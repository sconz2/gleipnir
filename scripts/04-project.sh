#!/usr/bin/env bash
# Gleipnir: the project. Cloned onto the VM's own disk as dev, and shared
# with claude through the project group.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"

REPO="$(cfg repo)"
DEST=/srv/project
DEV_HOME=/home/dev

# --- Git access for dev: the repo's deploy key -------------------------------
install -d -o dev -g dev -m 0700 "$DEV_HOME/.ssh"
if [ -n "${GLEIPNIR_KEY:-}" ]; then
  install -o dev -g dev -m 0600 "$GLEIPNIR_KEY" "$DEV_HOME/.ssh/deploy_key"
fi

# The git server's name, from git@host:…, ssh://…@host/… or https://host/…
host="$(printf '%s' "$REPO" | sed -E 's#^[a-z+]+://##; s#^[^@/]*@##; s#[:/].*$##')"

if [ -f "$DEV_HOME/.ssh/deploy_key" ] && [ -n "$host" ]; then
  cat > "$DEV_HOME/.ssh/config" <<EOF
Host $host
  IdentityFile ~/.ssh/deploy_key
  IdentitiesOnly yes
EOF
  chown dev:dev "$DEV_HOME/.ssh/config"
  chmod 0600 "$DEV_HOME/.ssh/config"
fi

# The server's SSH identity, so the first connection can't be impersonated
known="$DEV_HOME/.ssh/known_hosts"
if [ "$host" = "github.com" ]; then
  # GitHub publishes its host keys; fetch them over HTTPS
  curl -fsSL https://api.github.com/meta | python3 -I -c '
import json, sys
for key in json.load(sys.stdin)["ssh_keys"]:
    print("github.com " + key)' > "$known.new"
  mv "$known.new" "$known"
elif [ -n "$host" ]; then
  warn "Trusting $host's SSH key on first use"
  ssh-keyscan "$host" > "$known" 2>/dev/null || true
fi
if [ -f "$known" ]; then
  chown dev:dev "$known"
  chmod 0644 "$known"
fi

# --- Git identity for dev ----------------------------------------------------
git_name="$(cfg git.name '')"
git_email="$(cfg git.email '')"
if [ -n "$git_name" ]; then sudo -u dev -H git config --global user.name "$git_name"; fi
if [ -n "$git_email" ]; then sudo -u dev -H git config --global user.email "$git_email"; fi

# --- The project folder -------------------------------------------------------
install -d -o dev -g project -m 2775 "$DEST"
# Only dev (the owner) and claude may run git in the project. Git refuses
# everyone else, including the admin user, so a hook or setting planted in
# .git can never run with admin rights.
git config --system --unset-all safe.directory 2>/dev/null || true
if ! sudo -u claude -H git config --global --get-all safe.directory 2>/dev/null | grep -qx "$DEST"; then
  sudo -u claude -H git config --global --add safe.directory "$DEST"
fi

if [ ! -d "$DEST/.git" ]; then
  if [ -n "$(ls -A "$DEST")" ]; then
    fail "$DEST isn't empty and isn't a git repo; refusing to clone over it"
  fi
  log "Cloning $REPO"
  sudo -u dev -H git clone "$REPO" "$DEST"
  sudo -u dev -H git -C "$DEST" config core.sharedRepository group

  # Let the project group (dev and claude) edit everything, now and for new files
  setfacl -R -m g:project:rwX "$DEST"
  find "$DEST" -type d -exec setfacl -m d:g:project:rwX {} +
fi

# --- npm packages, on first setup ---------------------------------------------
if [ -f "$DEST/package.json" ] && [ ! -d "$DEST/node_modules" ]; then
  if [ -f "$DEST/package-lock.json" ]; then install_cmd="npm ci"; else install_cmd="npm install"; fi
  log "Installing npm packages ($install_cmd)"
  sudo -u dev -H bash -c "cd '$DEST' && $install_cmd"
fi

log "Project ready in $DEST"
