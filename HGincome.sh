#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
STATE_DIR="$SCRIPT_DIR/.hgincome"
INSTANCE_ID=''
LOCK_HELD=false
COMMAND=''
SELECT_ACCOUNT=''
SELECT_ACCOUNT_ID=''
SELECT_DEVICE=''
YES=false
TUNNEL_LOGS=false
LOG_TAIL=100

info() { printf '%s\n' "$*"; }
die() { printf 'HGincome: %s\n' "$*" >&2; exit 1; }

usage() {
    printf '%s\n' \
        'HGincome — Honeygain account/device manager (Bash + Docker)' \
        '' \
        'Usage: bash HGincome ACCOUNT COMMAND [OPTIONS]' \
        '       bash HGincome COMMAND [OPTIONS]  (all accounts)' \
        '       bash HGincome.sh COMMAND --account ACCOUNT  (compatible syntax)' \
        '' \
        '  --accounts   List account names, device counts, and proxy files' \
        '  --check      Validate all accounts and proxies without Docker' \
        '  --start      Create or start configured devices' \
        '  --stop       Stop managed containers, keeping their identities' \
        '  --restart    Restart tunnels before their Honeygain devices' \
        '  --status     Show managed containers' \
        '  --logs       Read one device’s logs' \
        '  --delete     Remove managed containers, keeping configuration/IDs' \
        '  --pull       Pull the configured Docker images' \
        '  --help       Show this help' \
        '' \
        '  --account ID   Limit an operation to one account' \
        '  --device N     Device number (1–10); required with --logs' \
        '  --tunnel       Show tunnel logs instead of Honeygain logs' \
        '  --tail N       Number of log lines (default: 100)' \
        '  --yes          Confirm --delete without an interactive prompt' \
        '' \
        'Run on a Linux Docker host. No software is installed automatically.'
}

parse_args() {
    if (($#)) && [[ $1 != -* ]]; then
        [[ -n $1 ]] || die 'Account ID must not be empty.'
        SELECT_ACCOUNT=$1
        shift
    fi
    while (($#)); do
        case "$1" in
            --accounts|--check|--start|--stop|--restart|--status|--logs|--delete|--pull|--help)
                [[ -z $COMMAND ]] || die 'Choose exactly one command.'
                COMMAND=$1
                shift
                ;;
            --account|--device|--tail)
                (($# >= 2)) || die "Missing value for $1."
                case "$1" in
                    --account)
                        [[ -z $SELECT_ACCOUNT ]] || die 'Specify the account once: either ACCOUNT first or --account ACCOUNT.'
                        [[ -n $2 ]] || die '--account must not be empty.'
                        SELECT_ACCOUNT=$2
                        ;;
                    --device) SELECT_DEVICE=$2 ;;
                    --tail) LOG_TAIL=$2 ;;
                esac
                shift 2
                ;;
            --yes) YES=true; shift ;;
            --tunnel) TUNNEL_LOGS=true; shift ;;
            *) die "Unknown option: $1. Use --help." ;;
        esac
    done
    [[ -n $COMMAND ]] || COMMAND=--help
    if [[ -n $SELECT_ACCOUNT ]]; then
        valid_account_name "$SELECT_ACCOUNT" || die 'Account names must be 1–64 letters, digits, spaces, dots, underscores or hyphens, starting with a letter or digit and without trailing spaces.'
        account_id "$SELECT_ACCOUNT"
        SELECT_ACCOUNT_ID=$REPLY
    fi
    [[ $LOG_TAIL =~ ^[0-9]{1,5}$ ]] || die '--tail must be a number from 0 to 99999.'
    LOG_TAIL=$((10#$LOG_TAIL))
    if [[ -n $SELECT_DEVICE ]]; then
        [[ $SELECT_DEVICE =~ ^0?[1-9]$|^10$ ]] || die '--device must be 1–10.'
        SELECT_DEVICE=$((10#$SELECT_DEVICE))
    fi
    if [[ $COMMAND == --logs ]]; then
        [[ -n $SELECT_ACCOUNT && -n $SELECT_DEVICE ]] || die '--logs requires --account ID and --device N.'
    else
        [[ -z $SELECT_DEVICE && $TUNNEL_LOGS == false && $LOG_TAIL == 100 ]] || die '--device, --tunnel and --tail are only for --logs.'
    fi
    [[ $YES == false || $COMMAND == --delete ]] || die '--yes is only for --delete.'
    [[ $COMMAND != --pull || -z $SELECT_ACCOUNT ]] || die '--pull does not take --account.'
}

load_properties() {
    HONEYGAIN_IMAGE='honeygain/honeygain:latest'
    TUN2PROXY_IMAGE='ghcr.io/tun2proxy/tun2proxy:v0.8.5'
    TUN2PROXY_DNS_MODE='over-tcp'
    DEVICES_PER_ACCOUNT=10
    ACCEPT_TOU=false
    RESTART_POLICY='unless-stopped'
    ENABLE_LOGS=true
    LOG_MAX_SIZE='5m'
    LOG_MAX_FILES=2
    TUNNEL_START_TIMEOUT=20
    DOCKER_BIN=docker
    [[ -f "$SCRIPT_DIR/properties.conf" ]] || die 'Missing properties.conf.'
    # Global settings remain trusted Bash code; section-based accounts are data.
    source "$SCRIPT_DIR/properties.conf"
    [[ -n $DOCKER_BIN ]] || die 'Docker executable must not be empty.'
    case "$COMMAND" in
        --accounts)
            [[ $DEVICES_PER_ACCOUNT =~ ^[1-9]$|^10$ ]] || die 'DEVICES_PER_ACCOUNT must be 1–10.'
            return
            ;;
        --check|--start|--pull) ;;
        --restart)
            [[ $TUNNEL_START_TIMEOUT =~ ^[1-9][0-9]{0,2}$ ]] || die 'TUNNEL_START_TIMEOUT must be 1–999 seconds.'
            return
            ;;
        *) return ;;
    esac
    [[ $DEVICES_PER_ACCOUNT =~ ^[1-9]$|^10$ ]] || die 'DEVICES_PER_ACCOUNT must be 1–10.'
    [[ $ACCEPT_TOU == true || $ACCEPT_TOU == false ]] || die 'ACCEPT_TOU must be true or false.'
    [[ $ENABLE_LOGS == true || $ENABLE_LOGS == false ]] || die 'ENABLE_LOGS must be true or false.'
    [[ $RESTART_POLICY =~ ^(no|always|unless-stopped|on-failure)$ ]] || die 'Invalid RESTART_POLICY.'
    [[ $TUN2PROXY_DNS_MODE =~ ^(virtual|over-tcp|direct)$ ]] || die 'Invalid TUN2PROXY_DNS_MODE.'
    [[ $LOG_MAX_SIZE =~ ^[1-9][0-9]*[kmg]$ && $LOG_MAX_FILES =~ ^[1-9][0-9]*$ ]] || die 'Invalid Docker log limits.'
    [[ $TUNNEL_START_TIMEOUT =~ ^[1-9][0-9]{0,2}$ ]] || die 'TUNNEL_START_TIMEOUT must be 1–999 seconds.'
    [[ -n $HONEYGAIN_IMAGE && -n $TUN2PROXY_IMAGE && -n $DOCKER_BIN ]] || die 'Docker executable and image names must not be empty.'
}

resolve_path() {
    case "$1" in
        /*|[A-Za-z]:[\\/]*) REPLY=$1 ;;
        *) REPLY="$SCRIPT_DIR/$1" ;;
    esac
}

normalize_proxy() {
    local value=$1 port
    case "$value" in
        socks5h://*) value="socks5://${value#socks5h://}" ;;
        socks4a://*) value="socks4://${value#socks4a://}" ;;
    esac
    [[ $value =~ ^(http|socks4|socks5)://([^[:space:]]+@)?(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9][A-Za-z0-9.-]*):([0-9]{1,5})$ ]] || return 1
    port=$((10#${BASH_REMATCH[4]}))
    ((port >= 1 && port <= 65535)) || return 1
    PROXY_ENDPOINT="${BASH_REMATCH[3],,}:$port"
    NORMALIZED_PROXY=$value
}

valid_account_name() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]{0,63}$ && $1 != *' ' ]]
}

account_id() {
    if [[ $1 =~ ^[a-z][a-z0-9_-]{0,11}$ ]]; then
        REPLY=$1
    else
        command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required for custom account names.'
        REPLY=$(printf '%s' "$1" | sha256sum)
        REPLY="a-${REPLY:0:10}"
    fi
}

trim_whitespace() {
    REPLY=${1#"${1%%[![:space:]]*}"}
    REPLY=${REPLY%"${REPLY##*[![:space:]]}"}
}

read_accounts_file() {
    local path="$SCRIPT_DIR/accounts.conf" line trimmed account='' key value number=0 format=''
    local -A sections=() keys=()
    [[ -f $path && -r $path ]] || die 'Create accounts.conf from accounts.conf.example first.'
    while IFS= read -r line || [[ -n $line ]]; do
        number=$((number + 1))
        line=${line%$'\r'}
        ((number != 1)) || line=${line#$'\xef\xbb\xbf'}
        trim_whitespace "$line"
        trimmed=$REPLY
        [[ -z $trimmed || $trimmed == \#* || $trimmed == \;* ]] && continue
        if [[ -z $format ]]; then
            if [[ $trimmed == ACCOUNT_IDS=* ]]; then
                # Compatibility only: legacy account files are trusted Bash code.
                info 'Using legacy Bash accounts.conf; the section-based example avoids executing account data.'
                source "$path"
                return
            fi
            format=sections
        fi
        if [[ $trimmed == \[*\] ]]; then
            account=${trimmed:1:${#trimmed}-2}
            valid_account_name "$account" || die "Invalid account name at line $number."
            [[ -z ${sections[$account]:-} ]] || die "Duplicate account section at line $number."
            sections[$account]=1
            ACCOUNT_IDS+=("$account")
            continue
        fi
        [[ $trimmed != \[* ]] || die "Invalid account section at line $number; use [Account Name]."
        [[ -n $account ]] || die "Account data at line $number needs an [account] section first."
        [[ $line == *=* ]] || die "Expected key=value at line $number (value hidden)."
        key=${line%%=*}
        trim_whitespace "$key"
        key=$REPLY
        value=${line#*=}
        case "$key" in
            email|password|devices|network|proxy_file|device_prefix) ;;
            *) die "Unknown account setting at line $number (value hidden)." ;;
        esac
        [[ -z ${keys[$account:$key]:-} ]] || die "Duplicate setting for account $account at line $number."
        keys[$account:$key]=1
        # Everything after the first '=' is literal, including quotes and spaces.
        case "$key" in
            email) ACCOUNT_EMAIL[$account]=$value ;;
            password) ACCOUNT_PASSWORD[$account]=$value ;;
            devices) ACCOUNT_DEVICES[$account]=$value ;;
            network)
                [[ $value == proxy ]] || die "Proxy is the only supported account network (line $number)."
                info "Account $account: network setting is obsolete; remove it. Proxies are always used."
                ;;
            proxy_file) ACCOUNT_PROXY_FILE[$account]=$value ;;
            device_prefix) ACCOUNT_DEVICE_PREFIX[$account]=$value ;;
        esac
    done < "$path"
}

load_accounts() {
    local validate=${1:-true}
    declare -ga ACCOUNT_IDS=()
    declare -gA ACCOUNT_EMAIL=() ACCOUNT_PASSWORD=() ACCOUNT_DEVICES=()
    declare -gA ACCOUNT_NETWORK=() ACCOUNT_PROXY_FILE=() ACCOUNT_DEVICE_PREFIX=()
    declare -gA DEVICE_PROXY=() COUNTS=() PREFIXES=() ACCOUNT_CONTAINER_ID=()
    read_accounts_file
    if ((${#ACCOUNT_IDS[@]} == 0)); then
        [[ $validate == false && -z $SELECT_ACCOUNT ]] && return 0
        die 'No accounts configured. Edit accounts.conf; see accounts.conf.example.'
    fi

    local account count prefix path line number index key id
    local selected=false
    local -A seen_accounts=() seen_ids=() seen_endpoints=() seen_prefixes=()
    for account in "${ACCOUNT_IDS[@]}"; do
        valid_account_name "$account" || die 'Invalid account name; use 1–64 letters, digits, spaces, dots, underscores or hyphens.'
        [[ -z ${seen_accounts[$account]:-} ]] || die "Duplicate account name: $account."
        seen_accounts[$account]=1
        account_id "$account"
        id=$REPLY
        [[ -z ${seen_ids[$id]:-} ]] || die "Account identity collision for $account. Choose another name."
        seen_ids[$id]=1
        ACCOUNT_CONTAINER_ID[$account]=$id
        [[ -z ${ACCOUNT_NETWORK[$account]:-} || ${ACCOUNT_NETWORK[$account]} == proxy ]] || die "Account $account: proxy is the only supported network."
        if [[ $validate == true ]]; then
            [[ -n ${ACCOUNT_EMAIL[$account]:-} && -n ${ACCOUNT_PASSWORD[$account]:-} ]] || die "Account $account needs an email and password."
            [[ ${ACCOUNT_EMAIL[$account]} == *@*.* && ${ACCOUNT_EMAIL[$account]} != *[$'\r\n\t ']* ]] || die "Account $account has an invalid email."
            [[ ${ACCOUNT_PASSWORD[$account]} != *[$'\r\n']* ]] || die "Account $account has a multiline password."
        fi
        count=${ACCOUNT_DEVICES[$account]:-$DEVICES_PER_ACCOUNT}
        [[ $count =~ ^[1-9]$|^10$ ]] || die "Account $account must request 1–10 devices."
        prefix=${ACCOUNT_DEVICE_PREFIX[$account]:-}
        if [[ -n $prefix ]]; then
            [[ $prefix =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,28}$ ]] || die "Account $account device prefix must be 1–29 letters, digits, dots, underscores or hyphens."
            [[ -z ${seen_prefixes[$prefix]:-} ]] || die "Duplicate device prefix for account $account."
            seen_prefixes[$prefix]=1
        fi
        COUNTS[$account]=$count
        PREFIXES[$account]=$prefix
        [[ -z $SELECT_ACCOUNT || $SELECT_ACCOUNT == "$account" ]] && selected=true
        [[ $validate == true ]] || continue
        resolve_path "${ACCOUNT_PROXY_FILE[$account]:-proxies/$account.txt}"
        path=$REPLY
        [[ -f $path && -r $path ]] || die "Missing or unreadable proxy file for account $account."
        number=0
        index=0
        while IFS= read -r line || [[ -n $line ]]; do
            number=$((number + 1))
            line=${line%$'\r'}
            [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
            normalize_proxy "$line" || die "Account $account: invalid proxy at line $number (URL hidden)."
            index=$((index + 1))
            ((index <= count)) || continue
            [[ -z ${seen_endpoints[$PROXY_ENDPOINT]:-} ]] || die "Account $account: proxy endpoint at line $number is already assigned to another device."
            seen_endpoints[$PROXY_ENDPOINT]=1
            key="$account:$index"
            DEVICE_PROXY[$key]=$NORMALIZED_PROXY
        done < "$path"
        ((index >= count)) || die "Account $account needs $count proxies but has $index."
        ((index <= count)) || info "Account $account: using the first $count of $index proxies."
    done
    [[ $selected == true ]] || die "Unknown account: $SELECT_ACCOUNT."
}

list_accounts() {
    load_accounts false
    if ((${#ACCOUNT_IDS[@]} == 0)); then
        info 'No accounts configured.'
        return
    fi
    local account total=0
    printf '%-64s %-7s %s\n' 'ACCOUNT' 'DEVICES' 'PROXY FILE'
    for account in "${ACCOUNT_IDS[@]}"; do
        [[ -z $SELECT_ACCOUNT || $SELECT_ACCOUNT == "$account" ]] || continue
        printf '%-64s %-7s %s\n' "$account" "${COUNTS[$account]}" "${ACCOUNT_PROXY_FILE[$account]:-proxies/$account.txt}"
        total=$((total + COUNTS[$account]))
    done
    info "$total selected device slots. Credentials and proxy URLs are not displayed."
}

read_instance() {
    [[ -f "$STATE_DIR/instance-id" ]] || return 1
    IFS= read -r INSTANCE_ID < "$STATE_DIR/instance-id" || die 'Unreadable instance-id.'
    [[ $INSTANCE_ID =~ ^[a-f0-9]{12}$ ]] || die 'Invalid instance-id; do not change or remove it while containers exist.'
}

cleanup() {
    if [[ $LOCK_HELD == true ]]; then
        rmdir -- "$STATE_DIR/lock" 2>/dev/null || true
    fi
}

prepare_state() {
    [[ ! -L $STATE_DIR ]] || die 'The state directory must not be a symlink.'
    mkdir -p -- "$STATE_DIR"
    chmod 700 -- "$STATE_DIR"
    mkdir -- "$STATE_DIR/lock" 2>/dev/null || die 'Another HGincome operation holds .hgincome/lock. Remove a stale lock only after checking no manager is running.'
    LOCK_HELD=true
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if ! read_instance; then
        INSTANCE_ID=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
        [[ $INSTANCE_ID =~ ^[a-f0-9]{12}$ ]] || die 'Unable to generate instance ID.'
        printf '%s\n' "$INSTANCE_ID" > "$STATE_DIR/instance-id"
    fi
    if [[ ! -f "$STATE_DIR/resolv.conf" ]]; then
        printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\noptions timeout:2 attempts:3\n' > "$STATE_DIR/resolv.conf"
    fi
}

docker_ready() {
    command -v "$DOCKER_BIN" >/dev/null 2>&1 || die 'Docker is not installed. Install Docker Engine on the Linux host first.'
    "$DOCKER_BIN" info >/dev/null 2>&1 || die 'Docker daemon is unavailable or permission was denied. Check Docker access; HGincome does not invoke sudo automatically.'
}

docker_cmd() { "$DOCKER_BIN" "$@"; }

set_names() {
    local account=$1 device=$2 id=${ACCOUNT_CONTAINER_ID[$1]}
    printf -v SLOT '%02d' "$device"
    APP_NAME="hgincome-$INSTANCE_ID-$id-$SLOT"
    TUN_NAME="$APP_NAME-tun"
    DEVICE_NAME="${PREFIXES[$account]:-hg-$INSTANCE_ID-$id}-$SLOT"
}

exists() { docker_cmd inspect "$1" >/dev/null 2>&1; }

assert_owned() {
    local owner
    owner=$(docker_cmd inspect --format '{{ index .Config.Labels "io.hgincome.instance" }}' "$1") || die "Cannot inspect $1."
    [[ $owner == "$INSTANCE_ID" ]] || die "Refusing to modify unrelated container $1."
}

assert_spec() {
    local spec
    assert_owned "$1"
    spec=$(docker_cmd inspect --format '{{ index .Config.Labels "io.hgincome.spec" }}' "$1") || die "Cannot inspect $1."
    [[ $spec == "$SPEC" ]] || die "Configuration changed for $1. Delete this account's containers and start again to apply it; device names remain stable."
}

wait_for_tunnel() {
    local state attempt
    for ((attempt=0; attempt<TUNNEL_START_TIMEOUT; attempt++)); do
        state=$(docker_cmd inspect --format '{{.State.Status}}' "$TUN_NAME") || return 1
        case "$state" in
            running) return 0 ;;
            exited|dead|removing) return 1 ;;
        esac
        sleep 1
    done
    return 1
}

remove_failed_creation() {
    if exists "$1"; then
        assert_spec "$1"
        docker_cmd rm -f "$1" >/dev/null 2>&1 || die "Could not clean up failed container $1."
    fi
}

check_desired_containers() {
    list_managed
    [[ -n $MANAGED ]] || return 0
    local name account slot kind
    local -a stale=()
    while IFS= read -r name; do
        assert_owned "$name"
        account=$(docker_cmd inspect --format '{{ index .Config.Labels "io.hgincome.account" }}' "$name") || die "Cannot inspect $name."
        slot=$(docker_cmd inspect --format '{{ index .Config.Labels "io.hgincome.device" }}' "$name") || die "Cannot inspect $name."
        kind=$(docker_cmd inspect --format '{{ index .Config.Labels "io.hgincome.kind" }}' "$name") || die "Cannot inspect $name."
        [[ $kind == honeygain || $kind == tunnel ]] || die "Unexpected container kind for $name."
        if ! valid_account_name "$account" || [[ ! $slot =~ ^0[1-9]$|^10$ ]]; then
            die "Invalid account/device labels for $name."
        fi
        if [[ -z ${COUNTS[$account]:-} ]]; then
            stale+=("$name")
        elif ((10#$slot > COUNTS[$account])); then
            stale+=("$name")
        fi
    done <<< "$MANAGED"
    if ((${#stale[@]})); then
        printf 'Containers outside the desired configuration:\n' >&2
        printf '  %s\n' "${stale[@]}" >&2
        die 'Delete the affected account containers deliberately before starting a reduced or changed configuration.'
    fi
}

start_device() {
    local account=$1 device=$2 proxy mode=proxy new_tunnel=false
    local -a labels=() run_options=() network_options=()
    set_names "$account" "$device"
    proxy=${DEVICE_PROXY[$account:$device]}
    SPEC=$(printf '%s\0' "$INSTANCE_ID" "$account" "$device" "$DEVICE_NAME" "$mode" "$proxy" \
        "${ACCOUNT_EMAIL[$account]}" "${ACCOUNT_PASSWORD[$account]}" "$HONEYGAIN_IMAGE" "$TUN2PROXY_IMAGE" \
        "$TUN2PROXY_DNS_MODE" "$RESTART_POLICY" "$ENABLE_LOGS" "$LOG_MAX_SIZE" "$LOG_MAX_FILES" | sha256sum)
    SPEC=${SPEC%% *}
    labels=(--label "io.hgincome.instance=$INSTANCE_ID" --label "io.hgincome.account=$account"
        --label "io.hgincome.device=$SLOT" --label "io.hgincome.spec=$SPEC")
    run_options=(--detach --restart "$RESTART_POLICY")
    if [[ $ENABLE_LOGS == true ]]; then
        run_options+=(--log-driver json-file --log-opt "max-size=$LOG_MAX_SIZE" --log-opt "max-file=$LOG_MAX_FILES")
    else
        run_options+=(--log-driver none)
    fi
    # Validate the entire pair before starting or creating either container.
    if exists "$APP_NAME"; then
        assert_spec "$APP_NAME"
        if ! exists "$TUN_NAME"; then
            die "Tunnel missing for $APP_NAME. Delete this account's containers and recreate the pair."
        fi
    fi
    if exists "$TUN_NAME"; then
        assert_spec "$TUN_NAME"
        docker_cmd start "$TUN_NAME" >/dev/null || die "Could not start $TUN_NAME."
    else
        if ! docker_cmd run "${run_options[@]}" --name "$TUN_NAME" "${labels[@]}" \
            --label io.hgincome.kind=tunnel --cap-add NET_ADMIN \
            --device /dev/net/tun:/dev/net/tun \
            --sysctl net.ipv6.conf.all.disable_ipv6=1 --sysctl net.ipv6.conf.default.disable_ipv6=1 \
            "$TUN2PROXY_IMAGE" --dns "$TUN2PROXY_DNS_MODE" --proxy "$proxy" --verbosity warn >/dev/null 2>&1; then
            remove_failed_creation "$TUN_NAME"
            die "Could not create tunnel for account $account device $SLOT (proxy URL hidden)."
        fi
        new_tunnel=true
    fi
    if ! wait_for_tunnel; then
        die "Tunnel for $account device $SLOT is not running. Inspect its tunnel logs with --account and --device."
    fi
    network_options=(--network "container:$TUN_NAME" --mount "type=bind,source=$STATE_DIR/resolv.conf,target=/etc/resolv.conf,readonly")
    if exists "$APP_NAME"; then
        docker_cmd start "$APP_NAME" >/dev/null || die "Could not start $APP_NAME."
    elif ! docker_cmd run "${run_options[@]}" --name "$APP_NAME" "${labels[@]}" \
        --label io.hgincome.kind=honeygain "${network_options[@]}" "$HONEYGAIN_IMAGE" \
        -tou-accept -email "${ACCOUNT_EMAIL[$account]}" -pass "${ACCOUNT_PASSWORD[$account]}" \
        -device "$DEVICE_NAME" >/dev/null 2>&1; then
        # Docker can create a container before failing to start it.
        remove_failed_creation "$APP_NAME"
        if [[ $new_tunnel == true ]]; then
            remove_failed_creation "$TUN_NAME"
        fi
        die "Could not create Honeygain for account $account device $SLOT (credentials hidden)."
    fi
    info "Started $account device $SLOT ($DEVICE_NAME). Container startup is not proof of Honeygain acceptance or earnings."
}

start_accounts() {
    load_accounts
    [[ $ACCEPT_TOU == true ]] || die 'Review Honeygain terms, then explicitly set ACCEPT_TOU=true in properties.conf before starting.'
    local account device
    [[ -c /dev/net/tun ]] || die 'Proxy mode requires /dev/net/tun on the Linux Docker host. Docker Desktop/Git Bash is not a supported proxy runtime.'
    command -v sha256sum >/dev/null 2>&1 || die 'sha256sum (coreutils) is required.'
    docker_ready
    prepare_state
    check_desired_containers
    for account in "${ACCOUNT_IDS[@]}"; do
        [[ -z $SELECT_ACCOUNT || $account == "$SELECT_ACCOUNT" ]] || continue
        for ((device=1; device<=COUNTS[$account]; device++)); do
            start_device "$account" "$device"
        done
    done
}

list_managed() {
    local -a filters=(--filter "label=io.hgincome.instance=$INSTANCE_ID")
    [[ -z $SELECT_ACCOUNT ]] || filters+=(--filter "label=io.hgincome.account=$SELECT_ACCOUNT")
    MANAGED=$(docker_cmd ps -a "${filters[@]}" --format '{{.Names}}') || die 'Unable to list managed containers.'
}

manage_existing() {
    docker_ready
    if ! read_instance; then
        info 'No saved HGincome instance. Nothing to manage.'
        return
    fi
    local name kind actual_kind answer
    local -A managed_kinds=()
    if [[ $COMMAND != --status && $COMMAND != --logs ]]; then
        prepare_state
    fi
    if [[ $COMMAND == --logs ]]; then
        printf -v SLOT '%02d' "$SELECT_DEVICE"
        name="hgincome-$INSTANCE_ID-$SELECT_ACCOUNT_ID-$SLOT"
        [[ $TUNNEL_LOGS == false ]] || name+=-tun
        exists "$name" || die "Container not found: $name."
        assert_owned "$name"
        docker_cmd logs --tail "$LOG_TAIL" "$name"
        return
    fi
    list_managed
    [[ -n $MANAGED ]] || { info 'No managed containers match this selection.'; return; }
    if [[ $COMMAND == --status ]]; then
        printf '%-54s %-12s %-10s %s\n' 'CONTAINER' 'ACCOUNT' 'DEVICE' 'STATE'
        while IFS= read -r name; do
            docker_cmd inspect --format '{{.Name}} | {{ index .Config.Labels "io.hgincome.account" }} | {{ index .Config.Labels "io.hgincome.device" }} | {{.State.Status}}' "$name"
        done <<< "$MANAGED"
        return
    fi
    while IFS= read -r name; do
        assert_owned "$name"
        actual_kind=$(docker_cmd inspect --format '{{ index .Config.Labels "io.hgincome.kind" }}' "$name") || die "Cannot inspect $name."
        [[ $actual_kind == honeygain || $actual_kind == tunnel ]] || die "Unexpected container kind for $name."
        managed_kinds[$name]=$actual_kind
    done <<< "$MANAGED"
    if [[ $COMMAND == --restart ]]; then
        while IFS= read -r name; do
            [[ ${managed_kinds[$name]} == honeygain ]] || continue
            [[ ${managed_kinds[$name-tun]:-} == tunnel ]] || die "Tunnel missing for $name. Proxy-only restart requires an owned app/tunnel pair; stop/delete old direct containers instead."
        done <<< "$MANAGED"
    fi
    if [[ $COMMAND == --delete && $YES == false ]]; then
        info 'The following HGincome containers will be removed; account/proxy files and saved instance ID will be kept:'
        info "$MANAGED"
        [[ -t 0 ]] || die 'Noninteractive deletion requires --yes.'
        read -r -p 'Type DELETE to continue: ' answer
        [[ $answer == DELETE ]] || { info 'Cancelled.'; return; }
    fi
    # Stop/remove applications before tunnels to preserve namespace ordering.
    for kind in honeygain tunnel; do
        while IFS= read -r name; do
            actual_kind=${managed_kinds[$name]}
            [[ $actual_kind == "$kind" ]] || continue
            case "$COMMAND" in
                --delete) docker_cmd rm -f "$name" >/dev/null || die "Could not remove $name." ;;
                --stop|--restart) docker_cmd stop "$name" >/dev/null || die "Could not stop $name." ;;
            esac
        done <<< "$MANAGED"
    done
    if [[ $COMMAND == --restart ]]; then
        for kind in tunnel honeygain; do
            while IFS= read -r name; do
                actual_kind=${managed_kinds[$name]}
                [[ $actual_kind == "$kind" ]] || continue
                docker_cmd start "$name" >/dev/null || die "Could not start $name."
                if [[ $kind == tunnel ]]; then
                    TUN_NAME=$name
                    wait_for_tunnel || die "Tunnel $name is not running after restart. Applications remain stopped."
                fi
            done <<< "$MANAGED"
        done
    fi
    info "${COMMAND#--} completed for the selected HGincome containers."
}

main() {
    ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) || die 'Bash 4.4 or newer is required.'
    parse_args "$@"
    [[ $COMMAND != --help ]] || { usage; return; }
    load_properties
    case "$COMMAND" in
        --accounts) list_accounts ;;
        --check)
            load_accounts
            local account total=0
            for account in "${ACCOUNT_IDS[@]}"; do
                [[ -z $SELECT_ACCOUNT || $account == "$SELECT_ACCOUNT" ]] || continue
                info "Account $account: ${COUNTS[$account]} device slots, proxy network."
                total=$((total + COUNTS[$account]))
            done
            info "Configuration valid: $total selected device slots. No Docker containers launched."
            [[ $ACCEPT_TOU == true ]] || info 'Starting is disabled until ACCEPT_TOU=true. Service/network eligibility must be checked separately.'
            ;;
        --start) start_accounts ;;
        --pull)
            docker_ready
            docker_cmd pull "$HONEYGAIN_IMAGE"
            docker_cmd pull "$TUN2PROXY_IMAGE"
            ;;
        *) manage_existing ;;
    esac
}

main "$@"
