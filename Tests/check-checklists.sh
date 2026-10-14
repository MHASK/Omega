#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
OMEGA_CHECKLIST_CHECK="$(mktemp -d "${TMPDIR:-/tmp/}OmegaChecklistApp.XXXXXX")"
trap 'rm -rf "$OMEGA_CHECKLIST_CHECK"' EXIT
python3 - "$OMEGA_CHECKLIST_CHECK" <<'PY'
from pathlib import Path
import shlex,subprocess,plistlib,sys
work=Path(sys.argv[1]); app=work/'Check.app'
(app/'Contents/MacOS').mkdir(parents=True)
subprocess.run(['ditto','Resources',str(app/'Contents/Resources')],check=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.omega.checklist-check','CFBundleExecutable':'Check','CFBundleName':'Omega Checklist Check','CFBundlePackageType':'APPL'}))
source=work/'AppWithoutMain.swift'
source.write_text(Path('App.swift').read_text().replace('@main\n','',1))
args=shlex.split(next(l for l in Path('build.sh').read_text().splitlines() if l.startswith('xcrun swiftc')))
args=[arg for arg in args if arg not in ['-O','-whole-module-optimization']]
args[args.index('App.swift')]=str(source)
args.insert(args.index('-o'),'Tests/ChecklistCheck.swift')
args[args.index('-o')+1]=str(app/'Contents/MacOS/Check')
subprocess.run(args,check=True)
PY
mkdir -p "$OMEGA_CHECKLIST_CHECK/fixture"
"$OMEGA_CHECKLIST_CHECK/Check.app/Contents/MacOS/Check" "$OMEGA_CHECKLIST_CHECK/fixture"

if [[ -n "${1:-}" ]]; then
  mkdir -p "$1"
  cp "$OMEGA_CHECKLIST_CHECK/fixture/folder-checklists.png" "$1/folder-checklists.png"
fi
