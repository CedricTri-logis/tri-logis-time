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

async function main() {
  if (!fs.existsSync(STATE_PATH)) {
    console.error(
      "ERROR: No saved session found. Run 'node scripts/save-play-cookies.js' first."
    );
    process.exit(1);
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
      console.error(
        "ERROR: Session expired. Run 'node scripts/save-play-cookies.js' to re-authenticate."
      );
      process.exit(1);
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

      console.log(`PLAY_APP_STATE:${appState}`);
      console.log(`PLAY_STATUS:${updateStatus}`);
      if (lastUpdated) console.log(`PLAY_LAST_UPDATED:${lastUpdated}`);
      console.log(`PLAY_NORMALIZED_STATUS:${normalizeStatus(updateStatus)}`);
    } else {
      console.error("WARNING: Could not find app row in the grid.");
      console.error("Page snippet:", statusInfo.body);
      process.exit(2);
    }

    // Refresh cookies for next time
    await context.storageState({ path: STATE_PATH });
  } catch (err) {
    console.error(`ERROR: ${err.message}`);
    process.exit(2);
  } finally {
    await browser.close();
  }
}

main();
