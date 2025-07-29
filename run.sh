#!/bin/bash

VERSION="1.0.3"

function init {
    echo "Botstrap version ${VERSION}"

    if ! which ssh-copy-id >/dev/null
    then
        echo "Installing ssh..."
        sudo apt-get install ssh -y
    fi
    
    if ! which rsync >/dev/null
    then
    	echo "Installing rsync..."
    	sudo apt update && sudo apt -y install rsync
    fi
    
    if ! which jq >/dev/null
    then
    	echo "Installing jq..."
    	sudo apt update && sudo apt -y install jq
    fi
    
    echo "Important: make sure you have run ssh-copy-id for each host or mirror before using this script."

    CREATE_BOOTSTRAP_ERRORS=0
}

function reset {
    BOOTSTRAP_PATH=""
    BOOTSTRAP_CHECKSUM_PATH=""
}


function read_config {
    CONFIG=$(cat "/opt/botstrap/config.json")
    NODE_HOST=$(echo "$CONFIG" | jq -r '.["nodeHost"]')
    NODE_PORT=$(echo "$CONFIG" | jq -r '.["nodePort"]')
    NODE_SERVICE=$(echo "$CONFIG" | jq -r '.["nodeService"]')
    BOOTSTRAP_HOST=$(echo "$CONFIG" | jq -r '.["bootstrapHost"]')
    BOOTSTRAP_HOST_MODE=$(echo "$CONFIG" | jq -r '.["bootstrapHostMode"]')
    BOOTSTRAP_MIRRORS=$(echo "$CONFIG" | jq -r '.["bootstrapMirrors"]')
    BOOTSTRAP_USER=$(echo "$CONFIG" | jq -r '.["bootstrapUser"]')
    BOOTSTRAP_WEBROOT=$(echo "$CONFIG" | jq -r '.["bootstrapWebRoot"]')
    TIMEOUT=$(echo "$CONFIG" | jq -r '.["timeout"]')
    BOOTSTRAP_INTERVAL=$(echo "$CONFIG" | jq -r '.["bootstrapInterval"]')
    RETRY_INTERVAL=$(echo "$CONFIG" | jq -r '.["retryInterval"]')
    CREATE_BOOTSTRAP_ERROR_TOTAL=$(echo "$CONFIG" | jq -r '.["createBootstrapErrorTotal"]')

    #echo "CONFIG: ${CONFIG}"
}
#todo - move this into config.
LOCK_FILE_NAME=".botstrap.lock"
LOCK_FILE_CONTENT="locked-by-$(hostname)-$(date +%s)"
LOCK_FILE_PATH="${BOOTSTRAP_WEBROOT}/${LOCK_FILE_NAME}"
LOCK_EXPIRY_SECONDS=900
LOCAL_LOCK_STATE_FILE="/opt/botstrap/state/last-lock.json"
MIRROR_LOCK_STATE_DIR="/opt/botstrap/state/mirrors"
MIRROR_LOCK_EXPIRY_SECONDS=900
LOG_DIR="/opt/botstrap/logs"

mkdir -p "${LOG_DIR}"
mkdir -p "${MIRROR_LOCK_STATE_DIR}"

function create_bootstrap {
    # Check if we need to restart the node
    if [ "${CREATE_BOOTSTRAP_ERRORS}" -ge "${CREATE_BOOTSTRAP_ERROR_TOTAL}" ]; then    
        # This relies on having a systemd service set up to automatically start qortal after stopping.
        echo "Restarting node due to ${CREATE_BOOTSTRAP_ERRORS} consecutive errors..."
        # testing stopping via bash and stop script instead of trying to use sudo in script running as user.
        bash /opt/qortal/stop.sh
        # sleeping for 100 seconds to give Qortal service a chance to start fully again...
        CREATE_BOOTSTRAP_ERRORS=0
        sleep 100
    fi

    echo "Attempting to create bootstrap..."
    echo "Existing error count: ${CREATE_BOOTSTRAP_ERRORS}"

    URL="http://${NODE_HOST}:${NODE_PORT}/bootstrap/create"
    RESULT=$(curl -s -X POST --max-time "${TIMEOUT}" "${URL}")
    # echo "${RESULT}"

    if [ -z "${RESULT}" ]; then
        echo "Empty response from create bootstrap API, sleeping for 30 seconds and trying again..."
        sleep 30
        CREATE_BOOTSTRAP_ERRORS=$((CREATE_BOOTSTRAP_ERRORS + 1))
        echo "ERRORS: ${CREATE_BOOTSTRAP_ERRORS} / ${CREATE_BOOTSTRAP_ERROR_TOTAL}"
	return 1
    fi

    ERROR=$(echo "${RESULT}" | jq -r '.["error"]')
    if [ ! -z "${ERROR}" ]; then
        ERROR_MESSAGE=$(echo "${RESULT}" | jq -r '.["message"]')
        echo "An error occurred: ${ERROR_MESSAGE}, sleeping 30 seconds..."
	sleep 30
        CREATE_BOOTSTRAP_ERRORS=$((CREATE_BOOTSTRAP_ERRORS + 1))
        echo "ERRORS: ${CREATE_BOOTSTRAP_ERRORS} / ${CREATE_BOOTSTRAP_ERROR_TOTAL}"
        return 2
    fi

    # Get the path to the extracted bootstrap
    PATH_RESPONSE="${RESULT}"
    if [[ ! "${PATH_RESPONSE}" == *".7z" ]]; then
        echo "Error: invalid path: ${PATH_RESPONSE}, sleeping 20 seconds..."
	sleep 20
        CREATE_BOOTSTRAP_ERRORS=$((CREATE_BOOTSTRAP_ERRORS + 1))
        echo "ERRORS: ${CREATE_BOOTSTRAP_ERRORS} / ${CREATE_BOOTSTRAP_ERROR_TOTAL}"
        return 3
    fi

    echo "Bootstrap created at path: ${PATH_RESPONSE}"
    BOOTSTRAP_PATH="${PATH_RESPONSE}"
    BOOTSTRAP_CHECKSUM_PATH="${PATH_RESPONSE}.sha256"
    CREATE_BOOTSTRAP_ERRORS=0

    # After successful bootstrap creation, get block height and write to block.txt
    echo "Fetching block height..."
    BLOCK_HEIGHT=$(curl -s localhost:12391/admin/status | jq -r '.height')
    if [ -n "$BLOCK_HEIGHT" ]; then
        echo "$BLOCK_HEIGHT" > /var/www/html/block.txt
        echo "Block height $BLOCK_HEIGHT written to /var/www/html/block.txt"
    else
        echo "Error: Unable to retrieve block height."
        CREATE_BOOTSTRAP_ERRORS=$((CREATE_BOOTSTRAP_ERRORS + 1))
        echo "ERRORS: ${CREATE_BOOTSTRAP_ERRORS} / ${CREATE_BOOTSTRAP_ERROR_TOTAL}"
        return 4
    fi

    return 0
}


function upload_to_main_host {
    
    local BOOTSTRAP_FILENAME="$(basename -- $BOOTSTRAP_PATH)"
    local BOOTSTRAP_CHECKSUM_FILENAME="$(basename -- $BOOTSTRAP_CHECKSUM_PATH)"
    local BOOTSTRAP_FILENAME_NEW="${BOOTSTRAP_FILENAME}.new"
    local BOOTSTRAP_CHECKSUM_FILENAME_NEW="${BOOTSTRAP_CHECKSUM_FILENAME}.new"

    # Add the host to known hosts, to avoid terminal prompts when adding a new host in the config
    ssh-keyscan "${BOOTSTRAP_HOST}" >> "${HOME}/.ssh/known_hosts"

    # Upload the files
    echo "Uploading ${BOOTSTRAP_PATH} to ${BOOTSTRAP_HOST}:${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME_NEW}..."
    rsync_with_retry "${BOOTSTRAP_PATH}" "${BOOTSTRAP_USER}@${BOOTSTRAP_HOST}:${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME_NEW}"
    
    echo "Uploading ${BOOTSTRAP_CHECKSUM_PATH} to ${BOOTSTRAP_HOST}:${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME_NEW}..."
    rsync_with_retry "${BOOTSTRAP_CHECKSUM_PATH}" "${BOOTSTRAP_USER}@${BOOTSTRAP_HOST}:${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME_NEW}"

    # Upload block.txt to the main host
    if [ -f "block.txt" ]; then
        BLOCK_FILE_PATH="block.txt"
    else
        BLOCK_FILE_PATH="${BOOTSTRAP_WEBROOT}/block.txt"
    fi

    echo "Uploading ${BLOCK_FILE_PATH} to ${BOOTSTRAP_HOST}:${BOOTSTRAP_WEBROOT}/block.txt..."
    rsync_with_retry "${BLOCK_FILE_PATH}" "${BOOTSTRAP_USER}@${BOOTSTRAP_HOST}:${BOOTSTRAP_WEBROOT}/block.txt"

    # Check the files are intact
    local CHECKSUM_URL="http://${BOOTSTRAP_HOST}/${BOOTSTRAP_CHECKSUM_FILENAME_NEW}"
    local CHECKSUM_REMOTE=$(curl -s "${CHECKSUM_URL}")
    local CHECKSUM_LOCAL=$(sha256sum "${BOOTSTRAP_PATH}" | awk '{ print $1 }')
    if [ -z "${CHECKSUM_REMOTE}" ]; then
        echo "Error: no checksum could be found on the main server"
        return 1
    fi
    if [[ "${CHECKSUM_REMOTE}" != "${CHECKSUM_LOCAL}" ]]; then
        echo "Error: checksum files do not match"
        echo "CHECKSUM_LOCAL: ${CHECKSUM_LOCAL}"
        echo "CHECKSUM_REMOTE: ${CHECKSUM_REMOTE}"
        echo "CHECKSUM_URL: ${CHECKSUM_URL}"
        return 2
    fi

    # Check that the uploaded file matches its checksum file
    COMPUTED_CHECKSUM_REMOTE=$(ssh_with_retry "${BOOTSTRAP_USER}@${BOOTSTRAP_HOST}" "sha256sum ${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME_NEW}" | awk '{ print $1 }')
    if [[ "${COMPUTED_CHECKSUM_REMOTE}" != "${CHECKSUM_LOCAL}" ]]; then
        echo "Error: checksum of uploaded file does not match"
        echo "CHECKSUM_LOCAL: ${CHECKSUM_LOCAL}"
        echo "COMPUTED_CHECKSUM_REMOTE: ${COMPUTED_CHECKSUM_REMOTE}"
        echo "BOOTSTRAP_FILENAME_NEW: ${BOOTSTRAP_FILENAME_NEW}"
        return 3
    fi

    # All good
    return 0
}

function move_to_local_host {

    local BOOTSTRAP_FILENAME="$(basename -- $BOOTSTRAP_PATH)"
    local BOOTSTRAP_CHECKSUM_FILENAME="$(basename -- $BOOTSTRAP_CHECKSUM_PATH)"
    local BOOTSTRAP_FILENAME_NEW="${BOOTSTRAP_FILENAME}.new"
    local BOOTSTRAP_CHECKSUM_FILENAME_NEW="${BOOTSTRAP_CHECKSUM_FILENAME}.new"
    local CHECKSUM_FILE_SRC=$(cat ${BOOTSTRAP_CHECKSUM_PATH})

    # Upload the files
    echo "Moving ${BOOTSTRAP_PATH} to ${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME_NEW}..."
    mv "${BOOTSTRAP_PATH}" "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME_NEW}"
    
    echo "Moving ${BOOTSTRAP_CHECKSUM_PATH} to ${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME_NEW}..."
    mv "${BOOTSTRAP_CHECKSUM_PATH}" "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME_NEW}"

    # Move block.txt as well
    echo "Moving block.txt to ${BOOTSTRAP_WEBROOT}/block.txt..."
    mv "block.txt" "${BOOTSTRAP_WEBROOT}/block.txt"

    # Check the source and destination match
    echo "Checking relocated files..."
    local CHECKSUM_FILE_DEST=$(cat ${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME_NEW})
    if [[ "${CHECKSUM_FILE_SRC}" != "${CHECKSUM_FILE_DEST}" ]]; then
        echo "Error: checksum of moved file does not match original"
        echo "CHECKSUM_FILE_SRC: ${CHECKSUM_FILE_SRC}"
        echo "CHECKSUM_FILE_DEST: ${CHECKSUM_FILE_DEST}"
        echo "BOOTSTRAP_CHECKSUM_FILENAME_NEW: ${BOOTSTRAP_CHECKSUM_FILENAME_NEW}"
        return 1
    fi
    
    # Check that the copied file matches its checksum file
    echo "Validating checksum..."
    local COMPUTED_CHECKSUM_LOCAL=$(sha256sum "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME_NEW}" | awk '{ print $1 }')
    if [[ "${COMPUTED_CHECKSUM_LOCAL}" != "${CHECKSUM_FILE_DEST}" ]]; then
        echo "Error: checksum of moved file does not match its sha256 file"
        echo "CHECKSUM_FILE_DEST: ${CHECKSUM_FILE_DEST}"
        echo "COMPUTED_CHECKSUM_LOCAL: ${COMPUTED_CHECKSUM_LOCAL}"
        echo "BOOTSTRAP_FILENAME_NEW: ${BOOTSTRAP_FILENAME_NEW}"
        echo "BOOTSTRAP_CHECKSUM_FILENAME_NEW: ${BOOTSTRAP_CHECKSUM_FILENAME_NEW}"
        return 2
    fi

    # All good
    echo "Files copied successfully"
    return 0

}

function ssh_with_retry {
    local host="$1"
    local cmd="$2"
    local retries=4
    local delay=5
    local timeout=20

    for ((i=1; i<=retries; i++)); do
        >&2 echo "SSH attempt $i/$retries to $host..."
        local output
        if output=$(ssh -o ConnectTimeout=$timeout -o BatchMode=yes "$host" "$cmd" 2>/dev/null); then
            echo "$output"
            return 0
        fi
        >&2 echo "SSH failed. Retrying in $delay seconds..."
        sleep $delay
        delay=$((delay * 2))
    done

    >&2 echo "SSH to $host failed after $retries attempts."
    return 1
}


function rsync_with_retry {
    local SRC="$1"
    local DEST="$2"
    local MAX_RETRIES=3
    local RETRY_DELAY=5

    local attempt=1
    until rsync -raPz "$SRC" "$DEST"; do
        echo "⚠️ rsync failed (attempt $attempt/$MAX_RETRIES): $SRC → $DEST"
        if (( attempt >= MAX_RETRIES )); then
            echo "❌ Giving up after $MAX_RETRIES failed attempts."
            return 1
        fi
        ((attempt++))
        sleep "$RETRY_DELAY"
    done
    echo "✅ rsync succeeded: $SRC → $DEST"
    return 0
}

function sync_mirror {
    MIRROR="$1"

    lock_mirror "${MIRROR}" || return 1

    echo "==> Syncing to mirror: ${MIRROR}..."

    local BOOTSTRAP_FILENAME="$(basename -- $BOOTSTRAP_PATH)"
    local BOOTSTRAP_CHECKSUM_FILENAME="$(basename -- $BOOTSTRAP_CHECKSUM_PATH)"
    local BOOTSTRAP_FILENAME_NEW="${BOOTSTRAP_FILENAME}.new"
    local BOOTSTRAP_CHECKSUM_FILENAME_NEW="${BOOTSTRAP_CHECKSUM_FILENAME}.new"

    for FILE in "${BOOTSTRAP_FILENAME_NEW}" "${BOOTSTRAP_CHECKSUM_FILENAME_NEW}" "block.txt"; do
        SRC="${BOOTSTRAP_WEBROOT}/${FILE}"
        DEST="${BOOTSTRAP_USER}@${MIRROR}:${BOOTSTRAP_WEBROOT}/${FILE}"
        echo "Uploading ${SRC} to ${DEST}..."
        rsync_with_retry ${SRC} ${DEST}
    done

    echo "✅ Mirror ${MIRROR} synced successfully."
    unlock_mirror "${MIRROR}"
    return 0
}

function sync_mirrors {
    BOOTSTRAP_MIRRORS_ARRAY=$(echo "${BOOTSTRAP_MIRRORS}" | jq -r @sh | xargs echo)

    for MIRROR in ${BOOTSTRAP_MIRRORS_ARRAY}; do
        sync_mirror "${MIRROR}" &
    done

    wait
    echo "✅ All mirrors attempted."
}

function validate_timestamp {
    REMOTE_FILE="${1}"
    LOCAL_FILE="${2}"

    REMOTE_TIMESTAMP=$(ssh_with_retry "${BOOTSTRAP_USER}@${BOOTSTRAP_HOST}" "stat -c %Y ${REMOTE_FILE}")
    LOCAL_TIMESTAMP=$(stat -c %Y "${LOCAL_FILE}")

    if [ "${LOCAL_TIMESTAMP}" -le "${REMOTE_TIMESTAMP}" ]; then
        echo "Error: Local file is older or same as the remote file. Not replacing."
        return 1
    fi

    return 0
}

function upload {
    # Ensure the files exist
    if [ ! -f "${BOOTSTRAP_PATH}" ]; then
        echo "Error: no file exists at path ${BOOTSTRAP_PATH}"
        return 1
    fi
    if [ ! -f "${BOOTSTRAP_CHECKSUM_PATH}" ]; then
        echo "Error: no checksum file exists at path ${BOOTSTRAP_CHECKSUM_PATH}"
        return 2
    fi

    if [[ "${BOOTSTRAP_HOST_MODE}" == "remote" ]]; then
        upload_to_main_host
        EXIT_CODE=$?
    elif [[ "${BOOTSTRAP_HOST_MODE}" == "local" ]]; then
        move_to_local_host
        EXIT_CODE=$?
    else
        echo "Unknown host mode: ${BOOTSTRAP_HOST_MODE}"
        return 3
    fi

    if [ "${EXIT_CODE}" -ne 0 ]; then
        return "${EXIT_CODE}"
    fi
    return 0
}

function initiate_lock {
    echo "Attempting to acquire lock on ${BOOTSTRAP_HOST}..."

    # Create local state directory if needed
    mkdir -p "$(dirname "${LOCAL_LOCK_STATE_FILE}")"

    # Check if lock exists
    if [ -f ${LOCK_FILE_PATH} ]; then
        # Check local lock file
        LOCK_DATA=$(cat ${LOCK_FILE_PATH} 2>/dev/null)
        LOCK_TS=$(jq -r '.timestamp // 0')
        NOW_TS=$(date +%s)
        AGE=$((NOW_TS - LOCK_TS))

        if [ "$AGE" -gt "$LOCK_EXPIRY_SECONDS" ]; then
            echo "⚠️ Stale lock detected (age: ${AGE}s > ${LOCK_EXPIRY_SECONDS}s). Removing..."
            ssh_with_retry rm -f "${LOCK_FILE_PATH}"
        else
            echo "❌ Lock already exists and is fresh. Aborting this cycle."
            echo "${LOCK_DATA}" > "${LOCAL_LOCK_STATE_FILE}"
            return 1
        fi
    fi

    # Generate new lock content
    LOCK_TS=$(date +%s)
    LOCK_DATA="{\"host\": \"$(hostname)\", \"timestamp\": ${LOCK_TS}}"

    # Write lock
    echo "Writing lock on local machine:  ${LOCK_FILE_PATH}"
    echo "${LOCK_DATA}" > "${LOCAL_LOCK_STATE_FILE}"

    echo "✅ Lock acquired on ${BOOTSTRAP_HOST}."
    return 0
}

function release_lock {
    echo "Releasing lock on ${BOOTSTRAP_HOST}..."

    if [ ! -f "${LOCAL_LOCK_STATE_FILE}" ]; then
        echo "⚠️ No local lock state found. Continuing..."
        return
    fi

    LOCAL_LOCK_DATA=$(cat "${LOCAL_LOCK_STATE_FILE}")
    LOCAL_LOCK_HOST=$(echo "${LOCAL_LOCK_DATA}" | jq -r '.host')

    
    rm -f "${LOCAL_LOCK_STATE_FILE}"
    
}

function lock_mirror {
    MIRROR="$1"
    MIRROR_LOCK_FILE="${BOOTSTRAP_WEBROOT}/${LOCK_FILE_NAME}"
    LOCAL_MIRROR_LOCK_FILE="${MIRROR_LOCK_STATE_DIR}/${MIRROR}.json"

    echo "🔐 Attempting mirror lock on ${MIRROR}..."

    if ssh_with_retry "${BOOTSTRAP_USER}@${MIRROR}" "[ -f ${MIRROR_LOCK_FILE} ]"; then
        REMOTE_LOCK_DATA=$(ssh_with_retry "${BOOTSTRAP_USER}@${MIRROR}" "cat ${MIRROR_LOCK_FILE}" 2>/dev/null)
        REMOTE_TS=$(echo "${REMOTE_LOCK_DATA}" | jq -r '.timestamp // 0')
        NOW_TS=$(date +%s)
        AGE=$((NOW_TS - REMOTE_TS))

        if [ "$AGE" -gt "$MIRROR_LOCK_EXPIRY_SECONDS" ]; then
            echo "⚠️ Stale mirror lock (age ${AGE}s). Removing it..."
            ssh_with_retry "${BOOTSTRAP_USER}@${MIRROR}" "rm -f ${MIRROR_LOCK_FILE}"
        else
            echo "❌ Mirror lock on ${MIRROR} is active and fresh. Skipping."
            echo "${REMOTE_LOCK_DATA}" > "${LOCAL_MIRROR_LOCK_FILE}"
            return 1
        fi
    fi

    # Set new lock
    LOCK_TS=$(date +%s)
    LOCK_VAL="{\"host\": \"$(hostname)\", \"timestamp\": ${LOCK_TS}}"

    echo "${LOCK_VAL}" | ssh_with_retry "${BOOTSTRAP_USER}@${MIRROR}" "cat > ${MIRROR_LOCK_FILE}"
    echo "${LOCK_VAL}" > "${LOCAL_MIRROR_LOCK_FILE}"
    echo "✅ Mirror lock set for ${MIRROR}"
}

function unlock_mirror {
    MIRROR="$1"
    MIRROR_LOCK_FILE="${BOOTSTRAP_WEBROOT}/${LOCK_FILE_NAME}"
    LOCAL_MIRROR_LOCK_FILE="${MIRROR_LOCK_STATE_DIR}/${MIRROR}.json"

    if [ ! -f "${LOCAL_MIRROR_LOCK_FILE}" ]; then
        echo "⚠️ No local mirror lock file found for ${MIRROR}, skipping unlock."
        return 1
    fi

    LOCAL_DATA=$(cat "${LOCAL_MIRROR_LOCK_FILE}")
    LOCAL_HOST=$(echo "${LOCAL_DATA}" | jq -r '.host')

    REMOTE_DATA=$(ssh_with_retry "${BOOTSTRAP_USER}@${MIRROR}" "cat ${MIRROR_LOCK_FILE}" 2>/dev/null)
    REMOTE_HOST=$(echo "${REMOTE_DATA}" | jq -r '.host')

    if [[ "${REMOTE_HOST}" == "${LOCAL_HOST}" ]]; then
        ssh_with_retry "${BOOTSTRAP_USER}@${MIRROR}" "rm -f ${MIRROR_LOCK_FILE}"
        echo "✅ Released mirror lock on ${MIRROR}"
        rm -f "${LOCAL_MIRROR_LOCK_FILE}"
    else
        echo "⚠️ Mirror lock on ${MIRROR} is not owned by us. Skipping release."
    fi
}

function deploy_to_remote_host {
    echo "TODO: implement deploy_to_remote_host"
    return 1
}

function deploy_to_local_host {
    echo "Deploying to localhost..."

    local BOOTSTRAP_FILENAME="$(basename -- $BOOTSTRAP_PATH)"
    local BOOTSTRAP_CHECKSUM_FILENAME="$(basename -- $BOOTSTRAP_CHECKSUM_PATH)"
    local BOOTSTRAP_FILENAME_NEW="${BOOTSTRAP_FILENAME}.new"
    local BOOTSTRAP_CHECKSUM_FILENAME_NEW="${BOOTSTRAP_CHECKSUM_FILENAME}.new"

    mv "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}" "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}.old" &&
    mv "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME_NEW}" "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}" &&
    mv "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME}" "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME}.old" &&
    mv "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME_NEW}" "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME}"
}

function deploy_to_mirror {
    MIRROR="${1}"
    echo "Deploying to mirror ${MIRROR}..."

    local BOOTSTRAP_FILENAME="$(basename -- $BOOTSTRAP_PATH)"
    local BOOTSTRAP_CHECKSUM_FILENAME="$(basename -- $BOOTSTRAP_CHECKSUM_PATH)"
    local BOOTSTRAP_FILENAME_NEW="${BOOTSTRAP_FILENAME}.new"
    local BOOTSTRAP_CHECKSUM_FILENAME_NEW="${BOOTSTRAP_CHECKSUM_FILENAME}.new"

    # Create blank existing files if not already there
    ssh_with_retry "${BOOTSTRAP_USER}@${MIRROR}" "touch -a '${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}' && \
    touch -a '${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME}'"

    if ssh_with_retry "${BOOTSTRAP_USER}@${MIRROR}" "[ -f '${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME_NEW}' ]"; then
        ssh_with_retry "${BOOTSTRAP_USER}@${MIRROR}" "mv '${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}' '${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}.old' && \
            mv '${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME_NEW}' '${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}' && \
            mv '${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME}' '${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME}.old' && \
            mv '${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME_NEW}' '${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME}'"
    else
        echo "${MIRROR} didn't have ${BOOTSTRAP_FILENAME_NEW}! NOT MOVING FILES!"
        return 1    
    fi
}

function deploy {
    # Switch out the old bootstraps for the new one

    # Start with the main host
    if [[ "${BOOTSTRAP_HOST_MODE}" == "remote" ]]; then
        deploy_to_remote_host
        EXIT_CODE=$?
    elif [[ "${BOOTSTRAP_HOST_MODE}" == "local" ]]; then
        deploy_to_local_host
        EXIT_CODE=$?
    fi

    if [ "${EXIT_CODE}" -ne 0 ]; then
        return "${EXIT_CODE}"
    fi

    # Now deploy to each mirror
    BOOTSTRAP_MIRRORS_ARRAY=$(echo "${BOOTSTRAP_MIRRORS}" | jq -r @sh | xargs echo)
    for MIRROR in ${BOOTSTRAP_MIRRORS_ARRAY}
    do
        deploy_to_mirror "${MIRROR}"
        EXIT_CODE=$?
        if [ "${EXIT_CODE}" -ne 0 ]; then
            # Don't enforce, as otherwise a single offline mirror would prevent bootstraps being updated
            echo "Warning: mirror ${MIRROR} failed to deploy. Proceeding anyway..."
        fi
    done

}

function run {

    # Init
    reset
    read_config

    # Create
    create_bootstrap
    EXIT_CODE=$?
    if [ "${EXIT_CODE}" -ne 0 ]; then
        CREATE_BOOTSTRAP_ERRORS=$((CREATE_BOOTSTRAP_ERRORS+1))
        return "${EXIT_CODE}"
    fi

    # Upload
    upload
    EXIT_CODE=$?
    if [ "${EXIT_CODE}" -ne 0 ]; then
        return "${EXIT_CODE}"
    fi

    initiate_lock || return $?

    sync_mirrors

    # Go live
    deploy
    EXIT_CODE=$?
    release_lock 
    find /opt/botstrap/logs -name "botstrap-rclone-*.log" -type f -mtime +7 -exec rm -f {} \; 2>/dev/null
    if [ "${EXIT_CODE}" -ne 0 ]; then
        return "${EXIT_CODE}"
    fi

    return 0
}

function loop {
    init

    while [ true ]; do

        run
        EXIT_CODE=$?
        if [ "${EXIT_CODE}" -ne 0 ]; then
            echo "Retrying in ${RETRY_INTERVAL} seconds..."
            sleep "${RETRY_INTERVAL}"
        else
            echo "Process completed successfully."
            echo "Sleeping for ${BOOTSTRAP_INTERVAL} seconds until next cycle..."
            sleep "${BOOTSTRAP_INTERVAL}"
        fi
        echo

    done

}

loop

