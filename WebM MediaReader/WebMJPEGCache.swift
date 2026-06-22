//
//  WebMJPEGCache.swift
//  WebM MediaReader
//
//  One decoder + JPEG-encode pipeline shared across all video cursors. Mirrors
//  Bink's BinkJPEGCache exactly: CoreMedia copies cursors and re-requests
//  frames, so a per-cursor decoder re-seeks from the (sparse) keyframe every
//  time → O(N²) decode and a progressively-stuttering "crawl". Caching decoded
//  + JPEG-encoded frames here makes sequential playback O(1)/frame and serves
//  cursor copies / scrubs from cache.
//
//  Encode = `CGImageDestination` JPEG. Pure userspace CPU; it's the only
//  encoder that runs in the heavily-sandboxed MediaExtension appex (the Bink
//  catch-22 writeup explains why VideoToolbox encode is denied).
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

final class WebMJPEGCache {
    private let fileData: Data
    private let samples: [WebMSample]
    private let width: Int
    private let height: Int
    private let codec: WebMVPXDecoder.Codec
    private var frameCount: Int { samples.count }

    private let lock = NSLock()
    private var decoder: WebMVPXDecoder?
    private var decoderAt: Int = -1
    private var cache: [Int: Data] = [:]
    private var order: [Int] = []
    private var bytes = 0
    private let byteBudget = 192 * 1024 * 1024

    private let warmQueue = DispatchQueue(label: "com.sevdestruct.webm.prewarm", qos: .userInitiated)
    private let lookahead = 120
    private var warmedNext = 0
    private var warmTarget = 0
    private var warming = false

    init(fileData: Data, samples: [WebMSample], width: Int, height: Int, codec: WebMVPXDecoder.Codec) {
        self.fileData = fileData
        self.samples = samples
        self.width = width
        self.height = height
        self.codec = codec
    }

    /// Returns frame `i`'s JPEG, decoding+encoding (and warming ahead) as needed.
    func jpeg(forFrame i: Int) -> Data? {
        let result = produce(i)
        lock.lock()
        warmTarget = min(frameCount, i + 1 + lookahead)
        if warmedNext < i + 1 { warmedNext = i + 1 }
        let kick = !warming && warmedNext < warmTarget
        if kick { warming = true }
        lock.unlock()
        if kick { warmQueue.async { [weak self] in self?.warmLoop() } }
        return result
    }

    private func warmLoop() {
        while true {
            lock.lock()
            guard warmedNext < warmTarget, warmedNext < frameCount else {
                warming = false; lock.unlock(); return
            }
            let j = warmedNext
            lock.unlock()
            _ = produce(j)
            lock.lock(); if warmedNext == j { warmedNext = j + 1 }; lock.unlock()
        }
    }

    /// Index of the nearest keyframe ≤ `i`. VP9/VP8 are reference-frame coded,
    /// so we can only start decoding from a keyframe.
    private func nearestKeyframe(atOrBefore i: Int) -> Int {
        var j = min(i, samples.count - 1)
        while j > 0 && !samples[j].isKey { j -= 1 }
        return j
    }

    /// Synchronous decode + JPEG encode for one frame. libvpx is *stateful* —
    /// each frame depends on the previous one. When the requested frame is
    /// behind the decoder, or far enough ahead that catching up forward isn't
    /// worth it, restart from the nearest preceding key frame instead of
    /// re-decoding the whole stream from frame 0.
    private func produce(_ i: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[i] { return hit }

        // Decide where to start the decoder.
        //   - decoder fresh / has been thrown away: nearest key frame ≤ i
        //   - decoder is BEHIND i: keep state, catch up forward
        //     (UNLESS the catch-up span is so large we'd be faster restarting
        //      from a closer key frame — rare, but cheap to check)
        //   - decoder is AHEAD of i: it can't go backward; restart from key
        let key = nearestKeyframe(atOrBefore: i)
        var startFrom: Int
        if decoder == nil || decoderAt < 0 || decoderAt > i {
            decoder = WebMVPXDecoder(codec: codec)
            decoderAt = -1
            startFrom = key
        } else if decoderAt < key {
            // The cursor jumped forward past a key frame — restarting from the
            // key beats decoding everything between decoderAt and i.
            decoder = WebMVPXDecoder(codec: codec)
            decoderAt = -1
            startFrom = key
        } else {
            startFrom = decoderAt + 1
        }
        guard let dec = decoder else { return nil }

        // Catch up [startFrom, i) with the cheap path: tell libvpx about the
        // bytes so its reference-frame state advances, but skip the YUV→BGRA
        // conversion + malloc since we won't show these frames.
        for j in startFrom..<i {
            let s = samples[j]
            _ = fileData.withUnsafeBytes { raw -> Bool in
                let ptr = raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: s.offset)
                return dec.advanceFrame(bytes: ptr, size: s.size)
            }
            decoderAt = j
        }

        // Decode the requested frame and JPEG-encode it.
        let s = samples[i]
        guard let frame = fileData.withUnsafeBytes({ raw -> (UnsafeMutableRawPointer, Int, Int, Int)? in
            let ptr = raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: s.offset)
            return dec.decodeFrame(bytes: ptr, size: s.size)
        }) else {
            decoderAt = -1   // give up; next call rebuilds from scratch
            return nil
        }
        decoderAt = i

        guard let cg = WebMRenderer.cgImage(takingOwnedBGRA: frame.0,
                                            width: frame.1, height: frame.2, pitch: frame.3) else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        // 0.6 quality is the sweet spot for transcoded preview JPEGs: still
        // visually clean at typical playback sizes, ~3x smaller (and faster to
        // encode) than 0.85+. The downstream JPEG decoder eats CPU per byte so
        // smaller frames also reduce decode cost.
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let data = out as Data

        cache[i] = data; order.append(i); bytes += data.count
        while bytes > byteBudget, order.count > 1 {
            let evicted = order.removeFirst()
            if let old = cache.removeValue(forKey: evicted) { bytes -= old.count }
        }
        return data
    }
}

/// BGRA buffer → CGImage helper (same shape as Bink's renderer).
enum WebMRenderer {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let bgraBitmapInfo: CGBitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )

    /// Wrap a malloc'd BGRA buffer in a CGImage WITHOUT copying. The CGImage
    /// takes ownership: `ptr` is `free()`d when the image is released.
    static func cgImage(takingOwnedBGRA ptr: UnsafeMutableRawPointer,
                        width: Int, height: Int, pitch: Int) -> CGImage? {
        let release: CGDataProviderReleaseDataCallback = { _, data, _ in
            free(UnsafeMutableRawPointer(mutating: data))
        }
        guard let provider = CGDataProvider(
            dataInfo: nil, data: ptr, size: pitch * height, releaseData: release
        ) else { free(ptr); return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: pitch, space: sRGB, bitmapInfo: bgraBitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
