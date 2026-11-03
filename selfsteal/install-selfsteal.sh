#!/usr/bin/env bash
# Настраивает локальную HTTPS-маскировку Caddy для Xray Reality.
# Caddy: public TCP/80 for ACME HTTP-01, local TCP/8443 for Reality target.
# Xray keeps public TCP/443; this script never stops or reconfigures Xray.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly VERSION="1.1.0"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly WEB_ROOT="/var/www/remnawave-selfsteal"
readonly STATE_FILE="/etc/remnawave-selfsteal.conf"
readonly BACKUP_ROOT="/var/lib/remnawave-selfsteal/backups"
readonly CLI_FILE="/usr/local/sbin/remnawave-selfsteal"
readonly LOCK_FILE="/run/lock/remnawave-selfsteal.lock"
readonly MANAGED_MARKER="# Managed by remnawave-selfsteal"

DOMAIN=""
EXPECTED_IP=""
FORCE=0
SUCCESS=0
WORKDIR=""
BACKUP_DIR=""
PAGE_FILE=""
ACTION="install"
CADDY_LOG_PID=""

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Использование:
  sudo bash install-selfsteal.sh [--domain ИМЯ] [--expected-ip IPv4] [--force]
  sudo remnawave-selfsteal menu|status|check|start|stop|restart|logs|backup|backups
  sudo remnawave-selfsteal restore ИМЯ_КОПИИ
  sudo remnawave-selfsteal page /путь/страница.html
  bash install-selfsteal.sh self-test

Обычный запуск спрашивает домен. Публичный IPv4 определяется автоматически,
а если это не удалось - скрипт попросит ввести его вручную.

Опции:
  --domain ИМЯ          Домен Reality/Selfsteal, например brr1.example.com.
  --expected-ip IPv4    Ожидаемый IPv4 сервера, если автоопределение недоступно.
  --page ФАЙЛ           Своя HTML-страница (при повторном запуске страница сохраняется).
  --force               Разрешить замену чужого существующего Caddyfile.
  -h, --help            Показать справку.

Скрипт не занимает и не освобождает порт 443. Xray может продолжать слушать 443.
Для выпуска и продления сертификата публичный TCP/80 должен быть доступен из интернета.
EOF
}

need_root() {
  (( EUID == 0 )) || die "Запустите скрипт от root или через sudo."
}

need_commands() {
  local cmd missing=()
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  ((${#missing[@]} == 0)) || die "Не найдены команды: ${missing[*]}"
}

validate_domain() {
  local value=${1,,}
  [[ ${#value} -le 253 ]] || return 1
  [[ "$value" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

validate_ipv4() {
  python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if address.version == 4 and address.is_global else 1)
PY
}

load_saved_domain() {
  [[ -r "$STATE_FILE" ]] || return 1
  local saved
  saved=$(sed -n 's/^DOMAIN=//p' "$STATE_FILE" | head -n1)
  validate_domain "$saved" || return 1
  DOMAIN=$saved
}

detect_public_ipv4() {
  local service value
  for service in \
    https://api.ipify.org \
    https://ifconfig.me/ip \
    https://icanhazip.com; do
    value=$(curl -4fsS --connect-timeout 5 --max-time 10 "$service" 2>/dev/null | tr -d '[:space:]') || true
    if validate_ipv4 "$value"; then
      printf '%s' "$value"
      return 0
    fi
  done
  return 1
}

resolve_ipv4() {
  getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u
}

resolve_ipv6() {
  getent ahostsv6 "$1" 2>/dev/null \
    | awk '{print $1}' \
    | grep -v '^::ffff:' \
    | sort -u || true
}

local_global_ipv6() {
  ip -6 -o address show scope global 2>/dev/null \
    | awk '{sub(/\/.*/, "", $4); print $4}' \
    | sort -u
}

port_listeners() {
  local port=$1
  ss -lntupH 2>/dev/null | awk -v wanted=":${port}" '$5 ~ (wanted "$") {print}'
}

assert_port_available_or_caddy() {
  local port=$1 listeners line pid
  listeners=$(port_listeners "$port")
  [[ -z "$listeners" ]] && return 0
  pid=$(systemctl show caddy --property=MainPID --value 2>/dev/null || true)
  while IFS= read -r line; do
    if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]] || [[ "$line" != *"pid=${pid},"* ]] \
       || [[ "$line" != *'"caddy"'* ]]; then
      printf '%s\n' "$listeners" >&2
      die "Порт $port занят чужим процессом (включая Caddy в Docker). Ничего не изменено."
    fi
  done <<< "$listeners"
}

acquire_lock() {
  need_commands flock
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Другой процесс Selfsteal уже выполняет изменения."
}

assert_managed() {
  local first_line
  [[ -f "$CADDYFILE" ]] || die "Caddyfile не найден."
  first_line=$(head -n1 "$CADDYFILE")
  [[ "$first_line" == "${MANAGED_MARKER} "* ]] || die "Caddyfile не принадлежит Selfsteal. Управление отменено."
  load_saved_domain || die "Не найден корректный сохранённый домен."
}

create_backup() {
  install -d -m 0700 "$BACKUP_ROOT"
  BACKUP_DIR=$(mktemp -d "${BACKUP_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
  local name file
  for name in Caddyfile index.html state cli; do
    case "$name" in
      Caddyfile) file=$CADDYFILE ;;
      index.html) file=$WEB_ROOT/index.html ;;
      state) file=$STATE_FILE ;;
      cli) file=$CLI_FILE ;;
    esac
    if [[ -f "$file" ]]; then
      cp -p -- "$file" "$BACKUP_DIR/$name"
      touch "$BACKUP_DIR/had-$name"
    fi
  done
  if systemctl is-active --quiet caddy; then touch "$BACKUP_DIR/active"; fi
  systemctl is-enabled caddy > "$BACKUP_DIR/enabled" 2>/dev/null || true
  touch "$BACKUP_DIR/complete-v1"
}

restore_snapshot() {
  local snapshot=$1 name file
  [[ -f "$snapshot/complete-v1" ]] || return 1
  for name in Caddyfile index.html state cli; do
    case "$name" in
      Caddyfile) file=$CADDYFILE ;;
      index.html) file=$WEB_ROOT/index.html ;;
      state) file=$STATE_FILE ;;
      cli) file=$CLI_FILE ;;
    esac
    if [[ -f "$snapshot/had-$name" ]]; then
      mkdir -p -- "$(dirname -- "$file")" || return 1
      cp -p -- "$snapshot/$name" "$file" || return 1
    else
      rm -f -- "$file" || return 1
    fi
  done
  if [[ -f "$snapshot/active" ]]; then
    systemctl restart caddy || return 1
  else
    systemctl stop caddy || return 1
  fi
  case "$(cat "$snapshot/enabled")" in
    enabled) systemctl enable caddy >/dev/null || return 1 ;;
    enabled-runtime) systemctl enable --runtime caddy >/dev/null || return 1 ;;
    masked) systemctl mask caddy >/dev/null || return 1 ;;
    masked-runtime) systemctl mask --runtime caddy >/dev/null || return 1 ;;
    disabled|not-found|"") systemctl disable caddy >/dev/null || return 1 ;;
  esac
}

stop_caddy_logs() {
  [[ -n "$CADDY_LOG_PID" ]] || return 0
  kill "$CADDY_LOG_PID" 2>/dev/null || true
  wait "$CADDY_LOG_PID" 2>/dev/null || true
  CADDY_LOG_PID=""
}

rollback() {
  local rc=$?
  trap - EXIT
  stop_caddy_logs
  if (( SUCCESS == 0 )) && [[ -n "$BACKUP_DIR" ]]; then
    warn "Ошибка. Восстанавливаю файлы и прежнее состояние Caddy из $BACKUP_DIR"
    if ! restore_snapshot "$BACKUP_DIR"; then
      warn "Автоматическое восстановление не завершилось. Копия: $BACKUP_DIR"
      rc=1
    fi
  fi
  [[ -z "$WORKDIR" || ! -d "$WORKDIR" ]] || rm -rf -- "$WORKDIR"
  return "$rc"
}

begin_transaction() {
  create_backup
  SUCCESS=0
  trap rollback EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

write_page() {
  if [[ -n "$PAGE_FILE" ]]; then
    [[ -f "$PAGE_FILE" && -s "$PAGE_FILE" ]] || die "HTML-файл отсутствует или пуст: $PAGE_FILE"
    install -d -m 0755 "$WEB_ROOT"
    install -m 0644 "$PAGE_FILE" "$WEB_ROOT/index.html"
    return
  fi
  [[ ! -f "$WEB_ROOT/index.html" ]] || return 0
  install -d -m 0755 "$WEB_ROOT"
  install -m 0644 /dev/null "$WEB_ROOT/index.html"
  cat > "$WEB_ROOT/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="robots" content="noindex,nofollow">
  <title>Service status</title>
  <style>
    :root { color-scheme: light dark; font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { min-height: 100vh; margin: 0; display: grid; place-items: center; background: #f4f6f8; color: #17202a; }
    main { width: min(560px, calc(100% - 48px)); padding: 40px; border-radius: 18px; background: #fff; box-shadow: 0 18px 60px rgba(23,32,42,.10); }
    h1 { margin: 0 0 12px; font-size: 28px; }
    p { margin: 0; color: #5d6d7e; line-height: 1.6; }
    .status { display: inline-flex; align-items: center; gap: 9px; margin-top: 24px; font-weight: 600; color: #216e39; }
    .dot { width: 10px; height: 10px; border-radius: 50%; background: #2da44e; box-shadow: 0 0 0 5px rgba(45,164,78,.12); }
    @media (prefers-color-scheme: dark) { body { background: #0d1117; color: #e6edf3; } main { background: #161b22; box-shadow: none; } p { color: #8b949e; } .status { color: #56d364; } }
  </style>
</head>
<body>
  <main>
    <h1>Service is available</h1>
    <p>The requested service is online and operating normally.</p>
    <div class="status"><span class="dot"></span>All systems operational</div>
  </main>
</body>
</html>
HTML
}

write_caddyfile() {
  local target=$1
  cat > "$target" <<EOF
${MANAGED_MARKER} ${VERSION}
# Domain: ${DOMAIN}

{
        servers {
                protocols h1 h2
        }
}

http://${DOMAIN} {
        redir https://${DOMAIN}{uri} permanent
}

https://${DOMAIN}:8443 {
        bind 127.0.0.1

        tls {
                issuer acme {
                        disable_tlsalpn_challenge
                }
        }

        root * ${WEB_ROOT}
        encode zstd gzip
        header {
                -Server
                Strict-Transport-Security "max-age=31536000"
                X-Content-Type-Options "nosniff"
                Referrer-Policy "no-referrer"
        }
        file_server
}
EOF
  chmod 0600 "$target"
}

self_test() {
  need_commands python3
  validate_domain example.com
  validate_domain node-1.example.com
  if validate_domain localhost; then die "Self-test: принят некорректный домен."; fi
  if validate_domain '-bad.example.com'; then die "Self-test: принят некорректный домен."; fi
  if validate_domain 'bad_.example.com'; then die "Self-test: принят некорректный домен."; fi
  validate_ipv4 8.8.8.8 >/dev/null 2>&1
  if validate_ipv4 127.0.0.1 >/dev/null 2>&1; then die "Self-test: принят локальный IPv4."; fi
  printf '%s\n' "[ OK ] Self-test ${VERSION} пройден."
}

parse_args() {
  while (($#)); do
    case "$1" in
      --domain)
        (($# >= 2)) || die "После --domain нужно указать домен."
        shift
        DOMAIN=$1
        ;;
      --expected-ip)
        (($# >= 2)) || die "После --expected-ip нужно указать IPv4."
        shift
        EXPECTED_IP=$1
        ;;
      --page)
        (($# >= 2)) || die "После --page нужен путь."
        shift
        PAGE_FILE=$1
        ;;
      --force) FORCE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Неизвестный аргумент: $1" ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  need_root
  need_commands apt-get curl getent awk sed grep sort ss ip python3 systemctl install openssl flock realpath sha256sum
  acquire_lock
  if [[ -n "$PAGE_FILE" ]]; then
    [[ -f "$PAGE_FILE" && -s "$PAGE_FILE" ]] || die "HTML-файл отсутствует или пуст: $PAGE_FILE"
    PAGE_FILE=$(realpath -- "$PAGE_FILE")
    [[ "$PAGE_FILE" != "$WEB_ROOT/index.html" ]] || PAGE_FILE=""
  fi

  if [[ -z "$DOMAIN" ]]; then
    if load_saved_domain; then
      info "Использую сохранённый домен: $DOMAIN"
    else
      read -r -p "Домен Reality/Selfsteal (например brr1.example.com): " DOMAIN
    fi
  fi
  DOMAIN=${DOMAIN,,}
  validate_domain "$DOMAIN" || die "Некорректный домен: $DOMAIN"

  if [[ -z "$EXPECTED_IP" ]]; then
    if EXPECTED_IP=$(detect_public_ipv4); then
      ok "Публичный IPv4 определён автоматически: $EXPECTED_IP"
    else
      warn "Не удалось определить публичный IPv4 автоматически."
      read -r -p "Публичный IPv4 этой ноды: " EXPECTED_IP
    fi
  fi
  validate_ipv4 "$EXPECTED_IP" || die "Некорректный публичный IPv4: $EXPECTED_IP"

  local dns_v4 dns_v6 local_v6 address
  dns_v4=$(resolve_ipv4 "$DOMAIN" || true)
  [[ -n "$dns_v4" ]] || die "У $DOMAIN не найдена A-запись."
  grep -Fxq "$EXPECTED_IP" <<< "$dns_v4" \
    || die "$DOMAIN указывает на ${dns_v4//$'\n'/, }, а IPv4 этой ноды: $EXPECTED_IP"

  while IFS= read -r address; do
    [[ "$address" == "$EXPECTED_IP" ]] || die "Лишняя A-запись $address: все A-записи должны вести на эту ноду."
  done <<< "$dns_v4"

  dns_v6=$(resolve_ipv6 "$DOMAIN")
  if [[ -n "$dns_v6" ]]; then
    local_v6=$(local_global_ipv6)
    while IFS= read -r address; do
      grep -Fxq "$address" <<< "$local_v6" \
        || die "AAAA-запись $DOMAIN указывает на чужой IPv6 $address. Удалите/исправьте AAAA перед выпуском сертификата."
    done <<< "$dns_v6"
  fi

  ok "DNS проверен: $DOMAIN -> $EXPECTED_IP"
  assert_port_available_or_caddy 80
  assert_port_available_or_caddy 8443

  if [[ -s "$CADDYFILE" ]] \
     && [[ "$(head -n1 "$CADDYFILE")" != "${MANAGED_MARKER} "* ]] \
     && (( FORCE == 0 )); then
    die "Обнаружен чужой Caddyfile. Проверьте $CADDYFILE и повторите с --force только если его можно заменить."
  fi

  begin_transaction
  info "Устанавливаю необходимые пакеты."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates caddy curl openssl
  need_commands caddy

  WORKDIR=$(mktemp -d)

  write_page
  write_caddyfile "$WORKDIR/Caddyfile"
  caddy fmt --overwrite "$WORKDIR/Caddyfile"
  caddy validate --config "$WORKDIR/Caddyfile" --adapter caddyfile
  install -m 0644 "$WORKDIR/Caddyfile" "$CADDYFILE"

  systemctl enable caddy >/dev/null
  if command -v journalctl >/dev/null 2>&1; then
    info "Показываю журнал Caddy/ACME в реальном времени до завершения проверки сертификата."
    local caddy_log_since
    caddy_log_since=$(date '+%Y-%m-%d %H:%M:%S')
    # Include records emitted during start/reload; close the inherited lock FD.
    journalctl -u caddy --since "$caddy_log_since" \
      --follow --no-tail --no-pager -o cat 9>&- &
    CADDY_LOG_PID=$!
  else
    warn "journalctl не найден; ход выпуска можно проверить в журнале Caddy."
  fi
  if systemctl is-active --quiet caddy; then
    systemctl reload caddy
  else
    systemctl start caddy
  fi

  info "Жду выпуск сертификата через HTTP-01 на публичном порту 80."
  local attempt cert_ok=0
  for attempt in $(seq 1 60); do
    if https_check 8443 2>/dev/null; then
      cert_ok=1
      break
    fi
    printf 'Проверка сертификата: %s/60\n' "$attempt"
    sleep 2
  done
  stop_caddy_logs
  printf '\n'
  if (( cert_ok == 0 )); then
    journalctl -u caddy --since '-10 minutes' --no-pager -n 160 || true
    die "Сертификат не выпущен. Проверьте доступность публичного TCP/80."
  fi

  check_listeners || die "HTTPS должен слушать только 127.0.0.1:8443, без UDP/8443."

  if [[ "$(realpath -- "${BASH_SOURCE[0]}")" != "$CLI_FILE" ]]; then
    install -m 0755 "${BASH_SOURCE[0]}" "$CLI_FILE"
  fi
  printf 'DOMAIN=%s\nPUBLIC_IPV4=%s\n' "$DOMAIN" "$EXPECTED_IP" > "$STATE_FILE"
  chmod 0600 "$STATE_FILE"

  SUCCESS=1
  ok "Selfsteal настроен и проверен."
  printf '\nВерсия:         %s\n' "$VERSION"
  printf 'Домен:          %s\n' "$DOMAIN"
  printf 'Caddy HTTP:     публичный TCP/80 (ACME и redirect)\n'
  printf 'Caddy HTTPS:    127.0.0.1:8443 (только TCP, HTTP/1.1+HTTP/2)\n'
  printf 'Reality target: 127.0.0.1:8443\n'
  printf 'Reality SNI:    %s\n' "$DOMAIN"
  printf 'Порт 443:       не изменён; его должен слушать Xray Reality\n'
  printf 'Резервная копия: %s\n' "$BACKUP_DIR"
}

# Read-only checks do not reload Caddy, alter Xray or bypass certificate validation.
https_check() {
  local port=$1 actual expected
  [[ -f "$WEB_ROOT/index.html" ]] || return 1
  actual=$(curl --noproxy '*' -fsS --connect-timeout 3 --max-time 8 \
    --resolve "${DOMAIN}:${port}:127.0.0.1" "https://${DOMAIN}:${port}/" | sha256sum | awk '{print $1}') || return 1
  expected=$(sha256sum "$WEB_ROOT/index.html" | awk '{print $1}') || return 1
  [[ "$actual" == "$expected" ]]
}

check_listeners() {
  local tcp udp line
  tcp=$(ss -lntpH 'sport = :8443') || return 1
  udp=$(ss -lnupH 'sport = :8443') || return 1
  [[ -n "$tcp" && -z "$udp" ]] || return 1
  while IFS= read -r line; do
    [[ "$(awk '{print $4}' <<< "$line")" == '127.0.0.1:8443' ]] || return 1
  done <<< "$tcp"
}

show_status() {
  printf 'Selfsteal %s\n' "$VERSION"
  load_saved_domain || { warn "Сохранённый домен отсутствует."; return 1; }
  printf 'Домен: %s\nTarget: 127.0.0.1:8443\n' "$DOMAIN"
  systemctl --no-pager --full status caddy || return 1
}

check_health() {
  assert_managed
  local failed=0 cert
  if check_listeners; then
    ok 'HTTPS слушает только 127.0.0.1:8443; UDP/8443 закрыт.'
  else
    warn 'Проверьте TCP/8443 и UDP/8443: цель отсутствует или доступна извне.'
    failed=1
  fi
  if https_check 8443; then
    ok 'Локальный HTTPS: доверенная цепочка, правильный домен, успешный HTTP-ответ.'
  else
    warn 'Локальный HTTPS, сертификат или содержимое страницы не прошли проверку.'
    failed=1
  fi
  if https_check 443; then
    ok 'HTTPS через локальный вход 443: доверенный сертификат, содержимое совпадает с нашей страницей.'
    info 'Это проверка fallback с самой ноды; доступность из РФ и VPN-туннель проверяются клиентом.'
  else
    warn 'HTTPS через вход 443 не прошёл проверку. Проверьте target/SNI в панели и слушатель Xray.'
    failed=1
  fi
  cert=$(timeout 5 openssl s_client -connect 127.0.0.1:8443 -servername "$DOMAIN" \
    </dev/null 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null) || true
  [[ -z "$cert" ]] || printf 'Сертификат: %s\n' "$cert"
  info 'Caddy продлевает сертификат автоматически через HTTP-01; публичный TCP/80 должен оставаться доступным.'
  return "$failed"
}

list_backups() {
  [[ -d "$BACKUP_ROOT" ]] || { info 'Резервных копий пока нет.'; return 0; }
  local directory
  for directory in "$BACKUP_ROOT"/*; do
    [[ -f "$directory/complete-v1" ]] || continue
    basename -- "$directory"
  done
}

restore_backup() {
  local name=${1:-} snapshot
  [[ "$name" =~ ^[0-9]{8}T[0-9]{6}Z-[a-zA-Z0-9]{6}$ ]] || die 'Укажите имя из команды backups.'
  snapshot="$BACKUP_ROOT/$name"
  [[ -d "$snapshot" && ! -L "$snapshot" && -f "$snapshot/complete-v1" ]] || die 'Копия не найдена или имеет старый формат.'
  # Check the old configuration before changing the current files.
  if [[ -f "$snapshot/had-Caddyfile" ]]; then
    caddy validate --config "$snapshot/Caddyfile" --adapter caddyfile
  fi
  begin_transaction
  restore_snapshot "$snapshot"
  SUCCESS=1
  ok "Восстановлено из $name. Состояние до восстановления сохранено в $BACKUP_DIR"
  warn 'После смены домена согласуйте SNI и target в панели Remnawave; панель скрипт не меняет.'
}

management() {
  local action=$1
  shift
  need_root
  need_commands systemctl ss curl openssl timeout awk grep sed head sha256sum realpath
  case "$action" in
    status) show_status ;;
    check) check_health ;;
    logs) assert_managed; journalctl -u caddy --no-pager -n 100 ;;
    backups) list_backups ;;
    start|stop|restart)
      acquire_lock
      assert_managed
      if [[ "$action" != stop ]]; then
        caddy validate --config "$CADDYFILE" --adapter caddyfile
        assert_port_available_or_caddy 80
        assert_port_available_or_caddy 8443
      fi
      systemctl "$action" caddy
      ;;
    backup)
      acquire_lock
      assert_managed
      create_backup
      ok "Резервная копия: $BACKUP_DIR"
      ;;
    restore)
      acquire_lock
      assert_managed
      restore_backup "$@"
      ;;
    page)
      acquire_lock
      assert_managed
      PAGE_FILE=${1:-}
      [[ -f "$PAGE_FILE" && -s "$PAGE_FILE" ]] || die 'Укажите непустой HTML-файл.'
      [[ "$(realpath -- "$PAGE_FILE")" != "$WEB_ROOT/index.html" ]] || die 'Эта страница уже установлена.'
      begin_transaction
      write_page
      https_check 8443
      SUCCESS=1
      ok "Страница обновлена. Резервная копия: $BACKUP_DIR"
      ;;
    *) die "Неизвестная команда: $action" ;;
  esac
}

menu_action() {
  if bash "${BASH_SOURCE[0]}" "$@"; then
    return 0
  else
    warn 'Операция не завершена. Меню остаётся доступным; причина показана выше.'
  fi
}

menu() {
  [[ -t 0 ]] || die 'Для меню нужен интерактивный терминал; используйте status/check/install.'
  local choice backup_name page
  while true; do
    printf '\nSelfsteal %s\n1) Статус\n2) Проверка HTTPS и сертификата\n3) Логи\n4) Запустить\n5) Остановить\n6) Перезапустить\n7) Резервная копия\n8) Список копий\n9) Восстановить копию\n10) Заменить HTML-страницу\n11) Установка / перенастройка\n0) Выход\n' "$VERSION"
    read -r -p 'Выбор: ' choice || return 0
    # Each action is a separate process: errexit and rollback remain effective.
    case "$choice" in
      1) menu_action status ;;
      2) menu_action check ;;
      3) menu_action logs ;;
      4) menu_action start ;;
      5) menu_action stop ;;
      6) menu_action restart ;;
      7) menu_action backup ;;
      8) menu_action backups ;;
      9)
        menu_action backups
        read -r -p 'Имя копии: ' backup_name || return 0
        menu_action restore "$backup_name"
        ;;
      10)
        read -r -p 'Путь к HTML-файлу: ' page || return 0
        menu_action page "$page"
        ;;
      11) menu_action install ;;
      0) return 0 ;;
      *) warn 'Неизвестный пункт.' ;;
    esac
  done
}

dispatch() {
  ACTION=${1:-}
  case "$ACTION" in
    self-test) self_test ;;
    menu) menu ;;
    status|check|start|stop|restart|logs|backup|backups|restore|page) management "$@" ;;
    install) shift; main "$@" ;;
    '')
      if [[ -t 0 && -f "$STATE_FILE" ]]; then menu; else main; fi
      ;;
    *) main "$@" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  dispatch "$@"
fi
