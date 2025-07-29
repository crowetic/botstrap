#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# botstrap-auditor.sh
# Audits all bootstrap nodes to ensure they have a complete and valid bootstrap set.
# If any node is missing or stale, rsync the latest from a healthy peer.

CONFIG_FILE="/opt/botstrap/config.json"
AUDIT_LOG_DIR="/opt/botstrap/audit"
TIMESTAMP=$(date +%s)
AUDIT_REPORT_FILE="${AUDIT_LOG_DIR}/audit-${TIMESTAMP}.json"
mkdir -p "$AUDIT_LOG_DIR"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config file not found at $CONFIG_FILE"
  exit 1
fi

CONFIG=$(cat "$CONFIG_FILE")
AUDIT_NODES=$(echo "$CONFIG" | jq -r '.bootstrapAuditNodes[]')
BOOTSTRAP_WEBROOT=$(echo "$CONFIG" | jq -r '.bootstrapWebRoot')
BOOTSTRAP_USER=$(echo "$CONFIG" | jq -r '.bootstrapUser')

function is_local_node {
  NODE="$1"
  LOCAL_HOSTNAME=$(hostname)
  NODE_ID=$(echo "$NODE" | grep -oE 'bootstrap[0-9]+')
  [[ -n "$NODE_ID" && "$LOCAL_HOSTNAME" == *"$NODE_ID"* ]]
}

function rsync_with_retry {
    local SRC="$1"
    local DEST="$2"
    local MAX_RETRIES=3
    local RETRY_DELAY=5
    local attempt=1
    until rsync -raPz --delay-updates --partial-dir=.rsync-tmp "$SRC" "$DEST"; do
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

function ssh_with_retry {
    local host="$1"
    local cmd="$2"
    local retries=4
    local delay=5
    local timeout=20

    for ((i=1; i<=retries; i++)); do
        echo "SSH attempt $i/$retries to $host..."
        ssh -o ConnectTimeout=$timeout -o BatchMode=yes "$host" "$cmd" && return 0
        echo "SSH failed. Retrying in $delay seconds..."
        sleep $delay
        delay=$((delay * 2)) # exponential backoff
    done

    echo "SSH to $host failed after $retries attempts."
    return 1
}

function safe_ssh {
  local HOST="$1"
  shift
  local CMD="$*"
  local TIMEOUT=30  # Seconds to wait before giving up on a hung node

  ssh -o ConnectTimeout=30 -o BatchMode=yes "${BOOTSTRAP_USER}@${HOST}" "timeout $TIMEOUT bash -c $(printf '%q ' "$CMD")" 2>&1
}

function release_cluster_lock {
  echo "Releasing locks on all nodes..."
  for NODE in $AUDIT_NODES; do
    for LOCK in ".auditor.lock" ".botstrap.lock"; do
      if is_local_node "$NODE"; then
        rm -f "${BOOTSTRAP_WEBROOT}/${LOCK}"
      else
        ssh_with_retry "${BOOTSTRAP_USER}@${NODE}" "rm -f ${BOOTSTRAP_WEBROOT}/${LOCK}"
      fi
    done
  done
}

function run_audit {
  BOOTSTRAP_FILENAME="bootstrap-archive.7z"
  CHECKSUM_FILENAME="${BOOTSTRAP_FILENAME}.sha256"
  BLOCK_FILENAME="block.txt"

  echo "{ \"startedAt\": $TIMESTAMP, \"nodes\": [" > "$AUDIT_REPORT_FILE"

  LATEST_NODE=""
  LATEST_BLOCK=-1
  LATEST_TIMESTAMP=0

  for NODE in $AUDIT_NODES; do
    echo "Auditing $NODE..."
    echo "------------------------------------------------------------"
    FILES_PRESENT=true
    SHA_MATCH=true
    BLOCK_HEIGHT=0
    FILE_TIMESTAMP=0
    STATUS="healthy"
    ERROR=""

    if is_local_node "$NODE"; then
      [[ -f "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}" ]] || { FILES_PRESENT=false; STATUS="missing"; ERROR="Missing bootstrap file"; }
      [[ -f "${BOOTSTRAP_WEBROOT}/${CHECKSUM_FILENAME}" ]] || { FILES_PRESENT=false; STATUS="missing"; ERROR="Missing checksum file"; }
      [[ -f "${BOOTSTRAP_WEBROOT}/${BLOCK_FILENAME}" ]] || { FILES_PRESENT=false; STATUS="missing"; ERROR="Missing block.txt"; }

      if [ "$FILES_PRESENT" = true ]; then
        CHECKSUM_REMOTE=$(awk '{print $1}' "${BOOTSTRAP_WEBROOT}/${CHECKSUM_FILENAME}")
        COMPUTED_CHECKSUM=$(sha256sum "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}" | awk '{print $1}')
        BLOCK_LINE=$(head -n 1 "${BOOTSTRAP_WEBROOT}/${BLOCK_FILENAME}" || echo "")
        if [[ "$BLOCK_LINE" =~ ^[0-9]+$ ]]; then
          BLOCK_HEIGHT="$BLOCK_LINE"
        else
          echo "⚠️  Invalid or missing block height from $NODE: '$BLOCK_LINE'" >&2
          BLOCK_HEIGHT=0
        fi
        FILE_TIMESTAMP=$(stat -c %Y "${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}" || echo 0)
        [[ "$FILE_TIMESTAMP" =~ ^[0-9]+$ ]] || FILE_TIMESTAMP=0
      fi

    else
      ssh_with_retry "$NODE" "test -f ${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}" || {
        FILES_PRESENT=false
        STATUS="missing"
        ERROR="Missing bootstrap file"
      }

      ssh_with_retry "$NODE" "test -f ${BOOTSTRAP_WEBROOT}/${CHECKSUM_FILENAME}" || {
        FILES_PRESENT=false
        STATUS="missing"
        ERROR="Missing checksum file"
      }

      ssh_with_retry "$NODE" "test -f ${BOOTSTRAP_WEBROOT}/${BLOCK_FILENAME}" || {
        FILES_PRESENT=false
        STATUS="missing"
        ERROR="Missing block.txt"
      }

      if [ "$FILES_PRESENT" = true ]; then
        CHECKSUM_REMOTE=$(ssh_with_retry "$NODE" "cat ${BOOTSTRAP_WEBROOT}/${CHECKSUM_FILENAME}" | awk '{print $1}' || echo "")
        COMPUTED_CHECKSUM=$(ssh_with_retry "$NODE" "sha256sum ${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}" | awk '{print $1}' || echo "")
        
        BLOCK_LINE=$(ssh_with_retry "$NODE" "head -n 1 ${BOOTSTRAP_WEBROOT}/${BLOCK_FILENAME}" || echo "")
        if [[ "$BLOCK_LINE" =~ ^[0-9]+$ ]]; then
          BLOCK_HEIGHT="$BLOCK_LINE"
        else
          echo "⚠️  Invalid or missing block height from $NODE: '$BLOCK_LINE'" >&2
          BLOCK_HEIGHT=0
          STATUS="missing"
          FILES_PRESENT=false
          ERROR="Missing or invalid block.txt"
        fi

        FILE_TIMESTAMP=$(ssh_with_retry "$NODE" "stat -c %Y ${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}" || echo 0)
        [[ "$FILE_TIMESTAMP" =~ ^[0-9]+$ ]] || FILE_TIMESTAMP=0
      fi

    fi

    if [ "$FILES_PRESENT" = true ] && [ "$CHECKSUM_REMOTE" != "$COMPUTED_CHECKSUM" ]; then
      STATUS="corrupt"
      ERROR="Checksum mismatch"
      SHA_MATCH=false
    fi

    if [ "$FILES_PRESENT" = false ]; then
      echo "  ❌ One or more required files missing on $NODE"
    fi

    if [ "$SHA_MATCH" = false ]; then
      echo "  ❌ Checksum mismatch on $NODE"
    fi

    echo "  🧱 Block height: $BLOCK_HEIGHT"
    echo "  🕒 File timestamp: $FILE_TIMESTAMP"

    if [ "$STATUS" = "healthy" ] && \
      { [ "$BLOCK_HEIGHT" -gt "$LATEST_BLOCK" ] || \
      { [ "$BLOCK_HEIGHT" -eq "$LATEST_BLOCK" ] && [ "$FILE_TIMESTAMP" -gt "$LATEST_TIMESTAMP" ]; }; }; then

      LATEST_NODE="$NODE"
      LATEST_BLOCK="$BLOCK_HEIGHT"
      LATEST_TIMESTAMP="$FILE_TIMESTAMP"
      if [ "$NODE" = "$LATEST_NODE" ]; then
        echo "  ✅ Marked $NODE as latest node (block $LATEST_BLOCK, timestamp $LATEST_TIMESTAMP)"
      fi
    fi

    cat <<EOF >> "$AUDIT_REPORT_FILE"
  {
    "node": "$NODE",
    "status": "$STATUS",
    "blockHeight": $((BLOCK_HEIGHT + 0)),
    "timestamp": $((FILE_TIMESTAMP + 0)),
    "error": "$ERROR"
  },
EOF


  done

  sed -i '$ s/},/}/' "$AUDIT_REPORT_FILE"
  echo "], \"latestNode\": \"$LATEST_NODE\", \"latestBlock\": $LATEST_BLOCK, \"latestTimestamp\": $LATEST_TIMESTAMP }" >> "$AUDIT_REPORT_FILE"

  # Sync outdated/corrupt/missing nodes
  for SYNCNODE in $AUDIT_NODES; do
    TARGET_NODE="$SYNCNODE"  # <-- Keep the actual node being synced
    NODE_TIMESTAMP=$(jq -r ".nodes[] | select(.node==\"$TARGET_NODE\") | .timestamp" "$AUDIT_REPORT_FILE")
    NODE_STATUS=$(jq -r ".nodes[] | select(.node==\"$TARGET_NODE\") | .status" "$AUDIT_REPORT_FILE")
    NODE_BLOCK_HEIGHT=$(jq -r ".nodes[] | select(.node==\"$TARGET_NODE\") | .blockHeight" "$AUDIT_REPORT_FILE")

    echo "🔎 Checking if $TARGET_NODE needs sync:"
    echo "    → Node timestamp: $NODE_TIMESTAMP | Node block: $NODE_BLOCK_HEIGHT | Status: $NODE_STATUS"
    echo "    → Latest timestamp: $LATEST_TIMESTAMP | Latest block: $LATEST_BLOCK | Latest node: $LATEST_NODE"

    if [[ "$NODE_TIMESTAMP" -lt "$LATEST_TIMESTAMP" ]] || \
      [[ "$NODE_STATUS" != "healthy" ]] || \
      [[ "$NODE_BLOCK_HEIGHT" -lt "$LATEST_BLOCK" ]]; then

      if [[ "$TARGET_NODE" == "$LATEST_NODE" ]]; then
        echo "⚠️  Refusing to sync $TARGET_NODE from itself. Skipping."
        continue
      fi

      echo "🔁 Updating $TARGET_NODE from $LATEST_NODE (status: $NODE_STATUS, ts: $NODE_TIMESTAMP)..."

      TMPDIR="/tmp/from-${LATEST_NODE}"
      mkdir -p "$TMPDIR"

      echo "📦 Downloading all files from $LATEST_NODE..."

      if is_local_node "$LATEST_NODE"; then
        rsync_with_retry "${BOOTSTRAP_WEBROOT}/" "$TMPDIR/" || exit 1
      else
        rsync_with_retry "${BOOTSTRAP_USER}@${LATEST_NODE}:${BOOTSTRAP_WEBROOT}/" "$TMPDIR/" || exit 1
      fi

      echo "🚀 Syncing files to $TARGET_NODE..."
      if is_local_node "$TARGET_NODE"; then
        rsync_with_retry "$TMPDIR/" "${BOOTSTRAP_WEBROOT}/"
      else
        rsync_with_retry "$TMPDIR/" "${BOOTSTRAP_USER}@${TARGET_NODE}:${BOOTSTRAP_WEBROOT}/" || continue
      fi

      echo "✅ Node $TARGET_NODE repaired."
    else
      echo "✅ $TARGET_NODE is already up to date."
    fi
  done


  shopt -s nullglob
  TEMP_FILES=(/tmp/*.from.*)
  if (( ${#TEMP_FILES[@]} > 0 )); then
    echo "🧹 Removing temp files..."
    rm -f "${TEMP_FILES[@]}"
  fi
  shopt -u nullglob

  release_cluster_lock
  echo "Audit complete. Report written to $AUDIT_REPORT_FILE"
  echo "$AUDIT_REPORT_FILE" > "$AUDIT_LOG_DIR/latest_audit"
  cp "$AUDIT_REPORT_FILE" "$AUDIT_LOG_DIR/latest_audit.json.tmp"
  mv "$AUDIT_LOG_DIR/latest_audit.json.tmp" "$AUDIT_LOG_DIR/latest_audit.json"
}

while true; do
  run_audit
  echo "🛌 Sleeping for 3000 seconds (50 minutes) before next audit..."
  sleep 3000
done