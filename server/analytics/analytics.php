<?php
/**
 * Anonymous usage analytics endpoint for MySQL Client (macOS app).
 *
 * Deployment (cPanel File Manager, manual — this host isn't served by the
 * app's GitHub repo):
 *   1. Create a MySQL database on tokay.tr (or reuse an existing one) and
 *      run schema.sql against it once, e.g. via phpMyAdmin.
 *   2. Copy config.sample.php to config.php in this same directory and
 *      fill in the real DB host/name/user/password. config.php is
 *      gitignored — never commit it.
 *   3. Upload this file, config.php, and schema.sql (for reference) to
 *      https://tokay.tr/MySQLClient/analytics/ — the path the Swift
 *      client (AnalyticsService.swift) posts to. (Note: the on-disk
 *      folder is "MySQLClient", matching the app's App Store display
 *      name — not "MySQLMacClient", the Xcode target name.)
 *   4. Confirm PHP's curl extension is enabled (used for the geo-IP
 *      lookup below) — enabled by default on virtually all cPanel PHP
 *      builds.
 *
 * Design notes:
 *   - Public, unauthenticated endpoint by nature (the client is
 *     anonymous) — input validation below is the only real abuse guard
 *     for v1; no rate limiting.
 *   - The requester's IP is used ONLY to resolve a country code and the
 *     network operator (org/ASN) via an external geo-IP lookup, then
 *     discarded — it is never written to the database or to any log.
 *   - Best-effort: any failure here should still return quickly. A
 *     failed geo-IP lookup does not fail the request (country/network end
 *     up NULL); a bad/missing config.php or DB error returns 500 but
 *     never leaks details to the client.
 *   - ip-api.com's free tier allows ~45 lookups/minute per server IP.
 *     Over that it returns an error and those events simply land with a
 *     NULL country/network — the event itself is still recorded. If the
 *     app ever gets busy enough for that to matter, cache lookups or
 *     move to a paid/self-hosted GeoIP database.
 */

declare(strict_types=1);

header('Content-Type: application/json; charset=utf-8');

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    exit;
}

// Reject absurdly large bodies before even reading them.
$contentLength = (int) ($_SERVER['CONTENT_LENGTH'] ?? 0);
if ($contentLength > 8192) {
    http_response_code(413);
    exit;
}

$raw = file_get_contents('php://input', false, null, 0, 8192);
$body = json_decode($raw ?: '', true);

if (!is_array($body)) {
    http_response_code(400);
    exit;
}

function analytics_string(array $body, string $key, int $maxLength): ?string
{
    $value = $body[$key] ?? null;
    if (!is_string($value) || $value === '') {
        return null;
    }
    return mb_substr($value, 0, $maxLength);
}

$deviceId = $body['device_id'] ?? null;
if (!is_string($deviceId) || !preg_match('/^[0-9A-Fa-f-]{36}$/', $deviceId)) {
    http_response_code(400);
    exit;
}

$eventName = $body['event'] ?? null;
$allowedEvents = ['app_open', 'feature_used', 'error'];
if (!is_string($eventName) || !in_array($eventName, $allowedEvents, true)) {
    http_response_code(400);
    exit;
}

$feature = analytics_string($body, 'feature', 64);
$appVersion = analytics_string($body, 'app_version', 20);
$osVersion = analytics_string($body, 'os_version', 20);
$deviceModel = analytics_string($body, 'device_model', 64);
$language = analytics_string($body, 'language', 10);
$timezone = analytics_string($body, 'timezone', 64);

// Numeric only, deliberately — the client never sends the server's
// free-text error message (see schema.sql for why). Anything else in
// this field is rejected outright rather than coerced.
$errorCode = null;
if (array_key_exists('error_code', $body) && $body['error_code'] !== null) {
    if (!is_int($body['error_code']) || $body['error_code'] < 0 || $body['error_code'] > 65535) {
        http_response_code(400);
        exit;
    }
    $errorCode = $body['error_code'];
}

// --- Country + network lookup: use the IP only for this, then let it go
// out of scope. The IP itself is never stored, logged, or echoed back.
// `org`/`as` describe the network operator (e.g. "Apple Inc." / "AS714"),
// which is what makes App Review traffic filterable without keeping a
// personal identifier. ---
$country = null;
$networkOrg = null;
$networkAsn = null;
$remoteAddr = $_SERVER['REMOTE_ADDR'] ?? null;
if ($remoteAddr !== null) {
    $ch = curl_init("http://ip-api.com/json/{$remoteAddr}?fields=countryCode,org,isp,as");
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => 2,
        CURLOPT_CONNECTTIMEOUT => 2,
    ]);
    $response = curl_exec($ch);
    curl_close($ch);
    if (is_string($response)) {
        $decoded = json_decode($response, true);
        if (is_array($decoded)) {
            if (isset($decoded['countryCode']) && is_string($decoded['countryCode'])) {
                $country = mb_substr($decoded['countryCode'], 0, 2);
            }
            // `org` is the more specific of the two but is often empty on
            // consumer connections, where `isp` carries the same idea.
            foreach (['org', 'isp'] as $key) {
                if (!empty($decoded[$key]) && is_string($decoded[$key])) {
                    $networkOrg = mb_substr($decoded[$key], 0, 128);
                    break;
                }
            }
            if (!empty($decoded['as']) && is_string($decoded['as'])) {
                $networkAsn = mb_substr($decoded['as'], 0, 64);
            }
        }
    }
}
unset($remoteAddr);

// --- Persist. ---
$config = require __DIR__ . '/config.php';

try {
    $pdo = new PDO(
        "mysql:host={$config['db_host']};dbname={$config['db_name']};charset=utf8mb4",
        $config['db_user'],
        $config['db_pass'],
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );

    // Turn the bare number into "1146 Table doesn't exist" for storage.
    // A code that isn't in mysql_error_codes yet is stored as just the
    // number — add a row to that table and later events pick up the text.
    if ($errorCode !== null) {
        $lookup = $pdo->prepare('SELECT description FROM mysql_error_codes WHERE code = :code');
        $lookup->execute(['code' => $errorCode]);
        $description = $lookup->fetchColumn();
        $errorCode = is_string($description)
            ? $errorCode . ' ' . $description
            : (string) $errorCode;
    }

    $statement = $pdo->prepare(
        'INSERT INTO analytics_events
            (device_id, event_name, feature, error_code, app_version, os_version, device_model, language, timezone, country, network_org, network_asn)
         VALUES
            (:device_id, :event_name, :feature, :error_code, :app_version, :os_version, :device_model, :language, :timezone, :country, :network_org, :network_asn)'
    );
    $statement->execute([
        'device_id' => $deviceId,
        'event_name' => $eventName,
        'feature' => $feature,
        'error_code' => $errorCode,
        'app_version' => $appVersion,
        'os_version' => $osVersion,
        'device_model' => $deviceModel,
        'language' => $language,
        'timezone' => $timezone,
        'country' => $country,
        'network_org' => $networkOrg,
        'network_asn' => $networkAsn,
    ]);
} catch (Throwable $e) {
    http_response_code(500);
    exit;
}

http_response_code(204);
