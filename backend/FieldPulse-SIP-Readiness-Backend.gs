/**
 * FieldPulse SIP Readiness Report — Google Apps Script Backend
 * Version: 2.1
 *
 * SETUP (one-time, ~5 minutes):
 * 1. Go to script.google.com → New project → paste this file
 * 2. Set NOTIFY_EMAIL, DRIVE_FOLDER_ID, and WEBHOOK_SECRET below
 *    WEBHOOK_SECRET must match the value in the WPF exe
 * 3. Deploy → New deployment → Web app
 *      Execute as: Me
 *      Who has access: Anyone   (authentication handled by HMAC secret below)
 * 4. Copy the Web app URL → paste into MainWindow.xaml.cs as WebhookUrl
 * 5. Done.
 *
 * v2.1 changes:
 *   - Uses report_html (full styled HTML from the WPF app) as the email body
 *   - Attaches csv_base64 as a .csv file when present
 *   - Saves HTML report to Drive as .html instead of .txt
 */

// ─── CONFIGURE THESE VALUES ──────────────────────────────────
// SECURITY: Move these to Script Properties for production deployments.
// In Apps Script editor: Project Settings > Script Properties
// PLACEHOLDER: Configure these in your own Apps Script deployment
// These values are NOT injected by GitHub Actions - you must set them manually
// in your Google Apps Script project after copying this file.
var NOTIFY_EMAIL    = 'YOUR_EMAIL@example.com';
var DRIVE_FOLDER_ID = 'YOUR_DRIVE_FOLDER_ID';

// Shared HMAC secret — must match WEBHOOK_SECRET in the client apps.
// IMPORTANT: Generate a unique UUID for production: https://www.uuidgenerator.net/
var WEBHOOK_SECRET  = 'YOUR_WEBHOOK_SECRET_UUID';
// ─────────────────────────────────────────────────────────────

// ─── SIZE LIMITS ─────────────────────────────────────────────
var MAX_PAYLOAD_BYTES   = 2 * 1024 * 1024;   // 2 MB (HTML report + CSV base64)
var MAX_DAILY_REQUESTS  = 200;
var MAX_REPORT_CHARS    = 204800;            // 200 KB plain text report
var MAX_HTML_CHARS      = 512 * 1024;        // 512 KB HTML report
var MAX_CUSTOMER_LEN    = 150;
var MAX_COMPUTER_LEN    = 100;
var DEDUP_WINDOW_MINS   = 5;                 // Reject duplicates within this window


// ─── HTML ESCAPING ───────────────────────────────────────────
function htmlEscape(str) {
  if (typeof str !== 'string') return '';
  return str
    .replace(/&/g,  '&amp;')
    .replace(/</g,  '&lt;')
    .replace(/>/g,  '&gt;')
    .replace(/"/g,  '&quot;')
    .replace(/'/g,  '&#39;')
    .replace(/\n/g, ' ')
    .replace(/\r/g, '');
}


// ─── DAILY RATE LIMIT ────────────────────────────────────────
function checkDailyLimit() {
  var props = PropertiesService.getScriptProperties();
  var today = Utilities.formatDate(new Date(), 'UTC', 'yyyy-MM-dd');
  var key   = 'daily_' + today;
  var count = parseInt(props.getProperty(key) || '0', 10);
  if (count >= MAX_DAILY_REQUESTS) return false;
  props.setProperty(key, String(count + 1));
  return true;
}


// ─── REQUEST DEDUPLICATION ───────────────────────────────────
// Generates an idempotency key from submission data and checks for recent duplicates.
// Returns { isDuplicate: bool, key: string, existingUrl?: string }
function checkDuplicateSubmission(customer, date, passCount, failCount, warnCount, computer) {
  var props = PropertiesService.getScriptProperties();

  // Build idempotency key from core identifying fields
  var rawKey = [customer, date, passCount, failCount, warnCount, computer].join('|');
  var keyHash = Utilities.base64Encode(Utilities.computeDigest(Utilities.DigestAlgorithm.MD5, rawKey));
  var propKey = 'dedup_' + keyHash;

  // Check if this key exists and is within the dedup window
  var existing = props.getProperty(propKey);
  if (existing) {
    try {
      var record = JSON.parse(existing);
      var recordTime = new Date(record.timestamp);
      var now = new Date();
      var diffMins = (now - recordTime) / (1000 * 60);

      if (diffMins < DEDUP_WINDOW_MINS) {
        return { isDuplicate: true, key: keyHash, existingUrl: record.driveUrl };
      }
    } catch (e) {
      // Invalid record, allow submission
    }
  }

  return { isDuplicate: false, key: keyHash, propKey: propKey };
}

// Records a successful submission for deduplication
function recordSubmission(propKey, driveUrl) {
  var props = PropertiesService.getScriptProperties();
  props.setProperty(propKey, JSON.stringify({
    timestamp: new Date().toISOString(),
    driveUrl: driveUrl
  }));
}


// ─── HMAC VERIFICATION ───────────────────────────────────────
// Constant-time comparison to prevent timing attacks
function verifyHmac(payload, clientSig) {
  if (typeof clientSig !== 'string' || clientSig.length === 0) return false;
  try {
    var computed = Utilities.computeHmacSha256Signature(payload, WEBHOOK_SECRET);
    var expected = Utilities.base64Encode(computed);
    // Pad shorter string to prevent length-based timing leak
    var maxLen = Math.max(expected.length, clientSig.length);
    var mismatch = expected.length ^ clientSig.length; // length difference contributes to mismatch
    for (var i = 0; i < maxLen; i++) {
      var expectedChar = i < expected.length ? expected.charCodeAt(i) : 0;
      var clientChar   = i < clientSig.length ? clientSig.charCodeAt(i) : 0;
      mismatch |= expectedChar ^ clientChar;
    }
    return mismatch === 0;
  } catch (e) {
    return false;
  }
}


// ─── INPUT VALIDATION ────────────────────────────────────────
function sanitizeString(val, maxLen, fallback) {
  if (typeof val !== 'string') return fallback;
  return val.replace(/[\x00-\x1F\x7F]/g, ' ').trim().substring(0, maxLen) || fallback;
}

function sanitizeIP(val) {
  if (typeof val !== 'string') return 'N/A';
  var clean = val.trim();
  if (/^(\d{1,3}\.){3}\d{1,3}$/.test(clean)) return clean;
  if (/^[0-9a-fA-F:]{3,39}$/.test(clean))     return clean;
  if (clean === 'N/A' || clean === 'Could not determine') return clean;
  return 'N/A';
}

function sanitizeInt(val, min, max) {
  var n = parseInt(val, 10);
  if (isNaN(n)) return 0;
  return Math.max(min, Math.min(max, n));
}

function sanitizeDate(val) {
  if (typeof val !== 'string') return new Date().toISOString().substring(0, 16);
  if (/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/.test(val.trim())) return val.trim();
  if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(val.trim())) return val.trim().substring(0, 16);
  return new Date().toISOString().substring(0, 16);
}


// ─── MAIN HANDLER ────────────────────────────────────────────
function doPost(e) {
  try {
    // 1. Payload size guard
    var rawBody = e.postData ? e.postData.contents : '';
    if (!rawBody || rawBody.length > MAX_PAYLOAD_BYTES) {
      return jsonResponse({ status: 'error', message: 'Request too large or empty.' });
    }

    // 2. HMAC authentication
    var clientSig = e.parameter ? (e.parameter.sig || '') : '';
    if (WEBHOOK_SECRET !== 'YOUR_SHARED_SECRET_HERE' && !verifyHmac(rawBody, clientSig)) {
      Logger.log('HMAC verification failed — rejected POST at ' + new Date().toISOString());
      return jsonResponse({ status: 'error', message: 'Unauthorized.' });
    }

    // 3. Rate limit
    if (!checkDailyLimit()) {
      Logger.log('Daily rate limit reached at ' + new Date().toISOString());
      return jsonResponse({ status: 'error', message: 'Daily limit reached. Try again tomorrow.' });
    }

    // 4. Parse JSON
    var data;
    try {
      data = JSON.parse(rawBody);
    } catch (parseErr) {
      return jsonResponse({ status: 'error', message: 'Invalid JSON.' });
    }

    if (typeof data !== 'object' || data === null || Array.isArray(data)) {
      return jsonResponse({ status: 'error', message: 'Invalid payload.' });
    }

    // 5. Sanitize fields — network
    var customer      = sanitizeString(data.customer,       MAX_CUSTOMER_LEN, 'Unknown Customer');
    var computer      = sanitizeString(data.computer,       MAX_COMPUTER_LEN, 'Unknown');
    var date          = sanitizeDate(data.date);
    var localIP       = sanitizeIP(data.local_ip);
    var publicIP      = sanitizeIP(data.public_ip);
    var gateway       = sanitizeIP(data.gateway);
    var passCount     = sanitizeInt(data.pass_count,        0, 999);
    var failCount     = sanitizeInt(data.fail_count,        0, 999);
    var warnCount     = sanitizeInt(data.warn_count,        0, 999);

    // 5b. Check for duplicate submission (within DEDUP_WINDOW_MINS)
    var dedupResult = checkDuplicateSubmission(customer, date, passCount, failCount, warnCount, computer);
    if (dedupResult.isDuplicate) {
      Logger.log('Duplicate submission detected for ' + customer + ' at ' + new Date().toISOString());
      return jsonResponse({
        status: 'duplicate',
        message: 'This report was already submitted. If you need to resubmit, please wait ' + DEDUP_WINDOW_MINS + ' minutes.',
        drive_url: dedupResult.existingUrl || ''
      });
    }

    // Onboarding fields
    var phoneCount    = sanitizeInt(data.phone_count,       0, 999);
    var phoneModels   = sanitizeString(data.phone_models,   200,  'Not specified');
    var macSerials    = sanitizeString(data.mac_serials,    1000, 'Not specified');
    var configNotes   = sanitizeString(data.config_notes,   1000, 'Not specified');
    var preferredTime = sanitizeString(data.preferred_time, 200,  'Not specified');
    var confFormer    = data.confirmed_former_provider === true ? 'YES' : 'NO';
    var confReset     = data.confirmed_factory_reset   === true ? 'YES' : 'NO';
    var confFirmware  = data.confirmed_firmware        === true ? 'YES' : 'NO';

    // Report content — plain text fallback + HTML body from WPF
    var reportBody    = sanitizeString(data.report || '',   MAX_REPORT_CHARS, '(no report content)');
    var reportHtml    = (typeof data.report_html === 'string' && data.report_html.length > 0)
                          ? data.report_html.substring(0, MAX_HTML_CHARS)
                          : '';

    // CSV attachment fields
    var csvBase64  = (typeof data.csv_base64  === 'string') ? data.csv_base64  : '';
    var csvFilename = (typeof data.csv_filename === 'string' && data.csv_filename.length > 0)
                        ? data.csv_filename.replace(/[^a-zA-Z0-9 ._-]/g, '').trim()
                        : '';

    // 6. Status label (server-generated)
    var statusLabel = failCount > 0
      ? '🔴 ACTION REQUIRED'
      : warnCount > 2
        ? '🟡 WARNINGS — review before onboarding'
        : '🟢 READY';

    // 7. Build filenames
    var safeCustomer  = customer.replace(/[^a-zA-Z0-9 _-]/g, '').trim() || 'Unknown';
    var safeDate      = Utilities.formatDate(new Date(), 'UTC', 'yyyy-MM-dd_HH-mm');
    var htmlFileName  = safeCustomer + ' — SIP Readiness — ' + safeDate + '.html';
    var plainFileName = safeCustomer + ' — SIP Readiness — ' + safeDate + '.txt';

    // 8. Save to Google Drive
    var driveUrl = '';
    try {
      var folder = DriveApp.getFolderById(DRIVE_FOLDER_ID);
      if (reportHtml.length > 0) {
        // Save the full styled HTML report
        var file = folder.createFile(htmlFileName, reportHtml, MimeType.HTML);
        driveUrl = file.getUrl();
      } else {
        // Fallback to plain text
        var file = folder.createFile(plainFileName, reportBody, MimeType.PLAIN_TEXT);
        driveUrl = file.getUrl();
      }
    } catch (driveErr) {
      Logger.log('Drive save failed: ' + driveErr.toString());
      try {
        var fallbackFile = DriveApp.createFile(plainFileName, reportBody, MimeType.PLAIN_TEXT);
        driveUrl = fallbackFile.getUrl();
        Logger.log('Saved to Drive root as fallback.');
      } catch (fallbackErr) {
        Logger.log('Drive fallback also failed: ' + fallbackErr.toString());
        driveUrl = '(Drive save failed — check folder permissions)';
      }
    }

    // 9. HTML-escape fields for subject line and fallback email
    var eCustomer = htmlEscape(customer);
    var eDate     = htmlEscape(date);
    var eStatus   = htmlEscape(statusLabel);
    var eDriveUrl = htmlEscape(driveUrl);

    // 10. Build subject
    var subject = '[SIP Readiness] ' + eCustomer + ' \u2014 ' + eStatus + ' (' + eDate + ')';
    subject = subject.replace(/[\r\n]+/g, ' ');

    // 11. Determine HTML body
    // Prefer the full styled HTML from the WPF app; fall back to a basic summary if absent
    var htmlBody;
    if (reportHtml.length > 0) {
      // Inject Drive link banner above the WPF-generated report
      var driveBanner = '<div style="font-family:Segoe UI,Arial,sans-serif;background:#F6F8FA;'
        + 'border:1px solid #D0D7DE;border-radius:6px;padding:12px 20px;margin-bottom:16px;">'
        + '<strong>Report saved to Google Drive:</strong> '
        + '<a href="' + eDriveUrl + '" style="color:#0062CC;">' + htmlEscape(reportHtml.length > 0 ? htmlFileName : plainFileName) + '</a>'
        + '</div>';
      htmlBody = driveBanner + reportHtml;
    } else {
      // Minimal fallback email (same as before)
      htmlBody = buildFallbackHtml(
        eCustomer, htmlEscape(computer), eDate,
        htmlEscape(localIP), htmlEscape(publicIP), htmlEscape(gateway),
        eStatus, passCount, warnCount, failCount,
        String(phoneCount), htmlEscape(phoneModels),
        htmlEscape(macSerials).replace(/\n/g, '<br>'),
        htmlEscape(configNotes), htmlEscape(preferredTime),
        confFormer, confReset, confFirmware,
        eDriveUrl, htmlEscape(plainFileName)
      );
    }

    // 12. Plain text body
    var textBody = 'SIP Readiness Report\n'
      + '----------------------------------------\n'
      + 'Customer : ' + customer      + '\n'
      + 'Computer : ' + computer      + '\n'
      + 'Date     : ' + date          + '\n'
      + 'Status   : ' + statusLabel   + '\n'
      + 'Results  : ' + passCount + ' PASS  |  ' + warnCount + ' WARN  |  ' + failCount + ' FAIL\n'
      + '----------------------------------------\n'
      + 'ONBOARDING\n'
      + 'Phones   : ' + phoneCount    + '\n'
      + 'Models   : ' + phoneModels   + '\n'
      + 'MAC/SN   : ' + macSerials    + '\n'
      + 'Config   : ' + configNotes   + '\n'
      + 'Time     : ' + preferredTime + '\n'
      + '----------------------------------------\n'
      + 'CONFIRMATIONS\n'
      + 'Former provider contacted : ' + confFormer   + '\n'
      + 'SIP phones factory reset  : ' + confReset    + '\n'
      + 'Firmware updated          : ' + confFirmware + '\n'
      + '----------------------------------------\n'
      + 'Drive    : ' + driveUrl + '\n\n'
      + reportBody;

    // 13. Build attachments array
    var attachments = [];
    var MAX_CSV_DECODED_BYTES = 2 * 1024 * 1024; // 2 MB limit for decoded CSV
    if (csvBase64.length > 0 && csvFilename.length > 0) {
      try {
        // Validate base64 string length before decoding (base64 is ~4/3 of original)
        var estimatedSize = Math.ceil(csvBase64.length * 3 / 4);
        if (estimatedSize > MAX_CSV_DECODED_BYTES) {
          Logger.log('CSV too large: estimated ' + estimatedSize + ' bytes exceeds limit');
        } else {
          var csvBytes = Utilities.base64Decode(csvBase64);
          // Double-check actual decoded size
          if (csvBytes.length > MAX_CSV_DECODED_BYTES) {
            Logger.log('CSV decoded size ' + csvBytes.length + ' exceeds limit');
          } else {
            var csvBlob = Utilities.newBlob(csvBytes, 'text/csv', csvFilename);
            attachments.push(csvBlob);
          }
        }
      } catch (blobErr) {
        Logger.log('CSV blob creation failed: ' + blobErr.toString());
        // Continue without attachment rather than failing the whole send
      }
    }

    // 14. Send email via GmailApp (supports attachments)
    var emailSent = false;
    try {
      var emailOptions = {
        subject:  subject,
        body:     textBody,
        htmlBody: htmlBody
      };
      if (attachments.length > 0) {
        emailOptions.attachments = attachments;
      }
      GmailApp.sendEmail(NOTIFY_EMAIL, subject, textBody, emailOptions);
      emailSent = true;
    } catch (mailErr) {
      Logger.log('Email send failed: ' + mailErr.toString());
      // Drive file was already saved; report partial success
    }

    // Record successful submission for deduplication
    if (dedupResult.propKey && driveUrl && driveUrl.indexOf('Drive save failed') === -1) {
      recordSubmission(dedupResult.propKey, driveUrl);
    }

    // Return appropriate status based on what succeeded
    if (emailSent) {
      return jsonResponse({ status: 'ok', drive_url: driveUrl });
    } else {
      return jsonResponse({
        status: 'partial',
        message: 'Report saved to Drive but email notification failed. FieldPulse team will retrieve it from Drive.',
        drive_url: driveUrl
      });
    }

  } catch (err) {
    Logger.log('doPost unhandled error: ' + err.toString());
    return jsonResponse({ status: 'error', message: 'An error occurred. Please save and email your report manually.' });
  }
}


// ─── FALLBACK HTML EMAIL ──────────────────────────────────────
// Used only when report_html is absent (e.g. older client versions)
function buildFallbackHtml(
  eCustomer, eComputer, eDate, eLocalIP, ePublicIP, eGateway,
  eStatus, passCount, warnCount, failCount,
  phoneCount, ePhoneModels, eMacSerials, eConfigNotes, ePreferredTime,
  confFormer, confReset, confFirmware,
  eDriveUrl, eFileName
) {
  return '<div style="font-family:Segoe UI,Arial,sans-serif;max-width:640px;">'
    + '<div style="background:#0062CC;padding:20px 24px;border-radius:6px 6px 0 0;">'
    + '<h2 style="color:#fff;margin:0;font-size:18px;">FieldPulse Engage</h2>'
    + '<p style="color:#A8C8F0;margin:4px 0 0;">SIP Phone Registration Readiness Report</p>'
    + '</div>'
    + '<div style="background:#F6F8FA;padding:16px 24px;border:1px solid #D0D7DE;border-top:none;">'
    + '<table style="border-collapse:collapse;width:100%;font-size:14px;">'
    + row('Customer',  eCustomer)
    + row('Computer',  eComputer)
    + row('Date',      eDate)
    + row('Local IP',  eLocalIP)
    + row('Public IP', ePublicIP)
    + row('Gateway',   eGateway)
    + '</table></div>'
    + '<div style="padding:16px 24px;border:1px solid #D0D7DE;border-top:none;">'
    + '<p style="font-size:15px;font-weight:bold;margin:0 0 10px;">Overall Status: ' + eStatus + '</p>'
    + '<table style="border-collapse:collapse;font-size:14px;"><tr>'
    + '<td style="padding:4px 24px 4px 0;color:#1A7F37;"><strong>&#10003; ' + passCount + ' PASS</strong></td>'
    + '<td style="padding:4px 24px 4px 0;color:#9A6700;"><strong>&#9888; ' + warnCount + ' WARN</strong></td>'
    + '<td style="padding:4px 24px 4px 0;color:#CF222E;"><strong>&#10007; ' + failCount + ' FAIL</strong></td>'
    + '</tr></table></div>'
    + '<div style="padding:16px 24px;border:1px solid #D0D7DE;border-top:none;">'
    + '<h3 style="margin:0 0 10px;font-size:14px;color:#1F2328;">Onboarding Information</h3>'
    + '<table style="border-collapse:collapse;width:100%;font-size:14px;">'
    + row('SIP Phones',     phoneCount)
    + row('Phone Model(s)', ePhoneModels)
    + row('MAC / Serials',  eMacSerials)
    + row('Config Notes',   eConfigNotes)
    + row('Preferred Time', ePreferredTime)
    + '</table></div>'
    + '<div style="padding:16px 24px;border:1px solid #D0D7DE;border-top:none;">'
    + '<h3 style="margin:0 0 10px;font-size:14px;color:#1F2328;">Customer Confirmations</h3>'
    + '<table style="border-collapse:collapse;font-size:14px;">'
    + row('Former provider contacted', confFormer  === 'YES' ? '&#10003; YES' : '&#10007; NO')
    + row('SIP phones factory reset',  confReset   === 'YES' ? '&#10003; YES' : '&#10007; NO')
    + row('Firmware updated',          confFirmware === 'YES' ? '&#10003; YES' : '&#10007; NO')
    + '</table></div>'
    + '<div style="padding:16px 24px;border:1px solid #D0D7DE;border-top:none;">'
    + '<p style="margin:0 0 6px;font-size:14px;color:#57606A;">Full report saved to Google Drive:</p>'
    + '<a href="' + eDriveUrl + '" style="color:#0062CC;word-break:break-all;">' + eFileName + '</a>'
    + '</div>'
    + '<div style="padding:12px 24px;border:1px solid #D0D7DE;border-top:none;background:#F6F8FA;border-radius:0 0 6px 6px;">'
    + '<p style="margin:0;font-size:12px;color:#57606A;">Check details are in the Drive file.</p>'
    + '</div></div>';
}


// ─── HELPERS ─────────────────────────────────────────────────

function row(label, value) {
  return '<tr>'
    + '<td style="padding:4px 12px 4px 0;color:#57606A;width:110px;vertical-align:top;"><strong>'
    + htmlEscape(label) + '</strong></td>'
    + '<td style="padding:4px 0;color:#1F2328;">' + value + '</td>'
    + '</tr>';
}

function jsonResponse(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}


/**
 * GET — health check. Open the web app URL in a browser to confirm it's live.
 */
function doGet(e) {
  return ContentService
    .createTextOutput('FieldPulse SIP Readiness webhook is active. v2.1')
    .setMimeType(ContentService.MimeType.TEXT);
}


/**
 * TEST — Run this manually from the editor to verify email permissions.
 * 1. Select this function from the dropdown
 * 2. Click Run
 * 3. Authorize when prompted
 * 4. Check your inbox for the test email
 */
function testEmailPermissions() {
  var testHtml = '<div style="font-family:Segoe UI,Arial,sans-serif;padding:20px;">'
    + '<h2 style="color:#00034D;">FieldPulse SIP Readiness — Email Test</h2>'
    + '<p>If you received this email, GmailApp permissions are working correctly.</p>'
    + '<p style="color:#57606A;font-size:12px;">Sent at: ' + new Date().toISOString() + '</p>'
    + '</div>';

  GmailApp.sendEmail(
    NOTIFY_EMAIL,
    '[SIP Readiness] Email Permission Test',
    'This is a test email to verify GmailApp permissions.',
    { htmlBody: testHtml }
  );

  Logger.log('Test email sent successfully to ' + NOTIFY_EMAIL);
}
