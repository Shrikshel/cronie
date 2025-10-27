# cronie

[![Build Status](https://img.shields.io/badge/build-none-lightgrey)](https://example.com)
[![License](https://img.shields.io/badge/license-UNKNOWN-yellow)](./LICENSE)
[![Issues](https://img.shields.io/badge/issues-open-blue)](https://example.com/issues)

Cronie is a small, focused repository containing helper scripts and configuration for installing and managing the cronie-style cron service on Unix-like systems.

# 🕒 Cronie — Friendly systemd timer manager

![GitHub release (latest SemVer)](https://img.shields.io/github/v/release/Shrikshel/cronie?sort=semver)
![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/Shrikshel/cronie/build.yml?label=build)
![License](https://img.shields.io/github/license/Shrikshel/cronie)

**Cronie** is a simple yet powerful command-line utility for creating, managing, and monitoring **systemd timers** — an interactive alternative to traditional cron jobs.

It helps you define repeating jobs such as:
- "Run my backup every 6 hours"
- "Execute a script daily at 4 AM"
- "Clean logs weekly"
- "Send a reminder every Monday"

---

## ✨ Features

✅ Interactive menu for creating and managing timers  
✅ Works with both user-level and system-wide timers  
✅ Automatically sets up logs and persistent schedules  
✅ Human-friendly `OnCalendar` expressions  
✅ View, prune, and manage logs easily  
✅ Fully compatible with `systemctl`  
✅ Packaged as a `.deb` for easy install/uninstall  
✅ Safe — all timers isolated under `~/cronie/`

---

## 🚀 Quick Install

Install the latest version in **one line**:

```bash
curl -sL https://raw.githubusercontent.com/Shrikshel/cronie/main/scripts/install.sh | bash
```

🧹 Uninstall

To completely remove Cronie:

``` bash
curl -sL https://raw.githubusercontent.com/Shrikshel/cronie/main/scripts/uninstall.sh | bash
```

---

## ⚙️ Usage

Once installed, simply run:

```bash
cronie
```

You’ll see an interactive menu:

--- Cronie Main Menu ---
1. Create new timer
2. Manage existing timers
3. View logs
4. Backup/restore
5. Exit

