#!/usr/bin/env bash
# herdr-recycle-machines - disable then re-enable saved Herdr SSH machines to
# force them to reconnect.
#
# WHY: when a saved SSH machine loses its connection, Herdr 0.9.0 exposes no
# reconnect or refresh command. `herdr machine disable <id>` followed by
# `herdr machine enable <id>` is the narrowest available way to make one
# machine re-establish itself, because it touches only that machine's
# registration and leaves the local session, panes, and running agents alone.
# `herdr server stop` would also clear the problem, but it restarts everything
# and disturbs local work, so it is deliberately not what this does.
#
# SAFETY: by default this only cycles machines that are currently ENABLED. A
# machine you deliberately disabled has no connection to repair, and enabling
# it would silently change your setup rather than fix anything. Pass --all to
# include disabled machines, which leaves every machine enabled at the end.
#
# This script never calls `herdr machine remove` or `herdr machine rename`.
#
# A machine is only ever left disabled if its enable step fails. That is
# reported loudly, named explicitly, and makes the exit status non-zero, so a
# half-finished cycle is never mistaken for success.
#
# Usage:
#   herdr-recycle-machines [options] [id-or-label ...]
#
# Options:
#   -l, --label NAME  Cycle only the machine with this label. Repeatable, and
#                     matches the label column only, so a label that happens to
#                     look like an id is never mistaken for one.
#   -n, --dry-run     Print what would happen and change nothing.
#   -d, --delay SECS  Pause between disable and enable (default 2).
#   -a, --all         Also cycle machines that are currently disabled.
#   -q, --quiet       Only print problems and the final summary.
#   -h, --help        Show this help.
#
# With no --label and no positional arguments, every machine from
# `herdr machine list` is considered. A positional argument may be a machine's
# id or its label. Any name that matches nothing, or matches more than one
# machine, is an error rather than a silent no-op or a guess.
set -uo pipefail

PROG=${0##*/}

die() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 1
}

usage() {
  sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

DRY_RUN=0
DELAY=2
INCLUDE_DISABLED=0
QUIET=0
TARGETS=()

while [ $# -gt 0 ]; do
  case $1 in
  -n | --dry-run) DRY_RUN=1 ;;
  -a | --all) INCLUDE_DISABLED=1 ;;
  -q | --quiet) QUIET=1 ;;
  -d | --delay)
    [ $# -ge 2 ] || die "--delay needs a value"
    DELAY=$2
    shift
    ;;
  -l | --label)
    [ $# -ge 2 ] || die "--label needs a value"
    TARGETS+=("label	$2")
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  --)
    shift
    while [ $# -gt 0 ]; do
      TARGETS+=("any	$1")
      shift
    done
    break
    ;;
  -*) die "unknown option: $1 (try --help)" ;;
  *) TARGETS+=("any	$1") ;;
  esac
  shift
done

case $DELAY in
'' | *[!0-9.]*) die "--delay must be a non-negative number, got: $DELAY" ;;
esac

command -v herdr >/dev/null 2>&1 || die "herdr not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH (needed to parse herdr machine list --json)"

say() {
  [ "$QUIET" -eq 1 ] && return 0
  printf '%s\n' "$*"
}

# Read the machine inventory once, so the set being cycled cannot shift midway.
LISTING=$(herdr machine list --json 2>&1) || die "herdr machine list --json failed: $LISTING"
printf '%s' "$LISTING" | jq -e 'type == "array"' >/dev/null 2>&1 ||
  die "unexpected output from herdr machine list --json: $LISTING"

# id<TAB>label<TAB>enabled, one machine per line.
INVENTORY=$(printf '%s' "$LISTING" |
  jq -r '.[] | [.id, (.label // ""), (if .enabled then "enabled" else "disabled" end)] | @tsv')

[ -n "$INVENTORY" ] || {
  say "no saved machines; nothing to do"
  exit 0
}

# Resolve the requested targets against the inventory, by id first then label.
SELECTED=""
if [ ${#TARGETS[@]} -eq 0 ]; then
  SELECTED=$INVENTORY
else
  for target in "${TARGETS[@]}"; do
    mode=${target%%	*}
    want=${target#*	}
    if [ "$mode" = label ]; then
      match=$(printf '%s\n' "$INVENTORY" | awk -F'\t' -v w="$want" '$2 == w')
      [ -n "$match" ] || die "no machine has label '$want' (see: herdr machine list)"
    else
      match=$(printf '%s\n' "$INVENTORY" | awk -F'\t' -v w="$want" '$1 == w || $2 == w')
      [ -n "$match" ] || die "no machine matches '$want' (see: herdr machine list)"
    fi
    count=$(printf '%s\n' "$match" | grep -c .)
    [ "$count" -eq 1 ] || die "'$want' matches $count machines; use the id instead"
    SELECTED=${SELECTED:+$SELECTED$'\n'}$match
  done
  # Two names can resolve to the same machine; cycle it once, not twice.
  SELECTED=$(printf '%s\n' "$SELECTED" | awk 'NF && !seen[$0]++')
fi

cycled=0
skipped=0
failed=0
left_disabled=()

while IFS=$'\t' read -r id label state; do
  [ -n "$id" ] || continue
  name=${label:-$id}

  if [ "$state" = disabled ] && [ "$INCLUDE_DISABLED" -eq 0 ]; then
    say "skip  $name ($id): already disabled, nothing to reconnect (use --all to enable it)"
    skipped=$((skipped + 1))
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$state" = disabled ]; then
      say "would enable            $name ($id)"
    else
      say "would disable + enable  $name ($id)"
    fi
    cycled=$((cycled + 1))
    continue
  fi

  if [ "$state" = enabled ]; then
    if ! out=$(herdr machine disable "$id" 2>&1); then
      printf '%s: FAILED to disable %s (%s): %s\n' "$PROG" "$name" "$id" "$out" >&2
      failed=$((failed + 1))
      continue
    fi
    # Give the server a moment to tear the connection down before asking for it
    # back; enabling instantly can re-attach to the session being closed.
    sleep "$DELAY"
  fi

  if ! out=$(herdr machine enable "$id" 2>&1); then
    printf '%s: FAILED to enable %s (%s): %s\n' "$PROG" "$name" "$id" "$out" >&2
    printf '%s: %s IS LEFT DISABLED and needs: herdr machine enable %s\n' "$PROG" "$name" "$id" >&2
    left_disabled+=("$name ($id)")
    failed=$((failed + 1))
    continue
  fi

  say "cycled $name ($id)"
  cycled=$((cycled + 1))
done <<EOF
$SELECTED
EOF

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s: dry run: %d would be cycled, %d skipped\n' "$PROG" "$cycled" "$skipped"
  exit 0
fi

printf '%s: %d cycled, %d skipped, %d failed\n' "$PROG" "$cycled" "$skipped" "$failed"

if [ ${#left_disabled[@]} -gt 0 ]; then
  printf '%s: STILL DISABLED, fix these by hand:\n' "$PROG" >&2
  for m in "${left_disabled[@]}"; do
    printf '  %s\n' "$m" >&2
  done
fi

[ "$failed" -eq 0 ] || exit 1
