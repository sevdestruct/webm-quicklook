//
//  WebMDemuxer.swift
//  WebM MediaReader
//
//  A small EBML/Matroska (WebM) demuxer. It scans the container and builds a
//  per-track sample table — byte offset, length, presentation time and keyframe
//  flag for every coded frame — so the MEFormatReader can hand the existing
//  VP9/Opus samples straight to the system's built-in decoders. No decode, no
//  transcode: this is a pure demuxer.
//
//  WebM is a constrained Matroska profile, which is in turn an EBML document.
//  We only parse the handful of elements a player needs: SegmentInfo
//  (timestamp scale + duration), Tracks (codec + geometry) and the Clusters
//  (SimpleBlock / BlockGroup) that carry the frames.
//

import Foundation

/// One coded frame located by byte range, with its presentation time.
struct WebMSample {
    let offset: Int          // absolute byte offset in the file
    let size: Int            // byte length of the frame
    let pts: Int64           // presentation time in nanoseconds
    var duration: Int64      // nanoseconds (filled in after the full scan)
    let isKey: Bool
}

/// Everything we learned about one track.
struct WebMTrack {
    var number: Int = 0
    var type: Int = 0                  // 1 = video, 2 = audio
    var codecID: String = ""
    var codecPrivate: [UInt8] = []
    var width = 0, height = 0
    var displayWidth = 0, displayHeight = 0
    var sampleRate: Double = 0
    var channels = 0
    var bitDepth = 0
    var defaultDurationNs: Int64 = 0
    var samples: [WebMSample] = []
}

final class WebMDemuxer {

    // EBML / Matroska element IDs (full IDs incl. length marker).
    private enum ID {
        static let ebml: UInt32            = 0x1A45DFA3
        static let segment: UInt32         = 0x18538067
        static let info: UInt32            = 0x1549A966
        static let timestampScale: UInt32  = 0x2AD7B1
        static let duration: UInt32        = 0x4489
        static let tracks: UInt32          = 0x1654AE6B
        static let trackEntry: UInt32      = 0xAE
        static let trackNumber: UInt32     = 0xD7
        static let trackType: UInt32       = 0x83
        static let codecID: UInt32         = 0x86
        static let codecPrivate: UInt32    = 0x63A2
        static let defaultDuration: UInt32 = 0x23E383
        static let video: UInt32           = 0xE0
        static let pixelWidth: UInt32      = 0xB0
        static let pixelHeight: UInt32     = 0xBA
        static let displayWidth: UInt32    = 0x54B0
        static let displayHeight: UInt32   = 0x54BA
        static let audio: UInt32           = 0xE1
        static let samplingFreq: UInt32    = 0xB5
        static let channels: UInt32        = 0x9F
        static let bitDepth: UInt32        = 0x6264
        static let cluster: UInt32         = 0x1F43B675
        static let timestamp: UInt32       = 0xE7
        static let simpleBlock: UInt32     = 0xA3
        static let blockGroup: UInt32      = 0xA0
        static let block: UInt32           = 0xA1
        static let blockDuration: UInt32   = 0x9B
        static let referenceBlock: UInt32  = 0xFB
        static let cues: UInt32            = 0x1C53BB6B
        static let chapters: UInt32        = 0x1043A770
        static let tags: UInt32            = 0x1254C367
        static let seekHead: UInt32        = 0x114D9B74
        static let attachments: UInt32     = 0x1941A469

        // Elements that begin a new top level (segment) section — used to stop
        // an unknown-sized Cluster.
        static let level1: Set<UInt32> = [cluster, info, tracks, cues, chapters,
                                          tags, seekHead, attachments]
    }

    private let data: [UInt8]
    private let count: Int

    private(set) var tracks: [WebMTrack] = []
    private(set) var timestampScale: Int64 = 1_000_000   // ns per tick (default 1ms)
    private(set) var durationNs: Int64 = 0

    init?(fileData: Data) {
        self.data = [UInt8](fileData)
        self.count = data.count
        guard count > 4 else { return nil }
        guard parse() else { return nil }
    }

    // MARK: convenience

    var videoTrack: WebMTrack? { tracks.first { $0.type == 1 && !$0.samples.isEmpty } }
    var audioTrack: WebMTrack? { tracks.first { $0.type == 2 && !$0.samples.isEmpty } }

    // MARK: - low-level EBML readers

    /// Read a variable-length integer. `keepMarker` true returns the element ID
    /// verbatim (marker bits retained); false strips the marker to get a size.
    /// Returns the value, its byte length, and whether all data bits were 1
    /// (the "unknown size" sentinel).
    private func readVint(at pos: Int, keepMarker: Bool) -> (value: UInt64, length: Int, allOnes: Bool)? {
        guard pos < count else { return nil }
        let first = data[pos]
        guard first != 0 else { return nil }
        var mask: UInt8 = 0x80
        var len = 1
        while len <= 8 && (first & mask) == 0 { mask >>= 1; len += 1 }
        guard len <= 8, pos + len <= count else { return nil }

        var value: UInt64 = keepMarker ? UInt64(first) : UInt64(first & (mask &- 1))
        for i in 1..<len { value = (value << 8) | UInt64(data[pos + i]) }

        // "all ones" is computed over the data bits only (7 bits in byte 0,
        // 8 per following byte).
        let dataBits = 7 * 1 + 8 * (len - 1)
        let allOnesValue: UInt64 = dataBits >= 64 ? .max : (UInt64(1) << UInt64(dataBits)) - 1
        let stripped = keepMarker ? (value & (UInt64.max >> (64 - dataBits))) : value
        return (value, len, stripped == allOnesValue)
    }

    /// Read element header: returns (id, dataStart, dataSize, unknownSize, next).
    private func readElement(at pos: Int, parentEnd: Int) -> (id: UInt32, dataStart: Int, dataSize: Int, unknown: Bool)? {
        guard pos < parentEnd else { return nil }
        guard let idv = readVint(at: pos, keepMarker: true) else { return nil }
        let idEnd = pos + idv.length
        guard let sz = readVint(at: idEnd, keepMarker: false) else { return nil }
        let dataStart = idEnd + sz.length
        if sz.allOnes {
            return (UInt32(truncatingIfNeeded: idv.value), dataStart, parentEnd - dataStart, true)
        }
        let dataSize = Int(sz.value)
        guard dataStart + dataSize <= parentEnd else {
            // Truncated/over-long element: clamp to parent so we still use what we have.
            return (UInt32(truncatingIfNeeded: idv.value), dataStart, parentEnd - dataStart, true)
        }
        return (UInt32(truncatingIfNeeded: idv.value), dataStart, dataSize, false)
    }

    private func uint(_ off: Int, _ len: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<len where off + i < count { v = (v << 8) | UInt64(data[off + i]) }
        return v
    }
    private func sint(_ off: Int, _ len: Int) -> Int64 {
        guard len > 0 else { return 0 }
        var v = Int64(bitPattern: uint(off, len))
        let shift = 64 - len * 8
        v = (v << shift) >> shift          // sign-extend
        return v
    }
    private func float(_ off: Int, _ len: Int) -> Double {
        if len == 4 { return Double(Float(bitPattern: UInt32(truncatingIfNeeded: uint(off, len)))) }
        if len == 8 { return Double(bitPattern: uint(off, len)) }
        return 0
    }
    private func string(_ off: Int, _ len: Int) -> String {
        let slice = data[off..<min(off + len, count)]
        return String(decoding: slice, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    // MARK: - structure walk

    private func parse() -> Bool {
        var pos = 0
        // EBML header
        guard let hdr = readElement(at: pos, parentEnd: count), hdr.id == ID.ebml else { return false }
        pos = hdr.dataStart + hdr.dataSize

        // Find the Segment (skip anything else at top level).
        while pos < count {
            guard let el = readElement(at: pos, parentEnd: count) else { break }
            if el.id == ID.segment {
                parseSegment(start: el.dataStart, end: el.dataStart + el.dataSize)
                break
            }
            pos = el.dataStart + el.dataSize
        }

        guard !tracks.isEmpty else { return false }
        finalizeSampleTables()
        return tracks.contains { !$0.samples.isEmpty }
    }

    private func parseSegment(start: Int, end: Int) {
        var pos = start
        while pos < end {
            guard let el = readElement(at: pos, parentEnd: end) else { break }
            switch el.id {
            case ID.info:    parseInfo(start: el.dataStart, end: el.dataStart + el.dataSize)
            case ID.tracks:  parseTracks(start: el.dataStart, end: el.dataStart + el.dataSize)
            case ID.cluster: parseCluster(start: el.dataStart, end: el.dataStart + el.dataSize, unknown: el.unknown, segmentEnd: end)
            default: break
            }
            pos = el.dataStart + el.dataSize
            if pos <= el.dataStart { break }   // guard against zero-progress
        }
    }

    private func parseInfo(start: Int, end: Int) {
        var pos = start
        var durationTicks: Double = 0
        while pos < end {
            guard let el = readElement(at: pos, parentEnd: end) else { break }
            switch el.id {
            case ID.timestampScale: timestampScale = Int64(uint(el.dataStart, el.dataSize))
            case ID.duration:       durationTicks = float(el.dataStart, el.dataSize)
            default: break
            }
            pos = el.dataStart + el.dataSize
        }
        if timestampScale <= 0 { timestampScale = 1_000_000 }
        if durationTicks > 0 { durationNs = Int64(durationTicks * Double(timestampScale)) }
    }

    private func parseTracks(start: Int, end: Int) {
        var pos = start
        while pos < end {
            guard let el = readElement(at: pos, parentEnd: end) else { break }
            if el.id == ID.trackEntry {
                if let t = parseTrackEntry(start: el.dataStart, end: el.dataStart + el.dataSize) {
                    tracks.append(t)
                }
            }
            pos = el.dataStart + el.dataSize
        }
    }

    private func parseTrackEntry(start: Int, end: Int) -> WebMTrack? {
        var t = WebMTrack()
        var pos = start
        while pos < end {
            guard let el = readElement(at: pos, parentEnd: end) else { break }
            switch el.id {
            case ID.trackNumber:     t.number = Int(uint(el.dataStart, el.dataSize))
            case ID.trackType:       t.type = Int(uint(el.dataStart, el.dataSize))
            case ID.codecID:         t.codecID = string(el.dataStart, el.dataSize)
            case ID.codecPrivate:    t.codecPrivate = Array(data[el.dataStart..<min(el.dataStart + el.dataSize, count)])
            case ID.defaultDuration: t.defaultDurationNs = Int64(uint(el.dataStart, el.dataSize))
            case ID.video:           parseVideo(into: &t, start: el.dataStart, end: el.dataStart + el.dataSize)
            case ID.audio:           parseAudio(into: &t, start: el.dataStart, end: el.dataStart + el.dataSize)
            default: break
            }
            pos = el.dataStart + el.dataSize
        }
        return t.number > 0 ? t : nil
    }

    private func parseVideo(into t: inout WebMTrack, start: Int, end: Int) {
        var pos = start
        while pos < end {
            guard let el = readElement(at: pos, parentEnd: end) else { break }
            switch el.id {
            case ID.pixelWidth:    t.width = Int(uint(el.dataStart, el.dataSize))
            case ID.pixelHeight:   t.height = Int(uint(el.dataStart, el.dataSize))
            case ID.displayWidth:  t.displayWidth = Int(uint(el.dataStart, el.dataSize))
            case ID.displayHeight: t.displayHeight = Int(uint(el.dataStart, el.dataSize))
            default: break
            }
            pos = el.dataStart + el.dataSize
        }
    }

    private func parseAudio(into t: inout WebMTrack, start: Int, end: Int) {
        var pos = start
        while pos < end {
            guard let el = readElement(at: pos, parentEnd: end) else { break }
            switch el.id {
            case ID.samplingFreq: t.sampleRate = float(el.dataStart, el.dataSize)
            case ID.channels:     t.channels = Int(uint(el.dataStart, el.dataSize))
            case ID.bitDepth:     t.bitDepth = Int(uint(el.dataStart, el.dataSize))
            default: break
            }
            pos = el.dataStart + el.dataSize
        }
    }

    // MARK: clusters

    private var trackIndexByNumber: [Int: Int] = [:]

    private func parseCluster(start: Int, end: Int, unknown: Bool, segmentEnd: Int) {
        if trackIndexByNumber.isEmpty {
            for (i, t) in tracks.enumerated() { trackIndexByNumber[t.number] = i }
        }
        var clusterTS: Int64 = 0
        var pos = start
        let hardEnd = unknown ? segmentEnd : end
        while pos < hardEnd {
            // For an unknown-sized cluster, stop when the next level-1 element begins.
            if unknown, let peek = readVint(at: pos, keepMarker: true),
               ID.level1.contains(UInt32(truncatingIfNeeded: peek.value)) {
                break
            }
            guard let el = readElement(at: pos, parentEnd: hardEnd) else { break }
            switch el.id {
            case ID.timestamp:
                clusterTS = Int64(uint(el.dataStart, el.dataSize))
            case ID.simpleBlock:
                parseBlock(start: el.dataStart, size: el.dataSize, clusterTS: clusterTS, simple: true, key: nil)
            case ID.blockGroup:
                parseBlockGroup(start: el.dataStart, end: el.dataStart + el.dataSize, clusterTS: clusterTS)
            default: break
            }
            pos = el.dataStart + el.dataSize
            if pos <= el.dataStart { break }
        }
    }

    private func parseBlockGroup(start: Int, end: Int, clusterTS: Int64) {
        var pos = start
        var blockStart = -1, blockSize = 0
        var hasReference = false
        while pos < end {
            guard let el = readElement(at: pos, parentEnd: end) else { break }
            switch el.id {
            case ID.block:          blockStart = el.dataStart; blockSize = el.dataSize
            case ID.referenceBlock: hasReference = true
            default: break
            }
            pos = el.dataStart + el.dataSize
        }
        if blockStart >= 0 {
            parseBlock(start: blockStart, size: blockSize, clusterTS: clusterTS, simple: false, key: !hasReference)
        }
    }

    /// Parse a (Simple)Block header and append its frame(s) to the right track.
    /// Handles all four lacing modes so multi-frame audio blocks vend correctly.
    private func parseBlock(start: Int, size: Int, clusterTS: Int64, simple: Bool, key: Bool?) {
        let blockEnd = start + size
        guard let tn = readVint(at: start, keepMarker: false) else { return }
        var p = start + tn.length
        guard p + 3 <= blockEnd else { return }
        let relTS = sint(p, 2); p += 2
        let flags = data[p]; p += 1

        guard let ti = trackIndexByNumber[Int(tn.value)] else { return }
        let isKey = key ?? ((flags & 0x80) != 0)
        let ptsTicks = clusterTS + relTS
        let pts = ptsTicks * timestampScale

        let lacing = (flags & 0x06) >> 1        // 0 none, 1 Xiph, 2 fixed, 3 EBML
        if lacing == 0 {
            appendSample(ti, offset: p, size: blockEnd - p, pts: pts, isKey: isKey)
            return
        }

        // Laced: first a frame count byte, then per-frame sizes.
        guard p < blockEnd else { return }
        let frames = Int(data[p]) + 1; p += 1
        var sizes: [Int] = []
        switch lacing {
        case 1: // Xiph: sizes as sequences of 0xFF…<255
            for _ in 0..<(frames - 1) {
                var s = 0
                while p < blockEnd { let b = Int(data[p]); p += 1; s += b; if b != 255 { break } }
                sizes.append(s)
            }
        case 2: // fixed: equal-sized frames
            let total = blockEnd - p
            let each = frames > 0 ? total / frames : total
            sizes = Array(repeating: each, count: frames - 1)
        case 3: // EBML: first size is a vint, rest are signed-vint deltas
            guard let first = readVint(at: p, keepMarker: false) else { return }
            p += first.length
            var prev = Int(first.value)
            sizes.append(prev)
            for _ in 0..<(frames - 2) {
                guard let d = readVint(at: p, keepMarker: false) else { break }
                p += d.length
                let bias = (Int(1) << (7 * d.length - 1)) - 1
                prev += Int(d.value) - bias
                sizes.append(prev)
            }
        default: break
        }
        // Emit each laced frame. Lacing is an audio convention; share the block PTS.
        var fo = p
        for s in sizes {
            guard s > 0, fo + s <= blockEnd else { break }
            appendSample(ti, offset: fo, size: s, pts: pts, isKey: isKey)
            fo += s
        }
        if fo < blockEnd {   // last frame fills the remainder
            appendSample(ti, offset: fo, size: blockEnd - fo, pts: pts, isKey: isKey)
        }
    }

    private func appendSample(_ ti: Int, offset: Int, size: Int, pts: Int64, isKey: Bool) {
        guard size > 0, offset >= 0, offset + size <= count else { return }
        tracks[ti].samples.append(WebMSample(offset: offset, size: size, pts: pts, duration: 0, isKey: isKey))
    }

    // MARK: finalize

    private func finalizeSampleTables() {
        for i in tracks.indices {
            var s = tracks[i].samples
            guard !s.isEmpty else { continue }
            s.sort { $0.pts < $1.pts }
            // Per-sample duration = gap to the next sample; last reuses the prior gap
            // or the track's DefaultDuration.
            for j in 0..<s.count {
                if j + 1 < s.count {
                    s[j].duration = max(0, s[j + 1].pts - s[j].pts)
                }
            }
            if s.count >= 2 {
                s[s.count - 1].duration = s[s.count - 2].duration
            } else if tracks[i].defaultDurationNs > 0 {
                s[0].duration = tracks[i].defaultDurationNs
            }
            if tracks[i].defaultDurationNs > 0 {
                for j in 0..<s.count where s[j].duration <= 0 { s[j].duration = tracks[i].defaultDurationNs }
            }
            tracks[i].samples = s
            let last = s[s.count - 1]
            durationNs = max(durationNs, last.pts + max(0, last.duration))
        }
    }
}
