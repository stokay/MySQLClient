<?php
/**
 * Notification emails for new feedback — a function library, included by
 * feedback.php, analytics.php and feedback-inbox.php. Requesting this file
 * directly does nothing.
 *
 * There is no cron job behind this. Instead, every request that already
 * happens (a new message, any analytics event, opening the inbox) calls
 * feedback_notify_pending(), which sends ONE email covering everything not
 * yet announced — but no more often than `feedback_notify_interval_minutes`.
 * A flood of messages therefore produces one email per interval, not one
 * per message.
 */

declare(strict_types=1);

/**
 * Sends the digest if there is something to announce and the last one is
 * old enough. Never throws: a broken mail setup or a missing table must
 * not take the calling request down with it.
 */
function feedback_notify_pending(PDO $pdo, array $config): void
{
    try {
        $to = trim((string) ($config['feedback_notify_to'] ?? ''));
        if ($to === '' || filter_var($to, FILTER_VALIDATE_EMAIL) === false) {
            return;
        }
        $intervalMinutes = max(1, (int) ($config['feedback_notify_interval_minutes'] ?? 60));

        // Claim the slot first, in one statement: of two requests arriving
        // together only one sees a changed row, so only one sends.
        $claim = $pdo->prepare(
            "UPDATE feedback_state
             SET last_notified_at = NOW()
             WHERE id = 1
               AND (last_notified_at IS NULL OR last_notified_at <= NOW() - INTERVAL {$intervalMinutes} MINUTE)
               AND EXISTS (SELECT 1 FROM feedback_messages WHERE notified_at IS NULL)"
        );
        $claim->execute();
        if ($claim->rowCount() !== 1) {
            return;
        }

        $pending = $pdo->query(
            'SELECT id, category, message, name, email, app_version, os_version, language, created_at
             FROM feedback_messages WHERE notified_at IS NULL ORDER BY id ASC LIMIT 200'
        )->fetchAll(PDO::FETCH_ASSOC);
        if (!$pending) {
            return;
        }

        if (feedback_send_digest($to, $pending, $config)) {
            $lastId = (int) end($pending)['id'];
            $mark = $pdo->prepare('UPDATE feedback_messages SET notified_at = NOW() WHERE notified_at IS NULL AND id <= :last_id');
            $mark->execute(['last_id' => $lastId]);
        }
        // If mail() refused, the messages stay pending and go out with the
        // next digest once the interval has passed again.
    } catch (Throwable $e) {
        // Deliberately silent — see the function comment.
    }
}

/** Builds and sends the plain-text digest. Returns whether mail() accepted it. */
function feedback_send_digest(string $to, array $messages, array $config): bool
{
    $count = count($messages);
    $subject = $count === 1
        ? 'MySQL Client: 1 new feedback message'
        : "MySQL Client: {$count} new feedback messages";

    // Only the first few are quoted; the inbox has all of them. Keeps a
    // flood from turning into a very long email as well.
    $quoted = array_slice($messages, 0, 10);
    $lines = [];
    foreach ($quoted as $row) {
        $context = array_filter([
            $row['app_version'] ?? null,
            $row['os_version'] ?? null,
            $row['language'] ?? null,
        ]);
        $lines[] = sprintf('[%s] %s%s', $row['category'], $row['created_at'], $context ? ' · ' . implode(' · ', $context) : '');
        $text = (string) $row['message'];
        $lines[] = mb_strlen($text) > 600 ? mb_substr($text, 0, 600) . '…' : $text;
        if (!empty($row['name'])) {
            $lines[] = 'From: ' . $row['name'];
        }
        if (!empty($row['email'])) {
            $lines[] = 'Reply to: ' . $row['email'];
        }
        $lines[] = str_repeat('-', 40);
    }
    if ($count > count($quoted)) {
        $lines[] = sprintf('… and %d more.', $count - count($quoted));
    }
    $inboxUrl = trim((string) ($config['feedback_inbox_url'] ?? ''));
    if ($inboxUrl !== '') {
        $lines[] = '';
        $lines[] = 'Inbox: ' . $inboxUrl;
    }

    // The sender address is this server's own; nothing a user typed ever
    // reaches a header (their text only goes into the body).
    $from = trim((string) ($config['feedback_notify_from'] ?? ''));
    $headers = [
        'MIME-Version: 1.0',
        'Content-Type: text/plain; charset=UTF-8',
        'Content-Transfer-Encoding: 8bit',
    ];
    if ($from !== '' && filter_var($from, FILTER_VALIDATE_EMAIL) !== false) {
        $headers[] = 'From: MySQL Client Feedback <' . $from . '>';
    }

    return @mail($to, mb_encode_mimeheader($subject, 'UTF-8'), implode("\n", $lines), implode("\r\n", $headers));
}
