#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
FOLIO_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp/}FolioLayout.XXXXXX")"
trap 'rm -rf "$FOLIO_CHECK_DIR"' EXIT
FOLIO_CHECK_APP="$FOLIO_CHECK_DIR/Check.app"
mkdir -p "$FOLIO_CHECK_APP/Contents/MacOS"
cp -R Resources "$FOLIO_CHECK_APP/Contents/"
cat > "$FOLIO_CHECK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.folio.layout-check</string>
<key>CFBundleExecutable</key><string>LayoutCheck</string>
<key>CFBundleName</key><string>Folio Layout Check</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun swiftc -O -target arm64-apple-macosx14.0 Core.swift Recovery.swift UndoHistory.swift Store.swift Markdown.swift RichEditor.swift Search.swift Assistant.swift Interface.swift Tests/LayoutCheck.swift -o "$FOLIO_CHECK_APP/Contents/MacOS/LayoutCheck" -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers -framework WebKit -lsqlite3
"$FOLIO_CHECK_APP/Contents/MacOS/LayoutCheck" "$FOLIO_CHECK_DIR"
xcrun swiftc Tests/WideBlockCheck.swift -o "$FOLIO_CHECK_DIR/WideBlockCheck" -framework AppKit -framework WebKit
"$FOLIO_CHECK_DIR/WideBlockCheck" "$PWD/Resources/editor.css"
