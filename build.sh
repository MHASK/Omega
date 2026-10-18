#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="${1:-../Omega.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -whole-module-optimization -target arm64-apple-macosx14.0 Core.swift Coordination.swift Checklist.swift FolderTasks.swift FolderTasksUI.swift ChecklistUI.swift Recovery.swift UndoHistory.swift NotebookMigration.swift UndoTests.swift Store.swift Markdown.swift RichEditor.swift Search.swift SearchTests.swift Assistant.swift AssistantWork.swift AgentSetup.swift AssistantTests.swift AssistantWorkTests.swift Interface.swift Archive.swift GitSync.swift GitMerge.swift GitSyncUI.swift SettingsGit.swift LiveCollaboration.swift LiveCheckpointStore.swift Settings.swift SettingsAgents.swift Labels.swift LabelsTests.swift SettingsLabels.swift SettingsCard.swift Updates.swift AutoUpdates.swift SettingsUpdates.swift App.swift -o "$APP/Contents/MacOS/Folio" -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers -framework WebKit -lsqlite3
cp -R Resources/. "$APP/Contents/Resources/"
cp LICENSE NOTICE "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
cp OmegaIcon.icns "$APP/Contents/Resources/OmegaIcon.icns"
if [[ -n "${FOLIO_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$FOLIO_SIGN_IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
echo "Built $APP"
