# Changelog

All notable changes to Gearbox are documented here. Every released version has a matching `v*` git tag. `release.sh` keeps the five most recent GitHub release pages, so an older version is reachable by its tag after its page is pruned.

Write a version's entry before releasing it, and put the same prose in `release-notes/v<version>.md`: `release.sh` publishes that file as the release's notes, and stops before building anything when it is absent.

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
