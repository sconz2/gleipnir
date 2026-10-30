#!/usr/bin/env bash
# Gleipnir: Node.js, system-wide from NodeSource's apt repository and owned by root, so
# dev, claude and runner can use it but can't change it. The repository's signing key is
# checked by its fingerprint (scripts/versions.sh), and apt trusts only that key; nothing
# downloaded is run as a script.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"
export DEBIAN_FRONTEND=noninteractive

NODE_MAJOR="$(cfg node 24)"
[[ "$NODE_MAJOR" =~ ^[0-9]+$ ]] || fail "\"node\" must be a major version number, like 24"
KEYRING=/etc/apt/keyrings/nodesource.gpg

# --- NodeSource's repository, for this major version --------------------------------------
trusted_key https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key "$NODESOURCE_KEY_FINGERPRINT" "$KEYRING"
echo "deb [signed-by=$KEYRING] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
  > /etc/apt/sources.list.d/nodesource.list
# Node.js from NodeSource, never Ubuntu's older one
cat > /etc/apt/preferences.d/nodesource <<'PREF'
Package: nodejs
Pin: origin deb.nodesource.com
Pin-Priority: 600
PREF

current="$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || true)"
apt-get update -y >/dev/null
if [ "$current" != "$NODE_MAJOR" ]; then
  log "Installing Node.js $NODE_MAJOR"
  apt-get install -y nodejs >/dev/null
fi

log "Node.js $(node -v), npm $(npm -v)"