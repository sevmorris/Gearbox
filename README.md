# Gearbox

A Settings window over [mrk](https://github.com/sevmorris/mrk), this Mac's setup repository. It is the third app of the GUI suite over mrk, after Dipstick (the menu bar dashboard) and Barkeep's mrk mode (the Brewfile).

**The rule:** Gearbox runs mrk's own scripts through their check modes and decision options, and never does their work itself. When it needs an interface mrk lacks, the interface goes into mrk first, with its tests and its entry in BIN-1 (`docs/bin/mrk-usage.html`).

## The four panes

| Pane | What it reads | What it changes |
|---|---|---|
| App Preferences | `snapshot-prefs --check`, grouped by the apps of `config/app-prefs.tsv` | **Snapshot…** runs `make snapshot-prefs` in Gearbox's console, where its secret scan can stop and ask |
| macOS Defaults | `defaults.sh --check [--with-trackpad]`, with each key's section and `when` from `config/defaults.tsv` and its description from `docs/defaults/descriptions.tsv` | Each key's switch turns it off with `defaults.sh --skip` and `--revert`, and on with `--unskip` and `--key`, for every domain of the setting. **Apply This Key** runs `--key` for a key that differs or is absent. **Apply All…** runs `make defaults` (or `make trackpad`) in Gearbox's console, after a confirmation that names the restart of Finder, the Dock and SystemUIServer |
| Login Items | `config/login-items.txt` and `sync-login-items --check` | **Add**, **Ignore** and **Remove** run `sync-login-items --add`, `--ignore` and `--remove` |
| Dock | `config/dock.txt` and `dock-setup --check` | Reordering, adding and removing write `config/dock.txt`, the plain list `dock-setup` reads. **Apply…** runs `make dock` in Gearbox's console, after a confirmation |

`descriptions.tsv` and `dock-setup --check` arrived in mrk with [sevmorris/mrk#117](https://github.com/sevmorris/mrk/pull/117). Against an older mrk, the Defaults pane shows the keys without their descriptions, and the Dock pane says to run `make pull`.

**A key that is off** is one that `config/defaults-skip.tsv` lists: `make defaults` leaves it as it is, and `defaults.sh --check` calls it `skipped`. Turning a key off puts back the value it had before mrk wrote it, from its line in `~/.mrk/defaults-rollback.sh`; a key mrk never changed on this Mac stays as it is. Turning it on writes mrk's value. Either way, `defaults.sh` restarts Finder, the Dock and the menu bar when it changed a key. The switch of a setting that mrk writes to two domains, as the trackpad keys are, turns both. The skip list and these options arrived with [sevmorris/mrk#130](https://github.com/sevmorris/mrk/pull/130). Against an older mrk, the pane says to run `make pull`, and the switches are greyed out.

Gearbox reads the `--check` lines by the contract BIN-1 states for all five check modes ([sevmorris/mrk#122](https://github.com/sevmorris/mrk/pull/122)): fields split at each tab, each with `\t`, `\n` and `\\` undone, and a line taken when it has at least the fields Gearbox knows, since a later mrk may add more at the end. A line with a word Gearbox does not know is passed over. When a check prints lines and Gearbox reads none of them, the pane says this Gearbox is older than mrk's output, rather than show an empty list. With mrk#122, the Dock pane also shows what is in the Dock and not in `config/dock.txt` (what `make dock` deletes), and the Defaults pane shows a key that waits for its app's preferences.

**Gearbox never commits.** It changes files in the mrk checkout (`config/dock.txt`, through `sync-login-items` the login-items list and the manual, and through `defaults.sh` the skip list). Committing stays with `mrk-push` and `pushall`, with their secret scan and gates, and Dipstick's Unrecorded panel shows what is waiting. Barkeep works the same way.

The checkout is `~/mrk`, or the one `MRK_ROOT` names. Scripts run in it with the environment of an interactive login zsh, as Dipstick and Barkeep run them.

The Login Items pane needs Automation permission: `sync-login-items` reads the login items from System Events with AppleScript, and macOS asks once whether Gearbox may control System Events. If you decline, or System Events returns no login items, `sync-login-items` refuses to compare anything, and the pane says how to give access in System Settings → Privacy & Security → Automation.

## The console

A command that changes the Mac or pushes runs in Gearbox's console: a sheet over the window, with a phosphor screen like Magic Backup Machine's. Gearbox runs it as the Terminal window of Gearbox 0.2 did, `make <target>` under zsh in the checkout, with the login shell's environment and `MRK_ROOT`. It runs on a pseudo-terminal of its own, so what it asks works as in Terminal: snapshot-prefs's secret scan stops and asks before it commits, and you type the answer and press Return. ⌃C or ⌘. stops the command. Stop sends ⌃C, then SIGTERM, then SIGKILL. When the command exits, the pane reads mrk again.

The terminal is a dumb one, 80 columns wide, and says so (`TERM=dumb`). It shows text, a program's colours and weights, and a line that writes over itself, as git's progress does. It has no full screen, and `PAGER` and `GIT_PAGER` are `cat`. While the console is up, Gearbox's window does not close and Gearbox does not quit, so nothing hangs up a command half way, between a commit and its push.

The display button over the screen picks Phosphor Green, Phosphor Amber or Plain. A phosphor has one colour, so a program's red and green show in it, and bold glows brighter and dim fainter; Plain shows the colours. Gearbox keeps the choice in its own defaults domain.

## Install

Download the DMG from the [latest release](https://github.com/sevmorris/Gearbox/releases/latest), open it, and drag Gearbox to Applications. It is signed with a Developer ID and notarized by Apple.

**Check for Updates…** in the Gearbox menu asks GitHub for a newer Gearbox. Gearbox also asks without being asked, at launch and when it comes to the front, at most once an hour, and tells you only when a newer version is out. The sidebar then names that version. A version that needs a newer macOS than this Mac has is not offered. The update check is Gearbox's one network request. It keeps the time of the last check, and the version you said Not Now to, in Gearbox's own defaults domain.

## Build, test, look

```bash
./build.sh                 # build/Gearbox.app, signed ad hoc
swift test                 # the parsers, every command's arguments, the runner, the panes and the console, against stub scripts
build/Gearbox.app/Contents/MacOS/Gearbox --snapshot /tmp/gearbox-shots
```

`--snapshot DIR` loads each pane in the app's own window, against the real checkout, draws each into `DIR/<n>-<pane>.png`, then draws the console running `make dock ARGS=-n` into `DIR/5-console.png`, and quits. It runs only the read-only check modes and that dry run, which changes nothing. It puts the app's defaults domain back as it found it: SwiftUI writes the window's frame there as the window opens, and `snapshot-prefs` exports every `io.github.sevmorris.*` domain.

No test runs a real mrk script, touches real defaults or asks GitHub. The scripts are stubs in a temporary folder, the console's tests run zsh and make on a pseudo-terminal against a stub Makefile there, the app's settings and the update check's dates go through `UserDefaults.app`, a scratch suite under tests, named by a path in the temporary folder, and the update tests answer for GitHub themselves.

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
