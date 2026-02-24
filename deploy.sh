#!/bin/bash
# =============================================================================
# deploy.sh — Build, deploy to stores, and enforce minimum version
#
# Usage:
#   ./deploy.sh              # Bump build, deploy iOS + Android, update min version
#   ./deploy.sh --no-bump    # Deploy without bumping version
#   ./deploy.sh --skip-ios   # Skip iOS deploy
#   ./deploy.sh --skip-android  # Skip Android deploy
#   ./deploy.sh --no-enforce # Don't update minimum version in Supabase
# =============================================================================

set -euo pipefail

# -- Config -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/gps_tracker"
PUBSPEC="$PROJECT_DIR/pubspec.yaml"
SUPABASE_URL="https://xdyzdclwvhkfwbkrdsiz.supabase.co"
SUPABASE_SERVICE_ROLE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhkeXpkY2x3dmhrZndia3Jkc2l6Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2NzgzNTUwOSwiZXhwIjoyMDgzNDExNTA5fQ.VG_jEsaI0NL-V58ZRnaAasothRdPOxFg3JqJNkWRogY"

# Homebrew Ruby (required for Fastlane)
export PATH="/opt/homebrew/opt/ruby/bin:/opt/homebrew/lib/ruby/gems/4.0.0/bin:$PATH"

# -- Parse flags --------------------------------------------------------------
BUMP=true
DEPLOY_IOS=true
DEPLOY_ANDROID=true
ENFORCE_VERSION=true

for arg in "$@"; do
  case $arg in
    --no-bump)       BUMP=false ;;
    --skip-ios)      DEPLOY_IOS=false ;;
    --skip-android)  DEPLOY_ANDROID=false ;;
    --no-enforce)    ENFORCE_VERSION=false ;;
    -h|--help)
      echo "Usage: ./deploy.sh [--no-bump] [--skip-ios] [--skip-android] [--no-enforce]"
      exit 0
      ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

# -- Helpers ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()   { echo -e "${GREEN}[deploy]${NC} $1"; }
warn()  { echo -e "${YELLOW}[deploy]${NC} $1"; }
error() { echo -e "${RED}[deploy]${NC} $1"; }

# -- Read current version -----------------------------------------------------
CURRENT_VERSION=$(grep '^version:' "$PUBSPEC" | sed 's/version: //')
VERSION_NAME=$(echo "$CURRENT_VERSION" | cut -d'+' -f1)
BUILD_NUMBER=$(echo "$CURRENT_VERSION" | cut -d'+' -f2)

log "Current version: $CURRENT_VERSION"

# -- Bump build number --------------------------------------------------------
if [ "$BUMP" = true ]; then
  # Query TestFlight for the actual latest build number to avoid Apple incrementing
  if [ "$DEPLOY_IOS" = true ]; then
    log "Querying latest TestFlight build number..."
    export PATH="/opt/homebrew/opt/ruby/bin:/opt/homebrew/lib/ruby/gems/4.0.0/bin:$PATH"
    TF_OUTPUT=$(cd "$PROJECT_DIR/ios" && bundle exec fastlane latest_build 2>&1 || true)
    TF_BUILD=$(echo "$TF_OUTPUT" | grep -o 'LATEST_TF_BUILD:[0-9]*' | cut -d: -f2 || true)
    if [ -n "$TF_BUILD" ]; then
      log "Latest TestFlight build: $TF_BUILD"
      # Use the higher of pubspec or TestFlight, then +1
      if [ "$TF_BUILD" -ge "$BUILD_NUMBER" ] 2>/dev/null; then
        NEW_BUILD=$((TF_BUILD + 1))
      else
        NEW_BUILD=$((BUILD_NUMBER + 1))
      fi
    else
      warn "Could not query TestFlight, falling back to pubspec +1"
      NEW_BUILD=$((BUILD_NUMBER + 1))
    fi
  else
    NEW_BUILD=$((BUILD_NUMBER + 1))
  fi
  NEW_VERSION="${VERSION_NAME}+${NEW_BUILD}"
  sed -i '' "s/^version: .*/version: ${NEW_VERSION}/" "$PUBSPEC"
  log "Bumped version to: $NEW_VERSION"
else
  NEW_VERSION="$CURRENT_VERSION"
  NEW_BUILD="$BUILD_NUMBER"
  log "Skipping version bump (using $NEW_VERSION)"
fi

# -- Deploy -------------------------------------------------------------------
IOS_PID=""
ANDROID_PID=""
IOS_LOG=$(mktemp)
ANDROID_LOG=$(mktemp)

if [ "$DEPLOY_IOS" = true ]; then
  log "Starting iOS deploy..."
  (cd "$PROJECT_DIR/ios" && bundle exec fastlane beta 2>&1) > "$IOS_LOG" &
  IOS_PID=$!
fi

if [ "$DEPLOY_ANDROID" = true ]; then
  log "Starting Android deploy..."
  (cd "$PROJECT_DIR/android" && bundle exec fastlane alpha 2>&1) > "$ANDROID_LOG" &
  ANDROID_PID=$!
fi

# -- Wait for deploys ---------------------------------------------------------
IOS_OK=true
ANDROID_OK=true

if [ -n "$ANDROID_PID" ]; then
  if wait "$ANDROID_PID"; then
    log "Android deploy succeeded"
  else
    error "Android deploy FAILED"
    error "Log: $(tail -5 "$ANDROID_LOG")"
    ANDROID_OK=false
  fi
fi

if [ -n "$IOS_PID" ]; then
  if wait "$IOS_PID"; then
    log "iOS deploy succeeded"
  else
    error "iOS deploy FAILED"
    error "Log: $(tail -5 "$IOS_LOG")"
    IOS_OK=false
  fi
fi

# -- Enforce minimum version --------------------------------------------------
if [ "$ENFORCE_VERSION" = true ]; then
  if [ "$IOS_OK" = false ] && [ "$ANDROID_OK" = false ]; then
    error "Both deploys failed — skipping minimum version update"
  else
    log "Updating minimum_app_version to $NEW_VERSION..."
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      -X PATCH \
      "${SUPABASE_URL}/rest/v1/app_config?key=eq.minimum_app_version" \
      -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
      -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
      -H "Content-Type: application/json" \
      -H "Prefer: return=minimal" \
      -d "{\"value\": \"${NEW_VERSION}\"}")

    if [ "$HTTP_CODE" = "204" ]; then
      log "Minimum version enforced: $NEW_VERSION"
      log "Users with older builds will be prompted to update before clock-in"
    else
      error "Failed to update minimum version (HTTP $HTTP_CODE)"
    fi
  fi
fi

# -- Summary ------------------------------------------------------------------
echo ""
echo "========================================"
echo "  Deploy Summary — $NEW_VERSION"
echo "========================================"
[ "$DEPLOY_ANDROID" = true ] && echo "  Android: $( [ "$ANDROID_OK" = true ] && echo '✅ OK' || echo '❌ FAILED' )"
[ "$DEPLOY_IOS" = true ]     && echo "  iOS:     $( [ "$IOS_OK" = true ] && echo '✅ OK' || echo '❌ FAILED' )"
[ "$ENFORCE_VERSION" = true ] && echo "  Min ver: $NEW_VERSION"
echo "========================================"

# Cleanup
rm -f "$IOS_LOG" "$ANDROID_LOG"
