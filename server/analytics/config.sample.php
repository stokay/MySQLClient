<?php
// Copy this file to config.php on the server (same directory) and fill in
// the real values. config.php is gitignored — never commit real credentials.

return [
    'db_host' => 'localhost',
    'db_name' => 'your_cpanel_db_name',
    'db_user' => 'your_cpanel_db_user',
    'db_pass' => 'your_cpanel_db_password',

    // Login for dashboard.php's own login form. The dashboard refuses to
    // render while dashboard_pass is still CHANGE_ME.
    'dashboard_user' => 'admin',
    'dashboard_pass' => 'CHANGE_ME',

    // Optional: your own device_id (from AnalyticsService's persisted
    // UserDefaults value), so the dashboard can offer a "hide my own
    // testing" toggle. Leave unset to disable that toggle.
    'own_device_id' => '',

    // --- Feedback (feedback.php / feedback-inbox.php) ---

    // false turns the "Send Feedback" endpoint off at once: the app then
    // tells people feedback is unavailable. The off switch for abuse.
    'feedback_enabled' => true,

    // At most this many messages per hour from everyone together. Once
    // reached, further messages are refused until the hour moves on.
    'feedback_max_per_hour' => 30,

    // At most this many messages per day from one installation.
    'feedback_max_per_sender_per_day' => 5,

    // Where "new feedback" emails go. Lives only in this file, on the
    // server — it is not in the app and not in the repository. Leave
    // empty to get no emails (the inbox page still shows everything).
    'feedback_notify_to' => '',

    // The address those emails are sent FROM — one on this server's own
    // domain, or the mail may be rejected as spoofed. Optional.
    'feedback_notify_from' => '',

    // At most one notification email per this many minutes, covering
    // every message since the previous one.
    'feedback_notify_interval_minutes' => 60,

    // Link to the inbox, added to the notification email. Optional.
    'feedback_inbox_url' => 'https://tokay.tr/MySQLClient/analytics/feedback-inbox.php',
];
