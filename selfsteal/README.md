# Selfsteal для Remnawave / Xray Reality

Скрипт настраивает Caddy как локальную HTTPS-цель для Reality:

- Xray продолжает слушать публичный TCP `443`;
- Caddy слушает публичный TCP `80` для ACME HTTP-01 и перенаправления на HTTPS;
- Caddy слушает только `127.0.0.1:8443` для Reality `target`;
- HTTP/3 отключён, поэтому Caddy не открывает UDP `8443`;
- сертификат выпускается без временного освобождения порта `443`.

## Перед запуском

1. Создайте A-запись домена на публичный IPv4 ноды.
2. Откройте публичный TCP `80` в firewall.
3. TCP `443` можно не освобождать: его может уже слушать Xray.
4. Если у домена есть AAAA-запись, она должна указывать на IPv6 этой же ноды.

## Установка

```bash
curl -fsSL \
  https://raw.githubusercontent.com/igorlion/remnanode-installer/main/selfsteal/install-selfsteal.sh \
  -o /tmp/install-selfsteal.sh

sudo bash /tmp/install-selfsteal.sh
```

Обычный запуск спрашивает только домен. Публичный IPv4 определяется автоматически и сверяется с DNS.

Неинтерактивный запуск:

```bash
sudo bash /tmp/install-selfsteal.sh \
  --domain brr1.example.com \
  --expected-ip 203.0.113.10
```

После успешной установки повторно запустить настройку можно командой:

```bash
sudo remnawave-selfsteal
```

Сохранённый домен будет использован автоматически.

## Настройка Reality

В серверном профиле Xray:

```json
{
  "realitySettings": {
    "target": "127.0.0.1:8443",
    "serverNames": [
      "brr1.example.com"
    ]
  }
}
```

Домен в `serverNames` должен совпадать с доменом, переданным скрипту. В клиентском Host/SNI используется тот же домен.

## Защита от ошибок

- проверяются DNS, A/AAAA-записи и публичный IPv4;
- чужой Caddyfile не заменяется без явного `--force`;
- занятые не-Caddy процессом порты `80` и `8443` приводят к остановке;
- конфигурация проходит `caddy validate` до установки;
- при ошибке прежние Caddyfile и страница восстанавливаются;
- резервные копии хранятся в `/var/lib/remnawave-selfsteal/backups`.

Локальная проверка кода, не меняющая сервер:

```bash
bash -n selfsteal/install-selfsteal.sh
bash selfsteal/install-selfsteal.sh self-test
bash selfsteal/tests/test-install-selfsteal.sh
```
