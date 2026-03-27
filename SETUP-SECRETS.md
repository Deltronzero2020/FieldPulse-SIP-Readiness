# Setting Up GitHub Secrets

This guide explains how to configure the secrets required for automated builds.

---

## Required Secrets

| Secret Name | Description | Example |
|-------------|-------------|---------|
| `WEBHOOK_URL` | Your Google Apps Script deployment URL | `https://script.google.com/macros/s/ABC123.../exec` |
| `WEBHOOK_SECRET` | HMAC shared secret (UUID) | `b9998be9-a908-435e-a4a5-51ff793eb71b` |

---

## Step 1: Add Secrets to GitHub

1. Go to your GitHub repository
2. Click **Settings** (tab at the top)
3. In the left sidebar, click **Secrets and variables** → **Actions**
4. Click **New repository secret**
5. Add each secret:

### WEBHOOK_URL
- **Name:** `WEBHOOK_URL`
- **Value:** Your Google Apps Script web app URL
  - Find this in Apps Script: **Deploy** → **Manage deployments** → copy the URL

### WEBHOOK_SECRET
- **Name:** `WEBHOOK_SECRET`
- **Value:** A UUID that matches your Apps Script backend
  - Generate one at: https://www.uuidgenerator.net/
  - Must be the SAME value in both GitHub Secrets and your Apps Script

---

## Step 2: Configure Apps Script Backend

The backend (`FieldPulse-SIP-Readiness-Backend.gs`) is NOT automatically configured.

1. Open your Google Apps Script project
2. Update these values manually:

```javascript
var NOTIFY_EMAIL    = 'your-email@company.com';
var DRIVE_FOLDER_ID = 'your-google-drive-folder-id';
var WEBHOOK_SECRET  = 'same-uuid-as-github-secret';
```

3. Deploy a new version after changes

---

## Step 3: Test the Build

1. Create and push a new tag:
   ```bash
   git tag v1.0.1
   git push origin v1.0.1
   ```

2. Go to **Actions** tab to watch the build

3. Once complete, download from **Releases** and test

---

## Local Development

For local testing without GitHub Actions, create a file called `secrets.local.ps1` (gitignored):

```powershell
$env:WEBHOOK_URL = "https://script.google.com/macros/s/YOUR_URL/exec"
$env:WEBHOOK_SECRET = "your-secret-uuid"
```

Then modify the scripts to read from environment variables, or manually replace the placeholders.

---

## Security Notes

- **Never commit real secrets** to the repository
- GitHub Secrets are encrypted and only exposed during Actions runs
- The compiled EXE will contain the secrets (necessary for it to work)
- Rate limiting and HMAC validation protect against casual abuse
