-- =====================================================================
--  ChargeMatch Lite — migration 004: ratings removed (2026-11-26)
--      mysql -u root chargematch_lite < migrations/004_remove_ratings.sql
--  (never names a database; run once, after a mysqldump backup)
--  Drops the rating table, its trigger trg_rating_bi and the view
--  v_listing_trust. Result: 12 tables, 2 views, 5 triggers, 1 function,
--  2 procedures. Nothing else changes.
-- =====================================================================
DROP VIEW    IF EXISTS v_listing_trust;
DROP TRIGGER IF EXISTS trg_rating_bi;
DROP TABLE   IF EXISTS rating;
