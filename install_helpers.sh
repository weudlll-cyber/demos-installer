#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# install_helpers.sh
# Creates helper scripts in /root/demos_helpers and symlinks them into /usr/local/bin
# Usage: bash /root/demos_helpers/install_helpers.sh

HELPER_DIR="/root/demos_helpers"
GLOBAL_BIN="/usr/local/bin"
MONITOR_LOG="/var/log/demos_node_monitor.log"

mkdir -p "$HELPER_DIR" "$GLOBAL_BIN" || true

# restart_demos_node
cat > "$HELPER_DIR/restart_demos_node.sh" <<'HR'
#!/bin/bash
set -euo pipefail
systemctl restart demos-node.service
systemctl status demos-node.service --no-pager -l
HR
chmod 755 "$HELPER_DIR/restart_demos_node.sh"

# backup_demos_keys
cat > "$HELPER_DIR/backup_demos_keys.sh" <<'HB'
#!/bin/bash
set -euo pipefail
mkdir -p ~/demos-keys
cp /root/node/publickey ~/demos-keys/publickey 2>/dev/null || true
cp /root/node/privatekey ~/demos-keys/privatekey 2>/dev/null || true
chmod 600 ~/demos-keys/privatekey 2>/dev/null || true
ls -l ~/demos-keys || true
HB
chmod 700 "$HELPER_DIR/backup_demos_keys.sh"

# stop_demos_node
cat > "$HELPER_DIR/stop_demos_node.sh" <<'HS'
#!/bin/bash
set -euo pipefail
systemctl stop demos-node.service || true
systemctl disable --now demos-node.service || true
pgrep -f "/root/node" | xargs -r sudo kill -9 || true
pkill -f "/root/node/run" || true
lsof -ti :5332 | xargs -r sudo kill -9 || true
lsof -ti :53550 | xargs -r sudo kill -9 || true
docker ps -q --filter "name=demos" | xargs -r docker stop || true
rm -f /run/demos-node.pid /var/run/demos-node.pid /root/.demos_node_setup/installer.lock || true
systemctl status demos-node.service --no-pager -l || true
echo "Stop sequence complete"
HS
chmod 755 "$HELPER_DIR/stop_demos_node.sh"

# check_demos_node (enhanced)
cat > "$HELPER_DIR/check_demos_node.sh" <<'HC'
#!/bin/bash
set -euo pipefail

NODE_DIR="/root/node"
SERVICE="demos-node.service"
MON_LOG="/var/log/demos_node_monitor.log"
HEALTH_URL="http://127.0.0.1:53550/health"
AUTORESTART=0
VERBOSE=0

usage(){ echo "Usage: $0 [--status] [--logs=N] [--health] [--autorestart] [--restart] [--verbose]"; exit 1; }

TAIL_LINES=50
for arg in "$@"; do
  case "$arg" in
    --status) ACTION_STATUS=1 ;;
    --logs=*) ACTION_LOGS=1; TAIL_LINES="${arg#*=}" ;;
    --health) ACTION_HEALTH=1 ;;
    --autorestart) AUTORESTART=1 ;;
    --restart) ACTION_RESTART=1 ;;
    --verbose) VERBOSE=1 ;;
    --help) usage ;;
    *) ;;
  esac
done

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$MON_LOG"; }

if [ "${ACTION_STATUS:-0}" = "1" ]; then systemctl status "$SERVICE" --no-pager -l; fi
if [ "${ACTION_LOGS:-0}" = "1" ]; then journalctl -u "$SERVICE" -n "$TAIL_LINES" --no-pager; fi
if [ "${ACTION_RESTART:-0}" = "1" ]; then log "Manual restart requested"; systemctl restart "$SERVICE"; sleep 2; systemctl is-active --quiet "$SERVICE" && log "Service active after restart" || log "Service not active after restart"; exit 0; fi

HEALTH_OK=0

# Check systemd status
if systemctl is-active --quiet "$SERVICE"; then
  log "✅ systemd reports $SERVICE running"
  HEALTH_OK=$((HEALTH_OK+1))
else
  log "❌ systemd reports $SERVICE NOT running"
fi

# Check process presence
PROCESS_FOUND=0
MATCHING_PIDS=$(pgrep -f "$NODE_DIR" || true)
if [ -n "$MATCHING_PIDS" ]; then
  log "✅ Process referencing $NODE_DIR exists"
  PROCESS_FOUND=1
  HEALTH_OK=$((HEALTH_OK+1))
else
  log "❌ No process referencing $NODE_DIR directly"
  WRAPPER_PIDS=$(pgrep -f "run-wrapper.sh" || true)
  if [ -n "$WRAPPER_PIDS" ]; then
    for pid in $WRAPPER_PIDS; do
      CMD=$(ps -p "$pid" -o cmd=)
      log "⚠️ Found wrapper process: PID $pid — $CMD"
    done
    log "⚠️ Node may be running from a wrapper or alternate path"
    PROCESS_FOUND=1
    HEALTH_OK=$((HEALTH_OK+1))
  fi
fi

# Verbose process listing
if [ "$VERBOSE" -eq 1 ]; then
  log "🔍 Verbose process listing:"
  ps aux | grep -E 'run-wrapper|node|bun' | grep -v grep
fi

# Check HTTP health endpoint
if command -v curl >/dev/null 2>&1; then
  if curl -sSf --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
    log "✅ HTTP health endpoint OK: $HEALTH_URL"
    HEALTH_OK=$((HEALTH_OK+1))
  else
    log "❌ HTTP health endpoint failed or not present: $HEALTH_URL"
  fi
else
  log "⚠️ curl not present, skipped HTTP health check"
fi

# Final health summary
if [ "$HEALTH_OK" -ge 3 ]; then
  log "✅ Node appears HEALTHY (score=$HEALTH_OK)"
  exit 0
elif [ "$HEALTH_OK" -eq 2 ]; then
  log "⚠️ Node PARTIALLY HEALTHY (score=2)"
  exit 1
else
  log "❌ Node UNHEALTHY (score=$HEALTH_OK)"
  if [ "$AUTORESTART" -eq 1 ]; then
    log "🔁 Auto-restart enabled — restarting $SERVICE"
    systemctl restart "$SERVICE"
    sleep 3
    systemctl is-active --quiet "$SERVICE" && log "✅ Service active after auto-restart" && exit 0 || log "❌ Still not active" && exit 2
  fi
  exit 2
fi
HC
chmod 755 "$HELPER_DIR/check_demos_node.sh"

# Ensure monitor log exists
touch "$MONITOR_LOG" || true
chown root:root "$MONITOR_LOG" || true
chmod 644 "$MONITOR_LOG" || true

# Create symlinks (including .sh suffix for convenience)
ln -sf "$HELPER_DIR/restart_demos_node.sh" "$GLOBAL_BIN/restart_demos_node"
ln -sf "$HELPER_DIR/backup_demos_keys.sh" "$GLOBAL_BIN/backup_demos_keys"
ln -sf "$HELPER_DIR/stop_demos_node.sh" "$GLOBAL_BIN/stop_demos_node"
ln -sf "$HELPER_DIR/check_demos_node.sh" "$GLOBAL_BIN/check_demos_node"
ln -sf "$HELPER_DIR/check_demos_node.sh" "$GLOBAL_BIN/check_demos_node.sh"
chmod 755 "$GLOBAL_BIN"/check_demos_node* "$GLOBAL_BIN"/restart_demos_node "$GLOBAL_BIN"/backup_demos_keys "$GLOBAL_BIN"/stop_demos_node || true

echo "✅ [OK] Helpers installed to $HELPER_DIR and symlinked to $GLOBAL_BIN"
