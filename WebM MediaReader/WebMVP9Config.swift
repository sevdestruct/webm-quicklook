//
//  WebMVP9Config.swift
//  WebM MediaReader
//
//  VP9 in a WebM container carries no codec-configuration box, but VideoToolbox's
//  (supplemental) VP9 decoder won't initialise without a `vpcC` atom in the
//  CMVideoFormatDescription. We synthesise one by reading the handful of fields
//  in the VP9 uncompressed frame header of the first key frame: profile, bit
//  depth, chroma subsampling and colour range. (Spec: VP9 Bitstream &
//  Decoding Process, "uncompressed_header" / "color_config".)
//

import Foundation

enum WebMVP9Config {

    private struct BitReader {
        let bytes: [UInt8]
        var bit = 0
        init(_ d: ArraySlice<UInt8>) { bytes = Array(d) }
        mutating func f(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n {
                let byteIdx = bit >> 3
                guard byteIdx < bytes.count else { return v << 1 }
                let b = (Int(bytes[byteIdx]) >> (7 - (bit & 7))) & 1
                v = (v << 1) | b
                bit += 1
            }
            return v
        }
    }

    /// Build a `vpcC` atom (incl. the 4-byte version/flags box prefix CoreMedia
    /// expects) from a VP9 key-frame payload. Falls back to profile-0 / 8-bit /
    /// 4:2:0 / limited-range if the header can't be read.
    static func vpcC(fromKeyFrame frame: ArraySlice<UInt8>) -> Data {
        var profile = 0, bitDepth = 8, subX = 1, subY = 1, fullRange = 0

        var r = BitReader(frame)
        if r.f(2) == 0b10 {                       // frame_marker
            let lo = r.f(1), hi = r.f(1)
            profile = (hi << 1) | lo
            if profile == 3 { _ = r.f(1) }        // reserved_zero
            let showExisting = r.f(1)
            if showExisting == 0 {
                let frameType = r.f(1)            // 0 == KEY_FRAME
                _ = r.f(1)                        // show_frame
                _ = r.f(1)                        // error_resilient_mode
                if frameType == 0 {
                    let sync = r.f(24)            // frame_sync_code
                    if sync == 0x498342 {
                        if profile >= 2 { bitDepth = r.f(1) == 1 ? 12 : 10 }
                        let colorSpace = r.f(3)
                        if colorSpace != 7 {       // != CS_RGB
                            fullRange = r.f(1)
                            if profile == 1 || profile == 3 {
                                subX = r.f(1); subY = r.f(1); _ = r.f(1)
                            } else { subX = 1; subY = 1 }
                        } else {                   // RGB ⇒ 4:4:4 full range
                            fullRange = 1
                            if profile == 1 || profile == 3 { subX = 0; subY = 0 }
                        }
                    }
                }
            }
        }

        // chromaSubsampling per vpcC: 0=4:2:0(vert) 1=4:2:0(colocated) 2=4:2:2 3=4:4:4
        let chroma: Int
        switch (subX, subY) {
        case (1, 1): chroma = 1
        case (1, 0): chroma = 2
        default:     chroma = 3
        }

        var box = Data()
        box.append(contentsOf: [1, 0, 0, 0])                 // version 1, flags 0
        box.append(UInt8(profile))
        box.append(31)                                        // level 3.1 — generous; decoder tolerant
        box.append(UInt8((bitDepth << 4) | (chroma << 1) | (fullRange & 1)))
        box.append(1)                                         // colourPrimaries  (BT.709)
        box.append(1)                                         // transferCharacteristics
        box.append(1)                                         // matrixCoefficients
        box.append(contentsOf: [0, 0])                        // codecInitializationDataSize = 0
        return box
    }
}
