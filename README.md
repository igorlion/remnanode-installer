# Remnawave Node Installer

Однокомандная установка Remnawave Node на чистый Ubuntu/Debian-сервер с Docker, ротацией логов и автоматическим обновлением `zapret.dat`.

## Установка по шагам

### 1. Подготовь ноду в панели Remnawave

1. Создай новую ноду в панели Remnawave.
2. Укажи IP-адрес или домен нового сервера и нужный порт.
3. Сохрани ноду.
4. Открой выданный панелью уникальный `docker-compose.yml` и скопируй его целиком.

У каждой ноды свой `SECRET_KEY`, поэтому нельзя использовать compose от другой ноды.

### 2. Подключись к новому серверу

Подключись к чистому Ubuntu/Debian-серверу по SSH под `root` или пользователем с `sudo`.

Установщик предназначен именно для сервера ноды. Не запускай его на сервере, где установлена панель Remnawave.

### 3. Запусти установщик

```bash
curl -fsSL https://raw.githubusercontent.com/igorlion/remnanode-installer/main/install-remnanode.sh | sudo bash
```

Дождись приглашения вставить compose. Затем:

1. Скопируй уникальный `docker-compose.yml` ноды из панели Remnawave.
2. Вставь его в терминал целиком.
3. Нажми Enter, чтобы курсор оказался на новой строке.
4. Введи `__END__` и ещё раз нажми Enter.

Пример окончания вставки:

```text
    restart: always
__END__
```

Строка `__END__` не попадёт в compose — она только сообщает установщику, что вставка закончена.

### 4. Дождись завершения

Установщик проверит compose, скачает образ и запустит контейнер. В конце должно появиться:

```text
REMNAWAVE NODE УСТАНОВЛЕНА
```

После этого вернись в панель Remnawave и проверь, что нода перешла в состояние подключения. Обычно это занимает несколько секунд.

### 5. Если нода не подключилась

Посмотри состояние контейнера и последние логи:

```bash
cd /opt/remnanode
docker compose ps
docker compose logs --tail=100 -t
```

Также проверь, что `NODE_PORT` разрешён в firewall сервера и доступен с IP панели.

### 6. Включи маршрутизацию через zapret.dat

Файл `zapret.dat` устанавливается и обновляется автоматически, но сам по себе маршрутизацию не меняет. Чтобы использовать его, добавь категории из раздела [«Использование zapret.dat в профиле Xray»](#использование-zapretdat-в-профиле-xray) в нужное правило маршрутизации профиля Xray.

Секреты из compose вводятся только на сервере и не отправляются в этот репозиторий.

## Что делает установщик

- устанавливает Docker Engine и Compose plugin;
- проверяет уникальный compose перед сохранением;
- запускает Remnawave Node;
- подключает каталог Xray-логов и настраивает `logrotate`;
- загружает актуальный `zapret.dat` из проекта [`kutovoys/ru_gov_zapret`](https://github.com/kutovoys/ru_gov_zapret);
- обновляет `zapret.dat` каждый день через systemd timer;
- перезапускает контейнер только когда файл действительно изменился;
- не перезаписывает существующий `/opt/remnanode/docker-compose.yml`.

## Использование zapret.dat в профиле Xray

Добавь доменные категории в правило маршрутизации. `outboundTag` замени на тег нужного outbound из своего профиля:

```json
{
  "type": "field",
  "domain": [
    "ext:zapret.dat:zapret",
    "ext:zapret.dat:zapret-zapad"
  ],
  "outboundTag": "YOUR_OUTBOUND_TAG"
}
```

Это GeoSite-файл: значения `ext:zapret.dat:...` нужно помещать в поле `domain`, а не `ip`.

## Firewall

Для Ubuntu подготовлен отдельный интерактивный nftables-firewall. В обычном режиме он спрашивает только исходящий IP панели и при необходимости данные RU-моста. Порт Node API определяется из контейнера, рабочие значения повторно не запрашиваются, а после применения ставится автоматический SSH-safe rollback.

```bash
curl -fsSL https://raw.githubusercontent.com/igorlion/remnanode-installer/main/firewall/remnawave-firewall.sh -o /tmp/remnawave-firewall.sh
chmod +x /tmp/remnawave-firewall.sh
sudo /tmp/remnawave-firewall.sh apply
```

После применения не закрывай первую SSH-сессию: открой второе новое соединение и только после проверки введи `CONFIRM`. Полная инструкция: [firewall/README.md](firewall/README.md).

Для нестандартного SSH-доступа, других публичных портов, ручного IPv6 или нескольких адресных правил используй `apply --advanced`.

## Selfsteal для Reality

Отдельный скрипт устанавливает Caddy как локальную HTTPS-цель `127.0.0.1:8443`. Сертификат выпускается через публичный TCP `80`, поэтому Xray может всё время продолжать слушать TCP `443`:

```bash
curl -fsSL https://raw.githubusercontent.com/igorlion/remnanode-installer/main/selfsteal/install-selfsteal.sh -o /tmp/install-selfsteal.sh
sudo bash /tmp/install-selfsteal.sh
```

После установки укажи в Reality `target: 127.0.0.1:8443`, а домен Selfsteal используй в `serverNames` и клиентском SNI. Полная инструкция: [selfsteal/README.md](selfsteal/README.md).

## Полезные команды

```bash
# Состояние контейнера
cd /opt/remnanode && docker compose ps

# Логи контейнера
cd /opt/remnanode && docker compose logs -f -t

# Обновить ноду
cd /opt/remnanode && docker compose pull && docker compose up -d

# Обновить zapret.dat вручную
sudo /usr/local/sbin/update-remnawave-zapret

# Проверить таймер обновления
systemctl status remnawave-zapret-update.timer
```

## Требования

- чистый сервер Ubuntu или Debian с systemd;
- доступ `root`/`sudo`;
- созданная в панели Remnawave нода и её уникальный compose;
- исходящие HTTPS-соединения с GitHub и Docker registry.

## Документация

- [Установка Remnawave Node](https://docs.rw/install/remnawave-node/)
- [Маршрутизация заблокированных ресурсов](https://docs.rw/learn/zapret-ru-gov/)

## Лицензия

[MIT](LICENSE)

