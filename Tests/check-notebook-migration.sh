#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
OMEGA_MIGRATION_CHECK="$(mktemp -d "${TMPDIR:-/tmp/}OmegaMigrationCheck.XXXXXX")"
trap 'rm -rf "$OMEGA_MIGRATION_CHECK"' EXIT
xcrun swiftc -O -target arm64-apple-macosx14.0 Core.swift Recovery.swift UndoHistory.swift NotebookMigration.swift Tests/NotebookMigrationCheck.swift -o "$OMEGA_MIGRATION_CHECK/Check" -lsqlite3
"$OMEGA_MIGRATION_CHECK/Check"
