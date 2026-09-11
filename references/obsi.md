# `obsi.sh` — the wrapper, in full

`obsi.sh` sits at the root of this skill. It adds what the CLI has no command for and passes everything else through untouched, so `obsi.sh read path=note.md` is `read path=note.md` with the traps handled. Measured against Obsidian 1.13.7 (installer 1.13.4)

Everything it adds is computed inside the running app through `eval`, which is the CLI's own command, and only the answer crosses back. That is not a stylistic preference: it is the difference between 178 bytes and 1 087 045 for the same question

## Why it exists at all

A wrapper around a working CLI has to earn its place. These are the things it does that every caller would otherwise repeat, each of which fails silently:

| Trap | What the wrapper does |
| --- | --- |
| An application error exits **0** and prints `Error: ` on stdout | checks every call and gives it a real exit status, including errors raised inside `eval` |
| The CLI reads stdin, so a call inside `while read` eats the loop's list | gives every call `</dev/null` |
| The client is `obsidian-cli` on some installs and `obsidian` on others, where that name may be the GUI launcher | tries `$OBSIDIAN_CLI`, then `obsidian-cli`, then `obsidian`, and accepts the first that answers `version` with two numbers |
| The whole link graph is about 1 MB of JSON for 1300 notes | never prints it — only `graph dump` produces it, and it writes to a file |

`--vault NAME` before the subcommand targets another vault, and travels as one argument, because a vault name may contain a space: `Obsidian Sandbox` does

## `find` — which note *is* this

**`search` already finds all of it.** That is worth stating first, because the opposite is easy to assume. Planting five notes with unique nonsense words, each in one place only, and searching for each:

| The word lives in | `search` finds it |
| --- | --- |
| the filename | yes |
| an `aliases` entry | yes |
| a property value | yes |
| a heading | yes |
| a tag | yes |

It matches the file's text, and the frontmatter is part of the text. So `find` is not an alternative to `search`. It runs `search` and adds the two things `search` structurally cannot do: **say where the match was**, and **be restricted to one field**

The difference in one query, on the vault measured:

```console
$ obsidian-cli vault=Vault search query=coastline limit=5000 | wc -l
6
$ ./obsi.sh --vault Vault find coastline --alias | wc -l
2
```

Six notes contain the word; two of them *answer to* it. `search` returns all six as bare paths with nothing to separate them, and no parameter narrows it — the command set cannot express "notes whose alias is this" at all. The nearest thing, `file file=<name>`, resolves wikilink-style by filename and **fails on an alias**: `file file="Qwibble"` on a note whose alias is `Qwibble` answers `Error: File "Qwibble" not found.`

So `find` reads names, tags, properties and headings from the metadata index, takes bodies from `search`, and merges the two into one ranked list:

```console
$ ./obsi.sh --vault Vault find coastline --alias
9	alias	05. Courses/…/Tides, currents and coastlines.md	coastline
9	alias	05. Courses/…/Coastlines.md	coastline
```

Both files of an alias collision, including the one whose path contains a comma — which is exactly what the first-party listing cannot express

```
obsi.sh find QUERY [--name] [--alias] [--tag] [--heading] [--body] [--value] [--prop NAME[=VALUE]] [--limit N]
```

Columns are **score**, **why it matched** (several joined by `+`), **path**, and **what matched**. Matching is case-insensitive substring. With no marker flag every marker is used at once; naming one or more narrows to those. `--limit` defaults to 20, and an empty result is the sentence `No matches found.`, the way the CLI answers one

| Marker | Exact | Partial |
| --- | --- | --- |
| filename | 10 | 6 |
| alias | 9 | 5 |
| tag | — | 4 |
| property value (`--value`) | — | 4 |
| heading | — | 3 |
| text — anything `search` matched, frontmatter included | — | 1 |

Each field counts once, at its best match, and the fields add up, so a note matching by alias and in its text outranks one that only appears in the text — but four matching headings no longer outrank an exact filename, which they did while scores were summed inside a field. They are deliberately coarse: the ranking is a convenience, the **reason column is the point**, because it makes a wrong hit visible instead of plausible

Where the ranking stops meaning anything is a marker that scores every hit identically. A common tag is the case that bites: 649 notes carry the same one on the vault measured, all at 4 points, and the order among them is alphabetical, which is to say arbitrary. So the cut is announced rather than made in silence — `find` prints what it dropped, and a search that answers "these are the notes with that tag" from twenty rows out of 649 is wrong in a way nothing else would have shown:

```console
$ ./obsi.sh --vault Vault find "lecture-notes" --tag --limit 3
4	tag	01. Data/03. Templates/01. Templates/lecture notes.md	#lecture-notes
4	tag	03. Journal/…/Pruning roses.md	#lecture-notes
4	tag	03. Journal/…/Composting basics.md	#lecture-notes
…	646 more matches at or below this score, raise --limit to see them
```

Announcing it is harder than it looks, and the first attempt printed nothing. `head` stops reading at its count, the shell builtin feeding it takes SIGPIPE, and under `set -o pipefail` the wrapper died at **141** on that line — after the rows had already appeared, so it read as a finished command. Note that this is a shell trap, not a CLI one: `obsidian-cli files | head -n 3` leaves `PIPESTATUS` at 0 even at 572 KB of output, because the client is Node and swallows EPIPE. `awk 'NR <= n'` reads to the end and leaves the status alone

Every tag a note carries is matched, in both places Obsidian keeps them: `cache.tags` for inline ones and `frontmatter.tags` for the rest — 5979 frontmatter tags against 16 inline on that vault, so a tag search that only read the inline ones would have found almost nothing. `tags` and `aliases` are read the way Obsidian reads them: a string is one item and is never split on commas, a list is taken item by item, and a tag holding a space is no tag at all — so `tags: a, b` carries no tags, as in Obsidian's own tag pane

`--prop NAME` keeps only notes that have that property, `--prop NAME=VALUE` only those where it holds that value. The filter is applied to the body half too — `search` knows nothing about it, and without that step it would quietly filter half the results

`--value` narrows the match to property values, as the other markers narrow to theirs; beside `--prop NAME` it looks at that property's values alone, so `find draft --value --prop status` asks for draft in `status` rather than in every property of the notes that have one

## `graph` — the vault's shape

`links` and `backlinks` answer for one note. For the whole vault there is no command: through commands it is one call per note, and their output carries no source column, so the lines cannot be attributed afterwards. `app.metadataCache.resolvedLinks` is the finished structure — `{source: {target: count}}`, the same the graph view draws

```console
$ ./obsi.sh --vault Vault graph
notes	1300
links between notes	5453
links to attachments	1418
unresolved links	94
nothing links to them	137
they link nowhere	226
connected components	126
largest component	1175
```

| Query | Answers |
| --- | --- |
| `graph` | the summary above. Its link counts are (source, target) pairs: a note linking another three times counts once, which is neither what `unresolved total` counts (unique targets) nor what `counts` does (occurrences) |
| `graph hubs [N]` | the most linked-to notes, incoming count first. Whatever is at the top is the vault's real MOC, named one or not |
| `graph ends [N]` | one note per line: what nothing points to, and what points nowhere |
| `graph components [N] [M]` | one **group** per line, largest first: size, then up to `M` members joined by ` \| `. Defaults 10 and 5 |
| `graph related NOTE [N] [--tag-max-notes K]` | what a note is connected to without being linked to it — see below |
| `graph unresolved [N]` | broken links as one row per target, source and count |
| `graph path FROM TO` | a shortest route from one note to another, one note per line, following links only in the direction they are written — so "No path found." means no route that way, not that the two are unconnected |
| `graph dump [FILE]` | the whole graph as JSON, written to `FILE` (default `graph.json`); prints only the size and where it went |

Attachments are counted but left out of the walk: an image linked from forty notes is an edge in the index, not a hub

### `related` — connected without an edge

Direct neighbours are left out on purpose: `links` and `backlinks` answer those already, and what is wanted here is a connection the vault holds without a link to show for it. The signals, weighted by how much each one actually says:

| Signal | Worth | What it means |
| --- | --- | --- |
| `co-cited` | 2 | something links to this note and to that one — the strongest, because a third party put them in the same context |
| `shares-links` | 2 | both notes point at the same things: the same argument read from the other end |
| `tag` | 1 | a tag in common, **counted only while the tag still distinguishes anything** |

That last condition is what makes the query usable. Without it, on the vault measured, a note came back with 873 related notes and every one of them carried `tag` as a reason, because a tag on 649 of 1300 notes is a category — a course, a year, a note type — and sharing it says nothing

`--tag-max-notes N` is how many notes a tag may be on and still count as a signal — **not** a number of tags. A tag on five notes says those five are about one thing; a tag on 649 says only that the vault has a category. It defaults to a twentieth of the vault, and the three settings on the same note gave 18, 51 and 873 results:

```console
$ ./obsi.sh --vault Vault graph related "…/Coastlines.md" --tag-max-notes 0       # structure only
$ ./obsi.sh --vault Vault graph related "…/Coastlines.md"                         # the default
$ ./obsi.sh --vault Vault graph related "…/Coastlines.md" --tag-max-notes 100000  # every tag counts
```

The threshold is a cliff rather than a curve — a tag on 65 notes counts fully and one on 66 not at all — which is why it is a flag and not a secret. A vault whose tags are all narrow wants a higher one; a vault tagged by topic wants `--tag-max-notes 0`

Unlinked mentions — a note naming this one in prose without a wikilink — are **not** among the signals. `metadataCache` does not hold them, and the substitute is one `search` per name and alias, which is approximate and belongs to a tool that reads the vault's text directly

### `unresolved` — the pairs the command cannot print

The first-party `unresolved` already lists broken links, and this does not replace it. The one thing it cannot do is say which file each one came from: it joins every source into a single field with `, `, and vault paths contain commas, so the field cannot be parsed back. One row per pair leaves nothing to parse:

```console
$ ./obsi.sh --vault Vault graph unresolved 200 | grep '^00. Attachments/scans'
00. Attachments/scans	05. Notes/Calculus — MOC.md	1
00. Attachments/scans	05. Notes/English — MOC.md	1
```

### `ends` and `components` are not the same question

`ends` is about one note's own degree, with direction: nothing links to it, or it links nowhere. `components` is about groups, ignoring direction: which notes can reach each other at all

They part company in both directions. A note with outgoing links but no incoming ones is an end, and it sits in the main component all the same. And a group that links only to itself is a component of its own where **not one member is an end** — measured on three notes linking in a cycle:

```console
$ ./obsi.sh --vault "Obsidian Sandbox" graph components 2 4
31	Adventurer/From plain-text note-taking.md | … and 27 more
3	Island/A.md | Island/B.md | Island/C.md

$ ./obsi.sh --vault "Obsidian Sandbox" graph ends 20 | grep 'Island/'
$
```

On a vault whose cut-off notes are all single, the two nearly collapse into each other — on the 1300-note vault measured, every one of the 125 non-main components held exactly one note, and each of those is an end twice over. The group case is the one `ends` can never show

### Why every component is listed, including the largest

An earlier version of this query was called `islands` and dropped the biggest component before printing, on the assumption that it is the mainland and only what is cut off from it is interesting. That assumption is not in the data. A vault that has split into halves of 600 and 600 would have had one half silently reported as an island, with nothing in the output admitting a choice had been made

So the mainland is row one, its size is visible, and everything cut off from it is every row after — the same information, with the judgement left to the reader. Both dimensions are bounded because a component is a listing like any other: a hundred paths joined onto one line is exactly the runaway output the third rule exists to stop. The default output is 719 bytes on a 1300-note vault

## What the graph does not contain

It is Obsidian's index, so it carries that index's blind spots, and every one of them is [documented with its reproduction](pitfalls.md): anchors are dropped, links inside fenced code blocks do not exist, a link written through an alias is unresolved rather than an edge, and unlinked mentions are absent from the data entirely. A count taken here is a count of what Obsidian believes, which is the point — it is what the app itself would draw

## `selftest` — is the copy still Obsidian's?

`find` and `graph related` read `tags` and `aliases` through a copy of Obsidian's own parsers, because the module that exports them cannot be required from `eval`, and a copy drifts when Obsidian changes. The one answer from Obsidian's own reading that `eval` can reach is `metadataCache.getTags()`, the tag counts the tag pane shows. `obsi.sh selftest` sums the same counts from what the wrapper reads, under `getTags`' own counting rules — excluded files skipped, every occurrence counted, a nested tag counted toward each parent, a tag Obsidian's tag check refuses counted for nothing, one tag in two cases counted once — and prints `tags agree with Obsidian's own count (N tags)`, or every tag whose count differs as tag, ours, Obsidian's, and exits 1

Measured on 1.13.7: 2 tags agree on the sandbox vault and 401 on a vault of 1299 notes. Before the refusal rule was added, the one tag that differed was a template placeholder, `#y{{date:YYYY}}`, which the wrapper reads as a tag the way Obsidian's per-file reading does, and which Obsidian's own count refuses. A difference after an update means the copy or the counting rules no longer match the running Obsidian: read the named tags before trusting `find --tag`

The JavaScript that `find`, `graph related` and `selftest` hand to `eval` is run in node against a made-up vault in `tests/fake-app.js`, taken from the wrapper exactly as it builds it. How it behaves against a real vault's index is still measured, not tested

## Passing anything else through

Anything the wrapper does not recognise goes to the CLI unchanged, with the error check and the stdin guard applied. There is no facade over the command set on purpose: it is generated by the running app and varies with the enabled plugins, so a wrapper that named each command would be a second source of truth going stale in silence
