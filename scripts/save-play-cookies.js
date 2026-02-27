#!/usr/bin/env node
/**
 * save-play-cookies.js
 *
 * Authenticates as claude@tri-logis.ca on Google Play Console
 * and saves the browser session (cookies + localStorage) for
 * future use by check-play-status.js.
 *
 * Handles 2FA automatically via TOTP (Google Authenticator secret).
 *
 * Usage:
 *   node scripts/save-play-cookies.js          # headless with auto-TOTP
 *   node scripts/save-play-cookies.js --visible # visible browser for debugging
 *
 * The script will:
 *   1. Open a Chromium browser
 *   2. Navigate to Google sign-in
 *   3. Auto-fill the email and password
 *   4. Auto-fill the TOTP code for 2FA
 *   5. Navigate to Play Console to establish session
 *   6. Save the storage state to ~/.claude/credentials/google-play-state.json
 */

const { chromium } = require("playwright");
const crypto = require("crypto");
const path = require("path");
const fs = require("fs");

const CREDENTIALS_PATH = path.join(
  process.env.HOME,
  ".claude/credentials/google-play.json"
);
const STATE_PATH = path.join(
  process.env.HOME,
  ".claude/credentials/google-play-state.json"
);
const DEVELOPER_ID = "7134686966635771144";
const APP_LIST_URL = `https://play.google.com/console/u/0/developers/${DEVELOPER_ID}/app-list`;

/**
 * Generate a TOTP code from a base32-encoded secret.
 */
function generateTOTP(secret) {
  const base32 = secret.replace(/\s/g, "").toUpperCase();
  const base32chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const c of base32) {
    const val = base32chars.indexOf(c);
    if (val === -1) continue;
    bits += val.toString(2).padStart(5, "0");
  }
  const key = Buffer.alloc(Math.floor(bits.length / 8));
  for (let i = 0; i < key.length; i++) {
    key[i] = parseInt(bits.substr(i * 8, 8), 2);
  }

  const time = Math.floor(Date.now() / 1000 / 30);
  const timeBuffer = Buffer.alloc(8);
  timeBuffer.writeBigUInt64BE(BigInt(time));

  const hmac = crypto.createHmac("sha1", key);
  hmac.update(timeBuffer);
  const hash = hmac.digest();

  const offset = hash[hash.length - 1] & 0x0f;
  const code =
    (((hash[offset] & 0x7f) << 24) |
      ((hash[offset + 1] & 0xff) << 16) |
      ((hash[offset + 2] & 0xff) << 8) |
      (hash[offset + 3] & 0xff)) %
    1000000;

  return code.toString().padStart(6, "0");
}

async function main() {
  const isVisible = process.argv.includes("--visible");

  // Load credentials
  if (!fs.existsSync(CREDENTIALS_PATH)) {
    console.error(
      `ERROR: Credentials file not found at ${CREDENTIALS_PATH}`
    );
    process.exit(1);
  }
  const creds = JSON.parse(fs.readFileSync(CREDENTIALS_PATH, "utf8"));

  if (!creds.totp_secret) {
    console.error(
      "ERROR: No totp_secret in credentials file. Add it to enable automated 2FA."
    );
    process.exit(1);
  }

  console.log(`Authenticating as ${creds.email}...`);

  const browser = await chromium.launch({ headless: !isVisible });
  const context = await browser.newContext();
  const page = await context.newPage();

  try {
    // Navigate to Google sign-in
    await page.goto("https://accounts.google.com/signin", {
      waitUntil: "networkidle",
    });

    // Enter email
    const emailInput = page.locator('input[type="email"]');
    await emailInput.waitFor({ timeout: 10000 });
    await emailInput.fill(creds.email);
    await page.locator("#identifierNext button, button:has-text('Next')").click();

    // Wait for password page
    await page.waitForTimeout(2000);
    const passwordInput = page.locator('input[type="password"]');
    await passwordInput.waitFor({ timeout: 10000 });
    await passwordInput.fill(creds.password);
    await page.locator("#passwordNext button, button:has-text('Next')").click();

    // Wait for 2FA page to load
    console.log("Waiting for 2FA prompt...");
    await page.waitForTimeout(3000);

    // Check if we're on a TOTP input page
    const totpInput = page.locator('input[type="tel"][id="totpPin"], input[name="totpPin"]');
    const hasTotpInput = await totpInput.count();

    if (hasTotpInput > 0) {
      console.log("TOTP input detected. Entering code...");
      const code = generateTOTP(creds.totp_secret);
      await totpInput.fill(code);
      await page.locator("#totpNext button, button:has-text('Next')").click();
      console.log("TOTP code submitted.");
    } else {
      // Check for "Try another way" link to switch to TOTP
      const tryAnotherWay = page.locator(
        'button:has-text("Try another way"), button:has-text("Essayer autrement"), a:has-text("Try another way"), a:has-text("Essayer autrement")'
      );
      const hasTryAnother = await tryAnotherWay.count();

      if (hasTryAnother > 0) {
        console.log("Switching to authenticator app method...");
        await tryAnotherWay.first().click();
        await page.waitForTimeout(2000);

        // Look for "Google Authenticator" option
        const authOption = page.locator(
          '[data-challengeindex] :has-text("Authenticator"), [data-challengeindex] :has-text("authentification")'
        );
        const hasAuthOption = await authOption.count();
        if (hasAuthOption > 0) {
          await authOption.first().click();
          await page.waitForTimeout(2000);
        }

        // Now try the TOTP input again
        const totpInput2 = page.locator('input[type="tel"]');
        await totpInput2.waitFor({ timeout: 10000 });
        const code = generateTOTP(creds.totp_secret);
        await totpInput2.fill(code);
        // Click next/verify button
        await page.locator('#totpNext button, button:has-text("Next"), button:has-text("Suivant")').click();
        console.log("TOTP code submitted via alternative method.");
      } else {
        console.log(
          "No TOTP prompt detected. Waiting for manual 2FA completion (up to 2 minutes)..."
        );
      }
    }

    // Wait until we're past Google sign-in
    await page.waitForURL(/^(?!.*accounts\.google\.com\/v3\/signin)/, {
      timeout: 120000,
    });

    console.log("Sign-in completed. Navigating to Play Console...");

    // Navigate to Play Console
    await page.goto(APP_LIST_URL, {
      waitUntil: "networkidle",
      timeout: 30000,
    });

    // Verify we're on the Play Console
    const currentUrl = page.url();
    if (currentUrl.includes("play.google.com/console")) {
      console.log("Successfully authenticated on Play Console!");

      // Save the storage state
      await context.storageState({ path: STATE_PATH });
      console.log(`Session saved to ${STATE_PATH}`);
      console.log(
        "You can now use 'node scripts/check-play-status.js' to check the review status."
      );
    } else {
      console.error(
        `ERROR: Did not reach Play Console. Current URL: ${currentUrl}`
      );
      if (isVisible) {
        console.log(
          "Please navigate to the Play Console manually in the browser window."
        );
        console.log(
          "Press Ctrl+C when done, or the browser will close in 60s."
        );
        await page.waitForTimeout(60000);
      }
    }
  } catch (err) {
    console.error(`ERROR: ${err.message}`);
    if (isVisible) {
      console.log(
        "If the browser is still open, complete any remaining steps manually."
      );
      console.log("The script will save cookies when the browser closes.");
    }
    // Try to save whatever state we have
    try {
      await context.storageState({ path: STATE_PATH });
      console.log("Partial session state saved.");
    } catch {}
  } finally {
    await browser.close();
  }
}

main();
