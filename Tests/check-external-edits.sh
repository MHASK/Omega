#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
OMEGA_EXTERNAL_CHECK="$(mktemp -d "${TMPDIR:-/tmp/}OmegaExternalApp.XXXXXX")"
trap 'rm -rf "$OMEGA_EXTERNAL_CHECK"' EXIT
python3 - "$OMEGA_EXTERNAL_CHECK" <<'PY'
from pathlib import Path
import shlex,subprocess,plistlib,sys
work=Path(sys.argv[1]); app=work/'Check.app'
(app/'Contents/MacOS').mkdir(parents=True)
subprocess.run(['ditto','Resources',str(app/'Contents/Resources')],check=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.omega.external-edit-check','CFBundleExecutable':'Check','CFBundleName':'Omega External Edit Check','CFBundlePackageType':'APPL'}))
source=work/'AppWithoutMain.swift'
source.write_text(Path('App.swift').read_text().replace('@main\n','',1))
args=shlex.split(next(l for l in Path('build.sh').read_text().splitlines() if l.startswith('xcrun swiftc')))
args[args.index('App.swift')]=str(source)
args[args.index('-O')]='-Onone'; args.remove('-whole-module-optimization')
args.insert(args.index('-o'),'Tests/ExternalEditCheck.swift')
args[args.index('-o')+1]=str(app/'Contents/MacOS/Check')
subprocess.run(args,check=True)
PY
mkdir -p "$OMEGA_EXTERNAL_CHECK/fixture"
"$OMEGA_EXTERNAL_CHECK/Check.app/Contents/MacOS/Check" "$OMEGA_EXTERNAL_CHECK/fixture"

if [[ -n "${1:-}" ]]; then
  mkdir -p "$1"
  cp "$OMEGA_EXTERNAL_CHECK/fixture/assistant-update.png" "$1/assistant-update.png"
fi
