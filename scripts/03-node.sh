#!/usr/bin/env bash
# Gleipnir: Node.js, system-wide from NodeSource and owned by root,
# so dev and claude can use it but can't change it.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"
export DEBIAN_FRONTEND=noninteractive

NODE_MAJOR="$(cfg node 24)"
[[ "$NODE_MAJOR" =~ ^[0-9]+$ ]] || fail "\"node\" must be a major version number, like 24"

current="$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || true)"
if [ "$current" != "$NODE_MAJOR" ]; then
  log "Installing Node.js $NODE_MAJOR"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y nodejs
fi

log "Node.js $(node -v), npm $(npm -v)"
