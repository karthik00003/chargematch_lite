"""Configuration loaded from .env (never hard-code secrets here).

.env is always read from this project folder (absolute path), so the app,
check_integrity.py and any script work no matter which directory they are
started from.
"""
import os
import sys

from dotenv import load_dotenv

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ENV_PATH = os.path.join(BASE_DIR, ".env")

if not os.path.isfile(ENV_PATH):
    sys.exit(f"No .env found at {ENV_PATH} — run ./setup_db.sh to create it.")
load_dotenv(ENV_PATH)


def _env(name, legacy=None, default=""):
    """Read MYSQL_* style names; fall back to the older DB_* names."""
    value = os.getenv(name)
    if (value is None or value == "") and legacy:
        value = os.getenv(legacy)
    return (value if value is not None else default).strip()


# The only database this project may ever use.
REQUIRED_DB = "chargematch_lite"

DB_NAME = _env("MYSQL_DB", "DB_NAME", REQUIRED_DB)
DB_USER = _env("MYSQL_USER", "DB_USER", "cmlite_app")
DB_PASSWORD = _env("MYSQL_PASSWORD", "DB_PASSWORD")
DB_SOCKET = _env("MYSQL_SOCKET", "DB_SOCKET")
DB_HOST = _env("MYSQL_HOST", "DB_HOST", "127.0.0.1")
DB_PORT = int(_env("MYSQL_PORT", "DB_PORT", "3306"))

APP_PORT = int(_env("PORT", "APP_PORT", "5060"))
SECRET_KEY = _env("SECRET_KEY")

PLACEHOLDERS = {"", "change_me", "change_me_letters_digits_only"}

if DB_NAME != REQUIRED_DB:
    sys.exit(f"Refusing to start: MYSQL_DB must be '{REQUIRED_DB}', got '{DB_NAME}'.")
if DB_USER == "root":
    sys.exit("Refusing to start: the app must connect as cmlite_app, never as root.")
if SECRET_KEY in PLACEHOLDERS:
    sys.exit(f"SECRET_KEY missing in {ENV_PATH} — run ./setup_db.sh to generate it.")
if DB_PASSWORD in PLACEHOLDERS:
    sys.exit(f"MYSQL_PASSWORD missing in {ENV_PATH} — run ./setup_db.sh to generate it.")
if APP_PORT == 5050:
    sys.exit("Port 5050 is reserved for another project; choose another PORT in .env.")
