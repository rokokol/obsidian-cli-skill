#!/usr/bin/env bash
# The offline half of the gate: obsi.sh driven against a fake CLI, so the shell half is
# checked on a runner with no Obsidian. Then — on copies with one defect planted each — it
# requires this same file to go red for that defect's own reason, because a check nobody has
# watched fail is a decoration.
#
#   check-obsi.sh [DIR]
#
# What it can and cannot answer. Everything the shell owns is covered against the stub:
# reaching the client, turning a dishonest exit status into an honest one, closing stdin,
# passing arguments through unchanged, merging and ranking two result sets, and bounding
# output without losing the notice that says it was bounded. The graph and find queries
# are JavaScript executed inside the app; the stub captures that code as the wrapper builds
# it and node runs it against tests/fake-app.js, so its logic is covered for the questions
# that fake vault asks. How it behaves against a real vault's index is still measured, not
# tested — see references/obsi.md. Needs node, from the flake's dev shell.
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
#
# A nix dev shell — where CI runs this — exports $out, which would export every captured
# output to every child and decide one check's result from the calling shell. It is taken
# off here, and the one check about an exported $out sets it itself
export -n out
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

# Every variable the stub reads, taken from the stub itself. The hand-kept list this replaced
# had already missed STUB_META_FILE, so a value inherited from the calling shell would have
# reached the find checks and quietly changed what they tested
# shellcheck disable=SC2046 # splitting the list into words is the point
unset $(grep -o 'STUB_[A-Z_]*' "$stub" | sort -u) || true
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

# Once a client has answered that the app is down, nothing further is probed: the next name
# in line may be `obsidian`, which on a packaged install is the GUI launcher and opens a
# window instead of answering. The shadowed launcher records whether it was ever run
printf '#!/bin/sh\ntouch "%s"\nexit 0\n' "$work/launcher-was-run" >"$work/shadow/obsidian"
chmod +x "$work/shadow/obsidian"
STUB_NO_APP=1 run version
want_status 1 "a client reporting the app down"
if [[ -e "$work/launcher-was-run" ]]; then
  fail "after a client reported the app down, the wrapper went on to run \`obsidian\` — the GUI launcher on packaged installs"
fi
checks=$((checks + 1))

# $OBSIDIAN_CLI names the client the caller chose, so it is asked before either name on PATH,
# even when another client there answers a version too
cat >"$work/shadow/obsidian-cli" <<'EOF'
#!/bin/sh
echo "1.0.0 (a client the caller did not choose)"
EOF
run version
want_status 0 "\$OBSIDIAN_CLI beside another client"
want_out "1.13.7" "\$OBSIDIAN_CLI beside another client"
checks=$((checks + 1))

# Without it, the client is asked before \`obsidian\`: asking the GUI launcher for its version
# opens a window on a packaged install instead of answering
cat >"$work/shadow/obsidian-cli" <<EOF
#!/bin/sh
exec "$stub" "\$@"
EOF
rm -f "$work/launcher-was-run"
OBSIDIAN_CLI="" run version
want_status 0 "the client before the launcher"
if [[ -e "$work/launcher-was-run" ]]; then
  fail "with no \$OBSIDIAN_CLI the wrapper asked \`obsidian\` before \`obsidian-cli\` — on a packaged install that opens a window"
fi
printf '#!/bin/sh\nexit 0\n' >"$work/shadow/obsidian-cli"
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

# An error the CLI itself reports on the query — at exit 0, like any other — has to end the
# query too. It is raised in cli, inside js, which runs inside its caller's $(…) where bash
# clears set -e, so js must pass the failure on rather than answer empty
STUB_ERROR="eval" run find x --name
want_status 1 "a CLI error on find's query"
want_out 'obsi: File "nope.md" not found.' "a CLI error on find's query"
want_not_out "No matches found." "a CLI error on find's query"
checks=$((checks + 1))

# A client that fails outright — a crash, a signal — exits non-zero, and whatever it printed
# before that is not an answer. Its own message, on stderr, has to reach the caller
STUB_CRASH=backlinks run backlinks path=x.md
want_status 1 "a client exiting non-zero"
want_out "the client crashed" "a client exiting non-zero"
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
export STUB_META="9	alias	Sea/Coastlines.md	coastline
6	name	Sea/Coastline primer.md	Coastline primer"
export STUB_SEARCH="Sea/Coastlines.md
Notes/Mentions it once.md"

run find coastline
want_status 0 "find merging two sources"
first=$(printf '%s\n' "$out" | sed -n 1p)
[[ "$first" == "10	alias+text	Sea/Coastlines.md	coastline" ]] ||
  fail "find did not merge the two sources into one ranked row: got '$first'"
want_out "1	text	Notes/Mentions it once.md" "find merging two sources"
checks=$((checks + 1))

# What was cut has to be said out loud, and saying it must not cost the exit status: `head`
# would take SIGPIPE here and kill the script under pipefail before the notice printed
run find coastline --limit 1
want_status 0 "find bounded by --limit"
want_out "2 more matches" "find bounded by --limit"
# One row and the notice, not every row and a notice claiming some were held back
rows=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
[[ "$rows" == 2 ]] ||
  fail "find bounded by --limit 1 printed $rows lines instead of one row and the notice: $out"
checks=$((checks + 1))

run find coastline --limit 99
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

# A nix dev shell exports $out, and bash keeps that export on a local of the same name. The
# 400 KB answer above, held in one, went into the environment of the next command the
# wrapper ran, exec refused it as "Argument list too long", and find said No matches found
out_env=$(env out=/nix/store/an-output-path "$OBSI_UNDER_TEST" find common --limit 2 2>&1) || true
case "$out_env" in
  *"3998 more matches"*) ;;
  *) fail "find under an exported \$out: $out_env" ;;
esac
checks=$((checks + 1))
unset STUB_META_FILE

# An empty result is a sentence, the way every listing in the CLI answers one. Empty output
# and a failure look the same to a caller
export STUB_META=""
export STUB_SEARCH="No matches found."
run find nothing
want_status 0 "find with no matches"
[[ "$out" == "No matches found." ]] ||
  fail "find with no matches: expected the sentence No matches found. and nothing else, got: $out"
checks=$((checks + 1))

# --prop must reach both halves. `search` knows nothing about the filter and the index query
# is not told it either, so the allowlist is applied to the rows of each: Dropped/Three.md
# comes from the index and Dropped/Two.md from the text, and neither may get through
export STUB_META="4	prop	Kept/One.md	status=draft
4	prop	Dropped/Three.md	status=done"
export STUB_SEARCH="Kept/One.md
Dropped/Two.md"
export STUB_ALLOWED="Kept/One.md"
run find draft --prop status=draft
want_status 0 "--prop filtering both halves"
want_not_out "Dropped/Two.md" "--prop filtering both halves"
want_not_out "Dropped/Three.md" "--prop filtering both halves"
want_out "Kept/One.md" "--prop filtering both halves"
checks=$((checks + 1))
unset STUB_ALLOWED

# A text search that hit its own cap makes the count of what was left out a floor, and the
# notice has to say so rather than state a number that is only a lower bound
export STUB_META=""
export STUB_SEARCH="N/one.md
N/two.md
N/three.md"
run find x --body --limit 1
want_status 0 "find with a capped text search"
want_out "at least 2 more" "find with a capped text search"
checks=$((checks + 1))

# The CLI's own `vault=NAME` spelling, before the command word, has to reach the wrapper's
# own commands as well; it used to go to the CLI as a vault selector followed by `find`
: >"$STUB_LOG"
export STUB_META="9	alias	A.md	x"
export STUB_SEARCH="No matches found."
run vault=Other find x
want_status 0 "vault= before a wrapper command"
grep -q '^vault=Other	eval	' "$STUB_LOG" ||
  fail "vault= before find did not reach the query as a vault selector: $(cat "$STUB_LOG")"
checks=$((checks + 1))

# --value narrows find to property values the way --name and the rest narrow to theirs: it is
# a marker, handed to the index query beside the others. The matching itself is JavaScript
# the stub cannot run, so what is checked here is what reaches that query
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
export STUB_CODE_LOG="$work/meta-code.js"
export STUB_META="4	prop	Kept/One.md	status=draft"
export STUB_SEARCH="No matches found."
run find draft --value
want_status 0 "find --value"
grep -qF "decode('$(b64 prop)')" "$STUB_CODE_LOG" ||
  fail "find --value did not reach the index query as its one marker"
checks=$((checks + 1))

run find draft --name --value
want_status 0 "find --name --value"
grep -qF "decode('$(b64 'name prop')')" "$STUB_CODE_LOG" ||
  fail "find --name --value did not reach the index query as both markers"
checks=$((checks + 1))

# With --prop NAME, --value looks at that property's values alone: `find draft --value
# --prop status` asks for draft in status, not in every property of the notes that have one
export STUB_ALLOWED="Kept/One.md"
run find draft --value --prop status=draft
want_status 0 "find --value --prop"
grep -qF "const scope = decode('$(b64 status)')" "$STUB_CODE_LOG" ||
  fail "find --value --prop status did not confine the value match to status"
checks=$((checks + 1))

# Without --value the filter confines nothing: a plain find still matches every property
run find draft --prop status
want_status 0 "find --prop without --value"
grep -qF "const scope = decode('')" "$STUB_CODE_LOG" ||
  fail "find --prop without --value confined the value match to the filtered property"
checks=$((checks + 1))
unset STUB_ALLOWED STUB_CODE_LOG

# ---- arguments the wrapper rejects --------------------------------------------------------
# Asked wrongly is exit 2, apart from 1, which is an answer from the CLI or the vault: a caller
# branching on the status has to tell a typo from a note that is not there

run find x --limit abc
want_status 2 "a non-numeric --limit"
want_out "positive number" "a non-numeric --limit"
checks=$((checks + 1))

run find x --nonsense
want_status 2 "an unknown find option"
checks=$((checks + 1))

run graph nonsense
want_status 2 "an unknown graph query"
want_out "unknown graph query" "an unknown graph query"
checks=$((checks + 1))

# The JavaScript behind `related` cannot run against a stub, but the argument it refuses to
# work without can: without a note it would otherwise send `undefined` into the app
run graph related
want_status 2 "graph related with no note"
want_out "needs a note path" "graph related with no note"
checks=$((checks + 1))

# An option it does not know must be refused, not taken as a row count. Swallowing an
# unknown argument is the CLI's own habit and the reason this wrapper exists
run graph related "a.md" --no-such-flag 3
want_status 2 "an unknown option to graph related"
want_out "unknown option" "an unknown option to graph related"
checks=$((checks + 1))

# A count is spliced into JavaScript run inside the live app, so anything that is not a plain
# number has to be refused before any of it is built. `app` is a name in that scope and was
# silently coerced to zero rows; the crafted value below would have run as code
: >"$STUB_LOG"
run graph hubs app
want_status 2 "a row count that names something in the app's scope"
want_out "positive number" "a row count that names something in the app's scope"
checks=$((checks + 1))

: >"$STUB_LOG"
run graph hubs '5, (function(){throw new Error("injected")})()'
want_status 2 "a hostile row count"
# Refusing is not enough on its own: nothing may have been sent to the app first
if grep -q 'code=' "$STUB_LOG"; then
  fail "a hostile row count: JavaScript reached the app before the value was refused"
fi
checks=$((checks + 1))

# Every count goes through that validator, each at its own call site, and a leading zero or
# a zero is refused with the rest: 010 is octal 8 in the app's sloppy-mode scope, and 0
# answers zero rows as though that were what was asked
for args in "graph hubs 010" "graph hubs 0" "graph ends app" "graph unresolved app" \
  "graph components 3 app" "find x --limit 010"; do
  read -ra words <<<"$args"
  : >"$STUB_LOG"
  run "${words[@]}"
  want_status 2 "the count in '$args'"
  want_out "positive number" "the count in '$args'"
  if grep -q 'code=' "$STUB_LOG"; then
    fail "the count in '$args': JavaScript reached the app before the value was refused"
  fi
  checks=$((checks + 1))
done

# The row count of `related` goes through the same validator; an independent review found
# that removing its check left every test green
run graph related a.md not-a-number
want_status 2 "a non-numeric row count to graph related"
want_out "positive number" "a non-numeric row count to graph related"
checks=$((checks + 1))

# The vault belongs before the command word. After it the CLI drops it in silence and
# answers for whichever vault is open, so the wrapper has to refuse it instead
run backlinks path=note.md total --vault "Other Vault"
want_status 2 "--vault after the command word"
want_out "before the command word" "--vault after the command word"
checks=$((checks + 1))

run backlinks path=note.md vault=Other
want_status 2 "vault= after the command word"
want_out "before the command word" "vault= after the command word"
checks=$((checks + 1))

# A missing value answers in the tool's own voice, not bash's `line N: 2: …`
run --vault
want_status 2 "--vault with no name"
want_out "obsi: --vault needs a name" "--vault with no name"
checks=$((checks + 1))

run find
want_status 2 "find with nothing to look for"
want_out "obsi: find needs something to look for" "find with nothing to look for"
checks=$((checks + 1))

for args in "find x --limit" "find x --prop" "graph related a.md --tag-max-notes"; do
  read -ra words <<<"$args"
  run "${words[@]}"
  want_status 2 "$args with no value"
  want_out "obsi: ${args##* } needs" "$args with no value"
  checks=$((checks + 1))
done

# A word more than a command takes is refused rather than dropped
run graph path Sea/A.md Sea/B.md Sea/C.md
want_status 2 "graph path with three notes"
want_out "needs two note paths" "graph path with three notes"
checks=$((checks + 1))

run graph dump "$work/one.json" "$work/two.json"
want_status 2 "graph dump with two files"
want_out "takes one file" "graph dump with two files"
checks=$((checks + 1))

# The rest of the graph queries refuse a word they do not take, the way path and dump do:
# taken in silence, the word was dropped and the query answered as though it had not been
# typed — the CLI's own habit, which this wrapper exists to stop
for args in "graph summary extra" "graph hubs 5 extra" "graph ends 5 extra" "graph unresolved 5 extra" \
  "graph components 3 3 extra" "graph related a.md 3 4"; do
  read -ra words <<<"$args"
  : >"$STUB_LOG"
  run "${words[@]}"
  want_status 2 "a word too many in '$args'"
  want_out "obsi: " "a word too many in '$args'"
  if grep -q 'code=' "$STUB_LOG"; then
    fail "a word too many in '$args': the query reached the app before the word was refused"
  fi
  checks=$((checks + 1))
done

# No command at all is a usage error: the help on stderr, and exit 2
run
want_status 2 "no command at all"
want_out "obsi.sh [--vault NAME] find QUERY" "no command at all"
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
# Written beside the target and moved over it, so nothing is left behind next to it
leftover=$(find "$work" -maxdepth 1 -name '.obsi-dump.*')
[[ -z "$leftover" ]] || fail "graph dump left a temp file beside its target: $leftover"
checks=$((checks + 1))

# A failed dump must leave the file as it was. The file used to be truncated before the
# query ran, so an app that was down turned an existing graph.json into an empty one
printf 'precious\n' >"$work/kept.json"
STUB_JS_ERROR=1 run graph dump "$work/kept.json"
want_status 1 "graph dump when the query fails"
[[ "$(cat "$work/kept.json")" == precious ]] ||
  fail "graph dump when the query fails: the existing file was clobbered — it now holds '$(cat "$work/kept.json")'"
checks=$((checks + 1))

# The same when the CLI refuses the query rather than the JavaScript: the refusal happens in
# js's own $(…), and an existing file must still be left as it was
printf 'precious\n' >"$work/kept-cli.json"
STUB_ERROR="eval" run graph dump "$work/kept-cli.json"
want_status 1 "graph dump when the CLI refuses the query"
[[ "$(cat "$work/kept-cli.json")" == precious ]] ||
  fail "graph dump when the CLI refuses the query: the file was emptied — it now holds '$(cat "$work/kept-cli.json")'"
checks=$((checks + 1))

# Whether the target can be written is asked before the query, so a dump that cannot land
# never costs the app a whole-graph query
: >"$STUB_LOG"
run graph dump "$work/no-such-dir/graph.json"
want_status 1 "graph dump into a missing folder"
want_out "cannot write to" "graph dump into a missing folder"
if grep -q 'code=' "$STUB_LOG"; then
  fail "graph dump into a missing folder: the graph was queried before the target was checked"
fi
checks=$((checks + 1))

# What the client prints on stderr is not part of its answer. Captured together with stdout,
# a warning from the app's runtime would land inside the JSON and make the dump unparseable
STUB_STDERR="Gtk-WARNING: noise from the app's runtime" run graph dump "$work/clean.json"
want_status 0 "graph dump with the client writing to stderr"
if grep -q 'Gtk-WARNING' "$work/clean.json"; then
  fail "graph dump with the client writing to stderr: the warning landed inside the JSON"
fi
checks=$((checks + 1))

# A graph query answers with rows or a sentence. An empty reply from the app — `graph ends`
# on a vault where no note qualified was one — printed a blank line at exit 0, which reads
# like an answer
STUB_EVAL="" run graph ends
want_status 1 "a graph query the app answered with nothing"
want_out "answered nothing" "a graph query the app answered with nothing"
checks=$((checks + 1))

# --tag-max-notes is spliced into the JavaScript as a literal too. `010` there is octal in
# the app's sloppy-mode scope and means 8, and `-1` is the wrapper's own sentinel for "the
# default", so a caller who typed it got the default without a word
for value in 010 -1; do
  : >"$STUB_LOG"
  run graph related a.md --tag-max-notes "$value"
  want_status 2 "--tag-max-notes $value"
  want_out "zero or a positive number" "--tag-max-notes $value"
  if grep -q 'code=' "$STUB_LOG"; then
    fail "--tag-max-notes $value: JavaScript reached the app before the value was refused"
  fi
  checks=$((checks + 1))
done
run graph related a.md --tag-max-notes 0
want_status 0 "--tag-max-notes 0, which turns the tag signal off"
checks=$((checks + 1))

# selftest is the wrapper's own command, not the CLI's: it must reach the app as a query and
# turn a reported difference into a failure, not pass through as an unknown CLI command
STUB_EVAL="tags agree with Obsidian's own count (3 tags)" run selftest
want_status 0 "selftest when the counts agree"
want_out "tags agree with Obsidian's own count" "selftest when the counts agree"
checks=$((checks + 1))

STUB_EVAL="Error: 1 tag count differs from Obsidian's own" run selftest
want_status 1 "selftest when a count differs"
want_out "differs from Obsidian's own" "selftest when a count differs"
checks=$((checks + 1))

# And it takes nothing: a word after it is refused rather than dropped
run selftest extra
want_status 2 "selftest with an argument"
want_out "takes no arguments" "selftest with an argument"
checks=$((checks + 1))

# ---- the JavaScript half, in node against a fake app --------------------------------------
# The stub saves the code the wrapper hands to eval, exactly as built; node runs it against
# the made-up vault in tests/fake-app.js. Taking the code from the wrapper rather than from
# a copy is what keeps this from drifting: a planted copy of obsi.sh is tested through the
# very same path

command -v node >/dev/null ||
  fail "node is missing — it is pinned in the flake's dev shell, so run this under nix develop"
fake_app="$root/tests/fake-app.js"
mkdir -p "$work/js"
export STUB_META="" STUB_SEARCH="No matches found."

answer_of() { # answer_of NAME ARGS... -> $out holds what the app would answer to find's query
  local name="$1"
  shift
  STUB_CODE_LOG="$work/js/$name.js" run "$@"
  out=$(node "$fake_app" "$work/js/$name.js" 2>&1) || fail "$name: node could not run the query: $out"
}

eval_of() { # eval_of NAME ARGS... -> $out holds what the app would answer to the call's last eval
  local name="$1"
  shift
  STUB_EVAL_LOG="$work/js/$name.js" run "$@"
  out=$(node "$fake_app" "$work/js/$name.js" 2>&1) || fail "$name: node could not run the query: $out"
}

want_answer() { # want_answer EXPECTED WHAT -> the whole answer, not a line of it
  [[ "$out" == "$1" ]] || fail "$2: expected exactly:"$'\n'"$1"$'\n'"got:"$'\n'"$out"
}

answer_of value find draft --value
want_out "4	prop	Sea/Other.md	note=draft" "find --value in node"
want_out "4	prop	Sea/Coastlines.md	status=draft" "find --value in node"
want_not_out "	name	" "find --value in node"
# Aliases and tags are read by their own markers, never a second time as property values
want_not_out "tags=" "find --value in node"
checks=$((checks + 1))

answer_of scoped find draft --value --prop status
want_out "4	prop	Sea/Coastlines.md	status=draft" "find --value --prop status in node"
want_not_out "note=draft" "find --value --prop status in node"
checks=$((checks + 1))

# Obsidian reads a string as ONE item and never splits it on commas: the alias is
# "coastline, shore", so "shore" is a partial match on it rather than an alias of its own
answer_of alias-string find shore --alias
want_out "5	alias	Sea/Coastlines.md	coastline, shore" "a comma string alias in node"
checks=$((checks + 1))

# A list item is taken whole, comma and all
answer_of alias-list find "smith, john" --alias
want_out "9	alias	Sea/Smith.md	Smith, John" "a list alias holding a comma in node"
checks=$((checks + 1))

# `tags: a, b` is one string holding a space, and Obsidian gives such a note no tags at all
answer_of tags-string find a --tag
want_not_out "Sea/Smith.md" "tags: a, b in node"
checks=$((checks + 1))

# Obsidian matches the key in any case, so `Tags:` and `Aliases:` count
answer_of mixed-tags find y --tag
want_out "4	tag	Sea/Tagged.md	#y" "a mixed-case key in node"
answer_of mixed-aliases find upper --alias
want_out "Sea/Tagged.md" "a mixed-case key in node"
checks=$((checks + 1))

# Naming no field means every field, property values among them
answer_of default find draft
want_out "4	prop	Sea/Other.md	note=draft" "a plain find in node"
checks=$((checks + 1))

# An exact name outranks a partial one, and a note matching in two fields scores for both:
# "coastline" is part of the name Coastlines and of the alias "coastline, shore"
answer_of name-exact find coastlines --name
want_answer "10	name	Sea/Coastlines.md	Coastlines" "an exact name in node"
answer_of name-alias find coastline --name --alias
want_answer "11	name+alias	Sea/Coastlines.md	Coastlines" "a name and an alias in node"
checks=$((checks + 1))

# A field scores once, at its best match: Template carries draft inline, as the frontmatter
# Draft and inside draft/idea, and that is one tag match, not three
answer_of best-per-field find draft --tag
want_answer "4	tag	Sea/Template.md	#draft" "one field scored once in node"
checks=$((checks + 1))

# --prop is asked of the app on its own, and its answer is the allowlist both halves are held
# to: a value names the notes holding it, a bare name every note that has the property, and a
# list property is matched item by item
eval_of prop-value find draft --prop status=draft
want_answer "Sea/Coastlines.md" "--prop status=draft in node"
eval_of prop-name find draft --prop status
want_answer "Sea/Coastlines.md
Sea/Other.md" "--prop status in node"
eval_of prop-list find draft --prop tags=Draft
want_answer "Sea/Template.md" "--prop on a list property in node"
checks=$((checks + 1))

# The graph queries against the fake vault's links: Smith links to Coastlines, to Tagged and
# to an image, Other links to Tagged and to a note that does not exist, and the rest link
# nowhere and are linked from nowhere
eval_of summary graph summary
want_answer "notes	7
links between notes	3
links to attachments	1
unresolved links	1
nothing links to them	5
they link nowhere	5
connected components	4
largest component	4" "graph summary in node"
checks=$((checks + 1))

eval_of hubs graph hubs 1
want_answer "2	Sea/Tagged.md
…	1	more linked-to notes" "graph hubs in node"
checks=$((checks + 1))

eval_of ends graph ends 1
want_answer "no-incoming	Sea/Ignored.md
no-incoming	… and 4 more
no-outgoing	Sea/Coastlines.md
no-outgoing	… and 4 more" "graph ends in node"
checks=$((checks + 1))

eval_of components graph components 2 2
want_answer "4	Sea/Coastlines.md | Sea/Other.md | … and 2 more
1	Sea/Ignored.md
…	2 more components" "graph components in node"
checks=$((checks + 1))

# A path follows links the way they are written: Smith reaches Tagged, and nothing is
# reachable from Coastlines, which links nowhere, though Smith links to it
eval_of path graph path Sea/Smith.md Sea/Tagged.md
want_answer "Sea/Smith.md
Sea/Tagged.md" "graph path in node"
eval_of no-path graph path Sea/Coastlines.md Sea/Tagged.md
want_answer "No path found." "graph path against the links' direction in node"
eval_of path-nowhere graph path Sea/Smith.md Sea/Nowhere.md
want_answer "Error: Sea/Nowhere.md is not a note in the graph" "graph path to a note not in the graph in node"
checks=$((checks + 1))

eval_of unresolved graph unresolved
want_answer "Missing note	Sea/Other.md	1" "graph unresolved in node"
checks=$((checks + 1))

# graph related compares tags without their `#`, from either place: Tagged carries x in its
# frontmatter as "#x", Lone carries it inline, and nothing links the two
eval_of related graph related Sea/Tagged.md --tag-max-notes 5
want_out "1	tag	Sea/Lone.md" "graph related in node"
checks=$((checks + 1))

# The whole answer: Smith links to Coastlines as well as to Tagged, so Coastlines is
# co-cited; Lone and Ignored share a tag with Tagged; Smith and Other, which link to it, are
# left to backlinks. With no --tag-max-notes a tag counts while it is on at most five notes
# here, the floor of the default
eval_of related-default graph related Sea/Tagged.md
want_answer "2	co-cited	Sea/Coastlines.md
1	tag	Sea/Ignored.md
1	tag	Sea/Lone.md" "graph related with the default tag ceiling in node"
checks=$((checks + 1))

# y is on three notes, so a ceiling of two leaves x alone as a signal
eval_of related-ceiling graph related Sea/Tagged.md --tag-max-notes 2
want_answer "2	co-cited	Sea/Coastlines.md
1	tag	Sea/Lone.md" "graph related under --tag-max-notes in node"
checks=$((checks + 1))

# Smith and Other both link to Tagged, which is the same argument read from the other end
eval_of related-shares graph related Sea/Smith.md
want_answer "2	shares-links	Sea/Other.md" "graph related sharing links in node"
checks=$((checks + 1))

# selftest sums the vault's tags the way find reads them, under getTags' own counting rules,
# and has to land on exactly the count Obsidian writes out by hand in tests/fake-app.js —
# nested parents, one tag in two cases, a trailing slash, a placeholder and a number that are
# no tags, an excluded file, and a merged tag Obsidian spells capitalised all included
eval_of selftest selftest
want_out "tags agree with Obsidian's own count (6 tags)" "selftest in node on a vault that agrees"
checks=$((checks + 1))

# And when Obsidian counts differently — the drift selftest exists to notice — every tag
# that differs is named with both counts, and the answer is an error
out=$(FAKE_GETTAGS=drift node "$fake_app" "$work/js/selftest.js" 2>&1) || fail "selftest: node could not run the query: $out"
want_out "Error: " "selftest in node on a vault that drifted"
want_out "#x	ours 2	obsidian 3" "selftest in node on a vault that drifted"
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
  # On /dev/null: the stub drains any stdin that is not a terminal, as the real client does,
  # so a copy without the stdin guard would otherwise wait for ever on a stdin that never
  # ends. The read-loop check supplies its own stdin, and it is what catches that copy
  nested_out=$(CHECK_OBSI_NESTED=1 OBSI_UNDER_TEST="$copy" "$self" "$root" </dev/null 2>&1)
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
nested_ok=$(CHECK_OBSI_NESTED=1 OBSI_UNDER_TEST="$obsi" "$self" "$root" </dev/null 2>&1) ||
  fail "the unmodified wrapper failed its own checks: $nested_ok"

# shellcheck disable=SC2016
expect_red "$(plant no-stdin-guard 's|"\$@" </dev/null 2>"\$scratch/stderr"|"$@" 2>"$scratch/stderr"|')" \
  "stdin left open on every call" "stdin was eaten"

# One plant per function: the same `case` stands in cli() and in js(), and a plant that
# neutered both at once never showed that either check works alone
# shellcheck disable=SC2016
expect_red "$(plant no-error-check-cli '/^cli() {$/,/^}$/s|"Error: "\*) die.*|"Error: "*) : ;;|')" \
  "the CLI's Error: prefix no longer turned into a failure" "an application error at exit 0"

# shellcheck disable=SC2016
expect_red "$(plant no-error-check-js '/^js() {$/,/^}$/s|"Error: "\*) die.*|"Error: "*) : ;;|')" \
  "an Error: raised inside eval no longer turned into a failure" "an error raised inside eval"

# shellcheck disable=SC2016
expect_red "$(plant dump-truncates-first 's/^graph_dump() {$/graph_dump() { : >"$1";/')" \
  "graph dump emptying its file before the query has answered" "the existing file was clobbered"

# shellcheck disable=SC2016
expect_red "$(plant stderr-in-answer '/printf .%s\\n. "\$err" >&2/s/.*/  [[ -z "$err" ]] || out="$err$out"/')" \
  "the client's stderr folded into its answer" "landed inside the JSON"

expect_red "$(plant empty-answer-passes '/the app answered nothing/s/.*/  :/')" \
  "an empty reply from the app printed as a blank answer" "answered with nothing"

expect_red "$(plant value-not-a-marker '/^        --value)$/,/;;$/s/markers=.*/:/')" \
  "--value accepted and dropped instead of narrowing to property values" "its one marker"

# shellcheck disable=SC2016
expect_red "$(plant scope-always 's/^    scope=""$/    scope="${prop%%=*}"/')" \
  "--prop confining the value match even without --value" "confined the value match to the filtered property"

# The JavaScript half, one plant per question the fake vault asks
expect_red "$(plant js-prop-marker-off "s/if (on('prop')) for/if (on('none')) for/")" \
  "the index query ignoring the property-value marker" "find --value in node"

expect_red "$(plant js-scope-dropped '/if (scope ? k !== scope/s/scope ? k !== scope : //')" \
  "the index query dropping the --value scope" "find --value --prop status in node"

expect_red "$(plant js-string-split "s/return \[v.trim()\]/return v.split(',').map(x => x.trim())/")" \
  "a frontmatter string split on commas" "a comma string alias in node"

expect_red "$(plant js-list-split '/typeof x === .string./s/\.map(x => x\.trim())/.flatMap(x => x.split(",")).map(x => x.trim())/')" \
  "a frontmatter list item split on commas" "a list alias holding a comma in node"

expect_red "$(plant js-tag-spaces-kept '/const fmTags/s/ \&\& !t\.includes(. .)//')" \
  "a tag holding a space kept as a tag" "tags: a, b in node"

# shellcheck disable=SC2016
expect_red "$(plant js-keys-case-sensitive 's|/^aliases$/i|/^aliases$/|; s|/^tags$/i|/^tags$/|')" \
  "the tags and aliases keys matched in one case only" "a mixed-case key in node"

expect_red "$(plant js-related-hash 's/fmTags(fm).map(t => t.slice(1))/fmTags(fm)/')" \
  "graph related comparing a frontmatter #x with an inline x" "graph related in node"

expect_red "$(plant selftest-passes-through '/^  selftest)$/,/^    ;;$/d')" \
  "selftest handed to the CLI as an unknown command" "selftest when the counts agree"

# selftest's counting, one plant per rule of getTags it has to reproduce
expect_red "$(plant js-selftest-no-parents '/if (last !== t) count/d')" \
  "selftest not counting a nested tag toward its parent" "selftest in node on a vault that agrees"

expect_red "$(plant js-selftest-invalid-counted 's/if (!valid.test(t) || numeric.test(t)) return/if (numeric.test(t)) return/')" \
  "selftest counting a tag Obsidian refuses, such as a template placeholder" "selftest in node on a vault that agrees"

expect_red "$(plant js-selftest-numbers-counted 's/if (!valid.test(t) || numeric.test(t)) return/if (!valid.test(t)) return/')" \
  "selftest counting a number as a tag" "selftest in node on a vault that agrees"

expect_red "$(plant js-selftest-case-sensitive 's/const k = t.toLowerCase()/const k = t/')" \
  "selftest keeping one tag in two cases apart" "selftest in node on a vault that agrees"

expect_red "$(plant js-selftest-ignored-counted '/isUserIgnored(f.path)) continue/d')" \
  "selftest counting the vault's excluded files" "selftest in node on a vault that agrees"

expect_red "$(plant js-selftest-silent 's/^if (rows.length)$/if (false)/')" \
  "selftest that never reports a difference" "selftest in node on a vault that drifted"

expect_red "$(plant out-stays-exported '/^export -n out err$/d')" \
  "an exported \$out from the caller left on the wrapper's own locals" "find under an exported"

expect_red "$(plant tag-max-octal '/related_tags" =~/s/=~ .* ]]/=~ ^(-1|[0-9]+)$ ]]/')" \
  "--tag-max-notes taking a leading zero and the default's sentinel" "--tag-max-notes 010"

# shellcheck disable=SC2016
expect_red "$(plant head-not-awk 's|awk -v n="\$limit" .NR <= n.|head -n "$limit"|')" \
  "the truncation notice bounded with head, which dies of SIGPIPE under pipefail" \
  "larger than a pipe buffer"

# shellcheck disable=SC2016
expect_red "$(plant unquoted-vault 's|prefix=("vault=\$2")|prefix=(vault= "$2")|')" \
  "a vault name split into two arguments" "arrived split"

expect_red "$(plant no-empty-sentence 's|echo "No matches found."|echo ""|')" \
  "an empty result printed as empty output rather than as a sentence" "find with no matches"

expect_red "$(plant no-prop-filter '/grep -Fxf/s/.*/      :/')" \
  "--prop applied to the index half only, leaving the body half unfiltered" \
  "--prop filtering both halves"

expect_red "$(plant hubs-unvalidated '/^    hubs)$/,/;;$/s/need_count.*/:/')" \
  "the row count of graph hubs spliced into JavaScript without being checked" \
  "a row count that names something in the app's scope"

# shellcheck disable=SC2016
expect_red "$(plant probes-on '/unreachable="\$candidate"/{n;s/break/continue/;}')" \
  "discovery probing on after a client reported the app down" \
  "went on to run"

echo "check-obsi: $checks checks passed, $planted planted defects caught"
