#!/usr/bin/env bash
# Runs every minute from cron. Pulls the repo; if it changed, applies to live CTFd.
set -euo pipefail

UPDATER_DIR=/opt/ctfd-updater
REPO_DIR="$UPDATER_DIR/repo"

set -a; source "$UPDATER_DIR/updater.env"; set +a   # CTFD_URL, ADMIN_TOKEN

cd "$REPO_DIR"
before=$(git rev-parse HEAD 2>/dev/null || echo none)
git fetch --quiet origin main
git reset --hard --quiet origin/main
after=$(git rev-parse HEAD)

if [ "$before" != "$after" ] || [ "${1:-}" = "--force" ]; then
  echo "[$(date '+%F %T')] change $before -> $after : applying"
  python3 "$REPO_DIR/apply.py"
else
  echo "[$(date '+%F %T')] no change"
fi
