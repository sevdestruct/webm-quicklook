//
//  WebMVorbisDecoder.swift
//  WebM MediaReader
//
//  Pure-CPU Vorbis → s16 LPCM via vendored libvorbis (+ libogg, for its
//  `ogg_packet` carrier struct — no actual Ogg framing involved). AudioToolbox
//  has no Vorbis decoder, so this is what fills the gap for VP8/Vorbis webm
//  files like the bundled sample.webm.
//
//  The codec setup uses three header packets (Identification, Comment, Setup)
//  that WebM stores in the track's CodecPrivate in Xiph-laced form:
//    byte 0 = packet_count - 1
//    then (packet_count - 1) lacing-size bytes (Xiph: 255 repeated, then a
//    < 255 byte terminates that packet's size)
//    then the three packet payloads concatenated.
//

import Foundation

/// Decodes Vorbis packets to interleaved s16 LPCM samples.
final class WebMVorbisDecoder {

    private var info = vorbis_info()
    private var comment = vorbis_comment()
    private var dsp = vorbis_dsp_state()
    private var block = vorbis_block()
    private var dspInited = false
    private var blockInited = false

    private(set) var channels: Int = 0
    private(set) var sampleRate: Double = 0

    init?(codecPrivate: [UInt8]) {
        guard let headers = Self.splitXiphLaced(codecPrivate), headers.count == 3 else {
            return nil
        }
        vorbis_info_init(&info)
        vorbis_comment_init(&comment)

        for (i, payload) in headers.enumerated() {
            var pkt = Self.makePacket(payload: payload, granule: -1, isFirst: i == 0, isLast: false)
            let r = vorbis_synthesis_headerin(&info, &comment, &pkt)
            if r < 0 {
                vorbis_info_clear(&info); vorbis_comment_clear(&comment)
                return nil
            }
        }
        guard info.channels > 0, info.rate > 0 else {
            vorbis_info_clear(&info); vorbis_comment_clear(&comment); return nil
        }
        channels = Int(info.channels)
        sampleRate = Double(info.rate)

        if vorbis_synthesis_init(&dsp, &info) != 0 {
            vorbis_info_clear(&info); vorbis_comment_clear(&comment); return nil
        }
        dspInited = true
        if vorbis_block_init(&dsp, &block) != 0 {
            return nil
        }
        blockInited = true
    }

    deinit {
        if blockInited { vorbis_block_clear(&block) }
        if dspInited { vorbis_dsp_clear(&dsp) }
        vorbis_comment_clear(&comment)
        vorbis_info_clear(&info)
    }

    /// Decode one Vorbis audio packet and append interleaved s16 LPCM to `out`.
    /// Returns the number of frames written (`out` grows by `frames * channels * 2` bytes).
    @discardableResult
    func decode(packet: [UInt8], into out: inout Data) -> Int {
        var pkt = Self.makePacket(payload: packet, granule: -1, isFirst: false, isLast: false)
        if vorbis_synthesis(&block, &pkt) != 0 { return 0 }
        if vorbis_synthesis_blockin(&dsp, &block) != 0 { return 0 }

        var totalFrames = 0
        while true {
            var pcmPlanes: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>? = nil
            let frames = vorbis_synthesis_pcmout(&dsp, &pcmPlanes)
            if frames <= 0 { break }
            if let pcmPlanes = pcmPlanes {
                appendInterleaved(planes: pcmPlanes, frames: Int(frames), into: &out)
                totalFrames += Int(frames)
            }
            _ = vorbis_synthesis_read(&dsp, frames)
        }
        return totalFrames
    }

    private func appendInterleaved(planes: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
                                   frames: Int, into out: inout Data) {
        let bytes = frames * channels * 2
        var scratch = [Int16](repeating: 0, count: frames * channels)
        for ch in 0..<channels {
            guard let plane = planes[ch] else { continue }
            for f in 0..<frames {
                let v = plane[f]
                let s = max(-1.0, min(1.0, v))
                scratch[f * channels + ch] = Int16(s * 32767.0)
            }
        }
        scratch.withUnsafeBufferPointer { buf in
            out.append(UnsafeRawBufferPointer(buf).bindMemory(to: UInt8.self).baseAddress!,
                       count: bytes)
        }
    }

    // MARK: - helpers

    /// Builds an `ogg_packet` referencing the caller's buffer. The buffer must
    /// outlive the resulting packet's use (we hand it straight to libvorbis,
    /// which copies what it needs synchronously).
    private static func makePacket(payload: [UInt8], granule: Int64,
                                   isFirst: Bool, isLast: Bool) -> ogg_packet {
        var pkt = ogg_packet()
        payload.withUnsafeBufferPointer { buf in
            pkt.packet = UnsafeMutablePointer(mutating: buf.baseAddress!)
        }
        pkt.bytes = payload.count
        pkt.b_o_s = isFirst ? 1 : 0
        pkt.e_o_s = isLast ? 1 : 0
        pkt.granulepos = granule
        return pkt
    }

    /// Split a Xiph-laced concatenation (used by WebM's Vorbis CodecPrivate
    /// and by Theora/Vorbis in Matroska generally) into its constituent packets.
    static func splitXiphLaced(_ raw: [UInt8]) -> [[UInt8]]? {
        guard !raw.isEmpty else { return nil }
        let count = Int(raw[0]) + 1
        guard count > 0, count <= 255 else { return nil }
        var p = 1
        var sizes: [Int] = []
        for _ in 0..<(count - 1) {
            var s = 0
            while p < raw.count {
                let b = Int(raw[p]); p += 1
                s += b
                if b != 255 { break }
            }
            sizes.append(s)
        }
        // last packet fills the remainder
        let known = sizes.reduce(0, +)
        let lastSize = raw.count - p - known
        guard lastSize > 0 else { return nil }
        sizes.append(lastSize)

        var packets: [[UInt8]] = []
        for s in sizes {
            guard p + s <= raw.count else { return nil }
            packets.append(Array(raw[p..<(p + s)]))
            p += s
        }
        return packets
    }
}
