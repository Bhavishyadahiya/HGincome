#!/usr/bin/env bash
set -Eeuo pipefail
# Load production functions without calling main; no runtime bypass is added to HGincome.
SOURCE=$1
CASE_DIR=$2
shift 2
script=''
while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == 'main "$@"' ]] || script+="$line"$'\n'
done < "$SOURCE"
source /dev/stdin <<< "$script"
SCRIPT_DIR=$CASE_DIR
STATE_DIR="$SCRIPT_DIR/.hgincome"

if [[ ${1:-} == --test-pairs ]]; then
    shift
    parse_args --start "$@"
    load_properties
    load_accounts
    [[ $ACCEPT_TOU == true ]] || die 'Terms not accepted.'
    docker_ready
    prepare_state
    check_desired_containers
    for account in "${ACCOUNT_IDS[@]}"; do
        [[ -z $SELECT_ACCOUNT || $account == "$SELECT_ACCOUNT" ]] || continue
        for ((device=1; device<=COUNTS[$account]; device++)); do
            start_device "$account" "$device"
        done
    done
else
    main "$@"
fi
