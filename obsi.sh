#!/usr/bin/env bash
# A thin wrapper over the official Obsidian CLI. It adds no commands of its own beyond the
# link graph, and passes everything else through untouched, so `obsi.sh read path=x.md` is
# `obsidian-cli read path=x.md` with the traps handled.
#
#   obsi.sh [--vault NAME] find QUERY [--name|--alias|--tag|--heading|--body]...
#                                    [--prop NAME[=VALUE]] [--limit N]
#   obsi.sh [--vault NAME] graph [hubs|ends|components|path|dump] [ARGS...]
#   obsi.sh [--vault NAME] <any CLI command and parameters...>
#
# It exists for four things the CLI leaves to every caller, each of which fails quietly:
#
#   1. An application error exits 0 and prints `Error: ` on stdout, so `set -e`, `if cmd`
#      and `2>/dev/null` all miss it. Every call here is checked and given a real status
#   2. The CLI reads stdin, so `while read f; do obsidian-cli … ; done < list` runs once
#      and looks like it ran to the end. Every call here is given </dev/null
#   3. The client is `obsidian-cli` on some installs and `obsidian` on others, and on the
#      latter that name may be the GUI launcher, which opens a window instead of answering
#   4. The whole link graph is about 1 MB of JSON for 1300 notes. Printing it into an
#      agent's context costs more than every other command in this skill together, so
#      nothing here prints it: the graph is walked inside the app and only the answer
#      comes back. `graph dump` is the one way to get all of it, and it writes to a file
#
# The graph is `app.metadataCache.resolvedLinks`, which is what Obsidian itself draws, so
# it inherits that index's limits: anchors are dropped, links inside code fences do not
# exist, a link written through an alias is unresolved rather than an edge, and unlinked
# mentions are absent entirely. See references/pitfalls.md before trusting a count
#
# Needs: bash 3.2, base64, and a running Obsidian 1.12+. Nothing else
set -euo pipefail

die() {
  printf 'obsi: %s\n' "$1" >&2
  exit 1
}

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---- reaching the app -----------------------------------------------------------------

# The name is tried before the GUI launcher's, because asking the wrong one for its version
# opens a window rather than answering. $OBSIDIAN_CLI wins over both, for installs that
# ship it under a third name
find_cli() {
  local candidate answer unreachable=""
  for candidate in ${OBSIDIAN_CLI:+"$OBSIDIAN_CLI"} obsidian-cli obsidian; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    answer=$("$candidate" version </dev/null 2>&1)
    # A client that is installed and cannot reach the app is a different problem from no
    # client at all, and telling someone to install what they already have sends them the
    # wrong way. Remembered rather than reported at once, so a later candidate can still win
    case "$answer" in
      *"unable to find Obsidian"*)
        unreachable="$candidate"
        continue
        ;;
    esac
    case "$answer" in
      [0-9]*.[0-9]*)
        printf '%s\n' "$candidate"
        return 0
        ;;
    esac
  done
  [[ -z "$unreachable" ]] ||
    die "$unreachable is installed, but Obsidian is not running — the CLI is a client to the app, not a vault reader"
  die "no Obsidian CLI answered a version. Install one, or point \$OBSIDIAN_CLI at it"
}

bin=""
# A vault name may contain spaces — `Obsidian Sandbox` does — so the prefix travels as an
# array. Unquoted ${vault:+…} would hand the CLI two arguments and it would ignore both
prefix=()

# cli ARGS... -> the command's stdout, with an application error turned into exit 1
cli() {
  local out status
  set +e
  out=$("$bin" ${prefix[@]+"${prefix[@]}"} "$@" </dev/null 2>&1)
  status=$?
  set -e
  case "$out" in
    "Error: "*) die "${out#Error: }" ;;
  esac
  ((status == 0)) || die "$out"
  printf '%s\n' "$out"
}

# js CODE -> what the app returned, without eval's `=> ` prefix. Newlines in CODE are fine;
# what matters is that the shell hands it over as a single argument
#
# The prefix check is repeated on the stripped value on purpose: a refusal raised by the
# JavaScript arrives as `=> Error: …`, which the CLI itself considers a successful call.
# Without this the wrapper would print an error and exit 0, which is the exact failure it
# exists to prevent
js() {
  local out
  out=$(cli eval code="$1")
  out="${out#"=> "}"
  case "$out" in
    "Error: "*) die "${out#Error: }" ;;
  esac
  printf '%s\n' "$out"
}

# b64 STRING -> base64 with no line breaks, so any path can be embedded in the JavaScript
# above without quoting or escaping it. `-w0` is GNU-only, hence the tr
b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

# The other half of that trick, for the JavaScript side. A vault's paths, aliases and
# headings are ordinary text: quotes, commas, apostrophes and non-ASCII all appear in them,
# and every one of those breaks a value spliced into a shell-quoted string
decoder() {
  cat <<'JS'
const decode = s => new TextDecoder().decode(Uint8Array.from(atob(s), c => c.charCodeAt(0)))
JS
}

# ---- finding a note ----------------------------------------------------------------------

# allowed_by_prop NAME[=VALUE] -> every note whose frontmatter satisfies it, one per line
allowed_by_prop() {
  js "(() => {
$(decoder)
const filter = decode('$(b64 "$1")')
const eq = filter.indexOf('=')
const key = eq < 0 ? filter : filter.slice(0, eq)
const want = eq < 0 ? null : filter.slice(eq + 1)
const out = []
for (const f of app.vault.getMarkdownFiles()) {
  const fm = (app.metadataCache.getFileCache(f) || {}).frontmatter || {}
  if (!(key in fm)) continue
  if (want !== null && [].concat(fm[key]).map(String).indexOf(want) < 0) continue
  out.push(f.path)
}
return out.join('\n')
})()"
}

# `search` already finds all of this. Measured on notes planted with unique nonsense words:
# it matches the filename, an alias, a property value, a heading and a tag, because it looks
# at the file's text and the frontmatter is part of that text. So this is not an alternative
# to `search` — it runs `search` and adds the two things `search` structurally cannot do:
#
#   * say WHERE the match was. `search query=unicast` returns 6 bare paths; two of those
#     notes answer to that name and four merely contain the word, and nothing in the output
#     separates them
#   * be restricted to one field. `--alias` returns those two and nothing else, which is a
#     question the command set cannot express at all
#
# Scores are deliberately coarse: an exact name or alias outranks a partial one, a partial
# name outranks a tag, and a body match is worth one point. The ranking is a convenience;
# the reason column is the point, because it makes a wrong hit visible rather than plausible
find_notes() {
  local query="$1" limit="$2" markers="$3" prop="$4" body meta

  meta=$(js "(() => {
$(decoder)
const q = decode('$(b64 "$query")').toLowerCase()
const markers = decode('$(b64 "$markers")').split(' ')
const propFilter = decode('$(b64 "$prop")')
const on = m => markers.indexOf(m) >= 0
const hits = {}
const add = (p, score, kind, detail) => {
  const h = hits[p] || (hits[p] = { score: 0, kinds: [], detail: '' })
  h.score += score
  if (h.kinds.indexOf(kind) < 0) h.kinds.push(kind)
  if (!h.detail) h.detail = detail || ''
}
const has = s => String(s).toLowerCase().indexOf(q) >= 0
const is = s => String(s).toLowerCase() === q
for (const f of app.vault.getMarkdownFiles()) {
  const c = app.metadataCache.getFileCache(f) || {}
  const fm = c.frontmatter || {}
  if (propFilter) {
    const eq = propFilter.indexOf('=')
    const key = eq < 0 ? propFilter : propFilter.slice(0, eq)
    if (!(key in fm)) continue
    if (eq >= 0 && [].concat(fm[key]).map(String).indexOf(propFilter.slice(eq + 1)) < 0) continue
  }
  if (on('name')) {
    if (is(f.basename)) add(f.path, 10, 'name', f.basename)
    else if (has(f.basename)) add(f.path, 6, 'name', f.basename)
  }
  if (on('alias')) for (const a of [].concat(fm.aliases || [])) {
    if (!a) continue
    if (is(a)) add(f.path, 9, 'alias', String(a))
    else if (has(a)) add(f.path, 5, 'alias', String(a))
  }
  if (on('tag')) {
    const tags = (c.tags || []).map(t => t.tag).concat([].concat(fm.tags || []).map(t => '#' + t))
    for (const t of tags) if (t && has(t)) add(f.path, 4, 'tag', String(t))
  }
  if (on('prop')) for (const k in fm) {
    if (k === 'aliases' || k === 'tags') continue
    for (const v of [].concat(fm[k])) if (v && has(v)) add(f.path, 4, 'prop', k + '=' + v)
  }
  if (on('heading')) for (const h of c.headings || []) if (has(h.heading)) add(f.path, 3, 'heading', h.heading)
}
return Object.keys(hits).map(p => [hits[p].score, hits[p].kinds.join('+'), p, hits[p].detail].join('\t')).join('\n')
})()")

  body=""
  if [[ "$markers" == *body* ]]; then
    body=$(cli search query="$query" limit="$((limit * 3))")
    [[ "$body" == "No matches found." ]] && body=""
    # `search` knows nothing about --prop, so without this the filter would quietly apply
    # to half the results and the other half would arrive unfiltered
    if [[ -n "$prop" && -n "$body" ]]; then
      body=$(printf '%s\n' "$body" | grep -Fxf <(allowed_by_prop "$prop") || true)
    fi
  fi

  # Two sources, one row per note: scores add up and the reasons are collected, so a note
  # that matches by alias and by body outranks one that only appears in the text
  local ranked
  ranked=$(awk -F'\t' -v OFS='\t' '
    FNR == NR { if (NF >= 3) { s[$3] += $1; k[$3] = k[$3] (k[$3] ? "+" : "") $2; if (d[$3] == "") d[$3] = $4 } ; next }
    $0 != "" { s[$0] += 1; k[$0] = k[$0] (k[$0] ? "+" : "") "body" }
    END { for (p in s) print s[p], k[p], p, d[p] }
  ' <(printf '%s\n' "$meta") <(printf '%s\n' "$body") |
    sort -t"$(printf '\t')" -k1,1nr -k3,3)

  # An empty result is a sentence rather than empty output, the way every listing in the
  # CLI answers it. Empty output and a failure would otherwise look the same to a caller
  if [[ -z "$ranked" ]]; then
    echo "No matches found."
    return
  fi

  # What is cut off has to be said out loud. A common tag matches hundreds of notes at the
  # same score — 649 carry `конспекты` on the vault measured — so a silent `head` turns
  # "these are the notes with that tag" into a sentence that is confidently wrong, and the
  # ordering among equal scores is alphabetical, which is to say arbitrary
  #
  # `head` is not the tool for it: it stops reading, `printf` takes SIGPIPE, and under
  # `set -o pipefail` the whole script dies at 141 before this notice is ever printed —
  # which is how the truncation stayed invisible in the first place. awk reads to the end
  local total
  total=$(printf '%s\n' "$ranked" | wc -l | tr -d ' ')
  printf '%s\n' "$ranked" | awk -v n="$limit" 'NR <= n'
  if ((total > limit)); then
    printf '…\t%s more matches at or below this score, raise --limit to see them\n' \
      "$((total - limit))"
  fi
}

# ---- the graph -------------------------------------------------------------------------

# Shared by every graph query: the adjacency the app already holds, reduced to notes.
# Attachments are counted but left out of the walk — an image linked from forty notes is
# not a hub, it is an image
graph_prelude() {
  decoder
  cat <<'JS'
const R = app.metadataCache.resolvedLinks, U = app.metadataCache.unresolvedLinks
const isNote = p => p.endsWith(".md") || p.endsWith(".canvas")
const indeg = {}, outdeg = {}, fwd = {}, adj = {}
const touch = p => {
  if (!(p in indeg)) { indeg[p] = 0; outdeg[p] = 0; fwd[p] = []; adj[p] = [] }
}
let links = 0, toAttachments = 0, unresolved = 0
for (const s in R) {
  touch(s)
  for (const t in R[s]) {
    links++
    if (!isNote(t)) { toAttachments++; continue }
    touch(t)
    outdeg[s]++; indeg[t]++
    fwd[s].push(t); adj[s].push(t); adj[t].push(s)
  }
}
for (const s in U) unresolved += Object.keys(U[s]).length
const notes = Object.keys(indeg)
const components = () => {
  const seen = new Set(), sizes = [], members = []
  for (const n of notes) {
    if (seen.has(n)) continue
    const stack = [n], group = []
    seen.add(n)
    while (stack.length) {
      const x = stack.pop()
      group.push(x)
      for (const y of adj[x]) if (!seen.has(y)) { seen.add(y); stack.push(y) }
    }
    sizes.push(group.length); members.push(group)
  }
  return { sizes, members }
}
const top = (map, n) => Object.keys(map).sort((a, b) => map[b] - map[a] || a.localeCompare(b)).slice(0, n)
JS
}

graph_summary() {
  js "(() => {
$(graph_prelude)
const { sizes } = components()
sizes.sort((a, b) => b - a)
const rows = [
  ['notes', notes.length],
  ['links between notes', links - toAttachments],
  ['links to attachments', toAttachments],
  ['unresolved links', unresolved],
  ['nothing links to them', notes.filter(n => indeg[n] === 0).length],
  ['they link nowhere', notes.filter(n => outdeg[n] === 0).length],
  ['connected components', sizes.length],
  ['largest component', sizes[0] || 0]
]
return rows.map(r => r[0] + '\t' + r[1]).join('\n')
})()"
}

graph_hubs() {
  js "(() => {
$(graph_prelude)
return top(indeg, $1).map(p => indeg[p] + '\t' + p).join('\n') || 'No links found.'
})()"
}

graph_ends() {
  js "(() => {
$(graph_prelude)
const nothing = notes.filter(n => indeg[n] === 0).sort()
const nowhere = notes.filter(n => outdeg[n] === 0).sort()
const show = (label, list) =>
  list.slice(0, $1).map(p => label + '\t' + p).join('\n') +
  (list.length > $1 ? '\n' + label + '\t… and ' + (list.length - $1) + ' more' : '')
return [show('no-incoming', nothing), show('no-outgoing', nowhere)].filter(Boolean).join('\n')
})()"
}

# Every component, largest first, rather than "the islands". Calling the biggest one the
# mainland and hiding it is a judgement the data does not support: a vault that has split
# into halves of 600 would report one of them as an island and say nothing about choosing.
# Here the first row is whatever the mainland is, its size is visible, and what is cut off
# is every row after it
#
# Both dimensions are bounded, because a component is a listing like any other: a hundred
# note paths joined onto one line is the same runaway output rule 3 exists to prevent
graph_components() {
  js "(() => {
$(graph_prelude)
const { members } = components()
if (!members.length) return 'No notes found.'
members.sort((a, b) => b.length - a.length || a[0].localeCompare(b[0]))
const lines = []
for (const group of members.slice(0, $1)) {
  const shown = group.sort().slice(0, $2)
  const more = group.length > $2 ? ' | … and ' + (group.length - $2) + ' more' : ''
  lines.push(group.length + '\t' + shown.join(' | ') + more)
}
if (members.length > $1) lines.push('…\t' + (members.length - $1) + ' more components')
return lines.join('\n')
})()"
}

# A shortest path along links as they are written, not as a graph drawing would show them:
# following a link is directed, and a note reachable only backwards is not reachable
graph_path() {
  js "(() => {
$(graph_prelude)
const from = decode('$(b64 "$1")'), to = decode('$(b64 "$2")')
if (!(from in indeg)) return 'Error: ' + from + ' is not a note in the graph'
if (!(to in indeg)) return 'Error: ' + to + ' is not a note in the graph'
const prev = { [from]: null }
const queue = [from]
while (queue.length) {
  const x = queue.shift()
  if (x === to) break
  for (const y of fwd[x]) if (!(y in prev)) { prev[y] = x; queue.push(y) }
}
if (!(to in prev)) return 'No path found.'
const path = []
for (let x = to; x !== null; x = prev[x]) path.push(x)
return path.reverse().join('\n')
})()"
}

# The only way to get the whole graph, and it goes to a file. What lands there is exactly
# `resolvedLinks`: an object of source path to an object of target path to link count
graph_dump() {
  local target="$1" out
  : >"$target" || die "cannot write to $target"
  out=$(js '(() => JSON.stringify(app.metadataCache.resolvedLinks))()')
  printf '%s\n' "$out" >"$target"
  printf 'wrote %s bytes to %s\n' "$(wc -c <"$target" | tr -d ' ')" "$target"
}

graph() {
  local what="${1:-summary}"
  [[ $# -eq 0 ]] || shift
  case "$what" in
    summary) graph_summary ;;
    hubs) graph_hubs "${1:-10}" ;;
    ends) graph_ends "${1:-10}" ;;
    components) graph_components "${1:-10}" "${2:-5}" ;;
    path)
      [[ $# -eq 2 ]] || die "graph path needs two note paths, exactly as the vault spells them"
      graph_path "$1" "$2"
      ;;
    dump)
      [[ $# -le 1 ]] || die "graph dump takes one file, or none for graph.json"
      graph_dump "${1:-graph.json}"
      ;;
    *) die "unknown graph query '$what' — try: summary, hubs, ends, components, path, dump" ;;
  esac
}

# ---- arguments ---------------------------------------------------------------------------

while (($#)); do
  case "$1" in
    --vault)
      prefix=("vault=${2:?--vault needs a name}")
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) break ;;
  esac
done
(($#)) || {
  usage >&2
  exit 2
}

bin=$(find_cli)

case "$1" in
  find)
    shift
    (($#)) || die "find needs something to look for"
    query="$1"
    shift
    limit=20
    prop=""
    markers=""
    while (($#)); do
      case "$1" in
        --name | --alias | --tag | --heading | --body)
          markers="$markers ${1#--}"
          shift
          ;;
        --prop)
          prop="${2:?--prop needs NAME or NAME=VALUE}"
          shift 2
          ;;
        --limit)
          limit="${2:?--limit needs a number}"
          shift 2
          ;;
        *) die "unknown option '$1' — try --name --alias --tag --heading --body --prop --limit" ;;
      esac
    done
    if ! [[ "$limit" =~ ^[1-9][0-9]*$ ]]; then
      die "--limit takes a positive number, not '$limit'"
    fi
    # Naming no marker means all of them, which is what someone who just wants the note
    # expects. Naming one narrows to it, and the `prop` marker is only ever on by default:
    # asked for explicitly it is a filter, not a thing to match the query against
    [[ -n "$markers" ]] || markers=" name alias tag prop heading body"
    find_notes "$query" "$limit" "${markers# }" "$prop"
    ;;
  graph)
    shift
    graph "$@"
    ;;
  *) cli "$@" ;;
esac
