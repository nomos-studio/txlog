#!/usr/bin/env bash
# Install project git hooks.
# Run once after cloning: bash scripts/install-hooks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/.git/hooks"

if [ ! -d "$HOOKS_DIR" ]; then
  echo "ERROR: $HOOKS_DIR not found — are you inside the git repo?"
  exit 1
fi

install_hook() {
  local src="$SCRIPT_DIR/$1"
  local dst="$HOOKS_DIR/$1"
  cp "$src" "$dst"
  chmod +x "$dst"
  echo "Installed: $dst"
}

install_hook pre-commit
echo "Done. Hooks are active."
