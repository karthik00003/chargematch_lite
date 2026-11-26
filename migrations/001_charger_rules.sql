-- =====================================================================
--  ChargeMatch Lite — migration 001: home-charger rules (2026-11-25)
--      mysql -u root chargematch_lite < migrations/001_charger_rules.sql
--  (never names a database; run it once, after a mysqldump backup)
--
--  * charger gets phase, parking_size, cable_provided
--  * the 20 demo chargers are set to valid AC set-ups (same values as seed.sql):
--    the three DC/CCS2 rows and the Type 1 row become AC chargers; the ids,
--    bookings, sessions, bills and ratings stay as they are
--  * the Nissan Leaf also takes the 15A socket (its portable charger)
--  * new fn_charger_problem + trg_charger_bi / trg_charger_bu,
--    fn_compat_reason also checks the parking bay, v_searchable_chargers
--    shows the new columns
-- =====================================================================
SET NAMES utf8mb4;

ALTER TABLE charger
    ADD COLUMN phase          TINYINT      NOT NULL DEFAULT 1 COMMENT '1- or 3-phase AC supply' AFTER connector_id,
    ADD COLUMN parking_size   ENUM('2W','3W','4W') NOT NULL DEFAULT '4W' COMMENT 'Largest vehicle the parking bay fits' AFTER power_kw,
    ADD COLUMN cable_provided TINYINT(1)   NOT NULL DEFAULT 0 COMMENT '1 = cable attached; 0 = customer brings one' AFTER parking_size,
    COMMENT = 'One physical home charging point (AC only, rules in fn_charger_problem). Must be APPROVED before it is searchable.';

-- set-ups from seed.sql (charger_id, label, connector, phase, kW, bay, cable)
UPDATE charger c
  JOIN (VALUES
        ROW(1,  'Bay A',        1, 1,  7.4, '4W', 1), ROW(2,  'Bay B',        2, 1,  3.3, '4W', 0),
        ROW(3,  'Garage',       1, 3, 11.0, '4W', 1), ROW(4,  'Scooter Point',4, 1,  3.0, '2W', 1),
        ROW(5,  'Wallbox 22',   1, 3, 22.0, '4W', 1), ROW(6,  'AC Slow',      1, 1,  7.4, '4W', 1),
        ROW(7,  'Porch',        2, 1,  3.3, '3W', 0), ROW(8,  'Driveway',     5, 1,  3.3, '4W', 0),
        ROW(9,  'Main',         1, 1,  7.4, '4W', 1), ROW(10, 'Bay 2',        1, 3, 11.0, '4W', 1),
        ROW(11, 'Gate 1',       1, 1,  7.4, '4W', 1), ROW(12, '3-Pin',        2, 1,  3.3, '3W', 0),
        ROW(13, 'Bay 1',        1, 1,  7.4, '4W', 1), ROW(14, 'Bay 2',        2, 1,  3.3, '4W', 0),
        ROW(15, 'Garden',       2, 1,  3.3, '2W', 0), ROW(16, 'Beach Bay',    1, 3, 22.0, '4W', 1),
        ROW(17, 'Hostel Lane',  2, 1,  3.3, '2W', 0), ROW(18, 'Car Bay',      1, 3, 11.0, '4W', 0),
        ROW(19, 'Basement',     1, 1,  7.4, '4W', 1), ROW(20, 'Scooter Dock', 4, 1,  3.0, '2W', 1)
       ) AS v (charger_id, label, connector_id, phase, power_kw, parking_size, cable_provided)
    ON v.charger_id = c.charger_id
   SET c.label = v.label, c.connector_id = v.connector_id, c.phase = v.phase, c.power_kw = v.power_kw,
       c.parking_size = v.parking_size, c.cable_provided = v.cable_provided;
UPDATE charger SET price_per_kwh = 14.00 WHERE charger_id = 10;
UPDATE charger SET review_note = 'No electrical safety certificate for a 22 kW 3-phase wallbox; please resubmit with it.'
 WHERE charger_id = 16;

INSERT IGNORE INTO model_connector (model_id, connector_id) VALUES (12, 2);   -- Leaf: portable 15A charger
UPDATE rating SET comment = 'The 22 kW wallbox really is fast!'           WHERE booking_id = 3 AND comment = 'Fast DC really is fast!';
UPDATE rating SET comment = 'Socket is far from the bay, had to re-park.' WHERE booking_id = 8 AND comment = 'Cable was short, had to re-park twice.';

DROP FUNCTION IF EXISTS fn_compat_reason;
DROP FUNCTION IF EXISTS fn_charger_problem;
DROP TRIGGER  IF EXISTS trg_charger_bi;
DROP TRIGGER  IF EXISTS trg_charger_bu;

DELIMITER $$

-- fn_compat_reason: NULL when the vehicle can use the charger, otherwise a
-- human-readable reason. Two rules: (1) the vehicle's model accepts the
-- charger's plug, (2) the vehicle fits the parking bay (2W < 3W < 4W: a car
-- can't use a two-wheeler bay, a scooter can use a car bay). Used by search
-- (WHERE ... IS NULL) and by trg_booking_bi (refuses with the same message).
CREATE FUNCTION fn_compat_reason(p_charger_id INT, p_vehicle_id INT)
RETURNS VARCHAR(255)
READS SQL DATA
BEGIN
    DECLARE v_conn      INT;
    DECLARE v_code      VARCHAR(20);
    DECLARE v_bay       VARCHAR(2);
    DECLARE v_model     INT;
    DECLARE v_class     VARCHAR(2);
    DECLARE v_mname     VARCHAR(110);
    DECLARE v_supported VARCHAR(200);

    SELECT c.connector_id, ct.code, c.parking_size INTO v_conn, v_code, v_bay
      FROM charger c JOIN connector_type ct ON ct.connector_id = c.connector_id
     WHERE c.charger_id = p_charger_id;
    IF v_conn IS NULL THEN RETURN 'Charger not found.'; END IF;

    SELECT v.model_id, vm.vehicle_class, CONCAT(vm.make, ' ', vm.model_name)
      INTO v_model, v_class, v_mname
      FROM vehicle v JOIN vehicle_model vm ON vm.model_id = v.model_id
     WHERE v.vehicle_id = p_vehicle_id;
    IF v_model IS NULL THEN RETURN 'Vehicle not found.'; END IF;

    IF NOT EXISTS (SELECT 1 FROM model_connector
                    WHERE model_id = v_model AND connector_id = v_conn) THEN
        SELECT GROUP_CONCAT(ct.code ORDER BY ct.code SEPARATOR ', ') INTO v_supported
          FROM model_connector mc JOIN connector_type ct ON ct.connector_id = mc.connector_id
         WHERE mc.model_id = v_model;
        RETURN CONCAT('Plug mismatch: your ', v_mname, ' takes ',
                      IFNULL(v_supported, 'no listed plug'),
                      ' but this charger has ', v_code, '.');
    END IF;

    IF FIELD(v_class, '2W', '3W', '4W') > FIELD(v_bay, '2W', '3W', '4W') THEN
        RETURN CONCAT('Parking bay is for ', v_bay, ', your ', v_mname, ' is ', v_class, '.');
    END IF;
    RETURN NULL;                                       -- compatible
END$$

-- fn_charger_problem: the home-charger rules in ONE place (the same rules as
-- the original ChargeMatch's charger_rule + charger_power_option data).
-- Returns NULL when the set-up is valid, otherwise the message to show.
-- trg_charger_bi / trg_charger_bu SIGNAL that message, so the database refuses
-- an invalid charger even when the web form is bypassed.
--   * AC only: Type 2, 15A socket (IND_SOCKET), Bharat AC-001 or LECCS
--     (no CCS2 / CHAdeMO / DC, no Type 1)
--   * Type 2      1-phase 3.3 or 7.4 kW · 3-phase 11 or 22 kW · 3W / 4W bays
--   * 15A socket  1-phase 1.0–3.3 kW (0.1 kW steps) · any bay · no cable
--   * Bharat AC-001 1-phase 1.0–3.3 kW (0.1 kW steps) · any bay · no cable
--   * LECCS       1-phase 0.5–3.3 kW (0.1 kW steps) · 2W / 3W bays only
--   * price ₹5–30 per kWh
CREATE FUNCTION fn_charger_problem(p_connector INT, p_phase TINYINT, p_kw DECIMAL(5,1),
                                   p_bay VARCHAR(2), p_cable TINYINT, p_price DECIMAL(5,2))
RETURNS VARCHAR(200)
READS SQL DATA
BEGIN
    DECLARE v_code   VARCHAR(20);
    DECLARE v_type   VARCHAR(2);
    DECLARE v_name   VARCHAR(30);
    DECLARE v_min_kw DECIMAL(5,1);
    DECLARE v_bays   VARCHAR(10);

    SELECT code, current_type INTO v_code, v_type
      FROM connector_type WHERE connector_id = p_connector;
    SET v_name = CASE v_code WHEN 'TYPE2' THEN 'Type 2' WHEN 'IND_SOCKET' THEN '15A socket'
                             WHEN 'BHARAT_AC001' THEN 'Bharat AC-001' WHEN 'TYPE1' THEN 'Type 1'
                             ELSE IFNULL(v_code, 'This connector') END;

    IF v_code IS NULL OR v_type <> 'AC' THEN
        RETURN CONCAT(v_name, ' can''t be listed: home chargers are AC only ',
                      '(Type 2, 15A socket, Bharat AC-001 or LECCS)');
    END IF;
    IF v_code NOT IN ('TYPE2', 'IND_SOCKET', 'BHARAT_AC001', 'LECCS') THEN
        RETURN CONCAT(v_name, ' can''t be listed: a home charger is Type 2, ',
                      '15A socket, Bharat AC-001 or LECCS');
    END IF;

    IF p_phase IS NULL OR p_phase NOT IN (1, 3) THEN
        RETURN 'Phase must be 1 or 3';
    END IF;
    IF p_phase = 3 AND v_code <> 'TYPE2' THEN
        RETURN CONCAT(v_name, ' is single-phase only');
    END IF;

    IF v_code = 'TYPE2' THEN
        IF p_phase = 1 AND (p_kw IS NULL OR p_kw NOT IN (3.3, 7.4)) THEN
            RETURN 'Type 2 1-phase must be 3.3 or 7.4 kW';
        END IF;
        IF p_phase = 3 AND (p_kw IS NULL OR p_kw NOT IN (11, 22)) THEN
            RETURN 'Type 2 3-phase must be 11 or 22 kW';
        END IF;
    ELSE
        SET v_min_kw = IF(v_code = 'LECCS', 0.5, 1.0);
        IF p_kw IS NULL OR p_kw < v_min_kw OR p_kw > 3.3 THEN
            RETURN CONCAT(v_name, ' 1-phase must be ', v_min_kw, '–3.3 kW (0.1 kW steps)');
        END IF;
    END IF;

    SET v_bays = CASE v_code WHEN 'TYPE2' THEN '3W,4W' WHEN 'LECCS' THEN '2W,3W' ELSE '2W,3W,4W' END;
    IF p_bay IS NULL OR NOT FIND_IN_SET(p_bay, v_bays) THEN
        RETURN CONCAT(v_name, ' can''t be on a ', IFNULL(p_bay, '?'), ' parking bay: it is for ',
                      REPLACE(v_bays, ',', ' / '), ' bays only');
    END IF;

    IF p_cable IS NULL OR p_cable NOT IN (0, 1) THEN
        RETURN 'Cable attached must be 0 (no) or 1 (yes)';
    END IF;
    IF p_cable = 1 AND v_code IN ('IND_SOCKET', 'BHARAT_AC001') THEN
        RETURN CONCAT('A ', v_name, ' is a bare socket, so it can''t have a cable attached');
    END IF;

    IF p_price IS NULL OR p_price < 5 OR p_price > 30 THEN
        RETURN 'Price must be between ₹5 and ₹30 per kWh';
    END IF;
    RETURN NULL;
END$$

-- 7) trg_charger_bi / 8) trg_charger_bu: a charger must be a valid home-charger
--    set-up (fn_charger_problem). Checked on every INSERT and UPDATE, so a
--    direct SQL statement can't store a DC charger, a wrong kW value, a LECCS
--    plug on a car bay or a socket "with cable" either.
CREATE TRIGGER trg_charger_bi
BEFORE INSERT ON charger
FOR EACH ROW
BEGIN
    DECLARE v_msg VARCHAR(200);
    SET v_msg = fn_charger_problem(NEW.connector_id, NEW.phase, NEW.power_kw,
                                   NEW.parking_size, NEW.cable_provided, NEW.price_per_kwh);
    IF v_msg IS NOT NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;
END$$

CREATE TRIGGER trg_charger_bu
BEFORE UPDATE ON charger
FOR EACH ROW
BEGIN
    DECLARE v_msg VARCHAR(200);
    SET v_msg = fn_charger_problem(NEW.connector_id, NEW.phase, NEW.power_kw,
                                   NEW.parking_size, NEW.cable_provided, NEW.price_per_kwh);
    IF v_msg IS NOT NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;
END$$

DELIMITER ;

CREATE OR REPLACE VIEW v_searchable_chargers AS
SELECT c.charger_id, c.label, c.phase, c.power_kw, c.parking_size, c.cable_provided, c.price_per_kwh,
       ct.connector_id, ct.code AS connector_code, ct.current_type,
       l.listing_id, l.name AS listing_name, l.address, l.city,
       l.latitude, l.longitude, l.open_time, l.close_time,
       u.user_id AS host_id, u.name AS host_name, u.phone AS host_phone,
       fn_charger_status(c.charger_id) AS live_status
  FROM charger c
  JOIN connector_type ct ON ct.connector_id = c.connector_id
  JOIN listing l         ON l.listing_id    = c.listing_id
  JOIN users u           ON u.user_id       = l.host_id
 WHERE c.approval = 'APPROVED'
   AND u.status   = 'ACTIVE';
