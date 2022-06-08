#!/usr/bin/env bash
set -euo pipefail

RELEASE=$1
UMBREL_ROOT=$2

./check-memory "${RELEASE}" "${UMBREL_ROOT}" "notfirstrun"

# Only used on Umbrel OS
SD_CARD_UMBREL_ROOT="/sd-root${UMBREL_ROOT}"

echo
echo "======================================="
echo "=============== UPDATE ================"
echo "======================================="
echo "=========== Stage: Install ============"
echo "======================================="
echo

versionToInt () {
  echo "$@" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }';
}

[[ -f "/etc/default/umbrel" ]] && source "/etc/default/umbrel"

# Make Umbrel OS specific updates
if [[ ! -z "${UMBREL_OS:-}" ]]; then
    echo
    echo "============================================="
    echo "Installing on Umbrel OS $UMBREL_OS"
    echo "============================================="
    echo

    # Update status file
cat <<EOF > "$UMBREL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 30, "description": "Updating Umbrel OS", "updateTo": "$RELEASE"}
EOF

    # In Umbrel OS v0.1.2, we need to bind Avahi to only
    # eth0,wlan0 interfaces to prevent hostname cycling
    # https://github.com/getumbrel/umbrel-os/issues/76
    # This patch can be safely removed from Umbrel v0.3.x+
    if [[ $UMBREL_OS == "v0.1.2" ]] && [[ -f "/etc/avahi/avahi-daemon.conf" ]]; then
        echo "Binding Avahi to eth0 and wlan0"
        sed -i "s/#allow-interfaces=eth0/allow-interfaces=eth0,wlan0/g;" "/etc/avahi/avahi-daemon.conf"
        systemctl restart avahi-daemon.service
    fi

    # Update SD card installation
    if  [[ -f "${SD_CARD_UMBREL_ROOT}/.umbrel" ]]; then
        echo "Replacing ${SD_CARD_UMBREL_ROOT} on SD card with the new release"
        rsync --archive \
            --verbose \
            --include-from="${UMBREL_ROOT}/.umbrel-${RELEASE}/scripts/update/.updateinclude" \
            --exclude-from="${UMBREL_ROOT}/.umbrel-${RELEASE}/scripts/update/.updateignore" \
            --delete \
            "${UMBREL_ROOT}/.umbrel-${RELEASE}/" \
            "${SD_CARD_UMBREL_ROOT}/"

        echo "Fixing permissions"
        chown -R 1000:1000 "${SD_CARD_UMBREL_ROOT}/"
    else
        echo "ERROR: No Umbrel installation found at SD root ${SD_CARD_UMBREL_ROOT}"
        echo "Skipping updating on SD Card..."
    fi

    # Install unattended-updates for automatic security updates
    # The binary is unattended-upgrade, the package is unattended-upgrades
    if ! command -v unattended-upgrade &> /dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install unattended-upgrades -y
    fi

    # Patch PwnKit
    # https://security-tracker.debian.org/tracker/CVE-2021-4034
    policykit_version=$(dpkg -s policykit-1 | grep '^Version:')
    if [[ "$policykit_version" != "Version: 0.105-25+rpt1+deb10u1" ]]; then
      apt-get install --yes --only-upgrade policykit-1
    fi

    # Patch raspberry pi kernel (to fix Dirtypipe vuln.)
    # https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2022-0847
    active_kernel_version=$(uname -r)
    if [[ $(versionToInt "${active_kernel_version}") -lt $(versionToInt "5.10.103") ]]; then
      apt-get update
      apt-get install --yes --only-upgrade raspberrypi-kernel

      touch "/tmp/umbrel-update-reboot-required"
    fi

    # Make sure dhcpd ignores virtual network interfaces
    dhcpd_conf="/etc/dhcpcd.conf"
    dhcpd_rule="denyinterfaces veth*"
    if [[ -f "${dhcpd_conf}" ]] && ! cat "${dhcpd_conf}" | grep --quiet "${dhcpd_rule}"; then
      echo "${dhcpd_rule}" | tee -a "${dhcpd_conf}"
      systemctl restart dhcpcd
    fi

    # This makes sure systemd services are always updated (and new ones are enabled).
    UMBREL_SYSTEMD_SERVICES="${UMBREL_ROOT}/.umbrel-${RELEASE}/scripts/umbrel-os/services/*.service"
    for service_path in $UMBREL_SYSTEMD_SERVICES; do
      service_name=$(basename "${service_path}")
      install -m 644 "${service_path}" "/etc/systemd/system/${service_name}"
      systemctl enable "${service_name}"
    done
fi

if ! command -v "yq" >/dev/null 2>&1; then
  >&2 echo "'yq' is missing. Installing now..."

  # Define checksums for yq (4.24.5)
  declare -A yq_sha256
  yq_sha256["arm64"]="8879e61c0b3b70908160535ea358ec67989ac4435435510e1fcb2eda5d74a0e9"
  yq_sha256["amd64"]="c93a696e13d3076e473c3a43c06fdb98fafd30dc2f43bc771c4917531961c760"

  yq_version="v4.24.5"
  system_arch=$(dpkg --print-architecture)
  yq_binary="yq_linux_${system_arch}"

  # Download yq from github
  yq_temp_file="/tmp/yq"
  curl -L "https://github.com/mikefarah/yq/releases/download/${yq_version}/${yq_binary}" -o "${yq_temp_file}"

  # Check file matches checksum
  if [[ "$(sha256sum "${yq_temp_file}" | awk '{ print $1 }')" == "${yq_sha256[$system_arch]}" ]]; then
    mv "${yq_temp_file}" /usr/bin/yq
    chmod +x /usr/bin/yq

    echo "yq installed successfully..."
  else
    echo "yq install failed. sha256sum mismatch"
  fi
fi

# Checkout to the new release
cd "$UMBREL_ROOT"/.umbrel-"$RELEASE"

# Configure new install
echo "Configuring new release"
cat <<EOF > "$UMBREL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 40, "description": "Configuring new release", "updateTo": "$RELEASE"}
EOF

PREV_ENV_FILE="$UMBREL_ROOT/.env"
BITCOIN_NETWORK="mainnet"
[[ -f "${PREV_ENV_FILE}" ]] && source "${PREV_ENV_FILE}"
PREV_ENV_FILE="${PREV_ENV_FILE}" NETWORK=$BITCOIN_NETWORK ./scripts/configure

# Pulling new containers
echo "Pulling new containers"
cat <<EOF > "$UMBREL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 50, "description": "Pulling new containers", "updateTo": "$RELEASE"}
EOF
docker-compose pull

# Stop existing containers
echo "Stopping existing containers"
cat <<EOF > "$UMBREL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 60, "description": "Removing old containers", "updateTo": "$RELEASE"}
EOF

cd "$UMBREL_ROOT"
./scripts/stop || {
  # If Docker fails to stop containers we're most likely hitting this Docker bug: https://github.com/moby/moby/issues/17217
  # Restarting the Docker service seems to fix it
  echo "Attempting to autofix Docker failure"
  cat <<EOF > "$UMBREL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 65, "description": "Attempting to autofix Docker failure", "updateTo": "$RELEASE"}
EOF
  sudo systemctl restart docker || true # Soft fail on environments that don't use systemd
  sleep 1
  ./scripts/stop || {
    # If this doesn't resolve the issue, start containers again before failing so the web UI is still accessible
    echo "That didn't work, attempting to restart containers"
    ./scripts/start
    echo "Error stopping Docker containers" > "${UMBREL_ROOT}/statuses/update-failure"
    false
  }
}

# Overlay home dir structure with new dir tree
echo "Overlaying $UMBREL_ROOT/ with new directory tree"
rsync --archive \
    --verbose \
    --include-from="$UMBREL_ROOT/.umbrel-$RELEASE/scripts/update/.updateinclude" \
    --exclude-from="$UMBREL_ROOT/.umbrel-$RELEASE/scripts/update/.updateignore" \
    --delete \
    "$UMBREL_ROOT"/.umbrel-"$RELEASE"/ \
    "$UMBREL_ROOT"/

# Update Docker for Umbrel OS users. Some old installs may be running outdated versions of Docker
# that have missing Docker DNS features that we now rely on.
if [[ ! -z "${UMBREL_OS:-}" ]]; then
  echo "Updating Docker..."
  cat <<EOF > "$UMBREL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 69, "description": "Updating Docker", "updateTo": "$RELEASE"}
EOF
  "${UMBREL_ROOT}/scripts/update/steps/get-docker.sh" || {
    # If the docker update fails, revert the update to avoid leaving the user in a broken state
    echo "Updating Docker failed, reverting update!"
    echo "Error updating Docker" > "${UMBREL_ROOT}/statuses/update-failure"
    rsync -av \
      --include-from="$UMBREL_ROOT/.umbrel-backup/scripts/update/.updateinclude" \
      --exclude-from="$UMBREL_ROOT/.umbrel-backup/scripts/update/.updateignore" \
      "$UMBREL_ROOT"/.umbrel-backup/ \
      "$UMBREL_ROOT"/
    ./scripts/start
    false
  }
fi

# Migrate 'apps' structure to using app repos
"${UMBREL_ROOT}/scripts/update/steps/migrate-to-repo.sh" "$RELEASE" "$UMBREL_ROOT"

# Fix permissions
echo "Fixing permissions"
find "$UMBREL_ROOT" -path "$UMBREL_ROOT/app-data" -prune -o -exec chown 1000:1000 {} +
chmod -R 700 "$UMBREL_ROOT"/tor/data/*

# Make Umbrel OS specific post-update changes
if [[ ! -z "${UMBREL_OS:-}" ]]; then

  # Delete unused Docker images on Umbrel OS
  echo "Deleting previous images"
  cat <<EOF > "$UMBREL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 90, "description": "Deleting previous images", "updateTo": "$RELEASE"}
EOF
  docker image prune --all --force

  # Uninstall dphys-swapfile since we now use our own swapfile logic
  # Remove this in the next breaking update
  if command -v dphys-swapfile >/dev/null 2>&1; then
    echo "Removing unused dependency \"dphys-swapfile\""
    cat <<EOF > "$UMBREL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 95, "description": "Removing unused dependencies", "updateTo": "$RELEASE"}
EOF
    apt-get remove -y dphys-swapfile
  fi

  # Setup swap if it doesn't already exist
  # Remove this in the next breaking update
  MOUNT_POINT="/mnt/data"
  SWAP_DIR="/swap"
  SWAP_FILE="${SWAP_DIR}/swapfile"
  if ! df -h "${SWAP_DIR}" 2> /dev/null | grep --quiet '/dev/sd'; then
    cat <<EOF > "$UMBREL_ROOT"/statuses/update-status.json
{"state": "installing", "progress": 97, "description": "Setting up swap", "updateTo": "$RELEASE"}
EOF

    echo "Bind mounting external storage to ${SWAP_DIR}"
    mkdir -p "${MOUNT_POINT}/swap" "${SWAP_DIR}"
    mount --bind "${MOUNT_POINT}/swap" "${SWAP_DIR}"

    echo "Checking ${SWAP_DIR} is now on external storage..."
    df -h "${SWAP_DIR}" | grep --quiet '/dev/sd'

    echo "Setting up swapfile"
    rm "${SWAP_FILE}" || true
    fallocate -l 4G "${SWAP_FILE}"
    chmod 600 "${SWAP_FILE}"
    mkswap "${SWAP_FILE}"
    swapon "${SWAP_FILE}"
  fi
fi
