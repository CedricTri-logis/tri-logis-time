Deploy the Flutter app to iOS (TestFlight) and Android (Google Play alpha) and enforce the minimum app version.

Steps:
1. Bump the build number in `gps_tracker/pubspec.yaml` (increment the +N part)
2. Deploy iOS and Android in parallel:
   - iOS: `cd gps_tracker/ios && bundle exec fastlane beta` (requires Homebrew Ruby: export PATH="/opt/homebrew/opt/ruby/bin:/opt/homebrew/lib/ruby/gems/4.0.0/bin:$PATH")
   - Android: `cd gps_tracker/android && bundle exec fastlane alpha` (same Ruby path)
3. After both deploys finish, read the ACTUAL build number from the iOS Fastlane output (look for "Build Number: XX" or "build_version: XX" — Apple may increment the build number beyond what pubspec.yaml says). Use the highest build number seen.
4. Sync pubspec.yaml to match the actual deployed build number (so it stays in sync for next deploy).
5. Update the minimum app version in Supabase so older builds are blocked from clocking in:
   - Use Supabase MCP tool `execute_sql`: `UPDATE app_config SET value = '<actual_version>', updated_at = NOW() WHERE key = 'minimum_app_version';`
   - Project ID: `xdyzdclwvhkfwbkrdsiz`
6. Commit and push all changes to GitHub:
   - Stage all modified files (pubspec.yaml, build configs, code changes, migrations, etc.)
   - Create a commit with message: `chore: Deploy v<version>+<build> to TestFlight & Google Play`
   - Push to the current branch on origin
   - Only commit+push if at least one deploy succeeded
7. Report the summary: which deploys succeeded/failed, what build number was deployed, what minimum version is now enforced, and the git push status.

Important notes:
- iOS TestFlight groups: The Fastfile distributes to the "Employee" EXTERNAL group only. The "Tri-Logis" INTERNAL group has automatic distribution enabled in App Store Connect and receives all builds automatically. Do NOT add "Tri-Logis" to the Fastfile groups — it causes an API error.
- Apple sometimes increments the build number (e.g. pubspec says +20 but Apple processes as build 21). Always check the Fastlane output for the actual build number and sync pubspec.yaml accordingly.
- Only update the minimum version if at least one deploy succeeded.
- Run both deploys as background tasks in parallel for speed.

Optional argument: $ARGUMENTS
- If the user says "android only" or "skip ios", only deploy Android
- If the user says "ios only" or "skip android", only deploy iOS
- If the user says "no enforce" or "sans bloquer", skip the minimum version update
