# Demos Node Installer

This repository provides a robust, idempotent installer script for setting up a Demos Network node on Ubuntu 24.04+. It handles:

- ✅ apt/dpkg lock detection and retries  
- ✅ Bun and Docker installation  
- ✅ Node repo cloning and dependency install  
- ✅ Systemd service creation  
- ✅ Public IP detection and peerlist setup  
- ✅ Key backup and restart helpers  
- ✅ One-time reboot with resume logic  
- ✅ Smart skipping of already-installed components  
- ✅ Bright red output for all user-facing messages  

---

🚀 Quick Start

To install a Demos node in one step:

`bash
curl -fsSL https://raw.githubusercontent.com/weudlll-cyber/demos-installer/main/demos_node_setup.sh | bash
`

> 💡 The script will automatically reboot once to finalize system upgrades.  
> After reboot, re-run the same command or execute the script locally if you saved it.

---

🧠 Features

- Idempotent: Safe to re-run anytime. Skips steps already completed or detected.
- Smart detection: Skips installs if Docker, Bun, or the node repo already exist.
- Reboot-aware: Automatically reboots once if needed, then resumes setup.
- Red output: All user-facing messages are printed in red for visibility.
- Public IP detection: Automatically configures .env and demos_peerlist.json.
- Helper scripts:
  - /root/restart_demos_node.sh: Restart and view logs
  - /root/backup_demos_keys.sh: Backup your node keys

---

🔐 After Install

- To restart and monitor logs:
  `bash
  /root/restart_demos_node.sh
  `

- To back up your keys:
  `bash
  /root/backup_demos_keys.sh
  `

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

---

🧪 Development Notes

This script is designed for reproducibility and operational clarity:
- All critical steps are marked and logged
- Reboot logic is tracked via marker files
- All user-facing output is bright red for visibility
- Safe to run manually or via curl

---

🧑‍💻 Maintainer

Built and maintained by Weudl  
Focused on privacy infrastructure, reproducible workflows, and community education.

