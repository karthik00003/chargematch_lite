-- =====================================================================
--  ChargeMatch Lite  —  schema.sql
--  Peer-to-peer rental of private home EV chargers.
--
--  Load with the database named explicitly (this file never names it):
--      mysql -u root chargematch_lite < schema.sql
--
--  Order:  1) 12 tables   2) 1 function   3) 5 triggers
--          4) 2 procedures   5) 2 views
--  Engine InnoDB, charset utf8mb4 everywhere.
-- =====================================================================

SET NAMES utf8mb4;

-- =====================================================================
-- 1. TABLES
-- =====================================================================

-- ---------- Admin-managed master data --------------------------------

CREATE TABLE users (
    user_id        INT          NOT NULL AUTO_INCREMENT,
    name           VARCHAR(80)  NOT NULL,
    email          VARCHAR(120) NOT NULL,
    password_hash  VARCHAR(255) NOT NULL COMMENT 'Werkzeug scrypt hash, never plain text',
    role           ENUM('ADMIN','HOST','CUSTOMER') NOT NULL,
    status         ENUM('ACTIVE','DISABLED') NOT NULL DEFAULT 'ACTIVE',
    created_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_users        PRIMARY KEY (user_id),
    CONSTRAINT uq_users_email  UNIQUE (email),
    CONSTRAINT chk_users_email CHECK (email LIKE '%_@_%._%')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  COMMENT='Every person who logs in: one admin, hosts (charger owners) and customers (EV drivers).';

CREATE TABLE connector_type (
    connector_id   INT          NOT NULL AUTO_INCREMENT,
    code           VARCHAR(20)  NOT NULL COMMENT 'Short plug code e.g. TYPE2, CCS2',
    description    VARCHAR(150) NOT NULL,
    current_type   ENUM('AC','DC') NOT NULL,
    CONSTRAINT pk_connector_type PRIMARY KEY (connector_id),
    CONSTRAINT uq_connector_code UNIQUE (code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  COMMENT='Lookup of plug standards used in India. A charger has exactly one plug type.';

CREATE TABLE amenity (
    amenity_id     INT          NOT NULL AUTO_INCREMENT,
    name           VARCHAR(50)  NOT NULL,
    icon           VARCHAR(10)  NOT NULL COMMENT 'Emoji shown in the UI',
    CONSTRAINT pk_amenity      PRIMARY KEY (amenity_id),
    CONSTRAINT uq_amenity_name UNIQUE (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  COMMENT='Lookup of facilities a host can offer at a listing (parking, Wi-Fi, ...).';

-- ---------- Host side -------------------------------------------------

CREATE TABLE listing (
    listing_id     INT          NOT NULL AUTO_INCREMENT,
    host_id        INT          NOT NULL,
    name           VARCHAR(100) NOT NULL,
    address        VARCHAR(200) NOT NULL,
    city           VARCHAR(50)  NOT NULL,
    latitude       DECIMAL(9,6) NOT NULL,
    longitude      DECIMAL(9,6) NOT NULL,
    open_time      TIME         NOT NULL,
    close_time     TIME         NOT NULL,
    created_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_listing       PRIMARY KEY (listing_id),
    CONSTRAINT fk_listing_host  FOREIGN KEY (host_id) REFERENCES users(user_id)
        ON DELETE RESTRICT,     -- keep history: disable a host instead of deleting
    CONSTRAINT chk_listing_lat   CHECK (latitude  BETWEEN -90  AND 90),
    CONSTRAINT chk_listing_lng   CHECK (longitude BETWEEN -180 AND 180),
    CONSTRAINT chk_listing_hours CHECK (open_time < close_time),
    INDEX idx_listing_city (city)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  COMMENT='A host''s location (home / garage) with map pin and daily opening hours.';

CREATE TABLE listing_amenity (
    listing_id     INT          NOT NULL,
    amenity_id     INT          NOT NULL,
    note           VARCHAR(100) NULL COMMENT 'Optional detail, e.g. "2 cars"',
    CONSTRAINT pk_listing_amenity PRIMARY KEY (listing_id, amenity_id),
    CONSTRAINT fk_la_listing FOREIGN KEY (listing_id) REFERENCES listing(listing_id)
        ON DELETE CASCADE,
    CONSTRAINT fk_la_amenity FOREIGN KEY (amenity_id) REFERENCES amenity(amenity_id)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  COMMENT='Many-to-many bridge: which amenities each listing offers.';

CREATE TABLE charger (
    charger_id     INT          NOT NULL AUTO_INCREMENT,
    listing_id     INT          NOT NULL,
    label          VARCHAR(40)  NOT NULL COMMENT 'Host''s name for the point, unique within a listing',
    connector_id   INT          NOT NULL,
    power_kw       DECIMAL(5,1) NOT NULL,
    parking_size   ENUM('2W','3W','4W') NOT NULL DEFAULT '4W' COMMENT 'Largest vehicle the parking bay fits',
    price_per_kwh  DECIMAL(5,2) NOT NULL COMMENT 'Rupees per kWh',
    status         ENUM('available','occupied','faulty','offline') NOT NULL DEFAULT 'available',
    approval       ENUM('PENDING','APPROVED','REJECTED') NOT NULL DEFAULT 'PENDING',
    reviewed_by    INT          NULL COMMENT 'Admin who approved/rejected',
    review_note    VARCHAR(200) NULL,
    CONSTRAINT pk_charger          PRIMARY KEY (charger_id),
    CONSTRAINT uq_charger_label    UNIQUE (listing_id, label),
    CONSTRAINT fk_charger_listing  FOREIGN KEY (listing_id)   REFERENCES listing(listing_id)
        ON DELETE CASCADE,      -- blocked anyway if the charger has bookings (booking FK is RESTRICT)
    CONSTRAINT fk_charger_conn     FOREIGN KEY (connector_id) REFERENCES connector_type(connector_id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_charger_reviewer FOREIGN KEY (reviewed_by)  REFERENCES users(user_id)
        ON DELETE SET NULL,
    -- Home chargers are AC only. Each plug has a short list of power values (the form's dropdown), and a LECCS
    -- plug is for 2W / 3W bays only. A CHECK can't look up connector_type, so it uses the connector ids that
    -- seed.sql fixes:
    --   1 = TYPE2         (allowed)          2 = IND_SOCKET (15A socket, allowed)
    --   3 = CCS2          (DC: not allowed)  4 = LECCS        (allowed, 2W / 3W bays only)
    --   5 = BHARAT_AC001  (allowed)          6 = TYPE1        (imported AC plug: not allowed)
    --   7 = CHADEMO       (DC: not allowed)  8 = BHARAT_DC001 (DC: not allowed)
    CONSTRAINT chk_charger_setup   CHECK (
           (connector_id = 1 AND power_kw IN (3.3, 7.4, 11.0, 22.0))      -- Type 2 (11 / 22 kW = 3-phase)
        OR (connector_id = 2 AND power_kw IN (2.2, 3.3))                  -- 15A socket
        OR (connector_id = 5 AND power_kw = 3.3)                          -- Bharat AC-001
        OR (connector_id = 4 AND power_kw IN (1.5, 3.0)
                             AND parking_size IN ('2W', '3W'))),          -- LECCS: light EVs only
    CONSTRAINT chk_charger_price   CHECK (price_per_kwh BETWEEN 5 AND 30),
    -- the host types the label (nothing is auto-generated): at least 3 characters, unique per listing (uq_charger_label)
    CONSTRAINT chk_charger_label   CHECK (CHAR_LENGTH(TRIM(label)) >= 3)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  COMMENT='One physical home charging point (AC only, rules in chk_charger_setup). Must be APPROVED before it is searchable.';

-- ---------- Customer side ---------------------------------------------

CREATE TABLE vehicle_model (
    model_id       INT          NOT NULL AUTO_INCREMENT,
    make           VARCHAR(40)  NOT NULL,
    model_name     VARCHAR(60)  NOT NULL,
    vehicle_class  ENUM('2W','3W','4W') NOT NULL,
    battery_kwh    DECIMAL(5,2) NOT NULL,
    CONSTRAINT pk_vehicle_model  PRIMARY KEY (model_id),
    CONSTRAINT uq_make_model     UNIQUE (make, model_name),
    CONSTRAINT chk_model_battery CHECK (battery_kwh > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  COMMENT='Catalogue of EV models with battery size; customers pick from this list.';

CREATE TABLE model_connector (
    model_id       INT          NOT NULL,
    connector_id   INT          NOT NULL,
    CONSTRAINT pk_model_connector PRIMARY KEY (model_id, connector_id),
    CONSTRAINT fk_mc_model FOREIGN KEY (model_id)     REFERENCES vehicle_model(model_id)
        ON DELETE CASCADE,
    CONSTRAINT fk_mc_conn  FOREIGN KEY (connector_id) REFERENCES connector_type(connector_id)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  COMMENT='Many-to-many bridge: which plug types each vehicle model accepts.';

CREATE TABLE vehicle (
    vehicle_id     INT          NOT NULL AUTO_INCREMENT,
    user_id        INT          NOT NULL,
    model_id       INT          NOT NULL,
    reg_no         VARCHAR(12)  NOT NULL COMMENT 'Indian number plate without spaces, e.g. KA19MN1234',
    CONSTRAINT pk_vehicle        PRIMARY KEY (vehicle_id),
    CONSTRAINT uq_vehicle_reg    UNIQUE (reg_no),
    CONSTRAINT fk_vehicle_user   FOREIGN KEY (user_id)  REFERENCES users(user_id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_vehicle_model  FOREIGN KEY (model_id) REFERENCES vehicle_model(model_id)
        ON DELETE RESTRICT,
    CONSTRAINT chk_vehicle_reg   CHECK (REGEXP_LIKE(reg_no, '^[A-Z]{2}[0-9]{2}[A-Z]{1,3}[0-9]{4}$', 'c'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  COMMENT='A customer''s actual vehicle (one model, one registration number).';

CREATE TABLE booking (
    booking_id        INT          NOT NULL AUTO_INCREMENT,
    customer_id       INT          NOT NULL,
    vehicle_id        INT          NOT NULL,
    charger_id        INT          NOT NULL,
    start_time        DATETIME     NOT NULL,
    end_time          DATETIME     NOT NULL,
    status            ENUM('requested','accepted','declined','charging','completed','cancelled')
                                   NOT NULL DEFAULT 'requested',
    cancel_reason     VARCHAR(200) NULL COMMENT 'Why it was cancelled or declined',
    created_at        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_booking          PRIMARY KEY (booking_id),
    CONSTRAINT fk_booking_customer FOREIGN KEY (customer_id) REFERENCES users(user_id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_booking_vehicle  FOREIGN KEY (vehicle_id)  REFERENCES vehicle(vehicle_id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_booking_charger  FOREIGN KEY (charger_id)  REFERENCES charger(charger_id)
        ON DELETE RESTRICT,
    CONSTRAINT chk_booking_order    CHECK (end_time > start_time),
    CONSTRAINT chk_booking_duration CHECK (TIMESTAMPDIFF(MINUTE, start_time, end_time) BETWEEN 15 AND 720),
    INDEX idx_booking_slot (charger_id, status, start_time, end_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  COMMENT='A customer''s request for a time slot on a charger. Life cycle enforced by triggers.';

CREATE TABLE charging_session (
    booking_id     INT          NOT NULL,
    start_pct      TINYINT UNSIGNED NOT NULL COMMENT 'Battery % when plugged in',
    end_pct        TINYINT UNSIGNED NULL     COMMENT 'Battery % when unplugged; NULL while charging',
    battery_kwh    DECIMAL(5,2) NOT NULL COMMENT 'Snapshot of the model battery size at start',
    started_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ended_at       DATETIME     NULL,
    CONSTRAINT pk_charging_session PRIMARY KEY (booking_id),
    CONSTRAINT fk_session_booking  FOREIGN KEY (booking_id) REFERENCES booking(booking_id)
        ON DELETE CASCADE,
    CONSTRAINT chk_session_start   CHECK (start_pct BETWEEN 0 AND 100),
    CONSTRAINT chk_session_end     CHECK (end_pct IS NULL OR (end_pct > start_pct AND end_pct <= 100)),
    CONSTRAINT chk_session_ended   CHECK ((end_pct IS NULL) = (ended_at IS NULL)),
    CONSTRAINT chk_session_battery CHECK (battery_kwh > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  COMMENT='1:1 with booking: the actual charging that happened (start/end battery %).';

CREATE TABLE bill (
    bill_id        INT          NOT NULL AUTO_INCREMENT,
    booking_id     INT          NOT NULL,
    kwh            DECIMAL(7,2) NOT NULL COMMENT '(end% - start%) / 100 x battery_kwh',
    rate           DECIMAL(5,2) NOT NULL COMMENT 'Snapshot of charger price_per_kwh',
    amount         DECIMAL(9,2) NOT NULL COMMENT 'kwh x rate, rupees',
    status         ENUM('PAYMENT_PENDING','PAID') NOT NULL DEFAULT 'PAYMENT_PENDING',
    generated_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    paid_at        DATETIME     NULL,
    CONSTRAINT pk_bill          PRIMARY KEY (bill_id),
    CONSTRAINT uq_bill_booking  UNIQUE (booking_id),
    CONSTRAINT fk_bill_booking  FOREIGN KEY (booking_id) REFERENCES booking(booking_id)
        ON DELETE RESTRICT,     -- money records are never deleted with a booking
    CONSTRAINT chk_bill_values  CHECK (kwh >= 0 AND amount >= 0 AND rate > 0),
    CONSTRAINT chk_bill_paid    CHECK ((status = 'PAID') = (paid_at IS NOT NULL)),
    CONSTRAINT chk_bill_paid_after CHECK (paid_at IS NULL OR paid_at >= generated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  COMMENT='Generated automatically (trigger) when a session ends. Amounts are frozen.';


-- =====================================================================
-- 2. FUNCTION
-- =====================================================================
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

-- =====================================================================
-- 3. TRIGGERS
-- =====================================================================

-- 1) trg_booking_bi: every rule a new booking must satisfy.
--    SEED BYPASS: seed.sql (run as root) sets @cm_seed_bypass = 1 so it can
--    insert *historical* bookings. The bypass skips ONLY the two clock rules
--    (start in future, inside opening hours) and only for the MySQL user root;
--    ownership, approval, plug, overlap and status rules always apply.
CREATE TRIGGER trg_booking_bi
BEFORE INSERT ON booking
FOR EACH ROW
BEGIN
    DECLARE v_owner    INT;
    DECLARE v_approval VARCHAR(10);
    DECLARE v_cstatus  VARCHAR(10);
    DECLARE v_open     TIME;
    DECLARE v_close    TIME;
    DECLARE v_reason   VARCHAR(255);
    DECLARE v_clash    INT DEFAULT 0;
    DECLARE v_msg      VARCHAR(255);
    DECLARE v_bypass   BOOLEAN DEFAULT
        (IFNULL(@cm_seed_bypass, 0) = 1 AND SUBSTRING_INDEX(USER(), '@', 1) = 'root');

    IF NEW.status <> 'requested' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A new booking must start in status requested.';
    END IF;

    IF NOT v_bypass AND NEW.start_time <= NOW() THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Booking start time must be in the future.';
    END IF;

    SELECT user_id INTO v_owner FROM vehicle WHERE vehicle_id = NEW.vehicle_id;
    IF v_owner IS NULL OR v_owner <> NEW.customer_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This vehicle does not belong to you.';
    END IF;

    SELECT c.approval, c.status, l.open_time, l.close_time
      INTO v_approval, v_cstatus, v_open, v_close
      FROM charger c JOIN listing l ON l.listing_id = c.listing_id
     WHERE c.charger_id = NEW.charger_id;
    IF v_approval IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Charger not found.';
    END IF;
    IF v_approval <> 'APPROVED' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This charger is not approved by the admin yet.';
    END IF;
    IF v_cstatus NOT IN ('available', 'occupied') THEN
        SET v_msg = CONCAT('This charger is ', v_cstatus, ' right now and cannot be booked.');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    IF NOT v_bypass AND (DATE(NEW.start_time) <> DATE(NEW.end_time)
                         OR TIME(NEW.start_time) < v_open
                         OR TIME(NEW.end_time)   > v_close) THEN
        SET v_msg = CONCAT('The slot must be on one day within opening hours (',
                           TIME_FORMAT(v_open, '%H:%i'), ' - ', TIME_FORMAT(v_close, '%H:%i'), ').');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    SET v_reason = fn_compat_reason(NEW.charger_id, NEW.vehicle_id);
    IF v_reason IS NOT NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_reason;
    END IF;

    -- Two intervals overlap when  start1 < end2  AND  end1 > start2
    SELECT COUNT(*) INTO v_clash
      FROM booking
     WHERE charger_id = NEW.charger_id
       AND status IN ('accepted', 'charging')
       AND start_time < NEW.end_time
       AND end_time   > NEW.start_time;
    IF v_clash > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'This slot overlaps a booking the host has already accepted. Please pick another time.';
    END IF;
END$$

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
    DECLARE v_bypass BOOLEAN DEFAULT
        (IFNULL(@cm_seed_bypass, 0) = 1 AND SUBSTRING_INDEX(USER(), '@', 1) = 'root');

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

        -- a late request (start time passed) can still be accepted until the slot's END time; after that it can
        -- only be declined. (seed.sql loads past history as root with @cm_seed_bypass = 1.)
        IF NOT v_bypass AND OLD.status = 'requested' AND NEW.status = 'accepted' AND NEW.end_time <= NOW() THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'This request''s time slot has already ended, so it can only be declined.';
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

-- 3) trg_booking_au: keep the charger's physical status in step with sessions.
CREATE TRIGGER trg_booking_au
AFTER UPDATE ON booking
FOR EACH ROW
BEGIN
    IF NEW.status = 'charging' AND OLD.status <> 'charging' THEN
        UPDATE charger SET status = 'occupied'
         WHERE charger_id = NEW.charger_id AND status = 'available';
    ELSEIF OLD.status = 'charging' AND NEW.status <> 'charging' THEN
        UPDATE charger SET status = 'available'
         WHERE charger_id = NEW.charger_id AND status = 'occupied';   -- never overrides faulty/offline
    END IF;
END$$

-- 4) trg_session_au: when the host records end %, create the bill and complete
--    the booking. kwh = (end - start) / 100 x battery_kwh; rate = charger price.
CREATE TRIGGER trg_session_au
AFTER UPDATE ON charging_session
FOR EACH ROW
BEGIN
    DECLARE v_rate DECIMAL(5,2);
    DECLARE v_kwh  DECIMAL(7,2);

    IF OLD.end_pct IS NOT NULL AND
       (NOT (NEW.end_pct <=> OLD.end_pct) OR NEW.start_pct <> OLD.start_pct
        OR NEW.battery_kwh <> OLD.battery_kwh) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A finished charging session cannot be changed.';
    END IF;

    IF OLD.end_pct IS NULL AND NEW.end_pct IS NOT NULL THEN
        SELECT c.price_per_kwh INTO v_rate
          FROM booking b JOIN charger c ON c.charger_id = b.charger_id
         WHERE b.booking_id = NEW.booking_id;

        SET v_kwh = ROUND((NEW.end_pct - NEW.start_pct) / 100 * NEW.battery_kwh, 2);

        INSERT INTO bill (booking_id, kwh, rate, amount, status, generated_at)
        VALUES (NEW.booking_id, v_kwh, v_rate, ROUND(v_kwh * v_rate, 2),
                'PAYMENT_PENDING', IFNULL(NEW.ended_at, NOW()));

        UPDATE booking SET status = 'completed' WHERE booking_id = NEW.booking_id;
    END IF;
END$$

-- 5) trg_bill_bu: bills are money records — amounts frozen, PAID is final.
CREATE TRIGGER trg_bill_bu
BEFORE UPDATE ON bill
FOR EACH ROW
BEGIN
    IF OLD.status = 'PAID' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This bill is already paid and is locked.';
    END IF;
    IF NEW.kwh <> OLD.kwh OR NEW.rate <> OLD.rate OR NEW.amount <> OLD.amount
       OR NEW.booking_id <> OLD.booking_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Bill kWh, rate and amount are final and cannot be changed.';
    END IF;
    IF NEW.status = 'PAID' AND NEW.paid_at IS NULL THEN
        SET NEW.paid_at = NOW();
    END IF;
END$$



-- =====================================================================
-- 4. STORED PROCEDURES  (each one checks the caller is the charger's host)
--    Pattern: EXIT HANDLER -> ROLLBACK + RESIGNAL, so the app still receives
--    the original error text.
-- =====================================================================

-- accept_booking: lock the charger row so two accepts on the same charger are
-- serialised, accept this request, auto-decline overlapping requests.
CREATE PROCEDURE accept_booking(IN p_host_id INT, IN p_booking_id INT)
BEGIN
    DECLARE v_charger  INT;
    DECLARE v_status   VARCHAR(10);
    DECLARE v_start    DATETIME;
    DECLARE v_end      DATETIME;
    DECLARE v_host     INT;
    DECLARE v_approval VARCHAR(10);
    DECLARE v_cstatus  VARCHAR(10);
    DECLARE v_clash    INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT b.charger_id, l.host_id INTO v_charger, v_host
      FROM booking b
      JOIN charger c ON c.charger_id = b.charger_id
      JOIN listing l ON l.listing_id = c.listing_id
     WHERE b.booking_id = p_booking_id;
    IF v_charger IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Booking not found.';
    END IF;
    IF v_host <> p_host_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only the host of this charger can accept the booking.';
    END IF;

    -- row lock: concurrent accept_booking calls for this charger wait here
    SELECT approval, status INTO v_approval, v_cstatus
      FROM charger WHERE charger_id = v_charger FOR UPDATE;

    SELECT status, start_time, end_time INTO v_status, v_start, v_end
      FROM booking WHERE booking_id = p_booking_id;

    IF v_status <> 'requested' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only a requested booking can be accepted.';
    END IF;
    IF v_approval <> 'APPROVED' OR v_cstatus IN ('faulty', 'offline') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This charger is not bookable right now (not approved, faulty or offline).';
    END IF;
    -- late is fine (start time passed) as long as the slot has not ended yet
    IF v_end <= NOW() THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This request''s time slot has already ended, so it can only be declined.';
    END IF;

    SELECT COUNT(*) INTO v_clash FROM booking
     WHERE charger_id = v_charger AND status IN ('accepted', 'charging')
       AND booking_id <> p_booking_id
       AND start_time < v_end AND end_time > v_start;
    IF v_clash > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'You already accepted another booking that overlaps this slot.';
    END IF;

    UPDATE booking SET status = 'accepted' WHERE booking_id = p_booking_id;

    UPDATE booking
       SET status = 'declined',
           cancel_reason = 'Slot given to another booking'
     WHERE charger_id = v_charger AND status = 'requested'
       AND booking_id <> p_booking_id
       AND start_time < v_end AND end_time > v_start;

    COMMIT;
END$$

-- end_session: host records end %; trg_session_au then creates the bill and
-- completes the booking, trg_booking_au frees the charger.
CREATE PROCEDURE end_session(IN p_host_id INT, IN p_booking_id INT, IN p_end_pct INT)
BEGIN
    DECLARE v_host   INT;
    DECLARE v_status VARCHAR(10);
    DECLARE v_start  INT;
    DECLARE v_msg    VARCHAR(255);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT l.host_id, b.status INTO v_host, v_status
      FROM booking b
      JOIN charger c ON c.charger_id = b.charger_id
      JOIN listing l ON l.listing_id = c.listing_id
     WHERE b.booking_id = p_booking_id;
    IF v_host IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Booking not found.';
    END IF;
    IF v_host <> p_host_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only the host of this charger can end the session.';
    END IF;
    IF v_status <> 'charging' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This booking is not charging right now.';
    END IF;

    SELECT start_pct INTO v_start FROM charging_session
     WHERE booking_id = p_booking_id FOR UPDATE;
    IF p_end_pct IS NULL OR p_end_pct <= v_start OR p_end_pct > 100 THEN
        SET v_msg = CONCAT('End battery % must be more than the start (', v_start, '%) and at most 100.');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    UPDATE charging_session SET end_pct = p_end_pct, ended_at = NOW()
     WHERE booking_id = p_booking_id;                                         -- fires trg_session_au

    COMMIT;
END$$

DELIMITER ;


-- =====================================================================
-- 5. VIEWS
-- =====================================================================

-- What customers can search: approved chargers of active hosts, with plug,
-- listing and host details plus the live status word.
CREATE VIEW v_searchable_chargers AS
SELECT c.charger_id, c.label, c.power_kw, c.parking_size, c.price_per_kwh,
       ct.connector_id, ct.code AS connector_code, ct.current_type,
       l.listing_id, l.name AS listing_name, l.address, l.city,
       l.latitude, l.longitude, l.open_time, l.close_time,
       u.user_id AS host_id, u.name AS host_name,
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

-- Money actually collected per listing. LEFT JOIN chain so listings with no
-- chargers / bookings / paid bills show 0. The PAID filter is in the ON clause
-- (putting it in WHERE would turn the LEFT JOIN into an inner join).
CREATE VIEW v_revenue_per_listing AS
SELECT l.listing_id, l.name AS listing_name, l.city,
       l.host_id, u.name AS host_name,
       COUNT(DISTINCT c.charger_id)   AS chargers,
       COUNT(bl.bill_id)              AS paid_bills,
       IFNULL(SUM(bl.kwh), 0)         AS kwh_sold,
       IFNULL(SUM(bl.amount), 0)      AS revenue
  FROM listing l
  JOIN users u        ON u.user_id     = l.host_id
  LEFT JOIN charger c ON c.listing_id  = l.listing_id
  LEFT JOIN booking b ON b.charger_id  = c.charger_id
  LEFT JOIN bill bl   ON bl.booking_id = b.booking_id AND bl.status = 'PAID'
 GROUP BY l.listing_id, l.name, l.city, l.host_id, u.name;
