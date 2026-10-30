#!/usr/bin/env bash
# Gleipnir: the working users, none with sudo and none with a password.
#   dev       you: the editor, your own copy of the project (/srv/project), git and pushing
#   claude    Claude Code, in its own copy of the project (/srv/work); firewalled in a later step
#   runner    runs the dev servers from Claude's copy; no login, no keys, firewalled too
#   browsers  downloads Playwright's browsers, when they're wanted; no login, nothing else
# claude and runner share Claude's copy through the "project" group. dev isn't in it:
# nothing Claude writes is ever run as dev.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"

getent group project >/dev/null || groupadd project

for user in dev claude; do
  id "$user" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$user"
  chmod 700 "/home/$user"
done
# runner's and browsers' homes are outside /home, which their services can't see at all
install -d -m 0755 "$(dirname "$RUNNER_HOME")"
if ! id runner >/dev/null 2>&1; then
  useradd --system --home-dir "$RUNNER_HOME" --create-home --shell /usr/sbin/nologin runner
fi
install -d -o runner -g runner -m 0700 "$RUNNER_HOME"
if ! id browsers >/dev/null 2>&1; then
  useradd --system --home-dir "$BROWSERS_HOME" --create-home --shell /usr/sbin/nologin browsers
fi
install -d -o browsers -g browsers -m 0700 "$BROWSERS_HOME"

usermod -aG project claude
usermod -aG project runner
# Earlier versions shared the project with dev through this group
gpasswd -d dev project >/dev/null 2>&1 || true

# No passwords: none of them logs in with one (the editor has its own), and a password
# would be a way from one of them to another, with su
for user in dev claude runner browsers; do
  passwd -l "$user" >/dev/null 2>&1 || true
done

# A guard, in case a base box ever puts new users in an admin group
for user in dev claude runner browsers; do
  if id -nG "$user" | grep -qwE 'sudo|admin|wheel'; then
    fail "$user is in an admin group; it must not have sudo"
  fi
done

log "Users ready: dev, claude, runner and browsers (group project: claude, runner)"