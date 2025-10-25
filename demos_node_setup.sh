#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# ============================================================
# Demos Node installer - single-file complete script
# Features:
# - DNS retry for raw.githubusercontent.com
# - dpkg/apt recovery (wait, kill stale, remove locks, dpkg --configure -a, apt -f)
# - apt wrapper with retries
# - one-time reboot with visible 15s delay and markers to resume
# - installs unzip, curl, Docker, Bun
# - clones node repo, installs deps (bun/npm)
# - creates run-wrapper and systemd unit
# - waits for key generation, writes .env and demos_peerlist.json
# - frees conflicting port, restarts service
# - creates helper scripts and global wrappers in /usr/local/bin
# - logs to /root/.demos_node_setup/install.log
# ============================================================

# -------------------------
# Paths and markers
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
# DNS check for GitHub raw (retry)
# -------------------------
DNS_OK=0
for i in {1..12}; do
  if ping -c 1 -W 2 raw.githubusercontent.com >/dev/null 2>&1; then
    red_echo "✅ DNS resolution OK: raw.githubusercontent.com"
    DNS_OK=1
    break
  fi
  red_echo "⏳ Waiting for DNS resolution (attempt $i/12)..."
  sleep 3
done
if [ "$DNS_OK" -ne 1 ]; then
  red_echo "⚠️ DNS still failing for raw.githubusercontent.com; you may run the script again when network is ready."
fi

# -------------------------
# dpkg/apt recovery (idempotent)
# -------------------------
A_RETRY_MAX=6
A_RETRY_WAIT=5

repair_dpkg_and_apt() {
  # stop automatic apt timers
  sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service >/dev/null 2>&1 || true

  # wait briefly for running apt/dpkg to finish
  for i in $(seq 1 $A_RETRY_MAX); do
    if pgrep -x dpkg >/dev/null || pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null; then
      echo "Waiting for dpkg/apt to finish (attempt $i/$A_RETRY_MAX)..."
      sleep "$A_RETRY_WAIT"
    else
      break
    fi
  done

  # if still running, kill stale processes
  if pgrep -x dpkg >/dev/null || pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null; then
    echo "Stale dpkg/apt processes detected; killing them"
    sudo pkill -9 dpkg || true
    sudo pkill -9 apt || true
    sudo pkill -9 apt-get || true
    sleep 1
  fi

  # remove lock files when safe
  if ! pgrep -x dpkg >/dev/null && ! pgrep -x apt >/dev/null && ! pgrep -x apt-get >/dev/null; then
    sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock || true
  fi

  # run dpkg/apt repair with retries
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

  sudo apt-get update -y >/dev/null 2>&1 || true
  return 0
}

repair_dpkg_and_apt || {
  red_echo "❌ ERROR: dpkg/apt repair failed; run 'sudo dpkg --configure -a' manually and retry."
  exit 1
}

# -------------------------
# apt wrapper with retries
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
red_echo "🔍 Preflight check..."
if command -v unzip >/dev/null && command -v curl >/dev/null; then red_echo "✅ unzip and curl present"; else red_echo "❌ unzip or curl missing"; fi
if command -v docker >/dev/null; then red_echo "✅ Docker detected"; else red_echo "❌ Docker not found"; fi
if command -v bun >/dev/null; then red_echo "✅ Bun detected"; else red_echo "❌ Bun not found"; fi
[ -d "$NODE_PATH" ] && red_echo "✅ Node repo exists at $NODE_PATH" || red_echo "❌ Node repo missing"
systemctl list-units --type=service | grep -q demos-node.service && red_echo "✅ Systemd service present" || red_echo "❌ Systemd service missing"
[ -f "$NODE_PATH/publickey" ] && [ -f "$NODE_PATH/privatekey" ] && red_echo "✅ Node keys found" || red_echo "❌ Node keys missing"
red_echo "🧪 Preflight done"

# -------------------------
# One-time reboot logic (15s warning)
# -------------------------
if ! marker_exists first_run_reboot_done && ! marker_exists first_run_reboot_scheduled; then
  write_marker first_run_reboot_scheduled
  touch "$FIRST_REBOOT_MARKER"
  red_echo "🚨 One-time reboot in 15s to finalize system upgrades"
  red_echo "After reboot, re-run this script or use the same curl command"
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
# Install unzip and curl
# -------------------------
if ! command -v unzip >/dev/null || ! command -v curl >/dev/null; then
  red_echo "📦 Installing unzip and curl"
  apt_wait_and_run "apt-get update -y"
  apt_wait_and_run "apt-get install -y unzip curl"
else
  red_echo "⏭️ Skipping unzip/curl install"
fi
write_marker unzip_installed

# -------------------------
# System update and base deps
# -------------------------
if ! marker_exists system_updated; then
  red_echo "📦 Updating system and installing base packages"
  apt_wait_and_run "apt-get update -y"
  apt_wait_and_run "apt-get upgrade -y"
  apt_wait_and_run "apt-get install -y ca-certificates gnupg lsb-release wget git build-essential jq lsof software-properties-common gpg"
  write_marker system_updated
else
  red_echo "⏭️ System update already done"
fi

# -------------------------
# Docker install
# -------------------------
if ! command -v docker >/dev/null; then
  red_echo "📦 Installing Docker"
  apt_wait_and_run "apt-get remove -y docker docker-engine docker.io containerd runc || true"
  sudo install -m 0755 -d /etc/apt/keyrings || true
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
  apt_wait_and_run "apt-get update -y"
  apt_wait_and_run "apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin"
  sudo systemctl enable --now docker || true
else
  red_echo "⏭️ Docker already installed"
fi
write_marker docker_installed

# -------------------------
# Bun install
# -------------------------
if ! command -v bun >/dev/null; then
  red_echo "📦 Installing Bun"
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
  red_echo "⏭️ Bun already present"
fi
write_marker bun_installed

# -------------------------
# Clone node repository and install deps
# -------------------------
if [ ! -d "$NODE_PATH" ]; then
  red_echo "🌱 Cloning node repository (branch: testnet)"
  git clone -b testnet https://github.com/kynesyslabs/node.git "$NODE_PATH" || {
    red_echo "❌ Git clone failed; check network or repo URL"
  }
  if [ -d "$NODE_PATH" ]; then
    pushd "$NODE_PATH" >/dev/null
    bun install || npm install || true
    popd >/dev/null
  fi
else
  red_echo "⏭️ Node repo already cloned"
fi
write_marker node_cloned

# -------------------------
# run-wrapper for systemd
# -------------------------
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

# -------------------------
# systemd service
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
# Wait for key generation
# -------------------------
if [ -f "$NODE_PATH/publickey" ] && [ -f "$NODE_PATH/privatekey" ]; then
  chmod 600 "$NODE_PATH/privatekey" || true
  write_marker keys_generated
  red_echo "✅ Node keys present"
else
  red_echo "⏳ Waiting up to 60s for node to generate keys"
  for i in {1..60}; do
    [ -f "$NODE_PATH/publickey" ] && [ -f "$NODE_PATH/privatekey" ] && break
    sleep 1
  done
  if [ -f "$NODE_PATH/publickey" ] && [ -f "$NODE_PATH/privatekey" ]; then
    chmod 600 "$NODE_PATH/privatekey" || true
    write_marker keys_generated
    red_echo "✅ Keys detected"
  else
    red_echo "⚠️ Keys not detected after wait; check node logs later"
  fi
fi

# -------------------------
# .env and demos_peerlist.json
# -------------------------
if ! marker_exists node_configured; then
  PUBLIC_IP="$(curl -s --max-time 5 https://api.ipify.org || echo 127.0.0.1)"
  log "Detected public IP: $PUBLIC_IP"
  red_echo "🌐 Writing .env and demos_peerlist.json using $PUBLIC_IP"
  echo "EXPOSED_URL=http://$PUBLIC_IP:53550" > "$NODE_PATH/.env"
  if [ -f "$NODE_PATH/publickey" ]; then
    PUBKEY="$(tr -d '\r\n' < "$NODE_PATH/publickey")"
    printf '{"%s":"http://%s:53550"}\n' "$PUBKEY" "$PUBLIC_IP" > "$NODE_PATH/demos_peerlist.json"
  fi
  write_marker node_configured
else
  red_echo "⏭️ Node already configured"
fi

# -------------------------
# Free port 5332 if occupied
# -------------------------
if command -v lsof >/dev/null && lsof -i :5332 &>/dev/null; then
  red_echo "🧹 Freeing port 5332"
  lsof -t -i :5332 | xargs -r kill || true
  sleep 2
fi

# -------------------------
# Restart service and verify
# -------------------------
systemctl restart demos-node.service || true
sleep 2
if systemctl is-active --quiet demos-node.service; then
  red_echo "✅ Node service is active"
else
  red_echo "⚠️ Node service not active — inspect: journalctl -u demos-node.service -n 200 --no-pager"
fi

# -------------------------
# Helper scripts (local)
# -------------------------
cat > /root/restart_demos_node.sh <<'EOF'
#!/bin/bash
systemctl restart demos-node.service
systemctl status demos-node.service --no-pager -l
EOF
chmod +x /root/restart_demos_node.sh || true

cat > /root/backup_demos_keys.sh <<'EOF'
#!/bin/bash
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
sudo systemctl stop demos-node.service || true
sudo systemctl disable --now demos-node.service || true
pgrep -f "/root/node" | xargs -r sudo kill -9 || true
pkill -f "/root/node/run" || true
sudo lsof -ti :5332 | xargs -r sudo kill -9 || true
sudo lsof -ti :53550 | xargs -r sudo kill -9 || true
sudo docker ps -q --filter "name=demos" | xargs -r sudo docker stop || true
sudo rm -f /run/demos-node.pid /var/run/demos-node.pid /root/.demos_node_setup/installer.lock || true
sudo systemctl status demos-node.service --no-pager -l || true
echo "Stop sequence complete"
EOF
chmod +x /root/stop_demos_node.sh || true

# -------------------------
# Global wrappers in /usr/local/bin
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
# Finalize
# -------------------------
write_marker install_complete
red_echo "🎉 Install complete. Global helper commands:"
red_echo "  restart_demos_node   - restart node and show status"
red_echo "  backup_demos_keys    - copy keys to ~/demos-keys"
red_echo "  stop_demos_node      - stop service, kill processes, free ports"
red_echo "ℹ️ Local helper scripts in /root/: restart_demos_node.sh, backup_demos_keys.sh, stop_demos_node.sh"
red_echo "ℹ️ Marker files are in $MARKER_DIR. Remove a marker to re-run a step."

# End of script
