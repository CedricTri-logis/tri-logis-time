Deploy the Flutter app to iOS (TestFlight) and Android (Google Play alpha) and enforce the minimum app version.

Steps:
1. **Pre-flight check**: Run `flutter analyze` on the full project BEFORE bumping the version. If there are any errors (not warnings), fix them first. Do NOT proceed with the deploy if there are compile errors.
2. Bump the build number in `gps_tracker/pubspec.yaml` (increment the +N part)
3. Deploy iOS and Android in parallel:
   - iOS: `cd gps_tracker/ios && bundle exec fastlane beta` (requires Homebrew Ruby: export PATH="/opt/homebrew/opt/ruby/bin:/opt/homebrew/lib/ruby/gems/4.0.0/bin:$PATH")
   - Android: `cd gps_tracker/android && bundle exec fastlane alpha` (same Ruby path)
4. **Both deploys MUST succeed with the SAME build number.** After both finish:
   - If one fails, fix the issue and redeploy BOTH platforms with the SAME build number so they stay in sync.
   - If a version code conflict occurs (e.g., "Version code XX has already been used"), bump to the next number and redeploy BOTH platforms with the new number.
   - Read the ACTUAL build number from the iOS Fastlane output (look for "build_version: XX" — Apple may increment). If Apple incremented, use that higher number and redeploy Android too.
   - NEVER leave iOS and Android on different build numbers.
5. Sync pubspec.yaml to match the actual deployed build number (so it stays in sync for next deploy).
6. Update the minimum app version in Supabase so older builds are blocked from clocking in:
   - Use Supabase MCP tool `execute_sql`: `UPDATE app_config SET value = '<actual_version>', updated_at = NOW() WHERE key = 'minimum_app_version';`
   - Project ID: `xdyzdclwvhkfwbkrdsiz`
7. **Push (run the full /push workflow)** — only if at least one deploy succeeded:
   - **Apply pending migrations**: Check `git status --short supabase/migrations/` and `git diff --name-only HEAD supabase/migrations/` for new/modified migration files. If any are found, list them and run `supabase db push --linked` from the project root. If it fails, stop and report the error.
   - **Commit**: Stage all modified files (pubspec.yaml, build configs, code changes, migrations, etc.). Create a commit with message: `chore: Deploy v<version>+<build> to TestFlight & Google Play` (using HEREDOC, with `Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>`).
   - **Push**: `git push` (or `git push -u origin HEAD` if no upstream).
   - **Vercel deployment**: Run `npx vercel --prod --yes` to trigger and watch the production deployment. Report the deployment URL and status.
8. Report the summary: which deploys succeeded/failed, what build number was deployed, what minimum version is now enforced, and the git push status.

Important notes:
- iOS TestFlight groups: The Fastfile distributes to the "Employee" EXTERNAL group only. The "Tri-Logis" INTERNAL group has automatic distribution enabled in App Store Connect and receives all builds automatically. Do NOT add "Tri-Logis" to the Fastfile groups — it causes an API error.
- Apple sometimes increments the build number (e.g. pubspec says +20 but Apple processes as build 21). Always check the Fastlane output for the actual build number and sync pubspec.yaml accordingly.
- Only update the minimum version if at least one deploy succeeded.
- Run both deploys as background tasks in parallel for speed.

Optional argument: $ARGUMENTS
- If the user says "android only" or "skip ios", only deploy Android
- If the user says "ios only" or "skip android", only deploy iOS
- If the user says "no enforce" or "sans bloquer", skip the minimum version update
