-- Device names: gives every device a readable name such as "Türkiye-23" —
-- the country it was first seen in, plus a running number within that
-- country. Run this file ONCE against a database that already has
-- events (e.g. paste it into phpMyAdmin's SQL tab), BEFORE uploading the
-- analytics.php / dashboard.php that use the new column.
--
-- On a fresh install, run schema.sql first and then this file WITHOUT
-- step 1 (schema.sql already creates the column); steps 2–3 are the same.
--
-- The name describes a device, not a person: it is derived only from the
-- country already stored with each event and the order devices first
-- appeared in. Still no IP address anywhere.

SET NAMES utf8mb4; -- the country list below has names like "Türkiye" and "Côte d'Ivoire"

-- ---------------------------------------------------------------------
-- Step 1 — the new column (existing databases only).
-- device_name is copied onto every event so the events table reads
-- without a join; idx_device_id is what lets a newly named device's
-- earlier events be found and labelled cheaply.
-- ---------------------------------------------------------------------
ALTER TABLE analytics_events
    ADD COLUMN device_name VARCHAR(80) NULL AFTER device_id,
    ADD KEY idx_device_id (device_id);

-- ---------------------------------------------------------------------
-- Step 2 — the two tables analytics.php names devices from.
-- ---------------------------------------------------------------------

-- One row per named device; this is what hands out the numbers. The
-- unique key is the guarantee that two devices never share a name, even
-- when their first events arrive at the same moment (analytics.php just
-- retries on a collision). A device is named after the country of its
-- first event that HAS a country, and keeps that name for good — a later
-- trip or VPN doesn't rename it. A device whose country was never
-- resolved has no row here and no name.
CREATE TABLE IF NOT EXISTS analytics_devices (
    device_id CHAR(36) NOT NULL,
    country CHAR(2) NOT NULL,
    seq INT UNSIGNED NOT NULL,
    device_name VARCHAR(80) NOT NULL,
    first_seen DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (device_id),
    UNIQUE KEY uq_country_seq (country, seq)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Country code → the name used in device names. Same idea as
-- mysql_error_codes: a code that isn't listed still works, the device is
-- just named after the bare code ("XX-1"). Renaming a country here only
-- affects devices named afterwards.
CREATE TABLE IF NOT EXISTS country_names (
    code CHAR(2) NOT NULL,
    name VARCHAR(64) NOT NULL,
    PRIMARY KEY (code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT IGNORE INTO country_names (code, name) VALUES
    ('AC', 'Ascension Island'),
    ('AD', 'Andorra'),
    ('AE', 'United Arab Emirates'),
    ('AF', 'Afghanistan'),
    ('AG', 'Antigua & Barbuda'),
    ('AI', 'Anguilla'),
    ('AL', 'Albania'),
    ('AM', 'Armenia'),
    ('AO', 'Angola'),
    ('AQ', 'Antarctica'),
    ('AR', 'Argentina'),
    ('AS', 'American Samoa'),
    ('AT', 'Austria'),
    ('AU', 'Australia'),
    ('AW', 'Aruba'),
    ('AX', 'Åland Islands'),
    ('AZ', 'Azerbaijan'),
    ('BA', 'Bosnia & Herzegovina'),
    ('BB', 'Barbados'),
    ('BD', 'Bangladesh'),
    ('BE', 'Belgium'),
    ('BF', 'Burkina Faso'),
    ('BG', 'Bulgaria'),
    ('BH', 'Bahrain'),
    ('BI', 'Burundi'),
    ('BJ', 'Benin'),
    ('BL', 'St. Barthélemy'),
    ('BM', 'Bermuda'),
    ('BN', 'Brunei'),
    ('BO', 'Bolivia'),
    ('BQ', 'Caribbean Netherlands'),
    ('BR', 'Brazil'),
    ('BS', 'Bahamas'),
    ('BT', 'Bhutan'),
    ('BV', 'Bouvet Island'),
    ('BW', 'Botswana'),
    ('BY', 'Belarus'),
    ('BZ', 'Belize'),
    ('CA', 'Canada'),
    ('CC', 'Cocos (Keeling) Islands'),
    ('CD', 'Congo - Kinshasa'),
    ('CF', 'Central African Republic'),
    ('CG', 'Congo - Brazzaville'),
    ('CH', 'Switzerland'),
    ('CI', 'Côte d''Ivoire'),
    ('CK', 'Cook Islands'),
    ('CL', 'Chile'),
    ('CM', 'Cameroon'),
    ('CN', 'China'),
    ('CO', 'Colombia'),
    ('CR', 'Costa Rica'),
    ('CU', 'Cuba'),
    ('CV', 'Cape Verde'),
    ('CW', 'Curaçao'),
    ('CX', 'Christmas Island'),
    ('CY', 'Cyprus'),
    ('CZ', 'Czechia'),
    ('DE', 'Germany'),
    ('DG', 'Diego Garcia'),
    ('DJ', 'Djibouti'),
    ('DK', 'Denmark'),
    ('DM', 'Dominica'),
    ('DO', 'Dominican Republic'),
    ('DZ', 'Algeria'),
    ('EA', 'Ceuta & Melilla'),
    ('EC', 'Ecuador'),
    ('EE', 'Estonia'),
    ('EG', 'Egypt'),
    ('EH', 'Western Sahara'),
    ('ER', 'Eritrea'),
    ('ES', 'Spain'),
    ('ET', 'Ethiopia'),
    ('FI', 'Finland'),
    ('FJ', 'Fiji'),
    ('FK', 'Falkland Islands'),
    ('FM', 'Micronesia'),
    ('FO', 'Faroe Islands'),
    ('FR', 'France'),
    ('GA', 'Gabon'),
    ('GB', 'United Kingdom'),
    ('GD', 'Grenada'),
    ('GE', 'Georgia'),
    ('GF', 'French Guiana'),
    ('GG', 'Guernsey'),
    ('GH', 'Ghana'),
    ('GI', 'Gibraltar'),
    ('GL', 'Greenland'),
    ('GM', 'Gambia'),
    ('GN', 'Guinea'),
    ('GP', 'Guadeloupe'),
    ('GQ', 'Equatorial Guinea'),
    ('GR', 'Greece'),
    ('GS', 'South Georgia & South Sandwich Islands'),
    ('GT', 'Guatemala'),
    ('GU', 'Guam'),
    ('GW', 'Guinea-Bissau'),
    ('GY', 'Guyana'),
    ('HK', 'Hong Kong'),
    ('HM', 'Heard & McDonald Islands'),
    ('HN', 'Honduras'),
    ('HR', 'Croatia'),
    ('HT', 'Haiti'),
    ('HU', 'Hungary'),
    ('IC', 'Canary Islands'),
    ('ID', 'Indonesia'),
    ('IE', 'Ireland'),
    ('IL', 'Israel'),
    ('IM', 'Isle of Man'),
    ('IN', 'India'),
    ('IO', 'British Indian Ocean Territory'),
    ('IQ', 'Iraq'),
    ('IR', 'Iran'),
    ('IS', 'Iceland'),
    ('IT', 'Italy'),
    ('JE', 'Jersey'),
    ('JM', 'Jamaica'),
    ('JO', 'Jordan'),
    ('JP', 'Japan'),
    ('KE', 'Kenya'),
    ('KG', 'Kyrgyzstan'),
    ('KH', 'Cambodia'),
    ('KI', 'Kiribati'),
    ('KM', 'Comoros'),
    ('KN', 'St. Kitts & Nevis'),
    ('KP', 'North Korea'),
    ('KR', 'South Korea'),
    ('KW', 'Kuwait'),
    ('KY', 'Cayman Islands'),
    ('KZ', 'Kazakhstan'),
    ('LA', 'Laos'),
    ('LB', 'Lebanon'),
    ('LC', 'St. Lucia'),
    ('LI', 'Liechtenstein'),
    ('LK', 'Sri Lanka'),
    ('LR', 'Liberia'),
    ('LS', 'Lesotho'),
    ('LT', 'Lithuania'),
    ('LU', 'Luxembourg'),
    ('LV', 'Latvia'),
    ('LY', 'Libya'),
    ('MA', 'Morocco'),
    ('MC', 'Monaco'),
    ('MD', 'Moldova'),
    ('ME', 'Montenegro'),
    ('MF', 'St. Martin'),
    ('MG', 'Madagascar'),
    ('MH', 'Marshall Islands'),
    ('MK', 'North Macedonia'),
    ('ML', 'Mali'),
    ('MM', 'Myanmar (Burma)'),
    ('MN', 'Mongolia'),
    ('MO', 'Macao'),
    ('MP', 'Northern Mariana Islands'),
    ('MQ', 'Martinique'),
    ('MR', 'Mauritania'),
    ('MS', 'Montserrat'),
    ('MT', 'Malta'),
    ('MU', 'Mauritius'),
    ('MV', 'Maldives'),
    ('MW', 'Malawi'),
    ('MX', 'Mexico'),
    ('MY', 'Malaysia'),
    ('MZ', 'Mozambique'),
    ('NA', 'Namibia'),
    ('NC', 'New Caledonia'),
    ('NE', 'Niger'),
    ('NF', 'Norfolk Island'),
    ('NG', 'Nigeria'),
    ('NI', 'Nicaragua'),
    ('NL', 'Netherlands'),
    ('NO', 'Norway'),
    ('NP', 'Nepal'),
    ('NR', 'Nauru'),
    ('NU', 'Niue'),
    ('NZ', 'New Zealand'),
    ('OM', 'Oman'),
    ('PA', 'Panama'),
    ('PE', 'Peru'),
    ('PF', 'French Polynesia'),
    ('PG', 'Papua New Guinea'),
    ('PH', 'Philippines'),
    ('PK', 'Pakistan'),
    ('PL', 'Poland'),
    ('PM', 'St. Pierre & Miquelon'),
    ('PN', 'Pitcairn Islands'),
    ('PR', 'Puerto Rico'),
    ('PS', 'Palestine'),
    ('PT', 'Portugal'),
    ('PW', 'Palau'),
    ('PY', 'Paraguay'),
    ('QA', 'Qatar'),
    ('RE', 'Réunion'),
    ('RO', 'Romania'),
    ('RS', 'Serbia'),
    ('RU', 'Russia'),
    ('RW', 'Rwanda'),
    ('SA', 'Saudi Arabia'),
    ('SB', 'Solomon Islands'),
    ('SC', 'Seychelles'),
    ('SD', 'Sudan'),
    ('SE', 'Sweden'),
    ('SG', 'Singapore'),
    ('SH', 'St. Helena'),
    ('SI', 'Slovenia'),
    ('SJ', 'Svalbard & Jan Mayen'),
    ('SK', 'Slovakia'),
    ('SL', 'Sierra Leone'),
    ('SM', 'San Marino'),
    ('SN', 'Senegal'),
    ('SO', 'Somalia'),
    ('SR', 'Suriname'),
    ('SS', 'South Sudan'),
    ('ST', 'São Tomé & Príncipe'),
    ('SV', 'El Salvador'),
    ('SX', 'Sint Maarten'),
    ('SY', 'Syria'),
    ('SZ', 'Eswatini'),
    ('TA', 'Tristan da Cunha'),
    ('TC', 'Turks & Caicos Islands'),
    ('TD', 'Chad'),
    ('TF', 'French Southern Territories'),
    ('TG', 'Togo'),
    ('TH', 'Thailand'),
    ('TJ', 'Tajikistan'),
    ('TK', 'Tokelau'),
    ('TL', 'Timor-Leste'),
    ('TM', 'Turkmenistan'),
    ('TN', 'Tunisia'),
    ('TO', 'Tonga'),
    ('TR', 'Türkiye'),
    ('TT', 'Trinidad & Tobago'),
    ('TV', 'Tuvalu'),
    ('TW', 'Taiwan'),
    ('TZ', 'Tanzania'),
    ('UA', 'Ukraine'),
    ('UG', 'Uganda'),
    ('UM', 'U.S. Outlying Islands'),
    ('US', 'United States'),
    ('UY', 'Uruguay'),
    ('UZ', 'Uzbekistan'),
    ('VA', 'Vatican City'),
    ('VC', 'St. Vincent & Grenadines'),
    ('VE', 'Venezuela'),
    ('VG', 'British Virgin Islands'),
    ('VI', 'U.S. Virgin Islands'),
    ('VN', 'Vietnam'),
    ('VU', 'Vanuatu'),
    ('WF', 'Wallis & Futuna'),
    ('WS', 'Samoa'),
    ('XK', 'Kosovo'),
    ('YE', 'Yemen'),
    ('YT', 'Mayotte'),
    ('ZA', 'South Africa'),
    ('ZM', 'Zambia'),
    ('ZW', 'Zimbabwe');

-- ---------------------------------------------------------------------
-- Step 3 — name the devices that are already in analytics_events.
-- Numbers follow the order devices first appeared in each country, so
-- the oldest device in Türkiye becomes "Türkiye-1". Does nothing on an
-- empty database. Written without window functions so it also runs on
-- MySQL 5.x / older MariaDB.
-- ---------------------------------------------------------------------

-- Scratch table: each device's first event that has a country.
DROP TABLE IF EXISTS device_naming_tmp;
CREATE TABLE device_naming_tmp (
    device_id CHAR(36) NOT NULL,
    country CHAR(2) NOT NULL,
    first_id BIGINT UNSIGNED NOT NULL,
    first_seen DATETIME NOT NULL,
    PRIMARY KEY (device_id),
    KEY idx_country_first (country, first_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO device_naming_tmp (device_id, country, first_id, first_seen)
SELECT e.device_id, e.country, e.id, e.created_at
FROM analytics_events e
JOIN (
    SELECT MIN(id) AS first_id
    FROM analytics_events
    WHERE country IS NOT NULL
    GROUP BY device_id
) f ON f.first_id = e.id;

-- A device's number = how many devices of the same country appeared no
-- later than it did.
INSERT INTO analytics_devices (device_id, country, seq, device_name, first_seen)
SELECT a.device_id,
       a.country,
       COUNT(*),
       CONCAT(COALESCE(MAX(c.name), a.country), '-', COUNT(*)),
       MAX(a.first_seen)
FROM device_naming_tmp a
JOIN device_naming_tmp b ON b.country = a.country AND b.first_id <= a.first_id
LEFT JOIN country_names c ON c.code = a.country
GROUP BY a.device_id, a.country;

UPDATE analytics_events e
JOIN analytics_devices d ON d.device_id = e.device_id
SET e.device_name = d.device_name;

DROP TABLE device_naming_tmp;
