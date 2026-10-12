#!/usr/bin/env bash
# ==========================================================================
# VirusTotal CTF — one-shot DigitalOcean deploy
# Run ONCE on a fresh Ubuntu 22.04/24.04 droplet, as root:
#
#     bash deploy.sh
#
# Installs Docker, writes the full stack (CTFd + MariaDB + Redis + Caddy
# auto-HTTPS) to /opt/ctfd, generates secrets, opens the firewall, starts it.
# Safe to re-run.
#
# ADMIN 2FA (Google Authenticator): optional. If BOTH TOTP_SECRET and
# GATE_SECRET are present in /opt/ctfd/.env, this script adds a TOTP gate in
# front of the /admin panel only. Remove those two lines and re-run to disable.
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
if [ -n "$DOMAIN" ]; then CADDY_SITE="$DOMAIN"; URL="https://$DOMAIN"
else CADDY_SITE=":80"; URL="http://$(curl -s -m 5 https://api.ipify.org || echo YOUR_DROPLET_IP)"; fi

# ---- 2) install Docker ---------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  say "Installing Docker…"; export DEBIAN_FRONTEND=noninteractive
  apt-get update -y; curl -fsSL https://get.docker.com | sh
else say "Docker already installed — skipping."; fi
systemctl enable --now docker

# ---- 3) stack dir + secrets ----------------------------------------------
say "Writing stack to $STACK_DIR …"
mkdir -p "$STACK_DIR"; cd "$STACK_DIR"
if [ ! -f .env ]; then
  cat > .env <<ENV
SECRET_KEY=$(openssl rand -hex 32)
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
MYSQL_PASSWORD=$(openssl rand -hex 32)
ENV
  chmod 600 .env; say "Generated fresh secrets in $STACK_DIR/.env"
else say ".env already exists — keeping existing secrets."; fi

# admin 2FA on only if BOTH secrets are set in .env
TWOFA=""
if grep -Eq '^TOTP_SECRET=.+' .env && grep -Eq '^GATE_SECRET=.+' .env; then TWOFA=1; fi

# ---- 3a) TOTP gate app (used only when 2FA is enabled) -------------------
mkdir -p "$STACK_DIR/totp-gate"
cat > "$STACK_DIR/totp-gate/app.py" <<'PYEOF'
import os
from flask import Flask, request, redirect, make_response
import pyotp
from itsdangerous import URLSafeTimedSerializer, BadSignature, SignatureExpired
SECRET = os.environ["TOTP_SECRET"]; GATE = os.environ["GATE_SECRET"]
TTL = int(os.environ.get("TOTP_TTL", "43200")); COOKIE = "vt2fa"
signer = URLSafeTimedSerializer(GATE, salt="vt2fa"); app = Flask(__name__)
FORM = """<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>Admin verification</title></head>
<body style="font-family:system-ui,Segoe UI,Arial;background:#0b1410;color:#eafff2;margin:0;display:flex;min-height:100vh;align-items:center;justify-content:center">
<form method=post style="background:#13251a;border:1px solid #00a357;border-radius:10px;padding:30px;width:320px;box-shadow:0 0 40px -10px #00ff6a">
<div style="font-family:'Courier New',monospace;color:#00ff6a;letter-spacing:2px;font-size:13px">// admin verification</div>
<h2 style="margin:6px 0 10px">Enter your 2FA code</h2>
<p style="color:#8fb6a0;font-size:14px;margin:0 0 14px">6-digit code from Google Authenticator.</p>
{err}
<input name=code inputmode=numeric autocomplete=one-time-code autofocus pattern="[0-9]*" maxlength=6
 style="width:100%;box-sizing:border-box;font-size:24px;letter-spacing:6px;text-align:center;padding:12px;margin:0 0 12px;background:#010a04;border:1px solid #00a357;color:#00ff6a;border-radius:8px">
<input type=hidden name=next value="{next}">
<button style="width:100%;padding:12px;background:#00ff6a;color:#001a08;border:0;border-radius:8px;font-weight:800;font-size:15px;cursor:pointer">VERIFY</button>
</form></body></html>"""
def is_https(): return request.headers.get("X-Forwarded-Proto","").lower()=="https"
def valid_cookie():
    c=request.cookies.get(COOKIE)
    if not c: return False
    try: signer.loads(c, max_age=TTL); return True
    except (BadSignature, SignatureExpired): return False
def safe_next(n):
    if not n or not n.startswith("/") or n.startswith("//") or not n.startswith("/admin"): return "/admin"
    return n
@app.route("/__2fa/verify")
def verify():
    if valid_cookie(): return ("ok",200)
    return redirect("/__2fa/login?next="+safe_next(request.headers.get("X-Forwarded-Uri","/admin")), code=302)
@app.route("/__2fa/login", methods=["GET","POST"])
def login():
    nxt=safe_next(request.values.get("next","/admin"))
    if request.method=="POST":
        code=(request.form.get("code") or "").strip().replace(" ","")
        if code and pyotp.TOTP(SECRET).verify(code, valid_window=1):
            resp=make_response(redirect(nxt, code=302))
            resp.set_cookie(COOKIE, signer.dumps("ok"), max_age=TTL, httponly=True, secure=is_https(), samesite="Lax", path="/")
            return resp
        return (FORM.format(err='<p style="color:#ff6b6b;font-size:13px;margin:0 0 10px">Invalid code — try again.</p>', next=nxt), 401)
    return (FORM.format(err="", next=nxt), 200)
@app.route("/__2fa/health")
def health(): return ("ok",200)
PYEOF

# ---- 3b) docker-compose.yml (gate service appended only when 2FA on) -----
{
cat <<'YML1'
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
    ports: ["127.0.0.1:8000:8000"]
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
YML1
if [ -n "$TWOFA" ]; then
cat <<'YML2'
  totp-gate:
    image: python:3.12-slim
    restart: always
    working_dir: /app
    command: sh -c "pip install --no-cache-dir flask pyotp itsdangerous gunicorn >/dev/null 2>&1 && exec gunicorn -b 0.0.0.0:8000 --workers 2 app:app"
    environment:
      - TOTP_SECRET=${TOTP_SECRET}
      - GATE_SECRET=${GATE_SECRET}
    volumes:
      - ./totp-gate:/app:ro
    networks: [web]
    expose: ["8000"]
YML2
fi
cat <<'YML3'

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
YML3
} > docker-compose.yml

# ---- 3c) Caddyfile (admin gate only when 2FA on) -------------------------
if [ -n "$TWOFA" ]; then
cat > Caddyfile <<CADDY
${CADDY_SITE} {
    encode gzip
    request_body { max_size 100MB }

    @twofa path /__2fa/*
    handle @twofa {
        reverse_proxy totp-gate:8000
    }

    @admin path /admin /admin/*
    handle @admin {
        forward_auth totp-gate:8000 {
            uri /__2fa/verify
        }
        reverse_proxy ctfd:8000
    }

    handle {
        reverse_proxy ctfd:8000
    }
}
CADDY
else
cat > Caddyfile <<CADDY
${CADDY_SITE} {
    reverse_proxy ctfd:8000
    request_body { max_size 100MB }
    encode gzip
}
CADDY
fi

# ---- 3d) backup helper ---------------------------------------------------
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

# ---- 4) firewall ---------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  say "Configuring firewall (22/80/443)…"
  ufw allow 22/tcp >/dev/null 2>&1 || true; ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw allow 80/tcp >/dev/null 2>&1 || true; ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
fi

# ---- 5) launch -----------------------------------------------------------
say "Pulling images and starting the stack…"
docker compose pull
docker compose up -d

# reload Caddy so a rewritten Caddyfile (e.g. toggling the 2FA gate) takes effect without a full recreate
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || docker compose restart caddy

say "Daily backup at 03:30 (cron)…"
( crontab -l 2>/dev/null | grep -v "$STACK_DIR/backup.sh" ; echo "30 3 * * * $STACK_DIR/backup.sh >> $STACK_DIR/backup.log 2>&1" ) | crontab -

cat <<DONE

============================================================
  CTFd stack is up.  Site: $URL
  Admin 2FA: $([ -n "$TWOFA" ] && echo "ENABLED (TOTP gate on /admin)" || echo "off")
============================================================
DONE
if [ -n "$TWOFA" ]; then cat <<'NOTE'
Admin 2FA is ON. Visiting /admin now asks for a Google Authenticator code
before the panel loads. The gate installs its deps on first start (~15s) —
give it a moment, then open /admin.
To DISABLE: remove the TOTP_SECRET and GATE_SECRET lines from /opt/ctfd/.env
and re-run this script.
NOTE
fi
