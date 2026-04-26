#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="probe204"
INSTALL_DIR="/opt/probe"
SCRIPT_PATH="${INSTALL_DIR}/probe.py"
UNINSTALL_PATH="${INSTALL_DIR}/uninstall.sh"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
DEFAULT_PORT="18080"
RAW_BASE="https://raw.githubusercontent.com/Anbois/probe204/main"
INSTRUCTION_FILE_NAME="probe204-uninstall.txt"

red_bold() { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }

fetch_file() {
  local url="$1"
  local output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$output" "$url"
  else
    red_bold "ERROR: curl or wget is required."
    exit 1
  fi
}

get_target_home() {
  local target_user="${SUDO_USER:-${USER:-root}}"

  if command -v getent >/dev/null 2>&1; then
    getent passwd "$target_user" | cut -d: -f6
  else
    eval echo "~${target_user}"
  fi
}

if [[ "${EUID}" -ne 0 ]]; then
  yellow "Need root privileges. Requesting sudo..."

  if [[ -r "$0" ]]; then
    exec sudo -E bash "$0" "$@"
  fi

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${RAW_BASE}/install.sh" | sudo -E bash -s -- "$@"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "${RAW_BASE}/install.sh" | sudo -E bash -s -- "$@"
  else
    red_bold "ERROR: curl or wget is required."
    exit 1
  fi
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  red_bold "ERROR: python3 is not installed. Install python3 first."
  exit 1
fi

CURRENT_PORT="${DEFAULT_PORT}"
if [[ -f "${SERVICE_PATH}" ]]; then
  DETECTED_PORT="$(grep -E '^Environment=PROBE204_PORT=' "${SERVICE_PATH}" | tail -n1 | sed 's/^Environment=PROBE204_PORT=//' || true)"
  if [[ -n "${DETECTED_PORT}" ]]; then
    CURRENT_PORT="${DETECTED_PORT}"
  fi
fi

printf "Probe HTTP port [%s]: " "${CURRENT_PORT}"
read -r PORT
PORT="${PORT:-${CURRENT_PORT}}"

if ! [[ "${PORT}" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  red_bold "ERROR: invalid port: ${PORT}"
  exit 1
fi

mkdir -p "${INSTALL_DIR}"

fetch_file "${RAW_BASE}/probe.py" "${SCRIPT_PATH}"
fetch_file "${RAW_BASE}/uninstall.sh" "${UNINSTALL_PATH}"

chmod 0755 "${SCRIPT_PATH}"
chmod 0755 "${UNINSTALL_PATH}"

cat > "${SERVICE_PATH}" <<EOF_SERVICE
[Unit]
Description=Simple HTTP 204 Probe Server
After=network.target

[Service]
Type=simple
Environment=PROBE204_HOST=0.0.0.0
Environment=PROBE204_PORT=${PORT}
ExecStart=/usr/bin/python3 ${SCRIPT_PATH}
Restart=always
RestartSec=3
User=root
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF_SERVICE

TARGET_HOME="$(get_target_home)"
if [[ -n "${TARGET_HOME}" && -d "${TARGET_HOME}" ]]; then
  INSTRUCTION_PATH="${TARGET_HOME}/${INSTRUCTION_FILE_NAME}"
  cat > "${INSTRUCTION_PATH}" <<EOF_INSTRUCTION
probe204 uninstall instructions
===============================

To remove probe204 from this server, run:

    sudo ${UNINSTALL_PATH}

This will:

1. Stop probe204 service.
2. Disable probe204 autostart.
3. Remove the systemd unit file:
   ${SERVICE_PATH}
4. Remove installed files from:
   ${INSTALL_DIR}
5. Reload systemd.

Check current service status:

    systemctl status ${SERVICE_NAME} --no-pager

EOF_INSTRUCTION
  chown "${SUDO_USER:-root}:${SUDO_USER:-root}" "${INSTRUCTION_PATH}" 2>/dev/null || true
  chmod 0644 "${INSTRUCTION_PATH}"
fi

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

green "probe204 installed and started."
systemctl --no-pager --full status "${SERVICE_NAME}" || true

printf '\nTest locally:\n'
printf '  curl -i http://127.0.0.1:%s/generate_204\n' "${PORT}"
printf '  curl -i http://127.0.0.1:%s/healthz\n' "${PORT}"

printf '\nUninstall command:\n'
printf '  sudo %s\n' "${UNINSTALL_PATH}"
if [[ -n "${TARGET_HOME:-}" && -d "${TARGET_HOME}" ]]; then
  printf 'Uninstall instructions saved to:\n'
  printf '  %s/%s\n' "${TARGET_HOME}" "${INSTRUCTION_FILE_NAME}"
fi

printf '\n'
red_bold "IMPORTANT: open TCP port ${PORT} in the server firewall and/or hosting provider firewall."
red_bold "If the port is closed externally, remote probes will not work."
