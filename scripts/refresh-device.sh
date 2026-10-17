#!/usr/bin/env bash
# Keeps Orgnote installed on an iPhone signed by a free Personal Team, whose
# provisioning profiles last only 7 days. Run it often (launchd does); it does
# nothing until the profile is within ORGNOTE_RENEW_DAYS of expiring, then
# requests a fresh profile, builds the committed main branch and reinstalls.
set -euo pipefail

device="${1:?usage: refresh-device.sh <device-udid>}"
renew_days="${ORGNOTE_RENEW_DAYS:-3}"
bundle_id="dev.tenelol.orgnote"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
state="$HOME/Library/Application Support/Orgnote/refresh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

# Prints "<epoch> <path>" for each local profile that signs this app or one
# of its extensions (the widget), whose profiles expire on their own clocks.
app_profiles() {
  local p
  for p in "$profiles"/*.mobileprovision; do
    [ -e "$p" ] || continue
    security cms -D -i "$p" >"$work/profile.plist" 2>/dev/null || continue
    case "$(plutil -extract Entitlements.application-identifier raw "$work/profile.plist" 2>/dev/null)" in
      *".$bundle_id" | *".$bundle_id".*) ;;
      *) continue ;;
    esac
    local expires
    expires="$(plutil -extract ExpirationDate raw "$work/profile.plist")"
    printf '%s %s\n' "$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expires" +%s)" "$p"
  done
}

# The device answers only while paired and on the same network or cable;
# otherwise try again on the next run, well before the profile lapses.
if ! xcrun devicectl device info apps --device "$device" --bundle-id "$bundle_id" \
  --json-output "$work/apps.json" >/dev/null 2>&1; then
  log "device $device not reachable; will retry"
  exit 0
fi
installed=false
grep -q "\"$bundle_id\"" "$work/apps.json" && installed=true

# The first profile to lapse decides; any expired piece stops the app or widget.
earliest="$(app_profiles | sort -n | head -1 | cut -d' ' -f1)"
remaining=$(( ${earliest:-0} - $(date +%s) ))
if $installed && [ "$remaining" -gt $(( renew_days * 86400 )) ]; then
  log "profile valid for $(( remaining / 86400 )) more days; nothing to do"
  exit 0
fi

# Xcode reuses a cached profile while it is valid, so set the old ones aside
# to make it request a fresh 7-day profile. They come back if the build fails.
mkdir -p "$state/replaced-profiles"
# Set-aside profiles are only kept for a failed build; a month is plenty.
find "$state/replaced-profiles" -name '*.mobileprovision' -mtime +30 -delete
moved=()
while read -r _ path; do
  [ -n "$path" ] || continue
  mv "$path" "$state/replaced-profiles/"
  moved+=("$state/replaced-profiles/$(basename "$path")")
done < <(app_profiles)

restore_profiles() {
  local p
  for p in "${moved[@]}"; do mv "$p" "$profiles/"; done
}

# Build what is committed on main, never a half-edited working tree.
mkdir "$work/src"
git -C "$repo" archive main | tar -x -C "$work/src"
(cd "$work/src" && xcodegen generate --quiet)
if ! xcodebuild -project "$work/src/Orgnote.xcodeproj" -scheme Orgnote -configuration Release \
  -destination "id=$device" -derivedDataPath "$state/DerivedData" \
  -allowProvisioningUpdates -quiet build; then
  restore_profiles
  log "build failed; kept the previous profile"
  exit 1
fi

xcrun devicectl device install app --device "$device" \
  "$state/DerivedData/Build/Products/Release-iphoneos/Orgnote.app" >/dev/null
earliest="$(app_profiles | sort -n | head -1 | cut -d' ' -f1)"
log "reinstalled $(git -C "$repo" rev-parse --short main); profiles valid until $(date -r "$earliest" '+%F %R')"
