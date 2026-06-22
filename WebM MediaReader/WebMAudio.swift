//
//  WebMAudio.swift
//  WebM MediaReader
//
//  Opus → signed-16-bit LPCM, decoded once up-front and vended through an
//  audio track reader / cursor. AudioConverterNew(opus → LPCM) is one of the
//  few VideoToolbox/AudioToolbox APIs that DOES work in this appex sandbox
//  (proven this session), so we don't need to vendor libopus.
//
//  Vorbis is left out for now — there's no sandboxed Opus equivalent for it;
//  it'd need vendored libvorbis to live here.
//

import Foundation
import CoreMedia
import AudioToolbox
import MediaExtension
import AVFoundation
import os

private let log = Logger(subsystem: kWebMLogSubsystem, category: "audio")

private let kAudioFormatOpus: AudioFormatID = 0x6F707573  // 'opus'

/// Pre-decoded LPCM, codec-agnostic. The whole audio track is decoded once at
/// init time (same pattern Bink uses; audio is small enough that this keeps
/// the cursor trivial). Opus uses AudioConverter (sandbox-safe); Vorbis uses
/// libvorbis (sandbox-safe; AudioToolbox has no Vorbis decoder).
final class WebMOpusAudioBuffer {
    let sampleRate: Double
    let channels: Int
    let bytesPerFrame: Int
    struct Packet { let pts: CMTime; let duration: CMTime; let data: Data }
    private(set) var packets: [Packet] = []
    /// Cumulative audio-frame index where `packets[i]` starts. Built during
    /// pre-roll so the cursor (which is frame-indexed) can map a frame back to
    /// the packet containing it in O(log n).
    private(set) var packetFrameStart: [Int64] = []
    /// Total LPCM frames across the whole track. The cursor advances in
    /// frame units (CoreMedia steps an LPCM cursor by 1 per audio frame
    /// because the format desc has mFramesPerPacket = 1).
    private(set) var totalFrames: Int64 = 0

    init?(track: WebMTrack?, fileData: Data) {
        guard let t = track, t.channels > 0 else { return nil }
        switch t.codecID {
        case "A_OPUS":
            guard t.sampleRate > 0 else { return nil }
            sampleRate = t.sampleRate
            channels = t.channels
            bytesPerFrame = 2 * channels
            guard let pkts = Self.preRollOpus(track: t, fileData: fileData,
                                              sampleRate: sampleRate, channels: channels,
                                              bytesPerFrame: bytesPerFrame) else { return nil }
            buildFrameTable(pkts)
            log.notice("opus pre-rolled: \(self.packets.count) packets, \(self.totalFrames) frames, ends at \(self.packets.last?.pts.seconds ?? 0)s")
        case "A_VORBIS":
            guard let dec = WebMVorbisDecoder(codecPrivate: t.codecPrivate) else {
                log.error("Vorbis decoder init failed (CodecPrivate length \(t.codecPrivate.count))")
                return nil
            }
            sampleRate = dec.sampleRate
            channels = dec.channels
            bytesPerFrame = 2 * channels
            guard let pkts = Self.preRollVorbis(track: t, fileData: fileData, decoder: dec,
                                                bytesPerFrame: bytesPerFrame,
                                                sampleRate: sampleRate) else { return nil }
            buildFrameTable(pkts)
            log.notice("vorbis pre-rolled: \(self.packets.count) packets, \(self.totalFrames) frames")
        default:
            return nil
        }
    }

    private func buildFrameTable(_ pkts: [Packet]) {
        packets = pkts
        packetFrameStart.reserveCapacity(pkts.count)
        var running: Int64 = 0
        for p in pkts {
            packetFrameStart.append(running)
            running += Int64(p.data.count / bytesPerFrame)
        }
        totalFrames = running
    }

    /// Read a half-open [start, start+count) range of audio frames as a single
    /// LPCM Data, splicing across packet boundaries. The returned data length
    /// is exactly `(end - start) * bytesPerFrame` (clamped to track length).
    func readFrames(start: Int64, count: Int64) -> Data {
        let s = max(0, min(start, totalFrames))
        let e = max(s, min(start + count, totalFrames))
        if s == e { return Data() }
        // Locate the packet containing `s` (last packet with frameStart ≤ s).
        var lo = 0, hi = packets.count - 1, p = 0
        while lo <= hi {
            let m = (lo + hi) / 2
            if packetFrameStart[m] <= s { p = m; lo = m + 1 } else { hi = m - 1 }
        }
        var out = Data()
        out.reserveCapacity(Int(e - s) * bytesPerFrame)
        var cur = s
        while cur < e, p < packets.count {
            let pStart = packetFrameStart[p]
            let pFrames = Int64(packets[p].data.count / bytesPerFrame)
            let take = min(e, pStart + pFrames) - cur
            if take > 0 {
                let off = Int(cur - pStart) * bytesPerFrame
                out.append(packets[p].data.subdata(in: off..<(off + Int(take) * bytesPerFrame)))
                cur += take
            }
            p += 1
        }
        return out
    }

    // MARK: Opus

    /// Decode each Opus packet individually into its own LPCM packet, using the
    /// demuxer-reported PTS so the audio timeline lines up with the video.
    /// Batching multiple Opus packets per call is faster but truncates the
    /// trailing audio when the input callback signals EOF mid-buffer — which
    /// produced the "audio cuts out after a few seconds" symptom users saw.
    private static func preRollOpus(track t: WebMTrack, fileData: Data,
                                    sampleRate: Double, channels: Int, bytesPerFrame: Int) -> [Packet]? {
        var src = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        var dst = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16, mReserved: 0)
        var conv: AudioConverterRef?
        guard AudioConverterNew(&src, &dst, &conv) == noErr, let conv = conv else {
            log.error("Opus converter init failed"); return nil
        }
        defer { AudioConverterDispose(conv) }

        let maxFramesPerPacket = 5_760   // Opus max frame: 120 ms @ 48 kHz
        let maxOutBytes = maxFramesPerPacket * channels * 2
        let outBuf = UnsafeMutablePointer<Int16>.allocate(capacity: maxFramesPerPacket * channels)
        defer { outBuf.deallocate() }

        let ts: CMTimeScale = CMTimeScale(sampleRate)
        var out: [Packet] = []
        // Feed exactly one Opus packet per FillComplexBuffer call. The feed
        // object is reset between iterations so the converter sees a fresh
        // single-packet stream each time.
        let feed = SinglePacketFeed()
        for sample in t.samples {
            feed.payload = fileData.withUnsafeBytes { raw -> UnsafePointer<UInt8> in
                raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: sample.offset)
            }
            feed.size = sample.size
            feed.delivered = false

            var outFrames: UInt32 = UInt32(maxFramesPerPacket)
            var abl = AudioBufferList()
            abl.mNumberBuffers = 1
            abl.mBuffers = AudioBuffer(mNumberChannels: UInt32(channels),
                                       mDataByteSize: UInt32(maxOutBytes),
                                       mData: UnsafeMutableRawPointer(outBuf))
            _ = AudioConverterFillComplexBuffer(conv,
                singlePacketCallback, Unmanaged.passUnretained(feed).toOpaque(),
                &outFrames, &abl, nil)
            guard outFrames > 0 else { continue }

            // Use the demuxer-reported PTS, converted from ns → sampleRate
            // ticks. Per-packet PTS keeps the audio timeline aligned with the
            // video even if Opus packets have non-uniform lengths.
            let ptsTicks = (sample.pts * Int64(ts) + 500_000_000) / 1_000_000_000
            let pts = CMTime(value: ptsTicks, timescale: ts)
            let dur = CMTime(value: Int64(outFrames), timescale: ts)
            let bytes = Int(outFrames) * bytesPerFrame
            out.append(Packet(pts: pts, duration: dur,
                              data: Data(bytes: outBuf, count: bytes)))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: Vorbis

    private static func preRollVorbis(track t: WebMTrack, fileData: Data,
                                      decoder: WebMVorbisDecoder, bytesPerFrame: Int,
                                      sampleRate: Double) -> [Packet]? {
        let ts: CMTimeScale = CMTimeScale(sampleRate)
        var out: [Packet] = []
        var buffer = Data()
        for s in t.samples {
            buffer.removeAll(keepingCapacity: true)
            let payload: [UInt8] = fileData.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: s.offset)
                return Array(UnsafeBufferPointer(start: p, count: s.size))
            }
            let frames = decoder.decode(packet: payload, into: &buffer)
            if frames > 0 {
                // Per-packet PTS from the demuxer, scaled ns → sampleRate.
                let ptsTicks = (s.pts * Int64(ts) + 500_000_000) / 1_000_000_000
                let pts = CMTime(value: ptsTicks, timescale: ts)
                let dur = CMTime(value: Int64(frames), timescale: ts)
                out.append(Packet(pts: pts, duration: dur, data: Data(buffer)))
            }
        }
        return out.isEmpty ? nil : out
    }

    func makeFormatDescription() -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0)
        var fmt: CMAudioFormatDescription?
        let st = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &fmt)
        return st == noErr ? fmt : nil
    }
}

/// Single-packet feed for AudioConverter: hands one Opus packet to the
/// converter, then reports EOF. Reset between packets.
final class SinglePacketFeed {
    var payload: UnsafePointer<UInt8>? = nil
    var size: Int = 0
    var delivered = false
    private var packetDesc = AudioStreamPacketDescription(
        mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: 0)

    func fill(outNumPackets: UnsafeMutablePointer<UInt32>,
              outData: UnsafeMutablePointer<AudioBufferList>,
              outPacketDesc: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?) -> OSStatus {
        if delivered || size == 0 {
            outNumPackets.pointee = 0; return -1
        }
        outData.pointee.mNumberBuffers = 1
        outData.pointee.mBuffers = AudioBuffer(mNumberChannels: 0,
                                               mDataByteSize: UInt32(size),
                                               mData: UnsafeMutableRawPointer(mutating: payload))
        packetDesc.mStartOffset = 0
        packetDesc.mVariableFramesInPacket = 0
        packetDesc.mDataByteSize = UInt32(size)
        if let outPacketDesc = outPacketDesc {
            withUnsafeMutablePointer(to: &packetDesc) { outPacketDesc.pointee = $0 }
        }
        outNumPackets.pointee = 1
        delivered = true
        return noErr
    }
}

private let singlePacketCallback: AudioConverterComplexInputDataProc = {
    (_, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) in
    let feed = Unmanaged<SinglePacketFeed>.fromOpaque(inUserData!).takeUnretainedValue()
    return feed.fill(outNumPackets: ioNumberDataPackets, outData: ioData,
                     outPacketDesc: outDataPacketDescription)
}

// MARK: - Audio track reader

final class WebMAudioTrackReader: NSObject, METrackReader {
    private let buffer: WebMOpusAudioBuffer
    private let trackID: CMPersistentTrackID
    private let formatDesc: CMAudioFormatDescription

    init(buffer: WebMOpusAudioBuffer, trackID: CMPersistentTrackID) {
        self.buffer = buffer
        self.trackID = trackID
        self.formatDesc = buffer.makeFormatDescription()!
        super.init()
    }

    func loadTrackInfo(completionHandler: @escaping (METrackInfo?, Error?) -> Void) {
        let ti = METrackInfo(__mediaType: kCMMediaType_Audio, trackID: trackID,
                             formatDescriptions: [formatDesc])
        ti.isEnabled = true
        ti.naturalTimescale = CMTimeScale(buffer.sampleRate)
        log.notice("audio loadTrackInfo")
        completionHandler(ti, nil)
    }

    func generateSampleCursor(atPresentationTimeStamp pts: CMTime,
        completionHandler: @escaping (MESampleCursor?, Error?) -> Void) {
        completionHandler(WebMAudioSampleCursor(buffer: buffer, formatDesc: formatDesc,
                                                frame: frameFor(pts: pts)), nil)
    }
    func generateSampleCursorAtFirstSampleInDecodeOrder(
        completionHandler: @escaping (MESampleCursor?, Error?) -> Void) {
        completionHandler(WebMAudioSampleCursor(buffer: buffer, formatDesc: formatDesc, frame: 0), nil)
    }
    func generateSampleCursorAtLastSampleInDecodeOrder(
        completionHandler: @escaping (MESampleCursor?, Error?) -> Void) {
        completionHandler(WebMAudioSampleCursor(buffer: buffer, formatDesc: formatDesc,
                                                frame: max(0, buffer.totalFrames - 1)), nil)
    }

    /// Audio-frame index for a presentation time. Tolerates the ±infinity
    /// CMTimes CoreMedia passes during inspection — Int64(inf) crashes the
    /// reader.
    private func frameFor(pts: CMTime) -> Int64 {
        let secs = pts.seconds
        guard secs.isFinite else { return secs < 0 ? 0 : max(0, buffer.totalFrames - 1) }
        let f = Int64(secs * buffer.sampleRate)
        return min(max(0, f), max(0, buffer.totalFrames - 1))
    }
}

// MARK: - Audio sample cursor

/// Frame-indexed cursor. KEY INVARIANT: cursor position, PTS, step deltas, and
/// CMSampleBuffer sampleCount must ALL be in audio-frame units (one frame =
/// `bytesPerFrame` bytes). The earlier packet-indexed cursor cut audio out
/// because CoreMedia steps an LPCM cursor by 1 per audio frame (the format
/// desc has mFramesPerPacket = 1), and one buffer of N=960 frames was being
/// read as "step 960" → cursor jumped to end-of-stream → silence. Fix from
/// the Bink session.
final class WebMAudioSampleCursor: NSObject, MESampleCursor {
    private let buffer: WebMOpusAudioBuffer
    private let formatDesc: CMAudioFormatDescription
    fileprivate var frame: Int64
    private var ts: CMTimeScale { CMTimeScale(buffer.sampleRate) }

    init(buffer: WebMOpusAudioBuffer, formatDesc: CMAudioFormatDescription, frame: Int64) {
        self.buffer = buffer
        self.formatDesc = formatDesc
        let last = max(0, buffer.totalFrames - 1)
        self.frame = min(max(0, frame), last)
        super.init()
    }
    func copy(with zone: NSZone? = nil) -> Any {
        WebMAudioSampleCursor(buffer: buffer, formatDesc: formatDesc, frame: frame)
    }

    private func pts(_ f: Int64) -> CMTime { CMTime(value: f, timescale: ts) }

    var presentationTimeStamp: CMTime { pts(frame) }
    var decodeTimeStamp: CMTime { pts(frame) }
    /// ONE audio frame, not the host packet's duration. CoreMedia advances per
    /// frame and reads this to size each step.
    var currentSampleDuration: CMTime { CMTime(value: 1, timescale: ts) }
    var currentSampleFormatDescription: CMFormatDescription? { formatDesc }
    var allowIncrementalFragmentParsing: Bool { false }
    var decodeTimeOfLastSampleReachableByForwardSteppingThatIsAlreadyLoadedByByteSource: CMTime {
        pts(max(0, buffer.totalFrames - 1))
    }

    func stepInDecodeOrder(by stepCount: Int64, completionHandler: @escaping (Int64, Error?) -> Void) {
        completionHandler(step(stepCount), nil)
    }
    func stepInPresentationOrder(by stepCount: Int64, completionHandler: @escaping (Int64, Error?) -> Void) {
        completionHandler(step(stepCount), nil)
    }
    func stepByDecodeTime(_ delta: CMTime, completionHandler: @escaping (CMTime, Bool, Error?) -> Void) {
        stepByTime(delta, completionHandler)
    }
    func stepByPresentationTime(_ delta: CMTime, completionHandler: @escaping (CMTime, Bool, Error?) -> Void) {
        stepByTime(delta, completionHandler)
    }
    private func step(_ n: Int64) -> Int64 {
        let last = max(0, buffer.totalFrames - 1)
        let target = min(max(0, frame + n), last)
        let actual = target - frame
        frame = target
        return actual
    }
    private func stepByTime(_ delta: CMTime, _ ch: @escaping (CMTime, Bool, Error?) -> Void) {
        let targetSecs = pts(frame).seconds + delta.seconds
        let last = max(0, buffer.totalFrames - 1)
        let target: Int64
        if targetSecs.isFinite {
            target = min(max(0, Int64(targetSecs * buffer.sampleRate)), last)
        } else {
            target = targetSecs < 0 ? 0 : last
        }
        let actual = CMTimeSubtract(pts(target), pts(frame))
        let pinned = (target == 0 || target == last)
        frame = target
        ch(actual, pinned, nil)
    }
    func sampleLocation() throws -> MESampleLocation { throw MEError(.locationNotAvailable) }
    func chunkDetails() throws -> MESampleCursorChunk { throw MEError(.locationNotAvailable) }
    var syncInfo: AVSampleCursorSyncInfo {
        AVSampleCursorSyncInfo(sampleIsFullSync: ObjCBool(true),
                               sampleIsPartialSync: false, sampleIsDroppable: false)
    }
    var dependencyInfo: AVSampleCursorDependencyInfo {
        AVSampleCursorDependencyInfo(
            sampleIndicatesWhetherItHasDependentSamples: true, sampleHasDependentSamples: false,
            sampleIndicatesWhetherItDependsOnOthers: true, sampleDependsOnOthers: ObjCBool(false),
            sampleIndicatesWhetherItHasRedundantCoding: false, sampleHasRedundantCoding: false)
    }

    func loadSampleBufferContainingSamples(to endCursor: MESampleCursor?,
        completionHandler: @escaping (CMSampleBuffer?, Error?) -> Void) {
        // End frame is half-open [frame, endFrame). If no end cursor was
        // given, default to ~50 ms ahead — small enough to be responsive,
        // large enough to amortise the per-call CMBlockBuffer overhead.
        let endFrame: Int64
        if let end = endCursor as? WebMAudioSampleCursor {
            endFrame = max(frame + 1, end.frame)
        } else {
            endFrame = min(frame + Int64(buffer.sampleRate / 20), buffer.totalFrames)
        }
        let pcm = buffer.readFrames(start: frame, count: endFrame - frame)
        guard !pcm.isEmpty else {
            completionHandler(nil, NSError(domain: "WebMMediaReader", code: -4)); return
        }
        let frames = Int64(pcm.count / buffer.bytesPerFrame)

        var bb: CMBlockBuffer?
        let dataLen = pcm.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: dataLen, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: dataLen, flags: 0, blockBufferOut: &bb) == noErr,
            let bb = bb else {
            completionHandler(nil, NSError(domain: "WebMMediaReader", code: -5)); return
        }
        let copyOK = pcm.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: bb,
                                          offsetIntoDestination: 0, dataLength: dataLen) == noErr
        }
        guard copyOK else {
            completionHandler(nil, NSError(domain: "WebMMediaReader", code: -6)); return
        }

        var sbuf: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: ts),
                                        presentationTimeStamp: pts(frame),
                                        decodeTimeStamp: .invalid)
        var bpf = buffer.bytesPerFrame
        let st = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bb,
            formatDescription: formatDesc, sampleCount: CMItemCount(frames),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &bpf, sampleBufferOut: &sbuf)
        completionHandler(st == noErr ? sbuf : nil,
                          st == noErr ? nil : NSError(domain: "WebMMediaReader", code: -7))
    }
}
