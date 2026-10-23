# Changelog

All notable changes to Gearbox are documented here. Every released version has a matching `v*` git tag. `release.sh` keeps the five most recent GitHub release pages, so an older version is reachable by its tag after its page is pruned.

Write a version's entry before releasing it, and put the same prose in `release-notes/v<version>.md`: `release.sh` publishes that file as the release's notes, and stops before building anything when it is absent.

## [0.5] — 2026-10-23

Gearbox says when macOS keeps a key from it, and opens the setting that lets it read the key.

**Added**
- **Keys Gearbox cannot read show as no access.** Mail keeps its settings where macOS lets an app read them only with Full Disk Access, and TextEdit and Passwords keep theirs where an app also needs permission to get the data of other apps. Without it, mrk's `defaults.sh --check` now reports their keys as `noaccess` ([sevmorris/mrk#131](https://github.com/sevmorris/mrk/pull/131)), and the macOS Defaults pane shows each with a lock and a "no access" badge, its switch greyed out, and "not known" for its value. "Not set" includes them, and the subtitle counts them.
- **Open Full Disk Access…**, in a banner over the list and in the detail of such a key, opens System Settings → Privacy & Security → Full Disk Access. macOS has no prompt for this permission, so turn Gearbox on there, and let macOS quit and reopen it.

**Fixed**
- Without Full Disk Access, Mail's key showed as waiting, though it was set. Without permission to get the data of other apps, TextEdit's showed the same, and a key's switch or `make defaults` from the console could write Passwords' keys to a file that Passwords does not read. With mrk#131 they are reported as no access, passed over by `make defaults`, and refused by the switch.

**Requirements**
- A Mac with Apple silicon.
- An mrk with [sevmorris/mrk#131](https://github.com/sevmorris/mrk/pull/131). With an older mrk, Gearbox works as 0.4 does.

## [0.4] — 2026-10-23

Each macOS default has a switch, so a key mrk sets can be turned off, and on again.

**Added**
- **A switch for each key in the macOS Defaults pane.** Off means `config/defaults-skip.tsv` lists the key, so `make defaults` leaves it as it is, and the key goes back to the value it had before mrk wrote it. On takes it out of the list and writes mrk's value. Gearbox runs `defaults.sh --skip` and `--revert`, or `--unskip` and `--key`, and reads the keys again with the list still in place. When a key changed, `defaults.sh` restarts Finder, the Dock and the menu bar. A setting that mrk writes to two domains, as the trackpad keys are, turns off and on in both.
- **Apply This Key**, in the detail of a key that differs or is absent, writes mrk's value of that key alone, with `defaults.sh --key`.
- **An Off filter**, beside All keys and Not set, shows the keys that are off. Not set leaves them out, and the subtitle counts them.

**Note**
- The switch changes `config/defaults-skip.tsv` in the mrk checkout. Gearbox does not commit it: `mrk-push` or `pushall` does, so the list moves to your next Mac with the rest of mrk.

**Requirements**
- A Mac with Apple silicon.
- An mrk with [sevmorris/mrk#130](https://github.com/sevmorris/mrk/pull/130), which adds the skip list and the options of one key. With an older mrk, the pane shows the keys as before, says to run `make pull`, and the switches are greyed out.

## [0.3] — 2026-10-22

Gearbox runs mrk's commands in a console of its own, instead of in Terminal.

**Changed**
- **The commands that change the Mac run in Gearbox's console**, a sheet over the window with a phosphor screen like Magic Backup Machine's, instead of in a Terminal window opened through a `.command` file. **Snapshot…**, **Apply All…** and **Apply…** run `make snapshot-prefs`, `make defaults` (or `make trackpad`) and `make dock` there, as the file ran them: under zsh in the checkout, with the login shell's environment and `MRK_ROOT`.
- **What a command asks works as it did in Terminal.** It runs on a pseudo-terminal of its own, so snapshot-prefs's secret scan stops and asks before it commits: type the answer, and Return sends it. ⌃C or ⌘. stops the command, and Stop sends ⌃C, then SIGTERM, then SIGKILL.
- **The pane reads mrk again when the command exits**, so there is no Refresh to press afterwards. The console shows how the command exited, and Done closes it.
- While the console is up, Gearbox's window does not close and Gearbox does not quit, so nothing hangs up a command half way.

**Added**
- The screen is Phosphor Green, Phosphor Amber or Plain, from the display button over it. Gearbox keeps the choice in its own defaults domain. A phosphor shows a program's colours in its own, with bold brighter and dim fainter; Plain shows the colours.
- `--snapshot` draws the console too, running `make dock ARGS=-n`, the dry run, which changes nothing.

**Note**
- macOS now holds Gearbox, not Terminal, responsible for what these commands do. If macOS asks whether Gearbox may reach another app's data, or `make defaults` cannot write a key in a protected domain, give Gearbox the access in System Settings → Privacy & Security.

**Requirements**
- A Mac with Apple silicon.
- An mrk from 2026-10-22 on, as for 0.2. The console runs the same `make` targets the Terminal window ran.

## [0.2] — 2026-10-22

Gearbox reads mrk's `--check` modes by the line contract of [sevmorris/mrk#122](https://github.com/sevmorris/mrk/pull/122), and still reads an mrk from before it.

**Added**
- **The Dock pane shows what is in the Dock and not in the list**, in a section of its own. `make dock` deletes these items from the Dock. **Add to the List** puts one in `config/dock.txt`, so `make dock` keeps it. An item of the list that is not in the Dock yet says so. Both come from `dock-setup --check`'s fifth field and `unlisted` lines, which arrive with mrk#122.
- **The Defaults pane shows a key that waits for its app.** A key that `config/defaults.tsv` writes only once its app has made its preferences, on a Mac where the app has not, is "waiting", not "absent": `make defaults` passes it over. mrk#122's `defaults.sh --check` reports these as `nodomain`; before it, they dropped out of the pane.

**Fixed**
- **A pane no longer reads "nothing to do" when it could not read mrk's output.** When a check prints lines and Gearbox can read none of them, the pane says that this Gearbox is older than mrk's output, and to check for updates.
- **Gearbox takes a line with more fields than it knows**, as mrk's contract allows a later version to add them. Gearbox 0.1 needed an exact count, so its Dock pane showed no state against mrk#122.
- **A name or key with a tab, a newline or a backslash** reads as the script wrote it in the Login Items and App Preferences panes, whose escapes Gearbox now undoes. A login item named with a backslash goes back to `sync-login-items --add` as the script listed it.
- A carriage return at the end of a field no longer joins two lines.

**Requirements**
- A Mac with Apple silicon.
- An mrk from 2026-10-22 on, as for 0.1. Gearbox 0.2 reads mrk both before and after mrk#122, so install it before `make pull` brings mrk#122 in.

## [0.1] — 2026-10-22

The first release.

**Added**
- **A Settings window over mrk.** Gearbox shows four of mrk's lists, one pane each: App Preferences, macOS Defaults, Login Items and the Dock. It runs mrk's own scripts through their check modes and decision options, and does none of their work itself, so each pane shows what the script would do.
- **App Preferences** shows the changes `snapshot-prefs --check` finds, grouped by the apps of `config/app-prefs.tsv`. **Snapshot…** runs `make snapshot-prefs` in a terminal, where its secret scan can stop and ask.
- **macOS Defaults** shows each key `defaults.sh --check` reads, with its section from `config/defaults.tsv` and its description from `docs/defaults/descriptions.tsv`. You can show only the keys that are not set, search the keys, and include the trackpad keys. **Apply All…** runs `make defaults`, or `make trackpad`, in a terminal, after a confirmation that names the restart of Finder, the Dock and SystemUIServer.
- **Login Items** compares `config/login-items.txt` with this Mac's login items through `sync-login-items --check`. **Add**, **Ignore** and **Remove** run `sync-login-items --add`, `--ignore` and `--remove`. The pane needs permission to control System Events. macOS asks once; if access is refused, the pane says where to give it.
- **Dock** edits `config/dock.txt`, the list `dock-setup` reads. Drag an app to move it, or add or remove an app or a folder. Each change writes the file, and `dock-setup --check` reads it again. If the file changed on disk after Gearbox read it, Gearbox reads it again and does not write over the change. **Apply…** runs `make dock` in a terminal, after a confirmation.
- **Gearbox never commits.** It changes files in the mrk checkout. Committing stays with `mrk-push` and `pushall`, and Dipstick's Unrecorded panel shows what is waiting.
- **Check for Updates…** in the Gearbox menu asks GitHub for a newer Gearbox. Gearbox also asks without being asked, at launch and when it comes to the front, at most once an hour, and tells you only when a newer version is out. The sidebar then names that version. A version that needs a newer macOS than the Mac has is not offered.

**Requirements**
- macOS 15 or later, on Apple silicon.
- An mrk from 2026-10-22 on, which has `docs/defaults/descriptions.tsv` and `dock-setup --check` ([sevmorris/mrk#117](https://github.com/sevmorris/mrk/pull/117)). With an older mrk, the Defaults pane shows the keys without their descriptions, and the Dock pane says to run `make pull`.
