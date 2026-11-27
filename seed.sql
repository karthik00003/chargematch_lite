-- =====================================================================
--  ChargeMatch Lite — seed.sql  (demo data, Mangaluru / Udupi area)
--      mysql -u root chargematch_lite < seed.sql
--
--  All demo passwords are:  demo1234   (stored only as scrypt hashes)
--
--  HOW PAST BOOKINGS ARE INSERTED
--  trg_booking_bi refuses bookings that start in the past or fall outside
--  opening hours. A demo needs history, so this file sets
--      @cm_seed_bypass = 1
--  which the trigger honours ONLY when the MySQL user is root (the app user
--  cmlite_app cannot use it) and ONLY for those two clock rules. Ownership,
--  approval, plug compatibility, overlap and the status state machine still
--  apply. Every past booking walks the real life cycle:
--      INSERT (requested) -> accepted -> session row -> charging
--      -> end_pct set  => trg_session_au creates the bill + completes it.
--  All dates are relative to CURDATE() so the data always looks fresh.
-- =====================================================================

SET NAMES utf8mb4;
SET @cm_seed_bypass = 1;

-- ---------------------------------------------------------------- users
INSERT INTO users (user_id, name, email, password_hash, role, created_at) VALUES
(1,  'Platform Admin',   'admin@cmlite.test',   'scrypt:32768:8:1$ypfIzi06CTzkPQrA$37a8d536e313aa53af77273b16c22274552066ff7a3744cf906c56a99a5b4006ce2e4bfc0b8df89b5de07296c7c8f1b4dafb7f87d1a6870542f74317acc11574', 'ADMIN',    CURDATE() - INTERVAL 60 DAY),
(2,  'Ananya Shetty',    'ananya@cmlite.test',  'scrypt:32768:8:1$r7ZtPkMzI4e6W2q5$87f5e3f21d63ba0681962650a89425f33a1fe732cac92acbab5fcd10032e4078b81670b8d42d94fe231d750ea6d6982cccdc93fd7818adf4a7cb17782b2a30eb', 'HOST',     CURDATE() - INTERVAL 50 DAY),
(3,  'Rohan Pai',        'rohan@cmlite.test',   'scrypt:32768:8:1$vni29nWgtA3Mqx5Q$cb7a51d909d14cc6e8b7d3469f84c0f9f64c3e4cf63b89b053fab8bd38180ccb643e695825edc52b1df90565c19c84acefd63e099743252d21764d4ffe45984f', 'HOST',     CURDATE() - INTERVAL 48 DAY),
(4,  'Fathima Rizwana',  'fathima@cmlite.test', 'scrypt:32768:8:1$svB5cICbBZGNG4SU$f76b83716a2f77ced5b46233c51b62f68a2344d41d7602c9b08f41b72c3ca589ff73e53b0f599192373ff0f3e7187530654f763d8731a0adbd6b18d72ccb2643', 'HOST',     CURDATE() - INTERVAL 45 DAY),
(5,  'Prakash Kamath',   'prakash@cmlite.test', 'scrypt:32768:8:1$C3eqJdO33bwddVCu$979c97a161e7f70f902f82313cdf01e3fa27b54c1d91f9ef03e86f5d71e28bae684eaf5a9ad21443b6ed0d1ba4b8679e769761e26756517a6f30555d80fb1ca1', 'HOST',     CURDATE() - INTERVAL 44 DAY),
(6,  'Shreya Bhat',      'shreya@cmlite.test',  'scrypt:32768:8:1$BFhmZ159f6LZt2Oy$649bf0a00937a0119624419b802c25bf0455a98e817d9fe0d3891c520a917f83a9202aa654b35ea3cb3e6c9e9baf12a36e44a979afce419c2119c9410f99c62a', 'HOST',     CURDATE() - INTERVAL 40 DAY),
(7,  'Kiran Rao',        'kiran@cmlite.test',   'scrypt:32768:8:1$lqwLOsEOry8E9FL9$beb7632a83b235dbbd80d9104fee7c531ee009d409617ee04b08de236e1d9a9418274bcb0f61e54f898c8be08c144a585c8286078d54bfa9d14f5cf424a0f619', 'CUSTOMER', CURDATE() - INTERVAL 35 DAY),
(8,  'Meera Nayak',      'meera@cmlite.test',   'scrypt:32768:8:1$hzFKAyj2dklGpNd8$ce483dddf8bf2eeaf7ac89a22ef8eeea66918bc04b8b209f0220564d74dd5e97fbd4e54c546e283901a096dd54643f436eaff1dc40e8ac13467013070dd08265', 'CUSTOMER', CURDATE() - INTERVAL 34 DAY),
(9,  'Arjun Hegde',      'arjun@cmlite.test',   'scrypt:32768:8:1$ekj3tfK1yzIdhHoT$c2edf66fdfd2ab54bde9d4b28d088f33a02609faf0d0e45ae5ce0019dd50e0ece1644cf3299216cf3c3be71757c3256aa84fb8f1ea31deae3eae8137d511b733', 'CUSTOMER', CURDATE() - INTERVAL 33 DAY),
(10, 'Divya Kini',       'divya@cmlite.test',   'scrypt:32768:8:1$xPPiNMgo1mssJdlr$f8274ae339265e175c6d6af2eb1ff03fb287a25dfb0802ca9ff0e17d5a9ba656dea8c5d21d786e823a8c572fabc3290ab67176e07cc901343461d434ae75230f', 'CUSTOMER', CURDATE() - INTERVAL 30 DAY),
(11, 'Nikhil D''Souza',  'nikhil@cmlite.test',  'scrypt:32768:8:1$Xt8SaSL13MMDqGgE$008a266a9d8e0d21546245bd279801d2f7f14e8bfdd9d181797aa09a8e05a0187a96b84e96a947027bf6f0b1b1f748f55470540c57b7d098deda88ba05640ca4', 'CUSTOMER', CURDATE() - INTERVAL 28 DAY);

-- ------------------------------------------------------ connector types
INSERT INTO connector_type (connector_id, code, description, current_type) VALUES
(1, 'TYPE2',        'IEC Type 2 (Mennekes) AC plug — most Indian 4-wheelers', 'AC'),
(2, 'IND_SOCKET',   '15 A Indian 3-pin socket with portable charger',          'AC'),
(3, 'CCS2',         'Combined Charging System 2 — DC fast charging',           'DC'),
(4, 'LECCS',        'Light EV CCS — compact plug for 2W/3W (e.g. Ather)',      'AC'),
(5, 'BHARAT_AC001', 'Bharat AC-001 — older Indian fleet standard',             'AC'),
(6, 'TYPE1',        'SAE J1772 Type 1 AC plug — imported models',              'AC'),
(7, 'CHADEMO',      'CHAdeMO — Japanese DC fast charging (e.g. Nissan Leaf)', 'DC'),
(8, 'BHARAT_DC001', 'Bharat DC-001 — low-power DC fleet standard',          'DC');

-- ------------------------------------------------------------ amenities
INSERT INTO amenity (amenity_id, name, icon) VALUES
(1, 'Covered parking', '🅿️'),
(2, 'Restroom',        '🚻'),
(3, 'Wi-Fi',           '📶'),
(4, 'Café nearby',     '☕'),
(5, 'CCTV',            '📹'),
(6, 'Waiting lounge',  '🛋️'),
(7, 'Drinking water',        '🚰'),
(8, 'Seating area',          '🪑'),
(9, 'Shade / tree cover',    '🌳'),
(10, 'Night lighting',        '💡'),
(11, 'Wheelchair accessible', '♿'),
(12, 'Tyre air pump',         '🛞'),
(13, 'Pet friendly',          '🐾'),
(14, 'Security guard',        '💂'),
(15, 'Two-wheeler parking',   '🛵'),
(16, 'Phone charging point',  '📱');

-- ------------------------------------------------------- vehicle models
-- The 56 catalogue models of the original ChargeMatch (15 2W, 7 3W, 34 4W) with the plugs each accepts.
-- Ids 1-12 are the first Lite models (demo vehicles use them); the e-Verito also takes Bharat AC-001 and the
-- Leaf its portable 15A charger, so every demo charger fits at least one model.
INSERT INTO vehicle_model (model_id, make, model_name, vehicle_class, battery_kwh) VALUES
(1, 'Tata', 'Nexon EV LR', '4W', 40.50),
(2, 'Tata', 'Tiago EV LR', '4W', 24.00),
(3, 'MG', 'ZS EV', '4W', 50.30),
(4, 'Mahindra', 'XUV400 EV', '4W', 39.40),
(5, 'Hyundai', 'Kona Electric', '4W', 39.20),
(6, 'Ather', '450X', '2W', 3.70),
(7, 'Ola', 'S1 Pro', '2W', 4.00),
(8, 'TVS', 'iQube S', '2W', 3.40),
(9, 'Bajaj', 'Chetak', '2W', 3.20),
(10, 'Mahindra', 'Treo', '3W', 7.37),
(11, 'Mahindra', 'e-Verito', '4W', 21.20),
(12, 'Nissan', 'Leaf (imported)', '4W', 40.00),
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

INSERT INTO model_connector (model_id, connector_id) VALUES
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

-- -------------------------------------------------------------- vehicles
INSERT INTO vehicle (vehicle_id, user_id, model_id, reg_no) VALUES
(1, 7,  1,  'KA19MN1234'),   -- Kiran : Nexon EV LR
(2, 7,  6,  'KA19EX4521'),   -- Kiran : Ather 450X
(3, 8,  2,  'KA20MB7788'),   -- Meera : Tiago EV
(4, 9,  3,  'KA19MH0042'),   -- Arjun : MG ZS EV
(5, 9,  10, 'KA19AB3310'),   -- Arjun : Treo auto
(6, 10, 5,  'KA20P5566'),    -- Divya : Kona
(7, 11, 7,  'KA19HY9087'),   -- Nikhil: Ola S1 Pro
(8, 11, 12, 'KA01MX2020');   -- Nikhil: Nissan Leaf

-- -------------------------------------------------------------- listings
INSERT INTO listing (listing_id, host_id, name, address, city, latitude, longitude, open_time, close_time, created_at) VALUES
(1,  2, 'Kadri Park Home Charger',  '14 Kadri Park Road, Kadri',          'Mangaluru', 12.886600, 74.855600, '06:00', '22:00', CURDATE() - INTERVAL 49 DAY),
(2,  2, 'Kankanady Garage',         '3rd Cross, Kankanady',               'Mangaluru', 12.872100, 74.860100, '07:00', '21:00', CURDATE() - INTERVAL 49 DAY),
(3,  3, 'Bejai 24x7 Point',         'Bejai Main Road, near KSRTC',        'Mangaluru', 12.888400, 74.840200, '00:00', '23:59:59', CURDATE() - INTERVAL 47 DAY),
(4,  3, 'Kodialbail Porch',         '2nd Lane, Kodialbail',               'Mangaluru', 12.878000, 74.842000, '08:00', '20:00', CURDATE() - INTERVAL 47 DAY),
(5,  4, 'Surathkal Beach Road',     'Near NITK Lighthouse Road, Surathkal','Mangaluru', 13.010800, 74.794300, '06:00', '23:00', CURDATE() - INTERVAL 44 DAY),
(6,  4, 'Panambur Villa',           'Kulai Junction, Panambur',           'Mangaluru', 12.945100, 74.809000, '07:00', '22:00', CURDATE() - INTERVAL 44 DAY),
(7,  5, 'Ambalpady Home',           'Ambalpady Temple Road',              'Udupi',     13.340900, 74.742100, '06:00', '22:00', CURDATE() - INTERVAL 43 DAY),
(8,  5, 'Malpe Road Garden',        'Malpe Road, Adi Udupi',              'Udupi',     13.350000, 74.712000, '08:00', '20:00', CURDATE() - INTERVAL 43 DAY),
(9,  6, 'Tiger Circle Stay',        'Near Tiger Circle, Manipal',         'Manipal',   13.352500, 74.786000, '00:00', '23:59:59', CURDATE() - INTERVAL 39 DAY),
(10, 6, 'End Point Basement',       'End Point Road, Manipal',            'Manipal',   13.346000, 74.793000, '07:00', '22:00', CURDATE() - INTERVAL 39 DAY);

INSERT INTO listing_amenity (listing_id, amenity_id, note) VALUES
(1,1,'Fits 1 car'), (1,5,NULL), (1,3,NULL),
(2,1,'2 cars'),     (2,4,'Coffee shop 100 m'),
(3,5,NULL),         (3,2,NULL), (3,4,'Hotel opposite'),
(4,1,NULL),
(5,4,'Beach café'), (5,2,NULL),
(6,1,NULL),         (6,5,NULL), (6,6,'Sit-out with fan'),
(7,3,NULL),         (7,2,NULL),
(8,1,NULL),
(9,3,'Fast Wi-Fi'), (9,4,NULL), (9,6,NULL),
(10,1,'Basement'),  (10,5,NULL);

-- -------------------------------------------------------------- chargers
--  Home chargers are AC only; every row passes chk_charger_setup: Type 2
--  3.3 / 7.4 / 11 / 22 kW (11 and 22 = 3-phase), 15A socket 2.2 / 3.3 kW,
--  Bharat AC-001 3.3 kW, LECCS 1.5 / 3.0 kW on a 2W / 3W bay; ₹5–30 per kWh.
--  2 PENDING (10, 20), 1 REJECTED (16), 1 taken out of service at the end (11)
INSERT INTO charger (charger_id, listing_id, label, connector_id, power_kw, parking_size, price_per_kwh, status, approval, reviewed_by, review_note) VALUES
(1,  1,  'Bay A',        1,  7.4, '4W', 12.00, 'available', 'APPROVED', 1, 'Wiring photos verified'),
(2,  1,  'Bay B',        2,  3.3, '4W',  9.00, 'available', 'APPROVED', 1, NULL),
(3,  2,  'Garage',       1, 11.0, '4W', 14.00, 'available', 'APPROVED', 1, NULL),
(4,  2,  'Scooter Point',4,  3.0, '2W', 10.00, 'available', 'APPROVED', 1, NULL),
(5,  3,  'Wallbox 22',   1, 22.0, '4W', 22.00, 'available', 'APPROVED', 1, 'Installer certificate seen'),
(6,  3,  'AC Slow',      1,  7.4, '4W', 13.00, 'available', 'APPROVED', 1, NULL),
(7,  4,  'Porch',        2,  3.3, '3W',  8.00, 'available', 'APPROVED', 1, NULL),
(8,  4,  'Driveway',     5,  3.3, '4W', 10.00, 'available', 'APPROVED', 1, NULL),
(9,  5,  'Main',         1,  7.4, '4W', 11.00, 'available', 'APPROVED', 1, NULL),
(10, 5,  'Bay 2',        1, 11.0, '4W', 14.00, 'available', 'PENDING',  NULL, NULL),
(11, 6,  'Gate 1',       1,  7.4, '4W', 12.00, 'available', 'APPROVED', 1, NULL),
(12, 6,  '3-Pin',        2,  3.3, '3W',  8.00, 'available', 'APPROVED', 1, NULL),
(13, 7,  'Bay 1',        1,  7.4, '4W', 13.00, 'available', 'APPROVED', 1, NULL),
(14, 7,  'Bay 2',        2,  3.3, '4W', 12.00, 'available', 'APPROVED', 1, NULL),
(15, 8,  'Garden',       2,  3.3, '2W',  9.00, 'available', 'APPROVED', 1, NULL),
(16, 8,  'Beach Bay',    1, 22.0, '4W', 25.00, 'available', 'REJECTED', 1, 'No electrical safety certificate for a 22 kW 3-phase wallbox; please resubmit with it.'),
(17, 9,  'Hostel Lane',  2,  3.3, '2W',  8.00, 'available', 'APPROVED', 1, NULL),
(18, 9,  'Car Bay',      1, 11.0, '4W', 14.00, 'available', 'APPROVED', 1, NULL),
(19, 10, 'Basement',     1,  7.4, '4W', 13.00, 'available', 'APPROVED', 1, NULL),
(20, 10, 'Scooter Dock', 4,  3.0, '2W', 10.00, 'available', 'PENDING',  NULL, NULL);

-- -------------------------------------------------------------- bookings
-- All 30 are inserted as 'requested' (trg_booking_bi checks each one), then
-- moved through the state machine below.
INSERT INTO booking (booking_id, customer_id, vehicle_id, charger_id, start_time, end_time, created_at) VALUES
-- past, will be completed
(1,  7,  1, 1,  TIMESTAMP(CURDATE() - INTERVAL 20 DAY, '09:00'), TIMESTAMP(CURDATE() - INTERVAL 20 DAY, '11:00'), CURDATE() - INTERVAL 21 DAY),
(2,  8,  3, 3,  TIMESTAMP(CURDATE() - INTERVAL 18 DAY, '10:00'), TIMESTAMP(CURDATE() - INTERVAL 18 DAY, '12:00'), CURDATE() - INTERVAL 19 DAY),
(3,  9,  4, 5,  TIMESTAMP(CURDATE() - INTERVAL 15 DAY, '14:00'), TIMESTAMP(CURDATE() - INTERVAL 15 DAY, '15:00'), CURDATE() - INTERVAL 16 DAY),
(4,  10, 6, 6,  TIMESTAMP(CURDATE() - INTERVAL 14 DAY, '18:00'), TIMESTAMP(CURDATE() - INTERVAL 14 DAY, '21:00'), CURDATE() - INTERVAL 15 DAY),
(5,  11, 7, 7,  TIMESTAMP(CURDATE() - INTERVAL 13 DAY, '08:30'), TIMESTAMP(CURDATE() - INTERVAL 13 DAY, '10:30'), CURDATE() - INTERVAL 14 DAY),
(6,  7,  2, 4,  TIMESTAMP(CURDATE() - INTERVAL 12 DAY, '17:00'), TIMESTAMP(CURDATE() - INTERVAL 12 DAY, '18:30'), CURDATE() - INTERVAL 13 DAY),
(7,  9,  5, 12, TIMESTAMP(CURDATE() - INTERVAL 11 DAY, '09:00'), TIMESTAMP(CURDATE() - INTERVAL 11 DAY, '12:00'), CURDATE() - INTERVAL 12 DAY),
(8,  11, 8, 14, TIMESTAMP(CURDATE() - INTERVAL 10 DAY, '10:00'), TIMESTAMP(CURDATE() - INTERVAL 10 DAY, '14:00'), CURDATE() - INTERVAL 11 DAY),
(9,  8,  3, 13, TIMESTAMP(CURDATE() - INTERVAL 9 DAY,  '07:00'), TIMESTAMP(CURDATE() - INTERVAL 9 DAY,  '09:00'), CURDATE() - INTERVAL 10 DAY),
(10, 10, 6, 18, TIMESTAMP(CURDATE() - INTERVAL 8 DAY,  '19:00'), TIMESTAMP(CURDATE() - INTERVAL 8 DAY,  '21:00'), CURDATE() - INTERVAL 9 DAY),
(11, 7,  1, 9,  TIMESTAMP(CURDATE() - INTERVAL 7 DAY,  '12:00'), TIMESTAMP(CURDATE() - INTERVAL 7 DAY,  '14:00'), CURDATE() - INTERVAL 8 DAY),
(12, 9,  4, 19, TIMESTAMP(CURDATE() - INTERVAL 6 DAY,  '15:00'), TIMESTAMP(CURDATE() - INTERVAL 6 DAY,  '17:00'), CURDATE() - INTERVAL 7 DAY),
(13, 11, 7, 17, TIMESTAMP(CURDATE() - INTERVAL 5 DAY,  '20:00'), TIMESTAMP(CURDATE() - INTERVAL 5 DAY,  '22:00'), CURDATE() - INTERVAL 6 DAY),
(14, 8,  3, 11, TIMESTAMP(CURDATE() - INTERVAL 4 DAY,  '10:00'), TIMESTAMP(CURDATE() - INTERVAL 4 DAY,  '12:00'), CURDATE() - INTERVAL 5 DAY),
(15, 10, 6, 1,  TIMESTAMP(CURDATE() - INTERVAL 3 DAY,  '16:00'), TIMESTAMP(CURDATE() - INTERVAL 3 DAY,  '18:00'), CURDATE() - INTERVAL 4 DAY),
(16, 7,  2, 15, TIMESTAMP(CURDATE() - INTERVAL 2 DAY,  '08:00'), TIMESTAMP(CURDATE() - INTERVAL 2 DAY,  '09:00'), CURDATE() - INTERVAL 3 DAY),
-- past, cancelled / declined
(17, 9,  4, 3,  TIMESTAMP(CURDATE() - INTERVAL 5 DAY,  '10:00'), TIMESTAMP(CURDATE() - INTERVAL 5 DAY,  '11:00'), CURDATE() - INTERVAL 7 DAY),
(18, 8,  3, 6,  TIMESTAMP(CURDATE() - INTERVAL 3 DAY,  '13:00'), TIMESTAMP(CURDATE() - INTERVAL 3 DAY,  '14:00'), CURDATE() - INTERVAL 4 DAY),
-- charging right now (Bejai is open 24x7)
(19, 7,  1, 5,  NOW() - INTERVAL 30 MINUTE,                      NOW() + INTERVAL 90 MINUTE,                      NOW() - INTERVAL 1 DAY),
-- future
(20, 8,  3, 1,  TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '09:00'),  TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '11:00'), NOW() - INTERVAL 2 HOUR),
(21, 9,  4, 6,  TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '14:00'),  TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '16:00'), NOW() - INTERVAL 2 HOUR),
(22, 10, 6, 3,  TIMESTAMP(CURDATE() + INTERVAL 2 DAY, '10:00'),  TIMESTAMP(CURDATE() + INTERVAL 2 DAY, '12:00'), NOW() - INTERVAL 1 HOUR),
(23, 11, 7, 2,  TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '18:00'),  TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '19:00'), NOW() - INTERVAL 1 HOUR),
(24, 7,  2, 4,  TIMESTAMP(CURDATE() + INTERVAL 2 DAY, '08:00'),  TIMESTAMP(CURDATE() + INTERVAL 2 DAY, '09:30'), NOW() - INTERVAL 50 MINUTE),
(25, 9,  5, 7,  TIMESTAMP(CURDATE() + INTERVAL 3 DAY, '09:00'),  TIMESTAMP(CURDATE() + INTERVAL 3 DAY, '11:00'), NOW() - INTERVAL 40 MINUTE),
(26, 11, 8, 14, TIMESTAMP(CURDATE() + INTERVAL 2 DAY, '11:00'),  TIMESTAMP(CURDATE() + INTERVAL 2 DAY, '13:00'), NOW() - INTERVAL 3 HOUR),
(27, 10, 6, 13, TIMESTAMP(CURDATE() + INTERVAL 3 DAY, '17:00'),  TIMESTAMP(CURDATE() + INTERVAL 3 DAY, '19:00'), NOW() - INTERVAL 5 HOUR),
(28, 10, 6, 18, TIMESTAMP(CURDATE() + INTERVAL 3 DAY, '17:00'),  TIMESTAMP(CURDATE() + INTERVAL 3 DAY, '19:00'),   NOW() - INTERVAL 4 HOUR),  -- same slot as #27 (cancelled), at Car Bay
(29, 7,  1, 3,  TIMESTAMP(CURDATE() + INTERVAL 2 DAY, '11:00'),  TIMESTAMP(CURDATE() + INTERVAL 2 DAY, '13:00'), NOW() - INTERVAL 30 MINUTE), -- overlaps #22
(30, 9,  4, 9,  TIMESTAMP(CURDATE() + INTERVAL 4 DAY, '07:00'),  TIMESTAMP(CURDATE() + INTERVAL 4 DAY, '09:00'), NOW() - INTERVAL 6 HOUR);

-- ---------------------------------------- history: bookings 1–16 completed
UPDATE booking SET status = 'accepted' WHERE booking_id BETWEEN 1 AND 16;

-- session rows: battery size is copied from the vehicle's model
INSERT INTO charging_session (booking_id, start_pct, battery_kwh, started_at)
SELECT b.booking_id, s.start_pct, vm.battery_kwh, b.start_time + INTERVAL 5 MINUTE
  FROM (VALUES ROW(1,20), ROW(2,30), ROW(3,15), ROW(4,25), ROW(5,10), ROW(6,20),
               ROW(7,15), ROW(8,30), ROW(9,40), ROW(10,20), ROW(11,30), ROW(12,25),
               ROW(13,5), ROW(14,35), ROW(15,30), ROW(16,50)) AS s (booking_id, start_pct)
  JOIN booking b        ON b.booking_id = s.booking_id
  JOIN vehicle v        ON v.vehicle_id = b.vehicle_id
  JOIN vehicle_model vm ON vm.model_id  = v.model_id;

UPDATE booking SET status = 'charging' WHERE booking_id BETWEEN 1 AND 16;

-- end each session: trg_session_au creates the bill and completes the booking
UPDATE charging_session SET end_pct = 80,  ended_at = started_at + INTERVAL 105 MINUTE WHERE booking_id = 1;
UPDATE charging_session SET end_pct = 90,  ended_at = started_at + INTERVAL 100 MINUTE WHERE booking_id = 2;
UPDATE charging_session SET end_pct = 75,  ended_at = started_at + INTERVAL 50  MINUTE WHERE booking_id = 3;
UPDATE charging_session SET end_pct = 85,  ended_at = started_at + INTERVAL 170 MINUTE WHERE booking_id = 4;
UPDATE charging_session SET end_pct = 90,  ended_at = started_at + INTERVAL 110 MINUTE WHERE booking_id = 5;
UPDATE charging_session SET end_pct = 100, ended_at = started_at + INTERVAL 80  MINUTE WHERE booking_id = 6;
UPDATE charging_session SET end_pct = 95,  ended_at = started_at + INTERVAL 170 MINUTE WHERE booking_id = 7;
UPDATE charging_session SET end_pct = 80,  ended_at = started_at + INTERVAL 230 MINUTE WHERE booking_id = 8;
UPDATE charging_session SET end_pct = 95,  ended_at = started_at + INTERVAL 110 MINUTE WHERE booking_id = 9;
UPDATE charging_session SET end_pct = 70,  ended_at = started_at + INTERVAL 105 MINUTE WHERE booking_id = 10;
UPDATE charging_session SET end_pct = 85,  ended_at = started_at + INTERVAL 110 MINUTE WHERE booking_id = 11;
UPDATE charging_session SET end_pct = 75,  ended_at = started_at + INTERVAL 100 MINUTE WHERE booking_id = 12;
UPDATE charging_session SET end_pct = 85,  ended_at = started_at + INTERVAL 110 MINUTE WHERE booking_id = 13;
UPDATE charging_session SET end_pct = 60,  ended_at = started_at + INTERVAL 45  MINUTE WHERE booking_id = 14;
UPDATE charging_session SET end_pct = 80,  ended_at = started_at + INTERVAL 105 MINUTE WHERE booking_id = 15;
UPDATE charging_session SET end_pct = 100, ended_at = started_at + INTERVAL 50  MINUTE WHERE booking_id = 16;

-- 12 bills paid, 4 still PAYMENT_PENDING (bookings 11, 12, 13, 15)
UPDATE bill SET status = 'PAID', paid_at = generated_at + INTERVAL 20 MINUTE
 WHERE booking_id IN (1,2,3,4,5,6,7,8,9,10,14,16);

-- --------------------------------------------- cancelled / declined history
UPDATE booking SET status = 'cancelled', cancel_reason = 'Plans changed'            WHERE booking_id = 17;
UPDATE booking SET status = 'declined',  cancel_reason = 'Host travelling that day' WHERE booking_id = 18;

-- --------------------------------------------- live session (booking 19)
UPDATE booking SET status = 'accepted' WHERE booking_id = 19;   -- already started, so not via accept_booking
-- host Rohan plugs in at 35 % (the app does the same two statements, after checking he is the host)
INSERT INTO charging_session (booking_id, start_pct, battery_kwh, started_at)
SELECT b.booking_id, 35, vm.battery_kwh, NOW()
  FROM booking b JOIN vehicle v ON v.vehicle_id = b.vehicle_id JOIN vehicle_model vm ON vm.model_id = v.model_id
 WHERE b.booking_id = 19;
UPDATE booking SET status = 'charging' WHERE booking_id = 19;   -- trg_booking_au marks the charger occupied

-- --------------------------------------------- future: use the procedure
CALL accept_booking(2, 20);     -- Ananya accepts Meera
CALL accept_booking(3, 21);     -- Rohan accepts Arjun
CALL accept_booking(5, 26);     -- Prakash accepts Nikhil
UPDATE booking SET status = 'cancelled', cancel_reason = 'Car went for service'           WHERE booking_id = 27;
UPDATE booking SET status = 'declined',  cancel_reason = 'Maintenance visit that morning' WHERE booking_id = 30;
-- left as 'requested': 22, 23, 24, 25, 28, 29.
-- Accepting 22 in the app will auto-decline 29 (same charger, overlapping).

-- ----------------------- charger 11 broke after #14 (it tripped twice): the host took it out of service
UPDATE charger SET status = 'out_of_service' WHERE charger_id = 11;

SET @cm_seed_bypass = NULL;
