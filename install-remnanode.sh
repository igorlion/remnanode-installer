#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID != 0 )); then
    echo "ОШИБКА: запусти установщик от root (например, через sudo bash)." >&2
    exit 1
fi

trap 'echo "ОШИБКА: установка прервана на строке $LINENO." >&2' ERR

DIR="/opt/remnanode"
LOGDIR="/var/log/remnanode"
ASSETDIR="/opt/remnawave/xray/share"
COMPOSE="$DIR/docker-compose.yml"
OVERRIDE="$DIR/docker-compose.override.yml"
ZAPRET_URL="https://github.com/kutovoys/ru_gov_zapret/releases/latest/download/zapret.dat"

export DEBIAN_FRONTEND=noninteractive

echo "[1/7] Установка Docker и необходимых пакетов..."
apt-get update
apt-get install -y ca-certificates curl logrotate

if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
fi

if ! docker compose version >/dev/null 2>&1; then
    apt-get install -y docker-compose-plugin
fi

systemctl enable --now docker
install -d -m 755 "$DIR" "$LOGDIR" "$ASSETDIR"

if [[ -f "$COMPOSE" ]]; then
    echo "ОШИБКА: $COMPOSE уже существует. Ничего не перезаписываю."
    exit 1
fi

echo "[2/7] Установка загрузчика и обновления zapret.dat..."

cat > /usr/local/sbin/update-remnawave-zapret <<UPDATER
#!/usr/bin/env bash
set -Eeuo pipefail

URL="$ZAPRET_URL"
DEST="$ASSETDIR/zapret.dat"
TMP="\$(mktemp "$ASSETDIR/.zapret.dat.XXXXXX")"
trap 'rm -f "\$TMP"' EXIT

curl --fail --location --silent --show-error \
    --retry 3 --retry-delay 3 --connect-timeout 20 --max-time 300 \
    --output "\$TMP" "\$URL"

SIZE="\$(stat -c '%s' "\$TMP")"
if (( SIZE < 100000 )); then
    echo "Ошибка: скачанный zapret.dat подозрительно маленький: \$SIZE байт." >&2
    exit 1
fi

if [[ -f "\$DEST" ]] && cmp -s "\$TMP" "\$DEST"; then
    echo "zapret.dat уже актуален."
    exit 0
fi

chmod 644 "\$TMP"
mv -f "\$TMP" "\$DEST"
trap - EXIT
echo "zapret.dat обновлён: \$SIZE байт."

if docker ps --format '{{.Names}}' | grep -Fxq remnanode; then
    cd "$DIR"
    docker compose restart remnanode
fi
UPDATER

chmod 755 /usr/local/sbin/update-remnawave-zapret
/usr/local/sbin/update-remnawave-zapret

cat > /etc/systemd/system/remnawave-zapret-update.service <<'SERVICE'
[Unit]
Description=Update Remnawave zapret.dat
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/update-remnawave-zapret
SERVICE

cat > /etc/systemd/system/remnawave-zapret-update.timer <<'TIMER'
[Unit]
Description=Daily update of Remnawave zapret.dat

[Timer]
OnCalendar=*-*-* 04:17:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now remnawave-zapret-update.timer

TMP_COMPOSE="$(mktemp)"
trap 'rm -f "$TMP_COMPOSE"' EXIT

echo
echo "======================================================"
echo "Скопируй docker-compose.yml из панели Remnawave"
echo "и вставь его сюда целиком."
echo
echo "После compose на новой строке напиши: __END__"
echo "======================================================"
echo

COMPOSE_DONE=false
while IFS= read -r line; do
    if [[ "$line" == "__END__" ]]; then
        COMPOSE_DONE=true
        break
    fi
    printf '%s\n' "$line" >> "$TMP_COMPOSE"
done </dev/tty

if [[ "$COMPOSE_DONE" != true ]]; then
    echo "ОШИБКА: ввод прерван до строки __END__." >&2
    exit 1
fi

if [[ ! -s "$TMP_COMPOSE" ]]; then
    echo "ОШИБКА: compose получился пустым."
    exit 1
fi

if ! grep -Eq 'SECRET_KEY[=:]' "$TMP_COMPOSE"; then
    echo "ОШИБКА: SECRET_KEY не найден. Возможно, compose вставлен не полностью."
    exit 1
fi

echo "[3/7] Проверка docker-compose.yml..."
docker compose -f "$TMP_COMPOSE" config --quiet
install -m 600 "$TMP_COMPOSE" "$COMPOSE"

echo "[4/7] Подключение zapret.dat и каталогов логов..."

cat > "$OVERRIDE" <<'OVERRIDE'
services:
  remnanode:
    volumes:
      - /var/log/remnanode:/var/log/remnanode
      - /opt/remnawave/xray/share/zapret.dat:/usr/local/bin/zapret.dat:ro
OVERRIDE

chmod 600 "$OVERRIDE"

cat > /etc/logrotate.d/remnanode <<'LOGROTATE'
/var/log/remnanode/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
LOGROTATE

chmod 644 /etc/logrotate.d/remnanode
logrotate -d /etc/logrotate.d/remnanode >/dev/null 2>&1

echo "[5/7] Полная проверка конфигурации..."
cd "$DIR"
docker compose config --quiet

echo "[6/7] Загрузка и запуск Remnawave Node..."
docker compose pull
docker compose up -d

echo "[7/7] Проверка состояния..."
docker compose ps

NODE_PORT="$(
    grep -Eo 'NODE_PORT[=:][[:space:]]*"?[0-9]+' "$COMPOSE" |
    grep -Eo '[0-9]+' |
    head -n1 || true
)"

echo
echo "======================================================"
echo "REMNAWAVE NODE УСТАНОВЛЕНА"
echo "======================================================"
echo "zapret.dat: $ASSETDIR/zapret.dat"
echo "Таймер обновления: systemctl status remnawave-zapret-update.timer"
echo "Логи контейнера: cd $DIR && docker compose logs -f -t"
echo "Xray-логи: tail -F $LOGDIR/access.log $LOGDIR/error.log"

if [[ -n "$NODE_PORT" ]]; then
    echo
    echo "NODE_PORT: $NODE_PORT"
    echo "Разреши его только для IP панели:"
    echo "ufw insert 1 allow from IP_ПАНЕЛИ to any port $NODE_PORT proto tcp"
    echo "ufw deny $NODE_PORT/tcp"
fi

echo
echo "В профиле Xray используй:"
echo "  ext:zapret.dat:zapret"
echo "  ext:zapret.dat:zapret-zapad"
