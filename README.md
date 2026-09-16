## Agent Utilities

Miscellaneous tools, tips, tricks to makes working with agents a bit easier.

## The Goods

### herdr-recycle-machines

herdr's remote machines is super handy, but my logins expire and then everything is broken. The best way I can find it to cycle enabled off/on. This will do it for you.

Usage:
```bash
  herdr-recycle-machines [options] [id-or-label ...]

Options:
  -l, --label NAME  Cycle only the machine with this label. Repeatable, and
                    matches the label column only, so a label that happens to
                    look like an id is never mistaken for one.
  -n, --dry-run     Print what would happen and change nothing.
  -d, --delay SECS  Pause between disable and enable (default 2).
  -a, --all         Also cycle machines that are currently disabled.
  -q, --quiet       Only print problems and the final summary.
  -h, --help        Show this help.
```
With no --label and no positional arguments, every machine from `herdr machine list` is considered -- they are excluded if not in enabled state.
