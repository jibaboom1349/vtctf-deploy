#!/usr/bin/env bash
# ==========================================================================
# VirusTotal CTF — one-shot DigitalOcean deploy
# Run this ONCE on a fresh Ubuntu 22.04/24.04 droplet, as root:
#
#     bash deploy.sh
#
# It installs Docker, writes the full production stack (CTFd + MariaDB +
# Redis + Caddy auto-HTTPS) into /opt/ctfd, generates secrets, opens the
# firewall, and starts everything. Safe to re-run.
# ==========================================================================
set -euo pipefail

STACK_DIR=/opt/ctfd

say(){ printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then echo "Please run as root (sudo bash deploy.sh)"; exit 1; fi

# ---- 1) domain (for HTTPS) ----------------------------------------------
echo
echo "Enter the DOMAIN that points at this droplet (e.g. ctf.yourschool.edu)."
echo "Its DNS 'A' record must already point to THIS server's public IP."
echo "Leave BLANK to serve plain HTTP on port 80 (no certificate — fine for a quick test)."
read -r -p "Domain: " DOMAIN || true
DOMAIN="$(echo "${DOMAIN:-}" | tr -d '[:space:]')"

if [ -n "$DOMAIN" ]; then
  CADDY_SITE="$DOMAIN"
  URL="https://$DOMAIN"
else
  CADDY_SITE=":80"
  URL="http://$(curl -s -m 5 https://api.ipify.org || echo YOUR_DROPLET_IP)"
fi

# ---- 2) install Docker (official convenience script) --------------------
if ! command -v docker >/dev/null 2>&1; then
  say "Installing Docker…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  curl -fsSL https://get.docker.com | sh
else
  say "Docker already installed — skipping."
fi
systemctl enable --now docker

# ---- 3) write the stack --------------------------------------------------
say "Writing stack to $STACK_DIR …"
mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

# secrets: generate once, keep on re-run
if [ ! -f .env ]; then
  cat > .env <<ENV
SECRET_KEY=$(openssl rand -hex 32)
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
MYSQL_PASSWORD=$(openssl rand -hex 32)
ENV
  chmod 600 .env
  say "Generated fresh secrets in $STACK_DIR/.env"
else
  say ".env already exists — keeping existing secrets."
fi

cat > docker-compose.yml <<'YML'
services:
  ctfd:
    image: ctfd/ctfd:3.7.0
    restart: always
    environment:
      - SECRET_KEY=${SECRET_KEY}
      - DATABASE_URL=mysql+pymysql://ctfd:${MYSQL_PASSWORD}@db/ctfd
      - REDIS_URL=redis://cache:6379
      - WORKERS=4
      - WORKER_CLASS=gevent
      - REVERSE_PROXY=true
      - LOG_FOLDER=/var/log/CTFd
      - ACCESS_LOG=-
      - ERROR_LOG=-
    volumes:
      - ctfd_uploads:/var/uploads
      - ctfd_logs:/var/log/CTFd
    depends_on:
      db: { condition: service_healthy }
      cache: { condition: service_started }
    networks: [internal, web]
    expose: ["8000"]

  db:
    image: mariadb:10.11
    restart: always
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - MYSQL_DATABASE=ctfd
      - MYSQL_USER=ctfd
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
    command: [mysqld, --character-set-server=utf8mb4, --collation-server=utf8mb4_unicode_ci, --wait_timeout=28800, --max-connections=400]
    volumes: [db_data:/var/lib/mysql]
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 12
    networks: [internal]

  cache:
    image: redis:4
    restart: always
    volumes: [redis_data:/data]
    networks: [internal]

  caddy:
    image: caddy:2
    restart: always
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on: [ctfd]
    networks: [web]

networks:
  internal: { internal: true }
  web: {}

volumes:
  ctfd_uploads: { name: ctfd_uploads }
  ctfd_logs: { name: ctfd_logs }
  db_data: { name: ctfd_db_data }
  redis_data: { name: ctfd_redis_data }
  caddy_data: { name: ctfd_caddy_data }
  caddy_config: { name: ctfd_caddy_config }
YML

cat > Caddyfile <<CADDY
${CADDY_SITE} {
    reverse_proxy ctfd:8000
    request_body {
        max_size 100MB
    }
    encode gzip
}
CADDY

# backup helper
cat > backup.sh <<'BAK'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
set -a; source ./.env; set +a
STAMP=$(date +%F_%H%M); mkdir -p backups
docker compose exec -T db sh -c "exec mysqldump -uctfd -p\"$MYSQL_PASSWORD\" ctfd" > "backups/db_${STAMP}.sql"
docker run --rm -v ctfd_uploads:/data:ro -v "$(pwd)/backups:/backup" alpine tar czf "/backup/uploads_${STAMP}.tar.gz" -C /data .
find backups -type f -mtime +14 -delete
echo "backup complete: backups/db_${STAMP}.sql + backups/uploads_${STAMP}.tar.gz"
BAK
chmod +x backup.sh

# ---- 4) firewall (allow SSH first so we never lock ourselves out) -------
if command -v ufw >/dev/null 2>&1; then
  say "Configuring firewall (22/80/443)…"
  ufw allow 22/tcp   >/dev/null 2>&1 || true
  ufw allow OpenSSH  >/dev/null 2>&1 || true
  ufw allow 80/tcp   >/dev/null 2>&1 || true
  ufw allow 443/tcp  >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
fi

# ---- 5) launch -----------------------------------------------------------
say "Pulling images and starting the stack…"
docker compose pull
docker compose up -d

say "Daily backup at 03:30 (cron)…"
( crontab -l 2>/dev/null | grep -v "$STACK_DIR/backup.sh" ; echo "30 3 * * * $STACK_DIR/backup.sh >> $STACK_DIR/backup.log 2>&1" ) | crontab -

cat <<DONE

============================================================
  CTFd stack is up.  Site: $URL
============================================================
NEXT (do these in your browser — one time):
  1. Open  $URL/setup
       - create your temporary admin, name the event, Finish.
  2. Admin panel -> Config -> Backup -> Import
       - upload  CTFd_VirusTotal_FINAL.zip  (from your Mac)
       - this restores all challenges, teams, roster, theme.
  3. After import you log in as  yihaolim@smu.edu.sg  (your
     existing admin from the export). The temporary admin from
     step 1 is replaced by the imported data — expected.
  4. Before the event: log in as yihaolim -> landing page ->
     "Clear All Tries", then "Start 45-min Quiz" when ready.

Useful:
  cd $STACK_DIR
  docker compose ps           # status
  docker compose logs -f ctfd # live logs
  ./backup.sh                 # manual backup
============================================================
DONE
