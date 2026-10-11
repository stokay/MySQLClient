<?php
/**
 * Feedback endpoint for MySQL Client (macOS app) — receives what the
 * "Send Feedback" form posts (FeedbackService.swift).
 *
 * Deployment: run feedback.sql once, add the `feedback_*` keys from
 * config.sample.php to config.php, then upload this file together with
 * feedback-notify.php and feedback-inbox.php next to analytics.php.
 *
 * Abuse limits — none of them look at the IP address, which changes too
 * easily to be worth anything and is not read here at all:
 *   - `feedback_enabled` false turns the whole thing off (503); the app
 *     tells the user feedback is unavailable right now.
 *   - A hard ceiling on messages per hour across everyone
 *     (`feedback_max_per_hour`). This is the limit that actually bounds a
 *     flood: once it is reached everything else is refused until the hour
 *     moves on.
 *   - A per-installation ceiling per day (`feedback_max_per_sender_per_day`).
 *     The ID is chosen by the client, so this only stops a well-behaved
 *     app from being used to send too much — it is not a security limit.
 *   - Plain text only, capped length, and nothing here is ever published:
 *     messages land in feedback-inbox.php behind the dashboard login.
 *   - Notification emails are batched (see feedback-notify.php), so a
 *     flood can't become a flood of email either.
 *
 * `install_proof`: App Store builds also send an Apple-signed proof that
 * the copy was installed from the App Store. It is accepted and ignored
 * for now — not verified, not stored. It is there so that, if this
 * endpoint is ever abused, requests without a valid proof can be refused
 * by changing only this file, with no app update needed.
 *
 * Responses are JSON: {"ok":true}, or {"error":"<code>"} with 400
 * (invalid input), 429 (a limit was hit), 503 (turned off) or 500.
 */

declare(strict_types=1);

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

function feedback_respond(int $status, array $payload): void
{
    http_response_code($status);
    echo json_encode($payload);
    exit;
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    feedback_respond(405, ['error' => 'method']);
}

// Big enough for a 4000-character message in any script plus the install
// proof, small enough that nobody stores a file here.
const FEEDBACK_MAX_BODY_BYTES = 49152;
const FEEDBACK_MIN_MESSAGE_LENGTH = 10;
const FEEDBACK_MAX_MESSAGE_LENGTH = 4000;

if ((int) ($_SERVER['CONTENT_LENGTH'] ?? 0) > FEEDBACK_MAX_BODY_BYTES) {
    feedback_respond(413, ['error' => 'too_large']);
}
$raw = file_get_contents('php://input', false, null, 0, FEEDBACK_MAX_BODY_BYTES + 1);
if ($raw === false || strlen($raw) > FEEDBACK_MAX_BODY_BYTES) {
    feedback_respond(413, ['error' => 'too_large']);
}
$body = json_decode($raw, true);
if (!is_array($body)) {
    feedback_respond(400, ['error' => 'invalid']);
}

/** An optional, length-capped, single-line string — null when absent. */
function feedback_string(array $body, string $key, int $maxLength): ?string
{
    $value = $body[$key] ?? null;
    if (!is_string($value)) {
        return null;
    }
    $value = trim(preg_replace('/[\x00-\x1F\x7F]+/u', ' ', $value) ?? '');
    return $value === '' ? null : mb_substr($value, 0, $maxLength);
}

$senderId = $body['sender_id'] ?? null;
if (!is_string($senderId) || !preg_match('/^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$/', $senderId)) {
    feedback_respond(400, ['error' => 'invalid']);
}

$category = $body['category'] ?? null;
if (!is_string($category) || !in_array($category, ['idea', 'problem', 'bug', 'other'], true)) {
    feedback_respond(400, ['error' => 'invalid']);
}

$message = $body['message'] ?? null;
if (!is_string($message) || !mb_check_encoding($message, 'UTF-8')) {
    feedback_respond(400, ['error' => 'invalid']);
}
// Line breaks and tabs are part of a message; other control characters
// have no business in one. Only true controls (Cc) go — the invisible
// joiners some scripts and emoji are written with must survive.
$message = trim(preg_replace('/[^\P{Cc}\n\t]+/u', '', str_replace(["\r\n", "\r"], "\n", $message)) ?? '');
$messageLength = mb_strlen($message);
if ($messageLength < FEEDBACK_MIN_MESSAGE_LENGTH || $messageLength > FEEDBACK_MAX_MESSAGE_LENGTH) {
    feedback_respond(400, ['error' => 'invalid_message']);
}

// How the sender would like to be addressed — optional, and never used
// for anything else.
$name = feedback_string($body, 'name', 80);

$email = null;
if (isset($body['email']) && is_string($body['email']) && trim($body['email']) !== '') {
    $email = trim($body['email']);
    if (strlen($email) > 254 || filter_var($email, FILTER_VALIDATE_EMAIL) === false) {
        feedback_respond(400, ['error' => 'invalid_email']);
    }
}

$appVersion = feedback_string($body, 'app_version', 32);
$osVersion = feedback_string($body, 'os_version', 40);
$deviceModel = feedback_string($body, 'device_model', 64);
$language = feedback_string($body, 'language', 10);
$serverInfo = feedback_string($body, 'server_info', 64);

$config = require __DIR__ . '/config.php';

if (($config['feedback_enabled'] ?? true) === false) {
    feedback_respond(503, ['error' => 'disabled']);
}
$maxPerHour = max(1, (int) ($config['feedback_max_per_hour'] ?? 30));
$maxPerSenderPerDay = max(1, (int) ($config['feedback_max_per_sender_per_day'] ?? 5));

try {
    $pdo = new PDO(
        "mysql:host={$config['db_host']};dbname={$config['db_name']};charset=utf8mb4",
        $config['db_user'],
        $config['db_pass'],
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );

    $recent = (int) $pdo->query('SELECT COUNT(*) FROM feedback_messages WHERE created_at > NOW() - INTERVAL 1 HOUR')->fetchColumn();
    if ($recent >= $maxPerHour) {
        feedback_respond(429, ['error' => 'busy']);
    }

    $bySender = $pdo->prepare('SELECT COUNT(*) FROM feedback_messages WHERE sender_id = :sender_id AND created_at > NOW() - INTERVAL 1 DAY');
    $bySender->execute(['sender_id' => $senderId]);
    if ((int) $bySender->fetchColumn() >= $maxPerSenderPerDay) {
        feedback_respond(429, ['error' => 'sender_limit']);
    }

    $insert = $pdo->prepare(
        'INSERT INTO feedback_messages
            (sender_id, category, message, name, email, app_version, os_version, device_model, language, server_info)
         VALUES
            (:sender_id, :category, :message, :name, :email, :app_version, :os_version, :device_model, :language, :server_info)'
    );
    $insert->execute([
        'sender_id' => strtolower($senderId),
        'category' => $category,
        'message' => $message,
        'name' => $name,
        'email' => $email,
        'app_version' => $appVersion,
        'os_version' => $osVersion,
        'device_model' => $deviceModel,
        'language' => $language,
        'server_info' => $serverInfo,
    ]);
} catch (Throwable $e) {
    feedback_respond(500, ['error' => 'server']);
}

// The message is stored; telling the developer about it is a separate,
// best-effort step that can't fail the request.
require_once __DIR__ . '/feedback-notify.php';
feedback_notify_pending($pdo, $config);

feedback_respond(200, ['ok' => true]);
