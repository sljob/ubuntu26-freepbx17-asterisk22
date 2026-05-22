#!/usr/bin/env bash
# =====================================================================
# Ubuntu 26.04 + PHP 8.3.31 (source) + Asterisk 22.9.0 + FreePBX 17
# G.729: bcg729 + arkadijs/asterisk-g72x
# Russian sounds - ОБЯЗАТЕЛЬНО
# Sysadmin + Firewall - ОБЯЗАТЕЛЬНО
#
# ИСПРАВЛЕННЫЙ ВАРИАНТ:
# - строго сначала локальные файлы из /root/offline-assets, потом интернет
# - framework переводится на signed online package
# - pm2 устанавливается и корректно регистрируется
# - incron поднимается
# - fwconsole restart в финале НЕ используется
# - chan_local принудительно включается
# - добавлен обязательный минимум модулей Asterisk для FreePBX
# - web admin FreePBX НЕ создается
# - Asterisk оформляется через нативный systemd unit
# - UCP Daemon поднимается через Node 18 + offline PM2 archive
#
# ИСПРАВЛЕНИЯ ОШИБОК:
# - исправлен mysql_root()
# - добавлен mysql_root_db_stdin()
# - добавлен /usr/bin/php для sysadmin_manager
# - в /etc/incron.allow добавлен root
# - добавлен reset firewall OOBE state
# - добавлен smoke-test firewall hook
# - добавлен offline runtime Node.js 18.20.8
# - добавлено offline восстановление PM2 из global archive
# - исправлен фикс UCP/PM2 через fwconsole pm2 --update
# =====================================================================

set -Eeuo pipefail

PHP_VER="${PHP_VER:-8.3.31}"
AST_VER="${AST_VER:-22.9.0}"
FREEPBX_TAG="${FREEPBX_TAG:-release/17.0}"

AST_USER="${AST_USER:-asterisk}"
AST_GROUP="${AST_GROUP:-asterisk}"

DB_ROOT_PASS="${DB_ROOT_PASS:-RootTempPass_2026!}"
DB_USER="${DB_USER:-freepbxuser}"
DB_ASTERISK="${DB_ASTERISK:-asterisk}"
DB_CDR="${DB_CDR:-asteriskcdrdb}"
DB_PASS_FILE="${DB_PASS_FILE:-/root/.freepbx_db_pass}"

SRC_DIR="${SRC_DIR:-/usr/src/ats-build}"
PHP_PREFIX="${PHP_PREFIX:-/usr/local/php83}"
PHP_BIN="${PHP_PREFIX}/bin/php"
PHP_CONFIG_BIN="${PHP_PREFIX}/bin/php-config"
PHP_FPM_BIN="${PHP_PREFIX}/sbin/php-fpm"
FPM_SOCK="${FPM_SOCK:-/run/php/php83-fpm.sock}"
FPM_PID="${FPM_PID:-/run/php/php83-fpm.pid}"
MYSQL_SOCK="${MYSQL_SOCK:-/run/mysqld/mysqld.sock}"

AST_MODULE_MODE="${AST_MODULE_MODE:-}"
AST_MODULE_FILE="${AST_MODULE_FILE:-/root/prod-modules.txt}"

INSTALL_RU_SOUNDS="${INSTALL_RU_SOUNDS:-yes}"
INSTALL_SYSADMIN_FIREWALL="${INSTALL_SYSADMIN_FIREWALL:-yes}"
ALLOW_ONLINE_SYSADMIN_FIREWALL="${ALLOW_ONLINE_SYSADMIN_FIREWALL:-no}"
INSTALL_IONCUBE="${INSTALL_IONCUBE:-yes}"

OFFLINE_ASSETS_DIR="${OFFLINE_ASSETS_DIR:-/root/offline-assets}"

NODE_VERSION_REQUIRED="${NODE_VERSION_REQUIRED:-18.20.8}"
NODE_TARBALL_NAME="${NODE_TARBALL_NAME:-node-v18.20.8-linux-x64.tar.xz}"
PM2_GLOBAL_ARCHIVE_NAME="${PM2_GLOBAL_ARCHIVE_NAME:-pm2-global-5.2.2-node18-linux-x64.tar.gz}"

LOG_FILE="${LOG_FILE:-/root/install-ats-$(date +%F-%H%M%S).log}"
CHECK_SCRIPT="${CHECK_SCRIPT:-/root/check-ats-ubuntu26-freepbx17.sh}"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-/root/ATS-CREDENTIALS.txt}"

RU_SOUNDS_ARCHIVE=""
SYSADMIN_HELPER_DEB=""
SYSADMIN_LIB_ARCHIVE=""
SYSADMIN_MODULE_DIR_ARCHIVE=""
FIREWALL_MODULE_DIR_ARCHIVE=""
IONCUBE_ARCHIVE=""
PHP_SOURCE_ARCHIVE=""
AST_SOURCE_ARCHIVE=""
BCG729_ARCHIVE=""
BCG729_DIR=""
ASTERISK_G72X_ARCHIVE=""
ASTERISK_G72X_DIR=""
FREEPBX_GPG_FILE=""
FREEPBX_SRC_DIR=""
NODE_OFFLINE_TARBALL=""
PM2_GLOBAL_ARCHIVE=""
DB_PASS=""

exec > >(tee -a "${LOG_FILE}") 2>&1

log()  { echo -e "\e[32m[$(date '+%F %T')]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }
die()  { echo -e "\e[31m[ERR ]\e[0m $*" >&2; exit 1; }

trap 'die "Ошибка на строке $LINENO. Команда: $BASH_COMMAND"' ERR

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Запускайте от root"
}

require_ubuntu_26() {
  [[ -f /etc/os-release ]] || die "Нет /etc/os-release"
  . /etc/os-release
  [[ "${ID}" = "ubuntu" ]] || die "Поддерживается только Ubuntu"
  [[ "${VERSION_ID}" = "26.04" ]] || die "Ожидалась Ubuntu 26.04, а не ${VERSION_ID}"
}

ensure_dir() {
  mkdir -p "$@"
}

pkg_exists() {
  apt-cache show "$1" >/dev/null 2>&1
}

apt_install_checked() {
  local ok=()
  local miss=()
  local p

  for p in "$@"; do
    if pkg_exists "${p}"; then
      ok+=("${p}")
    else
      miss+=("${p}")
    fi
  done

  if ((${#miss[@]} > 0)); then
    warn "Недоступные пакеты будут пропущены:"
    printf '  - %s\n' "${miss[@]}"
  fi

  if ((${#ok[@]} > 0)); then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${ok[@]}"
  fi
}

create_asterisk_user() {
  getent group "${AST_GROUP}" >/dev/null || groupadd -r "${AST_GROUP}"
  id "${AST_USER}" >/dev/null 2>&1 || useradd -r -g "${AST_GROUP}" -d /var/lib/asterisk -s /bin/bash "${AST_USER}"
}

create_db_pass() {
  if [[ -f "${DB_PASS_FILE}" ]]; then
    DB_PASS="$(cat "${DB_PASS_FILE}")"
  else
    DB_PASS="$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)"
    echo -n "${DB_PASS}" > "${DB_PASS_FILE}"
    chmod 600 "${DB_PASS_FILE}"
  fi
}

mysql_root_cmd() {
  if mysql -uroot -e "SELECT 1;" >/dev/null 2>&1; then
    echo "mysql -uroot"
    return 0
  fi
  if mysql -uroot -p"${DB_ROOT_PASS}" -e "SELECT 1;" >/dev/null 2>&1; then
    echo "mysql -uroot -p${DB_ROOT_PASS}"
    return 0
  fi
  return 1
}

mysql_root() {
  if mysql -uroot -e "SELECT 1;" >/dev/null 2>&1; then
    mysql -uroot "$@"
    return 0
  fi
  if mysql -uroot -p"${DB_ROOT_PASS}" -e "SELECT 1;" >/dev/null 2>&1; then
    mysql -uroot -p"${DB_ROOT_PASS}" "$@"
    return 0
  fi
  die "Не удалось войти в MariaDB как root"
}

mysql_root_db_stdin() {
  local db="$1"
  if mysql -uroot -e "SELECT 1;" >/dev/null 2>&1; then
    mysql -uroot "${db}"
    return 0
  fi
  if mysql -uroot -p"${DB_ROOT_PASS}" -e "SELECT 1;" >/dev/null 2>&1; then
    mysql -uroot -p"${DB_ROOT_PASS}" "${db}"
    return 0
  fi
  die "Не удалось войти в MariaDB как root для БД ${db}"
}

prefetch_file() {
  local url="$1"
  local dest="$2"
  local try

  if [[ -s "${dest}" ]]; then
    log "Уже есть: ${dest}"
    return 0
  fi

  for try in 1 2 3 4 5; do
    log "Скачивание (${try}/5): ${url}"
    if wget --tries=2 --timeout=60 -O "${dest}.part" "${url}"; then
      mv -f "${dest}.part" "${dest}"
      log "Скачано: ${dest}"
      return 0
    fi
    rm -f "${dest}.part"
    sleep 5
  done

  die "Не удалось скачать $(basename "${dest}")"
}

find_asset_by_pattern() {
  local pattern="$1"
  find "${OFFLINE_ASSETS_DIR}" -maxdepth 4 -type f 2>/dev/null | grep -Ei "${pattern}" | sort | head -1 || true
}

find_dir_by_pattern() {
  local pattern="$1"
  find "${OFFLINE_ASSETS_DIR}" -maxdepth 4 -type d 2>/dev/null | grep -Ei "${pattern}" | sort | head -1 || true
}

find_first_existing() {
  local f
  for f in "$@"; do
    [[ -f "${f}" ]] && { echo "${f}"; return 0; }
  done
  return 1
}

verify_tarball() {
  local archive="$1"
  [[ -s "${archive}" ]] || die "Архив пустой или отсутствует: ${archive}"

  case "${archive}" in
    *.tar.gz|*.tgz) tar -tzf "${archive}" >/dev/null 2>&1 || die "Архив поврежден: ${archive}" ;;
    *.tar.bz2|*.tbz2) tar -tjf "${archive}" >/dev/null 2>&1 || die "Архив поврежден: ${archive}" ;;
    *) die "Неподдерживаемый тип архива: ${archive}" ;;
  esac
}

verify_tarball_xz() {
  local archive="$1"
  [[ -s "${archive}" ]] || die "Архив пустой или отсутствует: ${archive}"
  case "${archive}" in
    *.tar.xz|*.txz) tar -tJf "${archive}" >/dev/null 2>&1 || die "Архив поврежден: ${archive}" ;;
    *) die "Неподдерживаемый тип xz-архива: ${archive}" ;;
  esac
}

extract_archive_to() {
  local archive="$1"
  local dest="$2"

  rm -rf "${dest}"
  mkdir -p "${dest}"

  case "${archive}" in
    *.tar.gz|*.tgz) tar -xzf "${archive}" -C "${dest}" ;;
    *.tar.bz2|*.tbz2) tar -xjf "${archive}" -C "${dest}" ;;
    *) die "Неподдерживаемый тип архива: ${archive}" ;;
  esac
}

copy_extracted_single_dir() {
  local archive="$1"
  local final_dir="$2"
  local tmp="/tmp/extract-copy.$$"
  local srcdir=""

  verify_tarball "${archive}"
  extract_archive_to "${archive}" "${tmp}"

  srcdir="$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -1 || true)"
  [[ -n "${srcdir}" ]] || die "После распаковки не найден каталог в ${archive}"

  rm -rf "${final_dir}"
  mkdir -p "$(dirname "${final_dir}")"
  cp -a "${srcdir}" "${final_dir}"
  rm -rf "${tmp}"
}

detect_offline_assets() {
  RU_SOUNDS_ARCHIVE="$(find_first_existing \
    "${OFFLINE_ASSETS_DIR}/asterisk-sounds-ru.tar.gz" \
    "${OFFLINE_ASSETS_DIR}/asterisk-core-sounds-ru-wav-current.tar.gz" \
    "/root/asterisk-sounds-ru.tar.gz" \
    "/tmp/asterisk-sounds-ru.tar.gz")" || true
  [[ -n "${RU_SOUNDS_ARCHIVE}" ]] || RU_SOUNDS_ARCHIVE="$(find_asset_by_pattern 'asterisk.*sounds.*ru.*\.(tar\.gz|tgz)$')"

  SYSADMIN_HELPER_DEB="$(find_first_existing \
    "${OFFLINE_ASSETS_DIR}/sysadmin17_8.2-8.2_sng12_all.deb" \
    "${OFFLINE_ASSETS_DIR}/sysadmin17_8.2-8.2_sng12_all.deb" \
    "/root/sysadmin17_8.2-8.2_sng12_all.deb" \
    "/tmp/sysadmin17_8.2-8.2_sng12_all.deb")" || true
  [[ -n "${SYSADMIN_HELPER_DEB}" ]] || SYSADMIN_HELPER_DEB="$(find_asset_by_pattern 'sysadmin17.*\.deb$')"

  SYSADMIN_LIB_ARCHIVE="$(find_first_existing \
    "${OFFLINE_ASSETS_DIR}/sysadmin-lib.tar.gz" \
    "/root/sysadmin-lib.tar.gz" \
    "/tmp/sysadmin-lib.tar.gz")" || true
  [[ -n "${SYSADMIN_LIB_ARCHIVE}" ]] || SYSADMIN_LIB_ARCHIVE="$(find_asset_by_pattern 'sysadmin-lib.*\.(tar\.gz|tgz)$')"

  SYSADMIN_MODULE_DIR_ARCHIVE="$(find_first_existing \
    "${OFFLINE_ASSETS_DIR}/freepbx-sysadmin-module-dir.tar.gz" \
    "/root/freepbx-sysadmin-module-dir.tar.gz" \
    "/tmp/freepbx-sysadmin-module-dir.tar.gz")" || true
  [[ -n "${SYSADMIN_MODULE_DIR_ARCHIVE}" ]] || SYSADMIN_MODULE_DIR_ARCHIVE="$(find_asset_by_pattern 'freepbx.*sysadmin.*module.*dir.*\.(tar\.gz|tgz)$')"

  FIREWALL_MODULE_DIR_ARCHIVE="$(find_first_existing \
    "${OFFLINE_ASSETS_DIR}/freepbx-firewall-module-dir.tar.gz" \
    "/root/freepbx-firewall-module-dir.tar.gz" \
    "/tmp/freepbx-firewall-module-dir.tar.gz")" || true
  [[ -n "${FIREWALL_MODULE_DIR_ARCHIVE}" ]] || FIREWALL_MODULE_DIR_ARCHIVE="$(find_asset_by_pattern 'freepbx.*firewall.*module.*dir.*\.(tar\.gz|tgz)$')"

  IONCUBE_ARCHIVE="$(find_first_existing \
    "${OFFLINE_ASSETS_DIR}/ioncube_loaders_lin_x86-64.tar.gz" \
    "/root/ioncube_loaders_lin_x86-64.tar.gz" \
    "/tmp/ioncube_loaders_lin_x86-64.tar.gz")" || true
  [[ -n "${IONCUBE_ARCHIVE}" ]] || IONCUBE_ARCHIVE="$(find_asset_by_pattern 'ioncube.*lin.*x86-64.*\.(tar\.gz|tgz)$')"

  PHP_SOURCE_ARCHIVE="$(find_first_existing \
    "${OFFLINE_ASSETS_DIR}/php-${PHP_VER}.tar.gz" \
    "/root/php-${PHP_VER}.tar.gz" \
    "/tmp/php-${PHP_VER}.tar.gz")" || true
  [[ -n "${PHP_SOURCE_ARCHIVE}" ]] || PHP_SOURCE_ARCHIVE="$(find_asset_by_pattern "php[-_].*${PHP_VER//./\\.}.*\.(tar\.gz|tgz)$")"

  AST_SOURCE_ARCHIVE="$(find_first_existing \
    "${OFFLINE_ASSETS_DIR}/asterisk-${AST_VER}.tar.gz" \
    "/root/asterisk-${AST_VER}.tar.gz" \
    "/tmp/asterisk-${AST_VER}.tar.gz")" || true
  [[ -n "${AST_SOURCE_ARCHIVE}" ]] || AST_SOURCE_ARCHIVE="$(find_asset_by_pattern "asterisk[-_].*${AST_VER//./\\.}.*\.(tar\.gz|tgz)$")"

  BCG729_ARCHIVE="$(find_asset_by_pattern '(^|/)(bcg729).*\.(tar\.gz|tgz|tar\.bz2|tbz2)$')"
  BCG729_DIR="$(find_dir_by_pattern '(^|/)(bcg729)$')"

  ASTERISK_G72X_ARCHIVE="$(find_asset_by_pattern 'asterisk-g72x.*\.(tar\.gz|tgz|tar\.bz2|tbz2)$')"
  ASTERISK_G72X_DIR="$(find_dir_by_pattern 'asterisk-g72x$')"

  FREEPBX_GPG_FILE="$(find_asset_by_pattern 'freepbx.*\.gpg$')"

  if [[ -d "${OFFLINE_ASSETS_DIR}/freepbx" ]]; then
    FREEPBX_SRC_DIR="${OFFLINE_ASSETS_DIR}/freepbx"
  else
    FREEPBX_SRC_DIR="$(find_dir_by_pattern '(^|/)(freepbx|framework)$')"
  fi

  NODE_OFFLINE_TARBALL="$(find_first_existing \
    "${OFFLINE_ASSETS_DIR}/${NODE_TARBALL_NAME}" \
    "/root/${NODE_TARBALL_NAME}" \
    "/tmp/${NODE_TARBALL_NAME}")" || true
  [[ -n "${NODE_OFFLINE_TARBALL}" ]] || NODE_OFFLINE_TARBALL="$(find_asset_by_pattern 'node-v18\.20\.8-linux-x64\.tar\.xz$')"

  PM2_GLOBAL_ARCHIVE="$(find_first_existing \
    "${OFFLINE_ASSETS_DIR}/${PM2_GLOBAL_ARCHIVE_NAME}" \
    "/root/${PM2_GLOBAL_ARCHIVE_NAME}" \
    "/tmp/${PM2_GLOBAL_ARCHIVE_NAME}")" || true
  [[ -n "${PM2_GLOBAL_ARCHIVE}" ]] || PM2_GLOBAL_ARCHIVE="$(find_asset_by_pattern 'pm2-global-5\.2\.2-node18-linux-x64\.tar\.gz$')"

  log "Offline assets:"
  echo "  RU_SOUNDS_ARCHIVE=${RU_SOUNDS_ARCHIVE:-NOT_FOUND}"
  echo "  SYSADMIN_HELPER_DEB=${SYSADMIN_HELPER_DEB:-NOT_FOUND}"
  echo "  SYSADMIN_LIB_ARCHIVE=${SYSADMIN_LIB_ARCHIVE:-NOT_FOUND}"
  echo "  SYSADMIN_MODULE_DIR_ARCHIVE=${SYSADMIN_MODULE_DIR_ARCHIVE:-NOT_FOUND}"
  echo "  FIREWALL_MODULE_DIR_ARCHIVE=${FIREWALL_MODULE_DIR_ARCHIVE:-NOT_FOUND}"
  echo "  IONCUBE_ARCHIVE=${IONCUBE_ARCHIVE:-NOT_FOUND}"
  echo "  PHP_SOURCE_ARCHIVE=${PHP_SOURCE_ARCHIVE:-NOT_FOUND}"
  echo "  AST_SOURCE_ARCHIVE=${AST_SOURCE_ARCHIVE:-NOT_FOUND}"
  echo "  BCG729_ARCHIVE=${BCG729_ARCHIVE:-NOT_FOUND}"
  echo "  BCG729_DIR=${BCG729_DIR:-NOT_FOUND}"
  echo "  ASTERISK_G72X_ARCHIVE=${ASTERISK_G72X_ARCHIVE:-NOT_FOUND}"
  echo "  ASTERISK_G72X_DIR=${ASTERISK_G72X_DIR:-NOT_FOUND}"
  echo "  FREEPBX_SRC_DIR=${FREEPBX_SRC_DIR:-NOT_FOUND}"
  echo "  FREEPBX_GPG_FILE=${FREEPBX_GPG_FILE:-NOT_FOUND}"
  echo "  NODE_OFFLINE_TARBALL=${NODE_OFFLINE_TARBALL:-NOT_FOUND}"
  echo "  PM2_GLOBAL_ARCHIVE=${PM2_GLOBAL_ARCHIVE:-NOT_FOUND}"
}

check_required_offline_assets_for_sysadmin_firewall() {
  local missing=0
  [[ -n "${SYSADMIN_HELPER_DEB:-}" ]] || { echo "  MISSING: sysadmin helper deb"; missing=1; }
  [[ -n "${SYSADMIN_LIB_ARCHIVE:-}" ]] || { echo "  MISSING: sysadmin-lib.tar.gz"; missing=1; }
  [[ -n "${SYSADMIN_MODULE_DIR_ARCHIVE:-}" ]] || { echo "  MISSING: freepbx-sysadmin-module-dir.tar.gz"; missing=1; }
  [[ -n "${FIREWALL_MODULE_DIR_ARCHIVE:-}" ]] || { echo "  MISSING: freepbx-firewall-module-dir.tar.gz"; missing=1; }
  return "${missing}"
}

prepare_sangoma_dirs() {
  log "Подготовка /etc/sangoma"
  mkdir -p /etc/sangoma /etc/sangoma/ssl /etc/sangoma/pbx /var/lib/sangoma /var/spool/sangoma
  chown -R root:root /etc/sangoma
  chmod 755 /etc/sangoma /etc/sangoma/ssl /etc/sangoma/pbx
  touch /etc/sangoma/.keep
}

ensure_asterisk_dirs() {
  mkdir -p /run/asterisk /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk
  chown -R "${AST_USER}:${AST_GROUP}" /run/asterisk /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk
}

write_native_asterisk_systemd_unit() {
  log "Создание нативного systemd unit для Asterisk"

  cat > /etc/systemd/system/asterisk.service <<EOF
[Unit]
Description=Asterisk PBX
After=network.target mariadb.service
Wants=network.target

[Service]
Type=simple
User=${AST_USER}
Group=${AST_GROUP}
Environment=HOME=/var/lib/asterisk
RuntimeDirectory=asterisk
RuntimeDirectoryMode=0755
ExecStart=/usr/sbin/asterisk -f -U ${AST_USER} -G ${AST_GROUP}
ExecReload=/usr/sbin/asterisk -rx 'core reload'
ExecStop=/usr/sbin/asterisk -rx 'core stop now'
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable asterisk >/dev/null 2>&1 || true
}

ensure_asterisk_running() {
  if asterisk -rx 'core show version' >/dev/null 2>&1; then
    log "Asterisk CLI уже доступен"
    return 0
  fi

  warn "Asterisk CLI недоступен, запускаю Asterisk"

  ensure_asterisk_dirs

  if [[ -f /etc/systemd/system/asterisk.service ]]; then
    systemctl daemon-reload
    systemctl restart asterisk || true
  fi

  for i in {1..40}; do
    if asterisk -rx 'core show version' >/dev/null 2>&1; then
      log "Asterisk успешно запущен"
      return 0
    fi
    sleep 1
  done

  tail -n 100 /var/log/asterisk/full 2>/dev/null || true
  journalctl -u asterisk -n 100 --no-pager 2>/dev/null || true
  die "Asterisk не удалось запустить или CLI недоступен"
}

module_to_menuselect_name() {
  local mod="$1"
  mod="$(printf '%s' "${mod}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  mod="${mod%.so}"
  echo "${mod}"
}

is_blank_line() {
  local s="$1"
  s="$(printf '%s' "${s}" | sed 's/[[:space:]]//g')"
  [[ -z "${s}" ]]
}

is_comment_line() {
  local s="$1"
  s="$(printf '%s' "${s}" | sed 's/^[[:space:]]*//')"
  [[ "${s:0:1}" = "#" ]]
}

select_asterisk_module_mode() {
  if [[ -n "${AST_MODULE_MODE}" ]]; then
    case "${AST_MODULE_MODE}" in
      preset|file|menu)
        log "AST_MODULE_MODE задан извне: ${AST_MODULE_MODE}"
        return 0
        ;;
      *)
        die "Неверный AST_MODULE_MODE='${AST_MODULE_MODE}'. Допустимо: preset | file | menu"
        ;;
    esac
  fi

  echo
  echo "=============================================================="
  echo "Выберите режим выбора модулей Asterisk"
  echo "=============================================================="
  echo "  1) preset - стандартный преднастроенный набор"
  echo "  2) file   - из файла ${AST_MODULE_FILE}"
  echo "  3) menu   - вручную через menuselect"
  echo "=============================================================="

  local answer=""
  while true; do
    read -r -p "Ваш выбор [1-3]: " answer
    case "${answer}" in
      1) AST_MODULE_MODE="preset"; break ;;
      2) AST_MODULE_MODE="file"; break ;;
      3) AST_MODULE_MODE="menu"; break ;;
      *) echo "Неверный выбор. Введите 1, 2 или 3." ;;
    esac
  done

  log "Выбран режим модулей Asterisk: ${AST_MODULE_MODE}"
}

force_required_asterisk_modules() {
  local opts_file="$1"

  local required=(
    chan_local
    chan_pjsip
    res_pjsip
    res_pjsip_authenticator_digest
    res_pjsip_endpoint_identifier_ip
    res_pjsip_endpoint_identifier_user
    res_pjsip_outbound_authenticator_digest
    res_pjsip_registrar
    res_pjsip_session
    res_pjsip_transport_websocket
    res_rtp_asterisk
    res_sorcery
    res_sorcery_astdb
    res_sorcery_config
    res_sorcery_memory
    res_odbc
    cdr_adaptive_odbc
    codec_ulaw
    codec_alaw
    format_wav
    format_wav_gsm
    format_gsm
    app_dial
    app_playback
    app_stack
    app_voicemail
    func_db
    func_strings
    func_channel
    pbx_config
  )

  local m
  for m in "${required[@]}"; do
    menuselect/menuselect --enable "${m}" "${opts_file}" >/dev/null 2>&1 || true
  done

  for m in chan_console chan_mobile cdr_pgsql cel_pgsql cdr_csv cdr_sqlite3_custom cel_sqlite3_custom; do
    menuselect/menuselect --disable "${m}" "${opts_file}" >/dev/null 2>&1 || true
  done
}

apply_asterisk_module_selection() {
  local src_dir="$1"
  local total=0
  local enabled=0
  local warned=0
  local rawmod=""
  local mod=""

  cd "${src_dir}"
  make menuselect.makeopts

  case "${AST_MODULE_MODE}" in
    preset)
      log "Режим модулей Asterisk: preset"
      ;;
    file)
      log "Режим модулей Asterisk: file (${AST_MODULE_FILE})"
      [[ -f "${AST_MODULE_FILE}" ]] || die "Файл модулей не найден: ${AST_MODULE_FILE}"

      while IFS= read -r rawmod || [[ -n "${rawmod}" ]]; do
        if is_blank_line "${rawmod}"; then
          continue
        fi
        if is_comment_line "${rawmod}"; then
          continue
        fi

        mod="$(module_to_menuselect_name "${rawmod}")"
        [[ -n "${mod}" ]] || continue

        total=$((total + 1))

        if menuselect/menuselect --enable "${mod}" menuselect.makeopts >/dev/null 2>&1; then
          log "Включён модуль: ${mod}"
          enabled=$((enabled + 1))
        else
          warn "Модуль ${mod} недоступен для включения в Asterisk ${AST_VER}, пропускаю"
          warned=$((warned + 1))
        fi
      done < "${AST_MODULE_FILE}"

      log "Итог выбора модулей из файла: всего=${total}, включено=${enabled}, предупреждений=${warned}"
      ;;
    menu)
      log "Режим модулей Asterisk: menu"
      echo
      echo "=============================================================="
      echo "Сейчас откроется интерактивный menuselect."
      echo "Выберите нужные модули вручную, сохраните изменения и выйдите."
      echo "После выхода сборка продолжится."
      echo "=============================================================="
      sleep 2
      make menuselect
      ;;
    *)
      die "Неизвестный AST_MODULE_MODE='${AST_MODULE_MODE}'"
      ;;
  esac

  force_required_asterisk_modules "menuselect.makeopts"

  for opt in codec_opus codec_opus_open_source; do
    menuselect/menuselect --disable "${opt}" menuselect.makeopts >/dev/null 2>&1 || true
  done

  for snd in \
    CORE-SOUNDS-EN-WAV CORE-SOUNDS-EN-ULAW CORE-SOUNDS-EN-ALAW CORE-SOUNDS-EN-G722 \
    CORE-SOUNDS-RU-WAV CORE-SOUNDS-RU-ULAW CORE-SOUNDS-RU-ALAW CORE-SOUNDS-RU-GSM \
    EXTRA-SOUNDS-EN-WAV EXTRA-SOUNDS-EN-ULAW EXTRA-SOUNDS-EN-ALAW \
    MOH-OPSOUND-WAV MOH-OPSOUND-ULAW MOH-OPSOUND-ALAW MOH-OPSOUND-GSM; do
    menuselect/menuselect --disable "${snd}" menuselect.makeopts >/dev/null 2>&1 || true
  done
}

extract_module_dir_from_archive() {
  local archive="$1"
  local module_name="$2"
  local tmpbase="$3"
  local found=""

  rm -rf "${tmpbase}"
  mkdir -p "${tmpbase}"
  extract_archive_to "${archive}" "${tmpbase}"

  found="$(
    find "${tmpbase}" -maxdepth 12 -type f -name module.xml 2>/dev/null \
      | while read -r f; do
          d="$(dirname "${f}")"
          if [[ "$(basename "${d}")" = "${module_name}" ]]; then
            echo "${d}"
          fi
        done | head -1
  )"

  [[ -n "${found}" ]] || return 1
  [[ -f "${found}/module.xml" ]] || return 1

  echo "${found}"
  return 0
}

install_sysadmin_firewall_offline() {
  log "Установка Sysadmin/Firewall из локальных файлов"

  check_required_offline_assets_for_sysadmin_firewall || die "Неполный offline-комплект для sysadmin/firewall"

  prepare_sangoma_dirs
  ensure_asterisk_running

  apt-get install -y "${SYSADMIN_HELPER_DEB}" || die "Не удалось установить ${SYSADMIN_HELPER_DEB}"

  mkdir -p /usr/lib/sysadmin
  verify_tarball "${SYSADMIN_LIB_ARCHIVE}"
  tar -xzf "${SYSADMIN_LIB_ARCHIVE}" -C /usr/lib
  [[ -f /usr/lib/sysadmin/includes.php ]] || die "После распаковки sysadmin-lib отсутствует /usr/lib/sysadmin/includes.php"

  local tmpmod="/tmp/freepbx-local-mods.$$"
  local sysadmin_dir=""
  local firewall_dir=""
  rm -rf "${tmpmod}"
  mkdir -p "${tmpmod}"

  verify_tarball "${SYSADMIN_MODULE_DIR_ARCHIVE}"
  verify_tarball "${FIREWALL_MODULE_DIR_ARCHIVE}"

  sysadmin_dir="$(extract_module_dir_from_archive "${SYSADMIN_MODULE_DIR_ARCHIVE}" "sysadmin" "${tmpmod}/sysadmin")" \
    || die "Не удалось найти корректную директорию sysadmin"
  firewall_dir="$(extract_module_dir_from_archive "${FIREWALL_MODULE_DIR_ARCHIVE}" "firewall" "${tmpmod}/firewall")" \
    || die "Не удалось найти корректную директорию firewall"

  rm -rf /var/www/html/admin/modules/sysadmin /var/www/html/admin/modules/firewall
  cp -a "${sysadmin_dir}" /var/www/html/admin/modules/
  chown -R "${AST_USER}:${AST_GROUP}" /var/www/html/admin/modules/sysadmin

  fwconsole chown || true
  fwconsole ma install sysadmin || true
  fwconsole ma enable sysadmin || true

  fwconsole ma list | grep -E '^\| sysadmin[[:space:]]+\|' | grep -q 'Enabled' || die "sysadmin не стал Enabled"

  cp -a "${firewall_dir}" /var/www/html/admin/modules/
  chown -R "${AST_USER}:${AST_GROUP}" /var/www/html/admin/modules/firewall

  fwconsole chown || true
  fwconsole ma install firewall || true
  fwconsole ma enable firewall || true

  ensure_asterisk_running
  fwconsole reload || fwconsole reload --dont-reload-asterisk || true
  fwconsole chown || true

  fwconsole ma list | grep -E '^\| sysadmin[[:space:]]+\|' | grep -q 'Enabled' || die "sysadmin не стал Enabled"
  fwconsole ma list | grep -E '^\| firewall[[:space:]]+\|' | grep -q 'Enabled' || die "firewall не стал Enabled"

  rm -rf "${tmpmod}"
}

install_sysadmin_firewall_online() {
  log "Пробуем сетевую установку Sysadmin/Firewall"

  prepare_sangoma_dirs
  ensure_asterisk_running

  fwconsole ma refreshsignatures || true
  fwconsole ma updateall || true

  fwconsole ma downloadinstall sysadmin || true
  fwconsole ma install sysadmin || true
  fwconsole ma enable sysadmin || true

  fwconsole ma downloadinstall firewall || true
  fwconsole ma install firewall || true
  fwconsole ma enable firewall || true

  ensure_asterisk_running
  fwconsole reload || fwconsole reload --dont-reload-asterisk || true
  fwconsole chown || true

  fwconsole ma list | grep -E '^\| sysadmin[[:space:]]+\|' | grep -q 'Enabled' || die "sysadmin не стал Enabled (online fallback)"
  fwconsole ma list | grep -E '^\| firewall[[:space:]]+\|' | grep -q 'Enabled' || die "firewall не стал Enabled (online fallback)"
}

fix_freepbx_framework_signed() {
  log "Фикс framework: перевод на официальный signed package"

  ensure_asterisk_running
  command -v fwconsole >/dev/null 2>&1 || die "fwconsole не найден"

  local before_line=""
  local after_line=""
  local tries=0

  before_line="$(fwconsole ma list 2>/dev/null | grep -E '^\| framework[[:space:]]+\|' || true)"
  echo "  framework before: ${before_line:-NOT_FOUND}"

  fwconsole ma refreshsignatures || true

  if echo "${before_line}" | grep -q 'Sangoma'; then
    log "Framework уже отмечен как Sangoma"
  else
    fwconsole ma downloadinstall framework || die "Не удалось скачать/установить framework из online-репозитория"
  fi

  fwconsole ma refreshsignatures || true
  ensure_asterisk_running
  fwconsole reload || fwconsole reload --dont-reload-asterisk || true
  fwconsole chown || true

  for tries in 1 2 3; do
    after_line="$(fwconsole ma list 2>/dev/null | grep -E '^\| framework[[:space:]]+\|' || true)"
    echo "  framework check ${tries}: ${after_line:-NOT_FOUND}"
    if echo "${after_line}" | grep -q 'Sangoma' && echo "${after_line}" | grep -q 'Enabled'; then
      log "Framework успешно переведен на signed online package"
      return 0
    fi
    sleep 2
    fwconsole ma refreshsignatures || true
  done

  die "Framework после фикса не стал Signed/Enabled"
}

install_russian_sounds() {
  local archive=""
  local tmpdir="/tmp/ru-sounds.$$"
  local count=""
  local test_file=""

  if [[ -n "${RU_SOUNDS_ARCHIVE:-}" ]]; then
    archive="${RU_SOUNDS_ARCHIVE}"
    log "Установка русских sounds из локального архива: ${archive}"
  else
    archive="/tmp/asterisk-core-sounds-ru-wav-current.tar.gz"
    log "Локальный архив русских sounds не найден, пробуем скачать upstream"
    prefetch_file \
      "https://downloads.asterisk.org/pub/telephony/sounds/asterisk-core-sounds-ru-wav-current.tar.gz" \
      "${archive}"
  fi

  verify_tarball "${archive}"

  rm -rf "${tmpdir}"
  mkdir -p "${tmpdir}" /var/lib/asterisk/sounds/ru

  extract_archive_to "${archive}" "${tmpdir}"

  find "${tmpdir}" -type f \( -name '*.wav' -o -name '*.gsm' -o -name '*.ulaw' -o -name '*.alaw' -o -name '*.g722' \) \
    -exec cp -af {} /var/lib/asterisk/sounds/ru/ \;

  chown -R "${AST_USER}:${AST_GROUP}" /var/lib/asterisk/sounds

  count="$(find /var/lib/asterisk/sounds/ru -type f | wc -l)"
  [[ "${count}" -gt 0 ]] || die "Русские sounds не установились"

  test_file="$(find /var/lib/asterisk/sounds/ru -type f \( -name '*.wav' -o -name '*.gsm' -o -name '*.ulaw' -o -name '*.alaw' -o -name '*.g722' \) | sort | head -1 || true)"
  [[ -n "${test_file}" ]] || die "После установки русских sounds не найдено ни одного audio-файла"

  rm -f /tmp/ru-test.ulaw /tmp/ru-sound-test.log
  asterisk -rx "file convert ${test_file} /tmp/ru-test.ulaw" >/tmp/ru-sound-test.log 2>&1 || true

  if [[ -f /tmp/ru-test.ulaw ]]; then
    log "Asterisk подтвердил чтение ru sounds: ${test_file}"
  else
    warn "Convert-тест не подтвердился для ${test_file}"
    cat /tmp/ru-sound-test.log || true
  fi

  rm -rf "${tmpdir}"
}

install_ioncube() {
  [[ "${INSTALL_IONCUBE}" = "yes" ]] || return 0

  local archive=""
  local tmpdir="/tmp/ioncube.$$"
  local ext_dir=""
  local loader=""

  if [[ -n "${IONCUBE_ARCHIVE:-}" ]]; then
    archive="${IONCUBE_ARCHIVE}"
  else
    archive="/tmp/ioncube_loaders_lin_x86-64.tar.gz"
    prefetch_file \
      "https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz" \
      "${archive}"
  fi

  verify_tarball "${archive}"

  rm -rf "${tmpdir}"
  mkdir -p "${tmpdir}"
  extract_archive_to "${archive}" "${tmpdir}"

  ext_dir="$("${PHP_CONFIG_BIN}" --extension-dir)"
  [[ -n "${ext_dir}" ]] || die "Не удалось определить extension_dir PHP"

  loader="$(find "${tmpdir}" -type f -name 'ioncube_loader_lin_8.3.so' | head -1 || true)"
  [[ -n "${loader}" ]] || die "Не найден ioncube_loader_lin_8.3.so"

  cp -f "${loader}" "${ext_dir}/ioncube_loader_lin_8.3.so"

  if ! grep -q 'ioncube_loader_lin_8.3.so' "${PHP_PREFIX}/etc/php.ini"; then
    sed -i "1izend_extension=${ext_dir}/ioncube_loader_lin_8.3.so" "${PHP_PREFIX}/etc/php.ini"
  fi

  systemctl restart php83-fpm
  "${PHP_BIN}" -v | grep -qi ionCube || die "ionCube не загрузился"

  rm -rf "${tmpdir}"
}

ensure_php_shebang_compat() {
  log "Обеспечение совместимости /usr/bin/php для sysadmin hooks"

  [[ -x "${PHP_BIN}" ]] || die "Нет ${PHP_BIN}"

  ln -sf "${PHP_BIN}" /usr/local/bin/php
  ln -sf "${PHP_BIN}" /usr/bin/php

  [[ -x /usr/bin/php ]] || die "/usr/bin/php не создан"
  /usr/bin/php -v >/dev/null 2>&1 || die "/usr/bin/php не запускается"
}

setup_nodejs_runtime() {
  log "Настройка Node.js ${NODE_VERSION_REQUIRED} runtime"

  local want_major="18"
  local current_major=""
  local online_url="https://nodejs.org/dist/v18.20.8/${NODE_TARBALL_NAME}"
  local online_tmp="/tmp/${NODE_TARBALL_NAME}"

  if command -v node >/dev/null 2>&1; then
    current_major="$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1 || true)"
    if [[ "${current_major}" = "${want_major}" ]]; then
      log "Node.js уже подходящей major-версии: $(node -v)"
      command -v npm >/dev/null 2>&1 || die "npm не найден при наличии node"
      return 0
    fi
    warn "Обнаружен неподходящий Node.js: $(node -v 2>/dev/null || true). Требуется major ${want_major}"
  fi

  if [[ -n "${NODE_OFFLINE_TARBALL:-}" && -f "${NODE_OFFLINE_TARBALL}" ]]; then
    log "Использую локальный Node.js tarball: ${NODE_OFFLINE_TARBALL}"
  else
    log "Локальный Node.js tarball не найден, пробую скачать: ${online_url}"
    prefetch_file "${online_url}" "${online_tmp}"
    NODE_OFFLINE_TARBALL="${online_tmp}"
  fi

  [[ -f "${NODE_OFFLINE_TARBALL}" ]] || die "Node.js tarball не найден"
  verify_tarball_xz "${NODE_OFFLINE_TARBALL}"

  mkdir -p /usr/local/lib/nodejs
  rm -rf "/usr/local/lib/nodejs/node-v${NODE_VERSION_REQUIRED}-linux-x64"
  tar -xJf "${NODE_OFFLINE_TARBALL}" -C /usr/local/lib/nodejs

  chown -R root:root "/usr/local/lib/nodejs/node-v${NODE_VERSION_REQUIRED}-linux-x64" || true
  chmod 755 "/usr/local/lib/nodejs/node-v${NODE_VERSION_REQUIRED}-linux-x64/bin/node" || true
  chmod 755 "/usr/local/lib/nodejs/node-v${NODE_VERSION_REQUIRED}-linux-x64/bin/npm" || true
  chmod 755 "/usr/local/lib/nodejs/node-v${NODE_VERSION_REQUIRED}-linux-x64/bin/npx" || true

  ln -sf "/usr/local/lib/nodejs/node-v${NODE_VERSION_REQUIRED}-linux-x64/bin/node" /usr/bin/node
  ln -sf "/usr/local/lib/nodejs/node-v${NODE_VERSION_REQUIRED}-linux-x64/bin/npm" /usr/bin/npm
  ln -sf "/usr/local/lib/nodejs/node-v${NODE_VERSION_REQUIRED}-linux-x64/bin/npx" /usr/bin/npx

  hash -r

  command -v node >/dev/null 2>&1 || die "node не найден после установки"
  command -v npm >/dev/null 2>&1 || die "npm не найден после установки"
  [[ "$(node -v | cut -d. -f1 | tr -d v)" = "${want_major}" ]] || die "После установки версия node не 18: $(node -v)"

  log "Node.js установлен: $(node -v), npm: $(npm -v)"
}

restore_pm2_from_offline_archive() {
  log "Восстановление PM2 из офлайн-архива"

  [[ -n "${PM2_GLOBAL_ARCHIVE:-}" && -f "${PM2_GLOBAL_ARCHIVE}" ]] || die "Не найден офлайн-архив PM2: ${PM2_GLOBAL_ARCHIVE_NAME}"
  verify_tarball "${PM2_GLOBAL_ARCHIVE}"

  if command -v pm2 >/dev/null 2>&1; then
    pm2 kill >/dev/null 2>&1 || true
  fi

  sudo -u "${AST_USER}" env HOME=/var/lib/asterisk PM2_HOME=/var/lib/asterisk/.pm2 \
    /usr/bin/pm2 kill >/dev/null 2>&1 || true

  rm -f /usr/bin/pm2 /usr/bin/pm2-runtime /usr/bin/pm2-docker /usr/bin/pm2-dev
  rm -rf /usr/lib/node_modules/pm2

  tar -C /usr -xzf "${PM2_GLOBAL_ARCHIVE}"

  [[ -x /usr/bin/pm2 ]] || die "/usr/bin/pm2 не появился после восстановления PM2"
  /usr/bin/pm2 -v >/dev/null 2>&1 || die "PM2 не запускается после восстановления"

  mkdir -p /var/lib/asterisk/.pm2 /var/lib/asterisk/.pm2/logs /var/lib/asterisk/.pm2/pids
  chown -R "${AST_USER}:${AST_GROUP}" /var/lib/asterisk/.pm2

  rm -f /var/lib/asterisk/.pm2/pm2.pid \
        /var/lib/asterisk/.pm2/rpc.sock \
        /var/lib/asterisk/.pm2/pub.sock || true
  rm -rf /var/lib/asterisk/.pm2/logs/* || true
  rm -rf /var/lib/asterisk/.pm2/pids/* || true

  log "PM2 восстановлен: $(/usr/bin/pm2 -v)"
}

setup_pm2() {
  log "Настройка pm2"

  setup_nodejs_runtime

  command -v node >/dev/null 2>&1 || die "node не найден"
  command -v npm >/dev/null 2>&1 || die "npm не найден"

  if [[ -n "${PM2_GLOBAL_ARCHIVE:-}" && -f "${PM2_GLOBAL_ARCHIVE}" ]]; then
    restore_pm2_from_offline_archive
  else
    warn "Офлайн-архив PM2 не найден, пробую online fallback через npm"
    if ! command -v pm2 >/dev/null 2>&1; then
      npm install -g pm2 || true
    fi
  fi

  local pm2bin=""
  pm2bin="$(command -v pm2 || true)"

  if [[ -z "${pm2bin}" && -x /usr/lib/node_modules/pm2/bin/pm2 ]]; then
    pm2bin="/usr/lib/node_modules/pm2/bin/pm2"
  fi

  [[ -n "${pm2bin}" ]] || die "pm2 не найден после установки"

  ln -sfn ../lib/node_modules/pm2/bin/pm2 /usr/bin/pm2 2>/dev/null || ln -sf "${pm2bin}" /usr/bin/pm2
  chmod 755 "${pm2bin}" || true
  [[ -x /usr/bin/pm2 ]] || die "/usr/bin/pm2 не исполняемый"

  /usr/bin/pm2 -v >/dev/null 2>&1 || die "pm2 не запускается через /usr/bin/pm2"

  fwconsole ma install pm2 || true
  fwconsole ma enable pm2 || true
  fwconsole reload || fwconsole reload --dont-reload-asterisk || true
  fwconsole chown || true
}

setup_incron() {
  log "Настройка incron"

  apt-get install -y incron || die "Не удалось установить incron"

  touch /etc/incron.allow
  grep -qx "${AST_USER}" /etc/incron.allow 2>/dev/null || echo "${AST_USER}" >> /etc/incron.allow
  grep -qx "root" /etc/incron.allow 2>/dev/null || echo "root" >> /etc/incron.allow

  mkdir -p /var/spool/asterisk/incron
  chown -R "${AST_USER}:${AST_GROUP}" /var/spool/asterisk/incron
  chmod 775 /var/spool/asterisk/incron

  systemctl enable incron || true
  systemctl restart incron || true
  sleep 3
  systemctl is-active --quiet incron || die "incron не активен"
}

fix_firewall_oobe_state() {
  log "Сброс stale-state firewall OOBE/wizard"

  [[ -f /etc/freepbx.conf ]] || {
    warn "FreePBX ещё не установлен, пропускаю firewall OOBE reset"
    return 0
  }

  local has_fw_kv="0"
  local has_sa_kv="0"
  local has_admin="0"

  has_fw_kv="$(mysql_root -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_ASTERISK}' AND table_name='kvstore_FreePBX_modules_Firewall';" 2>/dev/null || echo 0)"
  has_sa_kv="$(mysql_root -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_ASTERISK}' AND table_name='kvstore_FreePBX_modules_Sysadmin';" 2>/dev/null || echo 0)"
  has_admin="$(mysql_root -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_ASTERISK}' AND table_name='admin';" 2>/dev/null || echo 0)"

  if [[ "${has_fw_kv}" = "1" ]]; then
    mysql_root "${DB_ASTERISK}" -e "DELETE FROM kvstore_FreePBX_modules_Firewall WHERE \`key\` LIKE 'oobe%' OR \`key\` LIKE 'first%' OR \`key\` LIKE 'wizard%';" || true
  else
    warn "Таблица kvstore_FreePBX_modules_Firewall отсутствует, пропускаю"
  fi

  if [[ "${has_sa_kv}" = "1" ]]; then
    mysql_root "${DB_ASTERISK}" -e "DELETE FROM kvstore_FreePBX_modules_Sysadmin WHERE \`key\` LIKE 'firewall%oobe%' OR \`key\` LIKE 'firewall%wizard%';" || true
  else
    warn "Таблица kvstore_FreePBX_modules_Sysadmin отсутствует, пропускаю"
  fi

  if [[ "${has_admin}" = "1" ]]; then
    mysql_root "${DB_ASTERISK}" -e "DELETE FROM admin WHERE variable LIKE 'firewall_oobe%' OR variable LIKE 'firewall_first%' OR variable LIKE 'firewall_wizard%';" || true
  else
    warn "Таблица admin отсутствует, пропускаю"
  fi

  rm -rf /var/www/html/admin/modules/_cache/*firewall* 2>/dev/null || true
  rm -rf /var/www/html/admin/modules/_cache/*sysadmin* 2>/dev/null || true
  rm -rf /tmp/*firewall* 2>/dev/null || true
}

smoketest_sysadmin_firewall_hook() {
  log "Smoke-test sysadmin/firewall hook"

  [[ -x /usr/bin/php ]] || die "/usr/bin/php отсутствует"
  [[ -x /usr/bin/sysadmin_manager ]] || die "/usr/bin/sysadmin_manager отсутствует"

  /usr/bin/php -v >/dev/null 2>&1 || die "/usr/bin/php не запускается"

  mkdir -p /var/spool/asterisk/incron
  chown -R "${AST_USER}:${AST_GROUP}" /var/spool/asterisk/incron
  chmod 775 /var/spool/asterisk/incron

  rm -f /var/spool/asterisk/incron/firewall.firewall
  touch /var/spool/asterisk/incron/firewall.firewall
  chown "${AST_USER}:${AST_GROUP}" /var/spool/asterisk/incron/firewall.firewall

  /usr/bin/php /usr/bin/sysadmin_manager firewall.firewall >/tmp/sysadmin-firewall-hook-test.log 2>&1 || {
    cat /tmp/sysadmin-firewall-hook-test.log || true
    die "sysadmin_manager firewall.firewall завершился ошибкой"
  }

  sleep 2

  if [[ -e /var/spool/asterisk/incron/firewall.firewall ]]; then
    cat /tmp/sysadmin-firewall-hook-test.log || true
    die "Smoke-test firewall hook не прошёл: файл firewall.firewall не удалён"
  fi

  log "Smoke-test firewall hook успешно пройден"
}

write_check_script() {
  cat > "${CHECK_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -u

PHP_BIN="/usr/local/php83/bin/php"
RESULTS=()

ok()   { RESULTS+=("OK|$1|$2"); }
warn() { RESULTS+=("WARN|$1|$2"); }
fail() { RESULTS+=("FAIL|$1|$2"); }

check_service() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

check_php_module() {
  "${PHP_BIN}" -m 2>/dev/null | grep -qi "^$1$"
}

check_freepbx_module_enabled() {
  local m="$1"
  fwconsole ma list 2>/dev/null | grep -E "^\| ${m}[[:space:]]+\|" | grep -q "Enabled"
}

check_freepbx_module_signed_sangoma() {
  local m="$1"
  fwconsole ma list 2>/dev/null | grep -E "^\| ${m}[[:space:]]+\|" | grep -q "Sangoma"
}

check_asterisk_cli() {
  asterisk -rx 'core show version' >/dev/null 2>&1
}

check_asterisk_service() {
  systemctl is-active --quiet asterisk 2>/dev/null
}

check_g729() {
  asterisk -rx 'module show like g729' 2>/dev/null | grep -Eq 'codec_g729(\.a)?\.so'
}

check_ru_sounds() {
  [[ -d /var/lib/asterisk/sounds/ru ]] && find /var/lib/asterisk/sounds/ru -type f 2>/dev/null | grep -q .
}

check_ru_sounds_asterisk_read() {
  local test_file
  test_file="$(find /var/lib/asterisk/sounds/ru -type f \( -name '*.wav' -o -name '*.gsm' -o -name '*.ulaw' -o -name '*.alaw' -o -name '*.g722' \) | sort | head -1 || true)"
  [[ -n "${test_file}" ]] || return 1

  rm -f /tmp/ru-check.ulaw
  asterisk -rx "file convert ${test_file} /tmp/ru-check.ulaw" >/tmp/ru-check.log 2>&1 || true
  [[ -f /tmp/ru-check.ulaw ]]
}

check_http_freepbx() {
  curl -fsI http://127.0.0.1/admin/ 2>/dev/null | grep -Eq 'HTTP/.* (200|301|302)'
}

check_ucp_pm2() {
  fwconsole pm2 --list 2>/dev/null | grep -qE '(^|\|)[[:space:]]*ucp[[:space:]]*\|'
}

check_ucp_ports() {
  ss -ltn 2>/dev/null | grep -Eq ':(8001|8003)[[:space:]]'
}

if [[ -f /etc/os-release ]] && grep -q 'VERSION_ID="26.04"' /etc/os-release; then
  ok "Ubuntu 26.04" "обнаружена"
else
  fail "Ubuntu 26.04" "не соответствует"
fi

if [[ -x "${PHP_BIN}" ]]; then
  ok "PHP 8.3 binary" "$("${PHP_BIN}" -v 2>/dev/null | head -1)"
else
  fail "PHP 8.3 binary" "не найден ${PHP_BIN}"
fi

if [[ -x /usr/bin/php ]]; then
  ok "/usr/bin/php" "$(/usr/bin/php -v 2>/dev/null | head -1)"
else
  fail "/usr/bin/php" "не найден"
fi

check_service php83-fpm && ok "PHP-FPM service" "active" || fail "PHP-FPM service" "inactive"

for mod in mysqli pdo_mysql mbstring intl xml curl openssl zip gd sodium gettext soap exif bcmath sockets; do
  if check_php_module "${mod}"; then
    ok "PHP module ${mod}" "есть"
  else
    fail "PHP module ${mod}" "нет"
  fi
done

if "${PHP_BIN}" -v 2>/dev/null | grep -qi ionCube; then
  ok "ionCube" "загружен"
else
  warn "ionCube" "не загружен"
fi

check_service mariadb && ok "MariaDB service" "active" || fail "MariaDB service" "inactive"
check_service apache2 && ok "Apache service" "active" || fail "Apache service" "inactive"
check_service incron && ok "Incron service" "active" || fail "Incron service" "inactive"

check_http_freepbx && ok "FreePBX HTTP" "http://127.0.0.1/admin/ отвечает" || fail "FreePBX HTTP" "нет ответа /admin/"

command -v asterisk >/dev/null 2>&1 && ok "Asterisk binary" "$(asterisk -V 2>/dev/null)" || fail "Asterisk binary" "не найден"
check_asterisk_cli && ok "Asterisk CLI" "доступен" || fail "Asterisk CLI" "не отвечает"
check_asterisk_service && ok "Asterisk service" "active" || warn "Asterisk service" "не active"
check_g729 && ok "G.729" "codec_g729/codec_g729a загружен" || fail "G.729" "codec_g729/codec_g729a не загружен"

ldconfig -p 2>/dev/null | grep -q libbcg729 && ok "bcg729 library" "найдена" || fail "bcg729 library" "не найдена"

if check_ru_sounds; then
  ok "Russian sounds files" "обнаружены"
else
  fail "Russian sounds files" "не обнаружены"
fi

if check_ru_sounds && check_ru_sounds_asterisk_read; then
  ok "Russian sounds Asterisk test" "Asterisk читает ru sounds"
else
  warn "Russian sounds Asterisk test" "файлы есть, но convert-тест не подтвержден"
fi

if check_freepbx_module_enabled framework; then
  if check_freepbx_module_signed_sangoma framework; then
    ok "FreePBX framework" "Enabled + Sangoma signed"
  else
    fail "FreePBX framework" "Enabled, но не Sangoma signed"
  fi
else
  fail "FreePBX framework" "не Enabled"
fi

check_freepbx_module_enabled core && ok "FreePBX core" "Enabled" || fail "FreePBX core" "не Enabled"
check_freepbx_module_enabled firewall && ok "FreePBX firewall" "Enabled" || fail "FreePBX firewall" "не Enabled"
check_freepbx_module_enabled sysadmin && ok "FreePBX sysadmin" "Enabled" || fail "FreePBX sysadmin" "не Enabled"
check_freepbx_module_enabled pm2 && ok "FreePBX pm2" "Enabled" || fail "FreePBX pm2" "не Enabled"

check_ucp_pm2 && ok "UCP PM2 process" "зарегистрирован" || fail "UCP PM2 process" "не найден"
check_ucp_ports && ok "UCP ports 8001/8003" "слушаются" || fail "UCP ports 8001/8003" "не слушаются"

[[ -f /usr/lib/sysadmin/includes.php ]] && ok "sysadmin lib" "найден" || fail "sysadmin lib" "не найден"
[[ -d /etc/sangoma ]] && ok "/etc/sangoma" "есть" || fail "/etc/sangoma" "нет"
[[ -x /usr/bin/pm2 ]] && ok "/usr/bin/pm2" "есть" || fail "/usr/bin/pm2" "нет"
[[ -x /usr/bin/sysadmin_manager ]] && ok "/usr/bin/sysadmin_manager" "есть" || fail "/usr/bin/sysadmin_manager" "нет"

rm -f /var/spool/asterisk/incron/firewall.firewall
touch /var/spool/asterisk/incron/firewall.firewall
chown asterisk:asterisk /var/spool/asterisk/incron/firewall.firewall 2>/dev/null || true
sleep 3

if [[ ! -e /var/spool/asterisk/incron/firewall.firewall ]]; then
  ok "Firewall incron hook" "firewall.firewall удаляется"
else
  fail "Firewall incron hook" "firewall.firewall не удалён"
fi

printf '\n'
printf '============================================================================================\n'
printf '%-6s | %-32s | %s\n' "STATE" "CHECK" "DETAILS"
printf '%-6s-+-%-32s-+-%s\n' "------" "--------------------------------" "----------------------------------------------"

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

for row in "${RESULTS[@]}"; do
  state="${row%%|*}"
  rest="${row#*|}"
  check="${rest%%|*}"
  detail="${rest#*|}"

  printf '%-6s | %-32s | %s\n' "${state}" "${check}" "${detail}"

  case "${state}" in
    OK) ((OK_COUNT++)) ;;
    WARN) ((WARN_COUNT++)) ;;
    FAIL) ((FAIL_COUNT++)) ;;
  esac
done

printf '============================================================================================\n'
printf 'ИТОГО: OK=%d  WARN=%d  FAIL=%d\n' "${OK_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}"
printf '============================================================================================\n'

(( FAIL_COUNT == 0 ))
EOF

  chmod +x "${CHECK_SCRIPT}"
}

write_credentials_file() {
  local host_ip=""
  local host_name=""
  local db_conf_user=""
  local db_conf_pass=""
  local db_conf_name=""
  local db_conf_host=""
  local db_conf_cdr=""
  local latest_log=""

  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  host_name="$(hostname -f 2>/dev/null || hostname)"

  db_conf_user="$(grep -E "AMPDBUSER" /etc/freepbx.conf 2>/dev/null | head -1 | sed -E "s/.*=>[[:space:]]*'([^']+)'.*/\1/" || true)"
  db_conf_pass="$(grep -E "AMPDBPASS" /etc/freepbx.conf 2>/dev/null | head -1 | sed -E "s/.*=>[[:space:]]*'([^']+)'.*/\1/" || true)"
  db_conf_name="$(grep -E "AMPDBNAME" /etc/freepbx.conf 2>/dev/null | head -1 | sed -E "s/.*=>[[:space:]]*'([^']+)'.*/\1/" || true)"
  db_conf_host="$(grep -E "AMPDBHOST" /etc/freepbx.conf 2>/dev/null | head -1 | sed -E "s/.*=>[[:space:]]*'([^']+)'.*/\1/" || true)"
  db_conf_cdr="$(grep -E "CDRDBNAME" /etc/freepbx.conf 2>/dev/null | head -1 | sed -E "s/.*=>[[:space:]]*'([^']+)'.*/\1/" || true)"

  [[ -n "${db_conf_user}" ]] || db_conf_user="${DB_USER}"
  [[ -n "${db_conf_pass}" ]] || db_conf_pass="${DB_PASS}"
  [[ -n "${db_conf_name}" ]] || db_conf_name="${DB_ASTERISK}"
  [[ -n "${db_conf_host}" ]] || db_conf_host="127.0.0.1"
  [[ -n "${db_conf_cdr}" ]] || db_conf_cdr="${DB_CDR}"

  latest_log="$(ls -1t /root/install-ats-*.log 2>/dev/null | head -1 || true)"

  cat > "${CREDENTIALS_FILE}" <<EOF
======================================================================
ATS CREDENTIALS
======================================================================

Host:
  Hostname: ${host_name}
  IP:       ${host_ip}

Web:
  FreePBX URL: http://${host_ip}/admin/

IMPORTANT:
  FreePBX WEB administrator is NOT created by this script.
  The first WEB user/admin must be created manually at first login
  through the browser.

MariaDB:
  Root user: root
  Root pass: ${DB_ROOT_PASS}

FreePBX / Asterisk database:
  DB host:   ${db_conf_host}
  DB name:   ${db_conf_name}
  CDR DB:    ${db_conf_cdr}
  DB user:   ${db_conf_user}
  DB pass:   ${db_conf_pass}

Linux service accounts:
  Asterisk user:  ${AST_USER}
  Asterisk group: ${AST_GROUP}
  Note: this is a service account, interactive password is not set.

Paths:
  Log file:         ${latest_log}
  Check script:     ${CHECK_SCRIPT}
  DB password file: ${DB_PASS_FILE}

Installed stack:
  Ubuntu:    26.04
  PHP:       $(${PHP_BIN} -v 2>/dev/null | head -1)
  Asterisk:  $(asterisk -V 2>/dev/null || echo "UNKNOWN")
  FreePBX:   ${FREEPBX_TAG}
======================================================================
EOF

  chmod 600 "${CREDENTIALS_FILE}"
}

print_final_credentials() {
  local host_ip=""
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

  echo
  echo "==================== SERVICE ACCOUNTS / PASSWORDS ===================="
  echo "FreePBX URL:        http://${host_ip}/admin/"
  echo
  echo "MariaDB root:"
  echo "  user:             root"
  echo "  pass:             ${DB_ROOT_PASS}"
  echo
  echo "FreePBX DB:"
  echo "  host:             127.0.0.1"
  echo "  name:             ${DB_ASTERISK}"
  echo "  cdr db:           ${DB_CDR}"
  echo "  user:             ${DB_USER}"
  echo "  pass:             ${DB_PASS}"
  echo
  echo "Linux service account:"
  echo "  user:             ${AST_USER}"
  echo "  group:            ${AST_GROUP}"
  echo "  password:         NOT SET (service account)"
  echo
  echo "FreePBX WEB admin:"
  echo "  NOT CREATED by script"
  echo "  create manually on first WEB login"
  echo
  echo "Credentials file:   ${CREDENTIALS_FILE}"
  echo "======================================================================"
}

install_pm2_asterisk_systemd() {
  log "Установка systemd unit для PM2 пользователя ${AST_USER}"

  cat > /etc/systemd/system/pm2-asterisk.service <<'EOF'
[Unit]
Description=PM2 resurrect service for asterisk
After=network.target mariadb.service asterisk.service
Wants=network.target mariadb.service asterisk.service

[Service]
Type=oneshot
User=asterisk
Group=asterisk
Environment=HOME=/var/lib/asterisk
Environment=PM2_HOME=/var/lib/asterisk/.pm2
ExecStart=/usr/bin/pm2 resurrect
ExecReload=/usr/bin/pm2 reload all
ExecStop=/usr/bin/pm2 kill
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable pm2-asterisk >/dev/null 2>&1 || true
}

fix_freepbx_ucp_pm2() {
  log "Фикс автозапуска UCP через PM2"

  mkdir -p /var/lib/asterisk/.pm2 /var/lib/asterisk/.pm2/logs /var/lib/asterisk/.pm2/pids
  chown -R "${AST_USER}:${AST_GROUP}" /var/lib/asterisk/.pm2

  if [[ -d /var/www/html/admin/modules/ucp/node ]]; then
    chown -R "${AST_USER}:${AST_GROUP}" /var/www/html/admin/modules/ucp/node
  else
    warn "Каталог UCP node не найден: /var/www/html/admin/modules/ucp/node"
  fi

  if command -v pm2 >/dev/null 2>&1; then
    pm2 kill >/dev/null 2>&1 || true
  fi

  sudo -u "${AST_USER}" env HOME=/var/lib/asterisk PM2_HOME=/var/lib/asterisk/.pm2 \
    /usr/bin/pm2 kill >/dev/null 2>&1 || true

  rm -f /var/lib/asterisk/.pm2/pm2.pid \
        /var/lib/asterisk/.pm2/rpc.sock \
        /var/lib/asterisk/.pm2/pub.sock || true
  rm -rf /var/lib/asterisk/.pm2/logs/* || true
  rm -rf /var/lib/asterisk/.pm2/pids/* || true

  fwconsole pm2 --update || true
  sleep 5

  if ! sudo -u "${AST_USER}" env HOME=/var/lib/asterisk PM2_HOME=/var/lib/asterisk/.pm2 \
      /usr/bin/pm2 list 2>/dev/null | grep -q 'ucp'; then
    if [[ -d /var/www/html/admin/modules/ucp/node ]]; then
      sudo -u "${AST_USER}" env HOME=/var/lib/asterisk PM2_HOME=/var/lib/asterisk/.pm2 \
        /usr/bin/pm2 start /var/www/html/admin/modules/ucp/node/index.js --name ucp || true
      sudo -u "${AST_USER}" env HOME=/var/lib/asterisk PM2_HOME=/var/lib/asterisk/.pm2 \
        /usr/bin/pm2 save || true
    fi
  fi

  systemctl reset-failed pm2-asterisk >/dev/null 2>&1 || true
  systemctl restart pm2-asterisk || true

  fwconsole reload || fwconsole reload --dont-reload-asterisk || true
  fwconsole chown || true

  if sudo -u "${AST_USER}" env HOME=/var/lib/asterisk PM2_HOME=/var/lib/asterisk/.pm2 \
      /usr/bin/pm2 list 2>/dev/null | grep -q 'ucp'; then
    log "UCP PM2 процесс зарегистрирован"
  else
    warn "UCP PM2 процесс не найден в pm2 list"
  fi
}

require_root
require_ubuntu_26
create_db_pass
select_asterisk_module_mode
detect_offline_assets

ensure_dir "${SRC_DIR}" /run/php /var/www/html /var/log "${OFFLINE_ASSETS_DIR}"

log "Лог установки: ${LOG_FILE}"

log "1/13 Базовые пакеты"

export DEBIAN_FRONTEND=noninteractive
echo "postfix postfix/mailname string $(hostname -s).local" | debconf-set-selections || true
echo "postfix postfix/main_mailer_type string 'Local only'" | debconf-set-selections || true

apt-get update

apt_install_checked \
  build-essential cmake autoconf automake libtool pkg-config \
  git wget curl subversion unzip rsync re2c bison flex patch \
  sox ffmpeg lame mpg123 \
  uuid-dev libjansson-dev libxml2-dev libsqlite3-dev libssl-dev \
  libncurses-dev libnewt-dev libedit-dev libreadline-dev \
  libsrtp2-dev libspandsp-dev libcurl4-openssl-dev \
  libspeex-dev libspeexdsp-dev libogg-dev libvorbis-dev \
  libasound2-dev portaudio19-dev libpq-dev libresample1-dev \
  libgmime-3.0-dev libunbound-dev \
  libmariadb-dev libmariadb-dev-compat \
  libzip-dev libbz2-dev libsodium-dev libargon2-dev libonig-dev \
  libpng-dev libjpeg-dev libfreetype6-dev libicu-dev libwebp-dev libxpm-dev \
  libldap2-dev libldap-dev libxslt1-dev libffi-dev libsasl2-dev \
  libkrb5-dev libc-client2007e-dev \
  gettext libsystemd-dev zlib1g-dev libcrypt-dev \
  cron mariadb-server mariadb-client mariadb-common \
  apache2 apache2-utils libapache2-mod-fcgid \
  ca-certificates gnupg lsb-release \
  redis-server sudo net-tools \
  fail2ban ipset iptables \
  sqlite3 unixodbc odbc-mariadb \
  tcpdump sngrep nmap avahi-daemon avahi-utils mailutils postfix \
  incron tftpd-hpa xinetd sysstat at

systemctl enable mariadb apache2 cron redis-server postfix
systemctl restart mariadb
systemctl restart apache2
systemctl restart cron
systemctl restart redis-server
systemctl restart postfix || true

log "2/13 Node.js 18 + pm2 runtime"

setup_nodejs_runtime

command -v node >/dev/null 2>&1 || die "node не найден после установки"
command -v npm >/dev/null 2>&1 || die "npm не найден после установки nodejs"

log "3/13 MariaDB: root + базы"

if mysql -uroot -e "SELECT VERSION();" >/dev/null 2>&1; then
  mysql -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
FLUSH PRIVILEGES;
SQL
fi

mysql_root -e "SELECT VERSION();" >/dev/null

mysql_root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_ASTERISK}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS \`${DB_CDR}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_ASTERISK}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_CDR}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_ASTERISK}\`.* TO '${DB_USER}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`${DB_CDR}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

log "4/13 Пользователь asterisk и каталоги"

create_asterisk_user
ensure_dir /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk /run/asterisk /etc/asterisk /tftpboot
chown -R "${AST_USER}:${AST_GROUP}" /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk /run/asterisk /etc/asterisk /tftpboot

sed -i 's|^TFTP_DIRECTORY=.*|TFTP_DIRECTORY="/tftpboot"|' /etc/default/tftpd-hpa || true
systemctl enable tftpd-hpa || true
systemctl restart tftpd-hpa || true

log "5/13 PHP ${PHP_VER} из исходников"

export PKG_CONFIG_PATH="/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CPPFLAGS="-I/usr/include/x86_64-linux-gnu ${CPPFLAGS:-}"
export LDFLAGS="-L/usr/lib/x86_64-linux-gnu ${LDFLAGS:-}"
export CFLAGS="${CFLAGS:-} -Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types"

if [[ ! -x "${PHP_BIN}" ]]; then
  cd "${SRC_DIR}"

  if [[ -n "${PHP_SOURCE_ARCHIVE:-}" ]]; then
    log "Использую локальный PHP archive: ${PHP_SOURCE_ARCHIVE}"
    cp -f "${PHP_SOURCE_ARCHIVE}" "${SRC_DIR}/php-${PHP_VER}.tar.gz"
  else
    prefetch_file "https://www.php.net/distributions/php-${PHP_VER}.tar.gz" "${SRC_DIR}/php-${PHP_VER}.tar.gz"
  fi

  verify_tarball "${SRC_DIR}/php-${PHP_VER}.tar.gz"

  rm -rf "${SRC_DIR}/php-${PHP_VER}"
  copy_extracted_single_dir "${SRC_DIR}/php-${PHP_VER}.tar.gz" "${SRC_DIR}/php-${PHP_VER}"

  cd "${SRC_DIR}/php-${PHP_VER}"

  PHP_CFG=(
    "--prefix=${PHP_PREFIX}"
    "--with-config-file-path=${PHP_PREFIX}/etc"
    "--with-config-file-scan-dir=${PHP_PREFIX}/etc/conf.d"
    "--enable-fpm"
    "--with-fpm-user=${AST_USER}"
    "--with-fpm-group=${AST_GROUP}"
    "--enable-mbstring"
    "--enable-bcmath"
    "--enable-sockets"
    "--enable-intl"
    "--enable-exif"
    "--enable-gd"
    "--enable-pcntl"
    "--enable-soap"
    "--enable-calendar"
    "--enable-shmop"
    "--enable-sysvmsg"
    "--enable-sysvsem"
    "--enable-sysvshm"
    "--with-curl"
    "--with-openssl"
    "--with-zlib"
    "--with-bz2"
    "--with-zip"
    "--with-mysqli=mysqlnd"
    "--with-pdo-mysql=mysqlnd"
    "--with-mysql-sock=${MYSQL_SOCK}"
    "--with-readline"
    "--with-mhash"
    "--with-iconv"
    "--with-jpeg"
    "--with-webp"
    "--with-freetype"
    "--with-xpm"
    "--with-xsl"
    "--with-ldap"
    "--with-sodium"
    "--with-password-argon2"
    "--with-kerberos"
    "--with-gettext"
    "--with-pear"
    "--enable-opcache"
  )

  if pkg-config --exists libsystemd; then
    PHP_CFG+=("--with-fpm-systemd")
  fi
  if pkg-config --exists libsasl2; then
    PHP_CFG+=("--with-ldap-sasl")
  fi
  if [[ -f /usr/include/c-client/c-client.h || -f /usr/include/c-client.h ]]; then
    PHP_CFG+=("--with-imap" "--with-imap-ssl")
  fi

  ./configure "${PHP_CFG[@]}" || die "PHP: configure упал"
  make -j"$(nproc)" || die "PHP: make упал"
  make install || die "PHP: make install упал"

  ensure_dir "${PHP_PREFIX}/etc" "${PHP_PREFIX}/etc/conf.d" "${PHP_PREFIX}/etc/php-fpm.d"

  cp php.ini-production "${PHP_PREFIX}/etc/php.ini"
  sed -i 's|^;date.timezone =.*|date.timezone = Europe/Moscow|' "${PHP_PREFIX}/etc/php.ini"
  sed -i 's|^upload_max_filesize = .*|upload_max_filesize = 120M|' "${PHP_PREFIX}/etc/php.ini"
  sed -i 's|^post_max_size = .*|post_max_size = 120M|' "${PHP_PREFIX}/etc/php.ini"
  sed -i 's|^memory_limit = .*|memory_limit = 512M|' "${PHP_PREFIX}/etc/php.ini"
  sed -i 's|^max_execution_time = .*|max_execution_time = 300|' "${PHP_PREFIX}/etc/php.ini"
  grep -q '^max_input_vars' "${PHP_PREFIX}/etc/php.ini" && sed -i 's|^max_input_vars = .*|max_input_vars = 2000|' "${PHP_PREFIX}/etc/php.ini" || echo 'max_input_vars = 2000' >> "${PHP_PREFIX}/etc/php.ini"

  cp sapi/fpm/php-fpm.conf "${PHP_PREFIX}/etc/php-fpm.conf"
  cp sapi/fpm/www.conf "${PHP_PREFIX}/etc/php-fpm.d/www.conf"

  grep -q '^include=' "${PHP_PREFIX}/etc/php-fpm.conf" || echo "include=${PHP_PREFIX}/etc/php-fpm.d/*.conf" >> "${PHP_PREFIX}/etc/php-fpm.conf"

  sed -i "s|^;*pid = .*|pid = ${FPM_PID}|" "${PHP_PREFIX}/etc/php-fpm.conf"
  sed -i "s|^;*error_log = .*|error_log = /var/log/php83-fpm.log|" "${PHP_PREFIX}/etc/php-fpm.conf"
  sed -i "s|^;*daemonize = .*|daemonize = no|" "${PHP_PREFIX}/etc/php-fpm.conf"

  sed -i "s|^user = .*|user = ${AST_USER}|" "${PHP_PREFIX}/etc/php-fpm.d/www.conf"
  sed -i "s|^group = .*|group = ${AST_GROUP}|" "${PHP_PREFIX}/etc/php-fpm.d/www.conf"
  sed -i "s|^listen = .*|listen = ${FPM_SOCK}|" "${PHP_PREFIX}/etc/php-fpm.d/www.conf"
  sed -i "s|^;listen.owner = .*|listen.owner = ${AST_USER}|" "${PHP_PREFIX}/etc/php-fpm.d/www.conf"
  sed -i "s|^;listen.group = .*|listen.group = ${AST_GROUP}|" "${PHP_PREFIX}/etc/php-fpm.d/www.conf"
  sed -i 's|^;listen.mode = .*|listen.mode = 0660|' "${PHP_PREFIX}/etc/php-fpm.d/www.conf"

  ln -sf "${PHP_BIN}" /usr/local/bin/php
fi

[[ -x "${PHP_BIN}" ]] || die "Нет ${PHP_BIN}"
[[ -x "${PHP_FPM_BIN}" ]] || die "Нет ${PHP_FPM_BIN}"
[[ -x "${PHP_CONFIG_BIN}" ]] || die "Нет ${PHP_CONFIG_BIN}"

ensure_php_shebang_compat

cat > "${PHP_PREFIX}/etc/conf.d/mysql-socket.ini" <<EOF
pdo_mysql.default_socket=${MYSQL_SOCK}
mysqli.default_socket=${MYSQL_SOCK}
EOF

log "6/13 Systemd unit для PHP-FPM"

touch /var/log/php83-fpm.log
chown "${AST_USER}:${AST_GROUP}" /var/log/php83-fpm.log

if ldd "${PHP_FPM_BIN}" 2>/dev/null | grep -qi systemd; then
  FPM_TYPE="notify"
else
  FPM_TYPE="simple"
fi

cat > /etc/systemd/system/php83-fpm.service <<EOF
[Unit]
Description=PHP 8.3 FPM
After=network.target

[Service]
Type=${FPM_TYPE}
PIDFile=${FPM_PID}
RuntimeDirectory=php
RuntimeDirectoryMode=0755
ExecStart=${PHP_FPM_BIN} --nodaemonize --fpm-config ${PHP_PREFIX}/etc/php-fpm.conf
ExecReload=/bin/kill -USR2 \$MAINPID
PrivateTmp=true
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable php83-fpm
systemctl restart php83-fpm
systemctl is-active --quiet php83-fpm || die "php83-fpm не стартует"

install_ioncube
ensure_php_shebang_compat

log "7/13 bcg729"

cd "${SRC_DIR}"
if [[ ! -f /usr/lib/libbcg729.so && ! -f /usr/lib/x86_64-linux-gnu/libbcg729.so ]]; then
  rm -rf "${SRC_DIR}/bcg729" "${SRC_DIR}/bcg729-build" "${SRC_DIR}/bcg729-build-static"

  if [[ -n "${BCG729_DIR:-}" && -d "${BCG729_DIR}" ]]; then
    log "Использую локальный каталог bcg729: ${BCG729_DIR}"
    cp -a "${BCG729_DIR}" "${SRC_DIR}/bcg729"
  elif [[ -n "${BCG729_ARCHIVE:-}" ]]; then
    log "Использую локальный архив bcg729: ${BCG729_ARCHIVE}"
    copy_extracted_single_dir "${BCG729_ARCHIVE}" "${SRC_DIR}/bcg729"
  else
    git clone --depth=1 https://github.com/BelledonneCommunications/bcg729.git "${SRC_DIR}/bcg729"
  fi

  mkdir "${SRC_DIR}/bcg729-build"
  cd "${SRC_DIR}/bcg729-build"
  cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON "${SRC_DIR}/bcg729"
  make -j"$(nproc)"
  make install

  mkdir "${SRC_DIR}/bcg729-build-static"
  cd "${SRC_DIR}/bcg729-build-static"
  cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF "${SRC_DIR}/bcg729"
  make -j"$(nproc)"
  make install
fi
ldconfig

if [[ ! -f /usr/lib/pkgconfig/libbcg729.pc && ! -f /usr/lib/x86_64-linux-gnu/pkgconfig/libbcg729.pc ]]; then
  ensure_dir /usr/lib/pkgconfig
  cat > /usr/lib/pkgconfig/libbcg729.pc <<'EOF'
prefix=/usr
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include
Name: libbcg729
Description: G729 codec library
Version: 1.1.1
Libs: -L${libdir} -lbcg729
Cflags: -I${includedir}
EOF
fi

log "8/13 Asterisk ${AST_VER}"

cd "${SRC_DIR}"
AST_TARBALL="asterisk-${AST_VER}.tar.gz"

if [[ -n "${AST_SOURCE_ARCHIVE:-}" ]]; then
  log "Использую локальный Asterisk archive: ${AST_SOURCE_ARCHIVE}"
  cp -f "${AST_SOURCE_ARCHIVE}" "/tmp/${AST_TARBALL}"
else
  prefetch_file "https://downloads.asterisk.org/pub/telephony/asterisk/${AST_TARBALL}" "/tmp/${AST_TARBALL}"
fi

verify_tarball "/tmp/${AST_TARBALL}"

if [[ ! -x /usr/sbin/asterisk ]]; then
  rm -rf "${SRC_DIR}/asterisk-${AST_VER}"
  copy_extracted_single_dir "/tmp/${AST_TARBALL}" "${SRC_DIR}/asterisk-${AST_VER}"
  cd "${SRC_DIR}/asterisk-${AST_VER}"

  contrib/scripts/get_mp3_source.sh || true
  ./configure --with-jansson-bundled --with-pjproject-bundled || die "Asterisk: configure упал"
  apply_asterisk_module_selection "$(pwd)"

  make -j"$(nproc)" || die "Asterisk: make упал"
  make install || die "Asterisk: make install упал"
  make install-headers || die "Asterisk: make install-headers упал"
  make samples || die "Asterisk: make samples упал"
  make config || die "Asterisk: make config упал"
  ldconfig
fi

[[ -x /usr/sbin/asterisk ]] || die "Asterisk binary не установлен"

sed -i "s/^;*runuser = .*/runuser = ${AST_USER}/" /etc/asterisk/asterisk.conf || true
sed -i "s/^;*rungroup = .*/rungroup = ${AST_GROUP}/" /etc/asterisk/asterisk.conf || true

write_native_asterisk_systemd_unit

log "9/13 G.729"

cd "${SRC_DIR}"
if [[ ! -f /usr/lib/asterisk/modules/codec_g729.so && ! -f /usr/lib/asterisk/modules/codec_g729a.so ]]; then
  rm -rf "${SRC_DIR}/asterisk-g72x"

  if [[ -n "${ASTERISK_G72X_DIR:-}" && -d "${ASTERISK_G72X_DIR}" ]]; then
    log "Использую локальный каталог asterisk-g72x: ${ASTERISK_G72X_DIR}"
    cp -a "${ASTERISK_G72X_DIR}" "${SRC_DIR}/asterisk-g72x"
  elif [[ -n "${ASTERISK_G72X_ARCHIVE:-}" ]]; then
    log "Использую локальный архив asterisk-g72x: ${ASTERISK_G72X_ARCHIVE}"
    copy_extracted_single_dir "${ASTERISK_G72X_ARCHIVE}" "${SRC_DIR}/asterisk-g72x"
  else
    git clone --depth=1 https://github.com/arkadijs/asterisk-g72x.git "${SRC_DIR}/asterisk-g72x"
  fi

  cd "${SRC_DIR}/asterisk-g72x"
  ./autogen.sh
  PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig" \
  ./configure --with-bcg729 CFLAGS="-O2"
  make
  make install
  ldconfig
fi

[[ -f /usr/lib/asterisk/modules/codec_g729.so || -f /usr/lib/asterisk/modules/codec_g729a.so ]] || die "codec_g729.so / codec_g729a.so не появился"

log "10/13 Старт Asterisk"
ensure_asterisk_running
systemctl is-active --quiet asterisk || warn "systemd unit asterisk пока не active, но CLI уже доступен"

log "11/13 Русские sounds"

if [[ "${INSTALL_RU_SOUNDS}" = "yes" ]]; then
  install_russian_sounds
else
  die "Русские sounds отключены, а по ТЗ они обязательны"
fi

log "12/13 Apache + FreePBX"

sed -i "s|^export APACHE_RUN_USER=.*|export APACHE_RUN_USER=${AST_USER}|" /etc/apache2/envvars
sed -i "s|^export APACHE_RUN_GROUP=.*|export APACHE_RUN_GROUP=${AST_GROUP}|" /etc/apache2/envvars

chown -R "${AST_USER}:${AST_GROUP}" /var/log/apache2 /var/lib/apache2 2>/dev/null || true
usermod -aG "${AST_GROUP}" www-data 2>/dev/null || true

a2enmod proxy proxy_fcgi setenvif rewrite headers expires ssl >/dev/null
a2dismod php\* >/dev/null 2>&1 || true
a2dissite 000-default >/dev/null 2>&1 || true

cat > /etc/apache2/sites-available/freepbx.conf <<EOF
<VirtualHost *:80>
    ServerName freepbx.local
    DocumentRoot /var/www/html

    <Directory /var/www/html>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch \.php$>
        SetHandler "proxy:unix:${FPM_SOCK}|fcgi://localhost/"
    </FilesMatch>

    DirectoryIndex index.php index.html

    ErrorLog \${APACHE_LOG_DIR}/freepbx_error.log
    CustomLog \${APACHE_LOG_DIR}/freepbx_access.log combined
</VirtualHost>
EOF

sed -i '/<Directory \/var\/www\/>/,/<\/Directory>/ s|AllowOverride None|AllowOverride All|' /etc/apache2/apache2.conf || true
a2ensite freepbx >/dev/null
systemctl restart apache2

log "13/13 FreePBX 17"

systemctl enable --now cron
ensure_dir /var/spool/cron/crontabs
chown root:crontab /var/spool/cron/crontabs 2>/dev/null || true
chmod 1730 /var/spool/cron/crontabs

sudo -u "${AST_USER}" crontab -l >/dev/null 2>&1 || sudo -u "${AST_USER}" bash -c 'echo "" | crontab -'
sudo -u "${AST_USER}" crontab -l >/dev/null 2>&1 || die "crontab от пользователя ${AST_USER} не работает"

cd /usr/src
if [[ ! -d /usr/src/freepbx ]]; then
  if [[ -n "${FREEPBX_SRC_DIR:-}" && -d "${FREEPBX_SRC_DIR}" ]]; then
    log "Использую локальный каталог FreePBX/framework: ${FREEPBX_SRC_DIR}"
    cp -a "${FREEPBX_SRC_DIR}" /usr/src/freepbx
  else
    git clone --depth=1 -b "${FREEPBX_TAG}" https://github.com/FreePBX/framework.git /usr/src/freepbx
  fi
fi
chown -R "${AST_USER}:${AST_GROUP}" /usr/src/freepbx

INSTALL_LOG=""
if [[ ! -f /etc/freepbx.conf ]]; then
  cd /usr/src/freepbx
  INSTALL_LOG="/root/freepbx_install_$(date +%Y%m%d_%H%M%S).log"

  if [[ -n "${FREEPBX_GPG_FILE:-}" && -f "${FREEPBX_GPG_FILE}" ]]; then
    sudo -u "${AST_USER}" mkdir -p /var/lib/asterisk/.gnupg || true
    sudo -u "${AST_USER}" gpg --homedir /var/lib/asterisk/.gnupg --import "${FREEPBX_GPG_FILE}" || true
  fi

  (
    set +eE +o pipefail
    trap - ERR
    ./start_asterisk start || true
    ./install -n \
      --dbhost=127.0.0.1 \
      --dbuser="${DB_USER}" \
      --dbpass="${DB_PASS}" \
      --dbname="${DB_ASTERISK}" \
      --cdrdbname="${DB_CDR}" \
      2>&1 | tee "${INSTALL_LOG}"
    exit 0
  )
  [[ -f /etc/freepbx.conf ]] || die "FreePBX install не завершился. Лог: ${INSTALL_LOG}"
fi

ln -sf /var/lib/asterisk/bin/fwconsole /usr/sbin/fwconsole || true

ensure_asterisk_running
fwconsole chown || true
fwconsole ma installall || true
fwconsole ma upgradeall || true

fix_freepbx_framework_signed

setup_pm2
install_pm2_asterisk_systemd
setup_incron
ensure_php_shebang_compat
fix_firewall_oobe_state

if [[ "${INSTALL_SYSADMIN_FIREWALL}" = "yes" ]]; then
  if check_required_offline_assets_for_sysadmin_firewall; then
    install_sysadmin_firewall_offline
  else
    if [[ "${ALLOW_ONLINE_SYSADMIN_FIREWALL}" = "yes" ]]; then
      warn "Офлайн-комплект неполный, пробуем online fallback для sysadmin/firewall"
      install_sysadmin_firewall_online
    else
      die "Для sysadmin/firewall не найден полный offline-комплект, а online fallback запрещён"
    fi
  fi
else
  die "Установка Sysadmin/Firewall отключена, а по ТЗ она обязательна"
fi

fix_firewall_oobe_state
smoketest_sysadmin_firewall_hook
fix_freepbx_ucp_pm2

ensure_asterisk_running
fwconsole reload || fwconsole reload --dont-reload-asterisk || true
fwconsole chown || true

systemctl restart apache2 php83-fpm postfix incron || true
systemctl restart asterisk || true
systemctl restart pm2-asterisk || true
ensure_asterisk_running

write_check_script
write_credentials_file

log "Финальные проверки"

PHP_STATE="$(systemctl is-active php83-fpm 2>/dev/null || true)"
DB_STATE="$(systemctl is-active mariadb 2>/dev/null || true)"
APACHE_STATE="$(systemctl is-active apache2 2>/dev/null || true)"
INCRON_STATE="$(systemctl is-active incron 2>/dev/null || true)"
AST_STATE="$(systemctl is-active asterisk 2>/dev/null || true)"

if ! asterisk -rx 'core show version' >/dev/null 2>&1; then
  die "Asterisk не отвечает по CLI. systemd-state=${AST_STATE}"
fi

IP_ADDR="$(hostname -I | awk '{print $1}')"
G729_SUMMARY="$(ls -1 /usr/lib/asterisk/modules/codec_g729.so /usr/lib/asterisk/modules/codec_g729a.so 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ' || true)"
[[ -n "${G729_SUMMARY}" ]] || G729_SUMMARY="НЕТ"

echo
echo "===================================================================="
echo "  FreePBX UI:    http://${IP_ADDR}/admin/"
echo "  PHP:           $(${PHP_BIN} -v | head -1)"
echo "  Asterisk:      $(asterisk -V 2>/dev/null || echo 'не отвечает')"
echo "  G.729 module:  ${G729_SUMMARY}"
echo "  Сервисы:       ${PHP_STATE} (php-fpm) | ${DB_STATE} (mariadb) | ${APACHE_STATE} (apache2) | ${INCRON_STATE} (incron) | ${AST_STATE} (asterisk)"
echo "  Лог скрипта:   ${LOG_FILE}"
echo "  Check script:  ${CHECK_SCRIPT}"
echo "  Credentials:   ${CREDENTIALS_FILE}"
echo "===================================================================="

print_final_credentials

echo
echo "===================== CHECKLIST REPORT ====================="
"${CHECK_SCRIPT}" || true
echo "============================================================"

log "Установка завершена"