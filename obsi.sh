#!/usr/bin/env bash
# Needs bash 3.2 and POSIX tools only
set -euo pipefail

# A nix dev shell exports $out, the build's output path, and bash keeps that export on a
# local of the same name: an answer held in `out` then went into the environment of every
# command run after it, and past 128 KB exec refused with "Argument list too long". The
# script's own names are its own, so whatever the caller exported under them is not
export -n out err

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

die() {
  printf 'obsi: %s\n' "$1" >&2
  exit 1
}

# usage_error MESSAGE -> exit 2. Asked wrongly is a different failure from an answer that
# says no, and a caller branching on the status has to tell a typo from a missing note
usage_error() {
  printf 'obsi: %s\n' "$1" >&2
  exit 2
}

# need_count VALUE... -> nothing, or exit. Every count here is spliced into JavaScript that
# runs inside the live app, so anything but a plain positive integer is refused before any
# of it is built. Unchecked, `graph hubs app` answered "No links found." at exit 0 — `app`
# is a name in that scope, coerced to zero rows — and a crafted value ran as code with the
# app's full access to the vault. One validator, so no count can be left out of it
need_count() {
  local value
  for value in "$@"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || usage_error "expected a positive number, not '$value'"
  done
}

usage() {
  cat <<'EOF'
A thin wrapper over the official Obsidian CLI. It adds no commands of its own beyond the
link graph, and passes everything else through untouched, so `obsi.sh read path=x.md` is
`obsidian-cli read path=x.md` with the traps handled

  obsi.sh [--vault NAME] find QUERY [--name|--alias|--tag|--heading|--body|--value]...
                                   [--prop NAME[=VALUE]] [--limit N]
  obsi.sh [--vault NAME] graph [summary|hubs|ends|components|related|unresolved|path|dump] [ARGS…]
  obsi.sh [--vault NAME] selftest
  obsi.sh [--vault NAME] <any CLI command and parameters...>

The CLI fails quietly in several ways, and each is absorbed here rather than left to every
caller. What they are, why each is handled the way it is, and the measurements behind both
are in references/obsi.md, and not repeated here

Nothing here reaches the network; it needs a running Obsidian 1.12+ to talk to.
Exit 0 done, 1 when the CLI or the vault answered with an error, 2 on a usage error
EOF
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
    # wrong way. It also ends the search: the app being down is true for every client, and
    # probing on reaches `obsidian`, which on a packaged install is the GUI launcher — the
    # one call this loop exists to avoid, since it opens a window instead of answering
    case "$answer" in
      *"unable to find Obsidian"*)
        unreachable="$candidate"
        break
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
  local out status err
  set +e
  out=$("$bin" ${prefix[@]+"${prefix[@]}"} "$@" </dev/null 2>"$scratch/stderr")
  status=$?
  set -e
  err=$(cat "$scratch/stderr")
  case "$out" in
    "Error: "*) die "${out#Error: }" ;;
  esac
  ((status == 0)) || die "$(printf '%s\n%s\n' "$out" "$err" | sed '/^$/d')"
  # The client's stderr is its diagnostics, never part of its answer. Captured together with
  # stdout, a runtime warning would land inside whatever the caller parses — a dumped graph
  # included — so it is passed on to stderr instead
  [[ -z "$err" ]] || printf '%s\n' "$err" >&2
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

# Obsidian's own reading of `tags` and `aliases`, copied from its bundle (1.13.4:
# parseFrontMatterStringArray, parseFrontMatterAliases, parseFrontMatterTags), because the
# eval scope cannot require the module that exports them. A string is ONE item and is never
# split on commas — `aliases: x, y` is one alias named "x, y" — a list is taken item by item,
# so "Smith, John" as a list item stays whole, items that are not strings are dropped, a
# tag holding a space is no tag at all, and the key matches in any case
fm_lists() {
  cat <<'JS'
const fmList = (fm, re) => {
  let v = null
  for (const k in fm || {}) if (Object.prototype.hasOwnProperty.call(fm, k) && re.test(k)) { v = fm[k]; break }
  if (!v) return []
  if (typeof v === 'string') return [v.trim()]
  return Array.isArray(v) ? v.filter(x => typeof x === 'string').map(x => x.trim()) : []
}
const fmAliases = fm => fmList(fm, /^aliases$/i).filter(Boolean)
const fmTags = fm => fmList(fm, /^tags$/i).filter(t => t && !t.includes(' ')).map(t => t.charAt(0) === '#' ? t : '#' + t)
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
# to `search` — it runs `search` and adds what `search` structurally cannot do:
#
#   * say WHERE the match was. `search query=coastline` returns 6 bare paths; two of those
#     notes answer to that name and four merely contain the word, and nothing in the output
#     separates them
#   * be restricted to one field. `--alias` returns those two and nothing else, which is a
#     question the command set cannot express at all
#
# Scores are deliberately coarse: an exact name or alias outranks a partial one, a partial
# name outranks a tag, and a body match is worth one point. The ranking is a convenience;
# the reason column is the point, because it makes a wrong hit visible rather than plausible
find_notes() {
  local query="$1" limit="$2" markers="$3" prop="$4" scope="$5" body meta

  meta=$(js "(() => {
$(decoder)
$(fm_lists)
const q = decode('$(b64 "$query")').toLowerCase()
const markers = decode('$(b64 "$markers")').split(' ')
const scope = decode('$(b64 "$scope")')
const on = m => markers.indexOf(m) >= 0
const hits = {}
// --prop is not applied here: the same predicate would then exist in two places and could
// drift apart, which is how it once filtered the index half and left the body half alone.
// It is asked once, of allowed_by_prop, and applied to both streams outside
// A field scores once per note, at its best match. Summing inside a field let four matching
// headings (4 x 3) outrank an exact filename (10), and a tag both inline and in frontmatter
// count twice — the opposite of the ranking the documentation promises
const add = (p, score, kind, detail) => {
  const h = hits[p] || (hits[p] = { best: {}, kinds: [], detail: '' })
  if (!(kind in h.best)) {
    h.kinds.push(kind)
    h.best[kind] = score
  } else if (score > h.best[kind]) h.best[kind] = score
  if (!h.detail) h.detail = detail || ''
}
const has = s => String(s).toLowerCase().indexOf(q) >= 0
const is = s => String(s).toLowerCase() === q
for (const f of app.vault.getMarkdownFiles()) {
  const c = app.metadataCache.getFileCache(f) || {}
  const fm = c.frontmatter || {}
  if (on('name')) {
    if (is(f.basename)) add(f.path, 10, 'name', f.basename)
    else if (has(f.basename)) add(f.path, 6, 'name', f.basename)
  }
  if (on('alias')) for (const a of fmAliases(fm)) {
    if (is(a)) add(f.path, 9, 'alias', a)
    else if (has(a)) add(f.path, 5, 'alias', a)
  }
  if (on('tag')) {
    const tags = (c.tags || []).map(t => t.tag).concat(fmTags(fm))
    for (const t of tags) if (t && has(t)) add(f.path, 4, 'tag', String(t))
  }
  // With a scope — --value beside --prop NAME — only that property's values count; without
  // one every property does, except the two the alias and tag markers already read
  if (on('prop')) for (const k in fm) {
    if (scope ? k !== scope : /^(aliases|tags)$/i.test(k)) continue
    for (const v of [].concat(fm[k])) if (v && has(v)) add(f.path, 4, 'prop', k + '=' + v)
  }
  if (on('heading')) for (const h of c.headings || []) if (has(h.heading)) add(f.path, 3, 'heading', h.heading)
}
return Object.keys(hits).map(p => {
  const h = hits[p]
  const score = h.kinds.reduce((sum, k) => sum + h.best[k], 0)
  return [score, h.kinds.join('+'), p, h.detail].join('\t')
}).join('\n')
})()")

  # `search` matches the file's whole text, frontmatter included, so what it contributes is
  # reported as `text`, not `body`: calling it body put `alias+body` on notes whose body
  # never contained the word. It is also capped, and a capped search makes any count of what
  # was left out a floor rather than a number
  body=""
  local capped=""
  if [[ "$markers" == *body* ]]; then
    body=$(cli search query="$query" limit="$((limit * 3))")
    [[ "$body" == "No matches found." ]] && body=""
    if [[ -n "$body" ]] && (($(printf '%s\n' "$body" | wc -l) >= limit * 3)); then
      capped=1
    fi
  fi

  # One predicate, asked once, applied to both streams. `search` knows nothing about --prop,
  # and the index query is no longer allowed to know either: a filter written in two places
  # drifts, and the last time it did, half the results came back unfiltered
  if [[ -n "$prop" ]]; then
    local allow="$scratch/allowed.txt"
    allowed_by_prop "$prop" >"$allow"
    if [[ ! -s "$allow" ]]; then
      echo "No matches found."
      return
    fi
    meta=$(printf '%s\n' "$meta" | awk -F'\t' 'NR == FNR { a[$0]; next } $3 in a' "$allow" -)
    [[ -z "$body" ]] ||
      body=$(printf '%s\n' "$body" | grep -Fxf "$allow" || true)
  fi

  # Two sources, one row per note: scores add up and the reasons are collected, so a note
  # that matches by alias and by body outranks one that only appears in the text
  local ranked
  ranked=$(awk -F'\t' -v OFS='\t' '
    FNR == NR { if (NF >= 3) { s[$3] += $1; k[$3] = k[$3] (k[$3] ? "+" : "") $2; if (d[$3] == "") d[$3] = $4 } ; next }
    $0 != "" { s[$0] += 1; k[$0] = k[$0] (k[$0] ? "+" : "") "text" }
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
  # same score — 649 carried one tag on the vault measured — so a silent cut turns "these
  # are the notes with that tag" into a sentence that is confidently wrong, and the ordering
  # among equal scores is alphabetical, which is to say arbitrary
  #
  # `head` is not the tool for it: it stops reading, `printf` takes SIGPIPE, and under
  # `set -o pipefail` the whole script dies at 141 before this notice is ever printed —
  # which is how the truncation stayed invisible in the first place. awk reads to the end
  local total
  total=$(printf '%s\n' "$ranked" | wc -l | tr -d ' ')
  printf '%s\n' "$ranked" | awk -v n="$limit" 'NR <= n'
  if ((total > limit)); then
    printf '…\t%s%s more matches at or below this score, raise --limit to see them\n' \
      "${capped:+at least }" "$((total - limit))"
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
const indeg = {}, outdeg = {}, fwd = {}, rev = {}, adj = {}
const touch = p => {
  if (!(p in indeg)) { indeg[p] = 0; outdeg[p] = 0; fwd[p] = []; rev[p] = []; adj[p] = [] }
}
let links = 0, toAttachments = 0, unresolved = 0
for (const s in R) {
  touch(s)
  for (const t in R[s]) {
    links++
    if (!isNote(t)) { toAttachments++; continue }
    touch(t)
    outdeg[s]++; indeg[t]++
    fwd[s].push(t); rev[t].push(s); adj[s].push(t); adj[t].push(s)
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
const linkedTo = {}
for (const p in indeg) if (indeg[p] > 0) linkedTo[p] = indeg[p]
const ranked = top(linkedTo, Infinity)
if (!ranked.length) return 'No links found.'
const lines = ranked.slice(0, $1).map(p => indeg[p] + '\t' + p)
if (ranked.length > $1) lines.push('…\t' + (ranked.length - $1) + '\tmore linked-to notes')
return lines.join('\n')
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
const out = [show('no-incoming', nothing), show('no-outgoing', nowhere)].filter(Boolean).join('\n')
return out || (notes.length ? 'Every note has a link in and a link out.' : 'No notes found.')
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

# What a note is related to without being linked to it. Direct neighbours are deliberately
# excluded: `links` and `backlinks` already answer those, and what is wanted here is the
# connection that exists in the vault without an edge to show for it
#
#   co-cited        something links to this note and to that one — the strongest signal,
#                   because a third party put them in the same context
#   shares-links    both notes point at the same things, which is the same argument read
#                   from the other end
#   tag             they carry a tag in common, which is weaker: a tag on 649 notes says
#                   almost nothing, so a tag is worth a point against co-citation's two
#
# Unlinked mentions — a note naming this one in prose without a wikilink — are NOT here.
# `metadataCache` does not hold them, and the substitute is one `search` per name and
# alias, which is approximate and belongs to whatever reads the vault's text directly
graph_related() {
  js "(() => {
$(graph_prelude)
$(fm_lists)
const target = decode('$(b64 "$1")')
if (!(target in indeg)) return 'Error: ' + target + ' is not a note in the graph'
const linked = new Set(fwd[target].concat(rev[target]))
linked.add(target)
const score = {}, why = {}
const bump = (p, n, kind) => {
  if (linked.has(p) || !(p in indeg)) return
  score[p] = (score[p] || 0) + n
  why[p] = why[p] || []
  if (why[p].indexOf(kind) < 0) why[p].push(kind)
}
for (const s of rev[target]) for (const t of fwd[s]) bump(t, 2, 'co-cited')
for (const t of fwd[target]) for (const s of rev[t]) bump(s, 2, 'shares-links')
const tagsOf = f => {
  const c = app.metadataCache.getFileCache(f) || {}
  const fm = c.frontmatter || {}
  return (c.tags || []).map(t => String(t.tag).replace(/^#/, ''))
    .concat(fmTags(fm).map(t => t.slice(1)))
}
const file = app.vault.getAbstractFileByPath(target)
const mine = new Set(file ? tagsOf(file) : [])
if (mine.size) {
  // A tag counts only while it still distinguishes anything. One carried by a fifth of the
  // vault is a category — a course, a year, a note type — and sharing it says nothing, so
  // it would otherwise put every note in the vault on this list at one point each.
  // --tag-max-notes sets that number; -1 here means the default, a twentieth of the vault
  const files = app.vault.getMarkdownFiles()
  const asked = $3
  const ceiling = asked >= 0 ? asked : Math.max(5, Math.floor(files.length * 0.05))
  const held = {}
  for (const f of files) for (const t of tagsOf(f)) if (mine.has(t)) held[t] = (held[t] || 0) + 1
  const telling = new Set(Object.keys(held).filter(t => held[t] <= ceiling))
  if (telling.size) {
    for (const f of files) {
      if (f.path === target) continue
      for (const t of tagsOf(f)) if (telling.has(t)) { bump(f.path, 1, 'tag'); break }
    }
  }
}
const ranked = Object.keys(score).sort((a, b) => score[b] - score[a] || a.localeCompare(b))
if (!ranked.length) return 'No related notes found.'
const lines = ranked.slice(0, $2).map(p => score[p] + '\t' + why[p].join('+') + '\t' + p)
if (ranked.length > $2) lines.push('…\t' + (ranked.length - $2) + '\tmore related notes')
return lines.join('\n')
})()"
}

# Broken links as pairs. The first-party `unresolved` already lists them; what it cannot do
# is say which file each one came from, because it joins every source into a single field
# with `, ` and vault paths contain commas. One row per pair leaves nothing to parse
graph_unresolved() {
  js "(() => {
$(graph_prelude)
const rows = []
for (const s in U) for (const t in U[s]) rows.push([t, s, U[s][t]])
if (!rows.length) return 'No unresolved links found.'
rows.sort((a, b) => a[0].localeCompare(b[0]) || a[1].localeCompare(b[1]))
const lines = rows.slice(0, $1).map(r => r.join('\t'))
if (rows.length > $1) lines.push('…\t' + (rows.length - $1) + '\tmore pairs')
return lines.join('\n')
})()"
}

# The only way to get the whole graph, and it goes to a file. What lands there is exactly
# `resolvedLinks`: an object of source path to an object of target path to link count
graph_dump() {
  local target="$1" dir tmp out
  dir=$(dirname -- "$target")
  # Asked before the query rather than by emptying the file: truncating it first meant a
  # query that failed — an app that was down — left an existing graph.json empty
  [[ -d "$dir" && -w "$dir" && (! -e "$target" || -w "$target") ]] ||
    die "cannot write to $target"
  out=$(js '(() => JSON.stringify(app.metadataCache.resolvedLinks))()')
  # Written beside the target and moved over it, so the file holds the old graph or the whole
  # new one, never an empty or a half-written one
  tmp=$(mktemp "$dir/.obsi-dump.XXXXXX") || die "cannot write to $target"
  if ! { printf '%s\n' "$out" >"$tmp" && mv -f -- "$tmp" "$target"; }; then
    rm -f -- "$tmp"
    die "cannot write to $target"
  fi
  printf 'wrote %s bytes to %s\n' "$(wc -c <"$target" | tr -d ' ')" "$target"
}

# answer QUERY ARGS... -> the query's reply, or exit. Every graph query answers with rows or
# with a sentence; an empty reply printed as a blank line at exit 0 would read like an answer
answer() {
  local out
  out=$("$@")
  [[ -n "$out" ]] || die "the app answered nothing to $1 — every graph query answers with rows or a sentence"
  printf '%s\n' "$out"
}

graph() {
  local what="${1:-summary}"
  [[ $# -eq 0 ]] || shift
  case "$what" in
    summary) answer graph_summary ;;
    hubs)
      need_count "${1:-10}"
      answer graph_hubs "${1:-10}"
      ;;
    ends)
      need_count "${1:-10}"
      answer graph_ends "${1:-10}"
      ;;
    components)
      need_count "${1:-10}" "${2:-5}"
      answer graph_components "${1:-10}" "${2:-5}"
      ;;
    unresolved)
      need_count "${1:-40}"
      answer graph_unresolved "${1:-40}"
      ;;
    related)
      [[ $# -ge 1 ]] || usage_error "graph related needs a note path, exactly as the vault spells it"
      related_note="$1"
      shift
      related_rows=10
      related_tags=""
      while (($#)); do
        case "$1" in
          --tag-max-notes)
            (($# >= 2)) || usage_error "--tag-max-notes needs a number: how many notes a tag may be on and still count as a signal, 0 to ignore tags entirely"
            related_tags="$2"
            shift 2
            ;;
          # An unrecognised flag must not be swallowed as a row count. Taking it silently is
          # the CLI's own habit — the one this wrapper exists to stop — and it turned
          # `--tags 0` into "show zero rows" without a word
          -*) usage_error "unknown option '$1' — graph related takes a row count and --tag-max-notes" ;;
          *)
            related_rows="$1"
            shift
            ;;
        esac
      done
      need_count "$related_rows"
      # Spliced into the JavaScript as a literal, so a leading zero is refused with the rest:
      # `010` there is octal in the app's sloppy-mode scope and means 8. -1 is this script's
      # own sentinel for the default and is set below, never taken from a caller
      if [[ -n "$related_tags" ]]; then
        [[ "$related_tags" =~ ^(0|[1-9][0-9]*)$ ]] ||
          usage_error "--tag-max-notes takes zero or a positive number, not '$related_tags'"
      else
        related_tags=-1
      fi
      answer graph_related "$related_note" "$related_rows" "$related_tags"
      ;;
    path)
      [[ $# -eq 2 ]] || usage_error "graph path needs two note paths, exactly as the vault spells them"
      answer graph_path "$1" "$2"
      ;;
    dump)
      [[ $# -le 1 ]] || usage_error "graph dump takes one file, or none for graph.json"
      graph_dump "${1:-graph.json}"
      ;;
    *) usage_error "unknown graph query '$what' — see obsi.sh --help" ;;
  esac
}

# ---- checking the copy against Obsidian ----------------------------------------------------

# fm_lists is a copy, and a copy drifts when Obsidian changes. The one answer from Obsidian's
# own reading that reaches eval is metadataCache.getTags(): the vault's tag counts as the tag
# pane shows them. selftest sums the same counts from what find and graph related read — the
# frontmatter through fm_lists, plus the inline tags — and names every tag whose count
# differs. Run after an Obsidian update: a difference means this copy, or getTags' own
# counting rules below, no longer match the Obsidian that is running
selftest_js() {
  cat <<'JS'
// getTags' counting rules, copied from Obsidian 1.13.4 (MetadataCache.getTags and the tag
// check it calls): excluded files are skipped, every occurrence counts, a nested tag counts
// toward each parent, a tag the check refuses counts for nothing, and spellings that differ
// only in case are one tag. The spelling Obsidian keeps for a merged tag depends on its own
// file order, so tags are compared case-folded rather than by spelling. The class below
// opens with two ranges written as characters, U+2000–U+206F and U+2E00–U+2E7F — general
// and supplemental punctuation — exactly as Obsidian's own source spells them with \u
const valid = new RegExp(/^#[^ -⁯⸀-⹿'!"#$%&()*+,.:;<=>?@^`{|}~\[\]\\\s]+/.source + '$')
const numeric = /^#\d+$/
const ours = {}
const count = t => {
  if (t.endsWith('/')) t = t.slice(0, -1)
  if (!valid.test(t) || numeric.test(t)) return
  const k = t.toLowerCase()
  ours[k] = (ours[k] || 0) + 1
  const last = t.split('/').pop()
  if (last !== t) count(t.slice(0, t.length - last.length - 1))
}
for (const f of app.vault.getMarkdownFiles()) {
  if (app.metadataCache.isUserIgnored(f.path)) continue
  const c = app.metadataCache.getFileCache(f)
  if (c) for (const t of fmTags(c.frontmatter).concat((c.tags || []).map(x => x.tag))) count(t)
}
const theirs = {}
const obsidian = app.metadataCache.getTags()
for (const t in obsidian) theirs[t.toLowerCase()] = (theirs[t.toLowerCase()] || 0) + obsidian[t]
const rows = []
for (const t of new Set(Object.keys(ours).concat(Object.keys(theirs))))
  if ((ours[t] || 0) !== (theirs[t] || 0)) rows.push(t + '\tours ' + (ours[t] || 0) + '\tobsidian ' + (theirs[t] || 0))
if (rows.length)
  return 'Error: ' + rows.length + (rows.length > 1 ? ' tag counts differ' : ' tag count differs') +
    " from Obsidian's own — fm_lists no longer reads tags the way this Obsidian does, or getTags counts them differently now:\n" +
    rows.sort().join('\n')
return "tags agree with Obsidian's own count (" + Object.keys(theirs).length + ' tags)'
JS
}

self_test() {
  js "(() => {
$(fm_lists)
$(selftest_js)
})()"
}

# ---- arguments ---------------------------------------------------------------------------

while (($#)); do
  case "$1" in
    --vault)
      (($# >= 2)) || usage_error "--vault needs a name"
      prefix=("vault=$2")
      shift 2
      ;;
    vault=*)
      # The CLI's own spelling, before the command word. Taken here it reaches the wrapper's
      # own commands too; left in the arguments, `obsi.sh vault=X find …` went to the CLI as
      # a vault selector followed by a command called `find`, which the CLI does not have
      prefix=("$1")
      shift
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

cmd="$1"
shift
case "$cmd" in
  find)
    (($#)) || usage_error "find needs something to look for"
    query="$1"
    shift
    limit=20
    prop=""
    markers=""
    value_flag=""
    while (($#)); do
      case "$1" in
        --name | --alias | --tag | --heading | --body)
          markers="$markers ${1#--}"
          shift
          ;;
        --value)
          # Property values: the `prop` marker, which is otherwise only on by default
          markers="$markers prop"
          value_flag=1
          shift
          ;;
        --prop)
          (($# >= 2)) || usage_error "--prop needs NAME or NAME=VALUE"
          prop="$2"
          shift 2
          ;;
        --limit)
          (($# >= 2)) || usage_error "--limit needs a number"
          limit="$2"
          shift 2
          ;;
        *) usage_error "unknown option '$1' — see obsi.sh --help" ;;
      esac
    done
    need_count "$limit"
    # Naming no marker means all of them, which is what someone who just wants the note
    # expects. Naming one narrows to it. `--prop` is a filter, not a marker; the marker for
    # property values is `--value`
    [[ -n "$markers" ]] || markers=" name alias tag prop heading body"
    # With --value, --prop NAME also says where to look: the value match is confined to that
    # property. Without --value the filter narrows the notes and nothing else
    scope=""
    [[ -z "$value_flag" || -z "$prop" ]] || scope="${prop%%=*}"
    find_notes "$query" "$limit" "${markers# }" "$prop" "$scope"
    ;;
  graph) graph "$@" ;;
  selftest)
    (($# == 0)) || usage_error "selftest takes no arguments"
    answer self_test
    ;;
  *)
    # pass-through: anything not recognised above is the CLI's own command, with its
    # traps handled. `vault=` and `--vault` both belong before the command word: after it
    # the CLI drops them in silence and answers for whichever vault happens to be open,
    # so they are refused here rather than passed along to be ignored
    command_word=""
    for arg in "$cmd" "$@"; do
      if [[ -n "$command_word" && ("$arg" == vault=* || "$arg" == --vault) ]]; then
        usage_error "the vault goes before the command word: obsi.sh --vault NAME $command_word …"
      fi
      [[ -n "$command_word" || "$arg" == vault=* ]] || command_word="$arg"
    done
    cli "$cmd" "$@"
    ;;
esac
