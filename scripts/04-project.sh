#!/usr/bin/env bash
# Gleipnir: the project. Cloned onto the VM's own disk as dev, and shared
# with claude through the project group.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"

REPO="$(cfg repo)"
DEST=/srv/project

# --- Git access for dev: the repo's deploy key -------------------------------
# Everything is prepared here, then put in place as dev. Code Claude runs can end up running
# as dev (the dev servers run code Claude can edit), so nothing in dev's home is written as
# root: a link left there could otherwise point root's writes anywhere.
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

if [ -n "${GLEIPNIR_KEY:-}" ]; then
  cp "$GLEIPNIR_KEY" "$stage/deploy_key"
fi

# The git server's name, from git@host:…, ssh://…@host/… or https://host/…
host="$(printf '%s' "$REPO" | sed -E 's#^[a-z+]+://##; s#^[^@/]*@##; s#[:/].*$##')"

if [ -n "${GLEIPNIR_KEY:-}" ] && [ -n "$host" ]; then
  printf 'Host %s\n  IdentityFile ~/.ssh/deploy_key\n  IdentitiesOnly yes\n' "$host" > "$stage/config"
fi

# The server's SSH identity, so the first connection can't be impersonated
if [ "$host" = "github.com" ]; then
  # GitHub publishes its host keys; fetch them over HTTPS
  curl -fsSL https://api.github.com/meta | python3 -I -c '
import json, sys
for key in json.load(sys.stdin)["ssh_keys"]:
    print("github.com " + key)' > "$stage/known_hosts"
elif [ -n "$host" ]; then
  warn "Trusting $host's SSH key on first use"
  ssh-keyscan "$host" > "$stage/known_hosts" 2>/dev/null || true
  [ -s "$stage/known_hosts" ] || rm -f "$stage/known_hosts"
fi

chown -R dev:dev "$stage"
sudo -u dev -H bash -s "$stage" <<'SH'
set -euo pipefail
stage="$1"
mkdir -p ~/.ssh
chmod 0700 ~/.ssh
# install replaces whatever is in the way, rather than writing through it
if [ -f "$stage/deploy_key" ]; then install -m 0600 "$stage/deploy_key" ~/.ssh/deploy_key; fi
if [ -f "$stage/config" ]; then install -m 0600 "$stage/config" ~/.ssh/config; fi
if [ -f "$stage/known_hosts" ]; then install -m 0644 "$stage/known_hosts" ~/.ssh/known_hosts; fi
SH

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

  # Let the project group (dev and claude) edit everything, now and for new files.
  # As dev, the owner, never as root: claude can already change the project.
  sudo -u dev -H setfacl -R -m g:project:rwX "$DEST"
  sudo -u dev -H find "$DEST" -type d -exec setfacl -m d:g:project:rwX {} +

  # Your starter CLAUDE.md, only on this first setup, and only if the project
  # doesn't already have one. After that it's the project's file, not Gleipnir's.
  if [ -n "${GLEIPNIR_CLAUDE_MD:-}" ]; then
    if [ -e "$DEST/CLAUDE.md" ] || [ -e "$DEST/.claude/CLAUDE.md" ]; then
      log "The project already has a CLAUDE.md; leaving it as it is"
    else
      install -o dev -g dev -m 0644 "$GLEIPNIR_CLAUDE_MD" "$stage/CLAUDE.md"
      sudo -u dev -H install -m 0664 "$stage/CLAUDE.md" "$DEST/CLAUDE.md"
      log "Added your starter CLAUDE.md to the project"
    fi
  fi
fi

# --- The project's .env files, copied from your computer ------------------------------
# Your computer's copies win: they replace the ones in the machine on every provision.
# env/<machine>.env goes to the project's root; env/<machine>/<app>.env into each app's folder.
install -d -m 0755 /usr/local/lib/gleipnir
install -m 0755 "$GLEIPNIR_SRC/scripts/files/gleipnir-apps" /usr/local/lib/gleipnir/gleipnir-apps
install -m 0755 "$GLEIPNIR_SRC/scripts/files/gleipnir-env" /usr/local/sbin/gleipnir-env
if [ -n "${GLEIPNIR_ENV:-}" ] || [ -n "${GLEIPNIR_ENV_DIR:-}" ]; then
  /usr/local/sbin/gleipnir-env "${GLEIPNIR_ENV:-}" "${GLEIPNIR_ENV_DIR:-}"
fi

# --- Keep tmp/ out of git, on every provision -----------------------------------------
# tmp/ holds the context files, which mustn't be committed. Done as dev, since the
# project is writable by claude.
added="$(sudo -u dev -H bash -s <<'SH'
set -euo pipefail
cd /srv/project
if ! git check-ignore -q tmp/context; then
  # Start on a new line if the file doesn't end with one
  if [ -s .gitignore ] && [ -n "$(tail -c 1 .gitignore)" ]; then echo >> .gitignore; fi
  echo "tmp/" >> .gitignore
  echo yes
fi
SH
)"
if [ "$added" = "yes" ]; then
  log "Added tmp/ to the project's .gitignore (commit it when you're ready)"
fi

# --- The project's context folder, copied from your computer ---------------------
# Into tmp/context, replacing what's there. Readable by dev and claude; only dev can change it.
install -m 0755 "$GLEIPNIR_SRC/scripts/files/gleipnir-context" /usr/local/sbin/gleipnir-context
if [ -n "${GLEIPNIR_CONTEXT:-}" ]; then
  /usr/local/sbin/gleipnir-context "$GLEIPNIR_CONTEXT"
fi

# --- Each app's packages, on first setup --------------------------------------------
# Installed as dev, like you'd do in the editor's terminal. After this, installing packages
# is up to you or Claude.
while IFS=$'\t' read -r name folder _; do
  dir="$DEST/$folder"
  [ -d "$dir" ] && [ ! -L "$dir" ] || continue
  label="$name"; [ "$folder" = "." ] && label="the project"
  if [ -f "$dir/package.json" ] && [ ! -d "$dir/node_modules" ]; then
    if [ -f "$dir/package-lock.json" ]; then install_cmd="npm ci"; else install_cmd="npm install"; fi
    log "Installing npm packages for $label ($install_cmd)"
    sudo -u dev -H bash -c 'cd "$1" && '"$install_cmd" _ "$dir"
  fi
  if [ -f "$dir/composer.json" ] && [ ! -d "$dir/vendor" ]; then
    if command -v composer >/dev/null; then
      log "Installing Composer packages for $label"
      sudo -u dev -H bash -c 'cd "$1" && composer install --no-interaction --no-progress' _ "$dir"
    else
      warn "$label has a composer.json, but PHP isn't enabled (set php.enabled in the machine's config)"
    fi
  fi
done < <(apps)

log "Project ready in $DEST"