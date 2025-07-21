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

function acquire_cluster_lock {
  for NODE in $AUDIT_NODES; do
    echo "Checking lock on $NODE..."
    REMOTE_LOCK_FILE="${BOOTSTRAP_WEBROOT}/.auditor.lock" 

    if is_local_node "$NODE"; then
      if [ -f "$REMOTE_LOCK_FILE" ]; then
        LOCK_DATA=$(cat "$REMOTE_LOCK_FILE")
        LOCK_TS=$(echo "$LOCK_DATA" | jq -r '.timestamp // 0')
        AGE=$(( $(date +%s) - LOCK_TS ))
        if [ "$AGE" -lt 300 ]; then
          echo "❌ Lock already exists and is fresh on $NODE (age ${AGE}s). Exiting."
          echo "{\"node\": \"$NODE\", \"auditAttemptedAt\": $(date +%s), \"lockedBy\": $LOCK_DATA}" >> "$AUDIT_LOG_DIR/lock-attempts.log"
          exit 0
        else
          echo "⚠️  Stale lock detected on $NODE (age ${AGE}s). Removing..."
          echo "{\"node\": \"$NODE\", \"auditAttemptedAt\": $(date +%s), \"lockedBy\": $LOCK_DATA, \"staleLockFound\": \"$REMOTE_LOCK_FILE\"}" >> "$AUDIT_LOG_DIR/lock-attempts.log"
          rm -f "$REMOTE_LOCK_FILE"
        fi
      fi
    else
      ssh_cmd=(ssh "${BOOTSTRAP_USER}@${NODE}")
      if "${ssh_cmd[@]}" "[ -f ${REMOTE_LOCK_FILE} ]"; then
        LOCK_DATA=$("${ssh_cmd[@]}" "cat ${REMOTE_LOCK_FILE}" 2>/dev/null || echo '{}')
        LOCK_TS=$(echo "$LOCK_DATA" | jq -r '.timestamp // 0')
        AGE=$(( $(date +%s) - LOCK_TS ))
        if [ "$AGE" -lt 300 ]; then
          echo "❌ Lock already exists and is fresh on $NODE (age ${AGE}s). Exiting."
          echo "{\"node\": \"$NODE\", \"auditAttemptedAt\": $(date +%s), \"lockedBy\": $LOCK_DATA}" >> "$AUDIT_LOG_DIR/lock-attempts.log"
          exit 0
        else
          echo "⚠️  Stale lock detected on $NODE (age ${AGE}s). Removing..."
          echo "{\"node\": \"$NODE\", \"auditAttemptedAt\": $(date +%s), \"lockedBy\": $LOCK_DATA, \"staleLockFound\": \"$REMOTE_LOCK_FILE\"}" >> "$AUDIT_LOG_DIR/lock-attempts.log"
          "${ssh_cmd[@]}" "rm -f ${REMOTE_LOCK_FILE}"
        fi
      fi
    fi
  done

  echo "✅ No active audit detected. Setting locks on all nodes..."
  for NODE in $AUDIT_NODES; do
    LOCK_PAYLOAD="{\"host\": \"$(hostname)\", \"timestamp\": $(date +%s)}"
    if is_local_node "$NODE"; then
      echo "$LOCK_PAYLOAD" > "${BOOTSTRAP_WEBROOT}/.auditor.lock"
    else
      ssh_cmd=(ssh "${BOOTSTRAP_USER}@${NODE}")
      echo "$LOCK_PAYLOAD" | "${ssh_cmd[@]}" "cat > ${BOOTSTRAP_WEBROOT}/.auditor.lock"
    fi
  done
}

function release_cluster_lock {
  echo "Releasing locks on all nodes..."
  for NODE in $AUDIT_NODES; do
    if is_local_node "$NODE"; then
      rm -f "${BOOTSTRAP_WEBROOT}/.auditor.lock"
    else
      ssh_cmd=(ssh "${BOOTSTRAP_USER}@${NODE}")
      "${ssh_cmd[@]}" "rm -f ${BOOTSTRAP_WEBROOT}/.auditor.lock"
    fi
  done
}

function run_audit {
  BOOTSTRAP_FILENAME="bootstrap-archive.7z"
  CHECKSUM_FILENAME="${BOOTSTRAP_FILENAME}.sha256"
  BLOCK_FILENAME="block.txt"

  acquire_cluster_lock

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

      if [ "$FILES_PRESENT" = true ]; then
        echo "✅ All required files exist on $NODE."
        echo "→ Getting checksum from $NODE..."
        echo "→ Getting block height from $NODE..."
        echo "→ Getting file timestamp from $NODE..."
      else
        echo "❌ Missing required file(s) on $NODE: $ERROR"
      fi

      if [ "$CHECKSUM_REMOTE" != "$COMPUTED_CHECKSUM" ]; then
        echo "❌ Checksum mismatch on $NODE!"
        echo "→ Expected: $CHECKSUM_REMOTE"
        echo "→ Actual  : $COMPUTED_CHECKSUM"
      else
        echo "✅ Checksum matches."
      fi

      echo "→ Block height on $NODE: $BLOCK_HEIGHT"
      echo "→ File timestamp: $FILE_TIMESTAMP"
      echo "📦 Status for $NODE → $STATUS (Block: $BLOCK_HEIGHT | Timestamp: $FILE_TIMESTAMP)"
      echo "------------------------------------------------------------"

    else
      ssh_cmd=(ssh "${BOOTSTRAP_USER}@${NODE}")

      "${ssh_cmd[@]}" "test -f ${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}" || { FILES_PRESENT=false; STATUS="missing"; ERROR="Missing bootstrap file"; }
      "${ssh_cmd[@]}" "test -f ${BOOTSTRAP_WEBROOT}/${CHECKSUM_FILENAME}" || { FILES_PRESENT=false; STATUS="missing"; ERROR="Missing checksum file"; }
      "${ssh_cmd[@]}" "test -f ${BOOTSTRAP_WEBROOT}/${BLOCK_FILENAME}" || { FILES_PRESENT=false; STATUS="missing"; ERROR="Missing block.txt"; }

      if [ "$FILES_PRESENT" = true ]; then
        CHECKSUM_REMOTE=$("${ssh_cmd[@]}" "cat ${BOOTSTRAP_WEBROOT}/${CHECKSUM_FILENAME}" | awk '{print $1}')
        COMPUTED_CHECKSUM=$("${ssh_cmd[@]}" "sha256sum ${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}" | awk '{print $1}')
        BLOCK_LINE=$("${ssh_cmd[@]}" "head -n 1 ${BOOTSTRAP_WEBROOT}/${BLOCK_FILENAME}" 2>/dev/null || echo "")
        if [[ "$BLOCK_LINE" =~ ^[0-9]+$ ]]; then
          BLOCK_HEIGHT="$BLOCK_LINE"
        else
          echo "⚠️  Invalid or missing block height from $NODE: '$BLOCK_LINE'" >&2
          BLOCK_HEIGHT=0
        fi
        FILE_TIMESTAMP=$("${ssh_cmd[@]}" "stat -c %Y ${BOOTSTRAP_WEBROOT}/${BOOTSTRAP_FILENAME}" || echo 0)
        [[ "$FILE_TIMESTAMP" =~ ^[0-9]+$ ]] || FILE_TIMESTAMP=0
      fi
    fi

    if [ "$FILES_PRESENT" = true ] && [ "$CHECKSUM_REMOTE" != "$COMPUTED_CHECKSUM" ]; then
      STATUS="corrupt"
      ERROR="Checksum mismatch"
      SHA_MATCH=false
    fi

    if [ "$BLOCK_HEIGHT" -gt "$LATEST_BLOCK" ]; then
      LATEST_NODE="$NODE"
      LATEST_BLOCK="$BLOCK_HEIGHT"
      LATEST_TIMESTAMP="$FILE_TIMESTAMP"
    fi

    if [ "$FILES_PRESENT" = true ]; then
      echo "✅ All required files exist on $NODE."
      echo "→ Getting checksum from $NODE..."
      echo "→ Getting block height from $NODE..."
      echo "→ Getting file timestamp from $NODE..."
    else
      echo "❌ Missing required file(s) on $NODE: $ERROR"
    fi

    if [ "$CHECKSUM_REMOTE" != "$COMPUTED_CHECKSUM" ]; then
      echo "❌ Checksum mismatch on $NODE!"
      echo "→ Expected: $CHECKSUM_REMOTE"
      echo "→ Actual  : $COMPUTED_CHECKSUM"
    else
      echo "✅ Checksum matches."
    fi

    echo "→ Block height on $NODE: $BLOCK_HEIGHT"
    echo "→ File timestamp: $FILE_TIMESTAMP"
    echo "📦 Status for $NODE → $STATUS (Block: $BLOCK_HEIGHT | Timestamp: $FILE_TIMESTAMP)"
    echo "------------------------------------------------------------"

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
  echo "], \"latestNode\": \"$LATEST_NODE\", \"latestBlock\": $LATEST_BLOCK }" >> "$AUDIT_REPORT_FILE"

  for NODE in $AUDIT_NODES; do
    NODE_TIMESTAMP=$(jq -r ".nodes[] | select(.node==\"$NODE\") | .timestamp" "$AUDIT_REPORT_FILE")
    NODE_STATUS=$(jq -r ".nodes[] | select(.node==\"$NODE\") | .status" "$AUDIT_REPORT_FILE")

    if [[ "$NODE_TIMESTAMP" -lt "$LATEST_TIMESTAMP" ]] || [[ "$NODE_STATUS" != "healthy" ]] || [[ "$BLOCK_HEIGHT" -lt "$LATEST_BLOCK" ]]; then
      echo "🔁 Updating $NODE from $LATEST_NODE (status: $NODE_STATUS, ts: $NODE_TIMESTAMP)..."
      for FILE in "$BOOTSTRAP_FILENAME" "$CHECKSUM_FILENAME" "$BLOCK_FILENAME"; do
        if is_local_node "$NODE"; then
          rsync_with_retry "${BOOTSTRAP_WEBROOT}/${FILE}" "${BOOTSTRAP_WEBROOT}/${FILE}"
        elif is_local_node "$LATEST_NODE"; then
          rsync_with_retry "${BOOTSTRAP_WEBROOT}/${FILE}" "${BOOTSTRAP_USER}@${NODE}:${BOOTSTRAP_WEBROOT}/${FILE}"
        else
          TMPFILE="/tmp/${FILE}.from.${LATEST_NODE}"
          rsync_with_retry "${BOOTSTRAP_USER}@${LATEST_NODE}:${BOOTSTRAP_WEBROOT}/${FILE}" "$TMPFILE" || continue
          rsync_with_retry "$TMPFILE" "${BOOTSTRAP_USER}@${NODE}:${BOOTSTRAP_WEBROOT}/${FILE}"
          rm -f "$TMPFILE"
        fi
      done
      echo "Node $NODE repaired."
    fi
  done

  release_cluster_lock
  echo "Audit complete. Report written to $AUDIT_REPORT_FILE"
  echo "$AUDIT_REPORT_FILE" > "$AUDIT_LOG_DIR/latest_audit"
  cp "$AUDIT_REPORT_FILE" "$AUDIT_LOG_DIR/latest_audit.json"
  echo "📝 Latest audit saved to: $AUDIT_LOG_DIR/latest_audit.json"
}

while true; do
  run_audit
  echo "🛌 Sleeping for 7200 seconds (120 minutes) before next audit..."
  sleep 7200
done
