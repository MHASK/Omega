#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
DEST="${1:?Usage: publish.sh release-directory release-notes.md}"
NOTES="${2:?Provide release notes}"
[[ -z "$(git status --porcelain)" ]] || { print -u2 'Commit the release source changes first.'; exit 1; }
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { print -u2 'Push this release commit to origin/main first.'; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Omega.app/Contents/Info.plist")"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || exit 1
codesign --verify --deep --strict -R '=anchor apple generic and identifier "local.folio.notes" and certificate leaf[subject.OU] = "A5S8X4RCAS"' "$DEST/Omega.app"
python3 - "$DEST" "$VERSION" <<'VERIFY'
import hashlib,json,pathlib,plistlib,sys
root=pathlib.Path(sys.argv[1]); version=sys.argv[2]; m=json.loads((root/'Omega-update.json').read_text()); a=root/f'Omega-{version}.zip'
info=plistlib.loads((root/'Omega.app/Contents/Info.plist').read_bytes())
assert m['version']==version and m['build']==int(info['CFBundleVersion'])
assert m['archive']==f'https://github.com/MHASK/Omega/releases/download/v{version}/{a.name}'
assert m['size']==a.stat().st_size and m['sha256']==hashlib.sha256(a.read_bytes()).hexdigest()
VERIFY
gh release create "v$VERSION" --repo MHASK/Omega --target "$(git rev-parse HEAD)" --title "Omega $VERSION" --notes-file "$NOTES" --draft "$DEST/Omega-$VERSION.zip" "$DEST/Omega-$VERSION.sha256" "$DEST/Omega-update.json"
gh release edit "v$VERSION" --repo MHASK/Omega --draft=false --latest
