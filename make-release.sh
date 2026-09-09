#!/bin/sh
# Builds the shippable app and DMG, notarized and stapled, then writes the Sparkle
# appcast that tells existing copies the new version exists. ARCHS is passed on the
# command line because the same value set in project.pbxproj is silently ignored and
# yields an arm64-only binary. Needs the `notarytool` keychain profile once, and the
# Sparkle EdDSA private key in the login keychain — see NOTARIZING.md.
#
#   ./make-release.sh 0.3.0                    -> tag v0.3.0
#   ./make-release.sh 0.3.0 v0.3.0-beta.1      -> pre-release under a beta tag
set -e
cd "$(dirname "$0")"

VERSION="$1"
if [ -z "$VERSION" ]; then
  echo "usage: ./make-release.sh <version> [tag]    e.g. ./make-release.sh 0.3.0 v0.3.0-beta.1"
  exit 1
fi
# The tag is what the enclosure URL points at, so a beta tag has to be known here and
# not only at `gh release create` time — otherwise the feed links to a tag nobody made.
TAG="${2:-v$VERSION}"
case "$TAG" in
  *-beta*|*-rc*|*-alpha*) PRERELEASE="--prerelease"; LABEL="$VERSION Beta" ;;
  *)                      PRERELEASE=""; LABEL="$VERSION" ;;
esac
# Sparkle compares CFBundleVersion to decide what is newer. A UTC timestamp is monotonic
# and keeps no state anywhere, unlike an integer someone has to remember to bump.
BUILD=$(date -u +%Y%m%d%H%M)

ID="Developer ID Application: David Barkan (L26TPPMPF3)"
REPO="mrbarkan/videodart"

rm -rf ./build
xcodebuild -project VideoDart.xcodeproj -scheme VideoDart \
  -configuration Release -derivedDataPath ./build \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" build >/dev/null
rm -rf dist/VideoDart.app
mkdir -p dist
cp -R ./build/Build/Products/Release/VideoDart.app dist/

# Developer ID + hardened runtime: required for notarization, and the only way the app
# opens on someone else's Mac without the Privacy & Security dance.
#
# Signed inside-out rather than with --deep. Sparkle ships nested code — two XPC services,
# a helper app and the Autoupdate tool, each already signed by Sparkle's own team — and
# Apple's guidance is that --deep is not the way to re-sign those. It usually works right
# up until a notarization run rejects the bundle.
SPARKLE="dist/VideoDart.app/Contents/Frameworks/Sparkle.framework/Versions/B"
for nested in "$SPARKLE/XPCServices/Downloader.xpc" \
              "$SPARKLE/XPCServices/Installer.xpc" \
              "$SPARKLE/Updater.app" \
              "$SPARKLE/Autoupdate"; do
  codesign --force --options runtime --timestamp --sign "$ID" "$nested"
done
codesign --force --options runtime --timestamp --sign "$ID" \
  dist/VideoDart.app/Contents/Frameworks/Sparkle.framework
codesign --force --options runtime --timestamp --sign "$ID" dist/VideoDart.app
codesign --verify --strict --deep --verbose=1 dist/VideoDart.app 2>&1 | tail -1

# The app and the DMG are notarized separately and stapled separately: the DMG's ticket
# gets it mounted, the app's own ticket gets it launched after being dragged out — offline.
ditto -c -k --keepParent dist/VideoDart.app dist/VideoDart.zip
xcrun notarytool submit dist/VideoDart.zip --keychain-profile notarytool --wait
xcrun stapler staple dist/VideoDart.app
ditto -c -k --keepParent dist/VideoDart.app dist/VideoDart.zip  # re-zip, now stapled

# Staging dir exists only to put the /Applications drop target next to the app.
# ponytail: no background image or icon layout — that needs an AppleScripted Finder dance.
STAGE=$(mktemp -d)
cp -R dist/VideoDart.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f dist/VideoDart.dmg
hdiutil create -volname "VideoDart" -srcfolder "$STAGE" -format UDZO -quiet dist/VideoDart.dmg
rm -rf "$STAGE"
codesign --force --timestamp --sign "$ID" dist/VideoDart.dmg
xcrun notarytool submit dist/VideoDart.dmg --keychain-profile notarytool --wait
xcrun stapler staple dist/VideoDart.dmg

# --- Sparkle appcast -------------------------------------------------------------------
# sign_update prints the enclosure attributes verbatim — sparkle:edSignature and length —
# so they are dropped straight into the tag rather than parsed apart and reassembled.
SIGN="./build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
ENCLOSURE=$("$SIGN" dist/VideoDart.dmg)

# Only the newest item: Sparkle picks the best entry in the feed, and one release is the
# only thing this script knows about. Written to the repo root because SUFeedURL points
# at raw.githubusercontent.com — committing it is what publishes the update.
cat > appcast.xml <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>VideoDart</title>
    <item>
      <title>$LABEL</title>
      <pubDate>$(date -R 2>/dev/null || date "+%a, %d %b %Y %H:%M:%S %z")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/$REPO/releases/download/$TAG/VideoDart.dmg"
        type="application/octet-stream"
        $ENCLOSURE />
    </item>
  </channel>
</rss>
XML

echo
echo "dist/VideoDart.app"
echo "  version: $VERSION (build $BUILD)"
echo "  arches: $(lipo -archs dist/VideoDart.app/Contents/MacOS/VideoDart)"
echo "  min macOS: $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' dist/VideoDart.app/Contents/Info.plist)"
echo "  gatekeeper: $(spctl -a -vv dist/VideoDart.app 2>&1 | grep source=)"
echo "dist/VideoDart.dmg  <- send this one"
echo "  size: $(du -h dist/VideoDart.dmg | awk '{print $1}')"
echo "  gatekeeper: $(spctl -a -vv -t open --context context:primary-signature dist/VideoDart.dmg 2>&1 | grep source=)"
echo "  sha256: $(shasum -a 256 dist/VideoDart.dmg | awk '{print $1}')"
# The release notes are the newest CHANGELOG section, so the GitHub release and the
# changelog cannot drift apart by being written twice.
awk '/^## /{n++} n==1' CHANGELOG.md | tail -n +2 > dist/release-notes.md

echo
echo "appcast.xml and dist/release-notes.md written. To publish the update:"
echo "  gh release create $TAG dist/VideoDart.dmg --repo $REPO --title \"$LABEL\" $PRERELEASE --notes-file dist/release-notes.md"
echo "  git add appcast.xml && git commit -m \"Release $VERSION\" && git push"
echo "Existing copies see the update once appcast.xml is on the default branch."
