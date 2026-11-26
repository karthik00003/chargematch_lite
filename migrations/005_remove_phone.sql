-- 005: remove users.phone (sign-up no longer asks for it).
-- Run as root against chargematch_lite only:  mysql -uroot chargematch_lite < migrations/005_remove_phone.sql
-- The view is rewritten first (it read u.phone), then the column and its UNIQUE key / CHECK go.

CREATE OR REPLACE VIEW v_searchable_chargers AS
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

ALTER TABLE users
  DROP CHECK chk_users_phone,
  DROP INDEX uq_users_phone,
  DROP COLUMN phone;
