#!/usr/bin/env bash
set -euo pipefail

RELEASE=$1
UMBREL_ROOT=$2

echo "Migrating apps to use app repos"

cat <<EOF > "$UMBREL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 70, "description": "Reconfiguring apps", "updateTo": "$RELEASE"}
EOF

# 1. Install 'gettext-base' if not installed
# This needed for 'envsubst' which is used for templating
REQUIRED_PKG="gettext-base"
PKG_OK=$(dpkg-query -W --showformat='${Status}\n' $REQUIRED_PKG | grep "install ok installed")
if [[ "" = "${PKG_OK}" ]]; then
  apt-get --yes install "${REQUIRED_PKG}"
fi

# 5. Migrate Bitcoin, LND and Electrs
"${UMBREL_ROOT}/scripts/update/steps/migrate-bitcoin.sh" "${RELEASE}" "${UMBREL_ROOT}"
"${UMBREL_ROOT}/scripts/update/steps/migrate-lnd.sh" "${RELEASE}" "${UMBREL_ROOT}"
"${UMBREL_ROOT}/scripts/update/steps/migrate-electrs.sh" "${RELEASE}" "${UMBREL_ROOT}"

echo "Successfully migrated to enable app repos"