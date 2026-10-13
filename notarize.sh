#!/bin/zsh
set -euo pipefail
ARTIFACT="${1:?Usage: notarize.sh artifact result.json}"
RESULT="${2:?Provide a path for Apple's submission result}"
typeset -a AUTH
if [[ -n "${FOLIO_NOTARY_PROFILE:-}" ]]; then
  AUTH=(--keychain-profile "$FOLIO_NOTARY_PROFILE")
else
  : "${APPLE_ID:?Supply notarization credentials}"
  : "${APPLE_PASSWORD:?Supply an app-specific password in the environment}"
  : "${APPLE_TEAM_ID:?Supply the Developer ID signing team}"
  AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID")
fi
# Do not trace this command: authentication never belongs in release logs.
xcrun notarytool submit "$ARTIFACT" "${AUTH[@]}" --wait --output-format json > "$RESULT"
python3 - "$RESULT" <<'VERIFY'
import json,sys
result=json.load(open(sys.argv[1]))
print('Apple notarization:',result.get('status','Unknown'),'·',result.get('id',''))
if result.get('status') != 'Accepted':
    sys.exit('Notarization was not accepted. Inspect the submission log before releasing.')
VERIFY
