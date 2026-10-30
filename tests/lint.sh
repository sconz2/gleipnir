#!/usr/bin/env bash
# Gleipnir: static checks on every script. Run from anywhere:  tests/lint.sh
#   bash -n on the shell scripts (and ShellCheck, if it's installed), a syntax check on the
#   Python scripts, and on the Vagrantfile (if Ruby is installed).
set -uo pipefail
cd "$(dirname "$0")/.."

failed=0
shell_scripts=(install.sh scripts/*.sh)
python_scripts=()
for file in scripts/files/*; do
  case "$(head -n 1 "$file")" in
    *bash*) shell_scripts+=("$file") ;;
    *python*) python_scripts+=("$file") ;;
  esac
done

for file in "${shell_scripts[@]}"; do
  bash -n "$file" || { echo "lint: $file doesn't parse"; failed=1; }
done
sh -n install-shortcuts || { echo "lint: install-shortcuts doesn't parse"; failed=1; }

if command -v shellcheck >/dev/null; then
  shellcheck -x -P scripts -S warning "${shell_scripts[@]}" || failed=1
  shellcheck -s sh -S warning install-shortcuts || failed=1
else
  echo "lint: ShellCheck isn't installed; skipped it"
fi

for file in "${python_scripts[@]}" tests/unit/*.py; do
  python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$file" \
    || { echo "lint: $file doesn't parse"; failed=1; }
done

if command -v ruby >/dev/null; then
  ruby -c Vagrantfile >/dev/null || { echo "lint: the Vagrantfile doesn't parse"; failed=1; }
fi

if [ "$failed" -eq 0 ]; then echo "lint: all good"; fi
exit "$failed"