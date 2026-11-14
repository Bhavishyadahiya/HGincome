#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 1 && -d $1 && -f $1/project/tests/network-fixture.js ]] || {
    printf 'Usage: bash linux-network.sh /absolute/fresh-test-root (with project/tests/network-fixture.js)\n' >&2
    exit 1
}
TEST_ROOT=$(cd -- "$1" && pwd -P)
TEST_ID=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
PREFIX="hgincome-test-$TEST_ID"
LABEL="io.hgincome.test=$TEST_ID"
NETWORK="$PREFIX-network"
TARGET="$PREFIX-target"
PROXY="$PREFIX-proxy"
TUNNEL="$PREFIX-tunnel"
CLIENT="$PREFIX-client"
NETWORK_CREATED=false
declare -a CREATED=()

cleanup() {
    local name owner
    for name in "${CREATED[@]}"; do
        if docker inspect "$name" >/dev/null 2>&1; then
            owner=$(docker inspect --format '{{ index .Config.Labels "io.hgincome.test" }}' "$name")
            [[ $owner == "$TEST_ID" ]] || continue
            docker rm -f "$name" >/dev/null || true
        fi
    done
    if [[ $NETWORK_CREATED == true ]] && docker network inspect "$NETWORK" >/dev/null 2>&1; then
        owner=$(docker network inspect --format '{{ index .Labels "io.hgincome.test" }}' "$NETWORK")
        [[ $owner != "$TEST_ID" ]] || docker network rm "$NETWORK" >/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '=== Create isolated internal Docker network ===\n'
docker network create --internal --label "$LABEL" "$NETWORK" >/dev/null
NETWORK_CREATED=true
FIXTURE="$TEST_ROOT/project/tests/network-fixture.js"
CREATED=("$TARGET" "$PROXY" "$TUNNEL" "$CLIENT")
docker run -d --name "$TARGET" --label "$LABEL" --network "$NETWORK" \
    --mount "type=bind,source=$FIXTURE,target=/fixture.js,readonly" \
    -e TEST_MODE=target node:22-alpine node /fixture.js >/dev/null
TARGET_IP=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$TARGET")
docker run -d --name "$PROXY" --label "$LABEL" --network "$NETWORK" \
    --mount "type=bind,source=$FIXTURE,target=/fixture.js,readonly" \
    -e TEST_MODE=proxy -e "TEST_TARGET_IP=$TARGET_IP" node:22-alpine node /fixture.js >/dev/null
PROXY_IP=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$PROXY")
sleep 2
printf 'nameserver 1.1.1.1\noptions timeout:2 attempts:2\n' > "$TEST_ROOT/resolv.conf"

printf '=== Start actual tun2proxy image with HGincome flags ===\n'
docker run -d --name "$TUNNEL" --label "$LABEL" --network "$NETWORK" \
    --cap-add NET_ADMIN --device /dev/net/tun:/dev/net/tun \
    --sysctl net.ipv6.conf.all.disable_ipv6=1 --sysctl net.ipv6.conf.default.disable_ipv6=1 \
    ghcr.io/tun2proxy/tun2proxy:v0.8.5 --dns over-tcp \
    --proxy "socks5://$PROXY_IP:1080" --verbosity info >/dev/null
sleep 2
docker logs "$TUNNEL"
[[ $(docker inspect --format '{{.State.Status}}' "$TUNNEL") == running ]]

docker run -d --name "$CLIENT" --label "$LABEL" --network "container:$TUNNEL" \
    --mount "type=bind,source=$TEST_ROOT/resolv.conf,target=/etc/resolv.conf,readonly" \
    alpine:3.22 sleep 300 >/dev/null
printf '=== Interface and route setup ===\n'
docker exec "$CLIENT" ip address show
docker exec "$CLIENT" ip route
printf '=== Proxied HTTP with numeric destination ===\n'
RESPONSE=$(docker exec "$CLIENT" wget -T 8 -qO- http://198.51.100.42:8080/)
[[ $RESPONSE == 'HGincome isolated routing test OK' ]]
printf '%s\n' "$RESPONSE"
printf '=== TCP-forwarded DNS and proxied HTTP by name ===\n'
RESPONSE=$(docker exec "$CLIENT" wget -T 8 -qO- http://hgincome-test.invalid:8080/)
[[ $RESPONSE == 'HGincome isolated routing test OK' ]]
printf '%s\n' "$RESPONSE"
printf '=== Proxy requests ===\n'
docker logs "$PROXY"
printf '=== DNS fixture requests ===\n'
docker logs "$TARGET"
printf '=== Manual dependency-ordered restart ===\n'
docker stop "$CLIENT" >/dev/null
docker stop "$TUNNEL" >/dev/null
docker start "$TUNNEL" >/dev/null
sleep 2
docker start "$CLIENT" >/dev/null
RESPONSE=$(docker exec "$CLIENT" wget -T 8 -qO- http://hgincome-test.invalid:8080/)
[[ $RESPONSE == 'HGincome isolated routing test OK' ]]
printf 'PASS: route setup, numeric HTTP, DNS-over-TCP, hostname HTTP, and manual pair restart.\n'
