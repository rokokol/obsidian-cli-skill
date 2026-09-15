#!/usr/bin/env bash
# The gate for this repository: lint what it ships, hold the docs to the family's rules,
# and prove that each check can actually go red. A check that has never failed is a
# decoration.
#
# What this gate cannot cover is the skill's behavioural claims: they need a running
# Obsidian with a real vault, which no runner has. They carry their measurements instead,
# so a reader with an app open can falsify them — see references/pitfalls.md.
#
# Nothing here touches the network, so it is safe on pull requests.
# Needs: actionlint, shellcheck, shfmt, node — from the flake's dev shell, never from PATH's luck.
#
#   nix develop -c ./check.sh
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$HERE"

# One source of truth for what gets linted. A second copy of this list drifts, and a
# drifted list lies about what was checked.
scripts=(check.sh check-sh.sh check-skill.sh check-pins.sh check-changelog.sh check-interface.sh vendor-sync.sh check-obsi.sh obsi.sh tests/stub-cli.sh)
skill_name=obsidian-cli

fail() {
  echo "check: $1" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

missing=()
for tool in actionlint shellcheck shfmt node; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
((${#missing[@]} == 0)) ||
  fail "missing: ${missing[*]} — they are pinned in the flake, so run this as: nix develop -c ./check.sh"

echo "== the scripts parse and lint"
for s in "${scripts[@]}"; do bash -n "$s"; done
shellcheck "${scripts[@]}"
shfmt -d -i 2 -ci "${scripts[@]}"

echo "== the workflows are valid, and their tools come from the lock rather than a registry"
[[ -d .github/workflows ]] || fail ".github/workflows is missing — nothing gates this repository"
actionlint
# The checkers here are vendored — from the ci skill, and check-changelog.sh from the
# versioning skill: every copy must still be the blob .github/vendor.lock records, so one
# edited here instead of at its source fails by name
./vendor-sync.sh check
# The pin guard proves on every run that it catches each unpinned shape and stays quiet on
# the pinned spellings, then scans the workflows
./check-pins.sh

echo "== SKILL.md loads, every reference is reachable, and every link and anchor resolves"
# The one gate every skill repository shares, copied verbatim from the ci skill. It plants
# a defect per check on every run, so nothing here has to prove it separately
./check-skill.sh -n "$skill_name" .

echo "== the wrapper's help and these documents agree with its dispatcher"
# The bash-best-practices skill's check-sh.sh, vendored: obsi.sh's own subcommands, its
# flags and its exit codes must be in its help, and every `obsi.sh …` these documents
# spell must be one of them — or, since the wrapper passes unknown words through to the
# CLI, any command at all, which the checker allows once it sees the *) arm forward
# rather than refuse. It plants its own defects on every run
./check-sh.sh -d SKILL.md -d README.md obsi.sh

echo "== what these documents say about the Obsidian CLI is what its own help declares"
# obsi.sh passes unknown words through, so check-sh.sh cannot tell a real CLI command from a
# ghost; the CLI's own help can. The app is not on a runner, so the gate reads
# tests/obsidian-help.txt, the help one version answered, recorded with that version on its
# first line. With OBSIDIAN_CLI set to the client's binary the recording is first held to the
# live help, so the day the app moves the gate says the recording is stale
if [[ -n "${OBSIDIAN_CLI:-}" ]]; then
  diff <(sed 1d tests/obsidian-help.txt) <("$OBSIDIAN_CLI" help 2>/dev/null) >"$work/help.diff" ||
    fail "tests/obsidian-help.txt is not what $OBSIDIAN_CLI help answers now; regenerate it:"$'\n'"  { printf '# obsidian %s — …\n' \"\$($OBSIDIAN_CLI version)\"; $OBSIDIAN_CLI help; } >tests/obsidian-help.txt"$'\n'"$(head -n 20 "$work/help.diff")"
else
  echo "   against the recording of $(head -n 1 tests/obsidian-help.txt | cut -d' ' -f2-5); set OBSIDIAN_CLI to hold it to a live app"
fi
declared_of() { # declared_of [FILE] -> the "command" and "command parameter" lines a help declares
  # The help's shape: `vault=` under Options is every command's, a command sits at two
  # spaces under Commands, and its parameters at four, `file=<name>` or a flag like `total`
  awk '/^Options:/ { opt = 1; next }
    /^Commands:/ { opt = 0; cmds = 1; next }
    opt && /^  [a-z]+=/ { split($1, a, "="); print "*", a[1]; next }
    !cmds { next }
    /^  [a-z][a-z0-9:.-]*( |$)/ { cmd = $1; print cmd; next }
    cmd && /^    [^ ]/ { p = $1; sub(/=.*/, "", p); print cmd, p }' "${1:--}" | sort -u
}
declared_of tests/obsidian-help.txt >"$work/declared.txt"
# Every command an earlier recording declared: one the current recording has dropped was
# renamed or removed, and a bare span still naming it would otherwise pass as prose. The
# recordings are this file's own history, so the gate needs all of it, which the build
# workflow checks out; a shallow clone would show only the current one and prove nothing
[[ "$(git rev-parse --is-shallow-repository)" == false ]] ||
  fail "this clone is shallow, so the earlier recordings of tests/obsidian-help.txt are out of reach; fetch the whole history"
git log --format=%H -- tests/obsidian-help.txt | while read -r rev; do
  git show "$rev:tests/obsidian-help.txt" | declared_of
done | cut -d' ' -f1 | sort -u >"$work/was.txt"
[[ -s "$work/was.txt" ]] || fail "no earlier recording of tests/obsidian-help.txt was read — its history is missing"
# A parser that stopped matching the parameter lines would leave commands with no arguments,
# and every `key=` a document spells would then be a finding — but a list with only names
# must not be mistaken for the CLI either
grep -q '^[a-z][^ ]* [a-z<]' "$work/declared.txt" || fail "no parameter was read from tests/obsidian-help.txt — its shape moved"
# The ci skill's check-interface.sh, vendored: `obsidian-cli NAME …` in a span or a fenced
# line, and a span opening with a declared command, are held to the list, and it plants its
# own defects on every run. A typo shown on purpose is excused in check-interface.allow,
# which no agent loads, and -r makes a command the recordings once had and the current one
# lacks a finding anywhere
./check-interface.sh -d "$work/declared.txt" -r "$work/was.txt" -x check-interface.allow \
  -p 'obsidian-cli ' -b -f SKILL.md README.md references/*.md

echo "== the wrapper's shell half behaves, against a fake CLI"
# The shell half against the stub, and the JavaScript the wrapper builds for find, graph
# related and selftest run in node against a made-up vault — each with a defect planted per
# check on every run. What stays measured rather than tested is the real app's index
./check-obsi.sh .

echo "== the changelog obeys the versioning skill's rules"
# Pinned: without -t a changelog moved wholesale to another template stays green, which is
# the versioning skill's PITFALLS.md
./check-changelog.sh -n -t '## {date}' CHANGELOG.md

echo "== the skill fits in what an agent loads"
# A SKILL.md that grows too long stops being the routing layer it is meant to be and becomes
# a reference nobody reads to the end. The references are where length belongs, and they
# are loaded on demand. Counted in words, not lines: paragraphs are never hard-wrapped, so
# one line can hold a page and a line count measures nothing
max_words=2500
too_long() { # too_long FILE -> 0 when FILE is over the budget
  (($(wc -w <"$1") > max_words))
}
if too_long SKILL.md; then
  fail "SKILL.md is $(wc -w <SKILL.md | tr -d ' ') words — over $max_words, move the detail into references/"
fi
# And the budget is awake: one line a word over it is caught, which a line count would pass
awk -v n="$max_words" 'BEGIN { for (i = 0; i <= n; i++) printf "word "; print "" }' >"$work/long.md"
too_long "$work/long.md" ||
  fail "the length budget passed a document over it — the check measures nothing"

echo "== the skill still points at help as the command reference, and says so"
# The central rule this skill exists to hold: the command set is generated by the running
# app and varies with its enabled plugins, so a transcribed list is a second source of
# truth that goes stale in silence. If that sentence ever leaves the documents, the rule
# has been dropped and the next contributor will paste a command table back in
# shellcheck disable=SC2016 # the backticks are the sentence's own markdown
help_rule='Treat `help` as the reference'
states_help_rule() { grep -qF -- "$help_rule" "$1"; }
states_help_rule SKILL.md ||
  fail "SKILL.md no longer names help as the command reference"
grep -q 'does not repeat it' references/commands.md ||
  fail "references/commands.md no longer says why it omits the command list"
# And the check is awake: a SKILL.md that still mentions help in passing but has lost the
# rule is caught. The bare `grep help` this replaced passed exactly that
grep -vF -- "$help_rule" SKILL.md >"$work/no-rule.md"
grep -q 'help' "$work/no-rule.md" ||
  fail "the planted SKILL.md mentions help nowhere, so it cannot show a bare grep was blind"
if states_help_rule "$work/no-rule.md"; then
  fail "the help-rule check passed a SKILL.md that lost the rule"
fi

echo "== every document states the version its measurements came from"
# A number with no version beside it cannot be checked by the next reader, which is the
# only thing that makes these claims falsifiable rather than folklore
version_claim='1\.13\.7'
for f in SKILL.md references/commands.md references/pitfalls.md references/obsi.md; do
  grep -qE "$version_claim" "$f" ||
    fail "$f states behaviour without naming the version it was measured on"
done

echo "== and that check is awake — a document with no version is caught"
# The half that proves the loop above is doing something. Without it, a typo in the
# pattern would leave every future document unchecked and the run still green
printf '%s\n' '# A document with measurements and no version' 'It returned 12 backlinks' \
  >"$work/versionless.md"
grep -qE "$version_claim" "$work/versionless.md" &&
  fail "the version guard matches a document that names no version"

echo "check: green"
