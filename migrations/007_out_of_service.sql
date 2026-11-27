-- 007: charger status faulty / offline -> one 'out_of_service' (set by the host's In service / Out of service toggle).
-- Run as root against chargematch_lite only (safe to run again):
--   mysql -uroot --default-character-set=utf8mb4 chargematch_lite < migrations/007_out_of_service.sql
SET NAMES utf8mb4;

-- 1) widen the ENUM, move the old values over, then drop them
ALTER TABLE charger MODIFY status ENUM('available','occupied','faulty','offline','out_of_service') NOT NULL DEFAULT 'available';
UPDATE charger SET status = 'out_of_service' WHERE status IN ('faulty', 'offline');
ALTER TABLE charger MODIFY status ENUM('available','occupied','out_of_service') NOT NULL DEFAULT 'available'
    COMMENT 'occupied = a car is charging (trg_booking_au); out_of_service = taken out by the host';

-- 2) search hides out-of-service chargers
-- What customers can search (list and map): approved, in-service chargers of active hosts, with plug,
-- listing and host details plus the live status word. Out-of-service chargers are not in it.
CREATE OR REPLACE VIEW v_searchable_chargers AS
SELECT c.charger_id, c.label, c.power_kw, c.parking_size, c.price_per_kwh,
       ct.connector_id, ct.code AS connector_code, ct.current_type,
       l.listing_id, l.name AS listing_name, l.address, l.city,
       l.latitude, l.longitude, l.open_time, l.close_time,
       u.user_id AS host_id, u.name AS host_name,
       -- live status word (approval is already APPROVED here); 'occupied' is kept in step with sessions by
       -- trg_booking_au, so it means a car is charging right now
       CASE c.status WHEN 'occupied' THEN 'in_use' ELSE 'available' END AS live_status
  FROM charger c
  JOIN connector_type ct ON ct.connector_id = c.connector_id
  JOIN listing l         ON l.listing_id    = c.listing_id
  JOIN users u           ON u.user_id       = l.host_id
 WHERE c.approval = 'APPROVED'
   AND c.status  <> 'out_of_service'
   AND u.status   = 'ACTIVE';

-- 3) booking + accept refuse an out-of-service charger
DROP TRIGGER IF EXISTS trg_booking_bi;
DROP PROCEDURE IF EXISTS accept_booking;
DELIMITER $$
CREATE TRIGGER trg_booking_bi
BEFORE INSERT ON booking
FOR EACH ROW
BEGIN
    DECLARE v_owner    INT;
    DECLARE v_approval VARCHAR(10);
    DECLARE v_cstatus  VARCHAR(20);
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
    IF v_cstatus = 'out_of_service' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This charger is out of service right now and cannot be booked.';
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

CREATE PROCEDURE accept_booking(IN p_host_id INT, IN p_booking_id INT)
BEGIN
    DECLARE v_charger  INT;
    DECLARE v_status   VARCHAR(10);
    DECLARE v_start    DATETIME;
    DECLARE v_end      DATETIME;
    DECLARE v_host     INT;
    DECLARE v_approval VARCHAR(10);
    DECLARE v_cstatus  VARCHAR(20);
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
    IF v_approval <> 'APPROVED' OR v_cstatus = 'out_of_service' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This charger is not bookable right now (not approved or out of service).';
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
