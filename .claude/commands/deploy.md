Deploy the Flutter app to iOS (TestFlight) and Android (Google Play alpha) and enforce the minimum app version.

**CRITICAL RULE: ALWAYS deploy BOTH platforms.** Even if changes only affect one platform, BOTH iOS and Android MUST be deployed together to keep build numbers synchronized. Never deploy one without the other.

Steps:
1. **Pre-flight check**: Run `flutter analyze` on the full project BEFORE bumping the version. If there are any errors (not warnings), fix them first. Do NOT proceed with the deploy if there are compile errors.
2. **Determine the next build number** — query BOTH stores to find the highest existing build number:
   - Query TestFlight: `cd gps_tracker/ios && bundle exec fastlane latest_build` (look for "LATEST_TF_BUILD:XX")
   - Query Google Play: `cd gps_tracker/android && bundle exec fastlane check_status` (look for "ALPHA_VERSION_CODES:XX" — may be comma-separated, take the highest)
   - Take the MAX of: pubspec build number, TestFlight build number, Google Play build number
   - New build = MAX + 1
   - Update `gps_tracker/pubspec.yaml` with the new build number
   - This ensures both platforms always get the exact same build number, regardless of any prior drift.
3. **Deploy iOS and Android in parallel** (BOTH are mandatory):
   - iOS: `cd gps_tracker/ios && bundle exec fastlane beta` (requires Homebrew Ruby: export PATH="/opt/homebrew/opt/ruby/bin:/opt/homebrew/lib/ruby/gems/4.0.0/bin:$PATH")
   - Android: `cd gps_tracker/android && bundle exec fastlane alpha` (same Ruby path)
4. **Both deploys MUST succeed with the SAME build number.** After both finish:
   - If one fails, fix the issue and redeploy the FAILED platform with the SAME build number. Do NOT move on until both are deployed with the same number.
   - If a version code conflict occurs (e.g., "Version code XX has already been used"), bump to the next number and redeploy BOTH platforms with the new number.
   - Read the ACTUAL build number from the iOS Fastlane output (look for "build_version: XX" — Apple may increment). If Apple incremented, use that higher number and redeploy Android too.
   - **NEVER leave iOS and Android on different build numbers.** This is the #1 rule of this workflow.
5. **Verify build number parity**: After both deploys succeed, confirm the deployed build numbers match. If they don't, redeploy the lagging platform.
6. Sync pubspec.yaml to match the actual deployed build number (so it stays in sync for next deploy).
7. **⛔ BLOCKING GATE — Wait for Google Play review approval, then enforce minimum version**:

   **CRITICAL: You MUST NOT update `minimum_app_version` unless `PLAY_NORMALIZED_STATUS` is EXACTLY `update_available`. Any other status (in_review, not_sent_for_review, draft, rejected, unknown, etc.) means the build is NOT available to employees yet. Enforcing a version that isn't available LOCKS ALL EMPLOYEES OUT OF THE APP. This is a production-breaking mistake.**

   a. Run `node scripts/check-play-status.js` to get the review status. Read the output carefully.
   b. Run `cd gps_tracker/android && bundle exec fastlane check_status` to confirm the build number on the alpha track.
   c. **ONLY if `PLAY_NORMALIZED_STATUS` is exactly `update_available`**:
      → Build is live. Enforce minimum version = deployed build number via Supabase MCP tool `execute_sql`:
        `UPDATE app_config SET value = '<build>', updated_at = NOW() WHERE key = 'minimum_app_version';`
        (Project ID: `xdyzdclwvhkfwbkrdsiz`)
      → Report success and move to step 8.
   d. If `PLAY_NORMALIZED_STATUS` is `in_review` or `not_sent_for_review`:
      → **DO NOT enforce minimum version.**
      → Inform the user: "Build XX is still [status] on Google Play. Polling every 5 minutes..."
      → Poll: re-run `node scripts/check-play-status.js` every 5 minutes.
      → Max wait: 60 minutes (12 checks). After that, ask the user what to do.
      → When status changes to `update_available`: enforce minimum version automatically (same SQL as above).
      → **Repeat: DO NOT enforce until you see `update_available`. No exceptions.**
   e. If cookies expired (exit code 1): warn user, suggest `node scripts/save-play-cookies.js`, **DO NOT enforce — skip enforcement entirely.**
   f. If status is `rejected`, `unknown`, or any other unexpected status: warn user, **DO NOT enforce — skip enforcement entirely.**
   g. If the user passed "no enforce" / "sans bloquer": skip this entire step.
8. **Push (run the full /push workflow)** — only if both deploys succeeded:
   - **Apply pending migrations**: Check `git status --short supabase/migrations/` and `git diff --name-only HEAD supabase/migrations/` for new/modified migration files. If any are found, list them and run `supabase db push --linked` from the project root. If it fails, stop and report the error.
   - **Commit**: Stage all modified files (pubspec.yaml, build configs, code changes, migrations, etc.). Create a commit with message: `chore: Deploy v<version>+<build> to TestFlight & Google Play` (using HEREDOC, with `Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>`).
   - **Push**: `git push` (or `git push -u origin HEAD` if no upstream).
   - **Vercel deployment**: Run `npx vercel --prod --yes` to trigger and watch the production deployment. Report the deployment URL and status.
9. Report the summary: both deploy statuses, the SINGLE build number deployed to both platforms, Google Play review status, what minimum version is now enforced, and the git push status.

Important notes:
- **Both platforms are ALWAYS deployed together** — there is no option to skip one. If the user asks to deploy only one platform, warn them that both must be deployed to keep build numbers in sync, and deploy both.
- iOS TestFlight groups: The Fastfile distributes to the "Employee" EXTERNAL group only. The "Tri-Logis" INTERNAL group has automatic distribution enabled in App Store Connect and receives all builds automatically. Do NOT add "Tri-Logis" to the Fastfile groups — it causes an API error.
- Apple sometimes increments the build number (e.g. pubspec says +20 but Apple processes as build 21). Always check the Fastlane output for the actual build number and sync pubspec.yaml accordingly.
- Only update the minimum version if both deploys succeeded.
- Run both deploys as background tasks in parallel for speed.

Optional argument: $ARGUMENTS
- If the user says "no enforce" or "sans bloquer", skip the minimum version update
- If the user asks to deploy only one platform (e.g. "ios only", "android only"), WARN them that both platforms must stay in sync and deploy BOTH anyway. The only exception is if one platform is completely broken and cannot build — in that case, warn clearly that the build numbers will be out of sync and this must be resolved ASAP.
