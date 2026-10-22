#!/usr/bin/env zsh
# release.sh — Build, verify, package, and publish a Gearbox release.
#
# Usage: ./release.sh <version> [--generated-notes] [--skip-tests]
#   e.g. ./release.sh 0.1
#
# Requires: swift, hdiutil, gh (GitHub CLI), git, codesign, xcrun, plutil,
#   security, lipo, and python3 with dmgbuild; preflight checks each.
#
# A Swift package, not an Xcode project: swift builds the binary, and
# scripts/assemble-app.sh builds the app bundle around it, as it does for
# build.sh. Ported from Dipstick's release.sh, the other Swift package over mrk
# (itself PasswordGen's), with every guard the sibling scripts carry.

set -euo pipefail

REPO="sevmorris/Gearbox"
APP_NAME="Gearbox"
BINARY_NAME="Gearbox"

# notarytool keychain profile, shared by every sibling release script. A profile
# cannot be exported, so a new Mac needs it created again under this name:
#   xcrun notarytool store-credentials notarytool --apple-id <email> --team-id T9RLNAXPWU
# Set NOTARY_PROFILE to use another (a Mac still holding the old WoWoNotary one).
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool}"

# ── Args ──────────────────────────────────────────────────────────────────────
# One positional argument (the version) plus optional flags in any position.
# Anything else — including no arguments, or a second positional that isn't a
# flag — fails with usage.
ALLOW_GENERATED_NOTES=0
SKIP_TESTS=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --generated-notes) ALLOW_GENERATED_NOTES=1 ;;
        --skip-tests)      SKIP_TESTS=1 ;;
        *)                 ARGS+=("$arg") ;;
    esac
done

if [[ ${#ARGS[@]} -ne 1 ]]; then
    echo "Usage: $0 <version> [--generated-notes] [--skip-tests]"
    echo "  e.g. $0 0.1"
    echo ""
    echo "  --generated-notes  Release without a curated release-notes file,"
    echo "                     generating notes from commit subjects instead."
    echo "  --skip-tests       Skip the test suite (not recommended; use only when"
    echo "                     tests are known-broken and you need an emergency release)."
    exit 1
fi

VERSION="${ARGS[1]}"
TAG="v${VERSION}"
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="$SCRIPT_DIR"
APP_SWIFT="$PROJECT_DIR/Sources/Gearbox/GearboxApp.swift"
ENTITLEMENTS="$PROJECT_DIR/Gearbox.entitlements"
BUILD_DIR="/tmp/gearbox_build_${VERSION}"
APP_PATH="$BUILD_DIR/${APP_NAME}.app"
DMG="/tmp/Gearbox-${TAG}.dmg"
APP_ZIP="/tmp/Gearbox-${TAG}-app.zip"
MOUNT="/tmp/gearbox_verify_${VERSION}"
NOTES_FILE="$PROJECT_DIR/release-notes/${TAG}.md"
TEST_LOG="/tmp/gearbox_test_${VERSION}.log"
IDENTITY="Developer ID Application: Seven Morris (T9RLNAXPWU)"

# ── Helpers ───────────────────────────────────────────────────────────────────
step()  { echo "\n▶ $*"; }
ok()    { echo "  ✓ $*"; }
fail()  { echo "\n  ✗ $*" >&2; exit 1; }
warn()  { echo "  ! $*" >&2; }

cleanup() {
    # ${VAR:-} so the trap fires cleanly even if the script exits before these
    # paths are defined, which `set -u` would otherwise turn into an error
    # inside the trap. A failure between attach and detach leaves the image
    # mounted, so detach before removing the mount point.
    if [[ -d "${MOUNT:-}" ]]; then
        hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    fi
    rm -rf -- "${MOUNT:-}" "${BUILD_DIR:-}" 2>/dev/null || true
    rm -f  -- "${DMG:-}" 2>/dev/null || true
    rm -f  -- "${APP_ZIP:-}" 2>/dev/null || true
    rm -f  -- "${TEST_LOG:-}" 2>/dev/null || true
}
# A zsh EXIT trap does not fire on a signal, so Ctrl-C or a closed terminal
# during the long notarization wait would skip the cleanup. These handlers exit
# and let the EXIT trap do it, exactly once.
trap 'exit 130' INT
trap 'exit 143' TERM
trap cleanup EXIT

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight checks"
python3 -c "import dmgbuild" 2>/dev/null \
    || fail "python3 module 'dmgbuild' not installed — run: python3 -m pip install dmgbuild"

# Importing dmgbuild does not prove it can run. On 2026-09-16 a pyenv Python
# built against Xcode 27's macOS 27 SDK, on macOS 26.7, imported it and then
# segfaulted on its first subprocess — dmgbuild's hdiutil call.
python3 -c "import subprocess; subprocess.run(['/usr/bin/true'], check=True)" &>/dev/null \
    || fail "$(command -v python3) cannot start a subprocess, so dmgbuild would crash — rebuild that Python against an SDK no newer than this macOS"

for cmd in swift hdiutil gh git codesign xcrun python3 plutil security lipo; do
    command -v $cmd &>/dev/null || fail "'$cmd' not found in PATH"
done
ok "Tools present"

[[ -f "$ENTITLEMENTS" ]] || fail "Entitlements file not found: ${ENTITLEMENTS#$PROJECT_DIR/}"
plutil -lint "$ENTITLEMENTS" >/dev/null || fail "${ENTITLEMENTS#$PROJECT_DIR/} is not a valid plist"
security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY" \
    || fail "Signing identity not found in the keychain: $IDENTITY"
ok "Entitlements and signing identity present"

# True when this user's console session is locked. Reads IOKit's console-user
# records for our uid rather than taking the first: with more than one user
# logged in, the first record need not be ours.
screen_locked() {
    local plist i uid
    plist=$(ioreg -n Root -d1 -a 2>/dev/null) || return 1
    for i in 0 1 2 3 4 5 6 7; do
        uid=$(plutil -extract "IOConsoleUsers.$i.kCGSSessionUserIDKey" raw -o - - <<<"$plist" 2>/dev/null) || return 1
        [[ "$uid" == "$(id -u)" ]] || continue
        [[ "$(plutil -extract "IOConsoleUsers.$i.CGSSessionScreenIsLocked" raw -o - - <<<"$plist" 2>/dev/null)" == true ]]
        return
    done
    return 1
}

# A missing profile used to surface at the notarization step, after a clean
# build — which is how a new Mac found out. Asking costs one API call.
# A locked screen reads as a missing profile: notarytool keeps its credentials
# in the data-protection keychain, which locks with the screen. On 2026-09-24 a
# release stopped here at 4 a.m. and was sent looking for a profile that was
# there all along. Asked only once the check has failed, so it can never stop a
# release that would otherwise go ahead.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null; then
    screen_locked && fail "The screen is locked, so notarytool cannot read its keychain profile '$NOTARY_PROFILE' — unlock the Mac and re-run"
    fail "notarytool profile '$NOTARY_PROFILE' is missing, rejected or unreachable — create it with: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <email> --team-id T9RLNAXPWU"
fi
ok "notarytool profile '$NOTARY_PROFILE' works"

cd "$PROJECT_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
    fail "Working tree is dirty — commit or stash changes before releasing"
fi
ok "Working tree clean"

# Resolve the tracked remote/branch. Fall back to `origin` + current branch
# when no upstream is configured; `-u` sets it on first push so subsequent
# runs resolve cleanly.
if UPSTREAM=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null); then
    REMOTE="${UPSTREAM%%/*}"
    BRANCH="${UPSTREAM#*/}"
else
    REMOTE="origin"
    BRANCH=$(git branch --show-current)
fi

# Releases are cut from main, and only from main. Work happens on branches
# that reach main when the owner merges them, and a release from one of those
# would publish unmerged code as "latest" — nothing else in this preflight
# asks which branch it is releasing from. Both the branch checked out and the
# branch the push lands on have to be main: a session branch that tracks main
# would otherwise push its own commits straight onto it.
CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" != "main" || "$BRANCH" != "main" ]]; then
    fail "Releases are cut from main only — HEAD is on '${CURRENT_BRANCH:-a detached HEAD}' and would push to $REMOTE/$BRANCH. Switch to main and re-run"
fi
ok "Releasing from main"

# The remote's tags are the record, not this clone's. A clone that has not seen
# a release — made on another Mac, or one whose tag push failed — passes a
# local-only check, then builds, notarizes and pushes the branch before the tag
# is refused, as re-runs of ClipHack and WaxOnWaxOff did on 2026-09-16. Fetching
# first lets the checks below see every published tag, and a local tag that
# disagrees with the remote makes the fetch itself fail.
git fetch --tags "$REMOTE" \
    || fail "Could not fetch tags from $REMOTE — a tag reported as rejected above points at different commits here and on $REMOTE"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    fail "Tag $TAG already exists — has this version been released?"
fi
ok "Tag $TAG is available"

# The push at the end is a fast-forward or nothing, so a remote branch with
# commits this one lacks would fail it after the notarization. Stop now instead.
if git rev-parse -q --verify "refs/remotes/$REMOTE/$BRANCH" >/dev/null \
        && ! git merge-base --is-ancestor "$REMOTE/$BRANCH" HEAD; then
    fail "$REMOTE/$BRANCH has commits that HEAD lacks — pull before releasing"
fi
ok "HEAD contains everything on $REMOTE/$BRANCH"

# ── Version ordering ──────────────────────────────────────────────────────────
# Nothing here stopped a release going backwards. On 2026-09-03 Magic Backup
# Machine published v1.3.9 on top of v1.4.2 — two sessions releasing from one
# clone, neither aware of the other. GitHub served the older build as "latest"
# from that moment, and because the update checker compares numerically, every
# client already on 1.4.2 read 1.3.9 as older and reported itself up to date.
# The release could not reach anyone.
#
# Tags are the record of what is actually published, and what "latest" keys on,
# so they are what this compares against. Set ALLOW_DOWNGRADE=1 to override.
step "Checking version ordering"
version_core() { printf '%s' "${1%%[-+]*}"; }
HIGHEST_TAG=$(git tag --list 'v[0-9]*' --sort=-v:refname | head -1 | sed 's/^v//')
if [[ -n "$HIGHEST_TAG" ]]; then
    NEW_CORE=$(version_core "$VERSION")
    REF_CORE=$(version_core "$HIGHEST_TAG")
    # Numeric cores only: `sort -V` places 1.7.0 ahead of 1.7.0-rc.1, backwards
    # from semver, and comparing raw strings would block any release that
    # follows its own release candidate.
    if [[ "$NEW_CORE" != "$REF_CORE" ]] \
       && [[ "$(printf '%s\n%s\n' "$NEW_CORE" "$REF_CORE" | sort -V | head -1)" == "$NEW_CORE" ]]; then
        if [[ "${ALLOW_DOWNGRADE:-0}" != "0" ]]; then
            warn "$VERSION sorts below tag v$HIGHEST_TAG — continuing, ALLOW_DOWNGRADE is set"
        else
            fail "$VERSION sorts below the highest tag v$HIGHEST_TAG. Publishing it would leave GitHub serving an older build as 'latest', and clients on $HIGHEST_TAG would be told they are up to date. Set ALLOW_DOWNGRADE=1 to override."
        fi
    fi
fi
ok "Version $VERSION does not go backwards"

# Absent siblings are not drift — a fresh clone or a CI checkout has none, and
# the check passes quietly. Only a content mismatch stops the release.
#
# Worded to avoid quoting the registration marker itself: check-shared.sh finds
# shared files by grepping for that phrase, so spelling it here would enrol this
# script — which is app-specific and must never be compared across repos.
step "Checking shared files against sibling repos"
"$PROJECT_DIR/scripts/check-shared.sh" \
    || fail "Shared files have drifted from the sibling repos"

# ── Release-notes gate ────────────────────────────────────────────────────────
# The notes are read much later, at the GitHub-release step — by which point the
# branch and the tag have both been pushed. Failing there would strand a pushed
# tag with no release behind it, so the absence has to be caught here, while
# nothing has been mutated and nothing has left the machine.
#
# Without this, a forgotten notes file is invisible: the curated path announces
# itself, the generated path says nothing, and both end on the same "Release
# published" line. Shipping auto-generated notes becomes a silent default rather
# than a decision.
if [[ -f "$NOTES_FILE" ]]; then
    ok "Curated notes present: release-notes/${TAG}.md"
elif (( ALLOW_GENERATED_NOTES )); then
    echo "\n  ⚠ --generated-notes — publishing $TAG without curated notes" >&2
    echo "      expected:  release-notes/${TAG}.md" >&2
    echo "      notes will be generated from commit subjects since the last tag" >&2
    ok "Generated notes accepted"
else
    echo "      expected:  release-notes/${TAG}.md" >&2
    fail "No curated notes for $TAG — write that file, or re-run with --generated-notes"
fi

# The minimum macOS is declared once, in Package.swift, and the Info.plist is
# written from it by scripts/assemble-app.sh.
MIN_DECLARED=$(sed -nE 's/.*\.macOS\("([0-9]+(\.[0-9]+){0,2})"\).*/\1/p' "$PROJECT_DIR/Package.swift" | head -1)
[[ -n "$MIN_DECLARED" ]] \
    || fail "Could not read the minimum macOS from Package.swift — expected platforms: [.macOS(\"X.Y\")]"
ok "Package.swift declares macOS $MIN_DECLARED"

# ── Tests ─────────────────────────────────────────────────────────────────────
# CI runs GearboxTests, but nothing here checks that it is green, and CI never
# runs the Swift toolchain on this Mac, the one that builds the release.
# FilmStrip's step, with its escape hatch.
#
# Before the version bump, like every gate above: a failure here leaves nothing
# committed and nothing to undo.
step "Running unit tests"
if (( SKIP_TESTS )); then
    warn "Skipping tests (--skip-tests)"
else
    if ! swift test > "$TEST_LOG" 2>&1; then
        cat "$TEST_LOG" >&2
        fail "Tests failed — fix before releasing, or pass --skip-tests for an emergency release"
    fi
    ok "Tests passed"
fi

# ── Version bump ──────────────────────────────────────────────────────────────
# The version lives in appVersion, which the update check falls back to when
# there is no bundle; the Info.plist below is written from VERSION.
step "Bumping version to $VERSION"
CURRENT=$(sed -nE 's/^let appVersion = "([^"]*)"$/\1/p' "$APP_SWIFT")
[[ -n "$CURRENT" ]] || fail "Could not read appVersion from ${APP_SWIFT#$PROJECT_DIR/}"
if [[ "$CURRENT" == "$VERSION" ]]; then
    ok "Already at $VERSION — skipping bump"
else
    sed -i '' "s/^let appVersion = \"${CURRENT}\"$/let appVersion = \"${VERSION}\"/" "$APP_SWIFT"
    [[ "$(sed -nE 's/^let appVersion = "([^"]*)"$/\1/p' "$APP_SWIFT")" == "$VERSION" ]] \
        || fail "appVersion rewrite did not take"
    git add "$APP_SWIFT"
    git commit -m "Bump version to $VERSION"
    ok "Bumped $CURRENT → $VERSION (committed)"
fi

# ── Build ─────────────────────────────────────────────────────────────────────
# A scratch path of its own, so every release builds from nothing rather than
# from whatever .build/ last held.
#
# swift builds for this Mac's architecture: arm64, which is what the README
# says. The check below makes sure the binary is what the README promises.
step "Building (clean, release)"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
SPM="$BUILD_DIR/spm"
swift build -c release --scratch-path "$SPM" 2>&1 | grep -v "^Build complete" || true
BIN_PATH=$(swift build -c release --scratch-path "$SPM" --show-bin-path)
[[ -f "$BIN_PATH/$BINARY_NAME" ]] || fail "swift build produced no $BINARY_NAME binary"
BUILT_ARCHS=$(lipo -archs "$BIN_PATH/$BINARY_NAME")
[[ " $BUILT_ARCHS " == *" arm64 "* ]] || fail "Binary is '$BUILT_ARCHS', not arm64"
ok "Built $BINARY_NAME ($BUILT_ARCHS)"

# ── Assemble the app bundle ───────────────────────────────────────────────────
# The same script build.sh uses, so a local build and a release are the same
# bundle: the icon, NSAppleEventsUsageDescription, and LSMinimumSystemVersion
# from Package.swift.
step "Assembling ${APP_NAME}.app"
"$PROJECT_DIR/scripts/assemble-app.sh" "$BIN_PATH/$BINARY_NAME" "$APP_PATH" "$VERSION" "$MIN_DECLARED" \
    || fail "Assembling the bundle failed"
# The Login Items pane runs mrk's sync-login-items, whose osascript asks System
# Events for the login items, and macOS holds Gearbox responsible for that
# request. This key is the sentence macOS shows when it asks; without it, macOS
# refuses the request without asking.
/usr/libexec/PlistBuddy -c "Print :NSAppleEventsUsageDescription" "$APP_PATH/Contents/Info.plist" &>/dev/null \
    || fail "The bundle has no NSAppleEventsUsageDescription — macOS would refuse the Login Items pane's request to System Events without asking"
ok "Bundle assembled"

# ── Sign ──────────────────────────────────────────────────────────────────────
# Developer ID with the hardened runtime and a secure timestamp. All three are
# required for notarization; an ad-hoc signature cannot be notarized at all.
step "Codesigning app"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_PATH" \
    || fail "Codesigning failed"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -3
# The same request again: under the hardened runtime, macOS also refuses Apple
# events from an app whose signature lacks this entitlement, and does not ask.
# build.sh's ad hoc signature has no hardened runtime, so a local build reads
# the login items whether the entitlement is there or not; only a release
# would find out. Read into a variable first: under pipefail, grep -q closing
# the pipe early could fail the check with the entitlement there.
SIGNED_ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null || true)
grep -qF "com.apple.security.automation.apple-events" <<<"$SIGNED_ENTITLEMENTS" \
    || fail "The signature has no com.apple.security.automation.apple-events entitlement — the Login Items pane could not ask System Events"
ok "Codesigning complete"

# ── Verify app version ────────────────────────────────────────────────────────
step "Verifying built app version"
BUILT_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)
[[ "$BUILT_VERSION" == "$VERSION" ]] || \
    fail "App version mismatch: expected $VERSION, got $BUILT_VERSION"
ok "App reports $BUILT_VERSION"

# The macOS this release needs, read from the app as built, for the notes'
# "Requires macOS" line and the update check's marker below. Read here, before
# notarizing, so a build without it stops before anything leaves the machine.
MIN_MACOS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
[[ "$MIN_MACOS" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] \
    || fail "Built app has no usable LSMinimumSystemVersion ('${MIN_MACOS}') — the release notes and the update check need it"
ok "Requires macOS $MIN_MACOS"

# ── Notarize app ──────────────────────────────────────────────────────────────
step "Notarizing app"
# Stapling the DMG alone leaves the app unstapled once it is dragged out, which
# is the only form anyone actually runs. Gatekeeper still passes it — it falls
# back to asking Apple — but that needs a working network on first launch. So
# the app gets its own notarization round trip and its own ticket here, before
# the DMG is built around it; the DMG is then stapled separately below.
#
# The ticket covers this exact cdhash, so this has to run after codesigning and
# before the app is copied into the DMG.
rm -f "$APP_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --wait --keychain-profile "$NOTARY_PROFILE" \
    || fail "App notarization failed"
xcrun stapler staple "$APP_PATH" || fail "Stapling the app failed"
xcrun stapler validate "$APP_PATH" >/dev/null || fail "App has no valid stapled ticket"
rm -f "$APP_ZIP"
ok "App notarized and stapled"

# ── Create DMG ────────────────────────────────────────────────────────────────
step "Creating DMG"
rm -f "$DMG"
# dmgbuild rather than bare hdiutil so the installer window is laid out:
# background art with an arrow, the app and the Applications alias pinned to its
# endpoints, chrome hidden. Matches the sibling apps.
DMG_BACKGROUND="$PROJECT_DIR/tools/dmg/dmg-background-gearbox.png"
[[ -f "$DMG_BACKGROUND" ]] \
    || fail "Missing DMG background: ${DMG_BACKGROUND#$PROJECT_DIR/} — regenerate with tools/dmg/make-background.py --app-name \"$APP_NAME\" --slug gearbox"

# A python3 that actually has dmgbuild, not Xcode's bundled one; /bin prepended
# because dmgbuild shells out to bare tool names.
PY_BIN=$(command -v python3)
PATH="/bin:/usr/bin:$PATH" "$PY_BIN" -m dmgbuild \
    -s "$PROJECT_DIR/tools/dmg/dmg-settings.py" \
    -D app="$APP_PATH" \
    -D background="$DMG_BACKGROUND" \
    "$APP_NAME $TAG" "$DMG"
[[ -f "$DMG" ]] || fail "dmgbuild did not produce $DMG"
ok "Created $(du -sh "$DMG" | cut -f1) DMG"

# ── Notarize ──────────────────────────────────────────────────────────────────
step "Notarizing DMG"
# NOTARY_PROFILE is defined at the top and proven usable in preflight.

# The image itself is signed, not only the app inside it. An unsigned DMG
# reports "no usable signature" to spctl even with a valid ticket stapled, so
# the wrapper can never be assessed — a download that looks unsigned to
# Gatekeeper while the app within it is perfectly notarized. Signing has to
# precede submission; stapling afterwards leaves the signature intact.
codesign --force --timestamp --sign "$IDENTITY" "$DMG" \
    || fail "Signing the DMG failed"

xcrun notarytool submit "$DMG" --wait --keychain-profile "$NOTARY_PROFILE" \
    || fail "DMG notarization failed — run 'xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE' for the reason"
xcrun stapler staple "$DMG" || fail "Stapling the DMG failed"
xcrun stapler validate "$DMG" >/dev/null || fail "The DMG has no valid stapled ticket"
spctl --assess --type open --context context:primary-signature "$DMG" 2>&1 \
    || fail "Gatekeeper rejected the DMG"
ok "Notarization complete"

# ── Verify DMG ────────────────────────────────────────────────────────────────
step "Verifying DMG contents"
rm -rf "$MOUNT"
mkdir "$MOUNT"
hdiutil attach "$DMG" -mountpoint "$MOUNT" -quiet -nobrowse -readonly
DMG_VERSION=$(defaults read "$MOUNT/${APP_NAME}.app/Contents/Info.plist" CFBundleShortVersionString)
# Check the ticket on the copy that actually ships, not on the build product
# we stapled — those are the two that can drift apart. Captured before the
# detach so the volume is never left mounted on a failure.
if xcrun stapler validate "$MOUNT/${APP_NAME}.app" >/dev/null 2>&1; then
    DMG_APP_STAPLED=1
else
    DMG_APP_STAPLED=0
fi
# What a user launches is the app inside the image, so assess that too and
# require notarization specifically: a merely Developer ID-signed app would
# still be refused on a first launch.
ASSESS=$(spctl --assess --type exec -vv "$MOUNT/${APP_NAME}.app" 2>&1 || true)
# The installer window is these two files: the .DS_Store carrying the layout and
# the background art it points at. Without them the image opens as a plain
# folder — which is how ClipHack 1.25.2 and 1.25.3 shipped, undetected, because
# nothing looked inside the image it had just built.
DMG_DSSTORE=( "$MOUNT"/.DS_Store(N) )
DMG_BGART=( "$MOUNT"/.background.*(N) )
hdiutil detach "$MOUNT" -quiet
[[ "$DMG_APP_STAPLED" == 1 ]] || \
    fail "App inside the DMG carries no notarization ticket"
grep -q "source=Notarized Developer ID" <<<"$ASSESS" || \
    fail "The app in the DMG is not recognised as notarized: $ASSESS"
[[ "$DMG_VERSION" == "$VERSION" ]] || \
    fail "DMG version mismatch: expected $VERSION, got $DMG_VERSION"
(( ${#DMG_DSSTORE} && ${#DMG_BGART} )) || \
    fail "DMG has no installer window layout (.DS_Store and .background.* are not both present)"
ok "DMG contains $DMG_VERSION, notarized, with its installer window layout"

# The README links to /releases/latest and names no version, so unlike the
# sibling scripts there is no download link here to rewrite.

# ── Tag and push ──────────────────────────────────────────────────────────────
step "Tagging and pushing"
git tag "$TAG"
# One atomic push: the branch and the tag land together or not at all. As two
# pushes, a refused tag left the release commit on the branch with nothing
# tagging it — which is how ClipHack put a 1.25.2 commit on main with no tag
# behind it on 2026-09-16. On failure nothing has been published, so the tag
# made above is removed and a re-run starts clean.
if ! git push --atomic -u "$REMOTE" "HEAD:refs/heads/$BRANCH" "refs/tags/$TAG"; then
    git tag -d "$TAG" >/dev/null
    fail "Push to $REMOTE failed and nothing was published — the local $TAG tag has been removed"
fi
ok "Pushed $TAG to $REMOTE/$BRANCH"

# ── GitHub release ────────────────────────────────────────────────────────────
step "Creating GitHub release"
# Every release says which macOS it needs: a line people read, and a marker the
# app's update check reads, which GitHub does not render. A Mac below it is told
# so instead of being offered a DMG whose app will not open.
REQUIRES_FOOTER="

---
Requires macOS ${MIN_MACOS} or later.
<!-- minimum-macos: ${MIN_MACOS} -->"
# A curated description at release-notes/v<version>.md wins over the generated
# commit list. Use it when the release needs prose the log can't produce —
# an explanation of what changed and what deliberately didn't. Without one,
# fall back to subjects since the last tag.
#
# NOTES_FILE is defined with the other paths and its absence is gated in
# preflight, so reaching the generated branch here means --generated-notes was
# passed deliberately.
if [[ -f "$NOTES_FILE" ]]; then
    ok "Using curated notes: release-notes/${TAG}.md"
    gh release create "$TAG" "$DMG" \
        --repo "$REPO" \
        --title "$APP_NAME $TAG" \
        --notes "$(<"$NOTES_FILE")${REQUIRES_FOOTER}"
else
    # App tags only: a non-release tag (a dependency release, a checkpoint) made
    # after the last release would otherwise be taken as it and silently shorten
    # these notes.
    PREV_TAG=$(git tag --list 'v[0-9]*' --sort=-creatordate | grep -v "^${TAG}$" | head -1 || true)
    if [[ -n "$PREV_TAG" ]]; then
        CHANGES=$(git log "${PREV_TAG}..HEAD" --pretty=format:"- %s" \
            | grep -v "^- Bump version" || true)
    else
        CHANGES=$(git log --pretty=format:"- %s" \
            | grep -v "^- Bump version" || true)
    fi
    [[ -n "$CHANGES" ]] || CHANGES="- Initial release"
    RELEASE_NOTES="### Changes
${CHANGES}"
    gh release create "$TAG" "$DMG" \
        --repo "$REPO" \
        --title "$APP_NAME $TAG" \
        --notes "${RELEASE_NOTES}${REQUIRES_FOOTER}"
fi
ok "Release published"

# ── Remove old releases (keep the ${KEEP_RELEASES} most recent) ───────────────
KEEP_RELEASES=5
step "Removing old releases (keeping ${KEEP_RELEASES} most recent)"
# Filtered to v* so non-release tags (build-dependency releases, checkpoints)
# are never in scope for pruning by date alone.
# Never prune the newest release for each minimum macOS that a later release
# left behind: it is the last version a Mac on that macOS can run. The update
# check stops there, and the docs and release notes send those users to it
# (WaxOnWaxOff 2.14.1 for macOS 14). Read from the minimum-macos marker every
# release's notes end with, newest first. The newest release overall is listed
# too, harmlessly, since KEEP_RELEASES already keeps it.
PROTECTED_TAGS=$(gh api "repos/${REPO}/releases?per_page=100" \
    --jq '.[] | select(.tag_name | test("^v[0-9]")) | [.published_at, .tag_name, (((.body // "") | capture("<!-- minimum-macos: (?<m>[0-9.]+) -->") | .m) // "")] | @tsv' \
    | sort -r | awk -F'\t' '$3 != "" && !seen[$3]++ { print $2 }' || true)
OLD_TAGS=$(gh release list --repo "$REPO" --limit 100 --json tagName \
    --jq '.[].tagName' | grep -E '^v[0-9]' | tail -n +$((KEEP_RELEASES + 1)) || true)
if [[ -z "$OLD_TAGS" ]]; then
    ok "No old releases to remove"
else
    while IFS= read -r old_tag; do
        if grep -qxF -- "$old_tag" <<<"$PROTECTED_TAGS"; then
            ok "Kept $old_tag: the newest release for its minimum macOS"
            continue
        fi
        # Prunes the release page and its asset, NOT the git tag. The tag is the
        # only durable pointer to what shipped: without it a version is
        # unbuildable from a clean clone and unreachable from its own history.
        # A release page is a convenience; a tag is the record.
        gh release delete "$old_tag" --repo "$REPO" --yes 2>/dev/null || true
        ok "Pruned release page for $old_tag (tag kept)"
    done <<< "$OLD_TAGS"
fi

# ── Clean up temp files ───────────────────────────────────────────────────────
step "Cleaning up"
rm -rf "$MOUNT" "$BUILD_DIR"
rm -f "$DMG"
ok "Temp files removed"

# ── Open release page ─────────────────────────────────────────────────────────
RELEASE_URL="https://github.com/${REPO}/releases/tag/${TAG}"
echo "\n✓ $APP_NAME $TAG released successfully."
echo "  $RELEASE_URL"
open "$RELEASE_URL"
