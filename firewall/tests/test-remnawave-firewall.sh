#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script="${repo_dir}/remnawave-firewall.sh"

bash -n "$script"
bash "$script" self-test

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$script"
else
  printf '%s\n' '[INFO] shellcheck не найден — статическая проверка пропущена.'
fi

printf '%s\n' '[ OK ] Все доступные локальные тесты пройдены; firewall не изменялся.'
