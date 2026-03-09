#!/usr/bin/env bash
# Record all sagefs.nvim screenshots and demo GIFs using VHS.
# Requirements: vhs, neovim (0.10+), sagefs daemon running on port 37749
# On Windows: run via WSL2 or Docker.
#
# Install VHS:
#   brew install vhs        # macOS
#   sudo apt install vhs    # Ubuntu (or use the GitHub Actions workflow)
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Recording screenshots..."
for tape in docs/tapes/screenshot-*.tape; do
  echo "  vhs $tape"
  vhs "$tape"
done

echo "==> Recording demo GIFs..."
for tape in docs/tapes/demo-*.tape; do
  echo "  vhs $tape"
  vhs "$tape"
done

echo ""
echo "Generated files:"
ls -lh docs/screenshot-*.png docs/demo-*.gif 2>/dev/null || true
