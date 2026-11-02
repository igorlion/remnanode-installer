#!/usr/bin/env bash
set -Eeuo pipefail

DIR=/opt/remnanode
LOGDIR=/var/log/remnanode
ASSETDIR=/opt/remnawave/xray/share
ZAPRET_URL=https://github.com/kutovoys/ru_gov_zapret/releases/latest/download/zapret.dat
WITH_ZAPRET=false
STAGE=

die() { echo "ОШИБКА: $*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Установка Remnawave Node на чистый Ubuntu/Debian с systemd.
  install-remnanode.sh                Без zapret (по умолчанию)
  install-remnanode.sh --with-zapret  Однократная загрузка zapret, RAM >= 2 GiB
  install-remnanode.sh --help        Эта справка
Таймеры обновления и автоматические перезапуски zapret не создаются.
Существующая установка не изменяется. Скрипт не предназначен для миграции.
HELP
}
parse_args() {
    case "${1:-}" in
        '') ;;
        --with-zapret) WITH_ZAPRET=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "Неизвестный аргумент: $1" ;;
    esac
    (( $# == 0 )) || die 'Лишние аргументы.'
}
check_existing_install() {
    # Check BEFORE apt, systemctl or writes. Refuse partial/legacy installations too.
    local path
    for path in "$DIR" "$ASSETDIR" "$LOGDIR" /etc/logrotate.d/remnanode \
        /usr/local/sbin/update-remnawave-zapret \
        /etc/systemd/system/remnawave-zapret-update.service \
        /etc/systemd/system/remnawave-zapret-update.timer; do
        [[ ! -e "$path" && ! -L "$path" ]] || die "Найдена существующая установка: $path. Требуется отдельная проверка/миграция."
    done
    if command -v docker >/dev/null 2>&1; then
        local names
        names=$(docker ps -a --format '{{.Names}}' 2>/dev/null) || die 'Docker недоступен; сначала проверь существующую установку.'
        if grep -Fxq remnanode <<< "$names"; then
            die 'Контейнер remnanode уже существует. Ничего не изменено.'
        fi
    fi
}
check_zapret_ram() {
    local ram_kib=$1
    [[ "$ram_kib" =~ ^[0-9]+$ ]] || die 'Не удалось определить RAM.'
    (( ram_kib >= 2097152 )) || die 'Для --with-zapret требуется >= 2 GiB RAM. На RU с 870 MiB база ~42 MB привела к OOM.'
}
preflight() {
    (( EUID == 0 )) || die 'Запусти установщик от root (sudo bash).'
    [[ -r /etc/os-release ]] || die 'Не удалось определить ОС.'
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in ubuntu|debian) ;; *) die 'Поддерживаются только Ubuntu/Debian.' ;; esac
    [[ -d /run/systemd/system ]] || die 'Требуется работающий systemd.'
    check_existing_install
    if [[ "$WITH_ZAPRET" == true ]]; then
        local ram_kib
        ram_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
        check_zapret_ram "$ram_kib"
        echo 'ВНИМАНИЕ: 2 GiB не гарантируют отсутствие OOM. Нужен отдельный тест Xray под нагрузкой.'
    fi
}
read_compose() {
    echo 'Вставь docker-compose.yml из панели. Заверши отдельной строкой __END__.'
    local line done=false
    while IFS= read -r line; do
        if [[ "$line" == __END__ ]]; then done=true; break; fi
        printf '%s\n' "$line" >> "$STAGE/docker-compose.yml"
    done </dev/tty
    [[ "$done" == true && -s "$STAGE/docker-compose.yml" ]] || die 'Ввод compose не завершён или пуст.'
    if [[ "$WITH_ZAPRET" == false ]] && grep -qi zapret "$STAGE/docker-compose.yml"; then
        die 'В compose уже упомянут zapret. Для режима без zapret нужен чистый compose из панели.'
    fi
    grep -Eq 'SECRET_KEY[[:space:]]*[=:]' "$STAGE/docker-compose.yml" || die 'SECRET_KEY не найден в compose.'
}
write_override() {
    cat > "$STAGE/docker-compose.override.yml" <<'OVERRIDE'
services:
  remnanode:
    volumes:
      - /var/log/remnanode:/var/log/remnanode
OVERRIDE
    if [[ "$WITH_ZAPRET" == true ]]; then
        cat >> "$STAGE/docker-compose.override.yml" <<'VOLUME'
      - type: bind
        source: /opt/remnawave/xray/share/zapret.dat
        target: /usr/local/bin/zapret.dat
        read_only: true
        bind:
          create_host_path: false
VOLUME
    fi
}
download_zapret() {
    curl --fail --location --silent --show-error --retry 3 \
        --connect-timeout 20 --max-time 300 --max-filesize 104857600 \
        --output "$STAGE/zapret.dat" "$ZAPRET_URL"
    local size
    size=$(stat -c '%s' "$STAGE/zapret.dat")
    (( size >= 100000 && size <= 104857600 )) || die 'Недопустимый размер zapret.dat.'
    echo 'База скачана. Размер не доказывает валидность GeoSite или достаточность RAM.'
}
# Explicit files avoid accidentally loading an unrelated Compose override.
compose() {
    docker compose --project-directory "$DIR" \
        -f "$DIR/docker-compose.yml" -f "$DIR/docker-compose.override.yml" "$@"
}
cleanup() { if [[ -n "$STAGE" ]]; then rm -rf -- "$STAGE"; fi; }
main() {
    parse_args "$@"
    preflight
    umask 077
    STAGE=$(mktemp -d)
    trap cleanup EXIT
    trap 'echo "ОШИБКА: установка прервана на строке $LINENO. Повторный запуск не является откатом; проверь частичную установку." >&2' ERR
    # Read secrets before changing the system, keep staging private.
    read_compose
    export DEBIAN_FRONTEND=noninteractive
    echo '[1/5] Установка зависимостей...'
    apt-get update
    apt-get install -y ca-certificates curl logrotate
    if ! command -v docker >/dev/null 2>&1; then
        # Download fully before executing; do not execute a partial network stream.
        curl -fsSL https://get.docker.com -o "$STAGE/get-docker.sh"
        sh "$STAGE/get-docker.sh"
    fi
    if ! docker compose version >/dev/null 2>&1; then apt-get install -y docker-compose-plugin; fi
    systemctl enable --now docker
    echo '[2/5] Проверка compose...'
    write_override
    # Suppress validation output, which may include secrets from user input.
    docker compose -f "$STAGE/docker-compose.yml" -f "$STAGE/docker-compose.override.yml" \
        config --quiet >/dev/null 2>&1 || die 'Compose не прошёл проверку. Секреты не выведены.'
    local services
    services=$(docker compose -f "$STAGE/docker-compose.yml" \
        -f "$STAGE/docker-compose.override.yml" config --services 2>/dev/null)
    [[ "$services" == remnanode ]] || die 'Compose должен содержать только service remnanode.'
    if [[ "$WITH_ZAPRET" == true ]]; then download_zapret; fi
    echo '[3/5] Сохранение конфигурации...'
    install -d -m 755 "$DIR" "$LOGDIR"
    install -m 600 "$STAGE/docker-compose.yml" "$DIR/docker-compose.yml"
    install -m 600 "$STAGE/docker-compose.override.yml" "$DIR/docker-compose.override.yml"
    if [[ "$WITH_ZAPRET" == true ]]; then
        install -d -m 755 "$ASSETDIR"
        install -m 644 "$STAGE/zapret.dat" "$ASSETDIR/zapret.dat"
    fi
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
    echo '[4/5] Загрузка и запуск контейнера...'
    compose config --quiet >/dev/null 2>&1 || die 'Итоговый Compose не прошёл проверку.'
    compose pull
    compose up -d
    echo '[5/5] Состояние контейнера...'
    compose ps
    echo 'Контейнер запущен. Это ещё не подтверждает работу Xray и клиентского VPN.'
    echo 'Проверь связь с панелью, активные inbounds, порты, память и клиентский выходной IP.'
    if [[ "$WITH_ZAPRET" == true ]]; then
        echo 'zapret.dat подключён однократно. Автообновления и таймера нет.'
        echo 'Правила ext:zapret.dat в Xray не добавлены. Их применение требует отдельной проверки.'
    else
        echo 'Установка без zapret: база, загрузчик и таймер не создавались.'
    fi
    echo "Логи: cd $DIR && docker compose logs --tail=100 -t"
    echo 'Firewall не изменён. Доступ к Node API согласуй отдельно, только с IP панели.'
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
