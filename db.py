"""Tiny data-access helpers around PyMySQL.

Every query uses %s placeholders — values are sent separately from the SQL
text, so user input can never change the query (no SQL injection).
"""
import re

import pymysql
from pymysql.cursors import DictCursor

import config


def connect():
    """Open a new connection as the least-privilege app user."""
    kwargs = dict(
        user=config.DB_USER,
        password=config.DB_PASSWORD,
        database=config.DB_NAME,
        charset="utf8mb4",
        cursorclass=DictCursor,
        autocommit=True,       # stored procedures manage their own transactions
    )
    if config.DB_SOCKET:
        kwargs["unix_socket"] = config.DB_SOCKET
    else:
        kwargs.update(host=config.DB_HOST, port=config.DB_PORT)
    return pymysql.connect(**kwargs)


# ---- Flask per-request connection ------------------------------------------
def get_conn():
    from flask import g
    if "db" not in g:
        g.db = connect()
    return g.db


def close_conn(_exc=None):
    from flask import g
    conn = g.pop("db", None)
    if conn is not None:
        conn.close()


def query(sql, args=None, one=False, conn=None):
    """Run a SELECT and return a list of dicts (or one dict / None)."""
    conn = conn or get_conn()
    with conn.cursor() as cur:
        cur.execute(sql, args)
        rows = cur.fetchall()
    return (rows[0] if rows else None) if one else rows


def execute(sql, args=None, conn=None):
    """Run INSERT/UPDATE/DELETE; returns (rowcount, lastrowid)."""
    conn = conn or get_conn()
    with conn.cursor() as cur:
        cur.execute(sql, args)
        return cur.rowcount, cur.lastrowid


def call(proc, *args, conn=None):
    """CALL a stored procedure with parameters."""
    conn = conn or get_conn()
    placeholders = ", ".join(["%s"] * len(args))
    with conn.cursor() as cur:
        cur.execute(f"CALL {proc}({placeholders})", args)   # proc names are fixed in code


# ---- Turning MySQL errors into friendly text -------------------------------
CHECK_MESSAGES = {
    "chk_users_email": "Please enter a valid email address.",
    "chk_listing_lat": "Latitude must be between -90 and 90.",
    "chk_listing_lng": "Longitude must be between -180 and 180.",
    "chk_listing_hours": "Opening time must be before closing time.",
    "chk_charger_setup": ("This connector can't have that power or parking bay: Type 2 3.3 / 7.4 / 11 / 22 kW, "
                          "15A socket 2.2 / 3.3 kW, Bharat AC-001 3.3 kW, LECCS 1.5 / 3.0 kW on a 2W / 3W bay "
                          "(home chargers are AC only)."),
    "chk_charger_price": "Price must be between ₹5 and ₹30 per kWh.",
    "chk_charger_label": "The charger label needs at least 3 characters.",
    "chk_model_battery": "Battery size must be greater than 0.",
    "chk_vehicle_reg": "Registration number must look like KA19MN1234 (state, district, series, 4 digits).",
    "chk_booking_order": "End time must be after start time.",
    "chk_booking_duration": "A booking must be between 15 minutes and 12 hours long.",
    "chk_session_start": "Start battery % must be between 0 and 100.",
    "chk_session_end": "End battery % must be more than start % and at most 100.",
}

DUPLICATE_MESSAGES = {
    "uq_users_email": "An account with this email already exists.",
    "uq_vehicle_reg": "This registration number is already registered.",
    "uq_charger_label": "This listing already has a charger with that label.",
    "uq_make_model": "That vehicle model already exists.",
}


def friendly_error(exc):
    """Convert a PyMySQL exception into a sentence for the user."""
    code = exc.args[0] if exc.args else None
    msg = str(exc.args[1]) if len(exc.args) > 1 else str(exc)
    if code == 1644:                       # SIGNAL SQLSTATE '45000' from our triggers/procedures
        return msg
    if code == 3819:                       # CHECK constraint violated
        m = re.search(r"'([^']+)'", msg)
        return CHECK_MESSAGES.get(m.group(1) if m else "", "A value is outside the allowed range.")
    if code == 1062:                       # duplicate key
        for key, text in DUPLICATE_MESSAGES.items():
            if key in msg:
                return text
        return "That value already exists."
    if code in (1451, 1452):               # foreign key
        return "This record is linked to other data and cannot be changed that way."
    if code in (1292, 1366):
        return "One of the values has the wrong format."
    return f"Database error: {msg}"
