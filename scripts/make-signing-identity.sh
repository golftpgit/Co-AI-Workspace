#!/bin/bash
# A stable local code-signing identity, so the keychain stops asking after
# every rebuild.
#
# **What the problem actually is.** The app is signed ad-hoc, which means it has
# no certificate and its designated requirement is its own code-directory hash.
# Every rebuild changes that hash. A keychain item's ACL records *which program*
# may read it by that requirement — so after a rebuild the app is a different
# program as far as the keychain is concerned, "Always Allow" no longer matches,
# and the panel comes back. It is not a setting anywhere in System Settings, and
# there is nothing to turn off: the panel is the ACL working correctly.
#
# A self-signed certificate fixes it. The requirement then names the
# certificate, which does not change when the code does. This is separate from
# notarisation, which needs a paid Developer ID (P9.6) — that is about
# Gatekeeper on *other* machines; this is about the keychain on this one.
#
# This script does not create the certificate for you. Creating one writes a
# private key into your login keychain, and that is your decision to make in an
# interface you can see. The steps take about thirty seconds:
#
#   1. Open **Keychain Access**
#   2. Menu **Keychain Access → Certificate Assistant → Create a Certificate…**
#   3. Name:            Co-AI Workspace Dev
#      Identity Type:   Self Signed Root
#      Certificate Type: **Code Signing**
#      (leave "Let me override defaults" unticked)
#   4. Create, then Done
#
# Then run `scripts/build-app.sh` again — it picks the identity up by name. The
# first launch after that will ask once more, because the app has genuinely
# changed identity; grant it and it should stay granted.
#
# Set COAI_SIGN_IDENTITY to use a different name.
set -uo pipefail

IDENTITY="${COAI_SIGN_IDENTITY:-Co-AI Workspace Dev}"

echo "── signing identity ──"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  echo "   ✓ \"$IDENTITY\" is present — scripts/build-app.sh will use it"
  security find-identity -v -p codesigning | grep -F "$IDENTITY" | sed 's/^/     /'
  exit 0
fi

echo "   ✗ no code-signing identity called \"$IDENTITY\""
echo ""
echo "   Create one in Keychain Access (about thirty seconds):"
echo "     Keychain Access → Certificate Assistant → Create a Certificate…"
echo "       Name:              $IDENTITY"
echo "       Identity Type:     Self Signed Root"
echo "       Certificate Type:  Code Signing"
echo ""
echo "   Then run scripts/build-app.sh again."
echo ""
echo "   Until then the app is signed ad-hoc, which works — the only cost is"
echo "   that the keychain asks again after every rebuild, because an ad-hoc"
echo "   signature is the binary's own hash and so changes every time."
exit 1
