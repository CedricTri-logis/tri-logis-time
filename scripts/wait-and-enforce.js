#!/usr/bin/env node
/**
 * wait-and-enforce.js
 *
 * Polls Google Play Console for alpha track availability, then automatically
 * enforces the minimum app version in Supabase when the build is live.
 *
 * Usage:
 *   node scripts/wait-and-enforce.js <version+build>
 *   node scripts/wait-and-enforce.js 1.0.0+81
 *
 * Behavior:
 *   1. Extracts build number from version arg (e.g. "1.0.0+81" → build "81")
 *   2. Runs check-play-status.js --build <number> to get THAT build's status
 *   3. If update_available → immediately enforces minimum version and exits
 *   4. If in_review/not_sent_for_review → polls every 5 minutes (max 60 min)
 *   5. On success: updates app_config.minimum_app_version via Supabase REST API
 *   6. On timeout/error: exits with non-zero code
 *
 * Exit codes:
 *   0 = enforced successfully
 *   1 = timeout (60 minutes)
 *   2 = script error or cookies expired
 *   3 = missing arguments
 */

const { execFileSync } = require("child_process");
const path = require("path");
const fs = require("fs");

// Configuration
const POLL_INTERVAL_MS = 5 * 60 * 1000; // 5 minutes
const MAX_POLLS = 12; // 12 * 5min = 60 minutes
const SUPABASE_URL = "https://xdyzdclwvhkfwbkrdsiz.supabase.co";
const CHECK_SCRIPT = path.join(__dirname, "check-play-status.js");

// Read service role key from dashboard/.env.local
function getServiceRoleKey() {
  const envPaths = [
    path.join(__dirname, "..", "dashboard", ".env.local"),
    path.join(__dirname, "..", "dashboard", ".vercel", ".env.development.local"),
  ];
  for (const p of envPaths) {
    if (fs.existsSync(p)) {
      const content = fs.readFileSync(p, "utf-8");
      const match = content.match(
        /SUPABASE_SERVICE_ROLE_KEY=(.+)/
      );
      if (match) return match[1].trim();
    }
  }
  return null;
}

function checkPlayStatus(buildNumber) {
  try {
    const args = [CHECK_SCRIPT];
    if (buildNumber) {
      args.push("--build", buildNumber);
    }
    const output = execFileSync("node", args, {
      encoding: "utf-8",
      timeout: 120000,
      cwd: path.join(__dirname),
    });
    // Parse the final PLAY_NORMALIZED_STATUS line (the last one is the aggregate)
    const lines = output.trim().split("\n");
    const statusLine = lines
      .reverse()
      .find((l) => l.startsWith("PLAY_NORMALIZED_STATUS:"));
    if (!statusLine) return { status: "unknown", raw: output };
    const status = statusLine.split(":")[1].trim();
    return { status, raw: output };
  } catch (err) {
    if (err.status === 1) return { status: "expired", raw: err.stderr || "" };
    if (err.status === 2) return { status: "not_found", raw: err.stderr || err.message };
    return { status: "error", raw: err.message };
  }
}

async function enforceMinVersion(version, serviceKey) {
  const url = `${SUPABASE_URL}/rest/v1/app_config?key=eq.minimum_app_version`;
  const response = await fetch(url, {
    method: "PATCH",
    headers: {
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
      "Content-Type": "application/json",
      Prefer: "return=representation",
    },
    body: JSON.stringify({
      value: version,
      updated_at: new Date().toISOString(),
    }),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Supabase API error ${response.status}: ${text}`);
  }

  const data = await response.json();
  return data;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  const version = process.argv[2];
  if (!version) {
    console.error("Usage: node scripts/wait-and-enforce.js <version+build>");
    console.error("Example: node scripts/wait-and-enforce.js 1.0.0+81");
    process.exit(3);
  }

  // Extract build number from version string (e.g. "1.0.0+81" → "81")
  const buildNumber = version.includes("+") ? version.split("+")[1] : null;
  if (!buildNumber) {
    console.error(
      "WARNING: No build number found in version string. " +
      "Expected format: 1.0.0+81. Will check any available build."
    );
  }

  const serviceKey = getServiceRoleKey();
  if (!serviceKey) {
    console.error("ERROR: Could not find SUPABASE_SERVICE_ROLE_KEY");
    process.exit(2);
  }

  const startTime = new Date();
  console.log(
    `[${startTime.toLocaleTimeString()}] Waiting for Google Play alpha track to show build as available...`
  );
  console.log(`  Target version: ${version}`);
  if (buildNumber) {
    console.log(`  Target build: ${buildNumber}`);
  }
  console.log(
    `  Will poll every 5 minutes for up to 60 minutes.\n`
  );

  for (let attempt = 1; attempt <= MAX_POLLS; attempt++) {
    const now = new Date();
    console.log(
      `[${now.toLocaleTimeString()}] Check ${attempt}/${MAX_POLLS}...`
    );

    const result = checkPlayStatus(buildNumber);
    console.log(`  Status: ${result.status}`);

    if (result.status === "update_available") {
      console.log(`\n  Build is AVAILABLE to testers!`);
      console.log(`  Enforcing minimum version: ${version}`);

      try {
        await enforceMinVersion(version, serviceKey);
        console.log(
          `  SUCCESS: minimum_app_version updated to ${version}`
        );
        console.log(
          `\n  Total wait time: ${Math.round((Date.now() - startTime.getTime()) / 1000)}s`
        );
        process.exit(0);
      } catch (err) {
        console.error(`  ERROR enforcing version: ${err.message}`);
        process.exit(2);
      }
    }

    if (result.status === "expired") {
      console.error(
        "  ERROR: Google Play cookies expired. Run: node scripts/save-play-cookies.js"
      );
      process.exit(2);
    }

    if (result.status === "not_found") {
      console.log(`  Build ${buildNumber} not yet visible on track. Waiting...`);
      // Continue polling — build may not have appeared yet
    }

    if (result.status === "error") {
      console.error(`  ERROR: ${result.raw}`);
      // Continue polling — transient errors are common
    }

    if (attempt < MAX_POLLS) {
      console.log(`  Waiting 5 minutes...\n`);
      await sleep(POLL_INTERVAL_MS);
    }
  }

  console.error(
    `\nTIMEOUT: Build not available after ${MAX_POLLS * 5} minutes.`
  );
  console.error(
    "  minimum_app_version was NOT updated. Run manually when ready:"
  );
  console.error(
    `  UPDATE app_config SET value = '${version}', updated_at = NOW() WHERE key = 'minimum_app_version';`
  );
  process.exit(1);
}

main();
