# Fixtures

Real output of mrk's `--check` modes on the owner's Mac, captured on 2026-10-22, so the parsers are tested against what the scripts print and not only against lines written by hand.

- `mrk-122/` — sevmorris/mrk#122 (branch `claude/charming-shamir-b646de`, commit `1e3f979`), the first mrk with one line contract for the five `--check` modes. Each `<script>--<flag>….out` is that command's stdout. `dock.txt`, `defaults.tsv`, `login-items.txt` and `app-prefs.tsv` are the `config/` files it read.
  - `dock-setup--check.out` has the fifth field on every line, and an `unlisted` line for `/Applications/Signal.app`, which is in the Dock and not in `dock.txt`.
  - `defaults.sh--check--with-trackpad.out` has no `nodomain` line: Mail's and TextEdit's domains exist on this Mac.
  - `sync-login-items--check.out` is empty: the login items match the list.
- `mrk-before-122/dock-setup--check.out` — `dock-setup --check` from mrk `8760cc7`, before #122: four fields, with the same `dock.txt`. Gearbox must still read it.

Capture them again with the scripts themselves; never edit one by hand.
