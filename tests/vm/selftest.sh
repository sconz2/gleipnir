#!/usr/bin/env bash
# Gleipnir: run the self-test in a machine, from your computer.
#   tests/vm/selftest.sh <machine>           everything, including Gjöll's network tests
#   tests/vm/selftest.sh <machine> --quick   without the network tests
set -euo pipefail
machine="${1:?usage: tests/vm/selftest.sh <machine> [--quick]}"
cd "$(dirname "$0")/../.."
vagrant ssh "$machine" -c "sudo gleipnir-selftest ${2:-}"