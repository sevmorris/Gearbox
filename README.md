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

## Build, test, look

```bash
./build.sh                 # build/Gearbox.app, signed ad hoc
swift test                 # the parsers, every command's arguments, the runner and the panes, against stub scripts
build/Gearbox.app/Contents/MacOS/Gearbox --snapshot /tmp/gearbox-shots
```

`--snapshot DIR` loads each pane in the app's own window, against the real checkout, draws each into `DIR/<n>-<pane>.png`, and quits. It runs only the read-only check modes. It puts the app's defaults domain back as it found it: SwiftUI writes the window's frame there as the window opens, and `snapshot-prefs` exports every `io.github.sevmorris.*` domain.

No test runs a real mrk script or touches real defaults. The scripts are stubs in a temporary folder, and the app's settings go through `UserDefaults.app`, a scratch suite under tests, named by a path in the temporary folder.

An ad hoc signature changes with every build, and macOS keys the Automation permission to it, so a rebuilt Gearbox asks again.

SwiftPM, macOS 15 or later, Apple silicon. Version 0.1, not released.

## License

MIT — Seven Morris
