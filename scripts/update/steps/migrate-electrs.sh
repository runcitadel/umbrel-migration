#!/usr/bin/env bash
set -euo pipefail

RELEASE=$1
UMBREL_ROOT=$2

APP_ID="electrs"
NEW_DATA_FOLDER="${UMBREL_ROOT}/electrs"
CURRENT_DATA_FOLDER="${UMBREL_ROOT}/app-data/${APP_ID}/data"
TOR_DATA_DIR="${UMBREL_ROOT}/tor/data"

cat <<EOF > "$UMBREL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 74, "description": "Moving Electrs Data", "updateTo": "$RELEASE"}
EOF

# Move Umbrel's current 'electrs' folder into the app's data folder
mv "${CURRENT_DATA_FOLDER}" "${NEW_DATA_FOLDER}"

echo "Electrs successfully migrated"