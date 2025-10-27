#!/usr/bin/env bash
set -euo pipefail

REPO="Shrikshel/cronie"
INSTALL_PATH="/usr/local/bin/cronie"

echo "📦 Installing Cronie..."

# Check for dependencies
for cmd in curl tar; do
  command -v "$cmd" >/dev/null || { echo "❌ Missing $cmd"; exit 1; }
done

# Determine latest version
LATEST=$(curl -s https://api.github.com/repos/$REPO/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
if [[ -z "$LATEST" ]]; then
  echo "❌ Unable to fetch latest release."
  exit 1
fi

echo "👉 Latest version: $LATEST"
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"

# Download .deb file
DEB_URL="https://github.com/$REPO/releases/download/$LATEST/cronie_${LATEST#v}.deb"
echo "⬇️ Downloading package..."
curl -sL -o cronie.deb "$DEB_URL" || { echo "❌ Failed to download release."; exit 1; }

# Install
if command -v dpkg &>/dev/null; then
  sudo dpkg -i cronie.deb || sudo apt-get install -f -y
else
  echo "No dpkg found, installing manually..."
  sudo install -m 755 cronie.sh "$INSTALL_PATH"
fi

echo "✅ Cronie installed successfully!"
echo "Run with: ct"
rm -rf "$TMP_DIR"
