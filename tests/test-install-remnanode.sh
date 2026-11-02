#!/usr/bin/env bash
# Runs only helpers with local fixtures. Never installs packages or starts Docker.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT/install-remnanode.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT
STAGE="$TEST_DIR/stage"
mkdir "$STAGE"
fail() { echo "FAIL: $*" >&2; exit 1; }
WITH_ZAPRET=false
write_override
! grep -qi zapret "$STAGE/docker-compose.override.yml" || fail 'Default mount includes zapret'
WITH_ZAPRET=true
write_override
grep -q 'create_host_path: false' "$STAGE/docker-compose.override.yml" || fail 'Missing safe bind'
grep -q 'target: /usr/local/bin/zapret.dat' "$STAGE/docker-compose.override.yml" || fail 'Wrong target'
# Linux stat fixture, network download fixture; no real network access.
stat() { wc -c < "${@: -1}" | tr -d ' '; }
curl() {
    local output=
    while (( $# )); do
        if [[ "$1" == --output ]]; then output=$2; shift 2; else shift; fi
    done
    head -c "$TEST_SIZE" /dev/zero > "$output"
}
TEST_SIZE=200000
download_zapret >/dev/null
TEST_SIZE=42
if (download_zapret >/dev/null 2>&1); then fail 'Small download accepted'; fi
# Existing install must be refused BEFORE any installed-command checks or writes.
DIR="$TEST_DIR/existing"; mkdir "$DIR"
for cmd in apt-get systemctl docker install; do
    eval "$cmd() { echo forbidden >> \"\$TEST_DIR/mutations\"; return 1; }"
done
if (check_existing_install >/dev/null 2>&1); then fail 'Existing installation accepted'; fi
[[ ! -e "$TEST_DIR/mutations" ]] || fail 'Command ran before existing-install check'
check_zapret_ram 2097152
for ram in 890880 2097151 invalid ''; do
    if (check_zapret_ram "$ram" >/dev/null 2>&1); then fail "RAM accepted: $ram"; fi
done
# Check argument handling in subshells because --help/invalid exit intentionally.
("$BASH" "$ROOT/install-remnanode.sh" --help) >/dev/null
if (parse_args --unknown >/dev/null 2>&1); then fail 'Unknown option accepted'; fi
if (parse_args --with-zapret extra >/dev/null 2>&1); then fail 'Extra argument accepted'; fi
# Verify Compose wrapper always specifies both files.
docker() { printf '%s\n' "$@" > "$TEST_DIR/compose-args"; }
compose config --quiet
grep -Fxq "$DIR/docker-compose.override.yml" "$TEST_DIR/compose-args" || fail 'Missing explicit override'
echo 'PASS: default/optional mounts, download rejection, arguments, Compose files'
