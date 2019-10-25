#!/usr/bin/env bash
set -euo pipefail
set -x

# See bin/finalize to check predefined vars
ROOT="/home/vcap"
export APP_ROOT="${ROOT}/app"
export AUTH_USER="${AUTH_USER:-admin}"
export AUTH_PASSWORD="${AUTH_PASSWORD:-}"

###

random_string() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${1:-32} | head -n 1
}

# exec process in bg or fg
launch() {
    local pid
    local rvalue
    (
        echo "Launching pid=$$: $@"
        {
            exec $@  2>&1;
        }
    ) &
    pid=$!
    wait ${pid} 2>/dev/null
    rvalue=$?
    echo "Finish pid=${pid}: ${rvalue}"
    return ${rvalue}
}


run_rclone() {
    if [ -z "${AUTH_PASSWORD}" ]
    then
        AUTH_PASSWORD="$(random_string)"
        echo "Generated random password for user ${AUTH_USER}: '${AUTH_PASSWORD}'"
    fi
    launch rclone rcd --rc-web-gui --rc-addr :${PORT} --rc-user "${AUTH_USER}" --rc-pass "${AUTH_PASSWORD}" $@
}

# run
run_rclone $@
