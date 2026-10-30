#!/usr/bin/env bash
# Gleipnir: the self-test, last of all. It checks that each user can do what it should and
# nothing more (see scripts/files/gleipnir-selftest). If anything fails, so does the
# provision, with the failures listed. Run it yourself any time: sudo gleipnir-selftest
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"

install -m 0755 "$GLEIPNIR_SRC/scripts/files/gleipnir-selftest" /usr/local/sbin/gleipnir-selftest

# The dev servers have had a moment to start; Gjöll's network tests ran in the Claude step
if ! /usr/local/sbin/gleipnir-selftest --quick | sed 's/^/    /'; then
  fail "The self-test failed (above). Fix what it lists, then provision again, or run: sudo gleipnir-selftest"
fi