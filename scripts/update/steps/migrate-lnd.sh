#!/usr/bin/env bash
set -euo pipefail

RELEASE=$1
UMBREL_ROOT=$2

NEW_DATA_FOLDER="${UMBREL_ROOT}/lnd"
CURRENT_DATA_FOLDER="${UMBREL_ROOT}/app-data/lightning/data"
TOR_DATA_DIR="${UMBREL_ROOT}/tor/data"

if [[ ! -d "${CURRENT_DATA_FOLDER}" ]]; then
	echo "LND has already been migrated"
	exit
fi

cat <<EOF > "$UMBREL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 74, "description": "Moving LND Data", "updateTo": "$RELEASE"}
EOF

# Lastly, move Umbrel's current 'lnd' folder into the app's data folder
# 'lightning' will then mount 'lnd' inside 'data' folder
mv "${CURRENT_DATA_FOLDER}" "${NEW_DATA_FOLDER}"

echo "LND successfully migrated"
