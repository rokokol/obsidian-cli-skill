# Pitfalls

Every entry was reproduced on Obsidian 1.13.7 (installer 1.13.4) on Linux against a live vault. Where a claim rests on a measurement, the measurement is given, so a later version can be checked against it rather than trusted

## Failures that look like success

### Errors exit 0, on stdout

Every application-level error — missing file, unknown command, missing required parameter, unknown tag — prints `Error: …` and exits **0**. The only non-zero status observed is **1**, when the app cannot be reached

```console
$ obsidian-cli read file="No Such Note 98765"; echo "exit=$?"
Error: File "No Such Note 98765" not found.
exit=0
```

The message goes to **stdout**, so `2>/dev/null` hides nothing and `$(…)` captures the error as if it were data. `set -e` and `if obsidian-cli …; then` never fire. Test for the `Error: ` prefix

### An unknown parameter silently changes the question

Unknown flags and parameter names are dropped without a word. A command that no longer has a target falls back to the file open in the GUI, and answers about that instead:

```console
$ obsidian-cli backlinks file=Tunnel total
12
$ obsidian-cli backlinks fil=Tunnel total
5
```

Both look like answers. The second is the backlink count of whatever note was open at the time. Nothing distinguishes them in the output — this is the strongest argument for passing `path=` and checking the result against something known

### Indexing is asynchronous, including through the CLI

A graph query issued immediately after a write can be answered from the pre-write index. Measured over 20 iterations each, writing through `create` and reading `links` back:

| Read timing | Fresh | Stale |
| --- | --- | --- |
| immediately | 11 | 9 |
| after 0.3 s | 20 | 0 |

Writing the file directly with a shell redirect behaves the same way: stale at 0 s, fresh from 0.2 s. Writing through the CLI is still preferable — it keeps any open editor in step — but neither route makes the index synchronous. Re-read before reporting success

## The link graph is Obsidian's, not the file's

### A link through an alias counts as broken

Alias resolution happens in the UI. The metadata index resolves by filename only, so an alias link is unresolved in both directions — it appears in `unresolved`, and the target's `backlinks` does not mention it:

```console
$ obsidian-cli links path="Ref.md"          # file contains [[Tun]], an alias of Tunnel
Tun (unresolved)
$ obsidian-cli eval code='JSON.stringify({byAlias:app.metadataCache.getFirstLinkpathDest("Tun","")?.path||null})'
=> {"byAlias":null}
```

Two consequences: `unresolved` over-reports broken links, and `backlinks` under-reports neighbours. Before treating an unresolved target as a typo, check it against `aliases`. On the vault measured, 2 of 60 unresolved targets were live aliases

### Links inside fenced code blocks do not exist

Obsidian does not parse links inside ``` fences, so a plugin block full of embeds contributes nothing to the graph:

````text
```media-gallery
![[clip.mp4]]
![[photo.jpg]]
```
````

`links` for that file reports neither. A `grep` for `[[` finds them, which is exactly how a linter that compares its own scan against the CLI ends up disagreeing with itself. The CLI is right about the graph; the grep is right about the text

### `total` counts different things per command

`backlinks … total` counts occurrences (12 across 11 files), `orphans total` and `unresolved total` count unique targets, `links … total` counts unique targets after deduplication and anchor stripping. Use `counts` where occurrences are what is wanted

### Anchors never survive

`[[Note#Heading|label]]` is reported as `Note.md`. There is no command that returns the anchor, so unused-heading analysis cannot be built on `links`

## Frontmatter

### `property:set` without `type=` flattens a YAML list

Setting a multi-valued field without `type=list` writes a scalar, and does so over an existing list without warning:

```console
$ obsidian-cli property:set path=note.md name=tags value="alpha, beta"
Set tags: alpha, beta
$ head -3 note.md
---
tags: alpha, beta
```

With `type=list` the same call writes a proper block sequence. **This corrects an earlier reading of this pitfall**: `property:set` is not incapable of writing YAML lists — it writes one correctly when told the type, and corrupts one when not told

### With `type=list` the comma cannot be escaped

The comma is the item separator and there is no escape. Both attempts damage the value rather than protecting it:

| Input | Result |
| --- | --- |
| `value="Smith, John" type=list` | two items: `Smith`, `John` |
| `value='Smith\, John' type=list` | two items: `Smith\`, `John` |
| `value='"Smith, John"' type=list` | two items: `'"Smith'`, `John"` |

A list value containing a comma cannot be written with `property:set` at all. `property:set` also replaces the whole list rather than appending to it

The way through is the app's own API, which writes correct YAML for any value and keeps the index consistent:

```bash
obsidian-cli eval code='(async()=>{const f=app.vault.getAbstractFileByPath("note.md");await app.fileManager.processFrontMatter(f,fm=>{fm.aliases=["Smith, John","Plain"]});return "ok"})()'
```

### An alias on two files collapses into one comma-joined line

`aliases verbose` reports a collision as a single record with both paths in one field — which looks like a way to detect one. Plain `aliases` deduplicates and hides it entirely. `unresolved verbose` joins its source files the same way, and `format=json` does not nest them into an array either

**That output cannot be parsed back out**, and the failure is quiet. Vault paths contain commas — a folder named `04. Reports, digests and charts` is enough — so splitting the field on `, ` reports collisions that do not exist: on the vault measured, that method claimed **485** where there were **60**

Ask the index instead. This is the alias map both directions of the problem need, and it is exact:

```bash
obsidian-cli eval code='(()=>{const m={};for(const f of app.vault.getMarkdownFiles()){const a=app.metadataCache.getFileCache(f)?.frontmatter?.aliases;if(!a)continue;for(const x of [].concat(a)){if(x)(m[String(x)]=m[String(x)]||[]).push(f.path)}}return JSON.stringify(m)})()'
```

```console
=> {"34984":["05. Courses/Networks/Tags and trunk ports.md"],"MOC architecture":["05. Courses/Networks/f13. Architecture — MOC.md"], …}
```

Every alias maps to an array of paths, so a collision is an entry with more than one, and membership answers whether an unresolved target is really broken. Append `Object.entries(m).filter(([,v])=>v.length>1)` for the collisions alone — it returned 60 where the text-splitting method returned 485

## Flags and commands that do nothing

- **`all` on `orphans` and `deadends` changes nothing.** Non-markdown files are counted with or without it; output is byte-identical. The official documentation does not list the flag at all, which fits
- **`folders` counts the vault root**, printing `/` first, so it is one higher than `vault info=folders`
- **The command set is not fixed.** `daily:*`, `unique`, `web`, `workspaces`, `publish:*` and `sync:*` are documented but absent unless their core plugin or service is enabled — locally 92 commands against the 130+ that circulate in third-party skills. `help` is the only accurate list
- **A vault name as a bare first argument is not accepted**, despite appearing in third-party documentation. `vault=<name>` before the command word is the form that works

## Setup

### Without a running app

```console
$ obsidian-cli vault; echo "exit=$?"
The CLI is unable to find Obsidian. Please make sure Obsidian is running and try again.
exit=1
```

The socket is `$XDG_RUNTIME_DIR/.obsidian-cli.sock`, and `~/.flatpak/md.obsidian.Obsidian/xdg-run/.obsidian-cli.sock` for a flatpak install. **The documented auto-launch did not happen** on a packaged install: the process count was unchanged before and after, and the command failed instead. Documentation says the first command launches Obsidian; do not rely on it

### The binary may not be called `obsidian`

Where the app registers itself it installs `obsidian` (Linux: a copy at `~/.local/bin/obsidian`). Where a package manager ships it, the client is `obsidian-cli` and `obsidian` is the **GUI launcher** — on the machine this was written on, a wrapper around `electron app.asar`. Running `obsidian help` there opens a second window instead of answering. Resolve the name once and verify it answers `version`

### "Set up CLI" can fail while the CLI works

On a packaged install the in-app registration can fail with `Unable to add to command line because the executable is "electron" instead of "obsidian"`. That is the PATH registration refusing to symlink a wrapper — not a broken CLI. If the package already provides the client, the button is not needed. The working state is `"cli": true` in `~/.config/obsidian/obsidian.json` plus a live socket

### Client and app versions drift apart

`version` reports both: `1.13.7 (installer 1.13.4)`. The app updates itself through a downloaded `.asar` while the packaged client stays at the version the package pinned. That pairing worked for everything documented here, but the socket protocol is between the two — when something behaves unlike this document, compare both numbers first
