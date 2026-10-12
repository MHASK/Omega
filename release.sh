#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
# Keep build numbers increasing; the installed app rejects downgrades.
VERSION="${1:?Usage: release.sh version build-number output-directory}"
BUILD="${2:?Supply an increasing integer build number}"
DEST="${3:?Supply a release output directory}"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$BUILD" =~ '^[1-9][0-9]*$' ]] || { print -u2 'Invalid release version'; exit 1; }
mkdir -p "$DEST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Info.plist
FOLIO_SIGN_IDENTITY="${FOLIO_SIGN_IDENTITY:-Developer ID Application: Aikolumi Software Private Limited (A5S8X4RCAS)}" ./build.sh "$DEST/Omega.app"
codesign --verify --deep --strict "$DEST/Omega.app"
ditto -c -k --norsrc --keepParent "$DEST/Omega.app" "$DEST/Omega-$VERSION.zip"
# Optional for downloads distributed outside this Mac. Credentials stay in Keychain.
if [[ -n "${FOLIO_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DEST/Omega-$VERSION.zip" --keychain-profile "$FOLIO_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DEST/Omega.app"
  ditto -c -k --norsrc --keepParent "$DEST/Omega.app" "$DEST/Omega-$VERSION.zip"
fi
python3 - "$DEST" "$VERSION" "$BUILD" <<'MANIFEST'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); version=sys.argv[2]; archive=root/f'Omega-{version}.zip'
digest=hashlib.sha256(archive.read_bytes()).hexdigest()
(root/f'Omega-{version}.sha256').write_text(f'{digest}  {archive.name}\n')
(root/'Omega-update.json').write_text(json.dumps({'schema':1,'version':version,'build':int(sys.argv[3]),'architecture':'arm64','minimumSystemVersion':'14.0','archive':f'https://github.com/MHASK/Omega/releases/download/v{version}/{archive.name}','sha256':digest,'size':archive.stat().st_size},indent=2)+'\n')
MANIFEST
print "Release $VERSION ($BUILD) is ready."
