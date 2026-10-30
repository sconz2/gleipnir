#!/usr/bin/env bash
# Gleipnir: set up, or update, a sandboxed Claude Code environment on Ubuntu 24.04.
#
#   sudo ./install.sh /path/to/config.json [deploy_key] [.env] [starter CLAUDE.md] [context folder] [apps' .env folder]
#
# Pass "" for any file you don't have, to reach the ones after it.
# Safe to re-run: that's how config changes and updates are applied.
# Vagrant runs this for you; on a VPS you run it yourself.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Gleipnir: run this as root (sudo)." >&2
  exit 1
fi

CONFIG_IN="${1:?usage: install.sh config.json [deploy_key] [env_file] [claude_file] [context_dir] [env_dir]}"
KEY_IN="${2:-}"
ENV_IN="${3:-}"
CLAUDE_MD_IN="${4:-}"
CONTEXT_IN="${5:-}"
ENV_DIR_IN="${6:-}"
SRC="$(cd "$(dirname "$0")" && pwd)"

# Check the whole config before anything else, so a mistake stops provisioning now, before
# anything is changed (the machine keeps its last good config), rather than halfway
python3 -I "$SRC/scripts/files/gleipnir-config" "$CONFIG_IN" || {
  echo "Gleipnir: fix the machine's config (machines/<name>.json), then provision again." >&2
  exit 1
}

# A root-only copy of the config: it can hold passwords
install -d -m 0755 /etc/gleipnir
install -m 0600 "$CONFIG_IN" /etc/gleipnir/config.json

# Ubuntu checks for services to restart after every package install and lists them each
# time; the base step does that once, quietly, instead
export NEEDRESTART_SUSPEND=1

export GLEIPNIR_SRC="$SRC"
export GLEIPNIR_CONFIG=/etc/gleipnir/config.json
export GLEIPNIR_KEY="$KEY_IN"
export GLEIPNIR_ENV="$ENV_IN"
export GLEIPNIR_CLAUDE_MD="$CLAUDE_MD_IN"
export GLEIPNIR_CONTEXT="$CONTEXT_IN"
export GLEIPNIR_ENV_DIR="$ENV_DIR_IN"

for step in "$SRC"/scripts/[0-9][0-9]-*.sh; do
  echo "==> Gleipnir: $(basename "$step" .sh)"
  bash "$step"
done

echo "==> Gleipnir: done"