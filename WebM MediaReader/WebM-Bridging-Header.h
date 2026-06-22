//
//  WebM-Bridging-Header.h
//  WebM MediaReader
//
//  Exposes the vendored libvpx decoder C-API to Swift.
//

#ifndef WebM_Bridging_Header_h
#define WebM_Bridging_Header_h

#include <vpx/vpx_codec.h>
#include <vpx/vpx_decoder.h>
#include <vpx/vpx_image.h>
#include <vpx/vp8dx.h>

#include <ogg/ogg.h>
#include <vorbis/codec.h>

#endif
