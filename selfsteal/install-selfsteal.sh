#!/usr/bin/env bash
# Настраивает локальную HTTPS-маскировку Caddy для Xray Reality.
# Caddy: public TCP/80 for ACME HTTP-01, local TCP/8443 for Reality target.
# Xray keeps public TCP/443; this script never stops or reconfigures Xray.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly VERSION="1.0.1"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly WEB_ROOT="/var/www/remnawave-selfsteal"
readonly STATE_FILE="/etc/remnawave-selfsteal.conf"
readonly BACKUP_ROOT="/var/lib/remnawave-selfsteal/backups"
readonly MANAGED_MARKER="# Managed by remnawave-selfsteal"

DOMAIN=""
EXPECTED_IP=""
FORCE=0
SUCCESS=0
WORKDIR=""
BACKUP_DIR=""
CADDYFILE_BACKUP=""
INDEX_BACKUP=""
HAD_INDEX=0

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Использование:
  sudo bash install-selfsteal.sh [--domain ИМЯ] [--expected-ip IPv4] [--force]
  bash install-selfsteal.sh self-test

Обычный запуск спрашивает домен. Публичный IPv4 определяется автоматически,
а если это не удалось - скрипт попросит ввести его вручную.

Опции:
  --domain ИМЯ          Домен Reality/Selfsteal, например brr1.example.com.
  --expected-ip IPv4    Ожидаемый IPv4 сервера, если автоопределение недоступно.
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
  local port=$1 listeners
  listeners=$(port_listeners "$port")
  [[ -z "$listeners" ]] && return 0
  if grep -q 'caddy' <<< "$listeners"; then
    return 0
  fi
  printf '%s\n' "$listeners" >&2
  die "Порт $port уже занят не Caddy. Ничего не изменено."
}

rollback() {
  local rc=$?
  [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf -- "$WORKDIR"
  (( SUCCESS == 1 )) && return 0
  [[ -n "$BACKUP_DIR" ]] || return "$rc"

  warn "Настройка не завершена. Восстанавливаю прежние файлы Caddy."
  if [[ -n "$CADDYFILE_BACKUP" && -f "$CADDYFILE_BACKUP" ]]; then
    install -m 0644 "$CADDYFILE_BACKUP" "$CADDYFILE"
  fi
  if (( HAD_INDEX == 1 )) && [[ -f "$INDEX_BACKUP" ]]; then
    install -d -m 0755 "$WEB_ROOT"
    install -m 0644 "$INDEX_BACKUP" "$WEB_ROOT/index.html"
  else
    rm -f -- "$WEB_ROOT/index.html"
  fi
  systemctl restart caddy >/dev/null 2>&1 || true
  return "$rc"
}

write_page() {
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
  ! validate_domain localhost
  ! validate_domain '-bad.example.com'
  ! validate_domain 'bad_.example.com'
  validate_ipv4 8.8.8.8 >/dev/null 2>&1
  ! validate_ipv4 127.0.0.1 >/dev/null 2>&1
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
  need_commands apt-get curl getent awk sed grep sort ss ip python3 systemctl install openssl

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

  local dns_v4 dns_v6 local_v6
  dns_v4=$(resolve_ipv4 "$DOMAIN")
  [[ -n "$dns_v4" ]] || die "У $DOMAIN не найдена A-запись."
  grep -Fxq "$EXPECTED_IP" <<< "$dns_v4" \
    || die "$DOMAIN указывает на ${dns_v4//$'\n'/, }, а IPv4 этой ноды: $EXPECTED_IP"

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

  local caddy_preexisting=0
  command -v caddy >/dev/null 2>&1 && caddy_preexisting=1
  if (( caddy_preexisting == 1 )) && [[ -s "$CADDYFILE" ]] \
     && ! grep -Fq "$MANAGED_MARKER" "$CADDYFILE" \
     && (( FORCE == 0 )); then
    die "Обнаружен чужой Caddyfile. Проверьте $CADDYFILE и повторите с --force только если его можно заменить."
  fi

  info "Устанавливаю необходимые пакеты."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates caddy curl openssl
  need_commands caddy

  install -d -m 0700 "$BACKUP_ROOT"
  BACKUP_DIR="${BACKUP_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)"
  install -d -m 0700 "$BACKUP_DIR"
  CADDYFILE_BACKUP="$BACKUP_DIR/Caddyfile"
  INDEX_BACKUP="$BACKUP_DIR/index.html"
  [[ -f "$CADDYFILE" ]] && install -m 0600 "$CADDYFILE" "$CADDYFILE_BACKUP"
  if [[ -f "$WEB_ROOT/index.html" ]]; then
    HAD_INDEX=1
    install -m 0600 "$WEB_ROOT/index.html" "$INDEX_BACKUP"
  fi

  WORKDIR=$(mktemp -d)
  trap rollback EXIT

  write_page
  write_caddyfile "$WORKDIR/Caddyfile"
  caddy validate --config "$WORKDIR/Caddyfile" --adapter caddyfile
  install -m 0644 "$WORKDIR/Caddyfile" "$CADDYFILE"

  systemctl enable caddy >/dev/null
  if systemctl is-active --quiet caddy; then
    systemctl reload caddy
  else
    systemctl start caddy
  fi

  info "Жду выпуск сертификата через HTTP-01 на публичном порту 80."
  local attempt cert_ok=0
  for attempt in $(seq 1 60); do
    if curl -fsS --connect-timeout 5 --max-time 10 \
      --resolve "${DOMAIN}:8443:127.0.0.1" \
      "https://${DOMAIN}:8443/" \
      | grep -Fq 'All systems operational'; then
      cert_ok=1
      break
    fi
    printf 'Проверка сертификата: %s/60\r' "$attempt"
    sleep 2
  done
  printf '\n'
  if (( cert_ok == 0 )); then
    journalctl -u caddy --since '-10 minutes' --no-pager -n 160 || true
    die "Сертификат не выпущен. Проверьте доступность публичного TCP/80."
  fi

  local tcp_8443 udp_8443
  tcp_8443=$(ss -lntpH 'sport = :8443' 2>/dev/null || true)
  udp_8443=$(ss -lnupH 'sport = :8443' 2>/dev/null || true)
  grep -q '127.0.0.1:8443' <<< "$tcp_8443" || die "Caddy не слушает 127.0.0.1:8443."
  [[ -z "$udp_8443" ]] || die "Caddy неожиданно открыл UDP/8443; HTTP/3 не отключён."

  install -m 0755 "${BASH_SOURCE[0]}" /usr/local/sbin/remnawave-selfsteal
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

if [[ ${1:-} == self-test ]]; then
  self_test
else
  main "$@"
fi
