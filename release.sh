#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
# Keep build numbers increasing; the installed app rejects downgrades.
VERSION="${1:?Usage: release.sh version build-number output-directory}"
BUILD="${2:?Supply an increasing integer build number}"
DEST="${3:?Supply a release output directory}"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$BUILD" =~ '^[1-9][0-9]*$' ]] || { print -u2 'Invalid release version'; exit 1; }
# Official releases must pass Apple notarization. A local development build can
# still be made with build.sh, but it cannot be published as an app update.
if [[ -z "${FOLIO_NOTARY_PROFILE:-}" && ( -z "${APPLE_ID:-}" || -z "${APPLE_PASSWORD:-}" || -z "${APPLE_TEAM_ID:-}" ) ]]; then
  print -u2 'Set FOLIO_NOTARY_PROFILE to an existing Keychain profile, or supply APPLE_ID, APPLE_PASSWORD and APPLE_TEAM_ID in the environment.'
  exit 1
fi
mkdir -p "$DEST"
DEST="${DEST:A}"
IDENTITY="${FOLIO_SIGN_IDENTITY:-Developer ID Application: Aikolumi Software Private Limited (A5S8X4RCAS)}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Info.plist
npm ci --prefix Editor --ignore-scripts
npm run build --prefix Editor
FOLIO_SIGN_IDENTITY="$IDENTITY" ./build.sh "$DEST/Omega.app"
codesign --verify --deep --strict "$DEST/Omega.app"
ditto -c -k --norsrc --keepParent "$DEST/Omega.app" "$DEST/Omega-$VERSION.zip"
./notarize.sh "$DEST/Omega-$VERSION.zip" "$DEST/notarization-app.json"
xcrun stapler staple "$DEST/Omega.app"
xcrun stapler validate "$DEST/Omega.app"
spctl --assess --type execute --verbose=2 "$DEST/Omega.app"
# The updater and the DMG ship the exact same stapled application. Automatic
# checks/downloads default to on; installation saves work before restarting.
ditto -c -k --norsrc --keepParent "$DEST/Omega.app" "$DEST/Omega-$VERSION.zip"
STAGE="$(mktemp -d "${TMPDIR:-/tmp/}omega-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$DEST/Omega.app" "$STAGE/Omega.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -ov -volname Omega -srcfolder "$STAGE" -format UDZO "$DEST/Omega-$VERSION.dmg"
codesign --force --timestamp --sign "$IDENTITY" "$DEST/Omega-$VERSION.dmg"
./notarize.sh "$DEST/Omega-$VERSION.dmg" "$DEST/notarization-dmg.json"
xcrun stapler staple "$DEST/Omega-$VERSION.dmg"
xcrun stapler validate "$DEST/Omega-$VERSION.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DEST/Omega-$VERSION.dmg"
python3 - "$DEST" "$VERSION" "$BUILD" <<'MANIFEST'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); version=sys.argv[2]; archive=root/f'Omega-{version}.zip'
digest=hashlib.sha256(archive.read_bytes()).hexdigest()
dmg=root/f'Omega-{version}.dmg'
(root/f'Omega-{version}.sha256').write_text(f'{digest}  {archive.name}\n{hashlib.sha256(dmg.read_bytes()).hexdigest()}  {dmg.name}\n')
(root/'Omega-update.json').write_text(json.dumps({'schema':1,'version':version,'build':int(sys.argv[3]),'architecture':'arm64','minimumSystemVersion':'14.0','archive':f'https://github.com/MHASK/Omega/releases/download/v{version}/{archive.name}','sha256':digest,'size':archive.stat().st_size},indent=2)+'\n')
MANIFEST
print "Release $VERSION ($BUILD) is ready."
