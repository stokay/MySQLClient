<?php
// Copy this file to config.php on the server (same directory) and fill in
// the real values. config.php is gitignored — never commit real credentials.

return [
    'db_host' => 'localhost',
    'db_name' => 'your_cpanel_db_name',
    'db_user' => 'your_cpanel_db_user',
    'db_pass' => 'your_cpanel_db_password',

    // Login for dashboard.php (HTTP Basic auth). The dashboard refuses to
    // render while dashboard_pass is still CHANGE_ME.
    'dashboard_user' => 'admin',
    'dashboard_pass' => 'CHANGE_ME',
];
