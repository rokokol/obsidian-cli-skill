#!/usr/bin/env bash
# The offline half of the gate: obsi.sh driven against a fake CLI, so the shell half is
# checked on a runner with no Obsidian. Then — on copies with one defect planted each — it
# requires this same file to go red for that defect's own reason, because a check nobody has
# watched fail is a decoration.
#
#   check-obsi.sh [DIR]
#
# What it can and cannot answer. The graph and find queries are JavaScript executed inside
# the app, and no stub can run them, so their logic is NOT covered here — it carries its
# measurements in references/obsi.md instead. What is covered is everything the shell owns:
# reaching the client, turning a dishonest exit status into an honest one, closing stdin,
# passing arguments through unchanged, merging and ranking two result sets, and bounding
# output without losing the notice that says it was bounded.
#
# Exit 1 with `check-obsi: <what>` on the first finding, 2 on a usage error.
set -uo pipefail

self=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")
root="${1:-.}"
[[ -d "$root" ]] || {
  echo "check-obsi: $root is not a directory" >&2
  exit 2
}
root=$(cd -- "$root" && pwd)

obsi="$root/obsi.sh"
stub="$root/tests/stub-cli.sh"
[[ -x "$obsi" ]] || {
  echo "check-obsi: $obsi is missing or not executable" >&2
  exit 2
}
[[ -x "$stub" ]] || {
  echo "check-obsi: $stub is missing or not executable" >&2
  exit 2
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "check-obsi: $1" >&2
  exit 1
}

checks=0

# run -> the wrapper's stdout and stderr in $out, its own status in $status. No pipe stands
# between the command and its verdict, because the status would then belong to the pipe
out=""
status=0
run() {
  out=$("$OBSI_UNDER_TEST" "$@" 2>&1)
  status=$?
  return 0
}

want_status() { # want_status EXPECTED WHAT
  ((status == $1)) ||
    fail "$2: expected exit $1, got $status — output was: $out"
}

want_out() { # want_out SUBSTRING WHAT
  case "$out" in
    *"$1"*) ;;
    *) fail "$2: expected output to contain '$1', got: $out" ;;
  esac
}

want_not_out() { # want_not_out SUBSTRING WHAT
  case "$out" in
    *"$1"*) fail "$2: output should not contain '$1', got: $out" ;;
  esac
}

OBSI_UNDER_TEST="${OBSI_UNDER_TEST:-$obsi}"
export OBSIDIAN_CLI="$stub"

# A developer's machine has the real client on PATH and an app behind it; a runner has
# neither. Shadowing both names with binaries that answer nothing makes the two identical,
# and it is what gives the discovery checks below anything to discover
mkdir -p "$work/shadow"
for name in obsidian-cli obsidian; do
  printf '#!/bin/sh\nexit 0\n' >"$work/shadow/$name"
  chmod +x "$work/shadow/$name"
done
PATH="$work/shadow:$PATH"
export PATH

# ---- reaching the client ----------------------------------------------------------------

unset STUB_NO_APP STUB_ERROR STUB_META STUB_SEARCH STUB_ALLOWED STUB_JS_ERROR STUB_LOG || true
export STUB_LOG="$work/calls.log"
: >"$STUB_LOG"

run version
want_status 0 "a passed-through command"
want_out "1.13.7" "a passed-through command"
checks=$((checks + 1))

# A binary that answers nothing is not the client, whatever it is called
printf '#!/bin/sh\nexit 0\n' >"$work/mute"
chmod +x "$work/mute"
OBSIDIAN_CLI="$work/mute" run version
want_status 1 "a binary that answers no version"
want_out "no Obsidian CLI answered a version" "a binary that answers no version"
export OBSIDIAN_CLI="$stub"
checks=$((checks + 1))

# With no reachable app the CLI exits 1 — the one case where its own status is honest. The
# wrapper must say which of the two problems it is: telling someone to install a client they
# already have sends them the wrong way, and this check exists because it did exactly that
# shellcheck disable=SC2162 # `read` here is the CLI's command name, not the shell builtin
STUB_NO_APP=1 run read path=x.md
want_status 1 "no running app"
want_out "Obsidian is not running" "no running app"
want_not_out "Install one" "no running app"
checks=$((checks + 1))

# ---- the dishonest exit status ----------------------------------------------------------

# An application error prints `Error: ` on stdout and exits 0. The wrapper exists to make
# that a real failure, and the message must not keep the prefix twice over
# shellcheck disable=SC2162,SC2209 # both `read`s name the CLI's command, not the builtin
STUB_ERROR=read run read path="nope.md"
want_status 1 "an application error at exit 0"
want_out "obsi: File \"nope.md\" not found." "an application error at exit 0"
checks=$((checks + 1))

# The same, raised by the JavaScript rather than by the CLI: it arrives as `=> Error: …`,
# which the CLI itself calls a successful call
STUB_JS_ERROR=1 run find anything
want_status 1 "an error raised inside eval"
want_out "obsi: nope.md is not a note in the graph" "an error raised inside eval"
checks=$((checks + 1))

# ---- stdin ------------------------------------------------------------------------------

# The client reads stdin, so a call inside `while read` eats the loop's list unless stdin is
# closed on it. Three lines in, three iterations out
lines=$(printf 'one\ntwo\nthree\n' | {
  n=0
  while IFS= read -r _; do
    "$OBSI_UNDER_TEST" version >/dev/null 2>&1 || true
    n=$((n + 1))
  done
  printf '%s\n' "$n"
})
[[ "$lines" == "3" ]] ||
  fail "a call inside a read loop: the loop ran $lines time(s) instead of 3 — stdin was eaten"
checks=$((checks + 1))

# ---- arguments reach the CLI unchanged ---------------------------------------------------

: >"$STUB_LOG"
run --vault "Obsidian Sandbox" backlinks path="a, b/note.md" counts
want_status 0 "a vault name containing a space"
# One argv line, and the vault must be one field rather than two
grep -q "^vault=Obsidian Sandbox	backlinks	" "$STUB_LOG" ||
  fail "a vault name containing a space arrived split: $(cat "$STUB_LOG")"
grep -q "path=a, b/note.md" "$STUB_LOG" ||
  fail "a path containing a comma did not arrive intact: $(cat "$STUB_LOG")"
checks=$((checks + 1))

# ---- find: merging, ranking, bounding ----------------------------------------------------

# Two sources: the index answers with score, reasons, path and detail; `search` answers with
# bare paths. A note in both must outrank one in either
export STUB_META="9	alias	Networks/Address types.md	unicast
6	name	Networks/Unicast primer.md	Unicast primer"
export STUB_SEARCH="Networks/Address types.md
Notes/Mentions it once.md"

run find unicast
want_status 0 "find merging two sources"
first=$(printf '%s\n' "$out" | sed -n 1p)
[[ "$first" == "10	alias+body	Networks/Address types.md	unicast" ]] ||
  fail "find did not merge the two sources into one ranked row: got '$first'"
want_out "1	body	Notes/Mentions it once.md" "find merging two sources"
checks=$((checks + 1))

# What was cut has to be said out loud, and saying it must not cost the exit status: `head`
# would take SIGPIPE here and kill the script under pipefail before the notice printed
run find unicast --limit 1
want_status 0 "find bounded by --limit"
want_out "2 more matches" "find bounded by --limit"
checks=$((checks + 1))

run find unicast --limit 99
want_status 0 "find within its limit"
want_not_out "more matches" "find within its limit"
checks=$((checks + 1))

# The same bounding, over enough rows to fill a pipe buffer. On three rows `head` and `awk`
# behave identically — everything fits, the writer finishes, nothing takes SIGPIPE — so a
# small case cannot tell them apart, and the regression this guards against only appears
# once the writer is still writing when the reader stops
awk 'BEGIN { for (i = 1; i <= 4000; i++)
  printf "4\ttag\tNotes/A rather long path standing in for a real one, number %d.md\t#common\n", i }' \
  >"$work/big-meta.txt"
export STUB_META_FILE="$work/big-meta.txt"
export STUB_META=""
export STUB_SEARCH="No matches found."
run find common --limit 2
want_status 0 "find bounded over a payload larger than a pipe buffer"
want_out "3998 more matches" "find bounded over a payload larger than a pipe buffer"
checks=$((checks + 1))
unset STUB_META_FILE

# An empty result is a sentence, the way every listing in the CLI answers one. Empty output
# and a failure look the same to a caller
export STUB_META=""
export STUB_SEARCH="No matches found."
run find nothing
want_status 0 "find with no matches"
want_out "No matches found." "find with no matches"
checks=$((checks + 1))

# --prop must reach both halves. `search` knows nothing about the filter, so without the
# second query its rows would arrive unfiltered
export STUB_META="4	prop	Kept/One.md	status=draft"
export STUB_SEARCH="Kept/One.md
Dropped/Two.md"
export STUB_ALLOWED="Kept/One.md"
run find draft --prop status=draft
want_status 0 "--prop filtering both halves"
want_not_out "Dropped/Two.md" "--prop filtering both halves"
want_out "Kept/One.md" "--prop filtering both halves"
checks=$((checks + 1))
unset STUB_ALLOWED

# ---- arguments the wrapper rejects --------------------------------------------------------

run find x --limit abc
want_status 1 "a non-numeric --limit"
want_out "positive number" "a non-numeric --limit"
checks=$((checks + 1))

run find x --nonsense
want_status 1 "an unknown find option"
checks=$((checks + 1))

run graph nonsense
want_status 1 "an unknown graph query"
want_out "unknown graph query" "an unknown graph query"
checks=$((checks + 1))

run find
want_status 1 "find with nothing to look for"
checks=$((checks + 1))

# ---- the graph never arrives whole --------------------------------------------------------

run graph dump "$work/graph.json"
want_status 0 "graph dump"
want_out "$work/graph.json" "graph dump"
# The point of the command: the graph goes to the file, and only its size to the terminal
want_not_out "resolvedLinks" "graph dump"
want_not_out '{"a.md"' "graph dump"
grep -q '"a.md"' "$work/graph.json" ||
  fail "graph dump wrote no graph to its file: $(cat "$work/graph.json")"
checks=$((checks + 1))

# ---- every check above is able to fail -----------------------------------------------------
# A copy of obsi.sh with one defect planted must send this same file red. Each defect is one
# that was actually hit while writing the wrapper, so the suite is pinned to real failures
# rather than to imagined ones.

if [[ -n "${CHECK_OBSI_NESTED:-}" ]]; then
  echo "check-obsi: $checks checks passed"
  exit 0
fi

planted=0

# The plant expressions below are sed scripts. Where one carries `$limit` or `${2:?…}` it is
# the wrapper's own text being matched, so it must stay literal — hence the disables

plant() { # plant NAME SED-EXPR -> a copy of obsi.sh with one edit applied
  local name="$1" expr="$2"
  local copy="$work/$name.sh"
  sed "$expr" "$obsi" >"$copy" 2>"$work/$name.sed-err" ||
    fail "planting '$name' failed: $(cat "$work/$name.sed-err")"
  # sed can fail after writing, and an expression that silently produced nothing would leave
  # a copy that fails every check — which reads exactly like a defect the suite caught
  [[ ! -s "$work/$name.sed-err" ]] ||
    fail "planting '$name' printed an error: $(cat "$work/$name.sed-err")"
  chmod +x "$copy"
  cmp -s "$copy" "$obsi" && fail "planting '$name' changed nothing — the pattern has drifted"
  bash -n "$copy" 2>/dev/null ||
    fail "planting '$name' produced a script that does not parse — that is a broken plant, not a defect"
  printf '%s\n' "$copy"
}

# A copy has to go red *for its own reason*. Without naming the finding, a plant caught by
# some unrelated check would still count, and the check it was meant to prove would stay
# untested while the tally claimed otherwise
expect_red() { # expect_red COPY WHAT FRAGMENT
  local copy="$1" what="$2" fragment="$3" nested_out nested_status
  nested_out=$(CHECK_OBSI_NESTED=1 OBSI_UNDER_TEST="$copy" "$self" "$root" 2>&1)
  nested_status=$?
  ((nested_status != 0)) ||
    fail "a copy with $what passed — nothing here would notice that defect"
  case "$nested_out" in
    *"$fragment"*) ;;
    *) fail "a copy with $what was caught by the wrong check — wanted '$fragment', got: $nested_out" ;;
  esac
  planted=$((planted + 1))
}

# The wrapper must still pass as itself, or the copies prove nothing
nested_ok=$(CHECK_OBSI_NESTED=1 OBSI_UNDER_TEST="$obsi" "$self" "$root" 2>&1) ||
  fail "the unmodified wrapper failed its own checks: $nested_ok"

expect_red "$(plant no-stdin-guard 's| </dev/null 2>&1|  2>\&1|')" \
  "stdin left open on every call" "stdin was eaten"

# shellcheck disable=SC2016
expect_red "$(plant no-error-check '/^  case "\$out" in$/,/^  esac$/s|"Error: "\*) die.*|"Error: "*) : ;;|')" \
  "the Error: prefix no longer turned into a failure" "an application error at exit 0"

# shellcheck disable=SC2016
expect_red "$(plant head-not-awk 's|awk -v n="\$limit" .NR <= n.|head -n "$limit"|')" \
  "the truncation notice bounded with head, which dies of SIGPIPE under pipefail" \
  "larger than a pipe buffer"

# shellcheck disable=SC2016
expect_red "$(plant unquoted-vault 's|prefix=("vault=\${2:?--vault needs a name}")|prefix=(vault= "${2:?--vault needs a name}")|')" \
  "a vault name split into two arguments" "arrived split"

expect_red "$(plant no-empty-sentence 's|echo "No matches found."|echo ""|')" \
  "an empty result printed as empty output rather than as a sentence" "find with no matches"

expect_red "$(plant no-prop-filter '/grep -Fxf/s/.*/      :/')" \
  "--prop applied to the index half only, leaving the body half unfiltered" \
  "--prop filtering both halves"

echo "check-obsi: $checks checks passed, $planted planted defects caught"
