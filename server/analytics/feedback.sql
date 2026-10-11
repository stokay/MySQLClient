-- Feedback: the tables behind the app's "Send Feedback" form
-- (feedback.php receives, feedback-inbox.php shows). Run this file once
-- (e.g. paste it into phpMyAdmin's SQL tab) BEFORE uploading those two
-- files. Safe to run again: it creates nothing that already exists.
--
-- Same on a fresh install and on an existing one — nothing here touches
-- the analytics tables.

SET NAMES utf8mb4;

-- One row per message someone chose to send. Unlike analytics_events
-- this is not anonymous usage data: it holds what the person typed, plus
-- their name and email address if they chose to give them.
--
-- sender_id is a random ID the app keeps for feedback only. It is
-- deliberately NOT the analytics device_id — a message can carry an email
-- address, and sharing the ID would tie that address to the device's
-- whole usage history. It exists so one installation can be limited to a
-- few messages a day, nothing else.
--
-- No IP address, no country: nothing is derived from the connection.
CREATE TABLE IF NOT EXISTS feedback_messages (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    sender_id CHAR(36) NOT NULL,
    category VARCHAR(16) NOT NULL,          -- idea | problem | bug | other
    message TEXT NOT NULL,
    name VARCHAR(80) NULL,                  -- only if the sender gave one, to address them by
    email VARCHAR(254) NULL,                -- only if the sender wants a reply
    -- The "system information" block; all NULL when the sender unticked it.
    app_version VARCHAR(32) NULL,
    os_version VARCHAR(40) NULL,
    device_model VARCHAR(64) NULL,
    language VARCHAR(10) NULL,
    server_info VARCHAR(64) NULL,           -- e.g. "MySQL 8.0.36"; never a host name
    status VARCHAR(12) NOT NULL DEFAULT 'new',   -- new | read | answered | closed
    notified_at DATETIME NULL,              -- when it went out in a notification email
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_created_at (created_at),
    KEY idx_sender_created (sender_id, created_at),
    KEY idx_status (status),
    KEY idx_notified_at (notified_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- A single row: when the last notification email went out. This is what
-- keeps a burst of messages from becoming a burst of emails — whoever
-- moves this timestamp forward gets to send the next one.
CREATE TABLE IF NOT EXISTS feedback_state (
    id TINYINT UNSIGNED NOT NULL,
    last_notified_at DATETIME NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT IGNORE INTO feedback_state (id, last_notified_at) VALUES (1, NULL);
