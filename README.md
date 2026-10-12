# VirusTotal CTF — live deploy kit

Pulled by the droplet's auto-updater (`/opt/ctfd-updater`). When this repo
changes, the droplet runs `apply.py`, which pushes the theme, landing page,
and challenge ordering to the LIVE CTFd via its admin API — without touching
users, teams, challenges, submissions, or scores.

Files:
- `theme_header_matrix_gif.html` — the Matrix theme (CSS + JS).
- `landing_matrix.html` — the index/landing page.
- `apply.py` — applies the two files above to the live site (stdlib only).
- `pull-and-apply.sh` — cron entrypoint: `git pull` then `apply.py` on change.

Secrets (CTFd URL + admin token) live in `/opt/ctfd-updater/updater.env`
on the droplet and are NEVER committed here.
