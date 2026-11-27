"""ChargeMatch Lite — Flask web app (served by waitress, like the original ChargeMatch).

Run with ./run.sh  (or: .venv/bin/python app.py)
All business rules live in the database (triggers / procedures / CHECKs); this file
runs parameterised SQL and shows the results. The look (static/style.css, app.js)
is copied from the original ChargeMatch project.
"""
import logging
import re
import secrets
import socket
import sys
import threading
import time as clock
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from functools import wraps

import pymysql
import requests
from flask import (Flask, abort, flash, g, jsonify, redirect, render_template, request,
                   session, url_for)
from flask.sessions import SecureCookieSessionInterface
from markupsafe import Markup
from werkzeug.exceptions import HTTPException
from werkzeug.middleware.proxy_fix import ProxyFix
from werkzeug.security import check_password_hash, generate_password_hash

import config
import db

app = Flask(__name__)
app.secret_key = config.SECRET_KEY              # from .env only (config.py stops if it is missing); never generated here
# Cookies belong to the host, not the port: the original ChargeMatch on 127.0.0.1:5050 also uses Flask's default
# cookie name "session", so the two apps overwrote each other's login. Lite gets its own name. The CSRF token lives
# inside this session cookie, and there is no remember-me cookie, so this is the app's only cookie.
app.config.update(
    SESSION_COOKIE_NAME="cmlite_session",
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    PERMANENT_SESSION_LIFETIME=timedelta(hours=8),   # a login lasts 8 hours (renewed on every request)
    SESSION_REFRESH_EACH_REQUEST=True,
    DEBUG=False,                                     # never the Werkzeug debugger / tracebacks, also not when shared
    PROPAGATE_EXCEPTIONS=False,
)


class SessionCookie(SecureCookieSessionInterface):
    """The login cookie is marked Secure only when the page came over https (the Cloudflare tunnel of
    start_public.sh). Plain http://127.0.0.1 (./run.sh) keeps working, because a Secure cookie is not sent there."""
    def get_cookie_secure(self, app):
        return request.is_secure


app.session_interface = SessionCookie()
# The tunnel forwards https://….trycloudflare.com to http://127.0.0.1:PORT and adds X-Forwarded-Proto / -Host /
# -For. ProxyFix trusts one such hop, so request.is_secure, url_for and redirects see the public https address.
# The app only listens on 127.0.0.1, so nothing else can send these headers.
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)
app.teardown_appcontext(db.close_conn)

DEFAULT_CENTER = (12.8700, 74.8430)          # Mangaluru
REJECT_MIN = 5                               # characters in a rejection reason

# Lite stores an emoji in amenity.icon; the original theme uses Lucide icon names.
# Presentation-only mapping (the data is not changed).
AMENITY_ICONS = {"Covered parking": "umbrella", "Restroom": "toilet", "Wi-Fi": "wifi",
                 "Café nearby": "coffee", "CCTV": "cctv", "Waiting lounge": "armchair",
                 "Drinking water": "glass-water", "Seating area": "sofa", "Shade / tree cover": "trees",
                 "Night lighting": "lightbulb", "Wheelchair accessible": "accessibility", "Tyre air pump": "gauge",
                 "Pet friendly": "paw-print", "Security guard": "shield-user", "Two-wheeler parking": "bike",
                 "Phone charging point": "smartphone-charging"}

# One status word per charger for the UI (approval + physical status). 'occupied' is kept in step with charging
# sessions by trg_booking_au, so it means "in use". The same CASE is in v_searchable_chargers.
CHARGER_STATUS_SQL = """CASE WHEN c.approval = 'PENDING'  THEN 'pending'
                             WHEN c.approval = 'REJECTED' THEN 'rejected'
                             WHEN c.status = 'out_of_service' THEN 'out_of_service'
                             WHEN c.status = 'occupied'   THEN 'in_use'
                             ELSE 'available' END"""

# status word -> the original's live-badge class + label
LIVE = {"available": ("available", "Available"), "in_use": ("in_use", "In use"),
        "out_of_service": ("offline", "Out of service"),
        "pending": ("awaiting_approval", "Awaiting approval"), "rejected": ("rejected", "Rejected")}

OPEN_TIMES = [f"{h:02d}:{m:02d}" for h in range(24) for m in (0, 15, 30, 45)]
CLOSE_TIMES = OPEN_TIMES[1:] + ["23:59"]


# =====================================================================
# Helpers: current user, CSRF, role guard, errors, formatting
# =====================================================================
@app.before_request
def load_user_and_check_csrf():
    g.user = None
    uid = session.get("uid")
    if uid:
        g.user = db.query("SELECT user_id, name, email, role, status FROM users WHERE user_id = %s",
                          (uid,), one=True)
        if not g.user or g.user["status"] != "ACTIVE":
            session.clear()
            g.user = None
            flash("Your account is disabled or no longer exists.", "error")
    if request.method == "POST":
        expected = session.get("csrf")
        if not expected or request.form.get("csrf_token") != expected:
            abort(400, "Form expired — please go back, reload the page and try again.")


def csrf_field():
    if "csrf" not in session:
        session["csrf"] = secrets.token_hex(16)
    return Markup(f'<input type="hidden" name="csrf_token" value="{session["csrf"]}">')


@app.context_processor
def inject_globals():
    csrf_field()                                  # make sure a token exists
    return {"csrf_field": csrf_field, "csrf_token": session["csrf"], "user": g.get("user"),
            "today": date.today(), "open_text": open_text, "LIVE": LIVE,
            "OPEN_TIMES": OPEN_TIMES, "CLOSE_TIMES": CLOSE_TIMES}


def role_required(*roles):
    def deco(view):
        @wraps(view)
        def wrapper(*a, **kw):
            if not g.user:
                flash("Please log in first.", "error")
                return redirect(url_for("login", next=request.path))
            if g.user["role"] not in roles:
                abort(403)
            return view(*a, **kw)
        return wrapper
    return deco


@app.errorhandler(pymysql.MySQLError)
def show_db_error(exc):
    """Any trigger SIGNAL / CHECK / FK error ends up here as a friendly message."""
    flash(db.friendly_error(exc), "error")
    return redirect(request.referrer or url_for("index"))


@app.errorhandler(400)
@app.errorhandler(403)
@app.errorhandler(404)
def http_error(err):
    titles = {400: "Bad request", 403: "Not allowed", 404: "Not found"}
    msgs = {403: "Your account role cannot open this page.",
            404: "That page or record does not exist (or isn't yours)."}
    return render_template("error.html", code=err.code, title=titles.get(err.code, "Error"),
                           message=msgs.get(err.code, err.description)), err.code


@app.errorhandler(Exception)
def server_error(exc):
    """Unexpected errors: a plain page for the visitor, the traceback only in this terminal / log."""
    if isinstance(exc, HTTPException):
        return http_error(exc) if exc.code in (400, 403, 404) else exc
    app.logger.exception("Unhandled error on %s %s", request.method, request.path)
    return render_template("error.html", code=500, title="Something went wrong",
                           message="The page could not be shown. Please try again."), 500


def as_time(value):
    """TIME columns come back as timedelta."""
    if isinstance(value, timedelta):
        secs = int(value.total_seconds())
        return time(secs // 3600, (secs % 3600) // 60)
    return value


@app.template_filter("hm")
def fmt_hm(value):
    t = as_time(value)
    return t.strftime("%H:%M") if t else ""


@app.template_filter("dt")
def fmt_dt(value):
    return value.strftime("%d %b %Y, %H:%M") if value else ""


@app.template_filter("inr")
def fmt_inr(value):
    return f"₹{float(value or 0):,.2f}"


def is_24h(open_t, close_t):
    o, c = as_time(open_t), as_time(close_t)
    return o == time(0, 0) and c >= time(23, 59)


def open_text(open_t, close_t):
    if is_24h(open_t, close_t):
        return "Open 24 hours"
    return f"Open {fmt_hm(open_t)}–{fmt_hm(close_t)}"


def open_now(open_t, close_t):
    now = datetime.now().time()
    return is_24h(open_t, close_t) or as_time(open_t) <= now < as_time(close_t)


def fmt_duration(mins):
    mins = int(mins)
    return f"{mins // 60} h {mins % 60} min" if mins >= 60 and mins % 60 else (f"{mins // 60} h" if mins >= 60 else f"{mins} min")


# Globals (not context-processor values) so that imported macros can use them too.
app.jinja_env.globals.update(fmt_duration=fmt_duration, csrf_field=csrf_field, LIVE=LIVE, open_text=open_text,
                             OPEN_TIMES=OPEN_TIMES, CLOSE_TIMES=CLOSE_TIMES, REJECT_MIN=REJECT_MIN)


def amenity_rows():
    rows = db.query("SELECT amenity_id, name FROM amenity ORDER BY name")
    for a in rows:
        a["icon"] = AMENITY_ICONS.get(a["name"], "sparkles")
    return rows


def listing_amenities(listing_ids):
    """{listing_id: [{amenity_id, name, icon, note}]}"""
    out = {lid: [] for lid in listing_ids}
    if not listing_ids:
        return out
    marks = ", ".join(["%s"] * len(listing_ids))
    for r in db.query(f"""SELECT la.listing_id, a.amenity_id, a.name, la.note FROM listing_amenity la
                            JOIN amenity a ON a.amenity_id = la.amenity_id
                           WHERE la.listing_id IN ({marks}) ORDER BY a.name""", tuple(listing_ids)):
        out[r["listing_id"]].append({"amenity_id": r["amenity_id"], "name": r["name"], "note": r["note"],
                                     "icon": AMENITY_ICONS.get(r["name"], "sparkles")})
    return out


def best_live(statuses):
    """Map colour of a listing = best status of its chargers."""
    for s in ("available", "in_use"):
        if s in statuses:
            return s
    return "offline"


def safe_back(default):
    back = request.form.get("back", "")
    return back if back.startswith("/") and not back.startswith("//") else default


# =====================================================================
# Auth
# =====================================================================
@app.route("/")
def index():
    if not g.user:
        return render_template("home.html")          # public landing page

    return redirect(url_for({"ADMIN": "admin_dashboard", "HOST": "host_dashboard",
                             "CUSTOMER": "customer_search"}[g.user["role"]]))


@app.route("/login", methods=["GET", "POST"])
def login():
    if g.user:
        return redirect(url_for("index"))
    email = ""
    if request.method == "POST":
        email = request.form.get("email", "").strip().lower()
        u = db.query("SELECT * FROM users WHERE email = %s", (email,), one=True)
        if not u or not check_password_hash(u["password_hash"], request.form.get("password", "")):
            flash("Wrong email or password.", "error")
        elif u["status"] != "ACTIVE":
            flash("This account has been disabled by the admin.", "error")
        else:
            session.clear()
            session["uid"] = u["user_id"]
            session.permanent = True                 # survives a browser restart; 8 h lifetime
            flash(f"Welcome back, {u['name']}!", "ok")
            nxt = request.args.get("next", "")
            return redirect(nxt if nxt.startswith("/") and not nxt.startswith("//") else url_for("index"))
    return render_template("login.html", email=email)


@app.route("/register", methods=["GET", "POST"])
def register():
    form = request.form
    if request.method == "POST":
        role, pw = form.get("role"), form.get("password", "")
        if role not in ("HOST", "CUSTOMER"):
            flash("Choose host or customer.", "error")
        elif len(pw) < 6:
            flash("Password must be at least 6 characters.", "error")
        elif pw != form.get("confirm", ""):
            flash("Passwords do not match.", "error")
        else:
            try:
                _, uid = db.execute(
                    "INSERT INTO users (name, email, password_hash, role) VALUES (%s, %s, %s, %s)",
                    (form.get("name", "").strip(), form.get("email", "").strip().lower(),
                     generate_password_hash(pw), role))
                session.clear()
                session["uid"] = uid
                session.permanent = True                 # survives a browser restart; 8 h lifetime
                flash("Account created. Welcome!", "ok")
                return redirect(url_for("customer_vehicles" if role == "CUSTOMER" else "host_listing_new"))
            except pymysql.MySQLError as e:
                flash(db.friendly_error(e), "error")
    return render_template("register.html", form=form)


@app.route("/logout", methods=["POST"])
def logout():
    session.clear()
    flash("Logged out.", "ok")
    return redirect(url_for("login"))


# =====================================================================
# Customer
# =====================================================================
def my_vehicles(uid):
    return db.query("""
        SELECT v.vehicle_id, v.reg_no, m.model_id, m.make, m.model_name, m.vehicle_class, m.battery_kwh,
               GROUP_CONCAT(ct.code ORDER BY ct.code SEPARATOR ', ') AS connectors,
               (SELECT COUNT(*) FROM booking b WHERE b.vehicle_id = v.vehicle_id) AS num_bookings
          FROM vehicle v
          JOIN vehicle_model m ON m.model_id = v.model_id
          LEFT JOIN model_connector mc ON mc.model_id = m.model_id
          LEFT JOIN connector_type ct ON ct.connector_id = mc.connector_id
         WHERE v.user_id = %s
         GROUP BY v.vehicle_id, v.reg_no, m.model_id, m.make, m.model_name, m.vehicle_class, m.battery_kwh
         ORDER BY v.vehicle_id""", (uid,))


@app.route("/customer")
@role_required("CUSTOMER")
def customer_search():
    uid = g.user["user_id"]
    vehicles = my_vehicles(uid)
    selected = request.args.get("vehicle", type=int) or (vehicles[0]["vehicle_id"] if vehicles else None)
    return render_template("customer_search.html", vehicles=vehicles, selected=selected,
                           amenities=amenity_rows(), center=DEFAULT_CENTER)


@app.route("/api/nearby")
@role_required("CUSTOMER")
def api_nearby():
    """Listings near a point for the Find chargers map (JSON). Data from v_searchable_chargers and
    fn_compat_reason; nothing here writes."""
    uid = g.user["user_id"]
    lat, lng = request.args.get("lat", type=float), request.args.get("lng", type=float)
    radius = request.args.get("radius", type=float)
    if lat is None or lng is None or not (-90 <= lat <= 90 and -180 <= lng <= 180):
        return jsonify(error="Choose a search point on the map."), 400
    if radius is None or not 1 <= radius <= 50:
        return jsonify(error="Radius must be between 1 and 50 km."), 400
    vid = request.args.get("vehicle_id", type=int)
    if vid and not db.query("SELECT 1 FROM vehicle WHERE vehicle_id = %s AND user_id = %s", (vid, uid), one=True):
        return jsonify(error="That vehicle isn't yours."), 403
    only_compat = request.args.get("only_compatible") == "1" and vid
    wanted = {int(x) for x in request.args.get("amenities", "").split(",") if x.strip().isdigit()}

    rows = db.query("""
        SELECT s.*,
               ROUND(ST_Distance_Sphere(POINT(s.longitude, s.latitude), POINT(%s, %s)) / 1000, 1) AS km,
               IF(%s IS NULL, NULL, fn_compat_reason(s.charger_id, %s)) AS reason
          FROM v_searchable_chargers s
         WHERE ST_Distance_Sphere(POINT(s.longitude, s.latitude), POINT(%s, %s)) <= %s
         ORDER BY km, s.listing_id, s.label""", (lng, lat, vid, vid, lng, lat, radius * 1000))
    listings = {}
    for r in rows:
        st = listings.get(r["listing_id"])
        if not st:
            st = listings[r["listing_id"]] = {
                "listing_id": r["listing_id"], "name": r["listing_name"], "address": r["address"], "city": r["city"],
                "lat": float(r["latitude"]), "lng": float(r["longitude"]), "distance_km": float(r["km"]),
                "hours": f"{fmt_hm(r['open_time'])}–{fmt_hm(r['close_time'])}",
                "hours_label": open_text(r["open_time"], r["close_time"]),
                "open_now": open_now(r["open_time"], r["close_time"]), "host": r["host_name"], "chargers": [],
                "details_url": url_for("listing_details", listing_id=r["listing_id"], vehicle=vid)}
        compatible = bool(vid) and r["reason"] is None
        st["chargers"].append({
            "charger_id": r["charger_id"], "label": r["label"], "connector": r["connector_code"],
            "current_type": r["current_type"], "power_kw": float(r["power_kw"]), "price": float(r["price_per_kwh"]),
            "bay": r["parking_size"],
            "cstatus": LIVE[r["live_status"]][0], "status": r["live_status"],
            "compatible": compatible, "reason": r["reason"]})
    amen = listing_amenities(list(listings))
    out = []
    for lid, st in listings.items():
        st["amenities"] = amen[lid]
        if wanted and not wanted <= {a["amenity_id"] for a in st["amenities"]}:
            continue
        usable = [c for c in st["chargers"] if c["compatible"] and c["status"] in ("available", "in_use")]
        st["any_compatible"] = bool(usable)
        if only_compat:
            st["chargers"] = [c for c in st["chargers"] if c["compatible"]]
            if not usable:
                continue
        st["live"] = best_live({c["status"] for c in (usable or st["chargers"])})
        out.append(st)
    return jsonify(out)


@app.route("/customer/book", methods=["POST"])
@role_required("CUSTOMER")
def customer_book():
    uid, f = g.user["user_id"], request.form
    try:
        start = datetime.strptime(f.get("start_time", ""), "%Y-%m-%dT%H:%M")
        end = datetime.strptime(f.get("end_time", ""), "%Y-%m-%dT%H:%M")
    except ValueError:
        flash("Choose a start and an end time.", "error")
        return redirect(url_for("customer_search"))
    try:
        _, bid = db.execute(
            """INSERT INTO booking (customer_id, vehicle_id, charger_id, start_time, end_time)
               VALUES (%s, %s, %s, %s, %s)""",
            (uid, f.get("vehicle_id", type=int), f.get("charger_id", type=int), start, end))
    except pymysql.MySQLError as e:
        flash(db.friendly_error(e), "error")            # e.g. the trigger's SIGNAL text
        return redirect(url_for("customer_search", vehicle=f.get("vehicle_id", type=int)))
    flash(f"Request sent: {booking_title(bid)}. The host will accept or decline it.", "ok")
    return redirect(url_for("customer_bookings", tab="upcoming", highlight=bid, _anchor=f"b-{bid}"))


@app.route("/listing/<int:listing_id>")
@role_required("CUSTOMER", "HOST", "ADMIN")
def listing_details(listing_id):
    st = db.query("""SELECT l.*, u.name AS host_name, u.status AS host_status
                       FROM listing l JOIN users u ON u.user_id = l.host_id
                      WHERE l.listing_id = %s""", (listing_id,), one=True)
    if not st:
        abort(404)
    public = bool(db.query("SELECT 1 FROM v_searchable_chargers WHERE listing_id = %s LIMIT 1", (listing_id,), one=True))
    role = g.user["role"]
    if role == "CUSTOMER" and not public or role == "HOST" and st["host_id"] != g.user["user_id"] and not public:
        abort(404)
    vehicles = my_vehicles(g.user["user_id"]) if role == "CUSTOMER" else []
    vid = request.args.get("vehicle", type=int)
    if vehicles and vid not in [v["vehicle_id"] for v in vehicles]:
        vid = vehicles[0]["vehicle_id"]
    show_all = role != "CUSTOMER"
    chargers = db.query(f"""
        SELECT c.*, ct.code AS connector, ct.current_type, {CHARGER_STATUS_SQL} AS live_status,
               {'fn_compat_reason(c.charger_id, %s)' if vid else 'NULL'} AS reason
          FROM charger c JOIN connector_type ct ON ct.connector_id = c.connector_id
         WHERE c.listing_id = %s {'' if show_all else "AND c.approval = 'APPROVED' AND c.status <> 'out_of_service'"}
         ORDER BY c.label""", ((vid, listing_id) if vid else (listing_id,)))
    return render_template("listing_details.html", st=st, public=public, chargers=chargers,
                           amenities=listing_amenities([listing_id])[listing_id], vehicles=vehicles,
                           vehicle_id=vid, open_now=open_now(st["open_time"], st["close_time"]))


@app.route("/customer/bookings")
@role_required("CUSTOMER")
def customer_bookings():
    rows = db.query("""
        SELECT b.*, c.label AS charger_label, c.power_kw, ct.code AS connector, ct.current_type,
               l.name AS listing_name, l.city, l.listing_id, l.latitude, l.longitude,
               v.reg_no, m.make, m.model_name,
               s.start_pct, s.end_pct, s.battery_kwh AS session_battery_kwh, s.started_at,
               bl.bill_id, bl.kwh AS bill_kwh, bl.rate AS bill_rate, bl.amount, bl.status AS bill_status, bl.paid_at
          FROM booking b
          JOIN charger c ON c.charger_id = b.charger_id
          JOIN connector_type ct ON ct.connector_id = c.connector_id
          JOIN listing l ON l.listing_id = c.listing_id
          JOIN vehicle v ON v.vehicle_id = b.vehicle_id
          JOIN vehicle_model m ON m.model_id = v.model_id
          LEFT JOIN charging_session s ON s.booking_id = b.booking_id
          LEFT JOIN bill bl ON bl.booking_id = b.booking_id
         WHERE b.customer_id = %s""", (g.user["user_id"],))

    def tab_of(b):
        if b["status"] in ("requested", "accepted"):
            return "upcoming"
        if b["status"] == "charging" or b["bill_status"] == "PAYMENT_PENDING":
            return "active"
        return "past"
    counts = {"upcoming": 0, "active": 0, "past": 0}
    for b in rows:
        b["tab"] = tab_of(b)
        counts[b["tab"]] += 1
    tab = request.args.get("tab") or ("active" if counts["active"] else "upcoming" if counts["upcoming"] else "past")
    if tab not in counts:
        tab = "upcoming"
    shown = sorted([b for b in rows if b["tab"] == tab], key=lambda b: b["start_time"], reverse=(tab != "upcoming"))
    return render_template("customer_bookings.html", bookings=shown, counts=counts, tab=tab, now=datetime.now(),
                           highlight=request.args.get("highlight", type=int))


@app.route("/customer/bookings/<int:bid>/cancel", methods=["POST"])
@role_required("CUSTOMER")
def customer_cancel(bid):
    cur = db.query("SELECT status FROM booking WHERE booking_id = %s AND customer_id = %s",
                   (bid, g.user["user_id"]), one=True)
    if not cur:
        abort(404)
    if cur["status"] in ("cancelled", "declined"):
        flash(f"{booking_title(bid)} is already {cur['status']}.", "error")
    else:
        # Any illegal move (e.g. charging -> cancelled) is refused by trg_booking_bu.
        db.execute("UPDATE booking SET status = 'cancelled', cancel_reason = 'Cancelled by customer' "
                   "WHERE booking_id = %s AND customer_id = %s", (bid, g.user["user_id"]))
        flash(f"Cancelled: {booking_title(bid)}.", "ok")
    return redirect(url_for("customer_bookings", tab="past", _anchor=f"b-{bid}"))


@app.route("/customer/vehicles", methods=["GET", "POST"])
@role_required("CUSTOMER")
def customer_vehicles():
    uid = g.user["user_id"]
    form = request.form
    if request.method == "POST":
        reg = form.get("reg_no", "").upper().replace(" ", "").replace("-", "")
        try:
            _, vid = db.execute("INSERT INTO vehicle (user_id, model_id, reg_no) VALUES (%s, %s, %s)",
                                (uid, form.get("model_id", type=int), reg))
            flash(f"Vehicle {reg} added.", "ok")
            return redirect(url_for("customer_vehicles", highlight=vid, _anchor=f"v-{vid}"))
        except pymysql.MySQLError as e:
            flash(db.friendly_error(e), "error")
    models = db.query("""
        SELECT m.model_id, m.make, m.model_name, m.vehicle_class, m.battery_kwh,
               GROUP_CONCAT(ct.code ORDER BY ct.code SEPARATOR ', ') AS connectors
          FROM vehicle_model m
          LEFT JOIN model_connector mc ON mc.model_id = m.model_id
          LEFT JOIN connector_type ct ON ct.connector_id = mc.connector_id
         GROUP BY m.model_id, m.make, m.model_name, m.vehicle_class, m.battery_kwh
         ORDER BY m.make, m.model_name""")
    classes = {"2W": "2-wheeler", "3W": "3-wheeler", "4W": "4-wheeler"}      # same labels as the original
    form_class = form.get("vehicle_class") or ""
    return render_template("customer_vehicles.html", vehicles=my_vehicles(uid), models=models, form=form,
                           vehicle_classes=classes, form_class=form_class,
                           highlight=request.args.get("highlight", type=int))


@app.route("/customer/vehicles/<int:vid>/delete", methods=["POST"])
@role_required("CUSTOMER")
def customer_vehicle_delete(vid):
    n, _ = db.execute("DELETE FROM vehicle WHERE vehicle_id = %s AND user_id = %s", (vid, g.user["user_id"]))
    flash("Vehicle removed." if n else "Vehicle not found.", "ok" if n else "error")
    return redirect(url_for("customer_vehicles"))


# =====================================================================
# Host
# =====================================================================
def own_listing(listing_id):
    row = db.query("SELECT * FROM listing WHERE listing_id = %s AND host_id = %s",
                   (listing_id, g.user["user_id"]), one=True)
    if not row:
        abort(404)
    return row


def own_charger(charger_id):
    row = db.query("""SELECT c.*, l.name AS listing_name FROM charger c JOIN listing l ON l.listing_id = c.listing_id
                       WHERE c.charger_id = %s AND l.host_id = %s""", (charger_id, g.user["user_id"]), one=True)
    if not row:
        abort(404)
    return row


def booking_title(booking_id):
    """How a booking is named to hosts and customers: "Kadri Park Home Charger — Bay A, Thu 26 Nov 14:00–15:00".
    booking_id is the table's primary key (global), so it is never shown as a "booking number"."""
    r = db.query("""SELECT l.name, c.label, b.start_time, b.end_time FROM booking b
                      JOIN charger c ON c.charger_id = b.charger_id JOIN listing l ON l.listing_id = c.listing_id
                     WHERE b.booking_id = %s""", (booking_id,), one=True)
    return f"{r['name']} — {r['label']}, {r['start_time']:%a %d %b %H:%M}–{r['end_time']:%H:%M}" if r else "the booking"


def own_booking(booking_id):
    row = db.query("""SELECT b.booking_id, b.status FROM booking b JOIN charger c ON c.charger_id = b.charger_id
                        JOIN listing l ON l.listing_id = c.listing_id
                       WHERE b.booking_id = %s AND l.host_id = %s""", (booking_id, g.user["user_id"]), one=True)
    if not row:
        abort(404)
    return row


@app.route("/host")
@role_required("HOST")
def host_dashboard():
    uid = g.user["user_id"]
    # earnings per listing come from v_revenue_per_listing (paid bills only; ₹0 for a listing with no sales)
    listings = db.query("""SELECT l.*, r.revenue, r.kwh_sold, r.paid_bills
                             FROM listing l
                             JOIN v_revenue_per_listing r ON r.listing_id = l.listing_id
                            WHERE l.host_id = %s ORDER BY l.listing_id""", (uid,))
    ids = [s["listing_id"] for s in listings]
    chargers = {lid: [] for lid in ids}
    if ids:
        marks = ", ".join(["%s"] * len(ids))
        for c in db.query(f"""
                SELECT c.*, ct.code AS connector, ct.current_type, {CHARGER_STATUS_SQL} AS live_status,
                       (SELECT COUNT(*) FROM booking b WHERE b.charger_id = c.charger_id
                         AND b.status IN ('requested', 'accepted') AND b.end_time > NOW()) AS upcoming,
                       (SELECT COUNT(*) FROM booking b WHERE b.charger_id = c.charger_id) AS num_bookings
                  FROM charger c JOIN connector_type ct ON ct.connector_id = c.connector_id
                 WHERE c.listing_id IN ({marks}) ORDER BY c.label""", tuple(ids)):
            chargers[c["listing_id"]].append(c)
    amen = listing_amenities(ids)
    for s in listings:
        s["chargers"] = chargers[s["listing_id"]]
        s["amenities"] = {a["amenity_id"]: a["note"] for a in amen[s["listing_id"]]}
        s["visible"] = any(c["live_status"] in ("available", "in_use") for c in s["chargers"])
    stats = db.query("""
        SELECT SUM(b.status IN ('accepted', 'charging', 'completed') AND DATE(b.start_time) = CURDATE()) AS today,
               SUM(b.status = 'charging') AS charging,
               SUM(bl.status = 'PAYMENT_PENDING') AS unpaid,
               IFNULL(SUM(CASE WHEN bl.status = 'PAYMENT_PENDING' THEN bl.amount END), 0) AS unpaid_amount,
               IFNULL(SUM(CASE WHEN bl.status = 'PAID' AND DATE_FORMAT(bl.paid_at, '%%Y-%%m') = DATE_FORMAT(NOW(), '%%Y-%%m')
                               THEN bl.amount END), 0) AS month_revenue
          FROM booking b JOIN charger c ON c.charger_id = b.charger_id
          JOIN listing l ON l.listing_id = c.listing_id
          LEFT JOIN bill bl ON bl.booking_id = b.booking_id
         WHERE l.host_id = %s""", (uid,), one=True)
    return render_template("host_home.html", listings=listings, stats=stats, amenities=amenity_rows(), now=datetime.now(),
                           rules=charger_rules())


# ------------------------------------------------------------ listing form (new = steps, edit = one form)
# Same checks and messages as the original ChargeMatch (parse_location / parse_details); the lengths follow the
# Lite columns (name 100, address 200, city 50). MySQL checks them again (NOT NULL, chk_listing_hours, ...).
CITY_RE = re.compile(r"^[A-Za-z]+(?:[ .'-][A-Za-z]+)*\.?$")     # Mangaluru, KR Nagar, Gadag-Betageri
LABEL_RE = re.compile(r"^[A-Za-z0-9]+(?:[ -][A-Za-z0-9]+)*$")    # charger label: WALLBOX, Bay 2, AC-1
PRICE_RE = re.compile(r"^\d{1,2}(\.\d{1,2})?$")
POWER_RE = re.compile(r"^\d{1,2}(\.\d)?$")                      # kW with one decimal (home chargers: max 22)
BAYS = ("2W", "3W", "4W")
BAY_NAMES = {"4W": "Cars (4W)", "3W": "Autos (3W)", "2W": "Two-wheelers (2W)"}
CONNECTOR_NAMES = {"TYPE2": "Type 2", "IND_SOCKET": "15A socket", "BHARAT_AC001": "Bharat AC-001", "LECCS": "LECCS"}


# The charger form's dropdowns: each AC home plug has a short list of power values; LECCS is for 2W / 3W bays only.
# The database enforces the same rules with ONE CHECK (chk_charger_setup); Flask checks first so the message can name
# the field.
CHARGER_RULES = {
    "TYPE2":        {"kw": [3.3, 7.4, 11.0, 22.0], "bays": ["2W", "3W", "4W"]},
    "IND_SOCKET":   {"kw": [2.2, 3.3],             "bays": ["2W", "3W", "4W"]},
    "BHARAT_AC001": {"kw": [3.3],                  "bays": ["2W", "3W", "4W"]},
    "LECCS":        {"kw": [1.5, 3.0],             "bays": ["2W", "3W"]},
}


def kw_label(kw):
    """7.4 -> '7.4 kW'; 11 -> '11 kW (3-phase)' (a home supply above 7.4 kW is 3-phase)."""
    kw = float(kw)
    return f"{kw:g} kW" + (" (3-phase)" if kw >= 11 else "")


def charger_rules():
    """[{connector_id, code, name, kw: [...], bays: [...]}] in the form's order. AC home plugs only."""
    ids = {r["code"]: r["connector_id"] for r in db.query("SELECT connector_id, code FROM connector_type")}
    return [dict(CHARGER_RULES[code], connector_id=ids[code], code=code, name=CONNECTOR_NAMES[code],
                 kw_labels=[kw_label(k) for k in CHARGER_RULES[code]["kw"]])
            for code in CHARGER_RULES if code in ids]


def connector_name(code):
    return CONNECTOR_NAMES.get(code, code)


app.jinja_env.globals.update(connector_name=connector_name, BAY_NAMES=BAY_NAMES, kw_label=kw_label)


def parse_charger(raw, rules, taken=()):
    """One charger's form values -> (values, {field: message}). Short fixed messages; chk_charger_setup checks the
    connector + kW + bay again in the database."""
    by_id = {str(r["connector_id"]): r for r in rules}
    label, conn = clean(raw.get("label")), (raw.get("connector_id") or "").strip()
    rule = by_id.get(conn)
    c = {"label": label, "connector_id": conn, "power_kw": (raw.get("power_kw") or "").strip(),
         "parking_size": (raw.get("parking_size") or "").strip(), "price": (raw.get("price") or "").strip(),
         "connector": rule["name"] if rule else "?"}
    errs = {}
    if not label:
        errs["label"] = "Enter a label"
    elif len(label) < 3:
        errs["label"] = "Minimum 3 characters"
    elif len(label) > 40:
        errs["label"] = "Maximum 40 characters"
    elif not LABEL_RE.match(label):
        errs["label"] = "Use letters, digits, spaces and - only"
    elif label.lower() in {t.lower() for t in taken}:
        errs["label"] = "This listing already has a charger with that label"
    if not rule:
        errs["connector_id"] = "Choose a connector"
    else:
        if not POWER_RE.match(c["power_kw"]) or float(c["power_kw"]) not in rule["kw"]:
            errs["power_kw"] = "Choose the power"
        if c["parking_size"] not in rule["bays"]:
            errs["parking_size"] = ("LECCS is for 2W / 3W bays only" if rule["code"] == "LECCS" and c["parking_size"]
                                    else "Choose the parking bay")
    if not PRICE_RE.match(c["price"]) or not 5 <= float(c["price"]) <= 30:
        errs["price"] = "Enter a price between ₹5 and ₹30"
    return c, errs


LISTING_STEPS = [(1, "Location", "map-pin"), (2, "Details", "info"), (3, "Chargers", "plug-zap"),
                 (4, "Amenities", "sparkles")]
STEP_OF = {"location": 1, "address": 1, "city": 1, "name": 2, "hours": 2, "charger": 3, "amenities": 4}


def clean(v):
    return " ".join((v or "").split())


def to_number(text, lo, hi):
    x = float(text)
    if not lo <= x <= hi:
        raise ValueError
    return x


def parse_listing_form(f):
    """Listing form -> (values, {field: message})."""
    errs = {}
    v = {k: clean(f.get(k)) for k in ("name", "address", "city", "latitude", "longitude", "open_time", "close_time")}
    if not v["name"]:
        errs["name"] = "Name is required"
    elif not 3 <= len(v["name"]) <= 100:
        errs["name"] = "Name must be 3–100 characters"
    if not v["address"]:
        errs["address"] = "Address is required"
    elif not 5 <= len(v["address"]) <= 200:
        errs["address"] = "Address must be 5–200 characters"
    if not v["city"]:
        errs["city"] = "City is required"
    elif len(v["city"]) > 50 or not CITY_RE.match(v["city"]):
        errs["city"] = "City: letters and spaces only (max 50 characters), e.g. Mangaluru"
    try:
        v["latitude"] = round(to_number(v["latitude"], -90, 90), 6)
        v["longitude"] = round(to_number(v["longitude"], -180, 180), 6)
    except ValueError:
        errs["location"] = "Set the listing's location: use “Use my current location” or click the map"
    if f.get("open_24h"):
        v["open_time"], v["close_time"] = "00:00:00", "23:59:59"
    elif v["open_time"] not in OPEN_TIMES or v["close_time"] not in CLOSE_TIMES:
        errs["hours"] = "Choose the opening and closing times from the lists (quarter hours), or tick Open 24 hours"
    elif v["open_time"] >= v["close_time"]:                    # "HH:MM" strings compare like times
        errs["hours"] = "Opening time must be before closing time (tick Open 24 hours for 00:00–23:59)"
    elif v["close_time"] == "23:59":
        v["close_time"] = "23:59:59"
    valid = {a["amenity_id"] for a in amenity_rows()}
    chosen = [a for a in f.getlist("amenity", type=int) if a in valid]
    notes = {a: clean(f.get(f"note_{a}")) or None for a in chosen}
    if any(n and len(n) > 100 for n in notes.values()):
        errs["amenities"] = "An amenity note can have at most 100 characters"
    v["amenities"] = notes
    return v, errs


def parse_wizard_chargers(f, rules):
    """The chargers added in step 3 (parallel c_label / c_connector / c_power / c_bay / c_price lists)
    -> (rows, message)."""
    rows, problems, seen = [], [], []
    keys = ("c_label", "c_connector", "c_power", "c_bay", "c_price")
    for label, conn, power, bay, price in zip(*[f.getlist(k) for k in keys]):
        c, errs = parse_charger({"label": label, "connector_id": conn, "power_kw": power,
                                 "parking_size": bay, "price": price}, rules, taken=seen)
        seen.append(c["label"])
        rows.append(c)
        problems += [f"{c['label'] or 'A charger'}: {m}" for m in errs.values()]
    if not rows:
        problems.append("Add at least one charger")
    return rows, " · ".join(dict.fromkeys(problems))


def save_listing(v, listing_id=None, chargers=()):
    """Insert/update a listing, its amenities (and, for a new listing, its chargers) in ONE transaction."""
    vals = (v["name"], v["address"], v["city"], v["latitude"], v["longitude"], v["open_time"], v["close_time"])
    conn = db.get_conn()
    conn.begin()
    try:
        if listing_id is None:
            _, listing_id = db.execute(
                """INSERT INTO listing (host_id, name, address, city, latitude, longitude, open_time, close_time)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s)""", (g.user["user_id"],) + vals)
        else:
            db.execute("""UPDATE listing SET name = %s, address = %s, city = %s, latitude = %s,
                                 longitude = %s, open_time = %s, close_time = %s
                           WHERE listing_id = %s AND host_id = %s""", vals + (listing_id, g.user["user_id"]))
        db.execute("DELETE FROM listing_amenity WHERE listing_id = %s", (listing_id,))
        for aid, note in v["amenities"].items():
            db.execute("INSERT INTO listing_amenity (listing_id, amenity_id, note) VALUES (%s, %s, %s)",
                       (listing_id, aid, note))
        for c in chargers:                      # new chargers start PENDING (column default): the admin decides each
            insert_charger(listing_id, c)
        conn.commit()
        return listing_id
    except Exception:
        conn.rollback()
        raise


def insert_charger(listing_id, c):
    """New chargers start PENDING (column default); chk_charger_setup checks the set-up."""
    db.execute("""INSERT INTO charger (listing_id, label, connector_id, power_kw, parking_size, price_per_kwh)
                  VALUES (%s, %s, %s, %s, %s, %s)""",
               (listing_id, c["label"], c["connector_id"], c["power_kw"], c["parking_size"], c["price"]))


def db_error_field(e):
    """Which form field / wizard step a refused save belongs to (by constraint name in MySQL's message)."""
    msg = str(e.args[1]) if len(e.args) > 1 else str(e)
    for key, field in (("charger", "charger"), ("kW", "charger"), ("parking bay", "charger"), ("socket", "charger"),
                       ("₹", "charger"),
                       ("hours", "hours"), ("_lat", "location"), ("_lng", "location"),
                       ("amenity", "amenities")):
        if key in msg:
            return field
    return "db"


def listing_page(template, s=None, field_errors=None, chargers=None, status=200):
    others = db.query("""SELECT latitude, longitude, name FROM listing WHERE host_id = %s AND listing_id <> %s""",
                      (g.user["user_id"], s["listing_id"] if s else 0))
    field_errors = field_errors or {}
    start = min([STEP_OF.get(k, 4) for k in field_errors] or [1])      # other errors: the last step (Submit)
    form = request.form if request.method == "POST" else {}
    chosen = ({a: clean(form.get(f"note_{a}")) for a in form.getlist("amenity", type=int)} if form
              else (s["amenities"] if s else {}))
    return render_template(template, s=s, form=form, field_errors=field_errors, chargers=chargers or [],
                           amenities=amenity_rows(), chosen=chosen, rules=charger_rules(), steps=LISTING_STEPS,
                           start=start, center=DEFAULT_CENTER,
                           points=[[float(p["latitude"]), float(p["longitude"]), p["name"]] for p in others]), status


@app.route("/host/listings/new", methods=["GET", "POST"])
@role_required("HOST")
def host_listing_new():
    """'List my charger': location -> details -> chargers -> amenities -> review (steps switch in the page); the
    submit saves the listing, its amenities and its chargers in one transaction."""
    if request.method == "GET":
        return listing_page("host_listing_wizard.html")
    v, errs = parse_listing_form(request.form)
    chargers, problem = parse_wizard_chargers(request.form, charger_rules())
    if problem:
        errs["charger"] = problem
    if errs:
        flash("Please fix the highlighted fields.", "error")
        return listing_page("host_listing_wizard.html", field_errors=errs, chargers=chargers, status=400)
    try:
        lid = save_listing(v, chargers=chargers)
    except pymysql.MySQLError as e:
        msg = db.friendly_error(e)
        flash(msg, "error")
        return listing_page("host_listing_wizard.html", field_errors={db_error_field(e): msg}, chargers=chargers,
                            status=400)
    flash("Submitted — the admin will review each charger.", "ok")
    return redirect(url_for("host_dashboard", _anchor=f"st-{lid}"))


@app.route("/host/listings/<int:listing_id>", methods=["GET", "POST"])
@role_required("HOST")
def host_listing(listing_id):
    s = own_listing(listing_id)
    s["amenities"] = {a["amenity_id"]: a["note"] for a in listing_amenities([listing_id])[listing_id]}
    if request.method == "GET":
        return listing_page("host_listing_form.html", s=s)
    v, errs = parse_listing_form(request.form)
    if errs:
        flash("Please fix the highlighted fields.", "error")
        return listing_page("host_listing_form.html", s=s, field_errors=errs, status=400)
    try:
        save_listing(v, listing_id)
    except pymysql.MySQLError as e:
        msg = db.friendly_error(e)
        flash(msg, "error")
        return listing_page("host_listing_form.html", s=s, field_errors={db_error_field(e): msg}, status=400)
    flash("Listing saved.", "ok")
    return redirect(url_for("host_dashboard", _anchor=f"st-{listing_id}"))


# ------------------------------------------------------------ reverse geocoding (pin -> address + city)
# GET /api/reverse?lat=..&lng=..  ->  {"address": "...", "city": "..."}
# The SERVER asks OpenStreetMap Nominatim (the browser never calls it): identifying User-Agent, 5 s timeout, at most
# one request per second for the whole app, answers cached per point rounded to 4 decimals (about 11 m).
# Only the coordinates are sent, nothing about the user.
NOMINATIM_REVERSE_URL = "https://nominatim.openstreetmap.org/reverse"
GEO_USER_AGENT = "ChargeMatchLite/1.0 (college project)"
_geo_lock, _geo_last, _geo_cache = threading.Lock(), [0.0], {}


class GeoServiceError(Exception):
    """The map service failed (message is shown to the host)."""


def reverse_geocode(lat, lng):
    key = (round(lat, 4), round(lng, 4))
    if key in _geo_cache:
        return _geo_cache[key]
    with _geo_lock:                                   # Nominatim policy: max 1 request per second
        wait = _geo_last[0] + 1.0 - clock.monotonic()
        if wait > 0:
            clock.sleep(wait)
        _geo_last[0] = clock.monotonic()
    try:
        r = requests.get(app.config.get("NOMINATIM_REVERSE_URL", NOMINATIM_REVERSE_URL),
                         params={"format": "jsonv2", "lat": f"{key[0]:.4f}", "lon": f"{key[1]:.4f}",
                                 "addressdetails": 1, "zoom": 18, "accept-language": "en"},
                         headers={"User-Agent": GEO_USER_AGENT, "Accept": "application/json"}, timeout=5)
    except requests.Timeout:
        raise GeoServiceError("the map service took too long to answer")
    except requests.RequestException:
        raise GeoServiceError("couldn't reach the map service; check the internet connection")
    if r.status_code == 429:
        raise GeoServiceError("the free map service is busy; wait a few seconds and try again")
    if r.status_code != 200:
        raise GeoServiceError(f"the map service answered HTTP {r.status_code}")
    try:
        data = r.json()
    except ValueError:
        raise GeoServiceError("the map service sent an unreadable answer")
    a = (data.get("address") or {}) if isinstance(data, dict) and not data.get("error") else {}
    first = lambda *keys: next((a[k] for k in keys if a.get(k)), "")
    street = " ".join(x for x in (a.get("house_number"), first("road", "pedestrian", "footway", "path")) if x)
    city = first("city", "town", "village", "suburb", "county", "state_district")
    # Address = place name (only when there is no street) + street + locality. Many Indian villages have no named
    # road in OpenStreetMap, so the locality falls back through neighbourhood / suburb / village / hamlet; the city
    # itself is not repeated here.
    area_keys = ("neighbourhood", "suburb", "quarter", "residential", "city_district", "village", "hamlet", "locality")
    area = next((a[k] for k in area_keys if a.get(k) and a[k].lower() != city.lower()), "")
    parts = []

    def add(part):
        if part and part.lower() not in (p.lower() for p in parts) and part.lower() != city.lower():
            parts.append(part)
    for part in (first("amenity", "building", "shop") if not street else "", street, area):
        add(part)
    # Still nothing (or too short for the 5-character minimum): take the first parts of display_name, skipping
    # the city, district, state, postcode and country.
    skip = {str(v).lower() for k, v in a.items() if k in ("city", "town", "county", "state_district", "state",
                                                            "postcode", "country", "country_code", "ISO3166-2-lvl4")}
    for piece in (data.get("display_name") or "").split(","):
        if len(", ".join(parts)) >= 5:
            break
        piece = piece.strip()
        if piece and piece.lower() not in skip and not piece.isdigit():
            add(piece)
    if len(", ".join(parts)) < 5 and city:          # last resort: "Near <city>" is still a valid, editable address
        parts = [f"Near {city}"]
    out = {"address": ", ".join(parts)[:200], "city": city[:50]}
    if len(_geo_cache) > 500:
        _geo_cache.clear()
    _geo_cache[key] = out
    return out


@app.route("/api/reverse")
def api_reverse():
    """Address + city for a map point. Public on purpose (the app only listens on 127.0.0.1); throttled + cached."""
    try:
        lat = to_number(request.args.get("lat", ""), -90, 90)
        lng = to_number(request.args.get("lng", ""), -180, 180)
    except ValueError:
        return jsonify(error="lat and lng must be valid numbers"), 400
    try:
        return jsonify(reverse_geocode(lat, lng))
    except GeoServiceError as e:
        return jsonify(error=str(e)), 502


def listing_labels(listing_id, except_id=0):
    return [r["label"] for r in db.query("SELECT label FROM charger WHERE listing_id = %s AND charger_id <> %s",
                                          (listing_id, except_id))]


@app.route("/host/listings/<int:listing_id>/chargers/new", methods=["POST"])
@role_required("HOST")
def host_charger_new(listing_id):
    own_listing(listing_id)
    c, errs = parse_charger(request.form, charger_rules(), taken=listing_labels(listing_id))
    if errs:
        flash("Charger not added: " + " · ".join(errs.values()), "error")
        return redirect(url_for("host_dashboard", _anchor=f"st-{listing_id}"))
    insert_charger(listing_id, c)                 # a refused set-up (trg_charger_bi) is shown by show_db_error
    flash(f"Charger {c['label']} added — it appears in search once the admin approves it.", "ok")
    return redirect(url_for("host_dashboard", _anchor=f"st-{listing_id}"))


SETUP_COLS = ("connector_id", "power_kw", "parking_size")


@app.route("/host/chargers/<int:charger_id>/edit", methods=["GET", "POST"])
@role_required("HOST")
def host_charger_edit(charger_id):
    c = own_charger(charger_id)
    rules = charger_rules()
    draft = None
    if request.method == "POST":
        draft, errs = parse_charger(request.form, rules, taken=listing_labels(c["listing_id"], charger_id))
        if errs:
            flash("Please fix: " + " · ".join(errs.values()), "error")
        else:
            # A different set-up (plug, power or bay), or editing a rejected charger, sends it back to
            # the admin; the label and price alone don't.
            needs_review = (any(str(draft[k]) != str(c[k]) for k in SETUP_COLS if k != "power_kw")
                            or float(draft["power_kw"]) != float(c["power_kw"]) or c["approval"] == "REJECTED")
            try:
                db.execute(f"""UPDATE charger SET label = %s, connector_id = %s, power_kw = %s,
                                      parking_size = %s, price_per_kwh = %s
                                      {", approval = 'PENDING', reviewed_by = NULL, review_note = NULL" if needs_review else ""}
                                WHERE charger_id = %s""",
                           (draft["label"], draft["connector_id"], draft["power_kw"],
                            draft["parking_size"], draft["price"], charger_id))
                flash("Charger saved." + (" It is back in the admin's approval queue (Approval pending)." if needs_review else ""), "ok")
                return redirect(url_for("host_dashboard", _anchor=f"st-{c['listing_id']}"))
            except pymysql.MySQLError as e:
                flash(db.friendly_error(e), "error")
    if draft:                                     # show what the host typed, not the saved row
        c = dict(c, label=draft["label"], connector_id=int(draft["connector_id"] or 0) or c["connector_id"],
                 power_kw=draft["power_kw"] or c["power_kw"],
                 parking_size=draft["parking_size"] or c["parking_size"], price_per_kwh=draft["price"])
    return render_template("host_charger_form.html", c=c, listing=own_listing(c["listing_id"]), rules=rules,
                           labels=listing_labels(c["listing_id"], charger_id))


OUT_OF_SERVICE_REASON = "Charger taken out of service by the host"


@app.route("/host/chargers/<int:charger_id>/status", methods=["POST"])
@role_required("HOST")
def host_charger_status(charger_id):
    """In service / Out of service, in ONE transaction. Out of service: the charger leaves search (v_searchable_chargers),
    trg_booking_bi refuses new bookings, and its requested / accepted bookings are cancelled (the customer sees the
    reason). A session already charging goes on; when it ends, trg_booking_au leaves out_of_service alone."""
    c = own_charger(charger_id)
    to_out = request.form.get("service") == "out"
    if request.form.get("service") not in ("in", "out"):
        abort(400)
    conn = db.get_conn()
    conn.begin()
    try:
        db.query("SELECT status FROM charger WHERE charger_id = %s FOR UPDATE", (charger_id,), one=True)
        charging = db.query("SELECT 1 FROM booking WHERE charger_id = %s AND status = 'charging' LIMIT 1",
                            (charger_id,), one=True)
        if to_out:
            db.execute("UPDATE charger SET status = 'out_of_service' WHERE charger_id = %s", (charger_id,))
            n, _ = db.execute("""UPDATE booking SET status = 'cancelled', cancel_reason = %s
                                  WHERE charger_id = %s AND status IN ('requested', 'accepted')""",
                              (OUT_OF_SERVICE_REASON, charger_id))
        else:                                     # back in service ('occupied' if a car is still charging there)
            db.execute("UPDATE charger SET status = %s WHERE charger_id = %s",
                       ("occupied" if charging else "available", charger_id))
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    if to_out:
        msg = f"{c['label']} is out of service and hidden from customers."
        if n:
            msg += f" {n} upcoming booking{'s were' if n != 1 else ' was'} cancelled (the customer sees why)."
        if charging:
            msg += " The session charging there now continues."
        flash(msg, "ok")
    else:
        flash(f"{c['label']} is back in service.", "ok")
    return redirect(url_for("host_dashboard", _anchor=f"charger-{charger_id}"))


@app.route("/host/chargers/<int:charger_id>/delete", methods=["POST"])
@role_required("HOST")
def host_charger_delete(charger_id):
    """Only a charger with no bookings at all can go: the booking FK (ON DELETE RESTRICT) refuses the rest."""
    c = own_charger(charger_id)
    try:
        db.execute("DELETE FROM charger WHERE charger_id = %s", (charger_id,))
    except pymysql.err.IntegrityError as e:
        if e.args[0] != 1451:                     # 1451 = row is referenced by a foreign key
            raise
        flash("This charger has booking history, so it can't be deleted — set it Out of service instead.", "error")
        return redirect(url_for("host_dashboard", _anchor=f"charger-{charger_id}"))
    flash(f"Charger {c['label']} deleted.", "ok")
    return redirect(url_for("host_dashboard", _anchor=f"st-{c['listing_id']}"))


@app.route("/host/payments")
@role_required("HOST")
def host_payments():
    """Every PAID bill this host has received, newest first, with a month filter and the total."""
    uid = g.user["user_id"]
    months = [r["ym"] for r in db.query("""
        SELECT DISTINCT DATE_FORMAT(bl.paid_at, '%%Y-%%m') AS ym FROM bill bl
          JOIN booking b ON b.booking_id = bl.booking_id JOIN charger c ON c.charger_id = b.charger_id
          JOIN listing l ON l.listing_id = c.listing_id
         WHERE l.host_id = %s AND bl.status = 'PAID' ORDER BY ym DESC""", (uid,))]
    this_month = datetime.now().strftime("%Y-%m")
    if this_month not in months:                  # "collected this month" links here even before the first payment
        months.insert(0, this_month)
    month = request.args.get("month", "")
    if month not in months:                       # "" = all months; anything else unknown is ignored
        month = ""
    rows = db.query("""
        SELECT bl.paid_at, bl.kwh, bl.rate, bl.amount, l.name AS listing_name, c.label AS charger_label,
               u.name AS customer_name, b.start_time, b.end_time
          FROM bill bl
          JOIN booking b ON b.booking_id = bl.booking_id
          JOIN charger c ON c.charger_id = b.charger_id
          JOIN listing l ON l.listing_id = c.listing_id
          JOIN users u   ON u.user_id    = b.customer_id
         WHERE l.host_id = %s AND bl.status = 'PAID'
           AND (%s = '' OR DATE_FORMAT(bl.paid_at, '%%Y-%%m') = %s)
         ORDER BY bl.paid_at DESC""", (uid, month, month))
    total = sum(r["amount"] for r in rows)
    kwh = sum(r["kwh"] for r in rows)
    month_names = {m: datetime.strptime(m, "%Y-%m").strftime("%B %Y") for m in months}
    return render_template("host_payments.html", rows=rows, total=total, kwh=kwh, months=months,
                           month_names=month_names, month=month)


HOST_TABS = {"requests": "Requests", "upcoming": "Upcoming", "charging": "Charging now",
             "unpaid": "Awaiting payment", "history": "History"}


@app.route("/host/bookings")
@role_required("HOST")
def host_requests():
    uid = g.user["user_id"]
    listing_id = request.args.get("listing", type=int)
    rows = db.query(f"""
        SELECT b.*, c.label AS charger_label, c.power_kw, ct.code AS connector,
               {CHARGER_STATUS_SQL} AS charger_live, l.name AS listing_name,
               u.name AS customer_name, v.reg_no, m.make, m.model_name,
               s.start_pct, s.end_pct, s.started_at,
               bl.bill_id, bl.kwh AS bill_kwh, bl.rate AS bill_rate, bl.amount, bl.status AS bill_status, bl.paid_at
          FROM booking b
          JOIN charger c ON c.charger_id = b.charger_id
          JOIN connector_type ct ON ct.connector_id = c.connector_id
          JOIN listing l ON l.listing_id = c.listing_id
          JOIN users u   ON u.user_id = b.customer_id
          JOIN vehicle v ON v.vehicle_id = b.vehicle_id
          JOIN vehicle_model m ON m.model_id = v.model_id
          LEFT JOIN charging_session s ON s.booking_id = b.booking_id
          LEFT JOIN bill bl ON bl.booking_id = b.booking_id
         WHERE l.host_id = %s {'AND l.listing_id = %s' if listing_id else ''}""",
                    (uid, listing_id) if listing_id else (uid,))

    def tab_of(b):
        if b["status"] == "requested":
            return "requests"
        if b["status"] == "accepted":
            return "upcoming"
        if b["status"] == "charging":
            return "charging"
        if b["bill_status"] == "PAYMENT_PENDING":
            return "unpaid"
        return "history"
    counts = {k: 0 for k in HOST_TABS}
    unpaid_amount = 0
    for b in rows:
        b["tab"] = tab_of(b)
        counts[b["tab"]] += 1
        if b["tab"] == "unpaid":
            unpaid_amount += b["amount"]
    tab = request.args.get("tab") or next((k for k in ("requests", "charging", "upcoming", "unpaid") if counts[k]), "history")
    if tab not in HOST_TABS:
        tab = "requests"
    shown = sorted([b for b in rows if b["tab"] == tab], key=lambda b: b["start_time"],
                   reverse=tab in ("unpaid", "history"))
    listings = db.query("SELECT listing_id, name FROM listing WHERE host_id = %s ORDER BY name", (uid,))
    return render_template("host_bookings.html", bookings=shown, counts=counts, unpaid_amount=unpaid_amount,
                           tab=tab, tabs=HOST_TABS, listings=listings, listing_id=listing_id, now=datetime.now())


@app.route("/host/bookings/<int:bid>/<action>", methods=["POST"])
@role_required("HOST")
def host_booking_action(bid, action):
    b = own_booking(bid)
    hid = g.user["user_id"]
    tab = "requests"
    if action == "accept":
        db.call("accept_booking", hid, bid)
        flash(f"Accepted: {booking_title(bid)}. Overlapping requests were declined automatically.", "ok")
        tab = "upcoming"
    elif action == "decline":
        n, _ = db.execute("""UPDATE booking SET status = 'declined', cancel_reason = 'Declined by host'
                              WHERE booking_id = %s AND status = 'requested'""", (bid,))
        flash(f"Declined: {booking_title(bid)}." if n else "Only a requested booking can be declined.", "ok" if n else "error")
    elif action == "cancel":
        db.execute("UPDATE booking SET status = 'cancelled', cancel_reason = 'Cancelled by host' WHERE booking_id = %s", (bid,))
        flash(f"Cancelled: {booking_title(bid)}.", "ok")
        tab = "history"
    elif action == "start":
        problem = start_session(hid, bid, request.form.get("start_pct", type=int))
        if problem:
            flash(problem, "error")
            tab = "upcoming"
        else:
            flash(f"Charging started: {booking_title(bid)}.", "ok")
            tab = "charging"
    elif action == "end":
        db.call("end_session", hid, bid, request.form.get("end_pct", type=int))
        bill = db.query("SELECT kwh, rate, amount FROM bill WHERE booking_id = %s", (bid,), one=True)
        flash(f"Session finished. Bill: {bill['kwh']} kWh × ₹{bill['rate']} = ₹{bill['amount']}.", "ok")
        tab = "unpaid"
    else:
        abort(404)
    return redirect(url_for("host_requests", tab=tab, _anchor=f"bk-{bid}"))


def start_session(host_id, booking_id, start_pct):
    """Host plugs the car in (was a stored procedure; now plain parameterised SQL in ONE transaction).
    Returns None, or a message when it isn't allowed. The charger row is locked (FOR UPDATE) so two sessions can't
    start on it at once; trg_booking_bu checks the status change, trg_booking_au marks the charger occupied."""
    conn = db.get_conn()
    conn.begin()
    try:
        b = db.query("""SELECT b.booking_id, b.charger_id, b.status, b.start_time, b.end_time, l.host_id,
                               vm.battery_kwh
                          FROM booking b
                          JOIN charger c        ON c.charger_id = b.charger_id
                          JOIN listing l        ON l.listing_id = c.listing_id
                          JOIN vehicle v        ON v.vehicle_id = b.vehicle_id
                          JOIN vehicle_model vm ON vm.model_id  = v.model_id
                         WHERE b.booking_id = %s""", (booking_id,), one=True)
        if not b or b["host_id"] != host_id:                     # ownership check in Python
            problem = "Only the host of this charger can start the session."
        else:
            charger = db.query("SELECT status FROM charger WHERE charger_id = %s FOR UPDATE", (b["charger_id"],), one=True)
            now = datetime.now()
            if b["status"] != "accepted":
                problem = "Only an accepted booking can be started."
            elif start_pct is None or not 0 <= start_pct <= 99:
                problem = "Start battery % must be between 0 and 99."
            elif now < b["start_time"] - timedelta(minutes=30):
                problem = (f"Too early: a session can start at most 30 minutes before the slot "
                           f"({b['start_time']:%d %b %H:%M}).")
            elif now >= b["end_time"]:
                problem = "This slot has already ended; the session cannot start."
            elif charger["status"] == "out_of_service":
                problem = "This charger is out of service. Put it back in service first."
            elif charger["status"] == "occupied":
                problem = "Another vehicle is already charging on this charger."
            else:
                problem = None
                db.execute("""INSERT INTO charging_session (booking_id, start_pct, battery_kwh, started_at)
                              VALUES (%s, %s, %s, NOW())""", (booking_id, start_pct, b["battery_kwh"]))
                db.execute("UPDATE booking SET status = 'charging' WHERE booking_id = %s", (booking_id,))
        conn.commit()
        return problem
    except Exception:
        conn.rollback()
        raise


@app.route("/host/bills")
@role_required("HOST")
def host_bills():
    """Bills live on the Bookings page ("Awaiting payment" / "History" tabs), as in the original."""
    return redirect(url_for("host_requests", tab="unpaid"))


@app.route("/host/bills/<int:bill_id>/paid", methods=["POST"])
@role_required("HOST")
def host_bill_paid(bill_id):
    """Host confirms the customer paid (cash / UPI). Was a stored procedure; now one UPDATE whose WHERE clause holds
    the ownership check. trg_bill_bu stamps paid_at and locks the bill once it is PAID."""
    n, _ = db.execute("""UPDATE bill bl
                           JOIN booking b ON b.booking_id = bl.booking_id
                           JOIN charger c ON c.charger_id = b.charger_id
                           JOIN listing l ON l.listing_id = c.listing_id
                            SET bl.status = 'PAID'
                          WHERE bl.bill_id = %s AND l.host_id = %s AND bl.status = 'PAYMENT_PENDING'""",
                      (bill_id, g.user["user_id"]))
    if n:
        bk = db.query("SELECT booking_id FROM bill WHERE bill_id = %s", (bill_id,), one=True)
        flash(f"Marked as paid: {booking_title(bk['booking_id'])}.", "ok")
    else:
        flash("That bill isn't yours or is already paid.", "error")
    return redirect(url_for("host_requests", tab="unpaid"))


# =====================================================================
# Admin
# =====================================================================
@app.route("/admin")
@role_required("ADMIN")
def admin_dashboard():
    summary = db.query("""SELECT
        (SELECT COUNT(*) FROM users WHERE role = 'HOST')     AS hosts,
        (SELECT COUNT(*) FROM users WHERE role = 'CUSTOMER') AS customers,
        (SELECT COUNT(*) FROM charger)                       AS chargers,
        (SELECT COUNT(*) FROM charger WHERE approval = 'PENDING') AS chargers_awaiting""", one=True)
    # "Chargers awaiting approval": one compact group per listing (name · city · host); the listing page has the rest
    rows = db.query("""
        SELECT c.charger_id, c.label, c.power_kw, c.parking_size, c.price_per_kwh, ct.code AS connector,
               l.listing_id, l.name, l.city, u.name AS host_name
          FROM charger c
          JOIN connector_type ct ON ct.connector_id = c.connector_id
          JOIN listing l ON l.listing_id = c.listing_id
          JOIN users u ON u.user_id = l.host_id
         WHERE c.approval = 'PENDING'
         ORDER BY l.listing_id, c.label""")
    groups = {}
    for r in rows:
        groups.setdefault(r["listing_id"], {"listing_id": r["listing_id"], "name": r["name"], "city": r["city"],
                                            "host_name": r["host_name"], "chargers": []})["chargers"].append(r)
    pending = list(groups.values())
    return render_template("admin_home.html", summary=summary, pending=pending, reject_min=REJECT_MIN)


@app.route("/admin/chargers/<int:charger_id>/review", methods=["POST"])
@role_required("ADMIN")
def admin_review(charger_id):
    decision = request.form.get("decision")
    note = (request.form.get("reason") or request.form.get("note") or "").strip() or None
    back = safe_back(url_for("admin_dashboard", _anchor="chargers-awaiting"))
    if decision not in ("APPROVED", "REJECTED"):
        abort(400)
    if decision == "REJECTED" and (not note or len(note) < REJECT_MIN):
        flash(f"Write a reason of at least {REJECT_MIN} characters — the host sees it.", "error")
        return redirect(back)
    n, _ = db.execute("""UPDATE charger SET approval = %s, reviewed_by = %s, review_note = %s
                          WHERE charger_id = %s""", (decision, g.user["user_id"], note, charger_id))
    if not n:
        abort(404)
    flash(f"Charger #{charger_id} {'approved' if decision == 'APPROVED' else 'rejected'}.", "ok")
    return redirect(back)


APPROVAL_FILTERS = (("", "All"), ("APPROVED", "Approved"), ("PENDING", "Pending"), ("REJECTED", "Rejected"))


@app.route("/admin/chargers")
@role_required("ADMIN")
def admin_chargers():
    """Every charger, filterable by approval (?approval=APPROVED|PENDING|REJECTED). Pending rows can be decided here."""
    approval = (request.args.get("approval") or "").upper()
    if approval not in ("APPROVED", "PENDING", "REJECTED"):
        approval = ""
    rows = db.query(f"""
        SELECT c.charger_id, c.label, c.power_kw, c.parking_size, c.price_per_kwh,
               c.approval, c.review_note, ct.code AS connector, ct.current_type,
               l.listing_id, l.name AS listing_name, l.city, u.name AS host_name,
               {CHARGER_STATUS_SQL} AS live_status
          FROM charger c
          JOIN connector_type ct ON ct.connector_id = c.connector_id
          JOIN listing l ON l.listing_id = c.listing_id
          JOIN users u ON u.user_id = l.host_id
         WHERE (%s = '' OR c.approval = %s)
         ORDER BY FIELD(c.approval, 'PENDING', 'APPROVED', 'REJECTED'), l.name, c.label""", (approval, approval))
    counts = {r["approval"]: r["n"] for r in db.query("SELECT approval, COUNT(*) AS n FROM charger GROUP BY approval")}
    counts[""] = sum(counts.values())
    return render_template("admin_chargers.html", rows=rows, approval=approval, counts=counts,
                           filters=APPROVAL_FILTERS, reject_min=REJECT_MIN)


@app.route("/admin/hosts", endpoint="admin_hosts", defaults={"role": "HOST"})
@app.route("/admin/customers", endpoint="admin_customers", defaults={"role": "CUSTOMER"})
@role_required("ADMIN")
def admin_people(role):
    q = request.args.get("q", "").strip()
    like = f"%{q}%"
    rows = db.query("""
        SELECT u.user_id, u.name, u.email, u.role, u.status, u.created_at,
               (SELECT COUNT(*) FROM listing l WHERE l.host_id = u.user_id) AS listings,
               (SELECT COUNT(*) FROM charger c JOIN listing l ON l.listing_id = c.listing_id WHERE l.host_id = u.user_id) AS chargers,
               (SELECT COUNT(*) FROM vehicle v WHERE v.user_id = u.user_id) AS vehicles,
               (SELECT GROUP_CONCAT(CONCAT(m.make, ' ', m.model_name) SEPARATOR ', ') FROM vehicle v
                  JOIN vehicle_model m ON m.model_id = v.model_id WHERE v.user_id = u.user_id) AS vehicle_names,
               (SELECT COUNT(*) FROM booking b WHERE b.customer_id = u.user_id) AS bookings
          FROM users u
         WHERE u.role = %s AND (%s = '' OR u.name LIKE %s OR u.email LIKE %s)
         ORDER BY u.name""", (role, q, like, like))
    counts = {r["role"]: r["n"] for r in db.query("SELECT role, COUNT(*) AS n FROM users GROUP BY role")}
    return render_template("admin_users.html", rows=rows, role=role, q=q, counts=counts)


# =====================================================================
# Start-up: waitress (like the original), foreground, clean Ctrl+C
# =====================================================================
def port_is_free(host, port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        # like waitress: closed connections still in TIME_WAIT don't count, only a real listener does
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind((host, port))
            return True
        except OSError:
            return False


if __name__ == "__main__":
    host = "127.0.0.1"
    if not port_is_free(host, config.APP_PORT):
        print(f"\n  Port {config.APP_PORT} is already in use (maybe the app is already running?).\n"
              f"  Find it with:  lsof -nP -iTCP:{config.APP_PORT} -sTCP:LISTEN\n"
              f"  or set another PORT in .env (not 5050).\n")
        sys.exit(1)
    try:
        db.connect().close()
    except pymysql.MySQLError as e:
        print(f"\n  Cannot connect to MySQL as {config.DB_USER}: {e}\n  Did you run ./setup_db.sh ?\n")
        sys.exit(1)

    from waitress.server import create_server

    # waitress logs nothing per request; hide its own "Serving on ..." info line, keep warnings/errors.
    logging.basicConfig(level=logging.WARNING, format="%(levelname)s %(name)s: %(message)s")
    logging.getLogger("waitress").setLevel(logging.WARNING)

    try:
        # binds the socket now. waitress would delete X-Forwarded-* (it trusts no proxy); keep them for ProxyFix
        # above: only the local cloudflared tunnel can reach 127.0.0.1.
        server = create_server(app, host=host, port=config.APP_PORT, threads=8,
                               clear_untrusted_proxy_headers=False)
    except OSError as e:
        print(f"\n  Could not listen on {host}:{config.APP_PORT}: {e}\n")
        sys.exit(1)
    print(f"ChargeMatch running at http://{host}:{config.APP_PORT} — press Ctrl+C to stop", flush=True)
    try:
        server.run()                    # blocks here, in the foreground, until Ctrl+C
    except KeyboardInterrupt:
        pass
    finally:
        server.close()
    print("\nChargeMatch stopped.", flush=True)
