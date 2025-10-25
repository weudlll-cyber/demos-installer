#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# ============================================================
# Demos Node installer - complete single-file script
# - idempotent markers for each step
# - one-time reboot with visible 15s delay
# - dpkg/apt recovery before any apt work
# - apt-lock tolerant: stops apt timers and retries
# - installs Docker, Bun, unzip, curl
# - clones node repo, installs deps (bun/npm)
# - creates run-wrapper and systemd unit
# - waits for key generation, writes .env and demos_peerlist.json
# - frees conflicting port, restarts service
# - creates helper scripts and installs them to /usr/local/bin
# - all user-facing output printed in bright red for visibility
# ============================================================

# -------------------------
# Paths and marker files
# -------------------------
MARKER_DIR="/root/.demos_node_setup"
TMP_DIR="${MARKER_DIR}/tmp"
LOGFILE="$MARKER_DIR/install.log"
NODE_PATH="/root/node"
SYSTEMD_SERVICE="/etc/systemd/system/demos-node.service"
FIRST_REBOOT_MARKER="${MARKER_DIR}/.first_reboot_pending"
LOCKFILE="$MARKER_DIR/installer.lock"
BUN_PROFILE="/etc/profile.d/bun.sh"
GLOBAL_BIN="/usr/local/bin"

mkdir -p "$TMP_DIR"
chmod 700 "$MARKER_DIR" "$TMP_DIR" 2>/dev/null || true

# -------------------------
# Helpers
# -------------------------
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }
red_echo(){ echo -e "\033[1;31m$*\033[0m"; }
write_marker(){ echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1" > "$TMP_DIR/$1.tmp" && mv -f "$TMP_DIR/$1.tmp" "$MARKER_DIR/$1" && sync; }
marker_exists(){ [ -f "$MARKER_DIR/$1" ]; }

# Prevent parallel runs
exec 200>"$LOCKFILE"
flock -n 200 || { red_echo "❌ Another installer run is active. Exiting."; exit 1; }

# -------------------------
# dpkg/apt recovery (idempotent)
# -------------------------
A_RETRY_MAX=6
A_RETRY_WAIT=5

repair_dpkg_and_apt() {
  # stop automatic apt timers that can interfere
  sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service >/dev/null 2>&1 || true

  # wait a short while for any active apt/dpkg to finish
  for i in $(seq 1 $A_RETRY_MAX); do
    if pgrep -x dpkg >/dev/null || pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null; then
      echo "Waiting for dpkg/apt to finish (attempt $i/$A_RETRY_MAX)..."
      sleep "$A_RETRY_WAIT"
    else
      break
    fi
  done

  # forcibly terminate stale apt/dpkg processes only if still present after waiting
  if pgrep -x dpkg >/dev/null || pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null; then
    echo "Stale dpkg/apt processes detected; killing them"
    sudo pkill -9 dpkg || true
    sudo pkill -9 apt || true
    sudo pkill -9 apt-get || true
    sleep 1
  fi

  # remove lock files only when no dpkg/apt processes running
  if ! pgrep -x dpkg >/dev/null && ! pgrep -x apt >/dev/null && ! pgrep -x apt-get >/dev/null; then
    sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock || true
  fi

  # run dpkg repair and dependency fix with retries
  local n=0
  until sudo dpkg --configure -a >/dev/null 2>&1 && sudo apt-get install -f -y >/dev/null 2>&1; do
    n=$((n+1))
    echo "dpkg/apt recovery attempt $n failed"
    if [ "$n" -ge "$A_RETRY_MAX" ]; then
      echo "dpkg/apt recovery failed after $A_RETRY_MAX attempts"
      return 1
    fi
    sleep "$A_RETRY_WAIT"
  done

  # refresh apt state
  sudo apt-get update -y >/dev/null 2>&1 || true
  return 0
}

repair_dpkg_and_apt || {
  red_echo "❌ ERROR: dpkg/apt repair failed; run 'sudo dpkg --configure -a' manually and retry."
  exit 1
}

# -------------------------
# Apt wrapper with retries (used for apt-get commands)
# -------------------------
apt_wait_and_run(){
  local cmd="$*"
  for i in {1..12}; do
    sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service >/dev/null 2>&1 || true
    if sudo bash -c "$cmd"; then
      return 0
    fi
    sleep 3
  done
  red_echo "❌ apt command failed after retries: $cmd"
  return 1
}

# -------------------------
# Preflight detection
# -------------------------
red_echo "🔍 Preflight check: scanning system for existing components..."
if command -v unzip >/dev/null && command -v curl >/dev/null; then red_echo "✅ unzip and curl installed"; else red_echo "❌ unzip or curl missing"; fi
if command -v docker >/dev/null; then red_echo "✅ Docker installed: $(docker --version 2>/dev/null || echo 'unknown')"; else red_echo "❌ Docker not found"; fi
if command -v bun >/dev/null; then red_echo "✅ Bun installed: $(bun --version 2>/dev/null || echo 'unknown')"; else red_echo "❌ Bun not found"; fi
[ -d "$NODE_PATH" ] && red_echo "✅ Node repo exists at $NODE_PATH" || red_echo "❌ Node repo missing"
systemctl list-units --type=service | grep -q demos-node.service && red_echo "✅ Systemd service registered" || red_echo "❌ Systemd service missing"
[ -f "$NODE_PATH/publickey" ] && [ -f "$NODE_PATH/privatekey" ] && red_echo "✅ Node keys found" || red_echo "❌ Node keys missing"
red_echo "🧪 Preflight complete. Proceeding..."

# -------------------------
# One-time reboot logic
# -------------------------
if ! marker_exists first_run_reboot_done && ! marker_exists first_run_reboot_scheduled; then
  write_marker first_run_reboot_scheduled
  touch "$FIRST_REBOOT_MARKER"
  red_echo "🚨 One-time reboot in 15s to finalize system upgrades"
  red_echo "After reboot, re-run this script or run the same curl command you used."
  sleep 15
  reboot
  exit 0
fi

if marker_exists first_run_reboot_scheduled && ! marker_exists first_run_reboot_done; then
  write_marker first_run_reboot_done
  rm -f "$FIRST_REBOOT_MARKER" || true
  red_echo "✅ Post-reboot: continuing install"
fi

# -------------------------
# Install unzip and curl (if missing)
# -------------------------
if ! command -v unzip >/dev/null || ! command -v curl >/dev/null; then
  red_echo "📦 Installing unzip and curl (required)"
  apt_wait_and_run "apt-get update -y"
  apt_wait_and_run "apt-get install -y unzip curl"
else
  red_echo "⏭️ Skipping unzip and curl install — already present"
fi
write_marker unzip_installed

# -------------------------
# System update and base packages
# -------------------------
if ! marker_exists system_updated; then
  red_echo "📦 Updating system packages and installing base deps"
  apt_wait_and_run "apt-get update -y"
  apt_wait_and_run "apt-get upgrade -y"
  apt_wait_and_run "apt-get install -y ca-certificates gnupg lsb-release wget git build-essential jq lsof software-properties-common gpg"
  write_marker system_updated
else
  red_echo "⏭️ Skipping system update — already marked complete"
fi

# -------------------------
# Docker install (if missing)
# -------------------------
if ! command -v docker >/dev/null; then
  red_echo "📦 Installing Docker (docker-ce, containerd)"
  apt_wait_and_run "apt-get remove -y docker docker-engine docker.io containerd runc || true"
  sudo install -m 0755 -d /etc/apt/keyrings || true
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
  apt_wait_and_run "apt-get update -y"
  apt_wait_and_run "apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin"
  sudo systemctl enable --now docker || true
else
  red_echo "⏭️ Skipping Docker install — already present"
fi
write_marker docker_installed

# -------------------------
# Bun install (if missing)
# -------------------------
if ! command -v bun >/dev/null; then
  red_echo "📦 Installing Bun (JavaScript runtime/package manager)"
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
  red_echo "⏭️ Skipping Bun install — already present"
fi
write_marker bun_installed

# -------------------------
# Clone node repository (if missing) and install dependencies
# -------------------------
if [ ! -d "$NODE_PATH" ]; then
  red_echo "🌱 Cloning node repository into $NODE_PATH (branch: testnet)"
  git clone -b testnet https://github.com/kynesyslabs/node.git "$NODE_PATH" || {
    red_echo "❌ Git clone failed; please check network and repo URL"
  }
  if [ -d "$NODE_PATH" ]; then
    pushd "$NODE_PATH" >/dev/null
    bun install || npm install || true
    popd >/dev/null
  fi
else
  red_echo "⏭️ Skipping node clone — $NODE_PATH already exists"
fi
write_marker node_cloned

# -------------------------
# run-wrapper: expose Bun path for systemd
# -------------------------
mkdir -p "$NODE_PATH"
cat > "$NODE_PATH/run-wrapper.sh" <<'EOF'
#!/bin/bash
# Ensure Bun is available in PATH when systemd runs the unit
export BUN_INSTALL=/root/.bun
export PATH=/root/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cd /root/node
exec /bin/bash ./run
EOF
chmod +x "$NODE_PATH/run-wrapper.sh" || true
write_marker run_wrapper_created

# -------------------------
# systemd service: demos-node
# -------------------------
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

# -------------------------
# Wait for key generation (publickey/privatekey)
# -------------------------
if [ -f "$NODE_PATH/publickey" ] && [ -f "$NODE_PATH/privatekey" ]; then
  chmod 600 "$NODE_PATH/privatekey" || true
  write_marker keys_generated
  red_echo "✅ Node keys already present"
else
  red_echo "⏳ Waiting for node to generate keys (up to 60s)..."
  for i in {1..60}; do
    [ -f "$NODE_PATH/publickey" ] && [ -f "$NODE_PATH/privatekey" ] && break
    sleep 1
  done
  if [ -f "$NODE_PATH/publickey" ] && [ -f "$NODE_PATH/privatekey" ]; then
    chmod 600 "$NODE_PATH/privatekey" || true
    write_marker keys_generated
    red_echo "✅ Keys detected and secured"
  else
    red_echo "⚠️ Keys not found after wait; continue and check node logs later"
  fi
fi

# -------------------------
# Configure .env and demos_peerlist.json using detected public IP
# -------------------------
if ! marker_exists node_configured; then
  PUBLIC_IP="$(curl -s --max-time 5 https://api.ipify.org || echo 127.0.0.1)"
  log "Detected public IP: $PUBLIC_IP"
  red_echo "🌐 Using public IP: $PUBLIC_IP for .env and peerlist"
  echo "EXPOSED_URL=http://$PUBLIC_IP:53550" > "$NODE_PATH/.env"
  if [ -f "$NODE_PATH/publickey" ]; then
    PUBKEY="$(tr -d '\r\n' < "$NODE_PATH/publickey")"
    printf '{"%s":"http://%s:53550"}\n' "$PUBKEY" "$PUBLIC_IP" > "$NODE_PATH/demos_peerlist.json"
  fi
  write_marker node_configured
else
  red_echo "⏭️ Skipping .env and peerlist configuration — already configured"
fi

# -------------------------
# Port cleanup: free up known conflicting port 5332 if in use
# -------------------------
if command -v lsof >/dev/null && lsof -i :5332 &>/dev/null; then
  red_echo "🧹 Freeing port 5332 (in use) to avoid conflicts"
  lsof -t -i :5332 | xargs -r kill || true
  sleep 2
fi

# -------------------------
# Restart the systemd service and verify
# -------------------------
systemctl restart demos-node.service || true
sleep 2
if systemctl is-active --quiet demos-node.service; then
  red_echo "✅ Node service is active"
else
  red_echo "⚠️ Node service is not active — check logs: journalctl -u demos-node.service -n 200 --no-pager"
fi

# -------------------------
# Helper scripts for operators (local)
# -------------------------
cat > /root/restart_demos_node.sh <<'EOF'
#!/bin/bash
# Restarts demos-node service and prints status
systemctl restart demos-node.service
systemctl status demos-node.service --no-pager -l
EOF
chmod +x /root/restart_demos_node.sh || true

cat > /root/backup_demos_keys.sh <<'EOF'
#!/bin/bash
# Copies node keys to ~/demos-keys with 600 perms for privatekey
mkdir -p ~/demos-keys
cp /root/node/publickey ~/demos-keys/publickey 2>/dev/null || true
cp /root/node/privatekey ~/demos-keys/privatekey 2>/dev/null || true
chmod 600 ~/demos-keys/privatekey 2>/dev/null || true
ls -l ~/demos-keys || true
EOF
chmod +x /root/backup_demos_keys.sh || true

cat > /root/stop_demos_node.sh <<'EOF'
#!/bin/bash
set -euo pipefail
# Stop and disable systemd service
sudo systemctl stop demos-node.service || true
sudo systemctl disable --now demos-node.service || true
# Kill any processes whose command line references /root/node
pgrep -f "/root/node" | xargs -r sudo kill -9 || true
pkill -f "/root/node/run" || true
# Free common ports used by the node
sudo lsof -ti :5332 | xargs -r sudo kill -9 || true
sudo lsof -ti :53550 | xargs -r sudo kill -9 || true
# Stop Docker containers containing 'demos' in their name
sudo docker ps -q --filter "name=demos" | xargs -r sudo docker stop || true
# Remove leftover PID or lock files used by the installer or node
sudo rm -f /run/demos-node.pid /var/run/demos-node.pid /root/.demos_node_setup/installer.lock || true
# Show final service status
sudo systemctl status demos-node.service --no-pager -l || true
echo "Stop sequence complete"
EOF
chmod +x /root/stop_demos_node.sh || true

# -------------------------
# Install global helper wrappers in /usr/local/bin
# -------------------------
mkdir -p "$GLOBAL_BIN"

cat > "$GLOBAL_BIN/restart_demos_node" <<'EOF'
#!/bin/bash
exec /root/restart_demos_node.sh "$@"
EOF
chmod +x "$GLOBAL_BIN/restart_demos_node" || true

cat > "$GLOBAL_BIN/backup_demos_keys" <<'EOF'
#!/bin/bash
exec /root/backup_demos_keys.sh "$@"
EOF
chmod +x "$GLOBAL_BIN/backup_demos_keys" || true

cat > "$GLOBAL_BIN/stop_demos_node" <<'EOF'
#!/bin/bash
exec /root/stop_demos_node.sh "$@"
EOF
chmod +x "$GLOBAL_BIN/stop_demos_node" || true

write_marker helpers_created

# -------------------------
# Final marker and completion message
# -------------------------
write_marker install_complete
red_echo "🎉 Install complete. Helper commands (available globally):"
red_echo "  restart_demos_node   - restart node and view status"
red_echo "  backup_demos_keys    - copy keys to ~/demos-keys (check perms)"
red_echo "  stop_demos_node      - stop service, kill processes, free ports (one-step)"
red_echo "ℹ️ Local helper scripts also available in /root/: restart_demos_node.sh, backup_demos_keys.sh, stop_demos_node.sh"
red_echo "ℹ️ Marker files located in $MARKER_DIR. Remove specific marker files to re-run particular steps."

# End of script
