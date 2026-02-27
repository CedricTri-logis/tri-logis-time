#!/usr/bin/env node
/**
 * check-play-status.js
 *
 * Checks the Google Play Console for the current alpha track release status
 * of the Tri Logis Time app (ca.trilogis.gpstracker).
 *
 * Navigates into the app's Closed Testing - Alpha track page to read the
 * ACTUAL release status (not the production status shown on the app list).
 *
 * Uses saved browser state (cookies) from claude@tri-logis.ca to
 * authenticate without needing to log in each time.
 *
 * Usage:
 *   node scripts/check-play-status.js
 *
 * Output (machine-readable lines):
 *   PLAY_TRACK:Closed testing - Alpha
 *   PLAY_STATUS:<status text>          e.g. "Available to selected testers", "In review"
 *   PLAY_RELEASED_ON:<date>            e.g. "Feb 27 1:27 PM" (only if available)
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
const APP_ID = "4975656360365049859";
const BASE_URL = `https://play.google.com/console/u/0/developers/${DEVELOPER_ID}/app/${APP_ID}`;

// Navigate to the alpha track releases page and extract release statuses
async function checkStatus() {
  if (!fs.existsSync(STATE_PATH)) {
    return { expired: true };
  }

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ storageState: STATE_PATH });
  const page = await context.newPage();

  try {
    // Step 1: Go to the closed testing page (within the app)
    await page.goto(`${BASE_URL}/closed-testing`, {
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

    // Also check if we got bounced back to app-list (no app context)
    if (url.includes("/app-list")) {
      return { expired: true };
    }

    await page.waitForTimeout(3000);

    // Step 2: Click "Manage track" to get to the releases list
    const manageTrack = page.locator("text=Manage track");
    try {
      await manageTrack.waitFor({ state: "visible", timeout: 10000 });
    } catch {
      // If "Manage track" isn't visible, the page structure may have changed
      // or there are no active tracks
      return {
        error: true,
        message: "Could not find 'Manage track' button on closed testing page",
      };
    }
    await manageTrack.click();
    await page.waitForTimeout(4000);

    // Step 3: Extract release statuses from the track page
    // The page shows releases in reverse chronological order.
    // Each release has a status like:
    //   - "Available to selected testers" (with check_circle icon)
    //   - "In review" (with schedule icon)
    //   - etc.
    const releaseInfo = await page.evaluate(() => {
      const body = document.body.innerText;
      const releases = [];

      // Split page text into lines and find release blocks
      const lines = body.split("\n").map((l) => l.trim()).filter(Boolean);

      let currentVersion = null;
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i];

        // Match version lines like "1.0.0"
        if (/^\d+\.\d+\.\d+$/.test(line)) {
          currentVersion = line;
          continue;
        }

        // Look for status indicators
        if (currentVersion) {
          const lower = line.toLowerCase();

          if (
            lower.includes("available to") &&
            lower.includes("tester")
          ) {
            // Find "Released on" date in nearby lines
            let releasedOn = "";
            for (let j = i + 1; j < Math.min(i + 5, lines.length); j++) {
              if (lines[j].toLowerCase().startsWith("released on")) {
                releasedOn = lines[j].replace(/^released on\s*/i, "");
                break;
              }
            }
            releases.push({
              version: currentVersion,
              status: line,
              releasedOn,
            });
            currentVersion = null;
          } else if (lower.includes("in review")) {
            releases.push({
              version: currentVersion,
              status: "In review",
              releasedOn: "",
            });
            currentVersion = null;
          } else if (
            lower.includes("draft") ||
            lower.includes("brouillon")
          ) {
            releases.push({
              version: currentVersion,
              status: "Draft",
              releasedOn: "",
            });
            currentVersion = null;
          } else if (
            lower.includes("rejected") ||
            lower.includes("rejeté")
          ) {
            releases.push({
              version: currentVersion,
              status: "Rejected",
              releasedOn: "",
            });
            currentVersion = null;
          } else if (
            lower.includes("halted") ||
            lower.includes("suspended")
          ) {
            releases.push({
              version: currentVersion,
              status: line,
              releasedOn: "",
            });
            currentVersion = null;
          }
        }
      }

      // Also extract track name from page heading
      let trackName = "";
      const headings = document.querySelectorAll("h1, h2");
      for (const h of headings) {
        const t = h.textContent?.trim() || "";
        if (
          t.toLowerCase().includes("closed testing") ||
          t.toLowerCase().includes("alpha")
        ) {
          trackName = t;
          break;
        }
      }

      return { trackName, releases };
    });

    // Refresh cookies for next time
    await context.storageState({ path: STATE_PATH });

    return releaseInfo;
  } catch (err) {
    return { error: true, message: err.message };
  } finally {
    await browser.close();
  }
}

function normalizeStatus(raw) {
  const s = raw.toLowerCase().trim();
  if (s.includes("available to") && s.includes("tester"))
    return "update_available";
  if (s.includes("in review") || s.includes("en examen"))
    return "in_review";
  if (s.includes("not yet sent") || s.includes("pas encore envoy"))
    return "not_sent_for_review";
  if (s.includes("draft") || s.includes("brouillon")) return "draft";
  if (s.includes("rejected") || s.includes("rejeté") || s.includes("rejete"))
    return "rejected";
  if (s.includes("halted")) return "halted";
  if (s.includes("suspended") || s.includes("suspendu")) return "suspended";
  return "unknown";
}

function refreshCookies() {
  const savScript = path.join(__dirname, "save-play-cookies.js");
  console.error(
    "Session expired. Auto-refreshing cookies via save-play-cookies.js..."
  );
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
      console.error(
        "ERROR: Could not refresh session. Run 'node scripts/save-play-cookies.js' manually."
      );
      process.exit(1);
    }
    result = await checkStatus();
    if (result.expired) {
      console.error(
        "ERROR: Session still expired after refresh. Run 'node scripts/save-play-cookies.js --visible' to debug."
      );
      process.exit(1);
    }
  }

  if (result.error) {
    console.error("WARNING: Could not read alpha track status.");
    if (result.message) console.error("Error:", result.message);
    process.exit(2);
  }

  const trackName = result.trackName || "Closed testing - Alpha";
  const releases = result.releases || [];

  if (releases.length === 0) {
    console.error("WARNING: No releases found on the alpha track.");
    process.exit(2);
  }

  console.log(`PLAY_TRACK:${trackName}`);

  // Report each release found
  for (let i = 0; i < releases.length; i++) {
    const r = releases[i];
    const prefix = i === 0 ? "" : `_${i + 1}`;
    console.log(`PLAY_VERSION${prefix}:${r.version}`);
    console.log(`PLAY_STATUS${prefix}:${r.status}`);
    if (r.releasedOn) console.log(`PLAY_RELEASED_ON${prefix}:${r.releasedOn}`);
    console.log(`PLAY_NORMALIZED_STATUS${prefix}:${normalizeStatus(r.status)}`);
  }

  // The primary status is the MOST RECENT "available" release, or the top release
  // For deploy workflow: check if any release is available to testers
  const availableRelease = releases.find(
    (r) => normalizeStatus(r.status) === "update_available"
  );
  const topRelease = releases[0];

  // Output the primary normalized status for scripting
  // If there's an available release, report update_available
  // Otherwise report the top release's status
  if (availableRelease) {
    console.log(`PLAY_NORMALIZED_STATUS:update_available`);
  } else {
    console.log(`PLAY_NORMALIZED_STATUS:${normalizeStatus(topRelease.status)}`);
  }
}

main();
