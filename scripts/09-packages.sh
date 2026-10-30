#!/usr/bin/env bash
# Gleipnir: each app's packages (npm and Composer), on first setup.
#
# Installed as claude, inside Gjöll, with the same proxy settings as Claude's sessions and
# npm's install scripts off: packages are code from the internet, so they get exactly what
# Claude's own commands would, never dev's access (the editor, your copy of the project, the
# deploy key). After this, installing packages is up to Claude.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"

CLAUDE_ENV=/etc/gleipnir/claude-env
NETWORK="$(cat /etc/gleipnir/claude-network 2>/dev/null || echo allowlist)"

[ -d "$WORK/.git" ] || fail "Claude's copy of the project isn't set up"

# Gjöll must be up, as it must be for Claude's sessions
if ! /usr/local/sbin/gjoll-firewall --check >/dev/null 2>&1; then
  warn "Gjöll isn't active, so the apps' packages weren't installed. Provision again once it is."
  exit 0
fi
env_vars=()
if [ "$NETWORK" = "allowlist" ]; then
  if ! systemctl is-active --quiet squid; then
    warn "Gjöll's proxy isn't running, so the apps' packages weren't installed. Provision again once it is."
    exit 0
  fi
  if [ -f "$CLAUDE_ENV" ]; then
    mapfile -t env_vars < <(grep -E '^[A-Za-z_]+=' "$CLAUDE_ENV")
  fi
fi

# Run a command as claude in a folder, with Claude's settings
as_claude_in() { # folder command...
  local dir="$1"; shift
  sudo -u claude -H env "${env_vars[@]}" bash -c 'cd "$1" && shift && exec "$@"' _ "$dir" "$@"
}

while IFS=$'\t' read -r name folder _; do
  label="$name"; [ "$folder" = "." ] && label="the project"
  # Only a real folder in Claude's copy: no links along the way
  dir="$(app_dir "$folder")" || continue

  if [ -f "$dir/package.json" ] && [ ! -e "$dir/node_modules" ]; then
    if [ -f "$dir/package-lock.json" ]; then install_cmd=(npm ci); else install_cmd=(npm install); fi
    log "Installing npm packages for $label (${install_cmd[*]})"
    # --ignore-scripts on the command itself: a .npmrc in the project can't turn it back on
    if ! as_claude_in "$dir" "${install_cmd[@]}" --ignore-scripts --no-audit --no-fund --loglevel=error; then
      warn "$label: ${install_cmd[*]} failed. Ask Claude to install its packages in $folder/."
    fi
  fi

  if [ -f "$dir/composer.json" ] && [ ! -e "$dir/vendor" ]; then
    if [ -x /usr/local/bin/composer ]; then
      log "Installing Composer packages for $label"
      if ! as_claude_in "$dir" /usr/local/bin/composer install --no-interaction --no-progress; then
        warn "$label: composer install failed. Ask Claude to install its packages in $folder/."
      fi
    else
      warn "$label has a composer.json, but PHP isn't enabled (set php.enabled in the machine's config)"
    fi
  fi
done < <(apps)

log "Packages checked"