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
 *   node scripts/check-play-status.js [--build <number>]
 *
 * Options:
 *   --build <number>  Only report status for this specific build number.
 *                     The final PLAY_NORMALIZED_STATUS reflects this build's
 *                     status (not any other available build on the track).
 *
 * Output (machine-readable lines):
 *   PLAY_TRACK:Closed testing - Alpha
 *   PLAY_VERSION:<version>             e.g. "1.0.0"
 *   PLAY_BUILD:<build number>          e.g. "81"
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
const ALPHA_TRACK_ID = "4698766574298897762";
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
    // Step 1: Navigate directly to the alpha track page
    await page.goto(`${BASE_URL}/tracks/${ALPHA_TRACK_ID}`, {
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

    // Wait for the releases section to load
    await page.waitForTimeout(5000);

    // Step 2: Expand all "Show summary" sections to reveal version codes (build numbers)
    // Supports both English ("Show summary") and French ("Afficher le résumé")
    await page.evaluate(() => {
      const allElements = document.querySelectorAll("*");
      for (const el of allElements) {
        const t = el.textContent?.trim();
        if ((t === "Show summary" || t === "Afficher le résumé") && el.children.length === 0) {
          el.click();
        }
      }
    });
    await page.waitForTimeout(2000);

    // Step 3: Extract release statuses from the track page
    // The page shows for each release (EN/FR):
    //   1.0.0                                         ← version
    //   Available to selected testers / Disponible pour certains testeurs  ← status
    //   1 version code / 1 code de version
    //   Released on Mar 16 / Date de sortie : 16 mars  ← date
    //   Version codes / Codes de version               ← (after expanding summary)
    //   136                                            ← build number
    const releaseInfo = await page.evaluate(() => {
      const body = document.body.innerText;
      const releases = [];
      const lines = body.split("\n").map((l) => l.trim()).filter(Boolean);

      let currentVersion = null;
      let currentStatus = null;
      let currentReleasedOn = "";
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i];

        // Match version lines like "1.0.0"
        if (/^\d+\.\d+\.\d+$/.test(line)) {
          if (currentVersion && currentStatus) {
            releases.push({
              version: currentVersion,
              build: null,
              status: currentStatus,
              releasedOn: currentReleasedOn,
            });
          }
          currentVersion = line;
          currentStatus = null;
          currentReleasedOn = "";
          continue;
        }

        if (!currentVersion) continue;

        const lower = line.toLowerCase();

        // Detect status lines (EN + FR)
        if (!currentStatus) {
          if (
            (lower.includes("available to") && lower.includes("tester")) ||
            (lower.includes("disponible") && lower.includes("testeur"))
          ) {
            currentStatus = line;
            // Look for release date nearby (EN: "Released on ...", FR: "Date de sortie : ...")
            for (let j = i + 1; j < Math.min(i + 8, lines.length); j++) {
              const lj = lines[j].toLowerCase();
              if (lj.startsWith("released on")) {
                currentReleasedOn = lines[j].replace(/^released on\s*/i, "");
                break;
              }
              if (lj.startsWith("date de sortie")) {
                currentReleasedOn = lines[j].replace(/^date de sortie\s*:\s*/i, "");
                break;
              }
            }
          } else if (lower.includes("in review") || lower.includes("en examen") || lower.includes("en cours d")) {
            currentStatus = "In review";
          } else if (lower.includes("draft") || lower.includes("brouillon")) {
            currentStatus = "Draft";
          } else if (lower.includes("rejected") || lower.includes("rejeté")) {
            currentStatus = "Rejected";
          } else if (lower.includes("halted") || lower.includes("suspended") || lower.includes("suspendu")) {
            currentStatus = line;
          }
          continue;
        }

        // After status is set, look for "Version codes" / "Codes de version" followed by build number
        if (lower === "version codes" || lower === "codes de version") {
          for (let j = i + 1; j < Math.min(i + 3, lines.length); j++) {
            if (/^\d+$/.test(lines[j])) {
              releases.push({
                version: currentVersion,
                build: lines[j],
                status: currentStatus,
                releasedOn: currentReleasedOn,
              });
              currentVersion = null;
              currentStatus = null;
              currentReleasedOn = "";
              break;
            }
          }
          if (!currentVersion) continue;
        }

        // Fallback: "N version code(s)" / "N code(s) de version" without expansion
        const versionCodeMatch = line.match(/^(\d+)\s+(version\s+codes?|codes?\s+de\s+version)$/i);
        if (versionCodeMatch && currentStatus && !releases.find(
          r => r.version === currentVersion && r.status === currentStatus
        )) {
          // Summary wasn't expanded — no build number available
        }
      }

      // Push any remaining pending release
      if (currentVersion && currentStatus) {
        releases.push({
          version: currentVersion,
          build: null,
          status: currentStatus,
          releasedOn: currentReleasedOn,
        });
      }

      // Extract track name from heading (EN + FR)
      let trackName = "";
      const headings = document.querySelectorAll("h1, h2");
      for (const h of headings) {
        const t = h.textContent?.trim() || "";
        const tl = t.toLowerCase();
        if (
          tl.includes("closed testing") || tl.includes("tests fermés") ||
          tl.includes("alpha")
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
  if (
    (s.includes("available to") && s.includes("tester")) ||
    (s.includes("disponible") && s.includes("testeur"))
  )
    return "update_available";
  if (s.includes("in review") || s.includes("en examen") || s.includes("en cours d"))
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

// Parse --build <number> from CLI args
function parseArgs() {
  const args = process.argv.slice(2);
  let targetBuild = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--build" && i + 1 < args.length) {
      targetBuild = args[i + 1];
      break;
    }
  }
  return { targetBuild };
}

async function main() {
  const { targetBuild } = parseArgs();

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
    if (r.build) console.log(`PLAY_BUILD${prefix}:${r.build}`);
    console.log(`PLAY_STATUS${prefix}:${r.status}`);
    if (r.releasedOn) console.log(`PLAY_RELEASED_ON${prefix}:${r.releasedOn}`);
    console.log(`PLAY_NORMALIZED_STATUS${prefix}:${normalizeStatus(r.status)}`);
  }

  // Determine the final PLAY_NORMALIZED_STATUS for scripting
  if (targetBuild) {
    // --build mode: only report the status of the specific target build
    const targetRelease = releases.find((r) => r.build === targetBuild);
    if (!targetRelease) {
      console.error(`WARNING: Build ${targetBuild} not found on the alpha track.`);
      console.log(`PLAY_NORMALIZED_STATUS:not_found`);
      process.exit(2);
    }
    console.log(`PLAY_NORMALIZED_STATUS:${normalizeStatus(targetRelease.status)}`);
  } else {
    // Default mode: report most recent available, or top release
    const availableRelease = releases.find(
      (r) => normalizeStatus(r.status) === "update_available"
    );
    const topRelease = releases[0];
    if (availableRelease) {
      console.log(`PLAY_NORMALIZED_STATUS:update_available`);
    } else {
      console.log(`PLAY_NORMALIZED_STATUS:${normalizeStatus(topRelease.status)}`);
    }
  }
}

main();
