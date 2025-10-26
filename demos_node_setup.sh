#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Fully standalone installer
# - repairs apt/dpkg
# - installs unzip/curl, Docker, Bun
# - clones node repo (testnet branch)
# - installs node deps (bun preferred, fallback npm)
# - creates run-wrapper and systemd unit
# - waits for keys and writes .env + demos_peerlist.json
# - creates embedded helper scripts and global symlinks
# - prints every major step in red for visibility
# - saves a local copy of the installer robustly (no harmless chmod error)
# - triggers a reboot automatically if certain steps require it (see NOTE)
#
# NOTE about reboot behaviour: This script WILL perform a reboot automatically
# if it determines a reboot is necessary from performed actions (system upgrade,
# Docker install, kernel/package conditions). It will announce the reboot in red
# and wait 15s before calling reboot. You asked for this behavior explicitly.
#
# Usage:
#  curl -fsSL <raw-url> -o /root/demos_node_setup.sh && chmod +x /root/demos_node_setup.sh && bash /root/demos_node_setup.sh
#  OR
#  curl -fsSL <raw-url> | bash
#
# If you run the piped form, the script will still try to save a local copy using
# RAW_INSTALLER_URL if you set it below.

MARKER_DIR="/root/.demos_node_setup"
TMP_DIR="${MARKER_DIR}/tmp"
LOGFILE="$MARKER_DIR/install.log"
NODE_PATH="/root/node"
SYSTEMD_SERVICE="/etc/systemd/system/demos-node.service"
LOCKFILE="$MARKER_DIR/installer.lock"
BUN_PROFILE="/etc/profile.d/bun.sh"
HELPER_DIR="/root/demos_helpers"
GLOBAL_BIN="/usr/local/bin"
MONITOR_LOG="/var/log/demos_node_monitor.log"
LOCAL_INSTALLER_PATH="/root/demos_node_setup.sh"

# If you run via pipe and you have published the raw URL, set it here before running.
# e.g.: RAW_INSTALLER_URL="https://raw.githubusercontent.com/weudlll-cyber/demos-installer/main/demos_node_setup.sh"
RAW_INSTALLER_URL=""

mkdir -p "$MARKER_DIR" "$TMP_DIR" "$HELPER_DIR"
chmod 700 "$MARKER_DIR" "$TMP_DIR" 2>/dev/null || true

red(){ echo -e "\033[1;31m$*\033[0m"; }
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }

write_marker(){ printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" > "$TMP_DIR/$1.tmp" && mv -f "$TMP_DIR/$1.tmp" "$MARKER_DIR/$1" && sync; }
marker_exists(){ [ -f "$MARKER_DIR/$1" ]; }

# Track whether actions require a reboot
NEED_REBOOT=0
mark_reboot_needed(){ NEED_REBOOT=1; write_marker "reboot_required"; }

# Prevent parallel runs
exec 200>"$LOCKFILE"
flock -n 200 || { red "❌ [LOCK] Another installer run is active. Exiting."; exit 1; }

# Utility: apt with retries
apt_run(){ local cmd="$*"; for i in {1..8}; do systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service >/dev/null 2>&1 || true; if bash -c "$cmd"; then return 0; fi; sleep 3; done; red "❌ [APT] Command failed after retries: $cmd"; return 1; }

# Repair dpkg/apt (idempotent)
red "🔧 [STEP] Repairing apt/dpkg (idempotent)"
repair_dpkg_and_apt(){
  systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service >/dev/null 2>&1 || true
  for i in {1..6}; do
    if pgrep -x dpkg >/dev/null || pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null; then
      red "⏳ [WAIT] Waiting for apt/dpkg (attempt $i/6)..."
      sleep 3
    else
      break
    fi
  done
  rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock || true
  pkill -9 dpkg apt apt-get 2>/dev/null || true
  dpkg --configure -a >/dev/null 2>&1 || true
  apt-get update -y >/dev/null 2>&1 || true
}
repair_dpkg_and_apt

# Install unzip and curl
if ! marker_exists unzip_installed; then
  red "🔧 [STEP] Ensuring unzip and curl are installed"
  if ! command -v unzip >/dev/null || ! command -v curl >/dev/null; then
    apt_run "apt-get update -y"
    apt_run "apt-get install -y unzip curl"
    red "✅ [OK] unzip/curl installed"
  else
    red "⏭️ [SKIP] unzip and curl already present"
  fi
  write_marker unzip_installed
fi

# Base system packages (this may include kernel or important packages)
if ! marker_exists system_updated; then
  red "🔧 [STEP] Updating system and installing base packages"
  apt_run "apt-get update -y"
  apt_run "apt-get upgrade -y"
  # If upgrade installed packages that may require reboot, detect /var/run/reboot-required
  if [ -f /var/run/reboot-required ]; then
    red "⚠️ [REBOOT] Packages updated require reboot"
    mark_reboot_needed
  fi
  apt_run "apt-get install -y ca-certificates gnupg lsb-release wget git build-essential jq lsof software-properties-common gpg"
  red "✅ [OK] Base packages installed"
  write_marker system_updated
fi

# Install Docker if missing (Docker apt install sometimes triggers service/kmod changes)
if ! marker_exists docker_installed; then
  red "🔧 [STEP] Installing Docker (if missing)"
  if ! command -v docker >/dev/null; then
    apt_run "apt-get remove -y docker docker-engine docker.io containerd runc || true"
    install -m 0755 -d /etc/apt/keyrings || true
    OS_ID=$(awk -F= '/^ID=/ {gsub(/"/,"",$2); print $2; exit}' /etc/os-release || echo ubuntu)
    curl -fsSL https://download.docker.com/linux/$OS_ID/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || true
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_ID $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt_run "apt-get update -y"
    if apt_run "apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin"; then
      systemctl enable --now docker || true
      red "✅ [OK] Docker installed or enabled"
      # Installing containerd/docker may require a reboot on some kernels or cgroup changes
      if [ -f /var/run/reboot-required ]; then
        red "⚠️ [REBOOT] Docker or containerd triggered reboot-required"
        mark_reboot_needed
      fi
    else
      red "⚠️ [WARN] Docker install reported issues; continuing"
    fi
  else
    red "⏭️ [SKIP] Docker already installed"
  fi
  write_marker docker_installed
fi

# Install Bun (best-effort)
if ! marker_exists bun_installed; then
  red "🔧 [STEP] Installing Bun (best-effort)"
  if ! command -v bun >/dev/null; then
    curl -fsSL https://bun.sh/install | bash || true
    if [ -d "$HOME/.bun/bin" ]; then
      cat > "$BUN_PROFILE" <<'BUNENV'
export BUN_INSTALL="$HOME/.bun"
export PATH="$HOME/.bun/bin:$PATH"
BUNENV
      chmod 644 "$BUN_PROFILE" || true
      export BUN_INSTALL="$HOME/.bun"
      export PATH="$HOME/.bun/bin:$PATH"
      red "✅ [OK] Bun installed and PATH updated"
    else
      red "⚠️ [WARN] Bun installer finished but $HOME/.bun not found; continuing"
    fi
  else
    red "⏭️ [SKIP] bun already present"
  fi
  write_marker bun_installed
fi

# Clone node repo
if ! marker_exists node_cloned; then
  red "🔧 [STEP] Cloning node repository (branch: testnet)"
  if [ ! -d "$NODE_PATH" ]; then
    if git clone -b testnet https://github.com/kynesyslabs/node.git "$NODE_PATH"; then
      red "✅ [OK] Node repository cloned"
    else
      red "❌ [ERROR] Git clone failed — check network or repo URL"
    fi
  else
    red "⏭️ [SKIP] Node directory already exists"
  fi
  write_marker node_cloned
fi

# Install node dependencies
if ! marker_exists deps_installed; then
  if [ -d "$NODE_PATH" ]; then
    pushd "$NODE_PATH" >/dev/null
    red "🔧 [STEP] Installing node dependencies (bun preferred, fallback npm)"
    if command -v bun >/dev/null; then
      if bun install 2>&1 | tee "$TMP_DIR/bun_install.log"; then
        red "✅ [OK] bun install completed"
      else
        red "⚠️ [WARN] bun install had issues; trying recovery"
        bun pm untrusted --yes >/dev/null 2>&1 || bun pm untrusted || true
        bun install 2>&1 | tee -a "$TMP_DIR/bun_install.log" || true
      fi
    else
      red "ℹ️ [INFO] bun not found; falling back to npm install"
      npm install || true
    fi
    popd >/dev/null
  else
    red "❌ [ERROR] Node directory missing; cannot install deps"
  fi
  write_marker deps_installed
fi

# Create run-wrapper
if ! marker_exists run_wrapper_created; then
  red "🔧 [STEP] Creating run-wrapper"
  mkdir -p "$NODE_PATH"
  cat > "$NODE_PATH/run-wrapper.sh" <<'RWH'
#!/bin/bash
export BUN_INSTALL=/root/.bun
export PATH=/root/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cd /root/node
exec /bin/bash ./run
RWH
  chmod +x "$NODE_PATH/run-wrapper.sh" || true
  red "✅ [OK] run-wrapper created"
  write_marker run_wrapper_created
fi

# Create systemd service
if ! marker_exists systemd_installed; then
  red "🔧 [STEP] Creating systemd service for demos-node"
  cat > "$SYSTEMD_SERVICE" <<'SVC'
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
SVC
  systemctl daemon-reload || true
  systemctl enable --now demos-node.service || true
  red "✅ [OK] systemd unit installed and started (if possible)"
  write_marker systemd_installed
fi

# Wait up to 60s for keys
if ! marker_exists keys_generated; then
  red "🔧 [STEP] Checking for node key generation"
  if [ -f "$NODE_PATH/publickey" ] && [ -f "$NODE_PATH/privatekey" ]; then
    chmod 600 "$NODE_PATH/privatekey" || true
    write_marker keys_generated
    red "✅ [OK] Node keys already present"
  else
    red "⏳ [WAIT] Waiting up to 60s for node to generate keys..."
    for i in {1..60}; do
      [ -f "$NODE_PATH/publickey" ] && [ -f "$NODE_PATH/privatekey" ] && break
      sleep 1
    done
    if [ -f "$NODE_PATH/publickey" ] && [ -f "$NODE_PATH/privatekey" ]; then
      chmod 600 "$NODE_PATH/privatekey" || true
      write_marker keys_generated
      red "✅ [OK] Keys detected after wait"
    else
      red "❌ [ERROR] Keys not detected after 60s"
      red "    ▶ Check node logs: journalctl -u demos-node.service -n 200 --no-pager"
      red "    ▶ Run health script: check_demos_node --health --logs=100"
      red "    ▶ Manually inspect: ls -l /root/node"
      # continue; allow user to debug
    fi
  fi
fi

# Write .env and demos_peerlist.json
if ! marker_exists node_configured; then
  red "🔧 [STEP] Writing .env and demos_peerlist.json"
  PUBLIC_IP="$(curl -s --max-time 5 https://api.ipify.org || echo 127.0.0.1)"
  log "Detected public IP: $PUBLIC_IP"
  red "🔍 [INFO] Detected public IP: $PUBLIC_IP"
  echo "EXPOSED_URL=http://$PUBLIC_IP:53550" > "$NODE_PATH/.env"
  if [ -f "$NODE_PATH/publickey" ]; then
    PUBKEY="$(tr -d '\r\n' < "$NODE_PATH/publickey")"
    printf '{"%s":"http://%s:53550"}\n' "$PUBKEY" "$PUBLIC_IP" > "$NODE_PATH/demos_peerlist.json"
  else
    red "⚠️ [WARN] publickey not present; peerlist will not include pubkey"
    printf '{}\n' > "$NODE_PATH/demos_peerlist.json"
  fi
  write_marker node_configured
  red "✅ [OK] Node config written"
fi

# Free port 5332 if occupied
if command -v lsof >/dev/null && lsof -i :5332 &>/dev/null; then
  red "🔧 [STEP] Freeing port 5332"
  lsof -t -i :5332 | xargs -r kill || true
  sleep 2
  red "✅ [OK] Port 5332 freed (if it was occupied)"
fi

# Restart and quick service check
red "🔧 [STEP] Restarting demos-node service"
systemctl restart demos-node.service || true
sleep 2
if systemctl is-active --quiet demos-node.service; then
  red "✅ [OK] Node service is active"
else
  red "⚠️ [WARN] Node service not active — inspect logs"
  red "    journalctl -u demos-node.service -n 200 --no-pager"
fi

# Create helper scripts (embedded, idempotent)
red "🔧 [STEP] Creating embedded helper scripts and symlinks"
create_helpers(){
  mkdir -p "$HELPER_DIR" "$GLOBAL_BIN" || true

  cat > "$HELPER_DIR/restart_demos_node.sh" <<'HR'
#!/bin/bash
set -euo pipefail
systemctl restart demos-node.service
systemctl status demos-node.service --no-pager -l
HR
  chmod 755 "$HELPER_DIR/restart_demos_node.sh"

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
rm -f /run/demos-node.pid /var/run/demos-node.pid "$MARKER_DIR/installer.lock" || true
systemctl status demos-node.service --no-pager -l || true
echo "Stop sequence complete"
HS
  chmod 755 "$HELPER_DIR/stop_demos_node.sh"

  cat > "$HELPER_DIR/check_demos_node.sh" <<'HC'
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
HC
  chmod 755 "$HELPER_DIR/check_demos_node.sh"

  # Ensure monitor log exists
  touch "$MONITOR_LOG" || true; chown root:root "$MONITOR_LOG" || true; chmod 644 "$MONITOR_LOG" || true

  # Create symlinks (overwrite dangling links)
  ln -sf "$HELPER_DIR/restart_demos_node.sh" "$GLOBAL_BIN/restart_demos_node"
  ln -sf "$HELPER_DIR/backup_demos_keys.sh" "$GLOBAL_BIN/backup_demos_keys"
  ln -sf "$HELPER_DIR/stop_demos_node.sh" "$GLOBAL_BIN/stop_demos_node"
  ln -sf "$HELPER_DIR/check_demos_node.sh" "$GLOBAL_BIN/check_demos_node"
  chmod 755 "$GLOBAL_BIN/restart_demos_node" "$GLOBAL_BIN/backup_demos_keys" "$GLOBAL_BIN/stop_demos_node" "$GLOBAL_BIN/check_demos_node" || true

  red "✅ [OK] Helpers installed to $HELPER_DIR and symlinked to $GLOBAL_BIN"
}

create_helpers
write_marker helpers_created

# Save local copy of the installer robustly (avoid chmod warning)
red "🔧 [STEP] Saving a local copy of the installer (if possible)"
if [ -f "$0" ]; then
  # $0 is a file on disk (script executed from file)
  cp -f "$0" "$LOCAL_INSTALLER_PATH" 2>/dev/null || true
  chmod +x "$LOCAL_INSTALLER_PATH" 2>/dev/null || true
  red "✅ [OK] Installer saved locally at $LOCAL_INSTALLER_PATH"
elif [ -n "$RAW_INSTALLER_URL" ]; then
  # Attempt to fetch from RAW_INSTALLER_URL if provided (useful when piped)
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL "$RAW_INSTALLER_URL" -o "$LOCAL_INSTALLER_PATH"; then
      chmod +x "$LOCAL_INSTALLER_PATH" 2>/dev/null || true
      red "✅ [OK] Installer downloaded and saved to $LOCAL_INSTALLER_PATH"
    else
      red "⚠️ [WARN] Could not download installer from RAW_INSTALLER_URL"
    fi
  else
    red "⚠️ [WARN] curl not available to download installer copy"
  fi
else
  red "⚠️ [SKIP] No local script file detected and RAW_INSTALLER_URL not set; skipping save"
fi

write_marker install_complete
red "🎉 [DONE] Full install complete."
red "🔗 Global commands: restart_demos_node backup_demos_keys stop_demos_node check_demos_node"
red "📁 Markers: $MARKER_DIR — remove a marker to re-run a step"

# If a reboot is needed, announce and reboot after short delay
if [ "$NEED_REBOOT" -eq 1 ]; then
  red "🔁 [REBOOT] A reboot is required to complete installation. Rebooting in 15 seconds."
  red "    If you want to avoid automatic reboot next time, edit the installer to remove mark_reboot_needed() calls."
  sleep 15
  reboot
fi

exit 0
