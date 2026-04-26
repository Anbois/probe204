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
warn() { echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $*"; }
fail() { echo -e "${RED}[ОШИБКА]${NC} $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Не найдена необходимая команда: $1"
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
  warn "Для установки нужны права root. Запрашиваю sudo..."

  local tmp_installer
  tmp_installer="$(mktemp /tmp/probe204-install.XXXXXX.sh)"

  # При запуске bash <(curl ...) путь $0 обычно /dev/fd/NN или /proc/self/fd/NN.
  # Такой поток нельзя надёжно повторно запускать после sudo, поэтому для этого случая
  # скачиваем install.sh заново в обычный временный файл.
  if [[ "$0" == /dev/fd/* || "$0" == /proc/self/fd/* ]]; then
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "${REPO_RAW_BASE}/install.sh" -o "$tmp_installer"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$tmp_installer" "${REPO_RAW_BASE}/install.sh"
    else
      rm -f "$tmp_installer"
      fail "Нужен sudo, а также curl или wget для повторного запуска установщика."
    fi
  elif [[ -r "$0" ]]; then
    cp "$0" "$tmp_installer"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "${REPO_RAW_BASE}/install.sh" -o "$tmp_installer"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp_installer" "${REPO_RAW_BASE}/install.sh"
  else
    rm -f "$tmp_installer"
    fail "Нужен sudo, а также curl или wget для автоповышения прав."
  fi

  [[ -s "$tmp_installer" ]] || fail "Временный файл установщика пустой: $tmp_installer"
  chmod 0755 "$tmp_installer"
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
    read -r -p "TCP-порт для probe204 [${default_port}]: " port || true
    port="${port:-$default_port}"

    if validate_port "$port"; then
      echo "$port"
      return
    fi

    warn "Некорректный порт. Нужно число от 1 до 65535."
  done
}

write_probe_py() {
  local port="$1"
  mkdir -p "${INSTALL_DIR}"

  cat > "${PROBE_FILE}" <<EOF_PY
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
EOF_PY

  chmod 0755 "${PROBE_FILE}"
}

write_uninstall_sh() {
  mkdir -p "${INSTALL_DIR}"

  cat > "${UNINSTALL_FILE}" <<'EOF_UNINSTALL'
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
warn() { echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $*"; }
fail() { echo -e "${RED}[ОШИБКА]${NC} $*" >&2; exit 1; }

if [[ "${EUID}" -ne 0 ]]; then
  fail "Удаление нужно запускать с sudo: sudo ${INSTALL_DIR}/uninstall.sh"
fi

if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
  systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || warn "Не удалось остановить/отключить ${SERVICE_NAME}"
else
  warn "Служба ${SERVICE_NAME} не зарегистрирована"
fi

rm -f "${SERVICE_FILE}"
rm -rf "${INSTALL_DIR}"
systemctl daemon-reload

info "probe204 удалён"
EOF_UNINSTALL

  chmod 0755 "${UNINSTALL_FILE}"
}

write_service() {
  cat > "${SERVICE_FILE}" <<EOF_SERVICE
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
EOF_SERVICE
}

write_uninstall_instruction() {
  local original_user="$1"
  local user_home="$2"

  [[ -n "$user_home" && -d "$user_home" ]] || return 0

  local target_file="${user_home}/${UNINSTALL_INSTRUCTION_FILE}"

  cat > "$target_file" <<EOF_TXT
Инструкция по удалению probe204

Для удаления probe204 с этого сервера выполните:

  sudo /opt/probe/uninstall.sh

Скрипт удаления выполнит:
- остановку systemd-службы probe204;
- отключение автозапуска;
- удаление /etc/systemd/system/probe204.service;
- удаление каталога /opt/probe;
- перезагрузку списка unit-файлов systemd.

Проверить статус перед удалением:

  systemctl status probe204 --no-pager
EOF_TXT

  chown "${original_user}:${original_user}" "$target_file" 2>/dev/null || true
  chmod 0644 "$target_file"
}

maybe_open_ufw() {
  local port="$1"

  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw не найден, firewall на сервере не изменялся."
    return
  fi

  if ufw status 2>/dev/null | grep -qi "Status: active"; then
    local answer
    read -r -p "ufw активен. Открыть TCP-порт ${port}? [y/N]: " answer || true
    case "${answer:-N}" in
      y|Y|yes|YES|д|Д|да|ДА)
        ufw allow "${port}/tcp"
        info "Добавлено правило ufw: ${port}/tcp"
        ;;
      *)
        warn "Правило ufw не добавлено."
        ;;
    esac
  else
    warn "ufw установлен, но не активен. Firewall на сервере не изменялся."
  fi
}

local_http_test() {
  local port="$1"
  echo
  echo "Локальный HTTP-тест:"
  echo "  curl -i http://127.0.0.1:${port}/generate_204"

  if command -v curl >/dev/null 2>&1; then
    local http_code
    http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${port}/generate_204" 2>/dev/null || true)"
    if [[ "$http_code" == "204" ]]; then
      info "Локальная проверка пройдена: HTTP 204"
    else
      warn "Локальная проверка не пройдена. Получен HTTP-код: ${http_code:-нет ответа}"
      warn "Проверьте: systemctl status ${SERVICE_NAME} --no-pager"
    fi
  else
    warn "curl не найден, автоматическая локальная проверка пропущена."
  fi
}

detect_external_ip() {
  command -v curl >/dev/null 2>&1 || return 0

  local ip
  ip="$(curl -4fsS --max-time 4 https://ifconfig.me 2>/dev/null || true)"
  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    ip="$(curl -4fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
  fi

  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "$ip"
  fi
}

print_external_check_instructions() {
  local port="$1"
  local external_ip="$2"
  local target="SERVER_IP"

  if [[ -n "$external_ip" ]]; then
    target="$external_ip"
  fi

  echo
  echo -e "${BOLD}Проверка снаружи:${NC}"
  echo "С другого сервера / ПК выполните:"
  echo
  echo "  curl -i http://${target}:${port}/generate_204"
  echo
  echo "Ожидаемый ответ:"
  echo "  HTTP/1.0 204 No Content"
  echo
  if [[ -n "$external_ip" ]]; then
    echo "Определённый внешний IPv4 сервера: ${external_ip}"
  else
    warn "Внешний IPv4 автоматически определить не удалось. Замените SERVER_IP на публичный IP сервера."
  fi
  echo
  echo "Если снаружи не отвечает:"
  echo "  1. Откройте TCP-порт ${port} в ufw/firewall сервера."
  echo "  2. Проверьте firewall панели VPS/хостера или cloud security group."
  echo "  3. Проверьте NAT/port-forward, если сервер находится за роутером."
  echo "  4. Убедитесь, что сервис слушает порт: sudo ss -lntp | grep ${port}"
}

main() {
  require_root_or_sudo

  need_cmd python3
  need_cmd systemctl
  need_cmd grep
  need_cmd getent

  local original_user user_home default_port port external_ip
  original_user="$(detect_original_user)"
  user_home="$(get_user_home "$original_user")"
  default_port="$(get_current_port)"
  port="$(ask_port "$default_port")"

  info "Устанавливаю probe204 в ${INSTALL_DIR}"

  write_probe_py "$port"
  write_uninstall_sh
  write_service
  write_uninstall_instruction "$original_user" "$user_home"

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}" >/dev/null
  systemctl restart "${SERVICE_NAME}"

  maybe_open_ufw "$port"

  external_ip="$(detect_external_ip || true)"

  echo
  info "probe204 установлен"
  echo "Служба: ${SERVICE_NAME}"
  echo "Порт: ${port}/tcp"

  local_http_test "$port"
  print_external_check_instructions "$port" "$external_ip"

  echo
  echo "Удаление:"
  echo "  sudo ${UNINSTALL_FILE}"
  echo
  if [[ -n "${user_home}" ]]; then
    echo "Инструкция по удалению создана здесь:"
    echo "  ${user_home}/${UNINSTALL_INSTRUCTION_FILE}"
  fi
  echo
  echo -e "${RED}${BOLD}ВАЖНО: если нужен доступ извне, необходимо открыть TCP-порт ${port} в firewall сервера, панели хостера, cloud security group или на роутере/NAT.${NC}"
  echo
  systemctl --no-pager --full status "${SERVICE_NAME}" || true
}

main "$@"
