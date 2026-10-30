# shellcheck shell=bash disable=SC2034  # sourced: its settings are used by the steps
# Gleipnir: shared helpers. Sourced by each step, not run on its own.

GLEIPNIR_CONFIG="${GLEIPNIR_CONFIG:-/etc/gleipnir/config.json}"
# The versions Gleipnir installs, and their checksums
source "$GLEIPNIR_SRC/scripts/versions.sh"

# Where things live in the machine
TRUSTED=/srv/project            # your copy of the project: dev's, which Claude can't change
WORK=/srv/work                  # Claude's copy: where it works and the dev servers run
CONTEXT_DIR=/srv/context        # background files for Claude, which it can read but not change
RUNNER_HOME=/var/lib/gleipnir/runner

log()  { echo "    $*"; }
warn() { echo "    WARNING: $*" >&2; }
fail() { echo "    ERROR: $*" >&2; exit 1; }

# Read a value from the config:  cfg <dotted.path> [default]
# Booleans print as true/false; lists print one item per line.
cfg() {
  python3 -I - "$GLEIPNIR_CONFIG" "$1" "${2-}" <<'PY'
import json, sys
path, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    data = json.load(fh)
for part in key.split("."):
    if isinstance(data, dict) and part in data:
        data = data[part]
    else:
        print(default)
        sys.exit(0)
if isinstance(data, bool):
    print("true" if data else "false")
elif isinstance(data, list):
    print("\n".join(str(item) for item in data))
else:
    print(data)
PY
}

# The project's apps, one per line, tab-separated:  name  folder  port  devserver  command
#   folder     relative to the project ("." is the project itself)
#   port       the port its dev server listens on inside the machine
#   devserver  true or false
#   command    its dev server command from the config, or empty to work it out
# Without "apps" in the config, the whole project is one app called "app" on port 5173.
apps() {
  python3 -I "$GLEIPNIR_SRC/scripts/files/gleipnir-apps" "$GLEIPNIR_CONFIG"
}

# An app's folder in Claude's copy, as an absolute path, only if it's really there: a folder,
# with no link anywhere along the way (a link could lead outside the copy). Fails otherwise.
#   app_dir <folder>
app_dir() {
  local wanted resolved
  wanted="$(realpath -m -s -- "$WORK/$1")"
  resolved="$(realpath -e -- "$WORK/$1" 2>/dev/null)" || return 1
  [ "$resolved" = "$wanted" ] && [ -d "$resolved" ] || return 1
  printf '%s\n' "$resolved"
}

# Download a signing key and keep only the key with this fingerprint (with its subkeys), as a
# keyring apt can use. Anything else in the download, such as a second key added by whoever
# changed the file, is left out; if the key isn't in it at all, provisioning stops.
#   trusted_key <url> <fingerprint> <keyring.gpg>
trusted_key() {
  local url="$1" fpr="$2" out="$3" home
  home="$(mktemp -d)"
  if ! curl -fsSL "$url" -o "$home/download"; then
    rm -rf "$home"
    fail "couldn't download the signing key from $url"
  fi
  if ! GNUPGHOME="$home" gpg --batch --quiet --import "$home/download" 2>/dev/null \
      || ! GNUPGHOME="$home" gpg --batch --with-colons --list-keys "$fpr" 2>/dev/null | grep -q "^fpr:*$fpr:"; then
    GNUPGHOME="$home" gpgconf --kill all 2>/dev/null || true
    rm -rf "$home"
    fail "the signing key from $url doesn't have the expected fingerprint ($fpr); stopping"
  fi
  GNUPGHOME="$home" gpg --batch --export "$fpr" > "$home/keyring"
  GNUPGHOME="$home" gpgconf --kill all 2>/dev/null || true
  install -d -m 0755 "$(dirname "$out")"
  install -m 0644 "$home/keyring" "$out"
  rm -rf "$home"
}