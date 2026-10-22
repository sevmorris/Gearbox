# Gearbox

A Settings window over [mrk](https://github.com/sevmorris/mrk), this Mac's setup repository. It is the third app of the GUI suite over mrk, after Dipstick (the menu bar dashboard) and Barkeep's mrk mode (the Brewfile).

**The rule:** Gearbox runs mrk's own scripts through their check modes and decision options, and never does their work itself. When it needs an interface mrk lacks, the interface goes into mrk first, with its tests and its entry in BIN-1 (`docs/bin/mrk-usage.html`).

## The four panes

| Pane | What it reads | What it changes |
|---|---|---|
| App Preferences | `snapshot-prefs --check`, grouped by the apps of `config/app-prefs.tsv` | **Snapshot…** runs `make snapshot-prefs` in a terminal, where its secret scan can stop and ask |
| macOS Defaults | `defaults.sh --check [--with-trackpad]`, with each key's section and `when` from `config/defaults.tsv` and its description from `docs/defaults/descriptions.tsv` | **Apply All…** runs `make defaults` (or `make trackpad`) in a terminal, after a confirmation that names the restart of Finder, the Dock and SystemUIServer |
| Login Items | `config/login-items.txt` and `sync-login-items --check` | **Add**, **Ignore** and **Remove** run `sync-login-items --add`, `--ignore` and `--remove` |
| Dock | `config/dock.txt` and `dock-setup --check` | Reordering, adding and removing write `config/dock.txt`, the plain list `dock-setup` reads. **Apply…** runs `make dock` in a terminal, after a confirmation |

`descriptions.tsv` and `dock-setup --check` arrived in mrk with [sevmorris/mrk#117](https://github.com/sevmorris/mrk/pull/117). Against an older mrk, the Defaults pane shows the keys without their descriptions, and the Dock pane says to run `make pull`.

**Gearbox never commits.** It changes files in the mrk checkout (`config/dock.txt`, and through `sync-login-items` the login-items list and the manual). Committing stays with `mrk-push` and `pushall`, with their secret scan and gates, and Dipstick's Unrecorded panel shows what is waiting. Barkeep works the same way.

The checkout is `~/mrk`, or the one `MRK_ROOT` names. Scripts run in it with the environment of an interactive login zsh, as Dipstick and Barkeep run them. A command that changes the Mac or pushes runs in a terminal window, through a self-deleting `.command` file, so it needs no Automation permission.

The Login Items pane needs one: `sync-login-items` reads the login items from System Events with AppleScript, and macOS asks once whether Gearbox may control System Events. If you decline, or System Events returns no login items, `sync-login-items` refuses to compare anything, and the pane says how to give access in System Settings → Privacy & Security → Automation.

## Install

Download the DMG from the [latest release](https://github.com/sevmorris/Gearbox/releases/latest), open it, and drag Gearbox to Applications. It is signed with a Developer ID and notarized by Apple.

**Check for Updates…** in the Gearbox menu asks GitHub for a newer Gearbox. Gearbox also asks without being asked, at launch and when it comes to the front, at most once an hour, and tells you only when a newer version is out. The sidebar then names that version. A version that needs a newer macOS than this Mac has is not offered. The update check is Gearbox's one network request. It keeps the time of the last check, and the version you said Not Now to, in Gearbox's own defaults domain.

## Build, test, look

```bash
./build.sh                 # build/Gearbox.app, signed ad hoc
swift test                 # the parsers, every command's arguments, the runner and the panes, against stub scripts
build/Gearbox.app/Contents/MacOS/Gearbox --snapshot /tmp/gearbox-shots
```

`--snapshot DIR` loads each pane in the app's own window, against the real checkout, draws each into `DIR/<n>-<pane>.png`, and quits. It runs only the read-only check modes. It puts the app's defaults domain back as it found it: SwiftUI writes the window's frame there as the window opens, and `snapshot-prefs` exports every `io.github.sevmorris.*` domain.

No test runs a real mrk script, touches real defaults or asks GitHub. The scripts are stubs in a temporary folder, the app's settings and the update check's dates go through `UserDefaults.app`, a scratch suite under tests, named by a path in the temporary folder, and the update tests answer for GitHub themselves.

An ad hoc signature changes with every build, and macOS keys the Automation permission to it, so a rebuilt Gearbox asks again.

The icon is drawn by `tools/icon/make-appicon.py`, which writes `assets/AppIcon.icns`. `build.sh` and `release.sh` both build the bundle with `scripts/assemble-app.sh`, so a local build and a release differ only in their signature.

SwiftPM, macOS 15 or later, Apple silicon.

## Release

```bash
caffeinate -dis ./release.sh 0.1
```

`release.sh` runs the tests, builds, signs with the Developer ID, notarizes, and publishes the DMG as a GitHub release. It releases from `main` only. It needs `release-notes/v<version>.md`, with the same prose as that version's entry in [CHANGELOG.md](CHANGELOG.md), the `notarytool` keychain profile, and a `python3` with `dmgbuild`. Its preflight checks each one before it builds anything.

The release is signed with the hardened runtime, which refuses Apple events from an app without the `com.apple.security.automation.apple-events` entitlement and does not ask. `Gearbox.entitlements` has it, for the Login Items pane. `release.sh` stops when the signature lacks the entitlement, or the bundle lacks `NSAppleEventsUsageDescription`. An ad hoc build from `build.sh` has no hardened runtime, so it cannot show this fault.

`tools/dmg/` and `scripts/check-shared.sh` are shared verbatim with the sibling apps, and `release.sh` stops when they differ. Change them in every repository at once.

## License

MIT — Seven Morris
