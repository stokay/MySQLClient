-- Run this once against the MySQL database on tokay.tr before deploying
-- analytics.php. No raw IP address is ever stored — country and network
-- operator are resolved server-side at insert time and the IP is
-- discarded immediately after.

CREATE TABLE IF NOT EXISTS analytics_events (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    device_id CHAR(36) NOT NULL,
    event_name VARCHAR(32) NOT NULL,
    feature VARCHAR(64) NULL,
    -- Code + description together, e.g. "1146 Table doesn't exist".
    -- The client only ever sends the NUMBER (1146); analytics.php looks the
    -- description up in mysql_error_codes below and stores the combined
    -- string. The server's own free-text error message is never sent or
    -- stored — it can echo back real row data (e.g. "Duplicate entry
    -- 'someone@example.com' for key 'PRIMARY'").
    error_code VARCHAR(191) NULL,
    app_version VARCHAR(20) NULL,
    os_version VARCHAR(20) NULL,
    device_model VARCHAR(64) NULL,
    language VARCHAR(10) NULL,
    timezone VARCHAR(64) NULL,
    country CHAR(2) NULL,
    -- Network operator behind the request, resolved from the IP at insert
    -- time alongside the country — then the IP is discarded, same as
    -- before. This is what makes App Review traffic identifiable:
    -- Apple's review machines report org "Apple Inc." / ASN "AS714", so
    -- they can be excluded with a WHERE clause instead of by guessing at
    -- IP ranges. Describes the network, not the person.
    network_org VARCHAR(128) NULL,
    network_asn VARCHAR(64) NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_event_name (event_name),
    KEY idx_error_code (error_code),
    KEY idx_country (country),
    KEY idx_network_asn (network_asn),
    KEY idx_created_at (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Lookup table analytics.php reads at insert time to turn the numeric code
-- the client sent into "1062 Duplicate entry for key". Seeded below with
-- the codes this app is realistically likely to see (auth/connection,
-- constraint violations, syntax, permissions, schema-object-not-found).
-- A code that isn't in this list is stored as the bare number — add a row
-- here by hand when you see one, and events from then on get the text; no
-- need to enumerate MySQL's full ~1000-code list upfront.
CREATE TABLE IF NOT EXISTS mysql_error_codes (
    code SMALLINT UNSIGNED NOT NULL,
    description VARCHAR(191) NOT NULL,
    PRIMARY KEY (code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO mysql_error_codes (code, description) VALUES
    (1045, 'Access denied for user'),
    (1046, 'No database selected'),
    (1049, 'Unknown database'),
    (1050, 'Table already exists'),
    (1051, 'Unknown table'),
    (1054, 'Unknown column in field list'),
    (1062, 'Duplicate entry for key'),
    (1064, 'SQL syntax error'),
    (1091, 'Can''t DROP; check that it exists'),
    (1109, 'Unknown table in field list'),
    (1116, 'Too many tables (join limit)'),
    (1136, 'Column count doesn''t match value count'),
    (1142, 'Command denied to user (missing privilege)'),
    (1143, 'Column command denied to user'),
    (1146, 'Table doesn''t exist'),
    (1147, 'No grant defined for user on host on table'),
    (1149, 'SQL syntax error near'),
    (1152, 'Aborted connection'),
    (1158, 'Got an error reading communication packet'),
    (1159, 'Got timeout reading communication packet'),
    (1160, 'Got an error writing communication packet'),
    (1161, 'Got timeout writing communication packet'),
    (1170, 'BLOB/TEXT column used in key without key length'),
    (1205, 'Lock wait timeout exceeded'),
    (1213, 'Deadlock found when trying to get lock'),
    (1216, 'Cannot add or update a child row (FK constraint)'),
    (1217, 'Cannot delete or update a parent row (FK constraint)'),
    (1227, 'Access denied (privilege required)'),
    (1235, 'Feature not supported by this MySQL version'),
    (1264, 'Value out of range for column'),
    (1265, 'Data truncated for column'),
    (1364, 'Field has no default value'),
    (1366, 'Incorrect value for column'),
    (1406, 'Data too long for column'),
    (1451, 'Cannot delete/update parent row (FK constraint)'),
    (1452, 'Cannot add/update child row (FK constraint)'),
    (1461, 'Max prepared statement count reached'),
    (1524, 'Plugin is not loaded'),
    (1530, 'Table partitioning error'),
    (1592, 'Unsafe statement for binary logging'),
    (1698, 'Access denied (auth plugin mismatch)'),
    (2002, 'Can''t connect (socket)'),
    (2003, 'Can''t connect to MySQL server (host/port)'),
    (2005, 'Unknown MySQL server host'),
    (2006, 'MySQL server has gone away'),
    (2013, 'Lost connection to MySQL server during query'),
    (2026, 'SSL connection error'),
    (2049, 'Old client/server incompatibility (auth protocol)');

-- ---------------------------------------------------------------------
-- Migration, for a database created before error_code became text.
-- Skip this block on a fresh install (the CREATE TABLE above is already
-- correct). Run it ONCE; the WHERE guard makes a repeat run a no-op
-- rather than concatenating the description twice.
-- ---------------------------------------------------------------------
-- ALTER TABLE analytics_events MODIFY error_code VARCHAR(191) NULL;
--
-- UPDATE analytics_events e
--   JOIN mysql_error_codes c ON c.code = e.error_code
--    SET e.error_code = CONCAT(c.code, ' ', c.description)
--  WHERE e.error_code REGEXP '^[0-9]+$';

-- ---------------------------------------------------------------------
-- Migration, for a database created before the network_org/network_asn
-- columns existed. Skip on a fresh install. Existing rows keep NULL —
-- the IP they came from was never stored, so they can't be backfilled.
-- ---------------------------------------------------------------------
-- ALTER TABLE analytics_events
--     ADD COLUMN network_org VARCHAR(128) NULL AFTER country,
--     ADD COLUMN network_asn VARCHAR(64) NULL AFTER network_org,
--     ADD KEY idx_network_asn (network_asn);
