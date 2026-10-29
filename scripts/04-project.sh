#!/usr/bin/env bash
# Gleipnir: the project, in two copies on the VM's own disk.
#
#   /srv/project  yours (dev's): what the editor opens, where you review, commit and push.
#                 Claude can't read or change it.
#   /srv/work     Claude's: where it works on wip/ branches, and where the dev servers run.
#                 dev can read it but never runs git in it.
#
# Work moves between them only as data (git bundles): `gleipnir-sync` copies your branches
# into Claude's copy, and `gleipnir-review` brings Claude's branch into yours. So nothing
# Claude writes (hooks, git settings, scripts) ever runs as dev.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"

REPO="$(cfg repo)"
FILES="$GLEIPNIR_SRC/scripts/files"

# Files handed from root to another user go through a folder of their own in here
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
chmod 0711 "$staging"
hand_over_to() { # user: prints a new folder only that user (and root) can use
  local folder
  folder="$(mktemp -d -p "$staging")"
  chown "$1:$1" "$folder"
  printf '%s\n' "$folder"
}

# --- Git access for dev: the repo's deploy key -------------------------------
# Everything is prepared here, then put in place as dev: nothing in dev's home is written as
# root, so a link left there can't point root's writes somewhere else.
stage="$(hand_over_to dev)"

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
rm -rf "$stage"

# --- Git identity -------------------------------------------------------------------
git_name="$(cfg git.name '')"
git_email="$(cfg git.email '')"
for user in dev claude; do
  if [ -n "$git_name" ]; then sudo -u "$user" -H git config --global user.name "$git_name"; fi
  if [ -n "$git_email" ]; then sudo -u "$user" -H git config --global user.email "$git_email"; fi
done

# Git refuses to work in a repo that belongs to someone else. That's what keeps dev (and
# the admin user) from ever running git in Claude's copy, so no system-wide exceptions.
git config --system --unset-all safe.directory 2>/dev/null || true
# Earlier versions let claude into your copy
sudo -u claude -H git config --global --unset-all safe.directory 2>/dev/null || true

# --- The helpers ------------------------------------------------------------------------
install -d -m 0755 /usr/local/lib/gleipnir
install -m 0755 "$FILES/gleipnir-apps" /usr/local/lib/gleipnir/gleipnir-apps
for helper in gleipnir-env gleipnir-context gleipnir-sync gleipnir-review; do
  install -m 0755 "$FILES/$helper" "/usr/local/sbin/$helper"
done

# Claude's copy: claude owns it; runner (the dev servers) shares it through the project
# group; dev can read it (for Heimdall's checks) but nothing more. Its .git is Claude's
# alone (dev can read it): the dev servers could otherwise change git's settings or hooks,
# which run as claude. Done as claude, which owns it all, never as root.
set_work_permissions() { # [-R]
  sudo -u claude -H bash -s -- "$@" <<'SH'
set -euo pipefail
cd /srv/work
chmod 2770 .
if [ "${1:-}" = "-R" ]; then
  setfacl -R -b .
  setfacl -R -m g:project:rwX,u:dev:rX .
  find . -type d -exec setfacl -m d:g:project:rwX,d:u:dev:rX {} +
else
  setfacl -m g:project:rwX,u:dev:rX,d:g:project:rwX,d:u:dev:rX .
fi
if [ -d .git ] && [ ! -L .git ]; then
  # Anything in it claude doesn't own (left by the dev servers) is reported, not skipped quietly
  if [ -n "$(find .git ! -user claude -print -quit)" ]; then
    echo "    WARNING: some of /srv/work/.git isn't claude's; check it: sudo find /srv/work/.git ! -user claude" >&2
  fi
  chgrp -R claude .git 2>/dev/null || true
  chmod -R g-ws,o-rwx .git 2>/dev/null || true
  setfacl -R -b .git 2>/dev/null || true
  setfacl -R -m u:dev:rX .git 2>/dev/null || true
  find .git -type d -exec setfacl -m d:u:dev:rX {} + 2>/dev/null || true
fi
SH
}

# --- From earlier versions: one copy, shared by dev and claude --------------------------
# That copy becomes Claude's, with everything in it (branches, uncommitted changes). Yours
# is cloned afresh from the repo, and your earlier branches are brought into it.
migrated=no
if [ ! -e "$WORK" ] && [ -d "$TRUSTED/.git" ] && [ "$(stat -c %G "$TRUSTED")" = project ]; then
  log "Splitting the project into your copy ($TRUSTED) and Claude's ($WORK)"
  # The dev servers of earlier versions ran from it, as dev
  sudo -u dev env XDG_RUNTIME_DIR="/run/user/$(id -u dev)" systemctl --user stop 'gleipnir-dev*' >/dev/null 2>&1 || true
  mv "$TRUSTED" "$WORK"
  # -h -P: links are changed themselves, never followed
  chown -R -h -P claude:project "$WORK"
  set_work_permissions -R
  # Context now lives in /srv/context. Removed as claude: the path is Claude's now.
  sudo -u claude -H rm -rf -- "$WORK/tmp/context"
  migrated=yes
fi

# --- Your copy ----------------------------------------------------------------------------
if [ ! -d "$TRUSTED/.git" ]; then
  if [ -e "$TRUSTED" ] && [ -n "$(ls -A "$TRUSTED")" ]; then
    fail "$TRUSTED isn't empty and isn't a git repo; refusing to clone over it"
  fi
  install -d -o dev -g dev -m 0750 "$TRUSTED"
  log "Cloning $REPO into your copy"
  sudo -u dev -H git clone --quiet "$REPO" "$TRUSTED"
fi
chmod 0750 "$TRUSTED"

if [ "$migrated" = yes ]; then
  # Your earlier local branches (including any commits you hadn't pushed), as previous/<name>
  if [ -n "$(sudo -u claude -H git -C "$WORK" for-each-ref --count=1 --format='%(refname)' refs/heads/)" ]; then
    # Written by root from git's output, so it can't be swapped before dev reads it
    previous="$(mktemp -d -p "$staging")"
    chmod 0755 "$previous"
    # shellcheck disable=SC2024  # root writing the file is the point
    sudo -u claude -H git -C "$WORK" -c core.fsmonitor=false -c core.hooksPath=/dev/null \
      bundle create --quiet - --branches > "$previous/all.bundle"
    chmod 0644 "$previous/all.bundle"
    sudo -u dev -H git -C "$TRUSTED" -c transfer.fsckObjects=true -c fetch.fsckObjects=true \
      fetch --quiet --no-tags --no-write-fetch-head "$previous/all.bundle" '+refs/heads/*:refs/remotes/previous/*'
    log "Your earlier branches are in your copy as previous/<name>. Claude could change them in the"
    log "shared copy, so review before using one, e.g. commits you hadn't pushed from main:"
    log "  git log -p origin/main..previous/main"
  fi
  log "Uncommitted changes from before stay in Claude's copy ($WORK)"
fi

# --- Claude's copy ------------------------------------------------------------------------
if [ ! -d "$WORK/.git" ]; then
  if [ -e "$WORK" ] && [ -n "$(ls -A "$WORK")" ]; then
    fail "$WORK isn't empty and isn't a git repo; refusing to set it up over it"
  fi
  install -d -o claude -g project -m 2770 "$WORK"
  sudo -u claude -H git -C "$WORK" init --quiet
  set_work_permissions
  /usr/local/sbin/gleipnir-sync
  # Start from your current branch, if the repo has one yet
  branch="$(sudo -u dev -H git -C "$TRUSTED" symbolic-ref --short -q HEAD || true)"
  if [ -n "$branch" ] && sudo -u claude -H git -C "$WORK" rev-parse --verify --quiet "refs/remotes/trusted/$branch" >/dev/null; then
    sudo -u claude -H git -C "$WORK" switch --quiet -c "$branch" "trusted/$branch"
  fi

  # Your starter CLAUDE.md, only on this first setup, and only if the project doesn't
  # already have one. After that it's the project's file: Claude commits it with its work.
  if [ -n "${GLEIPNIR_CLAUDE_MD:-}" ]; then
    if [ -e "$WORK/CLAUDE.md" ] || [ -e "$WORK/.claude/CLAUDE.md" ]; then
      log "The project already has a CLAUDE.md; leaving it as it is"
    else
      starter="$(hand_over_to claude)"
      install -o claude -g claude -m 0644 "$GLEIPNIR_CLAUDE_MD" "$starter/CLAUDE.md"
      sudo -u claude -H install -m 0664 "$starter/CLAUDE.md" "$WORK/CLAUDE.md"
      log "Added your starter CLAUDE.md to Claude's copy"
    fi
  fi
else
  set_work_permissions
fi

# --- The project's .env files, copied from your computer ------------------------------
# Your computer's copies win: they replace the ones in the machine on every provision.
# env/<machine>.env goes to the project's root; env/<machine>/<app>.env into each app's folder.
if [ -n "${GLEIPNIR_ENV:-}" ] || [ -n "${GLEIPNIR_ENV_DIR:-}" ]; then
  /usr/local/sbin/gleipnir-env "${GLEIPNIR_ENV:-}" "${GLEIPNIR_ENV_DIR:-}"
fi

# --- The project's context folder, copied from your computer ---------------------
if [ -n "${GLEIPNIR_CONTEXT:-}" ]; then
  /usr/local/sbin/gleipnir-context "$GLEIPNIR_CONTEXT"
fi

log "Project ready: yours in $TRUSTED, Claude's in $WORK"