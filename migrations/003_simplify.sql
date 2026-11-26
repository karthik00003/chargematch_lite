-- =====================================================================
--  ChargeMatch Lite — migration 003: simpler DBMS part (2026-11-26)
--      mysql -u root chargematch_lite < migrations/003_simplify.sql
--  (never names a database; run once, after a mysqldump backup)
--
--  * booking.parent_booking_id (rebook link) removed
--  * charger.phase and charger.cable_provided removed; the charger rules are
--    one CHECK (chk_charger_setup) instead of fn_charger_problem + 2 triggers
--  * fn_charger_status removed (a CASE in v_searchable_chargers / in Flask)
--  * procedures start_session and mark_bill_paid removed (plain SQL in Flask)
--  Result: 13 tables, 3 views, 6 triggers, 1 function, 2 procedures.
--  Every existing row is kept.
-- =====================================================================
SET NAMES utf8mb4;

DROP TRIGGER   IF EXISTS trg_charger_bi;
DROP TRIGGER   IF EXISTS trg_charger_bu;
DROP TRIGGER   IF EXISTS trg_booking_bu;
DROP FUNCTION  IF EXISTS fn_charger_problem;
DROP PROCEDURE IF EXISTS start_session;
DROP PROCEDURE IF EXISTS mark_bill_paid;
DROP VIEW      IF EXISTS v_searchable_chargers;      -- it used fn_charger_status and the dropped columns
DROP FUNCTION  IF EXISTS fn_charger_status;

ALTER TABLE booking
    DROP FOREIGN KEY fk_booking_parent,
    DROP COLUMN parent_booking_id;

ALTER TABLE charger
    DROP COLUMN phase,
    DROP COLUMN cable_provided,
    DROP CHECK chk_charger_power,
    ADD CONSTRAINT chk_charger_setup   CHECK (
           (connector_id = 1 AND power_kw IN (3.3, 7.4, 11.0, 22.0))      -- Type 2 (11 / 22 kW = 3-phase)
        OR (connector_id = 2 AND power_kw IN (2.2, 3.3))                  -- 15A socket
        OR (connector_id = 5 AND power_kw = 3.3)                          -- Bharat AC-001
        OR (connector_id = 4 AND power_kw IN (1.5, 3.0)
                             AND parking_size IN ('2W', '3W'))),          -- LECCS: light EVs only
    COMMENT = 'One physical home charging point (AC only, rules in chk_charger_setup). Must be APPROVED before it is searchable.';

DELIMITER $$

-- 2) trg_booking_bu: the booking state machine.
--    requested -> accepted | declined | cancelled
--    accepted  -> charging | cancelled
--    charging  -> completed
--    Slot details are frozen after creation (cancel and book again instead).
CREATE TRIGGER trg_booking_bu
BEFORE UPDATE ON booking
FOR EACH ROW
BEGIN
    DECLARE v_msg VARCHAR(255);

    IF NEW.customer_id <> OLD.customer_id OR NEW.vehicle_id <> OLD.vehicle_id
       OR NEW.charger_id <> OLD.charger_id OR NEW.start_time <> OLD.start_time
       OR NEW.end_time <> OLD.end_time THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Booking details cannot be changed after creation. Cancel and book again instead.';
    END IF;

    IF NEW.status <> OLD.status THEN
        IF NOT (   (OLD.status = 'requested' AND NEW.status IN ('accepted', 'declined', 'cancelled'))
                OR (OLD.status = 'accepted'  AND NEW.status IN ('charging', 'cancelled'))
                OR (OLD.status = 'charging'  AND NEW.status = 'completed') ) THEN
            SET v_msg = CONCAT('A booking cannot go from ', OLD.status, ' to ', NEW.status, '.');
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
        END IF;

        -- charging needs an open session; completed needs a finished one
        IF NEW.status = 'charging' AND NOT EXISTS
           (SELECT 1 FROM charging_session WHERE booking_id = NEW.booking_id AND end_pct IS NULL) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Start a charging session to move a booking to charging.';
        END IF;
        IF NEW.status = 'completed' AND NOT EXISTS
           (SELECT 1 FROM charging_session WHERE booking_id = NEW.booking_id AND end_pct IS NOT NULL) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'End the charging session to complete a booking.';
        END IF;

        IF NEW.status IN ('cancelled', 'declined') AND NEW.cancel_reason IS NULL THEN
            SET NEW.cancel_reason = IF(NEW.status = 'cancelled', 'Cancelled by customer', 'Declined by host');
        END IF;
    END IF;
END$$

DELIMITER ;

CREATE OR REPLACE VIEW v_searchable_chargers AS
SELECT c.charger_id, c.label, c.power_kw, c.parking_size, c.price_per_kwh,
       ct.connector_id, ct.code AS connector_code, ct.current_type,
       l.listing_id, l.name AS listing_name, l.address, l.city,
       l.latitude, l.longitude, l.open_time, l.close_time,
       u.user_id AS host_id, u.name AS host_name, u.phone AS host_phone,
       -- live status word (approval is already APPROVED here); 'occupied' is kept in step with sessions by
       -- trg_booking_au, so it means a car is charging right now
       CASE c.status WHEN 'faulty'   THEN 'faulty'
                     WHEN 'offline'  THEN 'offline'
                     WHEN 'occupied' THEN 'in_use'
                     ELSE 'available' END AS live_status
  FROM charger c
  JOIN connector_type ct ON ct.connector_id = c.connector_id
  JOIN listing l         ON l.listing_id    = c.listing_id
  JOIN users u           ON u.user_id       = l.host_id
 WHERE c.approval = 'APPROVED'
   AND u.status   = 'ACTIVE';
