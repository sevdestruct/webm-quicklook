//
//  WebMVPXDecoder.swift
//  WebM MediaReader
//
//  Wraps libvpx (vendored, decoder-only build) to turn VP9/VP8 frames into
//  malloc'd BGRA buffers we can hand off to CGImage.
//
//  VP9 decode inside the appex sandbox is *blocked* via VideoToolbox (the
//  output CVPixelBuffer allocation is silently denied — see the session log).
//  libvpx is pure userspace CPU and doesn't touch IOSurface, so it works.
//

import Foundation
import Accelerate

final class WebMVPXDecoder {

    enum Codec { case vp9, vp8 }

    private var ctx: vpx_codec_ctx_t = vpx_codec_ctx_t()
    private(set) var width: Int = 0
    private(set) var height: Int = 0
    // vImage's YUV → ARGB conversion: a setup-heavy struct that should be
    // built once and reused per decoder. Init is deferred until the first
    // frame so we know the right colour matrix to use (BT.601 vs BT.709).
    private var conversion = vImage_YpCbCrToARGB()
    private var conversionInited = false

    init?(codec: Codec) {
        let iface: OpaquePointer?
        switch codec {
        case .vp9: iface = vpx_codec_vp9_dx()
        case .vp8: iface = vpx_codec_vp8_dx()
        }
        guard let iface = iface else { return nil }
        // Let libvpx parallelise frame decode across cores. Capped at 8 — VP9
        // tile-row parallelism gives sharply diminishing returns past that, and
        // the sandbox limits worker threads in practice.
        let cores = UInt32(min(8, max(2, ProcessInfo.processInfo.activeProcessorCount)))
        var cfg = vpx_codec_dec_cfg_t(threads: cores, w: 0, h: 0)
        let r = vpx_codec_dec_init_ver(&ctx, iface, &cfg, 0, VPX_DECODER_ABI_VERSION)
        if r != VPX_CODEC_OK { return nil }
    }

    deinit {
        _ = vpx_codec_destroy(&ctx)
    }

    /// Decode one frame and return it as a malloc'd BGRA buffer with the given
    /// row pitch (= width * 4). Caller owns the buffer (free it, or hand to
    /// `CGDataProvider` with a release callback).
    func decodeFrame(bytes: UnsafePointer<UInt8>, size: Int) -> (buf: UnsafeMutableRawPointer, w: Int, h: Int, pitch: Int)? {
        let r = vpx_codec_decode(&ctx, bytes, UInt32(size), nil, 0)
        guard r == VPX_CODEC_OK else { return nil }
        var iter: vpx_codec_iter_t? = nil
        guard let img = vpx_codec_get_frame(&ctx, &iter) else { return nil }
        let i = img.pointee
        let w = Int(i.d_w), h = Int(i.d_h)
        width = w; height = h
        let pitch = w * 4
        guard let dst = malloc(pitch * h) else { return nil }
        // libvpx outputs I420 (or similar) planar YUV; convert to BGRA.
        convertI420ToBGRA(image: i, dst: dst.assumingMemoryBound(to: UInt8.self), pitch: pitch)
        return (dst, w, h, pitch)
    }

    /// Decode a frame ONLY to update libvpx's reference-frame state — skip the
    /// YUV→BGRA conversion and the malloc. Used during catch-up between a
    /// scrub target and the nearest preceding key frame, where intermediate
    /// pixels aren't going to be shown. Much cheaper than `decodeFrame`.
    func advanceFrame(bytes: UnsafePointer<UInt8>, size: Int) -> Bool {
        let r = vpx_codec_decode(&ctx, bytes, UInt32(size), nil, 0)
        guard r == VPX_CODEC_OK else { return false }
        // Drain the output iterator so libvpx releases its frame buffer slot.
        var iter: vpx_codec_iter_t? = nil
        _ = vpx_codec_get_frame(&ctx, &iter)
        return true
    }

    /// I420 → BGRA via Accelerate/vImage (SIMD; orders of magnitude faster
    /// than a per-pixel Swift loop). BT.601 limited-range matrix is correct
    /// for VP8 and the SD-VP9 streams users actually drop into preview.
    private func convertI420ToBGRA(image i: vpx_image_t, dst: UnsafeMutablePointer<UInt8>, pitch: Int) {
        let w = Int(i.d_w), h = Int(i.d_h)
        guard let yPlane = i.planes.0, let uPlane = i.planes.1, let vPlane = i.planes.2 else { return }
        let yStride = Int(i.stride.0)
        let uStride = Int(i.stride.1)
        let vStride = Int(i.stride.2)

        if !conversionInited {
            var pixelRange = vImage_YpCbCrPixelRange(
                Yp_bias: 16, CbCr_bias: 128,
                YpRangeMax: 235, CbCrRangeMax: 240,
                YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
            let st = vImageConvert_YpCbCrToARGB_GenerateConversion(
                kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, &pixelRange, &conversion,
                kvImage420Yp8_Cb8_Cr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags))
            guard st == kvImageNoError else { return }
            conversionInited = true
        }

        var srcY = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: yPlane),
                                 height: vImagePixelCount(h), width: vImagePixelCount(w),
                                 rowBytes: yStride)
        var srcCb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: uPlane),
                                  height: vImagePixelCount(h / 2), width: vImagePixelCount(w / 2),
                                  rowBytes: uStride)
        var srcCr = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: vPlane),
                                  height: vImagePixelCount(h / 2), width: vImagePixelCount(w / 2),
                                  rowBytes: vStride)
        var dstBuf = vImage_Buffer(data: UnsafeMutableRawPointer(dst),
                                   height: vImagePixelCount(h), width: vImagePixelCount(w),
                                   rowBytes: pitch)
        // ARGB → BGRA channel permutation. The CGImage we build later uses
        // byteOrder32Little + alpha-skip-first, so memory layout is BGRA.
        let permute: [UInt8] = [3, 2, 1, 0]
        _ = vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(
            &srcY, &srcCb, &srcCr, &dstBuf, &conversion, permute, 255,
            vImage_Flags(kvImageNoFlags))
    }
}
