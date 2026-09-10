---
name: obsidian-cli
description: "Drive a running Obsidian vault from the terminal through the official Obsidian CLI — read and write notes, find a note by name, alias, tag or property, query and summarise the whole link graph, search, manage properties, tags and tasks. Use whenever a request needs vault data or a vault operation rather than an explanation of Obsidian's UI. Triggers: Obsidian, obsidian-cli, vault, note, notes, backlinks, broken links, orphans, aliases, frontmatter properties, tasks in notes, link graph, most linked notes, related notes, path between notes. Russian triggers: обсидиан, обсидиан цли, обсидиан кли, обсидианкли, волт, вики, заметка, заметки, моя вики, найди в заметках, найди заметку, как называется заметка, поиск по алиасу, создай заметку, обратные ссылки, бэклинки, битые ссылки, сироты, теги заметок, свойства заметки, алиасы, граф заметок, граф связей, связность вики, острова заметок, изолированные заметки, самые цитируемые заметки, связанные заметки, путь между заметками, задачи в заметках"
license: MIT
---

# Obsidian CLI

The official CLI ships with Obsidian 1.12+. It is a thin client that talks to a **running** Obsidian app over a unix socket — not a standalone vault reader. Everything it reports comes from the app's own index, so it sees the vault exactly as Obsidian does

Written against Obsidian **1.13.7 (installer 1.13.4)** on Linux. Behaviour below was measured, not copied from the help text

## Before the first call

1. **Find the binary.** The name depends on how Obsidian was installed: the app registers `obsidian`, but package managers may ship the client as `obsidian-cli` while `obsidian` stays the GUI launcher. Run `command -v obsidian-cli obsidian`, then confirm the candidate answers `version` with two numbers. Calling a GUI launcher instead opens a second window
2. **Confirm the app is running.** With no reachable app every call prints `The CLI is unable to find Obsidian. Please make sure Obsidian is running and try again` and exits **1** — the only condition that sets a non-zero status. Do not expect the CLI to start Obsidian for you; on a packaged install it does not
3. **Ask the app what it can do.** `<cli> help` lists the commands available *right now*. The list is not fixed: `daily:*`, `unique`, `web`, `workspaces`, `publish:*` and `sync:*` appear only when the matching core plugin or service is enabled. Treat `help` as the reference and never guess a command from documentation

## The rules that prevent wrong answers

These cost one line each and are the difference between a real answer and a plausible one

1. **Read the output, not the exit status.** Every application-level error — missing file, unknown command, missing parameter — prints `Error: …` and still exits **0**, on **stdout**. `set -e`, `if cmd; then`, and `2>/dev/null` all fail to notice. Check for the `Error: ` prefix
2. **Always pass a target.** Unknown parameters and flags are ignored in silence, so one typo turns a targeted query into a query about whichever file is open in the GUI: `backlinks fil=Garden total` answered `5` where `file=` answers `12`. Nothing warns. Prefer `path=` (exact, from the vault root) over `file=` (wikilink-style name resolution) whenever the path is known
3. **Bound every listing.** These commands stream the whole vault. `search:context` for a common word returned **98 MB** in one call here. Put `limit=` on searches, `total` on counts, and pipe long listings through `grep`/`head` rather than reading them whole
4. **Close stdin on every call in a loop.** The CLI reads stdin, so `while IFS= read -r f; do <cli> links path="$f"; done < list` consumes the list on its first call and ends after one file, silently and 500 times too fast. Add `</dev/null` to the inner call

## Task to command

| Task | Command |
| --- | --- |
| Read a note | `read path="folder/note.md"` |
| Structure without the body | `outline path=…`, `properties path=…`, `wordcount path=…` |
| Neighbours of a note | `backlinks path=…`, `links path=…` |
| Find text | `search query=… limit=10`, `search:context query=… limit=5` for matching lines |
| Find the note itself, not just the text mentioning it | `obsi.sh find "…"`, narrowed by field or filtered by property — see `obsi.sh --help` |
| Vault-wide metadata | `tags counts sort=count`, `properties counts sort=count`, `aliases verbose` |
| Broken links | `unresolved verbose` |
| Unlinked notes | `orphans`, `deadends` |
| Tasks | `tasks todo verbose`, `task ref="note.md:8" toggle` |
| Create or overwrite | `create path=… content=… overwrite` |
| Add to a note | `append path=… content=…`, `prepend path=… content=…` (lands after the frontmatter) |
| Set one property | `property:set path=… name=… value=… type=list` |
| The vault's graph as a whole | `obsi.sh graph` and the queries `obsi.sh --help` lists |
| What a note relates to without linking to it | `obsi.sh graph related "folder/note.md"` |
| Broken links with the file each came from | `obsi.sh graph unresolved` — `unresolved verbose` joins its sources unparseably |
| Anything the CLI has no command for | `eval code=…` against the app's own API |
| Develop a plugin or theme: reload, errors, console, DOM, screenshot | `plugin:reload id=…`, `dev:errors`, `dev:console` after `dev:debug on` — the loop and its traps in [`references/plugin-dev.md`](references/plugin-dev.md) |

Values with spaces need quoting; `\n` and `\t` work inside `content=`. To target another vault, `vault=<name>` must come **before** the command word — a bare vault name as the first argument is not accepted

[`obsi.sh`](obsi.sh) sits beside this file and wraps the CLI rather than replacing it: what it does not recognise passes through with rules 1 and 4 applied, `find` says which field of a note matched — something `search`, which matches them all, cannot — and `graph` answers about the whole link graph without printing it. Flags, limits and why — [`references/obsi.md`](references/obsi.md). After an Obsidian update, run `obsi.sh selftest` before trusting `find --tag` or `graph related`: it checks the wrapper's copy of Obsidian's tag reading against the running app's own count

## Reading the graph

`links`, `backlinks` and `unresolved` read Obsidian's metadata index, which has consequences worth knowing before trusting a count:

- **Anchors are dropped and targets deduplicated.** `[[Note#Heading|text]]` is reported as `Note.md`; a note linked three times counts once in `links`
- **Links inside fenced code blocks do not exist.** Obsidian does not parse them, so a `grep` of the file finds links the CLI never reports
- **A link written through an alias counts as broken.** Alias resolution is a UI convenience; the index resolves by filename only, so `[[Plot]]` lands in `unresolved` and never appears in the target's `backlinks`. Before calling an unresolved target a broken link, check it against `aliases`
- **`total` is not one thing.** `backlinks … total` counts occurrences (12 across 11 files here), while `orphans total` and `unresolved total` count unique targets. Use `counts` to get occurrences per file
- **`links` marks broken targets inline** with a trailing ` (unresolved)` in the plain-text output
- **An unresolved target is not automatically a defect.** Several kinds share the list and want different answers — a note deliberately not written yet, a template placeholder, a typo or an alias link, a link written as an explicit path to a file that exists somewhere else; [commands.md](references/commands.md#what-an-unresolved-target-actually-is) has them with their shares. Read a sample before treating the list as a repair queue
- **Unlinked mentions have no command at all.** The app's Outgoing links panel shows them beside unresolved links, but `metadataCache` carries only `resolvedLinks` and `unresolvedLinks`, so `eval` does not reach them either. A neighbour mentioned by name without a wikilink is invisible to every command here; `search query="<name or alias>"` minus the files that already link is the manual substitute

## Writing

Prefer the CLI over editing files directly: it goes through the app, so the index and any open editor stay in step

- `property:set` **without `type=`** writes a scalar, and overwriting an existing YAML list that way silently flattens it to one line. Pass `type=list` for `tags`, `aliases` and every multi-valued field
- With `type=list` the comma is the item separator and **there is no escape**: neither `\,` nor quoting survives, so a value containing a comma cannot be written this way. `property:set` also replaces the whole list rather than appending
- For a list item containing a comma, for several fields at once, or for any append, go through the app's API instead — this writes correct YAML and keeps the index consistent:

  ```bash
  eval code='(async()=>{const f=app.vault.getAbstractFileByPath("folder/note.md");await app.fileManager.processFrontMatter(f,fm=>{fm.aliases=["Smith, John","Plain"]});return "ok"})()'
  ```

- **Indexing is asynchronous.** A graph query fired immediately after a write can answer from the previous state — 9 of 20 immediate reads did here, 0 of 20 after 0.3 s. Re-read before reporting success rather than trusting the write

## Reference

- [`references/commands.md`](references/commands.md) — output shape, counting semantics and one worked example per command group, all measured on a live vault. What `help` does not tell you
- [`references/pitfalls.md`](references/pitfalls.md) — every trap above with its reproduction, plus setup problems and the places the official documentation and the local build disagree
- [`references/obsi.md`](references/obsi.md) — the wrapper in full: every `find` and `graph` flag, how results are scored, and what each query cannot see
- [`references/plugin-dev.md`](references/plugin-dev.md) — the reload, errors, console and inspect loop for a plugin or theme, with what `help` leaves out

This skill covers the CLI only. How a particular vault's notes are written and organised — style, indexes, icons, diagrams, its own tooling — is set somewhere else, if it is set at all: most often by skills the vault carries itself, one per concern. Do not assume those rules exist, and do not invent them where they do not

Where such a skill lives depends on the agent — whichever skills directory it reads, under the vault, which for Claude Code is `<vault>/.claude/skills/`. The harness offers them only to a session started under the vault, so from anywhere else they are absent from the skill list while existing on disk. Before writing into a vault, look in that directory and read the relevant `SKILL.md` and the files it points to by path. A skill missing from the list means it was not offered to this session, never that it does not exist
