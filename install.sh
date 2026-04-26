#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="Anbois"
REPO_NAME="probe204"
BRANCH="main"

INSTALL_DIR="/opt/probe"
SERVICE_NAME="probe204"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
PROBE_FILE="${INSTALL_DIR}/probe.py"
UNINSTALL_FILE="${INSTALL_DIR}/uninstall.sh"
UNINSTALL_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}/uninstall.sh"

DEFAULT_PORT="18080"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $*"; }
fail() { echo -e "${RED}[ОШИБКА]${NC} $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Не найдена необходимая команда: $1"
}

detect_original_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "$SUDO_USER"
  else
    echo "${USER:-root}"
  fi
}

detect_original_home() {
  local u
  u="$(detect_original_user)"
  if [[ "$u" == "root" ]]; then
    echo "/root"
  else
    getent passwd "$u" | cut -d: -f6
  fi
}

require_root_or_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    return
  fi

  need_cmd sudo
  warn "Для установки нужны права root. Запрашиваю sudo..."

  local tmp_installer
  tmp_installer="$(mktemp /tmp/probe204-install.XXXXXX.sh)"

  if [[ "$0" == /dev/fd/* || "$0" == /proc/self/fd/* ]]; then
    need_cmd curl
    curl -fsSL "https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}/install.sh" -o "$tmp_installer"
  elif [[ -r "$0" ]]; then
    cp "$0" "$tmp_installer"
  else
    need_cmd curl
    curl -fsSL "https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}/install.sh" -o "$tmp_installer"
  fi

  [[ -s "$tmp_installer" ]] || fail "Не удалось подготовить временный установщик"

  chmod +x "$tmp_installer"
  sudo ORIGINAL_USER="${USER:-}" ORIGINAL_HOME="${HOME:-}" bash "$tmp_installer"
  rm -f "$tmp_installer"
  exit 0
}

detect_current_port() {
  if [[ -f "$PROBE_FILE" ]]; then
    local p
    p="$(grep -Eo 'PORT = [0-9]+' "$PROBE_FILE" 2>/dev/null | awk '{print $3}' | head -n1 || true)"
    if [[ -n "${p:-}" ]]; then
      echo "$p"
      return
    fi
  fi
  echo "$DEFAULT_PORT"
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 ))
}

get_external_ip() {
  curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || \
  curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || \
  true
}

main() {
  require_root_or_sudo

  need_cmd python3
  need_cmd systemctl
  need_cmd curl

  local current_port
  current_port="$(detect_current_port)"

  read -r -p "TCP-порт для probe204 [${current_port}]: " PORT
  PORT="${PORT:-$current_port}"

  validate_port "$PORT" || fail "Некорректный порт: $PORT"

  info "Устанавливаю probe204 в ${INSTALL_DIR}"

  mkdir -p "$INSTALL_DIR"

  cat > "$PROBE_FILE" <<EOF
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = ${PORT}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/generate_204":
            self.send_response(204)
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        return

HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
EOF

  curl -fsSL "$UNINSTALL_URL" -o "$UNINSTALL_FILE"
  chmod +x "$UNINSTALL_FILE"

  cat > "$SERVICE_FILE" <<EOF
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

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME" >/dev/null

  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -qi "Status: active"; then
      echo
      read -r -p "ufw активен. Открыть TCP-порт ${PORT}? [y/N]: " OPEN_UFW
      case "$OPEN_UFW" in
        y|Y|yes|YES|д|Д)
          ufw allow "${PORT}/tcp"
          info "Порт ${PORT}/tcp открыт в ufw"
          ;;
        *)
          warn "Порт в ufw не открывался"
          ;;
      esac
    else
      warn "ufw установлен, но не активен. Firewall на сервере не изменялся."
    fi
  fi

  local original_home
  original_home="${ORIGINAL_HOME:-$(detect_original_home)}"

  cat > "${original_home}/probe204-uninstall.txt" <<EOF
Удаление probe204

Для удаления:

sudo /opt/probe/uninstall.sh

Скрипт удаления:
- остановит службу probe204;
- отключит автозапуск;
- удалит systemd unit;
- удалит файлы /opt/probe;
- проверит и остановит зависший процесс, если он остался.

Проверка после удаления:

systemctl status probe204 --no-pager
sudo ss -lntp | grep ${PORT}
EOF

  chown "${ORIGINAL_USER:-$(detect_original_user)}":"${ORIGINAL_USER:-$(detect_original_user)}" "${original_home}/probe204-uninstall.txt" 2>/dev/null || true

  echo
  info "probe204 установлен"
  echo "Служба: ${SERVICE_NAME}"
  echo "Порт: ${PORT}/tcp"

  echo
  echo "Локальный HTTP-тест:"
  echo "  curl -i http://127.0.0.1:${PORT}/generate_204"

  if curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/generate_204"; then
    info "Локальная проверка пройдена: HTTP 204"
  else
    warn "Локальная проверка не пройдена"
  fi

  local external_ip
  external_ip="$(get_external_ip)"

  echo
  echo "Проверка снаружи:"
  echo "С другого сервера / ПК :"
  echo
  if [[ -n "$external_ip" ]]; then
    echo "  curl -i http://${external_ip}:${PORT}/generate_204"
  else
    echo "  curl -i http://SERVER_IP:${PORT}/generate_204"
  fi

  echo
  echo "Ожидаемый ответ:"
  echo "  HTTP/1.0 204 No Content"

  if [[ -n "$external_ip" ]]; then
    echo
    echo "Определённый внешний IPv4 сервера: ${external_ip}"
  fi

  echo
  echo "Если снаружи не отвечает:"
  echo "  1. Открыть TCP-порт ${PORT} в ufw/firewall сервера."
  echo "  2. Проверить firewall панели VPS/хостера или cloud security group."
  echo "  3. Проверить NAT/port-forward, если сервер находится за роутером."
  echo "  4. Убедиться, что сервис слушает порт: sudo ss -lntp | grep ${PORT}"

  echo
  echo "Удаление:"
  echo "  sudo /opt/probe/uninstall.sh"

  echo
  echo "Инструкция по удалению создана здесь:"
  echo "  ${original_home}/probe204-uninstall.txt"

  echo
  echo -e "${RED}${BOLD}ВАЖНО: если нужен доступ извне, необходимо открыть TCP-порт ${PORT} в firewall сервера, панели хостера, cloud security group или на роутере/NAT.${NC}"
  echo

  systemctl status "$SERVICE_NAME" --no-pager || true
}

main "$@"