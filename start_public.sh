#!/usr/bin/env bash
# =====================================================================
#  Share ChargeMatch Lite with friends for a while:   ./start_public.sh
#  Starts the app on 127.0.0.1:<PORT from .env> and a free Cloudflare quick tunnel to it, then prints the public
#  https link. Ctrl+C stops both (the link stops working).
#
#  The app still listens on 127.0.0.1 only, so the tunnel is the only way in from outside. It runs under waitress
#  (never Flask debug mode); visitors see a plain error page, never a traceback. Over the https link the login
#  cookie is marked Secure (ProxyFix reads the tunnel's X-Forwarded-Proto).
# =====================================================================
set -uo pipefail
cd "$(dirname "$0")" || exit 1
PY=".venv/bin/python"
LOGS="logs"
APP_LOG="$LOGS/public_app.log"
TUNNEL_LOG="$LOGS/public_tunnel.log"
APP_PID=""
TUNNEL_PID=""

say()  { printf '%s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---- 1. preflight checks --------------------------------------------------
[[ -x "$PY" ]]  || fail "No virtualenv in .venv. Create it: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
[[ -f .env ]]   || fail "No .env file. Run ./setup_db.sh first (it keeps existing data)."
"$PY" -c "import flask, pymysql, dotenv, waitress" 2>/dev/null \
    || fail "Python packages missing. Run: .venv/bin/pip install -r requirements.txt"
command -v cloudflared >/dev/null 2>&1 \
    || fail "cloudflared is not installed. Install it with:  brew install cloudflared"
if [[ -f "$HOME/.cloudflared/config.yml" || -f "$HOME/.cloudflared/config.yaml" ]]; then
    fail "~/.cloudflared/config.yml exists; quick tunnels don't work with it. Rename it while sharing."
fi

# PORT: from .env (an exported PORT=… overrides it, like app.py)
if [[ -z "${PORT:-}" ]]; then
    PORT="$(grep -E '^PORT=' .env | tail -1 | cut -d= -f2)"
fi
PORT="${PORT:-5060}"
[[ "$PORT" =~ ^[0-9]+$ ]] || fail "PORT in .env is not a number: '$PORT'"
[[ "$PORT" != "5050" ]]   || fail "Port 5050 is reserved for another project. Pick another PORT in .env."
export PORT

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    say "Port $PORT is already in use by:" >&2
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN | sed 's/^/    /' >&2
    fail "Stop it first (Ctrl+C in its terminal, or: kill $(lsof -tnP -iTCP:"$PORT" -sTCP:LISTEN | head -1)), then run ./start_public.sh again."
fi
mkdir -p "$LOGS"

# ---- 2. start + stop ------------------------------------------------------
cleanup() {                 # $1 = exit code (0 for Ctrl+C), else the script's own
    local rc=${1:-$?}
    trap - INT TERM EXIT
    say ""
    say "Stopping…"
    [[ -n "$TUNNEL_PID" ]] && kill "$TUNNEL_PID" 2>/dev/null
    [[ -n "$APP_PID" ]]    && kill "$APP_PID" 2>/dev/null
    wait 2>/dev/null
    say "Tunnel closed and app stopped. The public link no longer works."
    exit "$rc"
}
trap 'cleanup 0' INT TERM
trap cleanup EXIT

say "Starting ChargeMatch Lite on http://127.0.0.1:$PORT (log: $APP_LOG)…"
FLASK_DEBUG=0 "$PY" app.py >"$APP_LOG" 2>&1 &
APP_PID=$!
for _ in $(seq 1 40); do
    curl -fsS -o /dev/null "http://127.0.0.1:$PORT/login" 2>/dev/null && break
    kill -0 "$APP_PID" 2>/dev/null || { tail -20 "$APP_LOG"; fail "The app failed to start (see $APP_LOG)."; }
    sleep 0.5
done
curl -fsS -o /dev/null "http://127.0.0.1:$PORT/login" || fail "The app didn't answer on port $PORT (see $APP_LOG)."

say "Opening a Cloudflare quick tunnel (log: $TUNNEL_LOG)…"
cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:$PORT" >"$TUNNEL_LOG" 2>&1 &
TUNNEL_PID=$!
URL=""
for _ in $(seq 1 60); do
    # the log also mentions https://api.trycloudflare.com (where cloudflared asks for a link): skip it
    URL=$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" | grep -v '^https://api\.' | head -1)
    [[ -n "$URL" ]] && break
    kill -0 "$TUNNEL_PID" 2>/dev/null || { tail -20 "$TUNNEL_LOG"; fail "cloudflared exited (see $TUNNEL_LOG)."; }
    sleep 0.5
done
[[ -n "$URL" ]] || fail "No tunnel link after 30 s. Check the internet connection and $TUNNEL_LOG."

# A new link takes a few seconds to appear in DNS: wait until it really answers. Ask 1.1.1.1 directly (dig) and pin
# that address for curl: asking this Mac's resolver too early makes it cache "no such host" for a while, and then
# the link would not open in the browser on this laptop.
HOST="${URL#https://}"
READY=""
for _ in $(seq 1 40); do
    IP=""
    command -v dig >/dev/null 2>&1 && IP=$(dig +short +time=2 +tries=1 @1.1.1.1 "$HOST" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
    if [[ -n "$IP" ]] && curl -fsS -o /dev/null --max-time 5 --resolve "$HOST:443:$IP" "$URL/login" 2>/dev/null; then
        READY=1; break
    fi
    sleep 1.5
done
[[ -n "$READY" ]] || say "Note: the link doesn't answer from this laptop yet (new links can take a minute to reach DNS). Try it on your phone."

cat <<EOF

  ==================================================================
    Share this link: $URL
  ==================================================================
   It changes every time you restart. Keep this window open and the
   laptop awake. Press Ctrl+C to stop sharing.

EOF

# Stay here until Ctrl+C, or until one of the two processes dies. "sleep & wait" (not a plain sleep): Ctrl+C
# interrupts the wait at once, so the trap runs before this loop could see cloudflared (which gets Ctrl+C too) gone.
while kill -0 "$APP_PID" 2>/dev/null && kill -0 "$TUNNEL_PID" 2>/dev/null; do
    sleep 1 & wait $!
done
kill -0 "$APP_PID" 2>/dev/null    || { say "The app stopped unexpectedly. Last lines of $APP_LOG:"; tail -5 "$APP_LOG"; }
kill -0 "$TUNNEL_PID" 2>/dev/null || { say "The tunnel stopped unexpectedly. Last lines of $TUNNEL_LOG:"; tail -5 "$TUNNEL_LOG"; }
exit 1   # the EXIT trap stops whatever is still running
