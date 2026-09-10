#!/usr/bin/env bash
# A fake `obsidian-cli` for the offline tests. It answers from canned output instead of a
# running app, and — the part that matters — it records the argv of every call, so a test
# can assert what the wrapper actually sent rather than only what came back.
#
# It reproduces the CLI's two dishonest habits on purpose, because those are what obsi.sh
# exists to absorb: an application error prints `Error: …` on **stdout** and exits **0**,
# and the process **reads stdin**, so a call inside `while read` swallows the loop's list.
#
# Driven by the environment, so one stub serves every scenario:
#
#   STUB_LOG      file to append one tab-separated argv line per call
#   STUB_NO_APP   answer every call the way the CLI does with no app, and exit 1
#   STUB_META     what an `eval` carrying find's metadata query returns, before `=> `
#   STUB_META_FILE the same from a file, for a payload too big for the environment
#   STUB_ALLOWED  what an `eval` carrying the --prop allowlist query returns
#   STUB_SEARCH   what `search` returns
#   STUB_ERROR    a command name that must answer `Error: …` at exit 0
#   STUB_JS_ERROR make the metadata eval return `=> Error: …`, which the CLI calls success
set -uo pipefail

# The real client reads stdin. Draining it here is what makes the loop test meaningful:
# without `</dev/null` on the caller's side, this consumes the rest of the caller's list
if [ ! -t 0 ]; then cat >/dev/null 2>&1 || true; fi

if [ -n "${STUB_LOG:-}" ]; then
  printf '%s\n' "$(printf '%s\t' "$@")" >>"$STUB_LOG"
fi

if [ -n "${STUB_NO_APP:-}" ]; then
  echo "The CLI is unable to find Obsidian. Please make sure Obsidian is running and try again."
  exit 1
fi

# `vault=<name>` comes before the command word, and a vault name may contain spaces. Taking
# it off here is what lets a test assert that it arrived as ONE argument
vault=""
while [ $# -gt 0 ]; do
  case "$1" in
    vault=*)
      vault="${1#vault=}"
      shift
      ;;
    *) break ;;
  esac
done
: "$vault"

command_word="${1:-}"

if [ -n "${STUB_ERROR:-}" ] && [ "$command_word" = "$STUB_ERROR" ]; then
  echo "Error: File \"nope.md\" not found."
  exit 0
fi

case "$command_word" in
  version)
    echo "1.13.7 (installer 1.13.4)"
    ;;
  eval)
    code="${2#code=}"
    case "$code" in
      *"const markers"*)
        if [ -n "${STUB_JS_ERROR:-}" ]; then
          echo "=> Error: nope.md is not a note in the graph"
        elif [ -n "${STUB_META_FILE:-}" ]; then
          # A payload big enough to test bounding does not fit in the environment: it is
          # counted against ARG_MAX and inherited by every child, so it goes in a file
          printf '=> '
          cat "$STUB_META_FILE"
        else
          printf '=> %s\n' "${STUB_META:-}"
        fi
        ;;
      *"const filter"*) printf '=> %s\n' "${STUB_ALLOWED:-}" ;;
      *resolvedLinks*) echo '=> {"a.md":{"b.md":1}}' ;;
      *) echo "=> ok" ;;
    esac
    ;;
  search)
    printf '%s\n' "${STUB_SEARCH:-No matches found.}"
    ;;
  *)
    # Everything else echoes what it was given, so a pass-through test can see the argv
    printf 'passed-through:%s\n' "$(printf ' %s' "$@")"
    ;;
esac
