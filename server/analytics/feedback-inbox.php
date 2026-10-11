<?php
/**
 * Feedback inbox for MySQL Client — lists what feedback.php stored and
 * lets each message be marked read / answered / closed, or deleted.
 *
 * Deployment: upload next to dashboard.php. There is no separate login:
 * this page accepts the cookie dashboard.php's login form sets, and sends
 * anyone without it there.
 *
 * Everything shown here was typed by a stranger. All of it is escaped on
 * output and nothing is rendered as a link except the sender's email,
 * which is validated on the way in (feedback.php) and again here.
 */

declare(strict_types=1);

$config = require __DIR__ . '/config.php';

// --- Auth: the same signed cookie dashboard.php issues. ---
const DASHBOARD_AUTH_COOKIE = 'mysqlclient_dash_auth';

$expectedUser = (string) ($config['dashboard_user'] ?? '');
$expectedPass = (string) ($config['dashboard_pass'] ?? '');
if ($expectedPass === '' || $expectedPass === 'CHANGE_ME') {
    http_response_code(500);
    exit('Set dashboard_user / dashboard_pass in config.php before using this page.');
}
$authToken = hash_hmac('sha256', $expectedUser, $expectedPass);
if (!isset($_COOKIE[DASHBOARD_AUTH_COOKIE]) || !hash_equals($authToken, (string) $_COOKIE[DASHBOARD_AUTH_COOKIE])) {
    header('Location: dashboard.php');
    exit;
}

// A form on another site can make a signed-in browser POST here; it can't
// know this value, which is derived from the same secret as the cookie.
$csrfToken = hash_hmac('sha256', 'feedback-inbox', $authToken);

function h(?string $value): string
{
    return htmlspecialchars((string) $value, ENT_QUOTES, 'UTF-8');
}

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

$statuses = ['new' => 'New', 'read' => 'Read', 'answered' => 'Answered', 'closed' => 'Closed'];
$categories = ['idea' => 'Idea', 'problem' => 'Problem', 'bug' => 'Bug', 'other' => 'Other'];

$filter = $_GET['status'] ?? 'open';
if ($filter !== 'open' && $filter !== 'all' && !isset($statuses[$filter])) {
    $filter = 'open';
}
$selfUrl = 'feedback-inbox.php?status=' . rawurlencode($filter);

// --- Actions. ---
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    if (!hash_equals($csrfToken, (string) ($_POST['csrf'] ?? ''))) {
        http_response_code(403);
        exit('Invalid request.');
    }
    $id = (int) ($_POST['id'] ?? 0);
    $action = (string) ($_POST['action'] ?? '');
    try {
        if ($id > 0 && $action === 'delete') {
            $pdo->prepare('DELETE FROM feedback_messages WHERE id = :id')->execute(['id' => $id]);
        } elseif ($id > 0 && isset($statuses[$action])) {
            $pdo->prepare('UPDATE feedback_messages SET status = :status WHERE id = :id')
                ->execute(['status' => $action, 'id' => $id]);
        }
    } catch (Throwable $e) {
        http_response_code(500);
        exit('Could not update the message.');
    }
    // Redirect so a reload doesn't repeat the action.
    header('Location: ' . $selfUrl);
    exit;
}

$tablesMissing = false;
$messages = [];
$counts = array_fill_keys(array_keys($statuses), 0);
try {
    foreach ($pdo->query('SELECT status, COUNT(*) AS n FROM feedback_messages GROUP BY status') as $row) {
        if (isset($counts[$row['status']])) {
            $counts[$row['status']] = (int) $row['n'];
        }
    }
    $where = '1';
    $params = [];
    if ($filter === 'open') {
        $where = "status IN ('new', 'read')";
    } elseif ($filter !== 'all') {
        $where = 'status = :status';
        $params['status'] = $filter;
    }
    $list = $pdo->prepare("SELECT * FROM feedback_messages WHERE {$where} ORDER BY id DESC LIMIT 200");
    $list->execute($params);
    $messages = $list->fetchAll();
} catch (Throwable $e) {
    $tablesMissing = true;
}

// Opening the inbox is also a chance to send a notification that has been
// waiting for its interval to pass.
require_once __DIR__ . '/feedback-notify.php';
feedback_notify_pending($pdo, $config);

$filters = ['open' => 'Open', 'new' => 'New', 'read' => 'Read', 'answered' => 'Answered', 'closed' => 'Closed', 'all' => 'All'];
$filterCounts = $counts + ['open' => $counts['new'] + $counts['read'], 'all' => array_sum($counts)];
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="referrer" content="no-referrer">
<title>MySQL Client — Feedback</title>
<style>
  :root {
    --bg: #f5f6f8; --surface: #ffffff; --surface-2: #fafbfc; --border: #e4e7ec; --text: #16191d;
    --muted: #6b7482; --accent: #3b6ef5; --accent-soft: rgba(59, 110, 245, .12);
    --ok: #17a67c; --warn: #b7791f; --danger: #d93a3a;
    --shadow: 0 1px 2px rgba(16, 20, 28, .06), 0 4px 16px rgba(16, 20, 28, .05);
    --radius: 12px; color-scheme: light;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0d1117; --surface: #151a21; --surface-2: #1a2029; --border: #262d38; --text: #e6edf3;
      --muted: #8b949e; --accent: #5b8cff; --accent-soft: rgba(91, 140, 255, .16);
      --ok: #3fb98a; --warn: #d9a441; --danger: #f0665f;
      --shadow: 0 1px 2px rgba(0, 0, 0, .3), 0 4px 16px rgba(0, 0, 0, .25);
      color-scheme: dark;
    }
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: var(--bg); color: var(--text);
    font: 14px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, sans-serif;
    -webkit-font-smoothing: antialiased; padding: 28px 16px 64px;
  }
  .wrap { max-width: 860px; margin: 0 auto; }
  header.top { display: flex; flex-wrap: wrap; gap: 12px; align-items: center; justify-content: space-between; margin-bottom: 18px; }
  h1 { font-size: 20px; font-weight: 650; letter-spacing: -.01em; }
  a { color: var(--accent); }
  .btn {
    display: inline-block; padding: 6px 12px; border-radius: 8px; border: 1px solid var(--border);
    background: var(--surface); color: var(--text); font: inherit; font-size: 13px; text-decoration: none; cursor: pointer;
  }
  .btn:hover { border-color: var(--accent); }
  .btn.danger { color: var(--danger); }
  .filters { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 18px; }
  .filters a { text-decoration: none; }
  .filters a[aria-current="true"] { background: var(--accent-soft); border-color: var(--accent); color: var(--accent); font-weight: 600; }
  .filters span { color: var(--muted); margin-left: 4px; font-variant-numeric: tabular-nums; }
  .card {
    background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius);
    box-shadow: var(--shadow); padding: 16px 18px; margin-bottom: 14px;
  }
  .card.is-new { border-left: 3px solid var(--accent); }
  .meta { display: flex; flex-wrap: wrap; gap: 6px 10px; align-items: center; color: var(--muted); font-size: 12.5px; margin-bottom: 10px; }
  .badge {
    display: inline-block; padding: 1px 8px; border-radius: 999px; font-size: 12px; font-weight: 600;
    background: var(--surface-2); border: 1px solid var(--border); color: var(--text);
  }
  .badge.bug { color: var(--danger); }
  .badge.problem { color: var(--warn); }
  .badge.idea { color: var(--ok); }
  .badge.status { color: var(--muted); font-weight: 500; }
  /* The message is shown exactly as typed: wrapped, never interpreted. */
  .message { white-space: pre-wrap; overflow-wrap: anywhere; font-size: 14px; }
  .reply { margin-top: 10px; font-size: 13px; }
  .actions { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 14px; }
  .actions form { display: inline; }
  .empty { color: var(--muted); text-align: center; padding: 48px 0; }
  .notice { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); padding: 14px 16px; margin-bottom: 16px; }
</style>
</head>
<body>
<div class="wrap">

  <header class="top">
    <h1>MySQL Client — Feedback</h1>
    <a class="btn" href="dashboard.php">← Analytics</a>
  </header>

  <?php if ($tablesMissing): ?>
    <div class="notice">The feedback tables don't exist yet — run <code>feedback.sql</code> against this database first.</div>
  <?php else: ?>

  <nav class="filters" aria-label="Filter by status">
    <?php foreach ($filters as $key => $label): ?>
      <a class="btn" href="feedback-inbox.php?status=<?= h($key) ?>" aria-current="<?= $key === $filter ? 'true' : 'false' ?>">
        <?= h($label) ?><span><?= (int) $filterCounts[$key] ?></span>
      </a>
    <?php endforeach; ?>
  </nav>

  <?php if (!$messages): ?>
    <div class="empty">Nothing here.</div>
  <?php endif; ?>

  <?php foreach ($messages as $row): ?>
    <?php
      $category = isset($categories[$row['category']]) ? $row['category'] : 'other';
      $status = isset($statuses[$row['status']]) ? $row['status'] : 'new';
      $context = array_filter([$row['app_version'], $row['os_version'], $row['device_model'], $row['language'], $row['server_info']]);
      $email = is_string($row['email']) && filter_var($row['email'], FILTER_VALIDATE_EMAIL) !== false ? $row['email'] : null;
    ?>
    <article class="card <?= $status === 'new' ? 'is-new' : '' ?>">
      <div class="meta">
        <span class="badge <?= h($category) ?>"><?= h($categories[$category]) ?></span>
        <span class="badge status"><?= h($statuses[$status]) ?></span>
        <span><?= h($row['created_at']) ?></span>
        <?php foreach ($context as $item): ?><span>· <?= h($item) ?></span><?php endforeach; ?>
        <span title="Sender ID (random, feedback only)">· <?= h(substr((string) $row['sender_id'], 0, 8)) ?></span>
      </div>
      <div class="message"><?= h($row['message']) ?></div>
      <?php if (is_string($row['name'] ?? null) && $row['name'] !== ''): ?>
        <div class="reply">From: <strong><?= h($row['name']) ?></strong></div>
      <?php endif; ?>
      <?php if ($email !== null): ?>
        <div class="reply">Reply to:
          <a href="mailto:<?= h(str_replace('%40', '@', rawurlencode($email))) ?>?subject=<?= h(rawurlencode('Re: your MySQL Client feedback')) ?>"><?= h($email) ?></a>
        </div>
      <?php endif; ?>
      <div class="actions">
        <?php foreach ($statuses as $key => $label): if ($key === $status) { continue; } ?>
          <form method="post" action="<?= h($selfUrl) ?>">
            <input type="hidden" name="csrf" value="<?= h($csrfToken) ?>">
            <input type="hidden" name="id" value="<?= (int) $row['id'] ?>">
            <button class="btn" type="submit" name="action" value="<?= h($key) ?>">Mark <?= h(strtolower($label)) ?></button>
          </form>
        <?php endforeach; ?>
        <form method="post" action="<?= h($selfUrl) ?>" onsubmit="return confirm('Delete this message for good?');">
          <input type="hidden" name="csrf" value="<?= h($csrfToken) ?>">
          <input type="hidden" name="id" value="<?= (int) $row['id'] ?>">
          <button class="btn danger" type="submit" name="action" value="delete">Delete</button>
        </form>
      </div>
    </article>
  <?php endforeach; ?>

  <?php endif; ?>
</div>
</body>
</html>
