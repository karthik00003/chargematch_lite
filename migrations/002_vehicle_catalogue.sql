-- =====================================================================
--  ChargeMatch Lite — migration 002: full vehicle catalogue (2026-11-26)
--      mysql -u root chargematch_lite < migrations/002_vehicle_catalogue.sql
--  (never names a database; run once, after a mysqldump backup)
--
--  The 56 catalogue models of the original ChargeMatch (15 2W, 7 3W, 34 4W),
--  read with a read-only SELECT from its vehicle_model (is_custom = 0) and
--  model_connector. The 12 Lite models keep their model_id (vehicles and
--  bookings stay linked); 6 of them get the original's name (same battery,
--  same car), the other 44 models are added. A model's connectors are the
--  original's plus any it already had in Lite (nothing is taken away, so no
--  existing booking becomes incompatible).
-- =====================================================================
SET NAMES utf8mb4;

INSERT INTO connector_type (connector_id, code, description, current_type) VALUES
(7, 'CHADEMO',      'CHAdeMO — Japanese DC fast charging (e.g. Nissan Leaf)', 'DC'),
(8, 'BHARAT_DC001', 'Bharat DC-001 — low-power DC fleet standard',          'DC');

UPDATE vehicle_model SET model_name = 'Nexon EV LR' WHERE model_id = 1 AND make = 'Tata' AND model_name = 'Nexon EV';
UPDATE vehicle_model SET model_name = 'Tiago EV LR' WHERE model_id = 2 AND make = 'Tata' AND model_name = 'Tiago EV';
UPDATE vehicle_model SET model_name = 'XUV400 EV' WHERE model_id = 4 AND make = 'Mahindra' AND model_name = 'XUV400';
UPDATE vehicle_model SET model_name = 'iQube S' WHERE model_id = 8 AND make = 'TVS' AND model_name = 'iQube';
UPDATE vehicle_model SET model_name = 'e-Verito' WHERE model_id = 11 AND make = 'Mahindra' AND model_name = 'eVerito';
UPDATE vehicle_model SET model_name = 'Leaf (imported)' WHERE model_id = 12 AND make = 'Nissan' AND model_name = 'Leaf';

INSERT INTO vehicle_model (model_id, make, model_name, vehicle_class, battery_kwh) VALUES
(13, 'Ather', '450 Apex', '2W', 3.70),
(14, 'Ather', 'Rizta Z', '2W', 3.70),
(15, 'Bajaj', 'Chetak 3501', '2W', 3.50),
(16, 'Hero', 'Vida V1 Pro', '2W', 3.94),
(17, 'Honda', 'QC1', '2W', 1.50),
(18, 'Ola', 'S1 Air', '2W', 3.00),
(19, 'Ola', 'S1 X 4kWh', '2W', 4.00),
(20, 'Revolt', 'RV400', '2W', 3.24),
(21, 'River', 'Indie', '2W', 4.00),
(22, 'Simple Energy', 'One', '2W', 5.00),
(23, 'TVS', 'iQube ST 5.1', '2W', 5.10),
(24, 'Altigreen', 'neEV HD', '3W', 11.00),
(25, 'Bajaj', 'RE E-TEC 9.0', '3W', 8.90),
(26, 'Euler', 'HiLoad EV', '3W', 12.40),
(27, 'Mahindra', 'Treo Zor', '3W', 7.37),
(28, 'Piaggio', 'Ape E-City FX Max', '3W', 8.00),
(29, 'Piaggio', 'Ape E-Xtra FX', '3W', 8.00),
(30, 'BMW', 'i4 eDrive40', '4W', 83.90),
(31, 'BMW', 'iX1 LWB', '4W', 66.40),
(32, 'BYD', 'Atto 3', '4W', 60.48),
(33, 'BYD', 'eMAX 7', '4W', 71.80),
(34, 'BYD', 'Seal', '4W', 82.56),
(35, 'BYD', 'Sealion 7', '4W', 82.56),
(36, 'Citroen', 'eC3', '4W', 29.20),
(37, 'Hyundai', 'Creta Electric LR', '4W', 51.40),
(38, 'Hyundai', 'Ioniq 5', '4W', 72.60),
(39, 'Kia', 'EV6', '4W', 84.00),
(40, 'Kia', 'EV9', '4W', 99.80),
(41, 'Mahindra', 'BE 6', '4W', 79.00),
(42, 'Mahindra', 'XEV 9e', '4W', 79.00),
(43, 'Mahindra', 'XUV400 EV EC', '4W', 34.50),
(44, 'Mercedes-Benz', 'EQS 580', '4W', 107.80),
(45, 'MG', 'Comet EV', '4W', 17.30),
(46, 'MG', 'Windsor EV', '4W', 38.00),
(47, 'MG', 'Windsor EV Pro', '4W', 52.90),
(48, 'Tata', 'Curvv EV 45', '4W', 45.00),
(49, 'Tata', 'Curvv EV 55', '4W', 55.00),
(50, 'Tata', 'Harrier EV', '4W', 75.00),
(51, 'Tata', 'Nexon EV 45', '4W', 46.08),
(52, 'Tata', 'Punch EV LR', '4W', 35.00),
(53, 'Tata', 'Punch EV MR', '4W', 25.00),
(54, 'Tata', 'Tiago EV MR', '4W', 19.20),
(55, 'Tata', 'Tigor EV', '4W', 26.00),
(56, 'Volvo', 'EX40', '4W', 78.00);

INSERT IGNORE INTO model_connector (model_id, connector_id) VALUES
(1,3), (1,2), (1,1), (2,3), (2,2), (2,1), (3,3), (3,1),
(4,3), (4,2), (4,1), (5,3), (5,2), (5,1), (6,2), (6,4),
(7,2), (8,2), (9,2), (10,2), (11,5), (11,8), (11,2), (12,7),
(12,2), (12,6), (13,2), (13,4), (14,2), (14,4), (15,2), (16,2),
(17,2), (18,2), (19,2), (20,2), (21,2), (22,2), (23,2), (24,2),
(25,2), (26,2), (27,2), (28,2), (29,2), (30,3), (30,1), (31,3),
(31,1), (32,3), (32,1), (33,3), (33,1), (34,3), (34,1), (35,3),
(35,1), (36,3), (36,2), (36,1), (37,3), (37,1), (38,3), (38,1),
(39,3), (39,1), (40,3), (40,1), (41,3), (41,1), (42,3), (42,1),
(43,3), (43,2), (43,1), (44,3), (44,1), (45,2), (45,1), (46,3),
(46,2), (46,1), (47,3), (47,2), (47,1), (48,3), (48,2), (48,1),
(49,3), (49,2), (49,1), (50,3), (50,1), (51,3), (51,2), (51,1),
(52,3), (52,2), (52,1), (53,3), (53,2), (53,1), (54,3), (54,2),
(54,1), (55,3), (55,2), (55,1), (56,3), (56,1);
