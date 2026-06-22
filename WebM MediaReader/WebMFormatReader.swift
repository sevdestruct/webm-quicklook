//
//  WebMFormatReader.swift
//  WebM MediaReader
//
//  An MEFormatReader that makes a .webm look like a movie to AVFoundation.
//  Container-side it's a pure demuxer (see WebMDemuxer); codec-side it uses
//  the Bink trick: decode VP9/VP8 in-reader with libvpx (vendored, pure
//  userspace CPU) and present each frame as JPEG, so the SYSTEM's built-in
//  Motion-JPEG decoder renders it — no client opt-in needed, no per-client
//  catch-22, no sandbox-blocked VideoToolbox decode. Opus audio is decoded
//  in-reader to signed-16-bit LPCM with the AudioToolbox AudioConverter
//  (verified to work in this sandbox).
//

import Foundation
import MediaExtension
import CoreMedia
import AVFoundation
import os

let kWebMLogSubsystem = "com.sevdestruct.webm.mediareader"
private let log = Logger(subsystem: kWebMLogSubsystem, category: "reader")

// MARK: - Format reader extension (principal class)

final class WebMFormatReaderExtension: NSObject, MEFormatReaderExtension {
    func formatReader(with byteSource: MEByteSource,
                      options: MEFormatReaderInstantiationOptions?) throws -> MEFormatReader {
        return try WebMFormatReader(byteSource: byteSource)
    }
}

// MARK: - Format reader

final class WebMFormatReader: NSObject, MEFormatReader {
    private let fileData: Data
    private let demuxer: WebMDemuxer
    private let audio: WebMOpusAudioBuffer?

    init(byteSource: MEByteSource) throws {
        // Reader is sandboxed and handed a byte source (no file path), so read
        // the whole file into memory. The sync read API isn't exposed to Swift;
        // drive the async one to completion (init may block — the byte source
        // completes on its own queue).
        let len = byteSource.fileLength
        var assembled = Data()
        var offset: Int64 = 0
        while offset < len {
            let chunkLen = Int(min(len - offset, 8 * 1024 * 1024))
            let sem = DispatchSemaphore(value: 0)
            var got: Data?
            byteSource.read(length: chunkLen, from: offset) { d, _ in got = d; sem.signal() }
            sem.wait()
            guard let chunk = got, !chunk.isEmpty else { break }
            assembled.append(chunk)
            offset += Int64(chunk.count)
        }
        guard !assembled.isEmpty else {
            throw NSError(domain: "WebMMediaReader", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "byte source read failed"])
        }
        guard let dmx = WebMDemuxer(fileData: assembled) else {
            throw NSError(domain: "WebMMediaReader", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "not a parseable WebM stream"])
        }
        fileData = assembled
        demuxer = dmx
        // Opus audio is decoded once up front (it's small) so the audio cursor
        // can just step through pre-rolled LPCM packets like Bink does. Vorbis
        // would need libvorbis here.
        audio = WebMOpusAudioBuffer(track: dmx.audioTrack, fileData: assembled)
        super.init()
        let v = dmx.videoTrack
        log.notice("opened webm: \(dmx.tracks.count) tracks, video=\(v?.codecID ?? "none") \(v?.width ?? 0)x\(v?.height ?? 0) \(v?.samples.count ?? 0)f audio=\(dmx.audioTrack?.codecID ?? "none") dur=\(Double(dmx.durationNs)/1e9)s")
    }

    func loadFileInfo(completionHandler: @escaping (MEFileInfo?, Error?) -> Void) {
        let fi = MEFileInfo()
        fi.duration = CMTime(value: demuxer.durationNs, timescale: 1_000_000_000)
        completionHandler(fi, nil)
    }

    func loadMetadata(completionHandler: @escaping ([AVMetadataItem]?, Error?) -> Void) {
        completionHandler([], nil)
    }

    func loadTrackReaders(completionHandler: @escaping ([METrackReader]?, Error?) -> Void) {
        var readers: [METrackReader] = []
        if let v = demuxer.videoTrack,
           let vr = WebMVideoTrackReader(fileData: fileData, track: v, trackID: 1) {
            readers.append(vr)
        }
        if let a = audio {
            readers.append(WebMAudioTrackReader(buffer: a, trackID: 2))
        }
        log.notice("loadTrackReaders -> \(readers.count) reader(s)")
        completionHandler(readers, nil)
    }
}

// MARK: - Video track reader (Motion-JPEG via in-reader libvpx decode)

final class WebMVideoTrackReader: NSObject, METrackReader {
    private let track: WebMTrack
    private let trackID: CMPersistentTrackID
    private let formatDesc: CMVideoFormatDescription
    private let cache: WebMJPEGCache
    private let avgFrameDurationNs: Int64
    fileprivate var frameCount: Int { track.samples.count }

    init?(fileData: Data, track: WebMTrack, trackID: CMPersistentTrackID) {
        guard track.width > 0, track.height > 0, !track.samples.isEmpty else { return nil }
        let codec: WebMVPXDecoder.Codec
        switch track.codecID {
        case "V_VP9": codec = .vp9
        case "V_VP8": codec = .vp8
        default:
            log.error("unsupported video codec \(track.codecID)")
            return nil
        }
        var fmt: CMVideoFormatDescription?
        let st = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                codecType: kCMVideoCodecType_JPEG,
                                                width: Int32(track.width),
                                                height: Int32(track.height),
                                                extensions: nil,
                                                formatDescriptionOut: &fmt)
        guard st == noErr, let fmt = fmt else {
            log.error("CMVideoFormatDescriptionCreate (JPEG) failed: \(st)")
            return nil
        }
        self.track = track
        self.trackID = trackID
        self.formatDesc = fmt
        self.cache = WebMJPEGCache(fileData: fileData, samples: track.samples,
                                   width: track.width, height: track.height, codec: codec)
        if track.defaultDurationNs > 0 {
            avgFrameDurationNs = track.defaultDurationNs
        } else if let last = track.samples.last, track.samples.count > 1, last.pts > 0 {
            avgFrameDurationNs = max(1, last.pts / Int64(track.samples.count - 1))
        } else {
            avgFrameDurationNs = 33_333_333
        }
        super.init()
    }

    func loadTrackInfo(completionHandler: @escaping (METrackInfo?, Error?) -> Void) {
        let ti = METrackInfo(__mediaType: kCMMediaType_Video, trackID: trackID,
                             formatDescriptions: [formatDesc])
        ti.isEnabled = true
        ti.naturalTimescale = 1_000_000_000
        let dw = track.displayWidth > 0 ? track.displayWidth : track.width
        let dh = track.displayHeight > 0 ? track.displayHeight : track.height
        ti.naturalSize = CGSize(width: dw, height: dh)
        ti.nominalFrameRate = Float(1_000_000_000.0 / Double(avgFrameDurationNs))
        ti.requiresFrameReordering = false
        log.notice("video loadTrackInfo (MJPEG): \(dw)x\(dh) \(self.frameCount)f @\(ti.nominalFrameRate)fps")
        completionHandler(ti, nil)
    }

    private func makeCursor(index: Int) -> MESampleCursor {
        WebMVideoSampleCursor(cache: cache, samples: track.samples,
                              formatDesc: formatDesc, index: index)
    }
    func generateSampleCursor(atPresentationTimeStamp pts: CMTime,
        completionHandler: @escaping (MESampleCursor?, Error?) -> Void) {
        completionHandler(makeCursor(index: frameIndex(forSeconds: pts.seconds)), nil)
    }
    func generateSampleCursorAtFirstSampleInDecodeOrder(
        completionHandler: @escaping (MESampleCursor?, Error?) -> Void) {
        completionHandler(makeCursor(index: 0), nil)
    }
    func generateSampleCursorAtLastSampleInDecodeOrder(
        completionHandler: @escaping (MESampleCursor?, Error?) -> Void) {
        completionHandler(makeCursor(index: frameCount - 1), nil)
    }
    func loadTotalSampleDataLength(completionHandler: @escaping (Int64, Error?) -> Void) {
        // JPEGs are synthesised; rough heuristic (~1/8 raw size).
        completionHandler(Int64(track.width) * Int64(track.height) * Int64(frameCount) / 8, nil)
    }

    /// Map a presentation time to a frame index, tolerating the indefinite
    /// CMTimes (±infinity / NaN) CoreMedia passes during inspection — Int(inf)
    /// would crash the reader process and kill the whole track.
    private func frameIndex(forSeconds secs: Double) -> Int {
        guard secs.isFinite else { return secs < 0 ? 0 : frameCount - 1 }
        let target = Int64(secs * 1e9)
        var lo = 0, hi = frameCount - 1, ans = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if track.samples[mid].pts <= target { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return min(max(0, ans), frameCount - 1)
    }
}

// MARK: - Video sample cursor (vends one JPEG per frame)

final class WebMVideoSampleCursor: NSObject, MESampleCursor {
    private let cache: WebMJPEGCache
    private let samples: [WebMSample]
    private let formatDesc: CMVideoFormatDescription
    private var index: Int
    private var frameCount: Int { samples.count }

    init(cache: WebMJPEGCache, samples: [WebMSample],
         formatDesc: CMVideoFormatDescription, index: Int) {
        self.cache = cache
        self.samples = samples
        self.formatDesc = formatDesc
        self.index = min(max(0, index), samples.count - 1)
        super.init()
    }

    func copy(with zone: NSZone? = nil) -> Any {
        WebMVideoSampleCursor(cache: cache, samples: samples, formatDesc: formatDesc, index: index)
    }

    private func pts(_ i: Int) -> CMTime { CMTime(value: samples[i].pts, timescale: 1_000_000_000) }
    private func dur(_ i: Int) -> CMTime { CMTime(value: max(1, samples[i].duration), timescale: 1_000_000_000) }

    var presentationTimeStamp: CMTime { pts(index) }
    var decodeTimeStamp: CMTime { pts(index) }
    var currentSampleDuration: CMTime { dur(index) }
    var currentSampleFormatDescription: CMFormatDescription? { formatDesc }
    var allowIncrementalFragmentParsing: Bool { false }
    var decodeTimeOfLastSampleReachableByForwardSteppingThatIsAlreadyLoadedByByteSource: CMTime {
        pts(frameCount - 1)
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
        let target = min(max(0, index + Int(n)), frameCount - 1)
        let actual = Int64(target - index); index = target
        return actual
    }
    private func stepByTime(_ delta: CMTime, _ ch: @escaping (CMTime, Bool, Error?) -> Void) {
        let secs = pts(index).seconds + delta.seconds
        let target: Int
        if secs.isFinite {
            let t = Int64(secs * 1e9)
            var lo = 0, hi = frameCount - 1, ans = 0
            while lo <= hi {
                let mid = (lo + hi) / 2
                if samples[mid].pts <= t { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            target = min(max(0, ans), frameCount - 1)
        } else {
            target = secs < 0 ? 0 : frameCount - 1
        }
        let actual = CMTimeSubtract(pts(target), pts(index))
        let pinned = (target == 0 || target == frameCount - 1)
        index = target
        ch(actual, pinned, nil)
    }

    // We synthesise JPEGs from raw VP9 input, so samples have no byte location
    // in the source file — CoreMedia must read via loadSampleBufferContainingSamples.
    func sampleLocation() throws -> MESampleLocation { throw MEError(.locationNotAvailable) }
    func chunkDetails() throws -> MESampleCursorChunk { throw MEError(.locationNotAvailable) }

    // MJPEG frames are all sync (every JPEG is a self-contained image).
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
        guard let jpegData = cache.jpeg(forFrame: index) else {
            log.error("video frame \(self.index): decode/encode failed")
            completionHandler(nil, NSError(domain: "WebMMediaReader", code: -7)); return
        }
        let len = jpegData.count
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: len, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: len, flags: 0, blockBufferOut: &bb) == noErr,
              let bb = bb else {
            completionHandler(nil, NSError(domain: "WebMMediaReader", code: -8)); return
        }
        let copyOK = jpegData.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb,
                                          offsetIntoDestination: 0, dataLength: len) == noErr
        }
        guard copyOK else {
            completionHandler(nil, NSError(domain: "WebMMediaReader", code: -9)); return
        }

        var timing = CMSampleTimingInfo(duration: dur(index),
                                        presentationTimeStamp: pts(index),
                                        decodeTimeStamp: pts(index))
        var size = len
        var sbuf: CMSampleBuffer?
        let st = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bb,
            formatDescription: formatDesc, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sbuf)
        completionHandler(st == noErr ? sbuf : nil,
                          st == noErr ? nil : NSError(domain: "WebMMediaReader", code: -10))
    }
}
