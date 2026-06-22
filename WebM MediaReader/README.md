# WebM MediaReader — native AVFoundation playback for `.webm`

A macOS MediaExtension (`MEFormatReader`) that demuxes WebM/Matroska and presents
the contained tracks to AVFoundation. Stage 1, what's here, **demuxes only**; it
parses the container, builds the per-frame sample table, and vends the existing
compressed samples to the system. That's enough for the format reader to load,
report correct track info, and be accepted by QuickTime — but **playback is
blocked at the codec layer** (see "Where it stops" below).

## Layout

- `WebMDemuxer.swift` — pure-Swift EBML/Matroska parser. No C deps. Validated
  against ffprobe (offsets, sizes, keyframe flags, packet counts).
- `WebMFormatReader.swift` — `MEFormatReader` / `METrackReader` / `MESampleCursor`
  shapes mirroring the Bink reader (`~/Development/bink/BinkMediaReader/`),
  byte-located samples sliced from an in-memory copy of the file.
- `WebMVP9Config.swift` — synthesises a `vpcC` atom from the first VP9 keyframe
  (VideoToolbox needs it; WebM doesn't carry one).
- `Info.plist` — `EXExtensionPointIdentifier = com.apple.mediaextension.formatreader`,
  registers for `.webm` / `org.webmproject.webm`.
- `WebM_MediaReader.entitlements` — `mediaextension.formatreader` + `app-sandbox`
  + read-only-from-`/Applications/WebMQuickLook.app/` exception.

## Build / install

`install.sh` at the repo root builds all three extensions (preview, thumbnail,
media reader) and signs+installs into `/Applications/WebMQuickLook.app`. The
media reader is special:

- It's built with **automatic signing** + `-allowProvisioningUpdates` because the
  `mediaextension.formatreader` entitlement is profile-gated and ad-hoc/manual
  signing won't load it.
- It's signed under **team `FE47VDP2YV` + bundle `com.sevdestruct.webm.mediareader`**;
  the whole project signs under that team. Don't re-sign the appex without the
  embedded provisioning profile or the system will refuse to load it.
- It lives at `Contents/Extensions/`, not `PlugIns/` (ExtensionKit, embed copy
  phase uses `dstSubfolderSpec = 16`, `dstPath = "$(EXTENSIONS_FOLDER_PATH)"`).
- Install enables it via `pluginkit -e use`, but on macOS 26 the user **also**
  has to flip the toggle in *System Settings → General → Login Items & Extensions
  → Media Extensions → WebM MediaReader*. `pluginkit` alone is not enough.

Verify post-install with `./verify-mediaextension.sh` (opens a VP9/Opus webm in
QuickTime and tails the reader log).

## Where it stops — and what's actually needed for playback

The reader loads in QuickTime and the video/audio tracks are accepted (correct
`naturalSize` + `nominalFrameRate`; lesson #1 from the Bink work — get these
wrong and the track is silently dropped before any decode happens). But:

- **VP9 passthrough doesn't work.** QuickTime won't opt into Apple's
  supplemental VP9 decoder (`VTRegisterSupplementalVideoDecoderIfAvailable`), so
  after loading the reader it says "isn't compatible" without ever requesting a
  frame. Same per-client opt-in catch-22 that sank the Bink custom decoder,
  except here it's *Apple's own* decoder the client won't enable.
- **In-reader VP9 decode also fails** (measured this session). The appex sandbox
  silently denies the output `CVPixelBuffer` allocation — `VTDecompressionSession`
  *creates*, `VTDecompressionSessionDecodeFrame` returns `noErr` with
  `info=0`, but the callback's image is nil. No sandbox violation is logged. The
  identical Swift code outside the appex decodes a real 512×512 frame. This is
  the Bink wall, decode-side.
- **VP8 / Vorbis** have no Apple decoder at all, opt-in or not.
- **Opus** is the one bright spot: `AudioConverterNew(opus → LPCM)` works inside
  the appex sandbox. So an in-reader Opus → LPCM passthrough is viable.

The remaining route to native playback is therefore the same one Bink takes:
**decode in-reader with vendored userspace-CPU libraries** (which don't touch
VideoToolbox or IOSurface) and **vend Motion-JPEG video + LPCM audio** (codecs
every client decodes with no opt-in, and which Bink proved work in the appex
sandbox).

Concrete shopping list:
- `vendor/libvpx/` — decodes VP8 + VP9 to a malloc'd raw buffer. The reader
  decodes each frame, JPEG-encodes it with `CGImageDestination` (pure-CPU, the
  only encoder that works in this sandbox — see the Bink notes), and vends as
  `kCMVideoCodecType_JPEG`. Adopt the same `BinkJPEGCache` lookahead pattern.
- `vendor/libvorbis/` — decodes Vorbis packets to LPCM. (Opus uses Apple's
  `AudioConverter` instead.) Both audio paths vend as LPCM, like Bink does.
- Bridging header + `HEADER_SEARCH_PATHS` like Bink's `project.yml` target
  `BinkMediaReader` (XcodeGen translates to the same pbxproj shape we use here).

After that, the existing demuxer + reader scaffold just plugs in: every frame
already has a byte range and PTS; replace the "vend the bytes" cursor with
"decode-then-JPEG-encode" (copy the Bink `BinkJPEGCache` and `BinkVideoTrackReader`
patterns wholesale, swap in libvpx).

## Test files (not committed)

Built once with ffmpeg and reused across runs:
- `/tmp/vp9_opus.webm` — VP9 + Opus (modern webm).
- `/tmp/vp9_only.webm` — VP9 only (for video-path debugging).
- The committed `sample.webm` is VP8 + Vorbis (worst case; needs both vendored
  decoders).
