#!/usr/bin/env bash
set -Eeuo pipefail
: "${MOCK_DOCKER_STATE:?Set an isolated mock state directory.}"
[[ -d $MOCK_DOCKER_STATE ]] || exit 1

NAME=''
STATUS=''
IMAGE=''
declare -A LABELS=()
declare -a ARGS=()

load_container() {
    NAME=$1
    [[ $NAME =~ ^[a-zA-Z0-9_.-]+$ && -f "$MOCK_DOCKER_STATE/$NAME.record" ]] || return 1
    source "$MOCK_DOCKER_STATE/$NAME.record"
}

save_container() {
    local labels args
    labels=$(declare -p LABELS)
    args=$(declare -p ARGS)
    {
        printf 'STATUS=%q\nIMAGE=%q\n' "$STATUS" "$IMAGE"
        printf '%s\n' "${labels#declare -A }" "${args#declare -a }"
    } > "$MOCK_DOCKER_STATE/$NAME.record"
}

log_action() { printf '%s %s\n' "$1" "$NAME" >> "$MOCK_DOCKER_STATE/actions"; }

command_name=${1:-}
shift
case "$command_name" in
    info) exit 0 ;;
    pull) printf 'Mock pull only\n'; exit 0 ;;
    run)
        while (($#)); do
            case "$1" in
                --name) NAME=$2; shift 2 ;;
                --label) LABELS[${2%%=*}]=${2#*=}; shift 2 ;;
                --detach|-d) shift ;;
                --restart|--log-driver|--log-opt|--network|--mount|--device|--sysctl|--cap-add)
                    ARGS+=("$1" "$2"); shift 2 ;;
                --*) printf 'Unsupported mock flag\n' >&2; exit 1 ;;
                *) IMAGE=$1; shift; ARGS+=("$@"); break ;;
            esac
        done
        [[ -n $NAME && ! -f "$MOCK_DOCKER_STATE/$NAME.record" ]] || exit 1
        if [[ ${MOCK_FAIL_APP:-false} == true && ${LABELS[io.hgincome.kind]} == honeygain ]]; then
            exit 1
        fi
        if [[ ${MOCK_PARTIAL_APP:-false} == true && ${LABELS[io.hgincome.kind]} == honeygain ]]; then
            STATUS=created
            save_container
            log_action run
            exit 1
        fi
        if [[ ${MOCK_PARTIAL_TUN:-false} == true && ${LABELS[io.hgincome.kind]} == tunnel ]]; then
            STATUS=created
            save_container
            log_action run
            exit 1
        fi
        STATUS=running
        [[ ${MOCK_TUN_EXIT:-false} != true || ${LABELS[io.hgincome.kind]} != tunnel ]] || STATUS=exited
        save_container
        log_action run
        printf 'mock-container-id\n'
        ;;
    inspect)
        format=''
        if [[ ${1:-} == --format ]]; then format=$2; shift 2; fi
        load_container "$1" || exit 1
        if [[ ${MOCK_FAIL_KIND:-false} == true && $format == *'"io.hgincome.kind"'* ]]; then
            exit 1
        fi
        case "$format" in
            '') printf 'mock-inspect\n' ;;
            '{{.State.Status}}') printf '%s\n' "$STATUS" ;;
            *'{{.Name}}'*) printf '/%s | %s | %s | %s\n' "$NAME" "${LABELS[io.hgincome.account]}" "${LABELS[io.hgincome.device]}" "$STATUS" ;;
            *)
                if [[ $format =~ \"(io\.hgincome\.[a-z]+)\" ]]; then
                    printf '%s\n' "${LABELS[${BASH_REMATCH[1]}]:-}"
                else
                    printf 'Unsupported mock inspect format\n' >&2; exit 1
                fi
                ;;
        esac
        ;;
    start|stop)
        load_container "$1" || exit 1
        STATUS=running
        [[ $command_name != stop ]] || STATUS=exited
        save_container
        log_action "$command_name"
        printf '%s\n' "$NAME"
        ;;
    rm)
        [[ ${1:-} != -f ]] || shift
        load_container "$1" || exit 1
        log_action rm
        rm -- "$MOCK_DOCKER_STATE/$NAME.record"
        printf '%s\n' "$NAME"
        ;;
    ps)
        declare -a filters=()
        while (($#)); do
            case "$1" in
                -a) shift ;;
                --filter) filters+=("${2#label=}"); shift 2 ;;
                --format) shift 2 ;;
                *) exit 1 ;;
            esac
        done
        shopt -s nullglob
        for record in "$MOCK_DOCKER_STATE"/*.record; do
            load_container "$(basename "$record" .record)"
            match=true
            for filter in "${filters[@]}"; do
                [[ ${LABELS[${filter%%=*}]:-} == "${filter#*=}" ]] || match=false
            done
            [[ $match == false ]] || printf '%s\n' "$NAME"
        done
        ;;
    logs)
        [[ $1 == --tail ]]; shift 2
        load_container "$1" || exit 1
        printf 'Mock logs for %s\n' "$NAME"
        ;;
    *) printf 'Unsupported mock command\n' >&2; exit 1 ;;
esac
