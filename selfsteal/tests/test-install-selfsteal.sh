#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script="${repo_dir}/install-selfsteal.sh"

bash -n "$script"
bash "$script" self-test

grep -Fq 'disable_tlsalpn_challenge' "$script"
grep -Fq 'protocols h1 h2' "$script"
grep -Fq 'bind 127.0.0.1' "$script"
grep -Fq 'caddy fmt --overwrite' "$script"
! grep -Fq 'systemctl stop remnanode' "$script"
! grep -Fq 'dport 443' "$script"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$script"
else
  printf '%s\n' '[INFO] shellcheck не найден - статическая проверка пропущена.'
fi

printf '%s\n' '[ OK ] Все доступные тесты Selfsteal пройдены; система не изменялась.'
