#!/usr/bin/env bash
set -u

# probe204 uninstall.sh
# VERSION: 2026-04-26-fixed-process-cleanup-v2

SERVICE_NAME="probe204.service"
SERVICE_SHORT="probe204"
INSTALL_DIR="/opt/probe"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}"
PROBE_SCRIPT="${INSTALL_DIR}/probe.py"
DEFAULT_PORT="18080"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $*"; }
err()  { echo -e "${RED}[ОШИБКА]${NC} $*" >&2; }

need_root_or_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
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
    echo "Останавливаю службу ${SERVICE_SHORT}, если она есть..."

    # Важно: даже если unit-файл уже удалён, systemd может ещё держать процесс в памяти.
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true
  else
    warn "systemctl не найден, пропускаю остановку через systemd."
  fi
}

kill_leftover_processes() {
  echo "Проверяю оставшиеся процессы probe204..."

  local pids
  pids="$(pgrep -f "/opt/probe/probe.py" 2>/dev/null || true)"

  if [[ -n "${pids}" ]]; then
    warn "Найдены оставшиеся процессы probe204: ${pids}"
    echo "${pids}" | xargs -r kill 2>/dev/null || true
    sleep 1

    pids="$(pgrep -f "/opt/probe/probe.py" 2>/dev/null || true)"
    if [[ -n "${pids}" ]]; then
      warn "Процессы не завершились штатно, выполняю kill -9: ${pids}"
      echo "${pids}" | xargs -r kill -9 2>/dev/null || true
    fi
  else
    info "Оставшихся процессов probe204 не найдено"
  fi
}

detect_port_from_probe() {
  if [[ -f "${PROBE_SCRIPT}" ]]; then
    local port
    port="$(grep -Eo 'HTTPServer\(\("0\.0\.0\.0", *[0-9]+' "${PROBE_SCRIPT}" 2>/dev/null | grep -Eo '[0-9]+$' | tail -n 1 || true)"
    if [[ -n "${port}" ]]; then
      echo "${port}"
      return 0
    fi
  fi

  echo "${DEFAULT_PORT}"
}

cleanup_files() {
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
  local port="$1"

  echo
  echo "Финальная проверка:"

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
      err "Служба ${SERVICE_NAME} всё ещё активна"
    else
      info "Служба ${SERVICE_NAME} не активна"
    fi
  fi

  if [[ -e "${UNIT_FILE}" ]]; then
    err "Unit-файл всё ещё существует: ${UNIT_FILE}"
  else
    info "Unit-файл удалён"
  fi

  if [[ -d "${INSTALL_DIR}" ]]; then
    err "Каталог всё ещё существует: ${INSTALL_DIR}"
  else
    info "Каталог ${INSTALL_DIR} удалён"
  fi

  if command -v ss >/dev/null 2>&1; then
    if ss -lntp 2>/dev/null | grep -q ":${port} "; then
      err "Порт ${port} всё ещё слушается:"
      ss -lntp 2>/dev/null | grep ":${port} " || true
    else
      info "Порт ${port} не слушается"
    fi
  else
    warn "Команда ss не найдена, проверка порта пропущена"
  fi
}

main() {
  need_root_or_sudo "$@"

  echo
  echo -e "${BOLD}Удаление probe204${NC}"
  echo "Версия uninstall: 2026-04-26-fixed-process-cleanup-v2"
  echo

  local port
  port="$(detect_port_from_probe)"

  stop_systemd_service
  kill_leftover_processes
  cleanup_files
  final_check "${port}"

  echo
  info "probe204 удалён"
}

main "$@"
