-- Adds the optional "name" field to feedback messages. Only for a database
-- where feedback.sql was run BEFORE that column existed in it — run this
-- once there, before uploading the feedback.php that stores names. A
-- fresh feedback.sql already creates the column; running this after it
-- fails harmlessly with "Duplicate column name".

ALTER TABLE feedback_messages
    ADD COLUMN name VARCHAR(80) NULL AFTER message;
