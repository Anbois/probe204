#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="probe204"
INSTALL_DIR="/opt/probe"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
INSTRUCTION_FILE_NAME="probe204-uninstall.txt"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Need root privileges. Requesting sudo..."
  exec sudo bash "$0" "$@"
fi

echo "Stopping and disabling ${SERVICE_NAME}..."
systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true

echo "Removing systemd unit..."
rm -f "${SERVICE_PATH}"
systemctl daemon-reload
systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true

echo "Removing installed files..."
rm -rf "${INSTALL_DIR}"

# Best effort: remove local instruction files from common homes.
rm -f "/root/${INSTRUCTION_FILE_NAME}" 2>/dev/null || true
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  USER_HOME="$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6 || true)"
  if [[ -n "${USER_HOME}" ]]; then
    rm -f "${USER_HOME}/${INSTRUCTION_FILE_NAME}" 2>/dev/null || true
  fi
fi

echo "probe204 removed."
