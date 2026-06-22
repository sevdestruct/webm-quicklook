#!/bin/bash
#
# Build and install WebM Quick Look into /Applications, then register the
# Quick Look + Media extensions.
#
# Builds the whole app (which embeds the preview + thumbnail extensions) plus
# the native MediaExtension, assembles them into one bundle, signs, installs,
# and registers. The MediaExtension is signed separately because its
# com.apple.developer.mediaextension.formatreader entitlement is profile-gated.
set -e

CERT="Apple Development: Sev Gerk (XV4P32S998)"
PROJ="/Users/sev/Development/Webm-QuickLook-Plug-In"
BUILT_APP="$PROJ/build/Debug/Webm Quicklook.app"
APP="/Applications/Webm Quicklook.app"
APPEX="$APP/Contents/PlugIns/WebM Quicklook.appex"
THUMB_APPEX="$APP/Contents/PlugIns/WebM Quicklook Thumbnail.appex"
MEDIA_APPEX="$APP/Contents/Extensions/WebM MediaReader.appex"
MEDIA_BUNDLE_ID="com.sevdestruct.webm.mediareader"
APP_ENTITLEMENTS="$PROJ/Webm Quicklook/Webm_Quicklook.entitlements"
ENTITLEMENTS="$PROJ/WebM Quicklook/WebM_Quicklook.entitlements"
THUMB_ENTITLEMENTS="$PROJ/WebM Quicklook Thumbnail/WebM_Quicklook_Thumbnail.entitlements"

# Build the app (unsigned) — embeds the preview + thumbnail extensions. We sign
# manually below so the build stays non-interactive.
echo "→ Building app (preview + thumbnail embedded)…"
# ENABLE_DEBUG_DYLIB=NO: Debug builds otherwise split the binary into a separate
# "<name>.debug.dylib". Our top-level (non-deep) re-sign would leave that nested
# dylib ad-hoc-signed while the main executable gets the team signature, and
# dyld refuses to load it ("different Team IDs") — the app would crash at launch.
BUILD_OUTPUT=$(xcodebuild -project "$PROJ/Webm Quicklook.xcodeproj" \
  -scheme "Webm Quicklook" -configuration Debug \
  SYMROOT="$PROJ/build" ENABLE_DEBUG_DYLIB=NO \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build 2>&1)
echo "$BUILD_OUTPUT" | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" || true
echo "$BUILD_OUTPUT" | grep -q "BUILD SUCCEEDED" || { echo "✗ App build failed."; exit 1; }

# The MediaExtension format reader: profile-gated entitlement, so it builds with
# automatic signing (Xcode mints/embeds the provisioning profile). Signed in
# place by Xcode — do NOT re-sign it without the profile or it won't load.
echo "→ Building native MediaExtension (format reader)…"
MEDIA_OK=1
BUILD_OUTPUT=$(xcodebuild -project "$PROJ/Webm Quicklook.xcodeproj" \
  -target "WebM MediaReader" -configuration Debug \
  SYMROOT="$PROJ/build" ENABLE_DEBUG_DYLIB=NO \
  -allowProvisioningUpdates build 2>&1) || MEDIA_OK=0
echo "$BUILD_OUTPUT" | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED|Provisioning Profile:" || true
echo "$BUILD_OUTPUT" | grep -q "BUILD SUCCEEDED" || MEDIA_OK=0

echo "→ Installing to $APP…"
rm -rf "$APP"
cp -R "$BUILT_APP" "$APP"
if [ "$MEDIA_OK" = "1" ]; then
  mkdir -p "$APP/Contents/Extensions"
  cp -R "$PROJ/build/Debug/WebM MediaReader.appex" "$APP/Contents/Extensions/"
else
  echo "  ⚠ MediaExtension build failed (provisioning?) — installing without native playback."
fi

# Sign nested extensions first, then the app (seals everything). The
# MediaExtension keeps its own profile-based signature — don't touch it.
echo "→ Signing extensions + app…"
codesign --force --sign "$CERT" --options runtime --entitlements "$ENTITLEMENTS" "$APPEX"
codesign --force --sign "$CERT" --options runtime --entitlements "$THUMB_ENTITLEMENTS" "$THUMB_APPEX"
codesign --force --sign "$CERT" --options runtime --entitlements "$APP_ENTITLEMENTS" "$APP"

echo "→ Registering with Launch Services + Quick Look…"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -f "$APP" >/dev/null 2>&1 || true
pluginkit -a "$APPEX"
pluginkit -a "$THUMB_APPEX"
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

if [ "$MEDIA_OK" = "1" ]; then
  echo "→ Registering + enabling the MediaExtension…"
  pluginkit -a "$MEDIA_APPEX" 2>/dev/null || true
  pluginkit -e use -i "$MEDIA_BUNDLE_ID" 2>/dev/null || true
  echo "  (If .webm won't play natively, enable “WebM MediaReader” under System"
  echo "   Settings → General → Login Items & Extensions → Media Extensions.)"
fi

echo "✓ Done. Launch the app once if the extensions don't appear immediately."
