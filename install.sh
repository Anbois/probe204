#!/usr/bin/env bash
set -Eeuo pipefail

# probe204 installer
# Repository: https://github.com/Anbois/probe204

SERVICE_NAME="probe204"
INSTALL_DIR="/opt/probe"
PROBE_FILE="${INSTALL_DIR}/probe.py"
UNINSTALL_FILE="${INSTALL_DIR}/uninstall.sh"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
DEFAULT_PORT="18080"
REPO_RAW_BASE="https://raw.githubusercontent.com/Anbois/probe204/main"
UNINSTALL_INSTRUCTION_FILE="probe204-uninstall.txt"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

detect_original_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "${SUDO_USER}"
  else
    logname 2>/dev/null || echo "root"
  fi
}

get_user_home() {
  local user="$1"
  if [[ "$user" == "root" ]]; then
    echo "/root"
    return
  fi
  getent passwd "$user" | cut -d: -f6
}

require_root_or_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    return
  fi

  need_cmd sudo
  warn "Need root privileges. Requesting sudo..."

  # Do not re-exec "$0": with bash <(curl ...), "$0" may be /dev/fd/63,
  # which disappears after sudo boundary. Re-download to a real temp file.
  local tmp_installer
  tmp_installer="$(mktemp /tmp/probe204-install.XXXXXX.sh)"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${REPO_RAW_BASE}/install.sh" -o "$tmp_installer"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp_installer" "${REPO_RAW_BASE}/install.sh"
  else
    fail "curl or wget is required to request sudo automatically"
  fi

  chmod +x "$tmp_installer"
  exec sudo bash "$tmp_installer"
}

get_current_port() {
  if [[ -f "${PROBE_FILE}" ]]; then
    local current
    current="$(grep -Eo 'PORT = [0-9]+' "${PROBE_FILE}" 2>/dev/null | grep -Eo '[0-9]+' | tail -n1 || true)"
    if [[ -n "${current}" ]]; then
      echo "${current}"
      return
    fi
  fi
  echo "${DEFAULT_PORT}"
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 )) || return 1
}

ask_port() {
  local default_port="$1"
  local port

  while true; do
    read -r -p "Enter probe TCP port [${default_port}]: " port || true
    port="${port:-$default_port}"

    if validate_port "$port"; then
      echo "$port"
      return
    fi

    warn "Invalid port. Please enter a number from 1 to 65535."
  done
}

write_probe_py() {
  local port="$1"
  mkdir -p "${INSTALL_DIR}"

  cat > "${PROBE_FILE}" <<EOF
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = ${port}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/generate_204":
            self.send_response(204)
            self.end_headers()
        elif self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok\\n")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        return

if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
EOF

  chmod 0755 "${PROBE_FILE}"
}

write_uninstall_sh() {
  mkdir -p "${INSTALL_DIR}"

  cat > "${UNINSTALL_FILE}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="probe204"
INSTALL_DIR="/opt/probe"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

if [[ "${EUID}" -ne 0 ]]; then
  fail "Run as root: sudo ${INSTALL_DIR}/uninstall.sh"
fi

if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
  systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || warn "Could not stop/disable ${SERVICE_NAME}"
else
  warn "Service ${SERVICE_NAME} is not registered"
fi

rm -f "${SERVICE_FILE}"
rm -rf "${INSTALL_DIR}"
systemctl daemon-reload

info "probe204 has been removed"
EOF

  chmod 0755 "${UNINSTALL_FILE}"
}

write_service() {
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Simple HTTP 204 Probe Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${PROBE_FILE}
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF
}

write_uninstall_instruction() {
  local original_user="$1"
  local user_home="$2"

  [[ -n "$user_home" && -d "$user_home" ]] || return 0

  local target_file="${user_home}/${UNINSTALL_INSTRUCTION_FILE}"

  cat > "$target_file" <<EOF
probe204 uninstall instructions

To remove probe204 from this server, run:

  sudo /opt/probe/uninstall.sh

This will:
- stop the probe204 systemd service;
- disable autostart;
- remove /etc/systemd/system/probe204.service;
- remove /opt/probe;
- reload systemd units.

Check status before removal:

  systemctl status probe204 --no-pager
EOF

  chown "${original_user}:${original_user}" "$target_file" 2>/dev/null || true
  chmod 0644 "$target_file"
}

maybe_open_ufw() {
  local port="$1"

  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw not found. Firewall was not changed."
    return
  fi

  if ufw status 2>/dev/null | grep -qi "Status: active"; then
    read -r -p "ufw is active. Allow TCP port ${port}? [y/N]: " answer || true
    case "${answer:-N}" in
      y|Y|yes|YES)
        ufw allow "${port}/tcp"
        info "ufw rule added: ${port}/tcp"
        ;;
      *)
        warn "ufw rule was not added."
        ;;
    esac
  else
    warn "ufw is installed but not active. Firewall was not changed."
  fi
}

main() {
  require_root_or_sudo

  need_cmd python3
  need_cmd systemctl
  need_cmd grep
  need_cmd getent

  local original_user user_home default_port port
  original_user="$(detect_original_user)"
  user_home="$(get_user_home "$original_user")"
  default_port="$(get_current_port)"
  port="$(ask_port "$default_port")"

  write_probe_py "$port"
  write_uninstall_sh
  write_service
  write_uninstall_instruction "$original_user" "$user_home"

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"
  systemctl restart "${SERVICE_NAME}"

  maybe_open_ufw "$port"

  echo
  info "probe204 installed"
  echo "Service: ${SERVICE_NAME}"
  echo "Port: ${port}/tcp"
  echo "Local test:"
  echo "  curl -i http://127.0.0.1:${port}/generate_204"
  echo
  echo "Uninstall command:"
  echo "  sudo ${UNINSTALL_FILE}"
  echo
  if [[ -n "${user_home}" ]]; then
    echo "Uninstall instructions:"
    echo "  ${user_home}/${UNINSTALL_INSTRUCTION_FILE}"
  fi
  echo
  echo -e "${RED}${BOLD}IMPORTANT: open TCP port ${port} in your hoster/cloud firewall/security group/router if remote access is required.${NC}"
  echo
  systemctl --no-pager --full status "${SERVICE_NAME}" || true
}

main "$@"
