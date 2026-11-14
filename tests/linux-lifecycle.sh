#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 1 && -d $1 && -f $1/project/HGincome.sh && -f $1/project/properties.conf ]] || {
    printf 'Usage: bash linux-lifecycle.sh /absolute/fresh-test-root (with project/HGincome.sh and properties.conf)\n' >&2
    exit 1
}
TEST_ROOT=$(cd -- "$1" && pwd -P)
PROJECT="$TEST_ROOT/project"
TEST_ID=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
CASE_DIR="$TEST_ROOT/lifecycle-$TEST_ID"
APP_IMAGE="hgincome-test/$TEST_ID:sleeper"
TUN_IMAGE="hgincome-test/$TEST_ID:tunnel"
INSTANCE=''

cleanup() {
    if [[ -n $INSTANCE ]]; then
        local names name
        names=$(docker ps -a --filter "label=io.hgincome.instance=$INSTANCE" --format '{{.Names}}') || return
        while IFS= read -r name; do
            [[ -z $name ]] || docker rm -f "$name" >/dev/null || true
        done <<< "$names"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ ! -e $CASE_DIR ]]
mkdir -p "$CASE_DIR/proxies" "$CASE_DIR/.hgincome" "$TEST_ROOT/sleeper-build-$TEST_ID" "$TEST_ROOT/tunnel-build-$TEST_ID"
cp "$PROJECT/HGincome.sh" "$CASE_DIR/HGincome.sh"
cp "$PROJECT/properties.conf" "$CASE_DIR/properties.conf"
INSTANCE=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
printf '%s\n' "$INSTANCE" > "$CASE_DIR/.hgincome/instance-id"
# Ignore Honeygain credentials while keeping its full container invocation intact.
printf 'FROM alpine:3.22\nENTRYPOINT ["/bin/sh", "-c", "exec sleep 900", "--"]\n' > "$TEST_ROOT/sleeper-build-$TEST_ID/Dockerfile"
printf 'FROM ghcr.io/tun2proxy/tun2proxy:v0.8.5\nENTRYPOINT ["/usr/bin/tun2proxy-bin", "--setup", "--tun", "tun0"]\n' > "$TEST_ROOT/tunnel-build-$TEST_ID/Dockerfile"
docker build --pull=false -t "$APP_IMAGE" "$TEST_ROOT/sleeper-build-$TEST_ID" >/dev/null
docker build --pull=false -t "$TUN_IMAGE" "$TEST_ROOT/tunnel-build-$TEST_ID" >/dev/null
printf '\nHONEYGAIN_IMAGE=%q\nTUN2PROXY_IMAGE=%q\nACCEPT_TOU=true\nRESTART_POLICY=no\n' "$APP_IMAGE" "$TUN_IMAGE" >> "$CASE_DIR/properties.conf"
{
    printf 'ACCOUNT_IDS=(personal second)\n'
    printf 'ACCOUNT_EMAIL[personal]=personal@example.invalid\nACCOUNT_PASSWORD[personal]=synthetic-password\n'
    printf 'ACCOUNT_EMAIL[second]=second@example.invalid\nACCOUNT_PASSWORD[second]=synthetic-password\n'
} > "$CASE_DIR/accounts.conf"
# Documentation-only addresses. No proxy connections or Honeygain logins are made.
for i in {1..10}; do printf 'socks5://192.0.2.%s:1080\n' "$i"; done > "$CASE_DIR/proxies/personal.txt"
for i in {11..20}; do printf 'socks5://198.51.100.%s:1080\n' "$i"; done > "$CASE_DIR/proxies/second.txt"

run() { bash "$CASE_DIR/HGincome.sh" "$@"; }
count() {
    docker ps -a --filter "label=io.hgincome.instance=$INSTANCE" --format '{{.Names}}' | wc -l
}

printf '=== Real Docker: two accounts, ten slots each ===\n'
run --check
run --start
[[ $(count) == 40 ]]
printf '=== Idempotent startup ===\n'
run --start
[[ $(count) == 40 ]]
printf '=== Account-specific status and logs ===\n'
run --status --account personal
run --logs --account personal --device 1 --tunnel --tail 5
printf '=== Account-specific stop and restart ===\n'
run --stop --account personal
[[ $(docker inspect --format '{{.State.Status}}' "hgincome-$INSTANCE-personal-01") == exited ]]
[[ $(docker inspect --format '{{.State.Status}}' "hgincome-$INSTANCE-second-01") == running ]]
run --restart --account personal
[[ $(docker inspect --format '{{.State.Status}}' "hgincome-$INSTANCE-personal-01") == running ]]
printf '=== Account deletion and stable recreation ===\n'
run --delete --account personal --yes
[[ $(count) == 20 ]]
run --start --account personal
[[ $(count) == 40 ]]
[[ $(<"$CASE_DIR/.hgincome/instance-id") == "$INSTANCE" ]]
printf '=== Remove only this test instance ===\n'
run --delete --yes
[[ $(count) == 0 ]]
printf 'PASS: real Docker lifecycle for two accounts / 20 slots / 40 containers. No Honeygain logins.\n'
