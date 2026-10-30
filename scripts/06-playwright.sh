#!/usr/bin/env bash
# Gleipnir: Playwright's browsers (optional), shared by everyone in the machine.
#
# The browsers go in /opt/playwright, where tests run by you, Claude or the dev servers use
# them but none can change them. The version comes from the project, so the browsers match
# its Playwright; but that's a number Claude can write, so nothing it picks ever runs as
# root. Root installs the system libraries using the version pinned in scripts/versions.sh,
# and the browsers themselves are downloaded by a user of their own, "browsers", with no
# rights beyond that folder, using a fresh copy of Playwright from npm (never the project's
# own copy, which Claude could have changed).
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"
export DEBIAN_FRONTEND=noninteractive

BROWSERS=/opt/playwright
INSTALLER=browsers                        # downloads the browsers; owns their folder
INSTALLER_HOME=/var/lib/gleipnir/browsers
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

# --- The system libraries the browsers need: as root, at the pinned version ------------------
log "Installing the system libraries for Playwright's browsers (Playwright $PLAYWRIGHT_DEFAULT_VERSION's list)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
(
  cd "$work"
  export HOME="$work" npm_config_cache="$work/npm-cache" npm_config_ignore_scripts=true
  npx --yes "playwright@$PLAYWRIGHT_DEFAULT_VERSION" install-deps "${WANTED[@]}" > "$work/deps.log" 2>&1 \
    || { tail -n 30 "$work/deps.log" >&2; fail "the browsers' system libraries didn't install"; }
)

# --- The browsers: as their own user, at the project's version -----------------------------
if ! id "$INSTALLER" >/dev/null 2>&1; then
  useradd --system --home-dir "$INSTALLER_HOME" --create-home --shell /usr/sbin/nologin "$INSTALLER"
fi
install -d -o "$INSTALLER" -g "$INSTALLER" -m 0700 "$INSTALLER_HOME"
install -d -o "$INSTALLER" -g "$INSTALLER" -m 0755 "$BROWSERS"
chown -R "$INSTALLER:$INSTALLER" "$BROWSERS"
log "Installing Playwright $VERSION browsers: ${WANTED[*]}"
# shellcheck disable=SC2024  # root keeping the log is the point
if ! sudo -u "$INSTALLER" -H env HOME="$INSTALLER_HOME" npm_config_cache="$INSTALLER_HOME/npm-cache" \
    npm_config_ignore_scripts=true PLAYWRIGHT_BROWSERS_PATH="$BROWSERS" \
    bash -c 'cd "$HOME" && npx --yes "playwright@$1" install "${@:2}"' _ "$VERSION" "${WANTED[@]}" > "$work/install.log" 2>&1; then
  tail -n 30 "$work/install.log" >&2
  fail "Playwright's browser install failed"
fi
# Readable by everyone, changeable by nobody who runs code (claude, runner) or by you
chmod -R u=rwX,go=rX "$BROWSERS"

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