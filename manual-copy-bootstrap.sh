#!/bin/bash

VERSION="1.0.0"

function init {
    echo "Botstrap version ${VERSION}"

    if ! which ssh-copy-id >/dev/null
    then
        echo "Installing ssh..."
        sudo apt-get install ssh -y
    fi

    echo "Important: make sure you have run ssh-copy-id for each host or mirror before using this script."

    CREATE_BOOTSTRAP_ERRORS=0
}

function reset {
    BOOTSTRAP_PATH=""
    BOOTSTRAP_CHECKSUM_PATH=""
}

function read_config {
    CONFIG=$(cat "config.json")
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

    #echo "CONFIG: ${CONFIG}"
}

#function create_bootstrap {
    # Check if we need to restart the node
#    if [ "${CREATE_BOOTSTRAP_ERRORS} " -gt 10 ]; then
#        CREATE_BOOTSTRAP_ERRORS=0

#        # This relies on having a systemd service set up
#        echo "Restarting node due to ${CREATE_BOOTSTRAP_ERRORS} consecutive errors..."
#        sudo service "${NODE_SERVICE}" restart
#        sleep 30
#    fi

#    echo "Attempting to create bootstrap..."

#    URL="http://${NODE_HOST}:${NODE_PORT}/bootstrap/create"
#    RESULT=$(curl -s -X POST --max-time "${TIMEOUT}" "${URL}")
#    # echo "${RESULT}"

#    if [ -z "${RESULT}" ]; then
#        echo "Empty response from create bootstrap API"
#        return 1
#    fi

#    ERROR=$(echo "${RESULT}" | jq -r '.["error"]')
#    if [ ! -z "${ERROR}" ]; then
#        ERROR_MESSAGE=$(echo "${RESULT}" | jq -r '.["message"]')
#        echo "An error occurred: ${ERROR_MESSAGE}"
#        return 2
#    fi

    # Get the path to the extracted bootstrap
#    PATH_RESPONSE="${RESULT}"
#    if [[ ! "${PATH_RESPONSE}" == *".7z" ]]; then
#        echo "Error: invalid path: ${PATH_RESPONSE}"
#        return 3
#    fi

#    echo "Bootstrap created at path: ${PATH_RESPONSE}"
#    BOOTSTRAP_PATH="${PATH_RESPONSE}"
#    BOOTSTRAP_CHECKSUM_PATH="${PATH_RESPONSE}.sha256"
#    CREATE_BOOTSTRAP_ERRORS=0
#    return 0
#}
BOOTSTRAP_PATH="/var/www/html/manual-copy/bootstrap-archive.7z"
BOOTSTRAP_CHECKSUM_PATH="/var/www/html/manual-copy/bootstrap-archive.7z.sha256"
function upload_to_main_host {
    
    local BOOTSTRAP_FILENAME="$(basename -- $BOOTSTRAP_PATH)"
    local BOOTSTRAP_CHECKSUM_FILENAME="$(basename -- $BOOTSTRAP_CHECKSUM_PATH)"
    local BOOTSTRAP_FILENAME_NEW="${BOOTSTRAP_FILENAME}.new"
    local BOOTSTRAP_CHECKSUM_FILENAME_NEW="${BOOTSTRAP_CHECKSUM_FILENAME}.new"

    # Add the host to known hosts, to avoid terminal prompts when adding a new host in the config
    ssh-keyscan "${BOOTSTRAP_HOST}" >> "${HOME}/.ssh/known_hosts"

    # Upload the files
    echo "Uploading ${BOOTSTRAP_PATH} to ${BOOTSTRAP_HOST}:${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME_NEW}..."
    scp "${BOOTSTRAP_PATH}" "${BOOTSTRAP_USER}@${BOOTSTRAP_HOST}:${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME_NEW}"
    
    echo "Uploading ${BOOTSTRAP_CHECKSUM_PATH} to ${BOOTSTRAP_HOST}:${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME_NEW}..."
    scp "${BOOTSTRAP_CHECKSUM_PATH}" "${BOOTSTRAP_USER}@${BOOTSTRAP_HOST}:${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME_NEW}"

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
    COMPUTED_CHECKSUM_REMOTE=$(ssh "${BOOTSTRAP_USER}@${BOOTSTRAP_HOST}" "sha256sum ${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME_NEW}" | awk '{ print $1 }')
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

    # 
    # All good
    echo "Files copied successfully"
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

function sync_mirror {
    MIRROR="${1}"

    echo "Syncing mirror ${MIRROR}..."

    local BOOTSTRAP_FILENAME="$(basename -- $BOOTSTRAP_PATH)"
    local BOOTSTRAP_CHECKSUM_FILENAME="$(basename -- $BOOTSTRAP_CHECKSUM_PATH)"
    local BOOTSTRAP_FILENAME_NEW="${BOOTSTRAP_FILENAME}.new"
    local BOOTSTRAP_CHECKSUM_FILENAME_NEW="${BOOTSTRAP_CHECKSUM_FILENAME}.new"

    # Add the host to known hosts, to avoid terminal prompts when adding a new host in the config
    ssh-keyscan "${MIRROR}" >> "${HOME}/.ssh/known_hosts"

    # # Upload the files
    echo "Uploading ${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME_NEW} to mirror ${MIRROR}:${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME_NEW}..."
    scp "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME_NEW}" "${BOOTSTRAP_USER}@${MIRROR}:${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME_NEW}"
    
    echo "Uploading ${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME_NEW} to mirror ${MIRROR}:${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME_NEW}..."
    scp "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME_NEW}" "${BOOTSTRAP_USER}@${MIRROR}:${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME_NEW}"

    # Check the files are intact
    echo "Checking copied files..."
    local CHECKSUM_URL="http://${MIRROR}/${BOOTSTRAP_CHECKSUM_FILENAME_NEW}"
    local CHECKSUM_REMOTE=$(curl -s "${CHECKSUM_URL}")
    local CHECKSUM_LOCAL=$(cat "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME_NEW}")
    if [ -z "${CHECKSUM_REMOTE}" ]; then
        echo "Error: no checksum could be found on mirror ${MIRROR}"
        return 1
    fi
    if [[ "${CHECKSUM_REMOTE}" != "${CHECKSUM_LOCAL}" ]]; then
        echo "Error: checksum files on mirror do not match the local checksum"
        echo "CHECKSUM_LOCAL: ${CHECKSUM_LOCAL}"
        echo "CHECKSUM_REMOTE: ${CHECKSUM_REMOTE}"
        echo "CHECKSUM_URL: ${CHECKSUM_URL}"
        return 2
    fi

    # Check that the uploaded file matches the checksum file
    echo "Validating checksum..."
    COMPUTED_CHECKSUM_REMOTE=$(ssh "${BOOTSTRAP_USER}@${MIRROR}" "sha256sum ${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME_NEW}" | awk '{ print $1 }')
    if [[ "${COMPUTED_CHECKSUM_REMOTE}" != "${CHECKSUM_LOCAL}" ]]; then
        echo "Error: checksum of file uploaded to mirror ${MIRROR} does not match"
        echo "CHECKSUM_LOCAL: ${CHECKSUM_LOCAL}"
        echo "COMPUTED_CHECKSUM_REMOTE: ${COMPUTED_CHECKSUM_REMOTE}"
        echo "BOOTSTRAP_FILENAME_NEW: ${BOOTSTRAP_FILENAME_NEW}"
        return 3
    fi

    # All good
    return 0
}

function sync_mirrors {
    # Loop through mirrors
    BOOTSTRAP_MIRRORS_ARRAY=$(echo "${BOOTSTRAP_MIRRORS}" | jq -r @sh | xargs echo)
    for MIRROR in ${BOOTSTRAP_MIRRORS_ARRAY}
    do
        sync_mirror "${MIRROR}"
        EXIT_CODE=$?
        if [ "${EXIT_CODE}" -ne 0 ]; then
            # Don't enforce, as otherwise a single offline mirror would prevent bootstraps being updated
            echo "Warning: mirror ${MIRROR} failed to sync. Proceeding anyway..."
        fi
    done
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

    mv "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}" "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}.old" 
    mv "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME_NEW}" "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}" 
    mv "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME}" "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME}.old" 
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
    ssh "${BOOTSTRAP_USER}@${MIRROR}" "touch -a ${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}"
    ssh "${BOOTSTRAP_USER}@${MIRROR}" "touch -a ${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME}"

    # Swap the old and the new bootstraps
    ssh "${BOOTSTRAP_USER}@${MIRROR}" "mv '${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}' '${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}.old'" &&
    ssh "${BOOTSTRAP_USER}@${MIRROR}" "mv '${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME_NEW}' '${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}'" &&
    ssh "${BOOTSTRAP_USER}@${MIRROR}" "mv '${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME}' '${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME}.old'" &&
    ssh "${BOOTSTRAP_USER}@${MIRROR}" "mv '${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME_NEW}' '${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_CHECKSUM_FILENAME}'"
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
#    reset
    read_config

    # Create
#    create_bootstrap
#    EXIT_CODE=$?
#    if [ "${EXIT_CODE}" -ne 0 ]; then
#        CREATE_BOOTSTRAP_ERRORS=$((CREATE_BOOTSTRAP_ERRORS+1))
#        return "${EXIT_CODE}"
#    fi

    # Upload
    upload
    EXIT_CODE=$?
    if [ "${EXIT_CODE}" -ne 0 ]; then
        return "${EXIT_CODE}"
    fi

    sync_mirrors

    # Go live
    deploy
    EXIT_CODE=$?
    if [ "${EXIT_CODE}" -ne 0 ]; then
        return "${EXIT_CODE}"
    fi


    return 0
}

run

#function loop {
#    init
#
#    while [ true ]; do
#
#        run
#        EXIT_CODE=$?
#        if [ "${EXIT_CODE}" -ne 0 ]; then
#            echo "Retrying in ${RETRY_INTERVAL} seconds..."
#            sleep "${RETRY_INTERVAL}"
#        else
#            echo "Process completed successfully."
#            echo "Sleeping for ${BOOTSTRAP_INTERVAL} seconds until next cycle..."
#            sleep "${BOOTSTRAP_INTERVAL}"
#        fi
#        echo
#
#    done
#
#}

#loop
