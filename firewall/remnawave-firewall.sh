#!/usr/bin/env bash
# Интерактивный firewall для Ubuntu VPS с Remnawave Node/Xray и Docker host networking.
# Управляет только таблицей inet remnawave_guard. Не выполняет flush ruleset.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly VERSION="1.1.2"
readonly TABLE_FAMILY="inet"
readonly TABLE_NAME="remnawave_guard"
readonly INSTALL_PATH="/usr/local/sbin/remnawave-firewall"
readonly ETC_DIR="/etc/remnawave-firewall"
readonly RULES_FILE="${ETC_DIR}/rules.nft"
readonly STATE_DIR="/var/lib/remnawave-firewall"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly PENDING_RULES="${STATE_DIR}/pending-rules.nft"
readonly PENDING_BACKUP="${STATE_DIR}/pending-backup"
readonly LAST_BACKUP="${STATE_DIR}/last-backup"
readonly UNIT_FILE="/etc/systemd/system/remnawave-firewall.service"
readonly ROLLBACK_UNIT="remnawave-firewall-rollback"

DRY_RUN=0
FORCE_CONFLICTS=0
ROLLBACK_SECONDS=180
ASSUME_YES=0

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Использование:
  sudo bash remnawave-firewall.sh apply [--dry-run] [--rollback-seconds N]
  sudo remnawave-firewall status
  sudo remnawave-firewall test
  sudo remnawave-firewall confirm
  sudo remnawave-firewall rollback [КАТАЛОГ_РЕЗЕРВНОЙ_КОПИИ]
  bash remnawave-firewall.sh self-test

Команды:
  apply       Интерактивно собрать, проверить и применить правила.
  status      Показать таблицу, автозагрузку, таймер отката и Docker-сети.
  test        Проверить установленную конфигурацию без её изменения.
  confirm     Отменить страховочный откат и закрепить ожидающие правила.
  rollback    Восстановить последнее предыдущее состояние.
  self-test   Локальные тесты парсеров/генератора; firewall не меняется.

Опции apply:
  --dry-run              Только сформировать и проверить конфигурацию.
  --rollback-seconds N   Окно автоматического отката, 60..1800 (по умолчанию 180).
  --force-conflicts      Разрешить продолжение при найденных конфликтах.
  --yes                  Не задавать дополнительный вопрос о конфликтах.
EOF
}

need_root() {
  (( EUID == 0 )) || die "Эта команда требует root. Запустите через sudo."
}

need_commands() {
  local missing=() cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  ((${#missing[@]} == 0)) || die "Не найдены команды: ${missing[*]}. На Ubuntu установите пакет nftables и стандартные systemd/iproute2/python3."
}

ask() {
  local prompt=$1 default=${2-} answer
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " answer || die "Ввод прерван."
    printf '%s' "${answer:-$default}"
  else
    read -r -p "$prompt: " answer || die "Ввод прерван."
    printf '%s' "$answer"
  fi
}

ask_yes_no() {
  local prompt=$1 default=${2:-n} answer suffix
  [[ "$default" == "y" ]] && suffix="Y/n" || suffix="y/N"
  while true; do
    read -r -p "$prompt [$suffix]: " answer || die "Ввод прерван."
    answer=${answer:-$default}
    case "${answer,,}" in
      y|yes|д|да) return 0 ;;
      n|no|н|нет) return 1 ;;
      *) warn "Ответьте да или нет." ;;
    esac
  done
}

trim() {
  local value=$1
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

clean_ip_input() {
  local original=$1 cleaned
  cleaned=$(LC_ALL=C printf '%s' "$original" | tr -cd '0123456789abcdefABCDEF:.,; ')
  if [[ "$cleaned" != "$original" ]]; then
    warn "Во вводе IP обнаружены и удалены посторонние символы. Использую: $cleaned"
  fi
  printf '%s' "$cleaned"
}

clean_port_input() {
  local original=$1 cleaned
  cleaned=$(LC_ALL=C printf '%s' "$original" | tr -cd '0123456789,; -')
  if [[ "$cleaned" != "$original" ]]; then
    warn "Во вводе портов обнаружены и удалены посторонние символы. Использую: $cleaned"
  fi
  printf '%s' "$cleaned"
}

validate_port() {
  [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

normalize_ports() {
  local raw=$1 item start end
  local -a out=() items=()
  raw=${raw//;/,}
  raw=${raw// /,}
  IFS=',' read -r -a items <<< "$raw"
  for item in "${items[@]}"; do
    item=$(trim "$item")
    [[ -z "$item" ]] && continue
    if [[ $item =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start=${BASH_REMATCH[1]}; end=${BASH_REMATCH[2]}
      validate_port "$start" && validate_port "$end" && ((10#$start <= 10#$end)) \
        || die "Некорректный диапазон портов: $item"
      out+=("$((10#$start))-$((10#$end))")
    elif validate_port "$item"; then
      out+=("$((10#$item))")
    else
      die "Некорректный порт: $item"
    fi
  done
  local joined=""
  for item in "${out[@]}"; do
    [[ -n "$joined" ]] && joined+=", "
    joined+="$item"
  done
  printf '%s' "$joined"
}

normalize_ips() {
  local raw=$1 family=$2
  python3 - "$raw" "$family" <<'PY'
import ipaddress, re, sys
raw, wanted = sys.argv[1], int(sys.argv[2])
values = []
for value in re.split(r"[\s,;]+", raw.strip()):
    if not value:
        continue
    try:
        address = ipaddress.ip_address(value)
    except ValueError as exc:
        print(f"Некорректный IP {value!r}. Вводите только IP без /32 или /128: {exc}", file=sys.stderr)
        raise SystemExit(2)
    if address.version == wanted:
        if address.version == 4 and address.is_unspecified:
            values.append("0.0.0.0/0")
        elif address.version == 6 and address.is_unspecified:
            values.append("::/0")
        else:
            values.append(f"{address}/{32 if address.version == 4 else 128}")
print(", ".join(dict.fromkeys(values)))
PY
}

current_ssh_port() {
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    awk '{print $4}' <<< "$SSH_CONNECTION"
    return
  fi
  if command -v sshd >/dev/null 2>&1; then
    sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true
  fi
}

current_ssh_source() {
  local ip=""
  [[ -n ${SSH_CONNECTION:-} ]] && ip=$(awk '{print $1}' <<< "$SSH_CONNECTION")
  [[ -z "$ip" ]] && return 0
  printf '%s' "$ip"
}

current_ssh_server() {
  [[ -n ${SSH_CONNECTION:-} ]] || return 0
  awk '{print $3}' <<< "$SSH_CONNECTION"
}

node_ip_addresses() {
  local ssh_server
  ssh_server=$(current_ssh_server)
  {
    ip -o addr show 2>/dev/null | awk '$3 == "inet" || $3 == "inet6" {sub(/\/.*/, "", $4); print $4}'
    if [[ -n "$ssh_server" ]]; then
      printf '%s\n' "$ssh_server"
    fi
  } | awk 'NF && !seen[$0]++'
}

validate_panel_ips() {
  local raw=$1
  python3 - "$raw" <<'PY'
import ipaddress, re, sys

for value in re.split(r"[\s,;]+", sys.argv[1].strip()):
    if not value:
        continue
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        raise SystemExit(2)
    if address.is_unspecified or address.is_loopback or address.is_multicast or address.is_link_local:
        print(f"Адрес {address} недопустим для удалённой панели.", file=sys.stderr)
        raise SystemExit(1)
PY
}

find_matching_ips() {
  local wanted=$1 candidates=$2
  python3 - "$wanted" "$candidates" <<'PY'
import ipaddress, re, sys

def addresses(text):
    result = set()
    for value in re.split(r"[\s,;]+", text.strip()):
        if not value:
            continue
        try:
            result.add(ipaddress.ip_address(value.split("/", 1)[0]))
        except ValueError:
            pass
    return result

for address in sorted(addresses(sys.argv[1]) & addresses(sys.argv[2]), key=lambda a: (a.version, int(a))):
    print(address)
PY
}

detect_ipv6_default() {
  ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 ' && printf 'y' || printf 'n'
}

write_rules() {
  local target=$1 ssh_port=$2 ssh_v4=$3 ssh_v6=$4 panel_port=$5 panel_v4=$6 panel_v6=$7
  local tcp_ports=$8 ipv6_enabled=$9
  {
    printf '# Generated by remnawave-firewall %s\n' "$VERSION"
    printf '# Replaces only table %s %s; never flushes the complete ruleset.\n\n' "$TABLE_FAMILY" "$TABLE_NAME"
    printf 'table %s %s; flush table %s %s\n\n' "$TABLE_FAMILY" "$TABLE_NAME" "$TABLE_FAMILY" "$TABLE_NAME"
    printf 'table %s %s {\n' "$TABLE_FAMILY" "$TABLE_NAME"
    cat <<'EOF'

  chain input {
    type filter hook input priority filter; policy drop;

    ct state invalid counter drop comment "drop invalid"
    ct state { established, related } counter accept comment "keep established"
    iifname "lo" counter accept comment "loopback"
    iifname != "lo" ip saddr 127.0.0.0/8 counter drop comment "anti-spoof IPv4 loopback"
    iifname != "lo" ip6 saddr ::1 counter drop comment "anti-spoof IPv6 loopback"
    meta nfproto ipv4 meta l4proto icmp counter accept comment "ICMPv4"
    meta nfproto ipv6 meta l4proto ipv6-icmp counter accept comment "ICMPv6 incl. NDP"
EOF
    [[ -n "$ssh_v4" ]] && printf '    ip saddr { %s } tcp dport %s ct state new counter accept comment "SSH IPv4"\n' "$ssh_v4" "$ssh_port"
    [[ -n "$ssh_v6" ]] && printf '    ip6 saddr { %s } tcp dport %s ct state new counter accept comment "SSH IPv6"\n' "$ssh_v6" "$ssh_port"
    [[ -n "$panel_v4" ]] && printf '    ip saddr { %s } tcp dport %s ct state new counter accept comment "Remnawave panel IPv4"\n' "$panel_v4" "$panel_port"
    [[ -n "$panel_v6" ]] && printf '    ip6 saddr { %s } tcp dport %s ct state new counter accept comment "Remnawave panel IPv6"\n' "$panel_v6" "$panel_port"
    if [[ -n "$tcp_ports" ]]; then
      [[ "$ipv6_enabled" == "yes" ]] \
        && printf '    tcp dport { %s } ct state new counter accept comment "public TCP IPv4+IPv6"\n' "$tcp_ports" \
        || printf '    meta nfproto ipv4 tcp dport { %s } ct state new counter accept comment "public TCP IPv4 only"\n' "$tcp_ports"
    fi
    cat <<'EOF'
    counter comment "implicit default drop"
  }
}
EOF
  } > "$target"
  chmod 0600 "$target"
}

show_docker_networks() {
  command -v docker >/dev/null 2>&1 || { info "Docker CLI не найден."; return 0; }
  local ids
  ids=$(docker ps -q 2>/dev/null || true)
  [[ -z "$ids" ]] && { info "Запущенных Docker-контейнеров нет или daemon недоступен."; return 0; }
  docker inspect --format '{{.Name}} | network={{.HostConfig.NetworkMode}} | published={{json .HostConfig.PortBindings}}' $ids 2>/dev/null || true
}

docker_bridge_publications() {
  command -v docker >/dev/null 2>&1 || return 1
  local ids line mode bindings
  ids=$(docker ps -q 2>/dev/null || true)
  [[ -z "$ids" ]] && return 1
  while IFS='|' read -r line mode bindings; do
    [[ "$mode" != "host" && "$bindings" != "null" && "$bindings" != "{}" ]] && return 0
  done < <(docker inspect --format '{{.Name}}|{{.HostConfig.NetworkMode}}|{{json .HostConfig.PortBindings}}' $ids 2>/dev/null || true)
  return 1
}

count_foreign_drop_chains() {
  local all own=0
  all=$(nft list ruleset 2>/dev/null | grep -Ec 'hook input[^;]*;.*policy drop|hook input .*policy drop' || true)
  if nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; then
    own=$(nft list table "$TABLE_FAMILY" "$TABLE_NAME" 2>/dev/null | grep -Ec 'hook input[^;]*;.*policy drop|hook input .*policy drop' || true)
  fi
  (( all > own ))
}

check_conflicts() {
  local -a conflicts=()
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    conflicts+=("UFW активен")
  fi
  if systemctl is-active --quiet firewalld.service 2>/dev/null; then
    conflicts+=("firewalld активен")
  fi
  if systemctl is-enabled --quiet nftables.service 2>/dev/null; then
    conflicts+=("штатный nftables.service включён; его /etc/nftables.conf может выполнить flush ruleset при загрузке")
  fi
  if systemctl is-enabled --quiet netfilter-persistent.service 2>/dev/null; then
    conflicts+=("netfilter-persistent.service включён и может загрузить конкурирующие правила")
  fi
  if count_foreign_drop_chains; then
    conflicts+=("найдена другая base-chain INPUT с policy drop; её DROP не может быть отменён ACCEPT-правилом этой таблицы")
  fi
  if docker_bridge_publications; then
    conflicts+=("есть опубликованные порты Docker не в host network; они проходят через FORWARD и не покрываются этим host INPUT firewall")
  fi
  if nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1 && [[ ! -d "$STATE_DIR" ]]; then
    conflicts+=("таблица $TABLE_FAMILY $TABLE_NAME уже существует, но состояние этого скрипта отсутствует")
  fi
  if ((${#conflicts[@]})); then
    warn "Обнаружены потенциальные конфликты:"
    printf '  - %s\n' "${conflicts[@]}" >&2
    if (( FORCE_CONFLICTS == 0 )); then
      (( ASSUME_YES == 0 )) && ask_yes_no "Вы проверили конфликты и хотите продолжить?" n && return 0
      die "Применение остановлено. После ручной проверки используйте --force-conflicts."
    fi
  fi
}

make_backup() {
  mkdir -p "$BACKUP_DIR"
  local stamp dir
  stamp=$(date -u +'%Y%m%dT%H%M%SZ')
  dir="${BACKUP_DIR}/${stamp}-$$"
  mkdir -m 0700 "$dir"
  if nft list table "$TABLE_FAMILY" "$TABLE_NAME" > "${dir}/table.previous" 2>/dev/null; then
    {
      printf 'delete table %s %s\n' "$TABLE_FAMILY" "$TABLE_NAME"
      cat "${dir}/table.previous"
    } > "${dir}/runtime.nft"
    printf 'present\n' > "${dir}/runtime.state"
  else
    printf 'delete table %s %s\n' "$TABLE_FAMILY" "$TABLE_NAME" > "${dir}/runtime.nft"
    printf 'absent\n' > "${dir}/runtime.state"
  fi
  if [[ -f "$RULES_FILE" ]]; then
    cp -a "$RULES_FILE" "${dir}/persistent.nft"
    printf 'present\n' > "${dir}/persistent.state"
  else
    printf 'absent\n' > "${dir}/persistent.state"
  fi
  systemctl is-enabled --quiet remnawave-firewall.service 2>/dev/null \
    && printf 'enabled\n' > "${dir}/service.state" \
    || printf 'disabled\n' > "${dir}/service.state"
  printf '%s\n' "$dir"
}

safe_backup_dir() {
  local dir=$1 resolved base
  [[ -n "$dir" && -d "$dir" && -f "$dir/runtime.nft" ]] || return 1
  resolved=$(readlink -f "$dir")
  base=$(readlink -f "$BACKUP_DIR")
  [[ "$resolved" == "$base"/* ]]
}

atomic_load() {
  local file=$1
  nft -c -f "$file"
  nft -f "$file"
}

restore_runtime() {
  local dir=$1 state tmp
  state=$(<"${dir}/runtime.state")
  if nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; then
    atomic_load "${dir}/runtime.nft"
  elif [[ "$state" == "present" ]]; then
    tmp=$(mktemp)
    cp "${dir}/table.previous" "$tmp"
    atomic_load "$tmp"
    rm -f "$tmp"
  fi
}

restore_persistent() {
  local dir=$1
  mkdir -p "$ETC_DIR"
  if [[ $(<"${dir}/persistent.state") == "present" ]]; then
    install -m 0600 "${dir}/persistent.nft" "$RULES_FILE"
  else
    rm -f "$RULES_FILE"
  fi
  if [[ $(<"${dir}/service.state") == "enabled" ]]; then
    [[ -f "$UNIT_FILE" ]] && systemctl enable remnawave-firewall.service >/dev/null
  else
    systemctl disable remnawave-firewall.service >/dev/null 2>&1 || true
  fi
}

cancel_rollback_timer() {
  systemctl stop "${ROLLBACK_UNIT}.timer" >/dev/null 2>&1 || true
  if systemctl is-active --quiet "${ROLLBACK_UNIT}.service" 2>/dev/null; then
    die "Автооткат уже выполняется; дождитесь его окончания и проверьте status."
  fi
  systemctl reset-failed "${ROLLBACK_UNIT}.timer" "${ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
}

schedule_rollback() {
  local seconds=$1 dir=$2
  cancel_rollback_timer
  systemd-run --quiet --collect --unit="$ROLLBACK_UNIT" --on-active="${seconds}s" \
    "$INSTALL_PATH" rollback-auto "$dir"
  ok "Автоматический откат запланирован через ${seconds} секунд."
}

install_self() {
  local source_path
  source_path=$(readlink -f "$0")
  mkdir -p "$ETC_DIR" "$STATE_DIR" "$BACKUP_DIR"
  if [[ "$source_path" != "$INSTALL_PATH" ]]; then
    install -m 0750 "$source_path" "$INSTALL_PATH"
  fi
}

write_unit() {
  local tmp
  tmp=$(mktemp)
  cat > "$tmp" <<EOF
[Unit]
Description=Remnawave host firewall (managed nftables table only)
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target docker.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} load
ExecReload=${INSTALL_PATH} load
RemainAfterExit=yes

[Install]
WantedBy=network-pre.target
EOF
  install -m 0644 "$tmp" "$UNIT_FILE"
  rm -f "$tmp"
  systemctl daemon-reload
}

commit_pending() {
  local active_state sub_state
  [[ -f "$PENDING_RULES" ]] || die "Нет ожидающей конфигурации для подтверждения."
  mkdir -p "$ETC_DIR"
  install -m 0600 "$PENDING_RULES" "$RULES_FILE"
  write_unit
  systemctl enable remnawave-firewall.service >/dev/null
  if ! systemctl start remnawave-firewall.service; then
    die "Не удалось запустить remnawave-firewall.service; страховочный откат остаётся активным."
  fi
  active_state=$(systemctl show remnawave-firewall.service --property=ActiveState --value)
  sub_state=$(systemctl show remnawave-firewall.service --property=SubState --value)
  if [[ "$active_state" != "active" || "$sub_state" != "exited" ]]; then
    die "remnawave-firewall.service не перешёл в состояние active (exited): ${active_state:-unknown} (${sub_state:-unknown}); страховочный откат остаётся активным."
  fi
  cancel_rollback_timer
  rm -f "$PENDING_RULES" "$PENDING_BACKUP"
  ok "Правила подтверждены; remnawave-firewall.service активен (exited) и включён в автозагрузку."
}

cmd_confirm() {
  need_root
  need_commands systemctl nft
  commit_pending
}

cmd_rollback() {
  need_root
  need_commands nft systemctl readlink
  local requested=${1-} dir=""
  if [[ -n "$requested" ]]; then
    dir=$requested
  elif [[ -f "$PENDING_BACKUP" ]]; then
    dir=$(<"$PENDING_BACKUP")
  elif [[ -f "$LAST_BACKUP" ]]; then
    dir=$(<"$LAST_BACKUP")
  else
    die "Не найдена резервная копия."
  fi
  safe_backup_dir "$dir" || die "Недопустимый каталог резервной копии: $dir"
  cancel_rollback_timer
  restore_runtime "$dir"
  restore_persistent "$dir"
  rm -f "$PENDING_RULES" "$PENDING_BACKUP"
  ok "Восстановлено состояние из $dir"
}

cmd_rollback_auto() {
  need_root
  need_commands nft systemctl readlink
  local dir=${1-}
  safe_backup_dir "$dir" || die "Некорректная резервная копия для автоотката."
  restore_runtime "$dir"
  restore_persistent "$dir"
  rm -f "$PENDING_RULES" "$PENDING_BACKUP"
  logger -t remnawave-firewall "Automatic rollback completed from $dir" 2>/dev/null || true
}

cmd_load() {
  need_root
  need_commands nft
  [[ -f "$RULES_FILE" ]] || die "Нет файла правил $RULES_FILE"
  atomic_load "$RULES_FILE"
}

cmd_status() {
  need_root
  need_commands nft systemctl ss
  printf 'remnawave-firewall %s\n\n' "$VERSION"
  if nft list table "$TABLE_FAMILY" "$TABLE_NAME" 2>/dev/null; then :; else warn "Управляемая таблица не загружена."; fi
  printf '\nАвтозагрузка: '
  systemctl is-enabled remnawave-firewall.service 2>/dev/null || true
  printf 'Сервис: '
  systemctl is-active remnawave-firewall.service 2>/dev/null || true
  printf 'Страховочный таймер:\n'
  systemctl list-timers "${ROLLBACK_UNIT}.timer" --no-pager 2>/dev/null || true
  printf '\nСлушающие TCP-сокеты:\n'
  ss -H -lntp 2>/dev/null || true
  printf '\nDocker network modes:\n'
  show_docker_networks
}

cmd_test() {
  need_root
  need_commands nft systemctl ss
  local failures=0
  if [[ -f "$RULES_FILE" ]] && nft -c -f "$RULES_FILE"; then ok "Синтаксис сохранённых правил корректен."; else warn "Сохранённые правила отсутствуют или не проходят nft -c."; failures=$((failures+1)); fi
  if nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; then ok "Таблица $TABLE_FAMILY $TABLE_NAME загружена."; else warn "Таблица не загружена."; failures=$((failures+1)); fi
  systemctl is-enabled --quiet remnawave-firewall.service && ok "Автозагрузка включена." || { warn "Автозагрузка не включена."; failures=$((failures+1)); }
  if count_foreign_drop_chains; then warn "Есть другая INPUT base-chain с policy drop: проверяйте совместимость вручную."; fi
  if docker_bridge_publications; then warn "Обнаружены Docker port bindings вне host network: данный INPUT firewall их не покрывает."; failures=$((failures+1)); else ok "Опубликованные bridge-порты Docker не обнаружены."; fi
  printf '\nПроверка с внешней машины (не с самой ноды) всё равно обязательна.\n'
  (( failures == 0 )) || return 1
}

cmd_apply() {
  need_root
  need_commands nft systemctl systemd-run ss ip python3 readlink install
  local os_id="" os_name="неизвестная ОС"
  if [[ -r /etc/os-release ]]; then
    os_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"' | head -n1)
    os_name=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | sed 's/^"//; s/"$//' | head -n1)
  fi
  [[ "$os_id" == "ubuntu" ]] || warn "Скрипт рассчитан на Ubuntu; обнаружено: $os_name."

  local ssh_default current_ssh_ip ipv6_default node_ips
  ssh_default=$(current_ssh_port); ssh_default=${ssh_default:-22}
  current_ssh_ip=$(current_ssh_source)
  ipv6_default=$(detect_ipv6_default)
  node_ips=$(node_ip_addresses)

  info "Будет изменена только таблица nftables '$TABLE_FAMILY $TABLE_NAME'."
  local panel_raw panel_port ssh_port ssh_raw tcp_raw ipv6_enabled
  printf '\nНужен публичный ИСХОДЯЩИЙ IP сервера Remnawave Panel.\n'
  printf 'Это адрес, С КОТОРОГО панель подключается к Node API этой ноды.\n'
  printf 'НЕ вводите IP настраиваемой ноды.\n'
  [[ -n "$node_ips" ]] && printf 'Обнаруженные IP этой ноды: %s\n\n' "${node_ips//$'\n'/, }"
  panel_raw=$(ask "Исходящий IP сервера панели (не IP ноды; несколько IP — через запятую)" "")
  panel_port=$(ask "TCP-порт Remnawave Node API (обязательно)" "")
  ssh_port=$(ask "TCP-порт SSH" "$ssh_default")
  [[ -n "$current_ssh_ip" ]] && info "Текущий SSH-клиент: $current_ssh_ip. Если этот IP постоянный, безопаснее указать его вместо значения по умолчанию."
  ssh_raw=$(ask "IP, которым разрешён SSH (0.0.0.0 = доступ всем)" "0.0.0.0")
  tcp_raw=$(ask "Публичные TCP-порты (пусто = ни одного)" "80,443")
  if ask_yes_no "Открывать указанные публичные порты также по IPv6?" "$ipv6_default"; then ipv6_enabled=yes; else ipv6_enabled=no; fi

  panel_raw=$(clean_ip_input "$panel_raw")
  ssh_raw=$(clean_ip_input "$ssh_raw")
  panel_port=$(clean_port_input "$panel_port")
  ssh_port=$(clean_port_input "$ssh_port")
  tcp_raw=$(clean_port_input "$tcp_raw")

  [[ -n $(trim "$panel_raw") ]] || die "IP панели обязателен. Домен здесь использовать нельзя."
  [[ -n $(trim "$panel_port") ]] || die "Порт Remnawave Node API обязателен."
  validate_port "$panel_port" || die "Некорректный порт панели: $panel_port"
  validate_port "$ssh_port" || die "Некорректный SSH-порт: $ssh_port"
  panel_port=$((10#$panel_port)); ssh_port=$((10#$ssh_port))
  local panel_v4 panel_v6 ssh_v4 ssh_v6 tcp_ports
  panel_v4=$(normalize_ips "$panel_raw" 4) || exit 1
  panel_v6=$(normalize_ips "$panel_raw" 6) || exit 1
  ssh_v4=$(normalize_ips "$ssh_raw" 4) || exit 1
  ssh_v6=$(normalize_ips "$ssh_raw" 6) || exit 1
  tcp_ports=$(normalize_ports "$tcp_raw")
  [[ -n "$panel_v4$panel_v6" ]] || die "Нужно указать хотя бы один адрес панели."
  [[ -n "$ssh_v4$ssh_v6" ]] || die "Нужно указать хотя бы один адрес/диапазон для SSH."
  validate_panel_ips "$panel_raw" || die "Укажите обычный unicast-адрес удалённой панели. Ничего не применено."
  local collisions
  collisions=$(find_matching_ips "$panel_raw" "$node_ips")
  if [[ -n "$collisions" ]]; then
    die "IP панели совпадает с адресом этой ноды: ${collisions//$'\n'/, }. Вероятно, введён IP ноды вместо исходящего IP панели. Ничего не применено."
  fi
  if [[ "$ipv6_enabled" == no && -n "$ssh_v6$panel_v6" ]]; then
    warn "IPv6 для публичных портов выключен, но адресные SSH/панельные разрешения IPv6 сохранены."
  fi
  if [[ "$ssh_raw" == "0.0.0.0" ]]; then
    warn "SSH-порт будет доступен со всех IPv4-адресов. Используйте SSH-ключи и отключите парольный вход."
  elif [[ -n "$current_ssh_ip" && "$ssh_raw" != *"$current_ssh_ip"* ]]; then
    warn "Текущий SSH-клиент $current_ssh_ip не виден во введённой строке. Проверьте IP особенно внимательно."
  fi

  printf '\nПроверка критичных адресов:\n'
  printf '  IP панели:       %s\n' "$panel_raw"
  printf '  IP этой ноды:    %s\n' "${node_ips//$'\n'/, }"
  printf '  Node API:        TCP/%s\n' "$panel_port"

  check_conflicts
  local generated
  generated=$(mktemp)
  trap 'rm -f "${generated:-}"' EXIT
  write_rules "$generated" "$ssh_port" "$ssh_v4" "$ssh_v6" "$panel_port" "$panel_v4" "$panel_v6" "$tcp_ports" "$ipv6_enabled"
  nft -c -f "$generated" || die "nftables отклонил конфигурацию; ничего не применено."
  ok "nft -c: конфигурация синтаксически корректна."

  printf '\nИтоговая конфигурация:\n'
  sed -n '1,240p' "$generated"
  printf '\nСейчас слушают:\n'
  ss -H -lntp 2>/dev/null || true
  printf '\nDocker network modes:\n'
  show_docker_networks

  if (( DRY_RUN )); then
    ok "Dry run завершён: firewall, systemd и постоянные файлы не изменены."
    return 0
  fi
  ask_yes_no "Применить правила со страховочным откатом через ${ROLLBACK_SECONDS} секунд?" n \
    || die "Отменено пользователем; ничего не применено."

  install_self
  local backup
  backup=$(make_backup)
  install -m 0600 "$generated" "$PENDING_RULES"
  printf '%s\n' "$backup" > "$PENDING_BACKUP"
  printf '%s\n' "$backup" > "$LAST_BACKUP"
  schedule_rollback "$ROLLBACK_SECONDS" "$backup"
  if ! atomic_load "$PENDING_RULES"; then
    warn "Применение не удалось; восстанавливаю резервную копию."
    cmd_rollback "$backup"
    return 1
  fi
  ok "Правила применены. Старое SSH-соединение сохранится благодаря established/related."
  warn "НЕ подтверждайте вслепую: откройте второе НОВОЕ SSH-соединение и проверьте доступ панели/VLESS."
  printf 'После успешной проверки введите CONFIRM\n'
  printf 'Любой другой ответ немедленно откатит правила.\n'
  local confirmation=""
  read -r confirmation || confirmation=""
  if [[ "$confirmation" == "CONFIRM" ]]; then
    commit_pending
  else
    warn "Подтверждение не получено — выполняю откат."
    cmd_rollback "$backup"
  fi
}

cmd_self_test() {
  need_commands python3
  local temp
  temp=$(mktemp)
  trap 'rm -f "${temp:-}"' EXIT
  validate_port 22
  ! validate_port 0
  ! validate_port 65536
  [[ $(normalize_ports '22, 80;443,1000-1002') == '22, 80, 443, 1000-1002' ]]
  [[ $(normalize_ips '192.0.2.10, 198.51.100.7' 4) == '192.0.2.10/32, 198.51.100.7/32' ]]
  [[ $(normalize_ips '2001:db8::1' 6) == '2001:db8::1/128' ]]
  [[ $(normalize_ips '0.0.0.0' 4) == '0.0.0.0/0' ]]
  validate_panel_ips '192.0.2.10, 2001:db8::10'
  ! validate_panel_ips '0.0.0.0' >/dev/null 2>&1
  ! validate_panel_ips '127.0.0.1' >/dev/null 2>&1
  ! validate_panel_ips '::1' >/dev/null 2>&1
  [[ $(find_matching_ips '2.27.61.13, 193.168.197.139' $'10.0.0.1\n2.27.61.13') == '2.27.61.13' ]]
  [[ -z $(find_matching_ips '193.168.197.139' $'10.0.0.1\n2.27.61.13') ]]
  SSH_CONNECTION= node_ip_addresses >/dev/null
  ! normalize_ips '192.0.2.10/32' 4 >/dev/null 2>&1
  [[ $(clean_ip_input $'2\321.27.61.13' 2>/dev/null) == '2.27.61.13' ]]
  [[ $(clean_port_input $'80,443\321' 2>/dev/null) == '80,443' ]]
  write_rules "$temp" 22 '203.0.113.7/32' '' 6666 '192.0.2.10/32' '' '80, 443' no
  grep -Fq 'policy drop' "$temp"
  grep -Fq 'ct state { established, related }' "$temp"
  grep -Fq 'ip saddr { 192.0.2.10/32 } tcp dport 6666' "$temp"
  grep -Fq 'meta nfproto ipv4 tcp dport { 80, 443 }' "$temp"
  ! grep -Fq 'set public_tcp' "$temp"
  ! grep -Fq 'flush ruleset' "$temp"
  if command -v nft >/dev/null 2>&1 && (( EUID == 0 )); then
    nft -c -f "$temp"
  else
    info "nft -c пропущен (для него нужны nft и root)."
  fi
  ok "Встроенные тесты пройдены."
}

main() {
  local command=${1:-help}
  shift || true
  while (($#)); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --force-conflicts) FORCE_CONFLICTS=1 ;;
      --yes) ASSUME_YES=1 ;;
      --rollback-seconds)
        shift; [[ ${1:-} =~ ^[0-9]+$ ]] || die "Для --rollback-seconds нужно число."
        ROLLBACK_SECONDS=$1
        (( ROLLBACK_SECONDS >= 60 && ROLLBACK_SECONDS <= 1800 )) || die "Окно отката: от 60 до 1800 секунд."
        ;;
      -h|--help) usage; return 0 ;;
      *)
        if [[ "$command" == rollback && -z ${rollback_arg:-} ]]; then rollback_arg=$1
        else die "Неизвестный аргумент: $1"; fi
        ;;
    esac
    shift
  done
  case "$command" in
    apply) cmd_apply ;;
    status) cmd_status ;;
    test) cmd_test ;;
    confirm) cmd_confirm ;;
    rollback) cmd_rollback "${rollback_arg:-}" ;;
    rollback-auto) die "Внутренняя команда не может вызываться с общими опциями." ;;
    load) cmd_load ;;
    self-test) cmd_self_test ;;
    help|-h|--help) usage ;;
    *) die "Неизвестная команда: $command. Используйте --help." ;;
  esac
}

# Внутренние команды принимают позиционный аргумент и вызываются systemd.
if [[ ${1:-} == rollback-auto ]]; then
  shift
  cmd_rollback_auto "${1:-}"
else
  main "$@"
fi
