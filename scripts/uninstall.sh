#!/usr/bin/env bash
set -e

echo "🧹 Uninstalling Cronie..."
if command -v dpkg &>/dev/null && dpkg -l | grep -q "^ii  cronie "; then
  sudo apt remove -y cronie
else
  sudo rm -f /usr/local/bin/cronie
fi

echo "✅ Cronie removed successfully."
