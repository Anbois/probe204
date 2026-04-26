#!/usr/bin/env bash
set -u

SERVICE_BASE="probe204"
SERVICE_NAME="probe204.service"
INSTALL_DIR="/opt/probe"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}"
PORT_DEFAULT="18080"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $*"; }
err()  { echo -e "${RED}[ОШИБКА]${NC} $*" >&2; }

require_root_or_sudo() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    err "Для удаления нужны права root, но sudo не найден."
    echo "Запустите от root:"
    echo "  su -"
    echo "  bash $0"
    exit 1
  fi

  warn "Для удаления нужны права root. Запрашиваю sudo..."
  exec sudo bash "$0" "$@"
}

stop_systemd_service() {
  if command -v systemctl >/dev/null 2>&1; then
    echo "Останавливаю службу ${SERVICE_NAME}, если она зарегистрирована..."

    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

    # На случай если systemd ещё держит состояние удалённого unit
    systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true
  else
    warn "systemctl не найден, пропускаю systemd-остановку."
  fi
}

kill_leftover_processes() {
  echo "Проверяю оставшиеся процессы probe204..."

  local pids=""
  pids="$(pgrep -f "/opt/probe/probe.py" 2>/dev/null || true)"

  if [ -n "$pids" ]; then
    warn "Найдены оставшиеся процессы probe204: $pids"
    kill $pids 2>/dev/null || true
    sleep 1

    local still=""
    still="$(pgrep -f "/opt/probe/probe.py" 2>/dev/null || true)"
    if [ -n "$still" ]; then
      warn "Некоторые процессы не завершились мягко, выполняю kill -9: $still"
      kill -9 $still 2>/dev/null || true
    fi
  else
    info "Оставшихся процессов probe204 не найдено"
  fi
}

kill_port_listener() {
  local port="$1"

  if ! command -v ss >/dev/null 2>&1; then
    return 0
  fi

  local pids=""
  pids="$(ss -lntp 2>/dev/null \
    | awk -v p=":${port}" '$4 ~ p {print $0}' \
    | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' \
    | sort -u)"

  if [ -n "$pids" ]; then
    warn "Порт ${port}/tcp всё ещё слушается процессами: $pids"
    warn "Останавливаю эти процессы..."
    kill $pids 2>/dev/null || true
    sleep 1

    local still=""
    still="$(ss -lntp 2>/dev/null \
      | awk -v p=":${port}" '$4 ~ p {print $0}' \
      | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' \
      | sort -u)"

    if [ -n "$still" ]; then
      warn "Процессы всё ещё слушают порт, выполняю kill -9: $still"
      kill -9 $still 2>/dev/null || true
    fi
  fi
}

remove_files() {
  echo "Удаляю файлы probe204..."

  rm -f "${UNIT_FILE}" 2>/dev/null || true
  rm -rf "${INSTALL_DIR}" 2>/dev/null || true

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true
  fi

  info "Файлы удалены"
}

final_check() {
  echo
  echo "Финальная проверка:"

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files "${SERVICE_NAME}" 2>/dev/null | grep -q "^${SERVICE_NAME}"; then
      warn "Unit ${SERVICE_NAME} всё ещё виден systemd."
    else
      info "Unit ${SERVICE_NAME} не зарегистрирован"
    fi
  fi

  if [ -d "${INSTALL_DIR}" ]; then
    warn "Каталог ${INSTALL_DIR} всё ещё существует"
  else
    info "Каталог ${INSTALL_DIR} отсутствует"
  fi

  if command -v ss >/dev/null 2>&1; then
    if ss -lntp 2>/dev/null | grep -q ":${PORT_DEFAULT} "; then
      warn "Порт ${PORT_DEFAULT}/tcp всё ещё слушается. Проверьте: sudo ss -lntp | grep ${PORT_DEFAULT}"
    else
      info "Порт ${PORT_DEFAULT}/tcp не слушается"
    fi
  fi

  echo
  info "Удаление probe204 завершено"
}

main() {
  require_root_or_sudo "$@"

  echo "${BOLD}Удаление probe204${NC}"
  echo

  stop_systemd_service
  kill_leftover_processes

  # Специально добиваем дефолтный порт: полезно после старого uninstall,
  # когда unit уже удалён, но python-процесс ещё жив.
  kill_port_listener "${PORT_DEFAULT}"

  remove_files
  final_check
}

main "$@"
