#!/usr/bin/env python3
"""
Tiny TOTP (Google Authenticator) gate for the CTFd /admin panel.
Caddy forward_auths /admin* to /__2fa/verify here; unauthenticated requests are
redirected to a 6-digit code form. On a correct code we set a short-lived signed
cookie and let the request through. Completely separate from CTFd — if this
service is down, only /admin is affected, never the student site.
"""
import os
from flask import Flask, request, redirect, make_response
import pyotp
from itsdangerous import URLSafeTimedSerializer, BadSignature, SignatureExpired

SECRET = os.environ["TOTP_SECRET"]          # base32 TOTP secret (from .env)
GATE   = os.environ["GATE_SECRET"]          # cookie-signing key (from .env)
TTL    = int(os.environ.get("TOTP_TTL", "43200"))   # cookie lifetime: 12h
COOKIE = "vt2fa"
signer = URLSafeTimedSerializer(GATE, salt="vt2fa")
app = Flask(__name__)

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

def is_https():
    return request.headers.get("X-Forwarded-Proto", "").lower() == "https"

def valid_cookie():
    c = request.cookies.get(COOKIE)
    if not c:
        return False
    try:
        signer.loads(c, max_age=TTL); return True
    except (BadSignature, SignatureExpired):
        return False

def safe_next(n):
    # only allow local admin paths, never an open redirect
    if not n or not n.startswith("/") or n.startswith("//") or not (n == "/admin" or n.startswith("/admin")):
        return "/admin"
    return n

@app.route("/__2fa/verify")
def verify():
    if valid_cookie():
        return ("ok", 200)
    nxt = safe_next(request.headers.get("X-Forwarded-Uri", "/admin"))
    return redirect("/__2fa/login?next=" + nxt, code=302)

@app.route("/__2fa/login", methods=["GET", "POST"])
def login():
    nxt = safe_next(request.values.get("next", "/admin"))
    if request.method == "POST":
        code = (request.form.get("code") or "").strip().replace(" ", "")
        if code and pyotp.TOTP(SECRET).verify(code, valid_window=1):
            resp = make_response(redirect(nxt, code=302))
            resp.set_cookie(COOKIE, signer.dumps("ok"), max_age=TTL,
                            httponly=True, secure=is_https(), samesite="Lax", path="/")
            return resp
        return (FORM.format(err='<p style="color:#ff6b6b;font-size:13px;margin:0 0 10px">Invalid code — try again.</p>', next=nxt), 401)
    return (FORM.format(err="", next=nxt), 200)

@app.route("/__2fa/health")
def health():
    return ("ok", 200)
