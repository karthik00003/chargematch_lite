#!/usr/bin/env python3
"""ChargeMatch Lite — data integrity checker (read-only).

Run:  .venv/bin/python check_integrity.py
Connects as the app user and runs SELECTs only. Every check is a query that
should return ZERO rows; any row returned is a problem and is printed.
Exit code 0 = all passed, 1 = something failed.
"""
import sys

import db

CHECKS = [
    # ---------------------------------------------------------- orphans
    ("Orphan listings (host missing)",
     "SELECT l.listing_id FROM listing l LEFT JOIN users u ON u.user_id = l.host_id WHERE u.user_id IS NULL"),
    ("Listings owned by a non-HOST user",
     "SELECT l.listing_id, u.role FROM listing l JOIN users u ON u.user_id = l.host_id WHERE u.role <> 'HOST'"),
    ("Orphan chargers (listing missing)",
     "SELECT c.charger_id FROM charger c LEFT JOIN listing l ON l.listing_id = c.listing_id WHERE l.listing_id IS NULL"),
    ("Orphan vehicles (owner or model missing)",
     """SELECT v.vehicle_id FROM vehicle v
          LEFT JOIN users u ON u.user_id = v.user_id
          LEFT JOIN vehicle_model m ON m.model_id = v.model_id
         WHERE u.user_id IS NULL OR m.model_id IS NULL"""),
    ("Orphan bookings (customer / vehicle / charger missing)",
     """SELECT b.booking_id FROM booking b
          LEFT JOIN users u   ON u.user_id = b.customer_id
          LEFT JOIN vehicle v ON v.vehicle_id = b.vehicle_id
          LEFT JOIN charger c ON c.charger_id = b.charger_id
         WHERE u.user_id IS NULL OR v.vehicle_id IS NULL OR c.charger_id IS NULL"""),
    ("Orphan sessions / bills",
     """SELECT 'session' AS kind, s.booking_id AS id FROM charging_session s
          LEFT JOIN booking b ON b.booking_id = s.booking_id WHERE b.booking_id IS NULL
        UNION ALL
        SELECT 'bill', bl.bill_id FROM bill bl
          LEFT JOIN booking b ON b.booking_id = bl.booking_id WHERE b.booking_id IS NULL"""),
    ("Orphan bridge rows (listing_amenity / model_connector)",
     """SELECT 'listing_amenity' AS kind, la.listing_id AS id FROM listing_amenity la
          LEFT JOIN listing l ON l.listing_id = la.listing_id
          LEFT JOIN amenity a ON a.amenity_id = la.amenity_id
         WHERE l.listing_id IS NULL OR a.amenity_id IS NULL
        UNION ALL
        SELECT 'model_connector', mc.model_id FROM model_connector mc
          LEFT JOIN vehicle_model m ON m.model_id = mc.model_id
          LEFT JOIN connector_type ct ON ct.connector_id = mc.connector_id
         WHERE m.model_id IS NULL OR ct.connector_id IS NULL"""),

    # --------------------------------------------------------- overlaps
    ("Overlapping accepted/charging bookings on the same charger",
     """SELECT a.booking_id AS booking_a, b.booking_id AS booking_b, a.charger_id
          FROM booking a JOIN booking b
            ON a.charger_id = b.charger_id AND a.booking_id < b.booking_id
           AND a.start_time < b.end_time AND a.end_time > b.start_time
         WHERE a.status IN ('accepted','charging') AND b.status IN ('accepted','charging')"""),
    ("More than one booking charging on a charger",
     "SELECT charger_id, COUNT(*) n FROM booking WHERE status = 'charging' GROUP BY charger_id HAVING n > 1"),

    # ------------------------------------------------------- bill maths
    ("Bill kWh <> (end% - start%) / 100 x battery_kwh",
     """SELECT bl.bill_id, bl.kwh,
               ROUND((s.end_pct - s.start_pct) / 100 * s.battery_kwh, 2) AS expected
          FROM bill bl JOIN charging_session s ON s.booking_id = bl.booking_id
         WHERE bl.kwh <> ROUND((s.end_pct - s.start_pct) / 100 * s.battery_kwh, 2)"""),
    ("Bill amount <> kWh x rate",
     "SELECT bill_id, amount, ROUND(kwh * rate, 2) AS expected FROM bill WHERE amount <> ROUND(kwh * rate, 2)"),
    ("Bill without a finished session",
     """SELECT bl.bill_id FROM bill bl LEFT JOIN charging_session s ON s.booking_id = bl.booking_id
         WHERE s.booking_id IS NULL OR s.end_pct IS NULL"""),
    ("PAID flag and paid_at disagree",
     """SELECT bill_id FROM bill
         WHERE (status = 'PAID' AND paid_at IS NULL) OR (status <> 'PAID' AND paid_at IS NOT NULL)"""),

    # ----------------------------------------------- life-cycle consistency
    ("Completed booking missing a finished session or bill",
     """SELECT b.booking_id FROM booking b
          LEFT JOIN charging_session s ON s.booking_id = b.booking_id
          LEFT JOIN bill bl ON bl.booking_id = b.booking_id
         WHERE b.status = 'completed' AND (s.end_pct IS NULL OR bl.bill_id IS NULL)"""),
    ("Charging booking without an open session",
     """SELECT b.booking_id FROM booking b LEFT JOIN charging_session s ON s.booking_id = b.booking_id
         WHERE b.status = 'charging' AND (s.booking_id IS NULL OR s.end_pct IS NOT NULL)"""),
    ("Session on a booking that never reached charging",
     """SELECT s.booking_id, b.status FROM charging_session s JOIN booking b ON b.booking_id = s.booking_id
         WHERE b.status NOT IN ('charging','completed')"""),
    ("Charger 'occupied' flag disagrees with charging bookings",
     """SELECT c.charger_id, c.status FROM charger c
         WHERE (c.status = 'occupied') <>
               EXISTS (SELECT 1 FROM booking b WHERE b.charger_id = c.charger_id AND b.status = 'charging')
           AND c.status IN ('available','occupied')"""),
    ("Session battery snapshot differs from the vehicle model",
     """SELECT s.booking_id, s.battery_kwh, m.battery_kwh AS model_kwh
          FROM charging_session s JOIN booking b ON b.booking_id = s.booking_id
          JOIN vehicle v ON v.vehicle_id = b.vehicle_id JOIN vehicle_model m ON m.model_id = v.model_id
         WHERE s.battery_kwh <> m.battery_kwh"""),
    ("Booking vehicle not owned by booking customer",
     "SELECT b.booking_id FROM booking b JOIN vehicle v ON v.vehicle_id = b.vehicle_id WHERE v.user_id <> b.customer_id"),
    ("Charger that is not a home AC set-up (same rule as chk_charger_setup)",
     """SELECT c.charger_id, ct.code, c.power_kw, c.parking_size FROM charger c
          JOIN connector_type ct ON ct.connector_id = c.connector_id
         WHERE NOT ((ct.code = 'TYPE2' AND c.power_kw IN (3.3, 7.4, 11, 22))
                 OR (ct.code = 'IND_SOCKET' AND c.power_kw IN (2.2, 3.3))
                 OR (ct.code = 'BHARAT_AC001' AND c.power_kw = 3.3)
                 OR (ct.code = 'LECCS' AND c.power_kw IN (1.5, 3.0) AND c.parking_size IN ('2W', '3W')))"""),
    ("Booking with an incompatible plug or parking bay (fn_compat_reason)",
     "SELECT booking_id, fn_compat_reason(charger_id, vehicle_id) AS reason FROM booking "
     "WHERE fn_compat_reason(charger_id, vehicle_id) IS NOT NULL"),
    ("Booking on a charger that is not APPROVED (active statuses)",
     """SELECT b.booking_id, c.approval FROM booking b JOIN charger c ON c.charger_id = b.charger_id
         WHERE c.approval <> 'APPROVED' AND b.status IN ('requested','accepted','charging')"""),
    ("Charger label shorter than 3 characters (same rule as chk_charger_label)",
     "SELECT charger_id, label FROM charger WHERE CHAR_LENGTH(TRIM(label)) < 3"),
    ("Duplicate amenity names (ignoring case and spaces)",
     """SELECT LOWER(REPLACE(name, ' ', '')) AS name_key, COUNT(*) AS n FROM amenity
         GROUP BY name_key HAVING COUNT(*) > 1"""),
]


def main():
    conn = db.connect()
    failures = 0
    print("ChargeMatch Lite — integrity checks (database: chargematch_lite)\n")
    for title, sql in CHECKS:
        rows = db.query(sql, conn=conn)
        if rows:
            failures += 1
            print(f"  FAIL  {title}  ({len(rows)} row(s))")
            for r in rows[:10]:
                print("          ", dict(r))
        else:
            print(f"  ok    {title}")

    totals = db.query("""SELECT (SELECT COUNT(*) FROM booking) bookings,
                                (SELECT COUNT(*) FROM bill) bills,
                                (SELECT IFNULL(SUM(amount),0) FROM bill WHERE status='PAID') paid_total""",
                      one=True, conn=conn)
    conn.close()
    print(f"\n{len(CHECKS) - failures}/{len(CHECKS)} checks passed. "
          f"bookings={totals['bookings']} bills={totals['bills']} paid=₹{totals['paid_total']}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
