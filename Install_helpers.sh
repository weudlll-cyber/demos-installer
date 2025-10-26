#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# install_helpers.sh
# Installs full helper scripts, health-check, and global wrappers.

HELPER_DIR="/root/demos_helpers"
GLOBAL_BIN="/usr/local/bin"
MONITOR_LOG="/var/log/demos_node_monitor.log"

mkdir -p "$HELPER_DIR" "$GLOBAL_BIN" || true

# restart helper
cat > "$HELPER_DIR/restart_demos_node.sh" <<'EOF'
#!/bin/bash
systemctl restart demos-node.service
systemctl status demos-node.service --no-pager -l
EOF
chmod +x "$HELPER_DIR/restart_demos_node.sh"

# backup keys
cat > "$HELPER_DIR/backup_demos_keys.sh" <<'EOF'
#!/bin/bash
mkdir -p ~/demos-keys
cp /root/node/publickey ~/demos-keys/publickey 2>/dev/null || true
cp /root/node/privatekey ~/demos-keys/privatekey 2>/dev/null || true
chmod 600 ~/demos-keys/privatekey 2>/dev/null || true
ls -l ~/demos-keys || true
EOF
chmod +x "$HELPER_DIR/backup_demos_keys.sh"

# stop helper
cat > "$HELPER_DIR/stop_demos_node.sh" <<'EOF'
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
EOF
chmod +x "$HELPER_DIR/stop_demos_node.sh"

# health-check script
cat > "$HELPER_DIR/check_demos_node.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
NODE_DIR="/root/node"
SERVICE="demos-node.service"
MON_LOG="/var/log/demos_node_monitor.log"
HEALTH_URL="http://127.0.0.1:53550/health"
AUTORESTART=0

usage(){ echo "Usage: $0 [--status] [--logs=N] [--health] [--autorestart] [--restart]"; exit 1; }

TAIL_LINES=50
for arg in "$@"; do
  case "$arg" in
    --status) ACTION_STATUS=1 ;;
    --logs=*) ACTION_LOGS=1; TAIL_LINES="${arg#*=}" ;;
    --health) ACTION_HEALTH=1 ;;
    --autorestart) AUTORESTART=1 ;;
    --restart) ACTION_RESTART=1 ;;
    --help) usage ;;
    *) ;;
  esac
done

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$MON_LOG"; }

if [ "${ACTION_STATUS:-0}" = "1" ]; then systemctl status "$SERVICE" --no-pager -l; fi
if [ "${ACTION_LOGS:-0}" = "1" ]; then journalctl -u "$SERVICE" -n "$TAIL_LINES" --no-pager; fi
if [ "${ACTION_RESTART:-0}" = "1" ]; then log "Manual restart requested"; systemctl restart "$SERVICE"; sleep 2; systemctl is-active --quiet "$SERVICE" && log "Service active after restart" || log "Service not active after restart"; exit 0; fi

HEALTH_OK=0
if systemctl is-active --quiet "$SERVICE"; then log "systemd reports $SERVICE running"; HEALTH_OK=1; else log "systemd reports $SERVICE NOT running"; HEALTH_OK=0; fi
if pgrep -f "/root/node" >/dev/null 2>&1; then log "Process referencing /root/node exists"; HEALTH_OK=$((HEALTH_OK+1)); else log "No process referencing /root/node"; fi
if command -v curl >/dev/null 2>&1; then
  if curl -sSf --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then log "HTTP health endpoint OK: $HEALTH_URL"; HEALTH_OK=$((HEALTH_OK+1)); else log "HTTP health endpoint failed or not present: $HEALTH_URL"; fi
else log "curl not present, skipped HTTP health check"; fi

if [ "$HEALTH_OK" -ge 2 ]; then log "Node appears HEALTHY (score=$HEALTH_OK)"; exit 0; else log "Node UNHEALTHY (score=$HEALTH_OK)"; if [ "$AUTORESTART" -eq 1 ]; then log "Auto-restart enabled"; systemctl restart "$SERVICE"; sleep 3; systemctl is-active --quiet "$SERVICE" && log "Service active after auto-restart" && exit 0 || log "Still not active" && exit 2; fi; exit 2; fi
EOF
chmod +x "$HELPER_DIR/check_demos_node.sh"

# install global wrappers
ln -sf "$HELPER_DIR/restart_demos_node.sh" /usr/local/bin/restart_demos_node
ln -sf "$HELPER_DIR/backup_demos_keys.sh" /usr/local/bin/backup_demos_keys
ln -sf "$HELPER_DIR/stop_demos_node.sh" /usr/local/bin/stop_demos_node
ln -sf "$HELPER_DIR/check_demos_node.sh" /usr/local/bin/check_demos_node
chmod +x /usr/local/bin/restart_demos_node /usr/local/bin/backup_demos_keys /usr/local/bin/stop_demos_node /usr/local/bin/check_demos_node || true

# ensure monitor log exists
touch "$MONITOR_LOG" || true; chown root:root "$MONITOR_LOG" || true; chmod 644 "$MONITOR_LOG" || true

echo "Helpers installed. Global commands: restart_demos_node backup_demos_keys stop_demos_node check_demos_node"
