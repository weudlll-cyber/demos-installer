
 # 🛡️ Demos Node Installer

This repository provides a robust, idempotent installer script for setting up a Demos Network node on Ubuntu 24.04+. It handles:

- ✅ DNS wait and retry for GitHub access  
- ✅ apt/dpkg lock detection and recovery  
- ✅ Bun and Docker installation  
- ✅ Node repo cloning and dependency install  
- ✅ Systemd service creation  
- ✅ Public IP detection and peerlist setup  
- ✅ Key backup, restart, stop, and health-check helpers  
- ✅ One-time reboot with resume logic  
- ✅ Smart skipping of already-installed components  
- ✅ Bright red output for all user-facing messages  

---

🚀 Quick Start

To install a Demos node in one step:

```bash
curl -fsSL https://raw.githubusercontent.com/weudlll-cyber/demos-installer/main/demosnodesetup.sh | bash
```

> 💡 The script will automatically reboot once to finalize system upgrades.  
> After reboot, re-run the same command or execute the script locally if you saved it.

---

🧠 Features

- Idempotent: Safe to re-run anytime. Skips steps already completed or detected.
- Smart detection: Skips installs if Docker, Bun, or the node repo already exist.
- Reboot-aware: Automatically reboots once if needed, then resumes setup.
- Red output: All user-facing messages are printed in red for visibility.
- Public IP detection: Automatically configures .env and demos_peerlist.json.
- Marker-based logic: Each step writes a marker to /root/.demosnodesetup for safe re-entry.
- Health check script: Monitors service status, logs, PID, and optional HTTP endpoint.

---

🧰 Helper Scripts

These are installed locally and globally:

| Script                      | Description                                      |
|-----------------------------|--------------------------------------------------|
| /root/demos_node_setup.sh   | Full installer script                            |
| /root/restart_demos_node.sh | Restart the node and show systemd status         |
| /root/backup_demos_keys.sh  | Copy keys to ~/demos-keys with secure perms      |
| /root/stop_demos_node.sh    | Stop service, kill processes, free ports         |
| /root/check_demos_node.sh   | Health-check tool with restart and log options   |

Global wrappers (available anywhere):

restart_demos_node     # Restart and show status
backup_demos_keys      # Backup keys to ~/demos-keys
stop_demos_node        # Stop service and clean up
check_demos_node       # Health check with options


---

🔐 After Install

- To restart and monitor logs:
  ```bash
  /root/restart_demos_node
  ```

- To back up your keys:
  ```bash
  /root/backup_demos_keys
  ```

- To check node health:
  ```bash
  /root/check_demos_node --health --logs=100
  ```

- Node source: github.com/kynesyslabs/node

---

🛠️ Troubleshooting

If the installer exits early or skips steps:
- Check /root/.demos_node_setup/ for marker files
- Delete specific markers to re-run steps:
  `bash
  rm /root/.demos_node_setup/docker_installed
  `

If apt locks persist:
- Wait for background processes to finish
- Re-run the script manually

If Bun blocks postinstalls:
```bash
cd /root/node
bun pm untrusted
bun install
```

To inspect logs:
```bash
journalctl -u demos-node.service -n 100 --no-pager
```

---

🧪 Development Notes

This script is designed for reproducibility and operational clarity:
- All critical steps are marked and logged
- Reboot logic is tracked via marker files
- All user-facing output is bright red for visibility
- Safe to run manually or via curl
- Health check script logs to /var/log/demosnodemonitor.log

---

🧑‍💻 Maintainer

Built and maintained by Weudl  
Focused on privacy infrastructure, reproducible workflows, and community education.
