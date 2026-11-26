-- 006: more amenities; late requests can be accepted until the slot's END time; charger label >= 3 characters.
-- Run ONCE, as root, against chargematch_lite only (step 3 fails if chk_charger_label already exists):
--   mysql -uroot --default-character-set=utf8mb4 chargematch_lite < migrations/006_amenities_late_accept.sql
SET NAMES utf8mb4;

-- 1) 10 more home-charging amenities (existing ones kept; a name or id already there is skipped)
INSERT INTO amenity (amenity_id, name, icon)
SELECT n.amenity_id, n.name, n.icon FROM (VALUES
    ROW(7, 'Drinking water', '🚰'),
    ROW(8, 'Seating area', '🪑'),
    ROW(9, 'Shade / tree cover', '🌳'),
    ROW(10, 'Night lighting', '💡'),
    ROW(11, 'Wheelchair accessible', '♿'),
    ROW(12, 'Tyre air pump', '🛞'),
    ROW(13, 'Pet friendly', '🐾'),
    ROW(14, 'Security guard', '💂'),
    ROW(15, 'Two-wheeler parking', '🛵'),
    ROW(16, 'Phone charging point', '📱')
) AS n (amenity_id, name, icon)
WHERE NOT EXISTS (SELECT 1 FROM amenity a WHERE a.name = n.name OR a.amenity_id = n.amenity_id);
ALTER TABLE amenity AUTO_INCREMENT = 1;   -- InnoDB sets it to MAX(amenity_id) + 1

-- 2) late accept rule (trigger + procedure), and declined requests no longer name a booking number
DROP TRIGGER IF EXISTS trg_booking_bu;
DROP PROCEDURE IF EXISTS accept_booking;
DELIMITER $$
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
DELIMITER ;

UPDATE booking SET cancel_reason = 'Slot given to another booking' WHERE cancel_reason LIKE 'Slot given to booking #%';

-- 3) charger labels are typed by the host: at least 3 characters (unique per listing is uq_charger_label)
ALTER TABLE charger ADD CONSTRAINT chk_charger_label CHECK (CHAR_LENGTH(TRIM(label)) >= 3);
