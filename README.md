# ⚡ ChargeMatch

A peer-to-peer platform where people rent out their **private home EV chargers**
(Mangaluru / Udupi / Manipal demo data). College DBMS mini-project.

**Stack:** MySQL 8+ · Python Flask · PyMySQL (parameterised queries only) · Jinja templates · Leaflet + OpenStreetMap

Most of the rules live **inside the database** (triggers, procedures, CHECK constraints).
The Flask app runs the SQL and shows the database's error messages to the user.

| Object | Count |
|---|---|
| Tables | 12 |
| Views | 2 |
| Triggers | 5 |
| Functions | 1 |
| Procedures | 2 |
| CHECK constraints | 18 |

Full database documentation: **[docs/DB_REPORT.md](docs/DB_REPORT.md)** (ER diagram, keys, normalisation, every object, sample queries).

---

## 1. First-time setup (once)

Needs: macOS with Homebrew MySQL running (`brew services start mysql`), Python 3.

```bash
cd ~/Desktop/dbms_lite

# 1) Python virtualenv + pinned packages
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

# 2) Database: creates/completes .env (random MYSQL_PASSWORD + SECRET_KEY), the database chargematch_lite,
#    the MySQL user cmlite_app, then loads schema.sql and seed.sql
./setup_db.sh
```

`setup_db.sh` safety rules:
* It only ever touches the database **`chargematch_lite`** (the name is hard-coded) and the user `cmlite_app`.
* It **always** creates or completes `.env` first (`MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_SOCKET`, `MYSQL_DB`, `MYSQL_USER`,
  `MYSQL_PASSWORD`, `PORT`, `SECRET_KEY`), generating any missing secret without printing it. It also makes sure
  `cmlite_app` exists with that password. Running it again is safe.
* If `chargematch_lite` already has tables it **keeps the data** and reloads nothing. To wipe and reload, run `./setup_db.sh --reset`.
  This asks you to type the database name, saves a `mysqldump` backup in `backups/`, and only then
  drops and recreates `chargematch_lite`.
* `schema.sql` and `seed.sql` contain no `CREATE DATABASE` / `DROP DATABASE` / `USE`. The script checks for these
  and refuses to load a file that has them. The script loads each file with the DB name given explicitly:
  `mysql -u root chargematch_lite < schema.sql`.
* The app user `cmlite_app` has only `SELECT, INSERT, UPDATE, DELETE, EXECUTE` on `chargematch_lite.*`.
  It cannot create or drop tables or see other databases. MySQL root is used only by `setup_db.sh`.

## 2. Start it each day

```bash
~/Desktop/dbms_lite/run.sh
```
You should see:
```
ChargeMatch running at http://127.0.0.1:5070 — press Ctrl+C to stop
```
Leave that Terminal window open and go to **http://127.0.0.1:5070** (the `PORT` in `.env`). The server is **waitress**, like the
original ChargeMatch: it prints nothing per request, only the banner and any errors.
Press `Ctrl+C` to stop; it prints `ChargeMatch stopped.`

`run.sh` works from any folder. It uses `.venv/bin/python` and checks the packages, `.env`, the MySQL login and the port
(it shows who holds the port if it is busy). Then it runs the server **in the foreground** on 127.0.0.1. Closing the
window stops the app. The port is set by `PORT` in `.env`, and port 5050 is never used.

### Share with friends: `./start_public.sh`

```bash
~/Desktop/dbms_lite/start_public.sh
```
It starts the app on the `.env` `PORT` (5070) and a free Cloudflare quick tunnel to it, then prints
`Share this link: https://….trycloudflare.com`. Send that link; it changes every time. Keep the window open and the
laptop awake. `Ctrl+C` stops both the tunnel and the app. Needs `cloudflared` (`brew install cloudflared`).
Stop `./run.sh` first: the script refuses to start if the port is busy and prints the `kill` command.

* The app still listens on 127.0.0.1 only; the tunnel is the only way in. Logs: `logs/public_app.log`, `logs/public_tunnel.log`.
* Over the https link the login cookie is `Secure`, `HttpOnly` and `SameSite=Lax`; no debug mode, and visitors
  never see a traceback (errors go to the log).
* Anyone with the link can log in with the demo accounts below (the login page no longer shows the password).
  Share the link only with people you trust, and stop sharing when you're done.

## 3. Demo logins

Every demo account uses the password **`demo1234`**. The database stores only scrypt hashes.

| Role | Email | Notes |
|---|---|---|
| Admin | `admin@cmlite.test` | approves / rejects chargers; sees read-only host and customer lists |
| Host | `ananya@cmlite.test` | Kadri Park + Kankanady (Mangaluru) |
| Host | `rohan@cmlite.test` | Bejai 24×7 (has a **live charging session**) + Kodialbail |
| Host | `fathima@cmlite.test` | Surathkal (1 PENDING Type 2 11 kW charger) + Panambur (1 charger **out of service**) |
| Host | `prakash@cmlite.test` | Udupi: Ambalpady + Malpe (1 **REJECTED** charger) |
| Host | `shreya@cmlite.test` | Manipal: Tiger Circle + End Point (1 PENDING) |
| Customer | `kiran@cmlite.test` | Nexon EV LR + Ather 450X (charging right now at Bejai) |
| Customer | `meera@cmlite.test` | Tiago EV LR |
| Customer | `arjun@cmlite.test` | MG ZS EV + Mahindra Treo |
| Customer | `divya@cmlite.test` | Kona Electric (a cancelled booking and a new request for the same slot) |
| Customer | `nikhil@cmlite.test` | Ola S1 Pro + Nissan Leaf (imported) (Type 1 / CHAdeMO + portable 15A charger, a car: only one charger fits!) |

### Suggested viva walk-through (≈5 min)
1. **Customer `nikhil`** → *Find chargers* with the Nissan Leaf, then click the map at Udupi (25 km radius): with “Only chargers
   that fit” ticked just the 15A socket on a car bay (Ambalpady, Bay 2) appears (`fn_compat_reason`). Untick it to see the
   others with the reason they don't fit: a plug mismatch (Type 2) or a parking bay that is too small (“Parking bay is for 2W,
   your Nissan Leaf (imported) is 4W.”). Switch to the Ola S1 Pro and more chargers fit.
2. In a result card, book a slot **outside opening hours** or **10 minutes long** to see the trigger / CHECK message. Then book a valid slot.
3. **Host `ananya`** → *Bookings* → *Requests* → accept it. `accept_booking` locks the charger row and auto-declines
   any overlapping requests. (Accepting #22 as Ananya declines #29.)
4. For a slot starting within 30 minutes: *Upcoming* → *Start session* (battery %), then *Charging now* → *Finish now* (end %).
   The bill is created by `trg_session_au`. *Awaiting payment* → *Mark as paid*. Paying a second time is refused by `trg_bill_bu`.
5. **Customer** → *My bookings* → *Past* shows each completed booking with its bill and “Payment successful” once paid.
   **Host** → *My chargers* shows each listing's earnings (“Earned ₹… · kWh sold …”) from the view `v_revenue_per_listing`
   (a listing with no paid bills shows ₹0).
   **Host** → *List my charger* has 4 steps (Location → Details → Chargers → Amenities; *Submit for approval* ends step 4). Step 3 is the
   charger form: pick the connector first (home chargers are AC only: Type 2, 15A socket, Bharat AC-001, LECCS), then Power
   offers only that connector's values (Type 2 3.3 / 7.4 / 11 / 22 kW, 15A socket 2.2 / 3.3, Bharat AC-001 3.3, LECCS
   1.5 / 3.0) and Parking bay its bays (LECCS: 2W / 3W only). *Add charger* is enabled once every value is valid. The
   database refuses anything else with one CHECK, **`chk_charger_setup`**, even from plain SQL. Nothing is
   stored until *Submit for approval*; then the listing, its amenities and its chargers are saved in **one transaction**
   (a CHECK failure, e.g. a ₹40 price, rolls everything back and the page opens on the step with the message).
   **Host** → *My chargers* → *Out of service* hides a charger from search and the map and cancels its upcoming
   bookings (the customer sees "Charger taken out of service by the host"); *Put in service* brings it back. *Delete*
   works only for a charger with no bookings: otherwise the booking FK (`ON DELETE RESTRICT`) refuses it. The
   *collected this month* card opens *Payments received* (every paid bill, month filter, total).
6. **Admin** → *Admin console*: 4 cards. *Hosts* / *Customers* open read-only lists (search only). *Chargers* opens all
   20 chargers with All / Approved / Pending / Rejected filters; *Pending approvals* opens the Pending filter. Approve a
   charger, or reject it with a note the host sees, there or in “Chargers awaiting approval” on the console.

## 4. Running SQL yourself

```bash
mysql -u root chargematch_lite
# tip: so ₹ / é / emoji display correctly in the terminal:
mysql -u root --default-character-set=utf8mb4 chargematch_lite
```
```sql
SHOW FULL TABLES;
SHOW TRIGGERS;
SHOW PROCEDURE STATUS WHERE Db = 'chargematch_lite';
SHOW FUNCTION STATUS  WHERE Db = 'chargematch_lite';
SELECT * FROM v_searchable_chargers;
SELECT * FROM v_revenue_per_listing;
SELECT fn_compat_reason(1, 7);            -- why the Ola S1 Pro can't use charger 1
SELECT fn_compat_reason(15, 8);           -- the Leaf doesn't fit the 2W bay at Garden
CALL accept_booking(2, 22);               -- host 2 accepts booking 22 (declines overlapping #29)
```
More example queries (joins, self-join, HAVING, spatial) are in `docs/DB_REPORT.md` §7.

## 5. Integrity check

```bash
.venv/bin/python check_integrity.py
```
Runs 25 read-only checks: orphans, overlapping accepted bookings, bill maths
(`kwh = (end−start)/100 × battery`, `amount = kwh × rate`), life-cycle consistency, the home-charger rules (same as
`chk_charger_setup`), plug + parking-bay compatibility, vehicle ownership, charger labels (3+ characters), duplicate amenity names and bookings left on out-of-service chargers. The exit code is 0 when all checks pass.

## 6. Project layout

```
schema.sql          12 tables → 1 function → 5 triggers → 2 procedures → 2 views
migrations/         001_charger_rules.sql … 007_out_of_service.sql: bring an existing database up to date
                    (keep users + bookings)
seed.sql            demo data (relative to today's date)
setup_db.sh         create DB + app user, load schema + seed (--reset = backup, drop, reload)
run.sh              start the app (waitress) on PORT from .env (5070)
start_public.sh     share it: app + Cloudflare quick tunnel, prints the https link
app.py              Flask routes (customer / host / admin)
db.py               PyMySQL helpers + friendly error messages
config.py           reads .env, refuses a wrong DB name or the root user
check_integrity.py  data integrity checks
tools/er_extract.py ER diagram from information_schema, verified against the data -> docs/ER_DIAGRAM.md
tools/er_chen.py    Chen-notation version (Graphviz) -> docs/er_chen.svg / .png
templates/          Jinja pages      static/  style.css + app.js + review_map.js copied from the original ChargeMatch,
                    customer_map.js adapted from it, host.js, lite.css (2 small overrides), validate.js (every
                    form: short fixed messages such as “Minimum 3 characters”, shown only after Enter / Submit /
                    Continue and cleared as soon as the value is valid)
docs/DB_REPORT.md   database report for the viva
.env.example        copy of the settings (.env itself is git-ignored)
```

## 7. Troubleshooting

| Problem | Fix |
|---|---|
| `Port 5070 is already in use` | The app is probably already running. Run `lsof -nP -iTCP:5070 -sTCP:LISTEN` to see what holds the port, or change `PORT` in `.env` |
| `start_public.sh`: `cloudflared is not installed` | `brew install cloudflared` |
| `Cannot connect to MySQL as cmlite_app` | `brew services start mysql`, then check `.env`. Running `./setup_db.sh --reset` re-creates the user |
| `already has N tables/views — data kept` | This is expected. `.env` and the app user were still checked and repaired. Use `./setup_db.sh --reset` to reload the demo data |
| `SECRET_KEY / MYSQL_PASSWORD missing in .env` | Run `./setup_db.sh`. It fills them in, resets `cmlite_app`'s password to match, and keeps your data |
| Map is blank | Leaflet and the map tiles load from the internet, so check your connection |
| “Couldn't find the address” | The host listing page fills address + city from the pin through OpenStreetMap Nominatim (the server calls it via `GET /api/reverse?lat=..&lng=..`, 5 s timeout, max 1 request/second, cached). Offline or rate-limited: type the address yourself, everything else still works |
| Add-vehicle list has only 12 models (database made before 2026-11-26) | Back it up, then `mysql -u root chargematch_lite < migrations/002_vehicle_catalogue.sql`: adds the original's catalogue (56 models) and keeps every vehicle and booking |
| Database still has the `rating` table or `v_listing_trust` | Back it up, then `mysql -u root chargematch_lite < migrations/004_remove_ratings.sql` |
| Database still has `users.phone` | Back it up, then `mysql -u root chargematch_lite < migrations/005_remove_phone.sql` |
| Only 6 amenities, or a late request can't be accepted | Back it up, then `mysql -u root --default-character-set=utf8mb4 chargematch_lite < migrations/006_amenities_late_accept.sql` |
| Charger status still has `faulty` / `offline` | Back it up, then `mysql -u root --default-character-set=utf8mb4 chargematch_lite < migrations/007_out_of_service.sql` |
| Database still has `fn_charger_status`, `start_session`, `mark_bill_paid` or `booking.parent_booking_id` | Back it up, then `mysql -u root chargematch_lite < migrations/003_simplify.sql` (keeps every row) |
| Upgrading a database made before 2026-11-25 (no `phase` / `parking_size` / `cable_provided` on `charger`) | Back it up (`mysqldump -u root --routines --triggers chargematch_lite > backups/x.sql`), then `mysql -u root chargematch_lite < migrations/001_charger_rules.sql`. It keeps users and bookings and turns the demo chargers into valid AC set-ups |
| Logged out when switching tabs (another Flask app on 127.0.0.1, e.g. the original on 5050) | Cookies are per host, not per port. Lite's login cookie is called `cmlite_session` (8-hour login), so it no longer clashes with another app's `session` cookie. After upgrading, log in once more |
| Seed data looks "old" | Dates are relative to the day you ran setup. Run `./setup_db.sh --reset` to refresh them |
