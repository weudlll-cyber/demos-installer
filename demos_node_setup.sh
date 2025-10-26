#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# demos_node_setup.sh
# Single-file installer: DNS wait, dpkg/apt recovery, installs deps, Docker, Bun,
# clones node, runs installs, creates systemd unit, starts node,
# installs helper scripts and global wrappers, saves a local copy of this installer.
#
# Usage:
# curl -fsSL https://raw.githubusercontent.com/<your-username>/<repo>/main/demos_node_setup.sh -o /root/demos_node_setup.sh && chmod +x /root/demos_node_setup.sh && bash /root/demos_node_setup.sh
# or:
# curl -fsSL https://raw.githubusercontent.com/<your-username>/<repo>/main/demos_node_setup.sh | bash

MARKER_DIR="/root/.demos_node_setup"
TMP_DIR="${MARKER_DIR}/tmp"
LOGFILE="$MARKER_DIR/install.log"
NODE_PATH="/root/node"
SYSTEMD_SERVICE="/etc/systemd/system/demos-node.service"
FIRST_REBOOT_MARKER="${MARKER_DIR}/.first_reboot_pending"
LOCKFILE="$MARKER_DIR/installer.lock"
BUN_PROFILE="/etc/profile.d/bun.sh"
HELPER_DIR="/root/demos_helpers"
GLOBAL_BIN="/usr/local/bin"
MONITOR_LOG="/var/log/demos_node_monitor.log"
RAW_INSTALLER_URL="https://raw.githubusercontent.com/weudlll-cyber/demos-installer/main/demos_node_setup.sh"
HELPERS_INSTALLER_PATH="$HELPER_DIR/install_helpers.sh"
LOCAL_INSTALLER_PATH="/root/demos_node_setup.sh"

mkdir -p "$MARKER_DIR" "$TMP_DIR" "$HELPER_DIR"
chmod 700 "$MARKER_DIR" "$TMP_DIR" 2>/dev/null || true

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }
red(){ echo -e "\033[1;31m$*\033[0m"; }
write_marker(){ printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" > "$TMP_DIR/$1.tmp" && mv -f "$TMP_DIR/$1.tmp" "$MARKER_DIR/$1" && sync; }
marker_exists(){ [ -f "$MARKER_DIR/$1" ]; }

# Prevent parallel runs
exec 200>"$LOCKFILE"
flock -n 200 || { red "❌ Another installer run is active. Exiting."; exit 1; }

# DNS wait for GitHub raw
DNS_OK=0
for i in {1..12}; do
  if ping -c 1 -W 2 raw.githubusercontent.com >/dev/null 2>&1; then DNS_OK=1; break; fi
  red "⏳ Waiting for DNS resolution (attempt $i/12)..."
  sleep 3
done
if [ "$DNS_OK" -ne 1 ]; then red "⚠️ DNS may be unavailable; continuing but consider retrying later."; fi

# dpkg/apt recovery (idempotent)
A_RETRY_MAX=6; A_RETRY_WAIT=5
repair_dpkg_and_apt(){
  systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service >/dev/null 2>&1 || true
  for i in $(seq 1 $A_RETRY_MAX); do
    if pgrep -x dpkg >/dev/null || pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null; then
      echo "Waiting for dpkg/apt to finish (attempt $i/$A_RETRY_MAX)..."
      sleep "$A_RETRY_WAIT"
    else
      break
    fi
  done
  if pgrep -x dpkg >/dev/null || pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null; then
    echo "Killing stale dpkg/apt processes"
    pkill -9 dpkg || true
    pkill -9 apt || true
    pkill -9 apt-get || true
    sleep 1
  fi
  if ! pgrep -x dpkg >/dev/null && ! pgrep -x apt >/dev/null && ! pgrep -x apt-get >/dev/null; then
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock || true
  fi
  local n=0
  until dpkg --configure -a >/dev/null 2>&1 && apt-get install -f -y >/dev/null 2>&1; do
    n=$((n+1))
    echo "dpkg/apt recovery attempt $n failed"
    [ "$n" -ge "$A_RETRY_MAX" ] && return 1
    sleep "$A_RETRY_WAIT"
  done
  apt-get update -y >/dev/null 2>&1 || true
  return 0
}
repair_dpkg_and_apt || { red "❌ dpkg/apt recovery failed; run 'sudo dpkg --configure -a' manually."; exit 1; }

# apt wrapper with retries
apt_run(){ local cmd="$*"; for i in {1..12}; do systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service >/dev/null 2>&1 || true; if bash -c "$cmd"; then return 0; fi; sleep 3; done; red "❌ apt command failed after retries: $cmd"; return 1; }

# One-time reboot logic (15s)
if ! marker_exists first_run_reboot_done && ! marker_exists first_run_reboot_scheduled; then
  write_marker first_run_reboot_scheduled
  touch "$FIRST_REBOOT_MARKER"
  red "🚨 One-time reboot in 15s to finalize system upgrades"
  red "After reboot, re-run the same command or execute $LOCAL_INSTALLER_PATH if saved"
  sleep 15
  reboot
  exit 0
fi
if marker_exists first_run_reboot_scheduled && ! marker_exists first_run_reboot_done; then
  write_marker first_run_reboot_done
  rm -f "$FIRST_REBOOT_MARKER" || true
  red "✅ Post-reboot: continuing install"
fi

# Install unzip and curl
if ! command -v unzip >/dev/null || ! command -v curl >/dev/null; then
  red "📦 Installing unzip and curl"
  apt_run "apt-get update -y"
  apt_run "apt-get install -y unzip curl"
else
  red "⏭️ Skipping unzip/curl install"
fi
write_marker unzip_installed

# System update and base deps
if ! marker_exists system_updated; then
  red "📦 Updating system and installing base packages"
  apt_run "apt-get update -y"
  apt_run "apt-get upgrade -y"
  apt_run "apt-get install -y ca-certificates gnupg lsb-release wget git build-essential jq lsof software-properties-common gpg"
  write_marker system_updated
else
  red "⏭️ System update already done"
fi

# Docker install
if ! command -v docker >/dev/null; then
  red "📦 Installing Docker"
  apt_run "apt-get remove -y docker docker-engine docker.io containerd runc || true"
  install -m 0755 -d /etc/apt/keyrings || true
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  apt_run "apt-get update -y"
  apt_run "apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin"
  systemctl enable --now docker || true
else
  red "⏭️ Docker already installed"
fi
write_marker docker_installed

# Bun install
if ! command -v bun >/dev/null; then
  red "📦 Installing Bun"
  curl -fsSL https://bun.sh/install | bash || true
  if [ -d "$HOME/.bun/bin" ]; then
    cat > "$BUN_PROFILE" <<'EOF'
export BUN_INSTALL="$HOME/.bun"
export PATH="$HOME/.bun/bin:$PATH"
EOF
    chmod 644 "$BUN_PROFILE" || true
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$HOME/.bun/bin:$PATH"
  fi
else
  red "⏭️ Bun already present"
fi
write_marker bun_installed

# Clone node repo
if [ ! -d "$NODE_PATH" ]; then
  red "🌱 Cloning node repository (branch: testnet)"
  git clone -b testnet https://github.com/kynesyslabs/node.git "$NODE_PATH" || red "❌ Git clone failed; check network or repo URL"
else
  red "⏭️ Node repo already cloned"
fi
write_marker node_cloned

# Install node deps with bun postinstall recovery
if [ -d "$NODE_PATH" ]; then
  pushd "$NODE_PATH" >/dev/null
  red "📦 Installing node dependencies (bun preferred, fallback npm)"
  if command -v bun >/dev/null; then
    if bun install 2>&1 | tee "$TMP_DIR/bun_install.log"; then
      red "✅ bun install completed"
    else
      red "⚠️ bun install reported issues; attempting bun postinstall recovery"
      if bun pm untrusted --yes >/dev/null 2>&1; then
        red "✅ bun pm untrusted --yes applied"
      else
        red "ℹ️ bun pm untrusted --yes not available; running bun pm untrusted (interactive approval may be needed)"
        bun pm untrusted || true
      fi
      red "🔁 Re-running bun install"
      bun install 2>&1 | tee -a "$TMP_DIR/bun_install.log" || true
    fi
  else
    red "ℹ️ bun not found; falling back to npm install"
    npm install || true
  fi
  popd >/dev/null
else
  red "❌ Node directory missing; clone failed earlier"
fi

# run-wrapper for systemd
mkdir -p "$NODE_PATH"
cat > "$NODE_PATH/run-wrapper.sh" <<'EOF'
#!/bin/bash
export BUN_INSTALL=/root/.bun
export PATH=/root/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cd /root/node
exec /bin/bash ./run
EOF
chmod +x "$NODE_PATH/run-wrapper.sh" || true
write_marker run_wrapper_created

# systemd service
cat > "$SYSTEMD_SERVICE" <<'EOF'
[Unit]
Description=Demos Node
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=root
WorkingDirectory=/root/node
ExecStart=/root/node/run-wrapper.sh
Restart=always
RestartSec=5
KillMode=process
LimitNOFILE=65536
Environment=PATH=/root/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=BUN_INSTALL=/root/.bun

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now demos-node.service || true
write_marker systemd_installed

# Wait for key generation (up to 60s)
if [ -f "$NODE_PATH/publickey" ] && [ -f "$NODE_PATH/privatekey" ]; then
  chmod 600 "$NODE_PATH/privatekey" || true
  write_marker keys_generated
  red "✅ Node keys present"
else
  red "⏳ Waiting up to 60s for node to generate keys"
  for i in {1..60}; do
    [ -f "$NODE_PATH/publickey" ] && [ -f "$NODE_PATH/privatekey" ] && break
    sleep 1
  done
  if [ -f "$NODE_PATH/publickey" ] && [ -f "$NODE_PATH/privatekey" ]; then
    chmod 600 "$NODE_PATH/privatekey" || true
    write_marker keys_generated
    red "✅ Keys detected"
  else
    red "⚠️ Keys not detected after wait; check node logs later"
  fi
fi

# .env and demos_peerlist.json
if ! marker_exists node_configured; then
  PUBLIC_IP="$(curl -s --max-time 5 https://api.ipify.org || echo 127.0.0.1)"
  log "Detected public IP: $PUBLIC_IP"
  red "🌐 Writing .env and demos_peerlist.json using $PUBLIC_IP"
  echo "EXPOSED_URL=http://$PUBLIC_IP:53550" > "$NODE_PATH/.env"
  if [ -f "$NODE_PATH/publickey" ]; then
    PUBKEY="$(tr -d '\r\n' < "$NODE_PATH/publickey")"
    printf '{"%s":"http://%s:53550"}\n' "$PUBKEY" "$PUBLIC_IP" > "$NODE_PATH/demos_peerlist.json"
  fi
  write_marker node_configured
else
  red "⏭️ Node already configured"
fi

# Free port 5332 if occupied
if command -v lsof >/dev/null && lsof -i :5332 &>/dev/null; then
  red "🧹 Freeing port 5332"
  lsof -t -i :5332 | xargs -r kill || true
  sleep 2
fi

# Restart service and verify
systemctl restart demos-node.service || true
sleep 2
if systemctl is-active --quiet demos-node.service; then
  red "✅ Node service is active"
else
  red "⚠️ Node service not active — inspect: journalctl -u demos-node.service -n 200 --no-pager"
fi

# Minimal helpers (created so helpers installer can run)
cat > "$HELPER_DIR/restart_demos_node.sh" <<'EOF'
#!/bin/bash
systemctl restart demos-node.service
systemctl status demos-node.service --no-pager -l
EOF
chmod +x "$HELPER_DIR/restart_demos_node.sh" || true

cat > "$HELPER_DIR/backup_demos_keys.sh" <<'EOF'
#!/bin/bash
mkdir -p ~/demos-keys
cp /root/node/publickey ~/demos-keys/publickey 2>/dev/null || true
cp /root/node/privatekey ~/demos-keys/privatekey 2>/dev/null || true
chmod 600 ~/demos-keys/privatekey 2>/dev/null || true
ls -l ~/demos-keys || true
EOF
chmod +x "$HELPER_DIR/backup_demos_keys.sh" || true

# Create helpers installer (clean, single-purpose)
cat > "$HELPERS_INSTALLER_PATH" <<'EOF'
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

HELPER_DIR="/root/demos_helpers"
GLOBAL_BIN="/usr/local/bin"
MONITOR_LOG="/var/log/demos_node_monitor.log"

mkdir -p "$HELPER_DIR" "$GLOBAL_BIN" || true

# restart helper
cat > "$HELPER_DIR/restart_demos_node.sh" <<'EOF2'
#!/bin/bash
systemctl restart demos-node.service
systemctl status demos-node.service --no-pager -l
EOF2
chmod +x "$HELPER_DIR/restart_demos_node.sh"

# backup keys
cat > "$HELPER_DIR/backup_demos_keys.sh" <<'EOF2'
#!/bin/bash
mkdir -p ~/demos-keys
cp /root/node/publickey ~/demos-keys/publickey 2>/dev/null || true
cp /root/node/privatekey ~/demos-keys/privatekey 2>/dev/null || true
chmod 600 ~/demos-keys/privatekey 2>/dev/null || true
ls -l ~/demos-keys || true
EOF2
chmod +x "$HELPER_DIR/backup_demos_keys.sh"

# stop helper
cat > "$HELPER_DIR/stop_demos_node.sh" <<'EOF2'
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
EOF2
chmod +x "$HELPER_DIR/stop_demos_node.sh"

# health-check script
cat > "$HELPER_DIR/check_demos_node.sh" <<'EOF2'
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
EOF2
chmod +x "$HELPER_DIR/check_demos_node.sh"

# Install global wrappers
ln -sf "$HELPER_DIR/restart_demos_node.sh" /usr/local/bin/restart_demos_node
ln -sf "$HELPER_DIR/backup_demos_keys.sh" /usr/local/bin/backup_demos_keys
ln -sf "$HELPER_DIR/stop_demos_node.sh" /usr/local/bin/stop_demos_node
ln -sf "$HELPER_DIR/check_demos_node.sh" /usr/local/bin/check_demos_node
chmod +x /usr/local/bin/restart_demos_node /usr/local/bin/backup_demos_keys /usr/local/bin/stop_demos_node /usr/local/bin/check_demos_node || true

# Ensure monitor log exists
touch "$MONITOR_LOG" || true; chown root:root "$MONITOR_LOG" || true; chmod 644 "$MONITOR_LOG" || true

# Save a local copy of the installer (best-effort)
if command -v curl >/dev/null 2>&1; then
  red "💾 Saving a local copy of the installer to $LOCAL_INSTALLER_PATH"
  curl -fsSL "$RAW_INSTALLER_URL" -o "$LOCAL_INSTALLER_PATH" || red "⚠️ Could not download raw installer to $LOCAL_INSTALLER_PATH"
  chmod +x "$LOCAL_INSTALLER_PATH" || true
else
  red "⚠️ curl not available; local copy not saved automatically"
fi

write_marker helpers_created
write_marker install_complete

red "🎉 Full install complete."
red "Global commands now available: restart_demos_node backup_demos_keys stop_demos_node check_demos_node"
red "Installer saved at: $LOCAL_INSTALLER_PATH"
red "Markers: $MARKER_DIR — remove a marker to re-run a step."

exit 0
