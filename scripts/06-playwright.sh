#!/usr/bin/env bash
# Gleipnir: Playwright's browsers (optional), shared by everyone in the machine.
#
# The browsers go in /opt/playwright, where tests run by you, Claude or the dev servers use
# them but none can change them. The version comes from the project, so the browsers match
# its Playwright; but that's a number Claude can write, so nothing it picks ever runs as
# root. Everything from npm runs as a user of its own, "browsers", with no rights beyond
# that folder: it asks Playwright (the version pinned in scripts/versions.sh) which system
# libraries the browsers need, and root installs just those with apt; then it downloads
# the browsers with the project's version of Playwright, a fresh copy from npm (never the
# project's own, which Claude could have changed). Once they're in, the folder is root's,
# and nothing of that user's is left running or kept.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"
export DEBIAN_FRONTEND=noninteractive

BROWSERS=/opt/playwright
INSTALLER=browsers                        # downloads the browsers
INSTALLER_HOME="$BROWSERS_HOME"
PROFILE=/etc/profile.d/gleipnir-playwright.sh
DEVSERVER_ENV=/etc/systemd/system/gleipnir-dev@.service.d/playwright.conf
OLD_USER_ENV=/etc/environment.d/60-gleipnir-playwright.conf   # earlier versions
EDITOR_ENV=/etc/systemd/system/code-server@dev.service.d/playwright.conf

# --- Turned off: remove it ------------------------------------------------------------
if [ "$(cfg playwright.enabled false)" != "true" ]; then
  if [ -d "$BROWSERS" ]; then
    rm -rf "$BROWSERS" "$PROFILE" "$DEVSERVER_ENV" "$EDITOR_ENV" "$OLD_USER_ENV"
    log "Playwright's browsers removed"
  else
    log "Playwright isn't enabled; skipping"
  fi
  exit 0
fi

# --- Which version: the one the project uses, so its browsers match -------------------
# The first app that uses Playwright decides: from its package-lock.json, or else its
# installed packages. Only the version number is read from Claude's copy of the project,
# as runner (never through a link), and it's checked before use.
FOLDERS=()
while IFS=$'\t' read -r _ folder _; do
  if dir="$(app_dir "$folder")"; then FOLDERS+=("$dir"); fi
done < <(apps)
VERSION="$(timeout 20 sudo -u runner python3 -I - "${FOLDERS[@]}" <<'PY'
import json, os, stat, sys
PACKAGES = ("playwright-core", "playwright", "@playwright/test")
def load(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 50_000_000:
            return None
        with os.fdopen(fd, "rb") as fh:
            fd = None
            data = json.loads(fh.read())
    except (OSError, ValueError):
        return None
    finally:
        if fd is not None:
            os.close(fd)
    return data if isinstance(data, dict) else None
def version():
    for folder in sys.argv[1:]:
        entries = (load(os.path.join(folder, "package-lock.json")) or {}).get("packages")
        if isinstance(entries, dict):
            for package in PACKAGES:
                entry = entries.get("node_modules/" + package)
                if isinstance(entry, dict) and entry.get("version"):
                    return str(entry["version"])
        for package in PACKAGES:
            data = load(os.path.join(folder, "node_modules", package, "package.json"))
            if data and data.get("version"):
                return str(data["version"])
    return ""
print(version())
PY
)" || VERSION=""
if [ -z "$VERSION" ]; then
  VERSION="$PLAYWRIGHT_DEFAULT_VERSION"
  warn "The project doesn't use Playwright yet; installing browsers for Playwright $VERSION (scripts/versions.sh). Provision again after adding it."
elif ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  fail "Unexpected Playwright version in the project: $VERSION"
fi

mapfile -t WANTED < <(cfg playwright.browsers chromium | sed '/^$/d')
[ "${#WANTED[@]}" -gt 0 ] || WANTED=(chromium)
for browser in "${WANTED[@]}"; do
  case "$browser" in
    chromium|firefox|webkit) ;;
    *) fail "playwright.browsers: \"$browser\" isn't one Gleipnir can install (use chromium, firefox or webkit)" ;;
  esac
done

# --- The user that does the downloading -------------------------------------------------
id "$INSTALLER" >/dev/null 2>&1 || fail "there's no $INSTALLER user (scripts/02-users.sh makes it)"
# Nothing of an earlier run is still about, and nothing it fetched (npm's cache, Playwright
# itself) is kept: its home is emptied before and after
stop_installer() {
  for _ in 1 2 3 4 5; do
    pkill -KILL -u "$INSTALLER" 2>/dev/null || return 0
    sleep 0.2
  done
}
reset_home() {
  rm -rf "$INSTALLER_HOME"
  install -d -o "$INSTALLER" -g "$INSTALLER" -m 0700 "$INSTALLER_HOME"
}
work="$(mktemp -d)"
trap 'stop_installer; reset_home; rm -rf "$work"' EXIT
stop_installer
reset_home
# A command as that user, in its own home, with Playwright's downloads going to $BROWSERS
as_installer() {
  sudo -u "$INSTALLER" -H env HOME="$INSTALLER_HOME" npm_config_cache="$INSTALLER_HOME/npm-cache" \
    npm_config_ignore_scripts=true PLAYWRIGHT_BROWSERS_PATH="$BROWSERS" \
    bash -c 'cd "$HOME" && "$@"' _ "$@"
}

# --- The system libraries the browsers need: Playwright names them, root installs them ------
# "install-deps --dry-run" has apt simulate the install and lists what's missing, one package
# a line, leaving with 1 when something is: nothing from npm runs as root.
log "Asking Playwright $PLAYWRIGHT_DEFAULT_VERSION which system libraries the browsers need"
set +e
as_installer npx --yes "playwright@$PLAYWRIGHT_DEFAULT_VERSION" install-deps --dry-run "${WANTED[@]}" \
  > "$work/deps.out" 2> "$work/deps.err"
asked=$?
set -e
case "$asked" in
  0|1) ;;
  *) tail -n 30 "$work/deps.err" >&2; fail "couldn't find out which system libraries the browsers need (playwright install-deps --dry-run)" ;;
esac
mapfile -t PACKAGES < <(sed -n 's/^  \([a-z0-9][a-z0-9.+-]*\)$/\1/p' "$work/deps.out")
if [ "$asked" -eq 1 ] && [ "${#PACKAGES[@]}" -eq 0 ]; then
  tail -n 30 "$work/deps.out" >&2
  fail "Playwright says system libraries are missing but didn't list them in the form Gleipnir reads (playwright install-deps --dry-run)"
fi
if [ "${#PACKAGES[@]}" -gt 0 ]; then
  log "Installing ${#PACKAGES[@]} system libraries for the browsers"
  apt-get install -y --no-install-recommends "${PACKAGES[@]}" > "$work/apt.log" 2>&1 \
    || { tail -n 30 "$work/apt.log" >&2; fail "the browsers' system libraries didn't install"; }
else
  log "The browsers' system libraries are all installed"
fi

# --- The browsers: downloaded by that user, at the project's version, then root's ----------
install -d -m 0755 "$BROWSERS"
chown -R -h "$INSTALLER:$INSTALLER" "$BROWSERS"   # -h: links themselves, never what they point at
log "Installing Playwright $VERSION browsers: ${WANTED[*]}"
if ! as_installer npx --yes "playwright@$VERSION" install "${WANTED[@]}" > "$work/install.log" 2>&1; then
  tail -n 30 "$work/install.log" >&2
  fail "Playwright's browser install failed"
fi
stop_installer
# Root's from here on: readable by everyone, changeable by nobody who runs code, not even
# the user that downloaded them. A link leading out of the folder has no business in it.
chown -R -h root:root "$BROWSERS"
chmod -R u=rwX,go=rX "$BROWSERS"
while IFS= read -r -d '' link; do
  case "$(readlink -f -- "$link" || true)" in
    "$BROWSERS"/*) ;;
    *) rm -f -- "$link"; warn "Removed $link, a link leading out of $BROWSERS" ;;
  esac
done < <(find "$BROWSERS" -type l -print0)

# --- Point every user at them ------------------------------------------------------------
# Login shells (vagrant ssh, and Claude's sessions)
echo "export PLAYWRIGHT_BROWSERS_PATH=$BROWSERS" > "$PROFILE"
chmod 0644 "$PROFILE"
# The dev servers (their step restarts them) and the editor and its terminal (the editor
# step restarts it)
rm -f "$OLD_USER_ENV"
for dropin in "$DEVSERVER_ENV" "$EDITOR_ENV"; do
  install -d -m 0755 "$(dirname "$dropin")"
  printf '[Service]\nEnvironment=PLAYWRIGHT_BROWSERS_PATH=%s\n' "$BROWSERS" > "$dropin"
  chmod 0644 "$dropin"
done
systemctl daemon-reload

log "Playwright $VERSION browsers ready in $BROWSERS"