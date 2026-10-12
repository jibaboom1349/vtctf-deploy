#!/usr/bin/env bash
# ==========================================================================
# Install the auto-updater on the droplet. Run ONCE, as root:
#
#     bash install-updater.sh
#
# It clones your deploy repo, asks for the CTFd URL + an admin API token,
# and installs a cron job that pulls + applies changes every minute.
# Safe to re-run (updates the clone and settings in place).
# ==========================================================================
set -euo pipefail

UPDATER_DIR=/opt/ctfd-updater
REPO_DIR="$UPDATER_DIR/repo"

if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo bash install-updater.sh)"; exit 1; fi
command -v git >/dev/null 2>&1 || { apt-get update -y && apt-get install -y git; }

echo
read -r -p "GitHub repo URL (https://github.com/OWNER/REPO.git): " REPO_URL
read -r -p "CTFd URL (e.g. https://ctf.yourschool.edu  or  http://YOUR_IP): " CTFD_URL
read -r -p "CTFd admin API token (CTFd -> Settings -> Access Tokens -> Generate): " ADMIN_TOKEN

mkdir -p "$UPDATER_DIR"

# secrets live OUTSIDE the repo, readable only by root
cat > "$UPDATER_DIR/updater.env" <<ENV
CTFD_URL=$CTFD_URL
ADMIN_TOKEN=$ADMIN_TOKEN
ENV
chmod 600 "$UPDATER_DIR/updater.env"

if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
  git -C "$REPO_DIR" fetch --quiet origin main
  git -C "$REPO_DIR" reset --hard --quiet origin/main
else
  rm -rf "$REPO_DIR"
  git clone --quiet "$REPO_URL" "$REPO_DIR"
fi

# cron: pull + apply every minute
LINE="* * * * * /usr/bin/env bash $REPO_DIR/pull-and-apply.sh >> $UPDATER_DIR/apply.log 2>&1"
( crontab -l 2>/dev/null | grep -v "pull-and-apply.sh" ; echo "$LINE" ) | crontab -

echo
echo "Installed. First apply now:"
/usr/bin/env bash "$REPO_DIR/pull-and-apply.sh" --force || true
echo
echo "Done. Live log:  tail -f $UPDATER_DIR/apply.log"
