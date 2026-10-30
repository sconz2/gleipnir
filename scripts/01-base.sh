#!/usr/bin/env bash
# Gleipnir: base packages and system settings.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get upgrade -y
apt-get install -y curl ca-certificates gnupg git tmux python3 acl iptables ipset polkitd
# Restart anything the upgrade left running on old libraries (install.sh turns off
# the check after each install, which repeats the same list every time)
if command -v needrestart >/dev/null; then needrestart -r a -q >/dev/null 2>&1 || true; fi

# Stop users planting files in /tmp that root or vagrant later open
# (Vagrant uploads provisioning scripts to /tmp before running them as root)
echo 'fs.protected_regular = 2' > /etc/sysctl.d/60-gleipnir.conf
sysctl -q -p /etc/sysctl.d/60-gleipnir.conf