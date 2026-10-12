#!/usr/bin/env python3
"""
Apply the VirusTotal CTF theme + landing + ordering to a LIVE CTFd, via the
admin API. Non-destructive: only touches theme_header, theme_settings, and the
index page. Never changes users, teams, challenges, submissions, or scores.

Run on the droplet (reads config from env):
    CTFD_URL=https://ctf.example.com  ADMIN_TOKEN=ctfd_xxxxx  python3 apply.py

Pure stdlib — no pip packages required.
"""
import json, os, re, sys, uuid, urllib.request, urllib.error

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
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read().decode() or "{}"
            return json.loads(raw)
    except urllib.error.HTTPError as e:
        sys.exit(f"API {method} {path} failed: {e.code} {e.read().decode()[:300]}")
    except Exception as e:
        sys.exit(f"API {method} {path} error: {e}")

def file_served(loc):
    """True only if the file is actually downloadable (row may exist but file be missing)."""
    req = urllib.request.Request(URL + "/files/" + loc, method="GET")
    req.add_header("Authorization", "Token " + TOK)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status == 200
    except Exception:
        return False

def upload_gif():
    """Upload matrix_rain.gif from the repo to CTFd as a standard file; return its location."""
    path = os.path.join(HERE, "matrix_rain.gif")
    if not os.path.exists(path):
        return None
    with open(path, "rb") as f:
        content = f.read()
    boundary = "----vtctf" + uuid.uuid4().hex
    nl = b"\r\n"
    parts = []
    parts += [b"--" + boundary.encode(),
              b'Content-Disposition: form-data; name="file"; filename="matrix_rain.gif"',
              b"Content-Type: image/gif", b"", content]
    parts += [b"--" + boundary.encode(),
              b'Content-Disposition: form-data; name="type"', b"", b"standard"]
    parts += [b"--" + boundary.encode() + b"--", b""]
    body = nl.join(parts)
    req = urllib.request.Request(URL + "/api/v1/files", data=body, method="POST")
    req.add_header("Authorization", "Token " + TOK)
    req.add_header("Content-Type", "multipart/form-data; boundary=" + boundary)
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            j = json.loads(r.read().decode() or "{}")
        return (j.get("data") or [{}])[0].get("location")
    except Exception as e:
        print("WARNING: GIF upload failed:", e)
        return None

def strip_comments(s):
    return re.sub(r"<!--.*?-->", "", s, flags=re.S).strip()

def read(name):
    with open(os.path.join(HERE, name), encoding="utf-8") as f:
        return f.read()

def _req(method, path):
    """Tolerant request (never exits) — used for the bulk reset."""
    req = urllib.request.Request(URL + path, method=method)
    req.add_header("Authorization", "Token " + TOK)
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode() or "{}")
    except Exception:
        return None

def wipe_all_submissions():
    """Delete EVERY submission (correct + incorrect, all accounts) -> clears all
       team scores and restores all tries. Collects ids first, then deletes."""
    ids, page = [], 1
    while page <= 10000:
        r = _req("GET", "/api/v1/submissions?per_page=100&page=%d" % page)
        data = (r or {}).get("data") or []
        ids += [s["id"] for s in data if s.get("id") is not None]
        pg = ((r or {}).get("meta") or {}).get("pagination") or {}
        if pg.get("next"):
            page = pg["next"]
        elif len(data) == 100:
            page += 1
        else:
            break
    deleted = 0
    for sid in ids:
        if _req("DELETE", "/api/v1/submissions/%d" % sid) is not None:
            deleted += 1
    return deleted

# ---- 0) one-shot RESET trigger ----------------------------------------------
#   If repo file reset.id holds a value this droplet hasn't applied yet, wipe all
#   submissions once, then record the id (outside the repo, so a git reset can't
#   un-record it). Bump reset.id in the repo to fire another reset later.
_reset_file  = os.path.join(HERE, "reset.id")
_marker_file = os.path.join(os.path.dirname(HERE), ".vt_last_reset")
if os.path.exists(_reset_file):
    _want = open(_reset_file, encoding="utf-8").read().strip()
    _have = ""
    try:
        _have = open(_marker_file, encoding="utf-8").read().strip()
    except Exception:
        pass
    if _want and _want != _have:
        _n = wipe_all_submissions()
        try:
            open(_marker_file, "w", encoding="utf-8").write(_want)
        except Exception:
            pass
        print("RESET #%s applied: deleted %d submission(s) — all scores + tries cleared (every account)" % (_want, _n))

# ---- 1) ensure the rain GIF is hosted, so the theme background resolves ------
#   The DB can list a matrix_rain.gif whose file is gone (e.g. an import that
#   restored records but not uploads). So require it to actually download;
#   otherwise upload a fresh copy. After one upload this just finds it (no re-upload).
gif_url = ""
files = api("GET", "/api/v1/files?per_page=100")
for row in (files.get("data") or []):
    loc = row.get("location") or ""
    if loc.endswith("matrix_rain.gif") and file_served(loc):
        gif_url = "/files/" + loc
        break
if not gif_url:
    new_loc = upload_gif()
    if new_loc and file_served(new_loc):
        gif_url = "/files/" + new_loc
        print("uploaded matrix_rain.gif ->", gif_url)
    else:
        print("WARNING: could not host matrix_rain.gif — background will be blank.")

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
