#!/usr/bin/env bash
# Gleipnir: set up, or update, a sandboxed Claude Code environment on Ubuntu 24.04.
#
#   sudo ./install.sh /path/to/config.json [/path/to/deploy_key]
#
# Safe to re-run: that's how config changes and updates are applied.
# Vagrant runs this for you; on a VPS you run it yourself.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Gleipnir: run this as root (sudo)." >&2
  exit 1
fi

CONFIG_IN="${1:?usage: install.sh config.json [deploy_key]}"
KEY_IN="${2:-}"
SRC="$(cd "$(dirname "$0")" && pwd)"

# A root-only copy of the config: it can hold passwords
install -d -m 0755 /etc/gleipnir
install -m 0600 "$CONFIG_IN" /etc/gleipnir/config.json

export GLEIPNIR_SRC="$SRC"
export GLEIPNIR_CONFIG=/etc/gleipnir/config.json
export GLEIPNIR_KEY="$KEY_IN"

for step in "$SRC"/scripts/[0-9][0-9]-*.sh; do
  echo "==> Gleipnir: $(basename "$step" .sh)"
  bash "$step"
done

echo "==> Gleipnir: done"
