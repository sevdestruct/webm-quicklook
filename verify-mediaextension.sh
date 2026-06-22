#!/bin/bash
# Verify the WebM MediaExtension is loading. Run AFTER enabling “WebM MediaReader”
# in System Settings → General → Login Items & Extensions → Media Extensions.
#
# NOTE: a generic AVFoundation command-line tool will NEVER route to a
# MediaExtension (Apple gates this to QuickTime/Finder). So this script tests by
# opening the file in QuickTime Player and watching the reader's os_log. Empty
# reader logs = the client didn't load the reader (consent/routing); reader logs
# with "opened webm" = success.
set -e
BUNDLE_ID="com.sevdestruct.webm.mediareader"
SUBSYS="com.sevdestruct.webm.mediareader"
TEST="${1:-/tmp/vp9_opus.webm}"

echo "→ enabled state:"; pluginkit -mAv -i "$BUNDLE_ID" | head -2
echo "→ opening $TEST in QuickTime Player…"
open -a "QuickTime Player" "$TEST"
sleep 6
echo "→ reader logs (last 30s) — non-empty means it loaded:"
/usr/bin/log show --last 30s --predicate "subsystem == \"$SUBSYS\"" --style compact 2>/dev/null | tail -25
echo "→ (quit QuickTime when done)"
