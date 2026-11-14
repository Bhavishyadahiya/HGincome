#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/hgincome-tests.XXXXXX")
chmod 700 "$TEST_DIR"
# Keep fixtures for inspection. They contain synthetic credentials only.
printf 'Isolated test directory: %s\n' "$TEST_DIR"
cp "$ROOT/tests/mock-docker.sh" "$TEST_DIR/docker"
chmod +x "$TEST_DIR/docker"
export MOCK_DOCKER_STATE="$TEST_DIR/docker-state"
mkdir "$MOCK_DOCKER_STATE"
CASE_DIR="$TEST_DIR/project with spaces"
mkdir -p "$CASE_DIR/proxies"
cp "$ROOT/properties.conf" "$CASE_DIR/properties.conf"
printf '\nDOCKER_BIN=%q\nACCEPT_TOU=true\n' "$TEST_DIR/docker" >> "$CASE_DIR/properties.conf"
PASS=0
OUTPUT=''

run() { bash "$ROOT/tests/driver.sh" "$ROOT/HGincome.sh" "$CASE_DIR" "$@"; }
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$*"; }
expect_ok() {
    local description=$1
    shift
    if ! OUTPUT=$(run "$@" 2>&1); then
        printf 'FAIL %s\n%s\n' "$description" "$OUTPUT" >&2
        exit 1
    fi
    pass "$description"
}
expect_fail() {
    local description=$1 text=$2
    shift 2
    if OUTPUT=$(run "$@" 2>&1); then
        printf 'FAIL %s: unexpectedly succeeded\n' "$description" >&2
        exit 1
    fi
    [[ $OUTPUT == *"$text"* ]] || { printf 'FAIL %s\n%s\n' "$description" "$OUTPUT" >&2; exit 1; }
    pass "$description"
}
records() {
    local file count=0
    for file in "$MOCK_DOCKER_STATE"/*.record; do
        [[ ! -f $file ]] || count=$((count + 1))
    done
    printf '%s\n' "$count"
}
config_two_accounts() {
    {
        printf 'ACCOUNT_IDS=(personal second)\n'
        printf 'ACCOUNT_EMAIL[personal]=%q\n' 'personal@example.invalid'
        printf 'ACCOUNT_PASSWORD[personal]=%q\n' 'p a$$ ! "quote" * [glob] apostrophe '\'' end'
        printf 'ACCOUNT_EMAIL[second]=%q\n' 'second@example.invalid'
        printf 'ACCOUNT_PASSWORD[second]=%q\n' 'second-password'
        printf 'ACCOUNT_NETWORK[personal]=proxy\nACCOUNT_NETWORK[second]=proxy\n'
    } > "$CASE_DIR/accounts.conf"
    local i
    for i in {1..10}; do
        printf 'socks5h://proxy-user:proxy-password@192.0.2.%s:1080\r\n' "$i"
    done > "$CASE_DIR/proxies/personal.txt"
    for i in {11..20}; do
        printf 'http://198.51.100.%s:8080\n' "$i"
    done > "$CASE_DIR/proxies/second.txt"
}

expect_ok 'help works without account configuration' --help
expect_fail 'multiple commands rejected' 'exactly one' --start --stop
expect_fail 'missing option value rejected' 'Missing value' --account
expect_fail 'invalid account IDs rejected' 'Account IDs' --check --account 'Bad/ID'
expect_fail 'logs require both selectors' 'requires --account' --logs --account personal
expect_fail 'invalid log device rejected' 'must be 1–10' --logs --account personal --device 11
expect_fail 'tail outside logs rejected' 'only for --logs' --check --tail 5
expect_fail 'yes outside deletion rejected' 'only for --delete' --start --yes
expect_fail 'pull account selector rejected' 'does not take --account' --pull --account personal
expect_ok 'status before initial state is harmless' --status

printf 'ACCOUNT_IDS=()\n' > "$CASE_DIR/accounts.conf"
expect_fail 'empty configuration fails clearly' 'No accounts configured' --check
config_two_accounts
expect_ok 'two accounts validate with 10 slots each, CRLF and proxy normalization' --check
[[ $OUTPUT == *'20 selected device slots'* ]] || exit 1
expect_ok 'account selection validates 10 selected slots' --check --account second
[[ $OUTPUT == *'10 selected device slots'* ]] || exit 1
expect_fail 'unknown configured account rejected' 'Unknown account' --check --account missing
printf 'ACCOUNT_DEVICES[second]=11\n' >> "$CASE_DIR/accounts.conf"
expect_fail 'hard maximum of 10 enforced' 'must request 1–10' --check
config_two_accounts
cp "$CASE_DIR/proxies/personal.txt" "$CASE_DIR/proxies/second.txt"
expect_fail 'duplicate endpoints across accounts rejected' 'already assigned' --check
config_two_accounts
printf 'socks5://user:secret-proxy-value@host:99999\n' > "$CASE_DIR/proxies/second.txt"
expect_fail 'bad proxy port rejected without exposing credentials' 'URL hidden' --check
[[ $OUTPUT != *secret-proxy-value* ]] || exit 1
config_two_accounts
printf 'https://user:secret-proxy-value@host.example:443\n' > "$CASE_DIR/proxies/second.txt"
expect_fail 'HTTPS proxy scheme rejected to match verified tunnel CLI' 'URL hidden' --check
[[ $OUTPUT != *secret-proxy-value* ]] || exit 1
config_two_accounts
printf 'http://198.51.100.50:8080\n' > "$CASE_DIR/proxies/second.txt"
expect_fail 'insufficient proxies rejected' 'needs 10 proxies but has 1' --check
config_two_accounts
printf 'ACCEPT_TOU=false\n' >> "$CASE_DIR/properties.conf"
expect_fail 'terms require explicit configuration approval' 'ACCEPT_TOU=true' --start
printf 'ACCEPT_TOU=true\n' >> "$CASE_DIR/properties.conf"
if [[ ! -c /dev/net/tun ]]; then
    expect_fail 'real proxy startup refuses unavailable Linux TUN device' '/dev/net/tun' --start
fi

expect_ok 'mock creates 20 apps and 20 tunnels for two accounts' --test-pairs
[[ $(records) == 40 ]] || exit 1
instance=$(<"$CASE_DIR/.hgincome/instance-id")
app="hgincome-$instance-personal-01"
(
    declare -A LABELS=()
    declare -a ARGS=()
    source "$MOCK_DOCKER_STATE/$app.record"
    found=false
    for ((i=0; i<${#ARGS[@]}; i++)); do
        if [[ ${ARGS[$i]} == -pass ]]; then
            [[ ${ARGS[$((i+1))]} == 'p a$$ ! "quote" * [glob] apostrophe '\'' end' ]] || exit 1
            found=true
        fi
    done
    [[ $found == true && ${LABELS[io.hgincome.account]} == personal ]] || exit 1
    [[ " ${ARGS[*]} " == *" --network container:$app-tun "* ]] || exit 1
)
pass 'password metacharacters preserved as one argument and correct tunnel namespace selected'
[[ $OUTPUT != *'p a$$'* && $OUTPUT != *proxy-password* ]] || exit 1
pass 'startup output excludes credentials and proxy URLs'
expect_ok 'starting again reuses the same 40 containers' --test-pairs
[[ $(records) == 40 && $(<"$CASE_DIR/.hgincome/instance-id") == "$instance" ]] || exit 1
expect_ok 'status works for selected account' --status --account personal
[[ $OUTPUT == *personal* && $OUTPUT != *second* ]] || exit 1
expect_ok 'device logs accept zero-padded slot and tail=0' --logs --account personal --device 01 --tail 0
expect_ok 'tunnel logs target paired tunnel' --logs --account personal --device 1 --tunnel
[[ $OUTPUT == *"$app-tun"* ]] || exit 1

before=$(wc -l < "$MOCK_DOCKER_STATE/actions")
printf 'ACCOUNT_PASSWORD[personal]=changed-password\n' >> "$CASE_DIR/accounts.conf"
expect_fail 'credential changes refuse stale containers before mutation' 'Configuration changed' --test-pairs --account personal
[[ $(wc -l < "$MOCK_DOCKER_STATE/actions") == "$before" ]] || exit 1
config_two_accounts
printf 'ACCOUNT_DEVICES[personal]=1\n' >> "$CASE_DIR/accounts.conf"
expect_fail 'reduced slot count lists leftovers and refuses startup' 'outside the desired configuration' --test-pairs --account personal
config_two_accounts
printf 'ACCOUNT_IDS=(personal)\n' >> "$CASE_DIR/accounts.conf"
expect_fail 'removed account is detected on full-folder startup' 'outside the desired configuration' --test-pairs
config_two_accounts
export MOCK_FAIL_KIND=true
expect_fail 'restart aborts on container kind inspection failure' 'Cannot inspect' --restart --account personal
unset MOCK_FAIL_KIND
printf 'TUN2PROXY_DNS_MODE=invalid\nDEVICES_PER_ACCOUNT=bad\n' >> "$CASE_DIR/properties.conf"
expect_ok 'management remains usable with invalid creation properties' --status --account personal
printf 'TUN2PROXY_DNS_MODE=over-tcp\nDEVICES_PER_ACCOUNT=10\n' >> "$CASE_DIR/properties.conf"
mkdir "$CASE_DIR/.hgincome/lock"
expect_fail 'concurrent mutation lock is enforced' 'Another HGincome' --stop
rmdir "$CASE_DIR/.hgincome/lock"
printf 'TUNNEL_START_TIMEOUT=0\n' >> "$CASE_DIR/properties.conf"
before=$(wc -l < "$MOCK_DOCKER_STATE/actions")
expect_fail 'restart validates timeout before stopping containers' 'TUNNEL_START_TIMEOUT must be' --restart --account personal
[[ $(wc -l < "$MOCK_DOCKER_STATE/actions") == "$before" ]] || exit 1
printf 'TUNNEL_START_TIMEOUT=20\n' >> "$CASE_DIR/properties.conf"
expect_ok 'stop only selected account' --stop --account personal
(
    declare -A LABELS=(); declare -a ARGS=()
    source "$MOCK_DOCKER_STATE/$app.record"
    [[ $STATUS == exited ]]
    source "$MOCK_DOCKER_STATE/hgincome-$instance-second-01.record"
    [[ $STATUS == running ]]
)
pass 'account stop leaves other account running'
expect_ok 'restart selected account stops apps first and starts tunnels first' --restart --account personal
mapfile -t actions < "$MOCK_DOCKER_STATE/actions"
last=$((${#actions[@]} - 40))
[[ ${actions[$last]} == "stop hgincome-$instance-personal-01" && ${actions[$((last+20))]} == "start hgincome-$instance-personal-01-tun" ]] || exit 1
expect_fail 'noninteractive delete requires explicit yes' 'requires --yes' --delete --account personal
expect_ok 'delete selected account removes apps and tunnels only' --delete --account personal --yes
[[ $(records) == 20 && -f "$CASE_DIR/accounts.conf" && $(<"$CASE_DIR/.hgincome/instance-id") == "$instance" ]] || exit 1
expect_ok 'recreation preserves device and instance names' --test-pairs --account personal
[[ $(records) == 40 && -f "$MOCK_DOCKER_STATE/$app.record" ]] || exit 1
expect_ok 'delete all removes only labeled instance containers' --delete --yes
[[ $(records) == 0 ]] || exit 1

export MOCK_FAIL_APP=true
expect_fail 'failed app creation removes only its newly created tunnel' 'Could not create Honeygain' --test-pairs --account personal
[[ $(records) == 0 && ! -d "$CASE_DIR/.hgincome/lock" ]] || exit 1
unset MOCK_FAIL_APP
export MOCK_PARTIAL_APP=true
expect_fail 'partially created app is removed before its new tunnel' 'Could not create Honeygain' --test-pairs --account personal
[[ $(records) == 0 ]] || exit 1
unset MOCK_PARTIAL_APP
export MOCK_PARTIAL_TUN=true
expect_fail 'partially created failed tunnel is removed safely' 'Could not create tunnel' --test-pairs --account personal
[[ $(records) == 0 ]] || exit 1
unset MOCK_PARTIAL_TUN
export MOCK_TUN_EXIT=true
expect_fail 'exited tunnel blocks app startup' 'is not running' --test-pairs --account personal
[[ $(records) == 1 ]] || exit 1
unset MOCK_TUN_EXIT
expect_ok 'failed tunnel can be inspected and deleted without valid accounts' --delete --yes

printf 'ACCOUNT_NETWORK[personal]=direct\n' >> "$CASE_DIR/accounts.conf"
expect_fail 'direct mode refuses ten devices on one host connection' 'supports one device' --check
printf 'ACCOUNT_DEVICES[personal]=1\nACCOUNT_NETWORK[second]=direct\nACCOUNT_DEVICES[second]=1\n' >> "$CASE_DIR/accounts.conf"
expect_fail 'multiple direct accounts on same host connection rejected' 'Only one direct device' --check
printf 'ACCOUNT_IDS=(personal)\n' >> "$CASE_DIR/accounts.conf"
expect_ok 'one direct account passes real entrypoint startup with mock Docker' --start
[[ $(records) == 1 ]] || exit 1
expect_ok 'direct cleanup' --delete --yes
printf '\n%s checks passed. No real Docker, Python, downloads, or external credentials used.\n' "$PASS"
