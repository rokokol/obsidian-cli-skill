#!/usr/bin/env bash
# shellcheck disable=SC2016 # every $ in a single-quoted text here is text to find, not an expansion
# The defect list for this repository, read by the tests skill's harness, vendored beside
# it, and run by .github/workflows/falsify.yml:
#
#   tests/t.sh falsify -- ./check-obsi.sh .
#
# Needs bash 3.2, since falsify sources it wherever t.sh runs, macOS included; check.sh
# holds it to that claim through check-sh.sh
#
# Each entry breaks one guard of obsi.sh — its shell half, or the JavaScript it hands to the
# app's eval — and requires the behaviour suite to notice. This list is the only proof that
# the suite's checks can fail; the gate does not plant defects of its own. The CONSEQUENCE is
# what goes wrong in the world when that guard stops working; when an entry survives, that
# sentence is the report.
#
#   defect NAME FILE FIND REPLACE CONSEQUENCE [expect survived REASON | expect caught FRAGMENT]
#
# A FIND or REPLACE of several lines or holding quotes is single-quoted, in the form and for
# the bash 3.2 reason templates/defects.sh of https://github.com/rokokol/tests-skill gives.
# Two entries share a line only where the line holds two behaviours a caller can tell apart

# ---- reaching the app ------------------------------------------------------------------

defect 'env/out-export' 'obsi.sh' \
  'export -n out err' \
  'export -n err' \
  'under a nix dev shell a large answer held in "out" is exported to every later command, exec refuses it, and find says No matches found' \
  expect caught 'find under an exported'

defect 'reach/version-shape' 'obsi.sh' \
  '      [0-9]*.[0-9]*)' \
  '      *)' \
  'any binary called obsidian-cli is taken for the client, whatever it answers, and every call goes to it'

defect 'reach/env-first' 'obsi.sh' \
  'for candidate in ${OBSIDIAN_CLI:+"$OBSIDIAN_CLI"} obsidian-cli obsidian; do' \
  'for candidate in obsidian-cli obsidian ${OBSIDIAN_CLI:+"$OBSIDIAN_CLI"}; do' \
  'OBSIDIAN_CLI is ignored whenever another client on PATH answers, so the user cannot choose which client talks to the app'

defect 'reach/launcher-last' 'obsi.sh' \
  ' obsidian-cli obsidian; do' \
  ' obsidian obsidian-cli; do' \
  'the GUI launcher is asked for its version before the client, and on a packaged install every call opens an Obsidian window'

defect 'reach/stop-when-app-down' 'obsi.sh' \
  '        unreachable="$candidate"
        break' \
  '        unreachable="$candidate"
        continue' \
  'with the app closed, discovery goes on to run "obsidian", which on a packaged install opens a window instead of answering' \
  expect caught 'went on to run'

defect 'reach/app-down-message' 'obsi.sh' \
  '  [[ -z "$unreachable" ]] ||' \
  '  true ||' \
  'someone with the client installed and the app closed is told to install a client they already have'

defect 'reach/probe-stdin' 'obsi.sh' \
  'answer=$("$candidate" version </dev/null 2>&1)' \
  'answer=$("$candidate" version 2>&1)' \
  'every obsi.sh call inside a while-read loop swallows the rest of the list while it looks for the client'

# ---- the dishonest client ------------------------------------------------------------------

defect 'cli/stdin' 'obsi.sh' \
  '"$@" </dev/null 2>"$scratch/stderr")' \
  '"$@" 2>"$scratch/stderr")' \
  'every CLI call inside a while-read loop swallows the rest of the list, and the loop quietly does one item' \
  expect caught 'stdin was eaten'

defect 'cli/error-at-exit-0' 'obsi.sh' \
  '    "Error: "*) die "${out#Error: }" ;;
  esac
  ((status == 0))' \
  '    "Error: "*) : ;;
  esac
  ((status == 0))' \
  'a missing note or a bad parameter reported by the app exits 0, and the caller acts on an error message as though it were the answer' \
  expect caught 'an application error at exit 0'

defect 'cli/nonzero-status' 'obsi.sh' \
  '((status == 0)) || die' \
  'true || die' \
  'a client that fails or crashes reads as success, with whatever it printed before dying taken for the answer'

defect 'cli/stderr-apart' 'obsi.sh' \
  '[[ -z "$err" ]] || printf '"'"'%s\n'"'"' "$err" >&2' \
  '[[ -z "$err" ]] || printf '"'"'%s\n'"'"' "$err"' \
  'a runtime warning from the app lands inside the answer, a dumped graph.json included, and makes it unparseable' \
  expect caught 'landed inside the JSON'

defect 'js/prefix' 'obsi.sh' \
  'out="${out#"=> "}"' \
  'out="$out"' \
  'every answer from eval starts with "=> ", and an error raised by the JavaScript exits 0'

defect 'js/cli-refusal-passed-on' 'obsi.sh' \
  '  ((status == 0)) || exit "$status"' \
  '  :' \
  "a refusal the CLI prints for the query is lost inside the caller's command substitution: find says No matches found and graph dump empties the file it was meant to keep, both at exit 0"

defect 'js/error-at-exit-0' 'obsi.sh' \
  '    "Error: "*) die "${out#Error: }" ;;
  esac
  printf '"'"'%s\n'"'"' "$out"' \
  '    "Error: "*) : ;;
  esac
  printf '"'"'%s\n'"'"' "$out"' \
  'a refusal raised inside the app — a note not in the graph, a selftest that found drift — prints and exits 0' \
  expect caught 'an error raised inside eval'

defect 'exit/usage-is-2' 'obsi.sh' \
  '  printf '"'"'obsi: %s\n'"'"' "$1" >&2
  exit 2' \
  '  printf '"'"'obsi: %s\n'"'"' "$1" >&2
  exit 1' \
  'every usage error exits 1, the same as an answer from the CLI or the vault, and a caller cannot tell a typo from a note that is not there'

defect 'answer/empty' 'obsi.sh' \
  '[[ -n "$out" ]] || die "the app answered nothing' \
  'true || die "the app answered nothing' \
  'a graph query the app answered with nothing prints a blank line at exit 0, which reads like an answer' \
  expect caught 'answered with nothing'

# ---- counts spliced into the app's JavaScript ------------------------------------------------

defect 'count/validator-body' 'obsi.sh' \
  '  for value in "$@"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || usage_error "expected a positive number, not '"'"'$value'"'"'"
  done' \
  '  :' \
  'a row count such as "app", or a crafted expression, runs as code inside the app with full access to the vault'

defect 'count/leading-zero' 'obsi.sh' \
  '=~ ^[1-9][0-9]*$ ]]' \
  '=~ ^[0-9]+$ ]]' \
  'a count of 010 is octal 8 in the app and 0 answers zero rows, both at exit 0 as if they were what was asked'

defect 'count/hubs' 'obsi.sh' \
  '      need_count "${1:-10}"
      answer graph_hubs' \
  '      :
      answer graph_hubs' \
  'the row count of graph hubs is spliced into the app unchecked, where "app" answers No links found and a crafted value runs as code' \
  expect caught "a row count that names something in the app's scope"

defect 'count/ends' 'obsi.sh' \
  '      need_count "${1:-10}"
      answer graph_ends' \
  '      :
      answer graph_ends' \
  'the row count of graph ends is spliced into the app unchecked, and a crafted value runs as code'

defect 'count/components-width' 'obsi.sh' \
  'need_count "${1:-10}" "${2:-5}"' \
  'need_count "${1:-10}"' \
  'the second count of graph components, how many notes each row shows, is spliced into the app unchecked'

defect 'count/unresolved' 'obsi.sh' \
  'need_count "${1:-40}"' \
  ':' \
  'the row count of graph unresolved is spliced into the app unchecked, and a crafted value runs as code'

defect 'count/find-limit' 'obsi.sh' \
  '    need_count "$limit"' \
  '    :' \
  'find --limit abc is not refused, and the cut and its notice go wrong without a word'

defect 'count/related-rows' 'obsi.sh' \
  'need_count "$related_rows"' \
  ':' \
  'the row count of graph related is spliced into the app unchecked, and a crafted value runs as code'

# ---- graph arguments -----------------------------------------------------------------------

defect 'arity/summary' 'obsi.sh' \
  '(($# == 0)) || usage_error "graph summary takes no arguments"' \
  'true || usage_error "graph summary takes no arguments"' \
  'a word after graph summary is dropped in silence, and the summary answers as though it had not been typed'

defect 'arity/hubs' 'obsi.sh' \
  '(($# <= 1)) || usage_error "graph hubs takes one row count"' \
  'true || usage_error "graph hubs takes one row count"' \
  'graph hubs 5 10 answers for 5 and drops the 10 without a word'

defect 'arity/ends' 'obsi.sh' \
  '(($# <= 1)) || usage_error "graph ends takes one row count"' \
  'true || usage_error "graph ends takes one row count"' \
  'a second word to graph ends is dropped in silence'

defect 'arity/unresolved' 'obsi.sh' \
  '(($# <= 1)) || usage_error "graph unresolved takes one row count"' \
  'true || usage_error "graph unresolved takes one row count"' \
  'a second word to graph unresolved is dropped in silence'

defect 'arity/components' 'obsi.sh' \
  '(($# <= 2)) || usage_error "graph components takes a row count and a width"' \
  'true || usage_error "graph components takes a row count and a width"' \
  'a third word to graph components is dropped in silence'

defect 'arity/related-rows' 'obsi.sh' \
  '[[ -z "$related_rows_given" ]] ||' \
  'true ||' \
  'graph related a.md 3 4 answers with 4 rows and drops the 3 without a word'

defect 'related/tag-max-shape' 'obsi.sh' \
  '[[ "$related_tags" =~ ^(0|[1-9][0-9]*)$ ]] ||' \
  '[[ "$related_tags" =~ ^-?[0-9]+$ ]] ||' \
  '--tag-max-notes 010 means 8 in the app, and -1 silently means the default' \
  expect caught '--tag-max-notes 010'

defect 'related/tag-max-default' 'obsi.sh' \
  '        related_tags=-1' \
  '        related_tags=0' \
  'graph related without --tag-max-notes ignores shared tags altogether, rather than counting the ones on under a twentieth of the vault'

defect 'related/tag-max-needs-value' 'obsi.sh' \
  '(($# >= 2)) || usage_error "--tag-max-notes needs a number' \
  'true || usage_error "--tag-max-notes needs a number' \
  "--tag-max-notes with no value ends in bash's own unbound-variable error instead of saying what it needs"

defect 'related/unknown-option' 'obsi.sh' \
  '-*) usage_error "unknown option '"'"'$1'"'"' — graph related takes a row count and --tag-max-notes" ;;' \
  '-*) shift ;;' \
  'a mistyped flag to graph related is swallowed and the query runs with defaults as though it had been understood'

defect 'related/needs-note' 'obsi.sh' \
  '[[ $# -ge 1 ]] || usage_error "graph related needs a note path' \
  'true || usage_error "graph related needs a note path' \
  "graph related with no note ends in bash's unbound-variable error instead of saying it needs a path"

defect 'path/two-notes' 'obsi.sh' \
  '[[ $# -eq 2 ]] || usage_error "graph path needs two' \
  '[[ $# -ge 2 ]] || usage_error "graph path needs two' \
  'graph path with a third note answers for the first two and drops the third without a word'

defect 'dump/one-file' 'obsi.sh' \
  '[[ $# -le 1 ]] || usage_error "graph dump takes one file' \
  'true || usage_error "graph dump takes one file' \
  'graph dump with two files writes the first and silently ignores the second'

defect 'dump/asked-first' 'obsi.sh' \
  '  [[ -d "$dir" && -w "$dir" && (! -e "$target" || -w "$target") ]] ||' \
  '  true ||' \
  'an unwritable target is found out only after the whole graph was queried, and a read-only graph.json in a writable folder is overwritten'

defect 'dump/in-place' 'obsi.sh' \
  'printf '"'"'%s\n'"'"' "$out" >"$tmp" && mv -f -- "$tmp" "$target"' \
  'printf '"'"'%s\n'"'"' "$out" >"$target"' \
  'the graph is written in place, so a failed write leaves graph.json half-written, and a hidden temp file is left beside it on every dump'

defect 'dump/truncates-first' 'obsi.sh' \
  '  local target="$1" dir tmp out' \
  '  local target="$1" dir tmp out
  : >"$target"' \
  'an app that is down turns an existing graph.json into an empty file' \
  expect caught 'the existing file was clobbered'

defect 'graph/unknown-query' 'obsi.sh' \
  '*) usage_error "unknown graph query '"'"'$what'"'"' — see obsi.sh --help" ;;' \
  '*) answer graph_summary ;;' \
  'a misspelt graph query answers with the summary, as if it were what was asked'

defect 'selftest/dispatched' 'obsi.sh' \
  '    answer self_test' \
  '    cli selftest' \
  'selftest goes to the CLI as a command it does not have, and never checks the copied tag rules' \
  expect caught 'selftest when the counts agree'

defect 'selftest/no-args' 'obsi.sh' \
  '(($# == 0)) || usage_error "selftest takes no arguments"' \
  'true || usage_error "selftest takes no arguments"' \
  'words after selftest are dropped in silence, the CLI habit the wrapper exists to stop'

# ---- the wrapper's own arguments --------------------------------------------------------------

defect 'args/vault-one-word' 'obsi.sh' \
  'prefix=("vault=$2")' \
  'prefix=(vault= "$2")' \
  'a vault name with a space reaches the CLI as two arguments, it ignores both, and answers for whichever vault is open' \
  expect caught 'arrived split'

defect 'args/vault-needs-name' 'obsi.sh' \
  '(($# >= 2)) || usage_error "--vault needs a name"' \
  'true || usage_error "--vault needs a name"' \
  "--vault with no name ends in bash's unbound-variable error instead of saying it needs a name"

defect 'args/vault-selector' 'obsi.sh' \
  '      prefix=("$1")' \
  '      break' \
  'obsi.sh vault=X find … sends find to the CLI as its own command, which the CLI does not have'

defect 'args/no-command' 'obsi.sh' \
  '  usage >&2
  exit 2' \
  '  usage >&2
  exit 0' \
  'a call whose command expanded to nothing exits 0, as though it had done something'

defect 'pass/vault-after-command' 'obsi.sh' \
  'if [[ -n "$command_word" && ("$arg" == vault=* || "$arg" == --vault) ]]; then' \
  'if false; then' \
  'a vault named after the command word is dropped by the CLI in silence, and the answer comes from whichever vault is open'

# ---- find: arguments ---------------------------------------------------------------------------

defect 'find/needs-query' 'obsi.sh' \
  '(($#)) || usage_error "find needs something to look for"' \
  'true || usage_error "find needs something to look for"' \
  "find with nothing to look for ends in bash's unbound-variable error instead of saying what it needs"

defect 'find/unknown-option' 'obsi.sh' \
  '*) usage_error "unknown option '"'"'$1'"'"' — see obsi.sh --help" ;;' \
  '*) shift ;;' \
  'a mistyped find flag is swallowed and the search runs wider than asked, looking like the narrowed answer'

defect 'find/limit-needs-value' 'obsi.sh' \
  '(($# >= 2)) || usage_error "--limit needs a number"' \
  'true || usage_error "--limit needs a number"' \
  "--limit with no value ends in bash's unbound-variable error instead of saying it needs a number"

defect 'find/prop-needs-value' 'obsi.sh' \
  '(($# >= 2)) || usage_error "--prop needs NAME or NAME=VALUE"' \
  'true || usage_error "--prop needs NAME or NAME=VALUE"' \
  "--prop with no value ends in bash's unbound-variable error instead of saying it needs a name"

defect 'find/value-marker' 'obsi.sh' \
  '          markers="$markers prop"' \
  '          :' \
  '--value is accepted and dropped, so find --value searches every field instead of property values' \
  expect caught 'its one marker'

defect 'find/default-markers' 'obsi.sh' \
  'markers=" name alias tag prop heading body"' \
  'markers=" name alias tag heading body"' \
  'a plain find stops matching property values, though naming no field is documented to mean all of them'

defect 'find/value-scope-name' 'obsi.sh' \
  'scope="${prop%%=*}"' \
  'scope="$prop"' \
  'find --value --prop status=draft looks for a property literally named status=draft and finds nothing'

defect 'find/scope-needs-value' 'obsi.sh' \
  '[[ -z "$value_flag" || -z "$prop" ]] ||' \
  '[[ -z "$prop" ]] ||' \
  'find --prop status confines the value match to status even without --value, so matches in other properties vanish' \
  expect caught 'confined the value match to the filtered property'

# ---- find: merging, ranking, bounding --------------------------------------------------------

defect 'find/text-over-fetch' 'obsi.sh' \
  'limit="$((limit * 3))")' \
  'limit="$limit")' \
  'the text search is asked for only as many notes as are shown, so its cap is never seen and the notice states a floor as an exact count'

defect 'find/search-sentence' 'obsi.sh' \
  '[[ "$body" == "No matches found." ]] && body=""' \
  'true' \
  'search answering No matches found is ranked as a note by that name, one point, text'

defect 'find/capped-floor' 'obsi.sh' \
  '>= limit * 3))' \
  '> limit * 3))' \
  'a text search that filled its cap exactly is reported as a complete count of what was left out, not a floor'

defect 'find/empty-sentence' 'obsi.sh' \
  '  if [[ -z "$ranked" ]]; then
    echo "No matches found."' \
  '  if [[ -z "$ranked" ]]; then
    echo ""' \
  'a find with no matches prints an empty line, which a caller cannot tell from a failure that printed nothing' \
  expect caught 'find with no matches'

defect 'find/prop-filters-index' 'obsi.sh' \
  'meta=$(printf '"'"'%s\n'"'"' "$meta" | awk -F'"'"'\t'"'"' '"'"'NR == FNR { a[$0]; next } $3 in a'"'"' "$allow" -)' \
  'meta=$meta' \
  '--prop filters the text half only, and every name, alias, tag and heading hit comes back unfiltered'

defect 'find/prop-filters-text' 'obsi.sh' \
  'body=$(printf '"'"'%s\n'"'"' "$body" | grep -Fxf "$allow" || true)' \
  'body=$body' \
  '--prop filters the index half only, and every text hit comes back unfiltered' \
  expect caught '--prop filtering both halves'

defect 'find/prop-none-kept' 'obsi.sh' \
  '"$allow" || true)' \
  '"$allow" || printf '"'"'%s\n'"'"' "$body")' \
  'find --prop naming a property no note has answers with every text hit, unfiltered, instead of No matches found' \
  expect caught 'find --prop naming a property no note has'

defect 'find/merge-adds' 'obsi.sh' \
  '$0 != "" { s[$0] += 1;' \
  '$0 != "" { s[$0] = 1;' \
  'a note found both by alias and in the text drops to one point and ranks below notes that only mention the word'

defect 'find/rank-order' 'obsi.sh' \
  'sort -t"$(printf '"'"'\t'"'"')" -k1,1nr -k3,3)' \
  'sort -t"$(printf '"'"'\t'"'"')" -k3,3)' \
  'find lists notes alphabetically, and --limit cuts off the exact match in favour of whatever sorts first'

defect 'find/empty-sentence' 'obsi.sh' \
  '  if [[ -z "$ranked" ]]; then' \
  '  if false; then' \
  'find with no matches prints a blank line at exit 0, which a caller cannot tell from a failure'

defect 'find/limit-applied' 'obsi.sh' \
  'awk -v n="$limit" '"'"'NR <= n'"'"'' \
  'awk -v n="$limit" '"'"'NR > 0'"'"'' \
  'find prints every match however many there are, while its notice still claims some were held back'

defect 'find/head-sigpipe' 'obsi.sh' \
  'awk -v n="$limit" '"'"'NR <= n'"'"'' \
  'head -n "$limit"' \
  'find over a large result dies of SIGPIPE under pipefail before it can say what it cut' \
  expect caught 'larger than a pipe buffer'

defect 'find/cut-said' 'obsi.sh' \
  'if ((total > limit)); then' \
  'if false; then' \
  'find cuts at --limit in silence, and "these are the notes with that tag" is confidently wrong'

# ---- find: the index query, run in the app ------------------------------------------------------

defect 'js-find/markers' 'obsi.sh' \
  'const on = m => markers.indexOf(m) >= 0' \
  'const on = m => true' \
  'find --alias answers with name, tag and property hits as well, so the one question only it can ask is gone'

defect 'js-find/name-exact' 'obsi.sh' \
  "if (is(f.basename)) add(f.path, 10, 'name', f.basename)" \
  "if (false) add(f.path, 10, 'name', f.basename)" \
  'a note whose name is exactly the query scores as a partial match and can rank below notes that merely contain it'

defect 'js-find/alias-exact' 'obsi.sh' \
  "if (is(a)) add(f.path, 9, 'alias', a)" \
  "if (false) add(f.path, 9, 'alias', a)" \
  'a note whose alias is exactly the query scores as a partial match and loses its rank'

defect 'js-find/tag-marker' 'obsi.sh' \
  "  if (on('tag')) {" \
  '  if (false) {' \
  'find --tag finds nothing, on any vault'

defect 'js-find/best-per-field' 'obsi.sh' \
  '} else if (score > h.best[kind]) h.best[kind] = score' \
  '} else h.best[kind] += score' \
  'a note carrying one tag three ways, or four matching headings, outranks an exact name match'

defect 'js-find/fields-add-up' 'obsi.sh' \
  'h.kinds.reduce((sum, k) => sum + h.best[k], 0)' \
  'h.best[h.kinds[0]]' \
  'a note that matches by name and by alias scores only for the first, and ranks with notes matching once'

defect 'js-find/prop-skips-lists' 'obsi.sh' \
  'if (scope ? k !== scope : /^(aliases|tags)$/i.test(k)) continue' \
  'if (scope ? k !== scope : false) continue' \
  'every alias and tag is reported a second time as a property value, and --value answers with aliases and tags'

defect 'js-find/value-scope' 'obsi.sh' \
  'if (scope ? k !== scope : /^(aliases|tags)$/i.test(k)) continue' \
  'if (/^(aliases|tags)$/i.test(k)) continue' \
  'find --value --prop status answers with draft in any property of the note, not in status alone' \
  expect caught 'find --value --prop status in node'

defect 'js-find/prop-marker' 'obsi.sh' \
  "if (on('prop')) for" \
  "if (on('none')) for" \
  'find --value finds nothing, and a plain find never matches a property value' \
  expect caught 'find --value in node'

# ---- Obsidian's reading of tags and aliases, copied ---------------------------------------------

defect 'fm/string-one-item' 'obsi.sh' \
  "if (typeof v === 'string') return [v.trim()]" \
  "if (typeof v === 'string') return v.split(',').map(x => x.trim())" \
  'aliases: coastline, shore becomes two aliases, which Obsidian itself never makes of it' \
  expect caught 'a comma string alias in node'

defect 'fm/list-strings-only' 'obsi.sh' \
  "v.filter(x => typeof x === 'string').map(x => x.trim())" \
  'v.map(x => x.trim())' \
  'one note with a number in its aliases or tags list makes every find and graph related throw inside the app'

defect 'fm/list-item-whole' 'obsi.sh' \
  "v.filter(x => typeof x === 'string').map(x => x.trim())" \
  "v.filter(x => typeof x === 'string').flatMap(x => x.split(',')).map(x => x.trim())" \
  'the alias "Smith, John" becomes two aliases, Smith and John, and an exact search for it finds nothing' \
  expect caught 'a list alias holding a comma in node'

defect 'fm/tags-key-any-case' 'obsi.sh' \
  'fmList(fm, /^tags$/i)' \
  'fmList(fm, /^tags$/)' \
  'a note with a capitalised Tags key has no tags to find, graph related or selftest, though Obsidian reads them' \
  expect caught 'a mixed-case key in node'

defect 'fm/aliases-key-any-case' 'obsi.sh' \
  'fmList(fm, /^aliases$/i)' \
  'fmList(fm, /^aliases$/)' \
  'a note with a capitalised Aliases key cannot be found by its aliases, though Obsidian reads them' \
  expect caught 'a mixed-case key in node'

defect 'fm/tag-space' 'obsi.sh' \
  ".filter(t => t && !t.includes(' '))" \
  '.filter(t => t)' \
  'tags: a, b is read as a tag, where Obsidian gives the note no tags at all' \
  expect caught 'tags: a, b in node'

defect 'fm/tag-hash-once' 'obsi.sh' \
  "t.charAt(0) === '#' ? t : '#' + t" \
  "'#' + t" \
  'a frontmatter tag written as #x is read as ##x, and find, graph related and selftest all miss it'

# ---- --prop, asked of the app ----------------------------------------------------------------------

defect 'js-prop/key-present' 'obsi.sh' \
  'if (!(key in fm)) continue' \
  'if (false) continue' \
  'find --prop status lets every note through, including notes that have no status at all'

defect 'js-prop/value' 'obsi.sh' \
  'if (want !== null && [].concat(fm[key]).map(String).indexOf(want) < 0) continue' \
  'if (false) continue' \
  'find --prop status=draft lets through every note that has a status, whatever it is'

defect 'js-prop/list-items' 'obsi.sh' \
  '[].concat(fm[key]).map(String).indexOf(want)' \
  '[String(fm[key])].indexOf(want)' \
  'find --prop tags=x misses every note whose tags are a list, which is nearly all of them'

# ---- the graph, run in the app -----------------------------------------------------------------------

defect 'graph/attachments-apart' 'obsi.sh' \
  'if (!isNote(t)) { toAttachments++; continue }' \
  'if (!isNote(t)) { toAttachments++ }' \
  'an image linked from forty notes counts as a note and tops graph hubs'

defect 'graph/undirected-components' 'obsi.sh' \
  'adj[s].push(t); adj[t].push(s)' \
  'adj[s].push(t)' \
  'components follow links one way only, so a connected vault reports islands that are not there'

defect 'graph/summary-links' 'obsi.sh' \
  "['links between notes', links - toAttachments]," \
  "['links between notes', links]," \
  'graph summary counts links to attachments twice, once as links between notes'

defect 'graph/summary-largest' 'obsi.sh' \
  'sizes.sort((a, b) => b - a)' \
  'sizes.sort((a, b) => a - b)' \
  'graph summary reports the smallest component as the largest'

defect 'graph/hubs-linked-only' 'obsi.sh' \
  'for (const p in indeg) if (indeg[p] > 0) linkedTo[p] = indeg[p]' \
  'for (const p in indeg) linkedTo[p] = indeg[p]' \
  'graph hubs lists notes nothing links to, at zero, and never answers No links found'

defect 'graph/hubs-order' 'obsi.sh' \
  'map[b] - map[a] || a.localeCompare(b)' \
  'map[a] - map[b] || a.localeCompare(b)' \
  'graph hubs lists the least linked-to notes first, and its cut drops the real hubs'

defect 'graph/hubs-cut-said' 'obsi.sh' \
  'if (ranked.length > $1) lines.push('"'"'…\t'"'"' + (ranked.length - $1) + '"'"'\tmore linked-to notes'"'"')' \
  'void 0' \
  'graph hubs cuts its list in silence and reads as the complete set'

defect 'graph/ends-incoming' 'obsi.sh' \
  'const nothing = notes.filter(n => indeg[n] === 0).sort()' \
  'const nothing = notes.filter(n => outdeg[n] === 0).sort()' \
  'graph ends reports notes that link nowhere as notes nothing links to'

defect 'graph/components-largest-first' 'obsi.sh' \
  'members.sort((a, b) => b.length - a.length || a[0].localeCompare(b[0]))' \
  'members.sort((a, b) => a[0].localeCompare(b[0]))' \
  'graph components lists islands alphabetically, and its cut can drop the mainland'

defect 'graph/components-width' 'obsi.sh' \
  'const shown = group.sort().slice(0, $2)' \
  'const shown = group.sort()' \
  'one component row lists every note in it, hundreds of paths on one line'

defect 'graph/path-directed' 'obsi.sh' \
  'for (const y of fwd[x]) if (!(y in prev))' \
  'for (const y of adj[x]) if (!(y in prev))' \
  'graph path walks links backwards, and reports a path a reader clicking links could never follow'

defect 'graph/path-unknown-target' 'obsi.sh' \
  "if (!(to in indeg)) return 'Error: ' + to + ' is not a note in the graph'" \
  'void 0' \
  'a misspelt target answers No path found, as though the note existed and were unreachable'

defect 'graph/unresolved-source' 'obsi.sh' \
  'rows.push([t, s, U[s][t]])' \
  'rows.push([t, U[s][t]])' \
  'graph unresolved lists each broken link without the note it is in, the one thing it exists to add'

# ---- graph related, run in the app ------------------------------------------------------------------

defect 'related/neighbours-excluded' 'obsi.sh' \
  'const linked = new Set(fwd[target].concat(rev[target]))' \
  'const linked = new Set()' \
  'graph related fills with the notes already linked to it, which links and backlinks already answer'

defect 'related/co-cited' 'obsi.sh' \
  "for (const s of rev[target]) for (const t of fwd[s]) bump(t, 2, 'co-cited')" \
  'void 0' \
  'graph related never names co-cited notes, the strongest signal it has'

defect 'related/shares-links' 'obsi.sh' \
  "for (const t of fwd[target]) for (const s of rev[t]) bump(s, 2, 'shares-links')" \
  'void 0' \
  'graph related never names notes that point at the same things'

defect 'related/tag-ceiling' 'obsi.sh' \
  'held[t] <= ceiling' \
  'held[t] <= Infinity' \
  'a tag on a fifth of the vault puts every note carrying it on the related list, and --tag-max-notes does nothing'

defect 'related/hash-stripped' 'obsi.sh' \
  '.concat(fmTags(fm).map(t => t.slice(1)))' \
  '.concat(fmTags(fm))' \
  'a frontmatter tag never meets the same tag written inline, so graph related misses what they share' \
  expect caught 'graph related in node'

defect 'related/self-scored' 'obsi.sh' \
  'linked.add(target)' \
  'void 0' \
  'graph related lists the note itself as related to itself, through every signal it shares with itself'

defect 'related/neighbours-scored' 'obsi.sh' \
  '  if (linked.has(p) || !(p in indeg)) return' \
  '  if (!(p in indeg)) return' \
  'graph related lists the notes the target already links to or is linked from, which links and backlinks already answer'

# ---- selftest, run in the app -----------------------------------------------------------------------

defect 'selftest/ignored' 'obsi.sh' \
  'if (app.metadataCache.isUserIgnored(f.path)) continue' \
  'if (false) continue' \
  "selftest counts the vault's excluded files, which Obsidian does not, and reports drift on every vault that excludes any" \
  expect caught 'selftest in node on a vault that agrees'

defect 'selftest/invalid' 'obsi.sh' \
  'if (!valid.test(t) || numeric.test(t)) return' \
  'if (numeric.test(t)) return' \
  'selftest counts a template placeholder as a tag, and reports drift that is not there' \
  expect caught 'selftest in node on a vault that agrees'

defect 'selftest/numeric' 'obsi.sh' \
  'if (!valid.test(t) || numeric.test(t)) return' \
  'if (!valid.test(t)) return' \
  'selftest counts a number such as #123 as a tag, which Obsidian does not, and reports drift that is not there' \
  expect caught 'selftest in node on a vault that agrees'

defect 'selftest/case' 'obsi.sh' \
  'const k = t.toLowerCase()' \
  'const k = t' \
  'selftest keeps one tag spelt in two cases apart, and reports drift that is not there' \
  expect caught 'selftest in node on a vault that agrees'

defect 'selftest/parents' 'obsi.sh' \
  'if (last !== t) count(t.slice(0, t.length - last.length - 1))' \
  'void 0' \
  'selftest does not count a nested tag toward its parent, and reports drift that is not there' \
  expect caught 'selftest in node on a vault that agrees'

defect 'selftest/trailing-slash' 'obsi.sh' \
  "if (t.endsWith('/')) t = t.slice(0, -1)" \
  'void 0' \
  'selftest counts a tag written with a trailing slash as a tag of its own, and reports drift that is not there'

defect 'selftest/theirs-folded' 'obsi.sh' \
  'theirs[t.toLowerCase()] = (theirs[t.toLowerCase()] || 0) + obsidian[t]' \
  'theirs[t] = (theirs[t] || 0) + obsidian[t]' \
  'selftest reports drift whenever Obsidian keeps a merged tag in a capitalised spelling'

defect 'selftest/reports' 'obsi.sh' \
  'if (rows.length)' \
  'if (false)' \
  'selftest says the tags agree when they do not, after the Obsidian update it exists to check' \
  expect caught 'selftest in node on a vault that drifted'
