#!/usr/bin/env python3
"""
Apply the VirusTotal CTF theme + landing + ordering to a LIVE CTFd, via the
admin API. Non-destructive: only touches theme_header, theme_settings, and the
index page. Never changes users, teams, challenges, submissions, or scores.

Run on the droplet (reads config from env):
    CTFD_URL=https://ctf.example.com  ADMIN_TOKEN=ctfd_xxxxx  python3 apply.py

Pure stdlib — no pip packages required.
"""
import json, os, re, sys, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
URL  = (os.environ.get("CTFD_URL") or "").rstrip("/")
TOK  = os.environ.get("ADMIN_TOKEN") or ""
if not URL or not TOK:
    sys.exit("Set CTFD_URL and ADMIN_TOKEN in the environment (see updater.env).")

def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(URL + path, data=data, method=method)
    req.add_header("Authorization", "Token " + TOK)
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read().decode() or "{}"
            return json.loads(raw)
    except urllib.error.HTTPError as e:
        sys.exit(f"API {method} {path} failed: {e.code} {e.read().decode()[:300]}")
    except Exception as e:
        sys.exit(f"API {method} {path} error: {e}")

def strip_comments(s):
    return re.sub(r"<!--.*?-->", "", s, flags=re.S).strip()

def read(name):
    with open(os.path.join(HERE, name), encoding="utf-8") as f:
        return f.read()

# ---- 1) find where the rain GIF is hosted so the theme bg resolves ----------
gif_url = ""
files = api("GET", "/api/v1/files?per_page=100")
for row in (files.get("data") or []):
    loc = row.get("location") or ""
    if loc.endswith("matrix_rain.gif"):
        gif_url = "/files/" + loc
        break
if not gif_url:
    print("WARNING: matrix_rain.gif not found in CTFd files — background will be blank. "
          "Re-import the full zip once so the GIF is hosted, then re-run.")

# ---- 2) theme_header + ordering functions (kept in sync with build.py) ------
theme = strip_comments(read("theme_header_matrix_gif.html")).replace(">>> GIF_URL <<<", gif_url)

cat_order  = r'function(a,b){var na=(String(a).match(/\d+/)||[999])[0];var nb=(String(b).match(/\d+/)||[999])[0];return (+na)-(+nb);}'
chal_order = r'function(a,b){function k(x){var m=String(x&&x.name).match(/(\d+)(?:\.(\d+))?(?:\.(\d+))?/);if(!m)return 1e9;return (+m[1])*1e4+(+(m[2]||0))*100+(+(m[3]||0));}return k(a)-k(b);}'
theme_settings = json.dumps({"challenge_category_order": cat_order, "challenge_order": chal_order})

api("PATCH", "/api/v1/configs", {"theme_header": theme, "theme_settings": theme_settings})
print("applied: theme_header + theme_settings" + (f"  (gif {gif_url})" if gif_url else ""))

# ---- 3) index (landing) page -------------------------------------------------
landing = strip_comments(read("landing_matrix.html"))
pages = api("GET", "/api/v1/pages?per_page=100")
page_id = None
for p in (pages.get("data") or []):
    if p.get("route") == "index":
        page_id = p.get("id"); break
if page_id is None:
    print("WARNING: no index page found — skipping landing update.")
else:
    full = api("GET", f"/api/v1/pages/{page_id}").get("data") or {}
    full["content"] = landing
    full["format"]  = "html"
    api("PATCH", f"/api/v1/pages/{page_id}", {
        "content": landing, "format": "html",
        "title": full.get("title") or "", "route": "index",
        "draft": bool(full.get("draft", False)), "hidden": bool(full.get("hidden", False)),
        "auth_required": bool(full.get("auth_required", False)),
    })
    print(f"applied: index page (#{page_id})")

print("DONE — live site updated, no data touched.")
