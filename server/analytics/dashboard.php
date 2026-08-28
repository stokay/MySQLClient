<?php
/**
 * Analytics dashboard for MySQL Client — reads the events analytics.php
 * writes and renders them as charts and sortable tables.
 *
 * Deployment: upload next to analytics.php (same directory, so it picks
 * up the same config.php), then open
 * https://tokay.tr/MySQLClient/analytics/dashboard.php
 *
 * Access: a login form (not the browser's native Basic Auth popup — that
 * can't carry a "remember me" checkbox), credentials from config.php
 * (`dashboard_user` / `dashboard_pass`). The page refuses to render at
 * all while the password is still the placeholder — analytics data
 * shouldn't sit on a public URL. On success, a signed cookie
 * (HMAC of the username keyed by the password — no server-side session
 * storage needed) is set: session-only by default, or ~90 days if
 * "remember me" was checked. Nothing about the password itself is ever
 * stored in the cookie.
 */

declare(strict_types=1);

$config = require __DIR__ . '/config.php';

// ---------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------
const DASHBOARD_AUTH_COOKIE = 'mysqlclient_dash_auth';

$expectedUser = (string) ($config['dashboard_user'] ?? '');
$expectedPass = (string) ($config['dashboard_pass'] ?? '');

if ($expectedPass === '' || $expectedPass === 'CHANGE_ME') {
    http_response_code(500);
    exit('Set dashboard_user / dashboard_pass in config.php before using this page.');
}

/** The cookie never carries the password itself — just proof it was known at login time. */
function dashboardAuthToken(string $user, string $pass): string
{
    return hash_hmac('sha256', $user, $pass);
}

$isAuthenticated = isset($_COOKIE[DASHBOARD_AUTH_COOKIE])
    && hash_equals(dashboardAuthToken($expectedUser, $expectedPass), (string) $_COOKIE[DASHBOARD_AUTH_COOKIE]);

$loginError = null;
if (!$isAuthenticated && $_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['dashboard_login'])) {
    $givenUser = (string) ($_POST['username'] ?? '');
    $givenPass = (string) ($_POST['password'] ?? '');
    if (hash_equals($expectedUser, $givenUser) && hash_equals($expectedPass, $givenPass)) {
        $rememberMe = !empty($_POST['remember_me']);
        setcookie(DASHBOARD_AUTH_COOKIE, dashboardAuthToken($expectedUser, $expectedPass), [
            'expires' => $rememberMe ? time() + 60 * 60 * 24 * 90 : 0, // 0 = until the browser closes
            'path' => '/',
            'secure' => true,
            'httponly' => true,
            'samesite' => 'Strict',
        ]);
        $isAuthenticated = true;
    } else {
        $loginError = 'Incorrect username or password.';
    }
}

if (!$isAuthenticated) {
    http_response_code(200);
    ?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>MySQL Client — Analytics</title>
<style>
  :root {
    --bg: #f5f6f8; --surface: #ffffff; --border: #e4e7ec; --text: #16191d;
    --muted: #6b7482; --accent: #3b6ef5; --danger: #d93a3a;
    --shadow: 0 1px 2px rgba(16,20,28,.06), 0 4px 16px rgba(16,20,28,.05);
    --radius: 12px; color-scheme: light;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0d1117; --surface: #151a21; --border: #262d38; --text: #e6edf3;
      --muted: #8b949e; --accent: #5b8cff; --danger: #f0665f;
      --shadow: 0 1px 2px rgba(0,0,0,.3), 0 4px 16px rgba(0,0,0,.25);
      color-scheme: dark;
    }
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: var(--bg); color: var(--text); min-height: 100vh;
    display: flex; align-items: center; justify-content: center;
    font: 14px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, sans-serif;
  }
  form {
    width: 100%; max-width: 320px; background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--radius); box-shadow: var(--shadow); padding: 28px;
  }
  h1 { font-size: 17px; font-weight: 650; margin-bottom: 20px; }
  label { display: block; font-size: 13px; color: var(--muted); margin: 14px 0 6px; }
  input[type="text"], input[type="password"] {
    width: 100%; padding: 9px 11px; border-radius: 8px; border: 1px solid var(--border);
    background: var(--bg); color: var(--text); font: inherit;
  }
  .remember { display: flex; align-items: center; gap: 8px; margin-top: 16px; font-size: 13px; color: var(--text); }
  .remember input { width: auto; }
  button {
    width: 100%; margin-top: 20px; padding: 10px; border-radius: 8px; border: none;
    background: var(--accent); color: #fff; font: inherit; font-weight: 600; cursor: pointer;
  }
  .error { color: var(--danger); font-size: 13px; margin-top: 12px; }
</style>
</head>
<body>
  <form method="post" autocomplete="off">
    <h1>MySQL Client — Analytics</h1>
    <label for="username">Username</label>
    <input id="username" type="text" name="username" autofocus required>
    <label for="password">Password</label>
    <input id="password" type="password" name="password" required>
    <label class="remember"><input type="checkbox" name="remember_me" value="1"> Remember me</label>
    <?php if ($loginError !== null): ?><div class="error"><?= htmlspecialchars($loginError, ENT_QUOTES, 'UTF-8') ?></div><?php endif; ?>
    <button type="submit" name="dashboard_login" value="1">Sign in</button>
  </form>
</body>
</html>
    <?php
    exit;
}

// ---------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------
$rangeDays = ['week' => 7, 'month' => 30, 'all' => null];
$range = $_GET['range'] ?? 'month';
if (!array_key_exists($range, $rangeDays)) {
    $range = 'month';
}
$days = $rangeDays[$range];

// Apple's App Review machines report ASN AS714 — excluded by default so
// review sessions don't distort real usage. Toggleable, because during a
// review you may specifically want to confirm the build phoned home.
$excludeReview = ($_GET['review'] ?? '0') !== '1';

// Your own device, from config.php — hidden by default for the same
// reason as review traffic: your own testing shouldn't drown out real
// usage in these numbers. Validated as a UUID shape before use since it
// goes into raw SQL below; a blank/malformed config value just disables
// the toggle rather than being spliced in as-is.
$ownDeviceId = (string) ($config['own_device_id'] ?? '');
if (!preg_match('/^[0-9A-Fa-f-]{36}$/', $ownDeviceId)) {
    $ownDeviceId = null;
}
$excludeMine = ($_GET['mine'] ?? '0') !== '1';

$conditions = [];
if ($days !== null) {
    // $days comes from the whitelist above, never from raw input.
    $conditions[] = "created_at >= DATE_SUB(NOW(), INTERVAL {$days} DAY)";
}
if ($excludeReview) {
    $conditions[] = "(network_asn IS NULL OR network_asn NOT LIKE 'AS714%')";
}
if ($excludeMine && $ownDeviceId !== null) {
    $conditions[] = "device_id != '{$ownDeviceId}'"; // regex-validated above, safe to interpolate
}
$where = $conditions ? implode(' AND ', $conditions) : '1=1';

/** Builds a query string for the current page carrying all three filters — the single place that knows how they combine, so no toggle link can forget one. */
function filterUrl(string $range, bool $excludeReview, bool $excludeMine): string
{
    $params = ['range' => $range];
    if (!$excludeReview) { $params['review'] = '1'; }
    if (!$excludeMine) { $params['mine'] = '1'; }
    return '?' . http_build_query($params);
}

// ---------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------
try {
    $pdo = new PDO(
        "mysql:host={$config['db_host']};dbname={$config['db_name']};charset=utf8mb4",
        $config['db_user'],
        $config['db_pass'],
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]
    );
} catch (Throwable $e) {
    http_response_code(500);
    exit('Database connection failed.');
}

/** Runs a SELECT against analytics_events with the active filters applied. */
function q(PDO $pdo, string $sql): array
{
    return $pdo->query($sql)->fetchAll();
}

$kpi = q($pdo, "
    SELECT
        COUNT(*)                                        AS events,
        COUNT(DISTINCT device_id)                       AS devices,
        SUM(event_name = 'app_open')                    AS opens,
        SUM(event_name = 'error')                       AS errors
    FROM analytics_events WHERE {$where}
")[0] ?? ['events' => 0, 'devices' => 0, 'opens' => 0, 'errors' => 0];

$daily = q($pdo, "
    SELECT DATE(created_at) AS day, COUNT(*) AS events, COUNT(DISTINCT device_id) AS devices
    FROM analytics_events WHERE {$where}
    GROUP BY DATE(created_at) ORDER BY day
");

$countries = q($pdo, "
    SELECT country, COUNT(DISTINCT device_id) AS devices, COUNT(*) AS events
    FROM analytics_events WHERE {$where} AND country IS NOT NULL
    GROUP BY country ORDER BY devices DESC, events DESC LIMIT 60
");

$languages = q($pdo, "
    SELECT language, COUNT(DISTINCT device_id) AS devices, COUNT(*) AS events
    FROM analytics_events WHERE {$where} AND language IS NOT NULL
    GROUP BY language ORDER BY devices DESC LIMIT 40
");

$features = q($pdo, "
    SELECT feature, COUNT(*) AS uses, COUNT(DISTINCT device_id) AS devices
    FROM analytics_events
    WHERE {$where} AND event_name = 'feature_used' AND feature IS NOT NULL
    GROUP BY feature ORDER BY uses DESC
");

$errors = q($pdo, "
    SELECT error_code, feature, COUNT(*) AS hits, COUNT(DISTINCT device_id) AS devices
    FROM analytics_events
    WHERE {$where} AND event_name = 'error' AND error_code IS NOT NULL
    GROUP BY error_code, feature ORDER BY hits DESC LIMIT 60
");

$versions = q($pdo, "
    SELECT app_version, COUNT(DISTINCT device_id) AS devices, COUNT(*) AS events
    FROM analytics_events WHERE {$where} AND app_version IS NOT NULL
    GROUP BY app_version ORDER BY devices DESC LIMIT 30
");

$osVersions = q($pdo, "
    SELECT os_version, COUNT(DISTINCT device_id) AS devices
    FROM analytics_events WHERE {$where} AND os_version IS NOT NULL
    GROUP BY os_version ORDER BY devices DESC LIMIT 30
");

$models = q($pdo, "
    SELECT device_model, COUNT(DISTINCT device_id) AS devices
    FROM analytics_events WHERE {$where} AND device_model IS NOT NULL
    GROUP BY device_model ORDER BY devices DESC LIMIT 30
");

$networks = q($pdo, "
    SELECT network_org, network_asn, COUNT(DISTINCT device_id) AS devices, COUNT(*) AS events
    FROM analytics_events WHERE {$where} AND network_org IS NOT NULL
    GROUP BY network_org, network_asn ORDER BY events DESC LIMIT 30
");

$recent = q($pdo, "
    SELECT device_id, event_name, feature, error_code, app_version, country, language, created_at
    FROM analytics_events WHERE {$where}
    ORDER BY id DESC LIMIT 60
");

// Review traffic is counted regardless of the toggle, so the banner can
// say how much is being hidden.
$reviewCount = (int) ($pdo->query("
    SELECT COUNT(*) AS c FROM analytics_events
    WHERE network_asn LIKE 'AS714%'
    " . ($days !== null ? "AND created_at >= DATE_SUB(NOW(), INTERVAL {$days} DAY)" : '')
)->fetch()['c'] ?? 0);

$ownCount = 0;
if ($ownDeviceId !== null) {
    $ownCount = (int) ($pdo->query("
        SELECT COUNT(*) AS c FROM analytics_events
        WHERE device_id = '{$ownDeviceId}'
        " . ($days !== null ? "AND created_at >= DATE_SUB(NOW(), INTERVAL {$days} DAY)" : '')
    )->fetch()['c'] ?? 0);
}

// Fill gaps so the chart shows quiet days as zero rather than skipping them.
$series = [];
if ($days !== null) {
    $byDay = [];
    foreach ($daily as $row) {
        $byDay[$row['day']] = $row;
    }
    for ($i = $days - 1; $i >= 0; $i--) {
        $day = date('Y-m-d', strtotime("-{$i} day"));
        $series[] = [
            'day' => $day,
            'events' => (int) ($byDay[$day]['events'] ?? 0),
            'devices' => (int) ($byDay[$day]['devices'] ?? 0),
        ];
    }
} else {
    foreach ($daily as $row) {
        $series[] = [
            'day' => $row['day'],
            'events' => (int) $row['events'],
            'devices' => (int) $row['devices'],
        ];
    }
}

function h(?string $value): string
{
    return htmlspecialchars((string) $value, ENT_QUOTES, 'UTF-8');
}

/** Percentage of the largest value in a column, for the inline bars. */
function share(int $value, int $max): float
{
    return $max > 0 ? round(($value / $max) * 100, 1) : 0.0;
}

function maxOf(array $rows, string $key): int
{
    $max = 0;
    foreach ($rows as $row) {
        $max = max($max, (int) $row[$key]);
    }
    return $max;
}

$rangeLabels = ['week' => 'Last 7 days', 'month' => 'Last 30 days', 'all' => 'All time'];
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>MySQL Client — Analytics</title>
<style>
  :root {
    --bg: #f5f6f8;
    --surface: #ffffff;
    --surface-2: #fafbfc;
    --border: #e4e7ec;
    --text: #16191d;
    --muted: #6b7482;
    --accent: #3b6ef5;
    --accent-soft: rgba(59, 110, 245, .12);
    --accent-2: #17a67c;
    --danger: #d93a3a;
    --shadow: 0 1px 2px rgba(16, 20, 28, .06), 0 4px 16px rgba(16, 20, 28, .05);
    --radius: 12px;
    color-scheme: light;
  }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      --bg: #0d1117;
      --surface: #151a21;
      --surface-2: #1a2029;
      --border: #262d38;
      --text: #e6edf3;
      --muted: #8b949e;
      --accent: #5b8cff;
      --accent-soft: rgba(91, 140, 255, .16);
      --accent-2: #3fb98a;
      --danger: #f0665f;
      --shadow: 0 1px 2px rgba(0, 0, 0, .3), 0 4px 16px rgba(0, 0, 0, .25);
      color-scheme: dark;
    }
  }
  :root[data-theme="dark"] {
    --bg: #0d1117;
    --surface: #151a21;
    --surface-2: #1a2029;
    --border: #262d38;
    --text: #e6edf3;
    --muted: #8b949e;
    --accent: #5b8cff;
    --accent-soft: rgba(91, 140, 255, .16);
    --accent-2: #3fb98a;
    --danger: #f0665f;
    --shadow: 0 1px 2px rgba(0, 0, 0, .3), 0 4px 16px rgba(0, 0, 0, .25);
    color-scheme: dark;
  }

  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: var(--bg);
    color: var(--text);
    font: 14px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, sans-serif;
    -webkit-font-smoothing: antialiased;
    padding: 28px 20px 64px;
  }
  .wrap { max-width: 1180px; margin: 0 auto; }

  header.top {
    display: flex; flex-wrap: wrap; gap: 16px;
    align-items: center; justify-content: space-between;
    margin-bottom: 22px;
  }
  .title h1 { font-size: 20px; font-weight: 650; letter-spacing: -.01em; }
  .title p { color: var(--muted); font-size: 13px; margin-top: 2px; }
  .controls { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }

  .segmented {
    display: inline-flex; background: var(--surface); border: 1px solid var(--border);
    border-radius: 9px; padding: 3px; box-shadow: var(--shadow);
  }
  .segmented a {
    display: block; padding: 6px 13px; border-radius: 6px; font-size: 13px;
    font-weight: 500; color: var(--muted); text-decoration: none; white-space: nowrap;
    transition: background .15s, color .15s;
  }
  .segmented a:hover { color: var(--text); }
  .segmented a[aria-current="true"] { background: var(--accent); color: #fff; }

  .btn {
    display: inline-flex; align-items: center; gap: 7px;
    background: var(--surface); border: 1px solid var(--border); color: var(--muted);
    border-radius: 9px; padding: 8px 13px; font: inherit; font-size: 13px; font-weight: 500;
    cursor: pointer; text-decoration: none; box-shadow: var(--shadow);
    transition: color .15s, border-color .15s;
  }
  .btn:hover { color: var(--text); }
  .btn.on { color: var(--accent); border-color: var(--accent); background: var(--accent-soft); }

  .kpis {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
    gap: 14px; margin-bottom: 18px;
  }
  .kpi {
    background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius);
    padding: 16px 18px; box-shadow: var(--shadow);
  }
  .kpi .label { color: var(--muted); font-size: 12px; font-weight: 500; text-transform: uppercase; letter-spacing: .05em; }
  .kpi .value { font-size: 28px; font-weight: 650; letter-spacing: -.02em; margin-top: 6px; font-variant-numeric: tabular-nums; }
  .kpi.danger .value { color: var(--danger); }

  .card {
    background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius);
    box-shadow: var(--shadow); margin-bottom: 18px; overflow: hidden;
  }
  .card > h2 {
    font-size: 14px; font-weight: 600; padding: 14px 18px;
    border-bottom: 1px solid var(--border); display: flex; justify-content: space-between; align-items: baseline;
  }
  .card > h2 span { color: var(--muted); font-weight: 450; font-size: 12px; }
  .card .body { padding: 16px 18px; }

  .grid2 { display: grid; grid-template-columns: repeat(auto-fit, minmax(430px, 1fr)); gap: 18px; }
  .grid2 .card { margin-bottom: 0; }

  .banner {
    background: var(--accent-soft); border: 1px solid var(--border); color: var(--text);
    border-radius: 10px; padding: 10px 14px; font-size: 13px; margin-bottom: 18px;
    display: flex; gap: 10px; align-items: center; flex-wrap: wrap;
  }
  .banner a { color: var(--accent); }

  .scroll { max-height: 420px; overflow: auto; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 9px 18px; border-bottom: 1px solid var(--border); }
  thead th {
    position: sticky; top: 0; background: var(--surface-2); z-index: 1;
    color: var(--muted); font-size: 11px; font-weight: 600;
    text-transform: uppercase; letter-spacing: .05em; white-space: nowrap;
  }
  th[data-sortable] { cursor: pointer; user-select: none; }
  th[data-sortable]:hover { color: var(--text); }
  th[data-sortable]::after { content: "↕"; opacity: .3; margin-left: 5px; font-size: 10px; }
  th.sorted-asc::after { content: "↑"; opacity: 1; color: var(--accent); }
  th.sorted-desc::after { content: "↓"; opacity: 1; color: var(--accent); }
  tbody tr:last-child td { border-bottom: none; }
  tbody tr:hover { background: var(--surface-2); }
  td.num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
  td.mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; color: var(--muted); }

  .bar-cell { width: 34%; min-width: 90px; }
  .bar { height: 6px; border-radius: 3px; background: var(--accent); opacity: .85; min-width: 2px; }
  .bar.alt { background: var(--accent-2); }
  .bar.warn { background: var(--danger); }

  .chart-wrap { position: relative; }
  #chart { width: 100%; height: 260px; display: block; }
  .legend { display: flex; gap: 18px; align-items: center; font-size: 12px; color: var(--muted); padding: 0 18px 14px; }
  .legend i { display: inline-block; width: 10px; height: 10px; border-radius: 3px; margin-right: 6px; vertical-align: -1px; }
  .tip {
    position: absolute; pointer-events: none; opacity: 0; transition: opacity .12s;
    background: var(--surface); border: 1px solid var(--border); border-radius: 8px;
    padding: 8px 11px; font-size: 12px; box-shadow: var(--shadow); white-space: nowrap; z-index: 5;
  }
  .tip b { font-weight: 600; }

  .empty { padding: 34px 18px; text-align: center; color: var(--muted); font-size: 13px; }
  footer { color: var(--muted); font-size: 12px; text-align: center; margin-top: 26px; }
</style>
</head>
<body>
<div class="wrap">

  <header class="top">
    <div class="title">
      <h1>MySQL Client — Analytics</h1>
      <p><?= h($rangeLabels[$range]) ?> · updated <?= h(date('d M Y, H:i')) ?></p>
    </div>
    <div class="controls">
      <nav class="segmented">
        <?php foreach ($rangeLabels as $key => $label): ?>
          <a href="<?= h(filterUrl($key, $excludeReview, $excludeMine)) ?>"
             aria-current="<?= $key === $range ? 'true' : 'false' ?>"><?= h($label) ?></a>
        <?php endforeach; ?>
      </nav>
      <a class="btn <?= $excludeReview ? 'on' : '' ?>"
         href="<?= h(filterUrl($range, !$excludeReview, $excludeMine)) ?>">
        <?= $excludeReview ? 'Review traffic hidden' : 'Review traffic shown' ?>
      </a>
      <?php if ($ownDeviceId !== null): ?>
      <a class="btn <?= $excludeMine ? 'on' : '' ?>"
         href="<?= h(filterUrl($range, $excludeReview, !$excludeMine)) ?>">
        <?= $excludeMine ? 'My testing hidden' : 'My testing shown' ?>
      </a>
      <?php endif; ?>
      <button class="btn" id="theme" type="button" title="Toggle theme">Theme</button>
    </div>
  </header>

  <?php if ($excludeReview && $reviewCount > 0): ?>
    <div class="banner">
      <span><strong><?= number_format($reviewCount) ?></strong> event<?= $reviewCount === 1 ? '' : 's' ?> from Apple's network (AS714) hidden — likely App Review.</span>
      <a href="<?= h(filterUrl($range, false, $excludeMine)) ?>">Show them</a>
    </div>
  <?php endif; ?>

  <?php if ($excludeMine && $ownCount > 0): ?>
    <div class="banner">
      <span><strong><?= number_format($ownCount) ?></strong> event<?= $ownCount === 1 ? '' : 's' ?> from your own device hidden.</span>
      <a href="<?= h(filterUrl($range, $excludeReview, false)) ?>">Show them</a>
    </div>
  <?php endif; ?>

  <section class="kpis">
    <div class="kpi"><div class="label">Events</div><div class="value"><?= number_format((int) $kpi['events']) ?></div></div>
    <div class="kpi"><div class="label">Unique devices</div><div class="value"><?= number_format((int) $kpi['devices']) ?></div></div>
    <div class="kpi"><div class="label">App opens</div><div class="value"><?= number_format((int) $kpi['opens']) ?></div></div>
    <div class="kpi <?= (int) $kpi['errors'] > 0 ? 'danger' : '' ?>"><div class="label">Errors</div><div class="value"><?= number_format((int) $kpi['errors']) ?></div></div>
  </section>

  <section class="card">
    <h2>Activity <span>events and unique devices per day</span></h2>
    <div class="chart-wrap">
      <svg id="chart" role="img" aria-label="Daily activity chart"></svg>
      <div class="tip" id="tip"></div>
    </div>
    <div class="legend">
      <span><i style="background: var(--accent)"></i>Events</span>
      <span><i style="background: var(--accent-2)"></i>Unique devices</span>
    </div>
  </section>

  <div class="grid2">

    <section class="card">
      <h2>Countries <span>where the app is used</span></h2>
      <?php if (!$countries): ?><div class="empty">No data in this range.</div><?php else: $m = maxOf($countries, 'devices'); ?>
      <div class="scroll"><table data-sortable-table>
        <thead><tr>
          <th data-sortable data-type="text">Country</th>
          <th data-sortable data-type="num" class="num">Devices</th>
          <th data-sortable data-type="num" class="num">Events</th>
          <th class="bar-cell"></th>
        </tr></thead>
        <tbody>
        <?php foreach ($countries as $row): ?>
          <tr>
            <td class="country" data-cc="<?= h($row['country']) ?>"><?= h($row['country']) ?></td>
            <td class="num" data-sort="<?= (int) $row['devices'] ?>"><?= number_format((int) $row['devices']) ?></td>
            <td class="num" data-sort="<?= (int) $row['events'] ?>"><?= number_format((int) $row['events']) ?></td>
            <td class="bar-cell"><div class="bar" style="width: <?= share((int) $row['devices'], $m) ?>%"></div></td>
          </tr>
        <?php endforeach; ?>
        </tbody>
      </table></div>
      <?php endif; ?>
    </section>

    <section class="card">
      <h2>Languages <span>what to localize next</span></h2>
      <?php if (!$languages): ?><div class="empty">No data in this range.</div><?php else: $m = maxOf($languages, 'devices'); ?>
      <div class="scroll"><table data-sortable-table>
        <thead><tr>
          <th data-sortable data-type="text">Language</th>
          <th data-sortable data-type="num" class="num">Devices</th>
          <th data-sortable data-type="num" class="num">Events</th>
          <th class="bar-cell"></th>
        </tr></thead>
        <tbody>
        <?php foreach ($languages as $row): ?>
          <tr>
            <td class="lang" data-lc="<?= h($row['language']) ?>"><?= h($row['language']) ?></td>
            <td class="num" data-sort="<?= (int) $row['devices'] ?>"><?= number_format((int) $row['devices']) ?></td>
            <td class="num" data-sort="<?= (int) $row['events'] ?>"><?= number_format((int) $row['events']) ?></td>
            <td class="bar-cell"><div class="bar alt" style="width: <?= share((int) $row['devices'], $m) ?>%"></div></td>
          </tr>
        <?php endforeach; ?>
        </tbody>
      </table></div>
      <?php endif; ?>
    </section>

    <section class="card">
      <h2>Features <span>what people actually use</span></h2>
      <?php if (!$features): ?><div class="empty">No feature usage in this range.</div><?php else: $m = maxOf($features, 'uses'); ?>
      <div class="scroll"><table data-sortable-table>
        <thead><tr>
          <th data-sortable data-type="text">Feature</th>
          <th data-sortable data-type="num" class="num">Uses</th>
          <th data-sortable data-type="num" class="num">Devices</th>
          <th class="bar-cell"></th>
        </tr></thead>
        <tbody>
        <?php foreach ($features as $row): ?>
          <tr>
            <td><?= h(ucwords(str_replace('_', ' ', (string) $row['feature']))) ?></td>
            <td class="num" data-sort="<?= (int) $row['uses'] ?>"><?= number_format((int) $row['uses']) ?></td>
            <td class="num" data-sort="<?= (int) $row['devices'] ?>"><?= number_format((int) $row['devices']) ?></td>
            <td class="bar-cell"><div class="bar" style="width: <?= share((int) $row['uses'], $m) ?>%"></div></td>
          </tr>
        <?php endforeach; ?>
        </tbody>
      </table></div>
      <?php endif; ?>
    </section>

    <section class="card">
      <h2>Errors <span>code and where it happened</span></h2>
      <?php if (!$errors): ?><div class="empty">No errors in this range. 🎉</div><?php else: $m = maxOf($errors, 'hits'); ?>
      <div class="scroll"><table data-sortable-table>
        <thead><tr>
          <th data-sortable data-type="text">Error</th>
          <th data-sortable data-type="text">Feature</th>
          <th data-sortable data-type="num" class="num">Hits</th>
          <th class="bar-cell"></th>
        </tr></thead>
        <tbody>
        <?php foreach ($errors as $row): ?>
          <tr>
            <td><?= h($row['error_code']) ?></td>
            <td class="mono"><?= h($row['feature'] ?? '—') ?></td>
            <td class="num" data-sort="<?= (int) $row['hits'] ?>"><?= number_format((int) $row['hits']) ?></td>
            <td class="bar-cell"><div class="bar warn" style="width: <?= share((int) $row['hits'], $m) ?>%"></div></td>
          </tr>
        <?php endforeach; ?>
        </tbody>
      </table></div>
      <?php endif; ?>
    </section>

    <section class="card">
      <h2>App versions <span>update adoption</span></h2>
      <?php if (!$versions): ?><div class="empty">No data in this range.</div><?php else: $m = maxOf($versions, 'devices'); ?>
      <div class="scroll"><table data-sortable-table>
        <thead><tr>
          <th data-sortable data-type="text">Version</th>
          <th data-sortable data-type="num" class="num">Devices</th>
          <th data-sortable data-type="num" class="num">Events</th>
          <th class="bar-cell"></th>
        </tr></thead>
        <tbody>
        <?php foreach ($versions as $row): ?>
          <tr>
            <td class="mono"><?= h($row['app_version']) ?></td>
            <td class="num" data-sort="<?= (int) $row['devices'] ?>"><?= number_format((int) $row['devices']) ?></td>
            <td class="num" data-sort="<?= (int) $row['events'] ?>"><?= number_format((int) $row['events']) ?></td>
            <td class="bar-cell"><div class="bar" style="width: <?= share((int) $row['devices'], $m) ?>%"></div></td>
          </tr>
        <?php endforeach; ?>
        </tbody>
      </table></div>
      <?php endif; ?>
    </section>

    <section class="card">
      <h2>macOS versions <span>minimum-target planning</span></h2>
      <?php if (!$osVersions): ?><div class="empty">No data in this range.</div><?php else: $m = maxOf($osVersions, 'devices'); ?>
      <div class="scroll"><table data-sortable-table>
        <thead><tr>
          <th data-sortable data-type="text">macOS</th>
          <th data-sortable data-type="num" class="num">Devices</th>
          <th class="bar-cell"></th>
        </tr></thead>
        <tbody>
        <?php foreach ($osVersions as $row): ?>
          <tr>
            <td class="mono"><?= h($row['os_version']) ?></td>
            <td class="num" data-sort="<?= (int) $row['devices'] ?>"><?= number_format((int) $row['devices']) ?></td>
            <td class="bar-cell"><div class="bar alt" style="width: <?= share((int) $row['devices'], $m) ?>%"></div></td>
          </tr>
        <?php endforeach; ?>
        </tbody>
      </table></div>
      <?php endif; ?>
    </section>

    <section class="card">
      <h2>Mac models</h2>
      <?php if (!$models): ?><div class="empty">No data in this range.</div><?php else: $m = maxOf($models, 'devices'); ?>
      <div class="scroll"><table data-sortable-table>
        <thead><tr>
          <th data-sortable data-type="text">Model</th>
          <th data-sortable data-type="num" class="num">Devices</th>
          <th class="bar-cell"></th>
        </tr></thead>
        <tbody>
        <?php foreach ($models as $row): ?>
          <tr>
            <td class="mono"><?= h($row['device_model']) ?></td>
            <td class="num" data-sort="<?= (int) $row['devices'] ?>"><?= number_format((int) $row['devices']) ?></td>
            <td class="bar-cell"><div class="bar" style="width: <?= share((int) $row['devices'], $m) ?>%"></div></td>
          </tr>
        <?php endforeach; ?>
        </tbody>
      </table></div>
      <?php endif; ?>
    </section>

    <section class="card">
      <h2>Networks <span>useful for spotting review traffic</span></h2>
      <?php if (!$networks): ?><div class="empty">No data in this range.</div><?php else: $m = maxOf($networks, 'events'); ?>
      <div class="scroll"><table data-sortable-table>
        <thead><tr>
          <th data-sortable data-type="text">Operator</th>
          <th data-sortable data-type="text">ASN</th>
          <th data-sortable data-type="num" class="num">Events</th>
          <th class="bar-cell"></th>
        </tr></thead>
        <tbody>
        <?php foreach ($networks as $row): ?>
          <tr>
            <td><?= h($row['network_org']) ?></td>
            <td class="mono"><?= h(explode(' ', (string) $row['network_asn'])[0] ?? '—') ?></td>
            <td class="num" data-sort="<?= (int) $row['events'] ?>"><?= number_format((int) $row['events']) ?></td>
            <td class="bar-cell"><div class="bar" style="width: <?= share((int) $row['events'], $m) ?>%"></div></td>
          </tr>
        <?php endforeach; ?>
        </tbody>
      </table></div>
      <?php endif; ?>
    </section>

  </div>

  <section class="card" style="margin-top: 18px;">
    <h2>Recent events <span>latest 60</span></h2>
    <?php if (!$recent): ?><div class="empty">Nothing recorded in this range.</div><?php else: ?>
    <div class="scroll"><table data-sortable-table>
      <thead><tr>
        <th data-sortable data-type="text">When</th>
        <th data-sortable data-type="text">Country</th>
        <th data-sortable data-type="text">Language</th>
        <th data-sortable data-type="text">Event</th>
        <th data-sortable data-type="text">Detail</th>
        <th data-sortable data-type="text">Version</th>
      </tr></thead>
      <tbody>
      <?php foreach ($recent as $row): ?>
        <tr>
          <td class="mono" data-sort="<?= h($row['created_at']) ?>"><?= h(date('d M H:i', strtotime((string) $row['created_at']))) ?></td>
          <td class="country" data-cc="<?= h($row['country']) ?>"><?= h($row['country'] ?? '—') ?></td>
          <td class="lang" data-lc="<?= h($row['language']) ?>"><?= h($row['language'] ?? '—') ?></td>
          <td><?= h(str_replace('_', ' ', (string) $row['event_name'])) ?></td>
          <td class="mono"><?= h($row['error_code'] ?? $row['feature'] ?? '—') ?></td>
          <td class="mono"><?= h($row['app_version'] ?? '—') ?></td>
        </tr>
      <?php endforeach; ?>
      </tbody>
    </table></div>
    <?php endif; ?>
  </section>

  <footer>MySQL Client analytics · no IP addresses are stored</footer>
</div>

<script>
(function () {
  // ---- Theme -------------------------------------------------------
  var root = document.documentElement;
  try {
    var saved = localStorage.getItem('dash-theme');
    if (saved) root.setAttribute('data-theme', saved);
  } catch (e) {}
  document.getElementById('theme').addEventListener('click', function () {
    var isDark = root.getAttribute('data-theme') === 'dark' ||
      (!root.hasAttribute('data-theme') && matchMedia('(prefers-color-scheme: dark)').matches);
    var next = isDark ? 'light' : 'dark';
    root.setAttribute('data-theme', next);
    try { localStorage.setItem('dash-theme', next); } catch (e) {}
    draw();
  });

  // ---- Friendly country / language names ---------------------------
  var regionNames = null, langNames = null;
  try {
    regionNames = new Intl.DisplayNames(['en'], { type: 'region' });
    langNames = new Intl.DisplayNames(['en'], { type: 'language' });
  } catch (e) {}

  function flag(cc) {
    if (!cc || cc.length !== 2) return '';
    return String.fromCodePoint.apply(null, cc.toUpperCase().split('').map(function (c) {
      return 0x1F1A5 + c.charCodeAt(0);
    }));
  }

  document.querySelectorAll('td.country').forEach(function (td) {
    var cc = td.dataset.cc;
    if (!cc) return;
    var name = cc;
    try { name = regionNames ? regionNames.of(cc) : cc; } catch (e) {}
    td.textContent = flag(cc) + ' ' + name;
  });
  document.querySelectorAll('td.lang').forEach(function (td) {
    var lc = td.dataset.lc;
    if (!lc) return;
    var name = lc;
    try { name = langNames ? langNames.of(lc) : lc; } catch (e) {}
    td.textContent = name + ' (' + lc + ')';
  });

  // ---- Sortable tables ---------------------------------------------
  document.querySelectorAll('table[data-sortable-table]').forEach(function (table) {
    table.querySelectorAll('th[data-sortable]').forEach(function (th) {
      th.addEventListener('click', function () {
        var index = th.cellIndex;
        var numeric = th.dataset.type === 'num';
        var dir = th.classList.contains('sorted-asc') ? 'desc' : 'asc';
        table.querySelectorAll('th').forEach(function (o) {
          o.classList.remove('sorted-asc', 'sorted-desc');
        });
        th.classList.add(dir === 'asc' ? 'sorted-asc' : 'sorted-desc');

        var body = table.tBodies[0];
        var rows = Array.prototype.slice.call(body.rows);
        rows.sort(function (a, b) {
          var av = a.cells[index], bv = b.cells[index];
          var x = av ? (av.dataset.sort !== undefined ? av.dataset.sort : av.textContent.trim()) : '';
          var y = bv ? (bv.dataset.sort !== undefined ? bv.dataset.sort : bv.textContent.trim()) : '';
          if (numeric) {
            x = parseFloat(x) || 0; y = parseFloat(y) || 0;
            return dir === 'asc' ? x - y : y - x;
          }
          return dir === 'asc'
            ? String(x).localeCompare(String(y), undefined, { numeric: true })
            : String(y).localeCompare(String(x), undefined, { numeric: true });
        });
        rows.forEach(function (r) { body.appendChild(r); });
      });
    });
  });

  // ---- Activity chart ----------------------------------------------
  var data = <?= json_encode($series, JSON_UNESCAPED_UNICODE) ?>;
  var svg = document.getElementById('chart');
  var tip = document.getElementById('tip');
  var NS = 'http://www.w3.org/2000/svg';

  function css(name) {
    return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  }

  function draw() {
    while (svg.firstChild) svg.removeChild(svg.firstChild);
    if (!data.length) return;

    var w = svg.clientWidth || 800, h = svg.clientHeight || 260;
    var padL = 44, padR = 14, padT = 14, padB = 26;
    var iw = Math.max(1, w - padL - padR), ih = Math.max(1, h - padT - padB);
    svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);

    var accent = css('--accent') || '#3b6ef5';
    var accent2 = css('--accent-2') || '#17a67c';
    var border = css('--border') || '#e4e7ec';
    var muted = css('--muted') || '#6b7482';

    var maxV = 0;
    data.forEach(function (d) { maxV = Math.max(maxV, d.events, d.devices); });
    maxV = Math.max(maxV, 1);
    var ticks = 4, step = Math.ceil(maxV / ticks) || 1;
    var top = step * ticks;

    function x(i) { return padL + (data.length === 1 ? iw / 2 : (i / (data.length - 1)) * iw); }
    function y(v) { return padT + ih - (v / top) * ih; }

    function el(name, attrs) {
      var node = document.createElementNS(NS, name);
      for (var k in attrs) node.setAttribute(k, attrs[k]);
      return node;
    }

    // Gridlines + y labels
    for (var t = 0; t <= ticks; t++) {
      var v = step * t, yy = y(v);
      svg.appendChild(el('line', { x1: padL, y1: yy, x2: w - padR, y2: yy, stroke: border, 'stroke-width': 1 }));
      var label = el('text', { x: padL - 9, y: yy + 4, fill: muted, 'font-size': 11, 'text-anchor': 'end' });
      label.textContent = v;
      svg.appendChild(label);
    }

    // X labels: first, middle, last
    [0, Math.floor(data.length / 2), data.length - 1].forEach(function (i, n, arr) {
      if (arr.indexOf(i) !== n) return;
      var d = data[i];
      if (!d) return;
      var text = el('text', {
        x: x(i), y: h - 7, fill: muted, 'font-size': 11,
        'text-anchor': i === 0 ? 'start' : (i === data.length - 1 ? 'end' : 'middle')
      });
      text.textContent = d.day.slice(5);
      svg.appendChild(text);
    });

    function path(key) {
      return data.map(function (d, i) { return (i ? 'L' : 'M') + x(i) + ' ' + y(d[key]); }).join(' ');
    }

    // Events area + line
    var gid = 'grad-' + Math.random().toString(36).slice(2);
    var defs = el('defs', {});
    var grad = el('linearGradient', { id: gid, x1: 0, y1: 0, x2: 0, y2: 1 });
    var s1 = el('stop', { offset: '0%', 'stop-color': accent, 'stop-opacity': .28 });
    var s2 = el('stop', { offset: '100%', 'stop-color': accent, 'stop-opacity': 0 });
    grad.appendChild(s1); grad.appendChild(s2); defs.appendChild(grad); svg.appendChild(defs);

    svg.appendChild(el('path', {
      d: path('events') + ' L' + x(data.length - 1) + ' ' + y(0) + ' L' + x(0) + ' ' + y(0) + ' Z',
      fill: 'url(#' + gid + ')'
    }));
    svg.appendChild(el('path', {
      d: path('events'), fill: 'none', stroke: accent,
      'stroke-width': 2, 'stroke-linejoin': 'round', 'stroke-linecap': 'round'
    }));
    svg.appendChild(el('path', {
      d: path('devices'), fill: 'none', stroke: accent2,
      'stroke-width': 2, 'stroke-dasharray': '4 3', 'stroke-linejoin': 'round', 'stroke-linecap': 'round'
    }));

    // Hover guide
    var guide = el('line', { y1: padT, y2: padT + ih, stroke: border, 'stroke-width': 1, opacity: 0 });
    var dot1 = el('circle', { r: 4, fill: accent, opacity: 0 });
    var dot2 = el('circle', { r: 4, fill: accent2, opacity: 0 });
    svg.appendChild(guide); svg.appendChild(dot1); svg.appendChild(dot2);

    svg.addEventListener('mousemove', function (ev) {
      var rect = svg.getBoundingClientRect();
      var px = ev.clientX - rect.left;
      var i = data.length === 1 ? 0 : Math.round(((px - padL) / iw) * (data.length - 1));
      i = Math.max(0, Math.min(data.length - 1, i));
      var d = data[i];
      guide.setAttribute('x1', x(i)); guide.setAttribute('x2', x(i)); guide.setAttribute('opacity', 1);
      dot1.setAttribute('cx', x(i)); dot1.setAttribute('cy', y(d.events)); dot1.setAttribute('opacity', 1);
      dot2.setAttribute('cx', x(i)); dot2.setAttribute('cy', y(d.devices)); dot2.setAttribute('opacity', 1);
      tip.innerHTML = '<b>' + d.day + '</b><br>' + d.events + ' events · ' + d.devices + ' devices';
      tip.style.opacity = 1;
      var tw = tip.offsetWidth;
      tip.style.left = Math.min(Math.max(x(i) - tw / 2, 4), rect.width - tw - 4) + 'px';
      tip.style.top = Math.max(y(Math.max(d.events, d.devices)) - 52, 0) + 'px';
    });
    svg.addEventListener('mouseleave', function () {
      tip.style.opacity = 0;
      guide.setAttribute('opacity', 0);
      dot1.setAttribute('opacity', 0);
      dot2.setAttribute('opacity', 0);
    });
  }

  draw();
  var resizeTimer;
  addEventListener('resize', function () {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(draw, 120);
  });
})();
</script>
</body>
</html>
