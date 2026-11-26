#!/usr/bin/env bash
# =====================================================================
#  Start ChargeMatch Lite in the FOREGROUND:   ./run.sh
#  Serves http://127.0.0.1:<PORT from .env, default 5060> until Ctrl+C.
#  Nothing is put in the background; closing this terminal stops the app.
# =====================================================================
set -uo pipefail
cd "$(dirname "$0")" || exit 1
PROJECT="$(pwd)"
PY="$PROJECT/.venv/bin/python"

fail() { echo "ERROR: $*" >&2; exit 1; }

# ---- 1. preflight checks (each with a clear message) --------------------
[[ -x "$PY" ]]   || fail "No virtualenv at $PROJECT/.venv — create it:
    python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
[[ -f .env ]]    || fail "No .env in $PROJECT — run ./setup_db.sh (keeps existing data)."

"$PY" -c "import flask, pymysql, dotenv, werkzeug" 2>/dev/null \
    || fail "Python packages missing in .venv — run: .venv/bin/pip install -r requirements.txt"

PORT="$(grep -E '^PORT=' .env | tail -1 | cut -d= -f2)"
[[ -n "$PORT" ]] || PORT="$(grep -E '^APP_PORT=' .env | tail -1 | cut -d= -f2)"   # older name
PORT="${PORT:-5060}"
[[ "$PORT" =~ ^[0-9]+$ ]] || fail "PORT in .env is not a number: '$PORT'"
[[ "$PORT" != "5050" ]]   || fail "PORT 5050 is reserved for another project. Pick another port in .env."

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Port $PORT is already in use by:" >&2
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN | sed 's/^/    /' >&2
    fail "Stop that process first (if it is an old ChargeMatch Lite: kill <PID>), then run ./run.sh again."
fi

# ---- 2. run the server in the foreground --------------------------------
# app.py checks .env + the MySQL login, binds 127.0.0.1:$PORT, prints
# "ChargeMatch Lite running at ... — press Ctrl+C to stop" and blocks.
"$PY" app.py
rc=$?

# ---- 3. say clearly why it stopped --------------------------------------
case $rc in
    0|130) ;;                                                   # Ctrl+C: normal stop
    *) echo "ChargeMatch Lite exited unexpectedly (exit code $rc). See the messages above." >&2 ;;
esac
exit $rc
