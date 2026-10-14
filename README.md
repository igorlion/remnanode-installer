# Remnawave Node Installer

Однокомандная установка Remnawave Node на чистый Ubuntu/Debian-сервер с Docker, ротацией логов и автоматическим обновлением `zapret.dat`.

## Быстрый запуск

```bash
curl -fsSL https://raw.githubusercontent.com/igorlion/remnanode-installer/main/install-remnanode.sh | sudo bash
```

Во время установки:

1. Скопируй уникальный `docker-compose.yml` ноды из панели Remnawave.
2. Вставь его в терминал целиком.
3. На новой строке введи `__END__` и нажми Enter.

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

После установки скрипт покажет обнаруженный `NODE_PORT`. Разреши подключение к нему только с IP панели:

```bash
ufw insert 1 allow from PANEL_IP to any port NODE_PORT proto tcp
ufw deny NODE_PORT/tcp
```

Перед включением UFW обязательно разреши свой SSH-порт и остальные необходимые сервисы.

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
