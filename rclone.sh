#!/usr/bin/env bash
[ -z "$DEBUG" ] || set -x
set -euo pipefail

# See bin/finalize to check predefined vars
ROOT="/home/vcap"
export APP_ROOT="${ROOT}/app"
export AUTH_ROOT="${ROOT}/auth"
export APP_CONFIG="${ROOT}/.config/rclone/rclone.conf"

### Configuration env vars

export AUTH_USER="${AUTH_USER:-admin}"
export AUTH_PASSWORD="${AUTH_PASSWORD:-}"
export SERVE="${SERVE:-1}"
export RCLONE_CONFIG="${RCLONE_CONFIG:-$APP_ROOT/rclone.conf}"
export GCS_LOCATION="${GCS_LOCATION:-europe-west4}"
export BINDING_NAME="${BINDING_NAME:-}"

###

get_binding_service() {
    local binding_name="${1}"
    jq --arg b "${binding_name}" '[.[][] | select(.binding_name == $b)]' <<<"${VCAP_SERVICES}"
}

services_has_tag() {
    local services="${1}"
    local tag="${2}"
    jq --arg t "${tag}" -e '.[].tags | contains([$t])' <<<"${services}" >/dev/null
}

get_s3_service() {
    local name=${1:-"aws-s3"}
    jq --arg n "${name}" '.[$n]' <<<"${VCAP_SERVICES}"
}

get_gcs_service() {
    local name=${1:-"google-storage"}
    jq --arg n "${name}" '.[$n]' <<<"${VCAP_SERVICES}"
}

set_s3_rclone_config() {
    local config="${1}"
    local services="${2}"

    jq  -r '.[] |
"["+ .name +"]
type = s3
provider = AWS
access_key_id = "+ .credentials.ACCESS_KEY_ID +"
secret_access_key = "+ .credentials.SECRET_ACCESS_KEY +"
region = "+  (.credentials.S3_API_URL | split(".")[0] | split("s3-")[1])  +"
location_constraint = "+ (.credentials.S3_API_URL | split(".")[0] | split("s3-")[1]) +"
acl = private
env_auth = false
"' <<<"${services}" >> ${config}
}

set_gcs_rclone_config() {
    local config="${1}"
    local services="${2}"

    for s in $(jq -r '.[] | .name' <<<"${services}")
    do
        jq -r --arg n "${s}" '.[] | select(.name == $n) | .credentials.PrivateKeyData' <<<"${services}" | base64 -d > "${AUTH_ROOT}/${s}-auth.json"
    done
    jq --arg p "${AUTH_ROOT}" --arg l "${GCS_LOCATION}" -r '.[] |
"["+ .name +"]
type = google cloud storage
client_id =
client_secret =
project_number =
service_account_file = "+ $p +"/"+ .name +"-auth.json
storage_class = REGIONAL
location = "+ $l +"
"' <<<"${services}" >> ${config}
}

get_bucket_vcap_service() {
    local rconfig="${1}"
    local binding_name="${2}"
    local service=""

    if [ -n "${binding_name}" ] && [ "${binding_name}" != "null" ]
    then
        service=$(get_binding_service "${binding_name}")
        if [ -n "${service}" ] && [ "${service}" != "null" ]
        then
            if services_has_tag "${service}" "gcp"
            then
                set_gcs_rclone_config "${rconfig}" "${service}"
            else
                set_s3_rclone_config "${rconfig}" "${service}"
            fi
        else
            echo "* Error, service '${binding_name}' not found!"
        fi
    else
        service=$(get_s3_service)
        if [ -n "${service}" ] && [ "${service}" != "null" ]
        then
            set_s3_rclone_config "${rconfig}" "${service}"
        fi
        service=$(get_gcs_service)
        if [ -n "${service}" ] && [ "${service}" != "null" ]
        then
            set_gcs_rclone_config "${rconfig}" "${service}"
        fi
    fi
}

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
    local cmd="rclone --config "${RCLONE_CONFIG}" rcd --rc-web-gui --rc-addr :${PORT}"

    if [ -z "${AUTH_PASSWORD}" ]
    then
        AUTH_PASSWORD="$(random_string)"
        echo "* Generated random password for user ${AUTH_USER}: '${AUTH_PASSWORD}'"
    fi
    if [ -r "${RCLONE_CONFIG}" ]
    then
        echo >> "${RCLONE_CONFIG}"
    else
        touch "${RCLONE_CONFIG}"
    fi
    mkdir -p $(dirname "${APP_CONFIG}")
    ln -sf "${RCLONE_CONFIG}" "${APP_CONFIG}"

    [ "x${SERVE}" == "x1" ] && cmd="${cmd} --rc-serve"
    get_bucket_vcap_service "${RCLONE_CONFIG}" "${BINDING_NAME}"
    launch ${cmd} --rc-user "${AUTH_USER}" --rc-pass "${AUTH_PASSWORD}" $@
}

# run
run_rclone $@
