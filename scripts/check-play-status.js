#!/usr/bin/env node
/**
 * check-play-status.js
 *
 * Checks the Google Play Console for the current review/update status
 * of the Tri Logis Time app (ca.trilogis.gpstracker).
 *
 * Uses saved browser state (cookies) from claude@tri-logis.ca to
 * authenticate without needing to log in each time.
 *
 * Usage:
 *   node scripts/check-play-status.js
 *
 * Output (machine-readable lines):
 *   PLAY_APP_STATE:<status text>       e.g. "Closed testing" or "Tests fermés"
 *   PLAY_STATUS:<status text>          e.g. "In review", "Update available", etc.
 *   PLAY_LAST_UPDATED:<date>           e.g. "Feb 27, 2026"
 *   PLAY_NORMALIZED_STATUS:<status>    Normalized English status for scripting
 *
 * Normalized statuses: update_available, in_review, not_sent_for_review,
 *                      draft, rejected, suspended, removed, unknown
 *
 * Exit codes:
 *   0 = success
 *   1 = cookies expired / login required
 *   2 = other error
 */

const { chromium } = require("playwright");
const { execFileSync } = require("child_process");
const path = require("path");
const fs = require("fs");

const STATE_PATH = path.join(
  process.env.HOME,
  ".claude/credentials/google-play-state.json"
);
const DEVELOPER_ID = "7134686966635771144";
const APP_LIST_URL = `https://play.google.com/console/u/0/developers/${DEVELOPER_ID}/app-list`;

// Map French/English status text to normalized keys
function normalizeStatus(raw) {
  const s = raw.toLowerCase().trim();
  if (
    s.includes("update available") ||
    s.includes("mise à jour disponible") ||
    s.includes("mise a jour disponible")
  )
    return "update_available";
  if (s.includes("in review") || s.includes("en cours d'examen") || s.includes("en examen"))
    return "in_review";
  if (
    s.includes("not yet sent for review") ||
    s.includes("pas encore envoyé pour examen") ||
    s.includes("pas encore envoye")
  )
    return "not_sent_for_review";
  if (s.includes("draft") || s.includes("brouillon")) return "draft";
  if (s.includes("rejected") || s.includes("rejeté") || s.includes("rejete"))
    return "rejected";
  if (s.includes("suspended") || s.includes("suspendu")) return "suspended";
  if (s.includes("removed") || s.includes("supprimé") || s.includes("supprime"))
    return "removed";
  if (s.includes("published") || s.includes("publi")) return "update_available";
  return "unknown";
}

async function checkStatus() {
  if (!fs.existsSync(STATE_PATH)) {
    return { expired: true };
  }

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ storageState: STATE_PATH });
  const page = await context.newPage();

  try {
    await page.goto(APP_LIST_URL, {
      waitUntil: "networkidle",
      timeout: 30000,
    });

    // Check if we got redirected to login (cookies expired)
    const url = page.url();
    if (
      url.includes("accounts.google.com") ||
      url.includes("/signin") ||
      url.includes("/ServiceLogin")
    ) {
      return { expired: true };
    }

    // Wait for the app list grid to load
    await page.waitForSelector('[role="grid"], [role="row"]', {
      timeout: 15000,
    });

    // Give it a moment for data to populate
    await page.waitForTimeout(2000);

    // Extract status from the app row
    const statusInfo = await page.evaluate(() => {
      const rows = document.querySelectorAll('[role="row"]');
      for (const row of rows) {
        const cells = row.querySelectorAll('[role="gridcell"]');
        if (cells.length === 0) continue;

        const text = row.textContent || "";
        if (
          text.includes("ca.trilogis.gpstracker") ||
          text.includes("Tri Logis Time")
        ) {
          const cellTexts = Array.from(cells).map((c) => {
            let t = c.textContent?.trim() || "";
            // Strip leading Material icon text (e.g. "info ", "check ", "schedule ")
            t = t.replace(/^(info|check|warning|error|brightness_1|schedule|pending|update|published_with_changes)\s+/i, "");
            return t;
          });
          return { found: true, cells: cellTexts };
        }
      }
      return { found: false, body: document.body.innerText.substring(0, 500) };
    });

    if (statusInfo.found) {
      const cells = statusInfo.cells;
      // Grid columns: [App name+package, Installs, App state, Update status, Last updated, pin, view]
      const appState = cells.length >= 3 ? cells[2] : "";
      const updateStatus = cells.length >= 4 ? cells[3] : "";
      const lastUpdated = cells.length >= 5 ? cells[4] : "";

      // Refresh cookies for next time
      await context.storageState({ path: STATE_PATH });

      return { appState, updateStatus, lastUpdated };
    } else {
      return { error: true, body: statusInfo.body };
    }
  } catch (err) {
    return { error: true, message: err.message };
  } finally {
    await browser.close();
  }
}

function refreshCookies() {
  const savScript = path.join(__dirname, "save-play-cookies.js");
  console.error("Session expired. Auto-refreshing cookies via save-play-cookies.js...");
  try {
    execFileSync("node", [savScript], { stdio: "inherit", timeout: 60000 });
    return true;
  } catch (err) {
    console.error(`ERROR: Cookie refresh failed: ${err.message}`);
    return false;
  }
}

async function main() {
  let result = await checkStatus();

  // Auto-recover: if cookies expired, refresh and retry once
  if (result.expired) {
    if (!refreshCookies()) {
      console.error("ERROR: Could not refresh session. Run 'node scripts/save-play-cookies.js' manually.");
      process.exit(1);
    }
    result = await checkStatus();
    if (result.expired) {
      console.error("ERROR: Session still expired after refresh. Run 'node scripts/save-play-cookies.js --visible' to debug.");
      process.exit(1);
    }
  }

  if (result.error) {
    console.error("WARNING: Could not find app row in the grid.");
    if (result.body) console.error("Page snippet:", result.body);
    if (result.message) console.error("Error:", result.message);
    process.exit(2);
  }

  console.log(`PLAY_APP_STATE:${result.appState}`);
  console.log(`PLAY_STATUS:${result.updateStatus}`);
  if (result.lastUpdated) console.log(`PLAY_LAST_UPDATED:${result.lastUpdated}`);
  console.log(`PLAY_NORMALIZED_STATUS:${normalizeStatus(result.updateStatus)}`);
}

main();
