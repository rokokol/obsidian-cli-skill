# Developing a plugin or theme through the CLI

`help dev:<command>` and `help plugin:reload` list the parameters; this file is what they do not say. Measured on Obsidian 1.13.7 (installer 1.13.4) on Linux, against a scratch vault

Every command acts on the window of the vault it is sent to, `vault=<name>` first. A plugin under test belongs in a scratch vault rather than the one holding real notes: `dev:mobile` reloads that window, and a relative screenshot path writes into it

## The loop

1. **Reload** — `plugin:reload id=<plugin-id>` answers `Reloaded: <id>`. It works on core plugins too (`id=bookmarks`), and a wrong id is `Error: Plugin "…" not found. Use "plugins" to list available plugins.` at exit 0, like every other error
2. **Errors** — `dev:errors` lists the uncaught errors the app captured, each with its time and stack, or says `No errors captured.` It needs no debugger. `dev:errors clear` empties the buffer (`Cleared 1 errors.`), and clearing before each reload is what makes the next read mean "this reload" rather than "since the app started"
3. **Console** — `dev:console level=error` needs the debugger: without it the answer is `Error: Debugger not attached. Use "dev:debug on" to start capturing console messages.` `dev:debug on` starts the capture, the attachment outlives the call, and `dev:debug off` ends it (`Debugger detached. Console capture stopped.`). The buffer also holds the app's own `Received CLI command {…}` line for every CLI call, so filter with `level=` rather than reading it whole; `limit=` defaults to 50
4. **Look without looking** — `dev:dom selector=… total`, `text`, `attr=<name>` or `css=<prop>` answers about the first match, or every match with `all`; `dev:css selector=… prop=<name>` lists the rules that set it with their source line; `dev:screenshot path=<absolute path>` writes a PNG of the window

## Traps

- **A relative `path=` for `dev:screenshot` is relative to the vault root**, not to the shell's directory: `path=rel.png` wrote `<vault>/rel.png`, into the vault, where it is indexed, synced and turns up among the orphans. Give an absolute path outside the vault
- **`dev:mobile on` and `off` reload the app window** — the answer is `Mobile emulation enabled. Reloading...` — and whatever was unsaved in it goes with the reload. While it is on, `body` carries `emulate-mobile is-phone is-mobile`, which is how a script can tell; switch it off when done
- **`eval` prints what the code logs above its result**, which matters as soon as the code under test logs anything — see [commands.md](commands.md#eval--the-escape-hatch)
- `dev:debug` and `dev:cdp` attach Chrome DevTools Protocol to the app, and `dev:cdp method=<CDP.method> params=<json>` runs one method. Beyond the console capture above they were not measured here; treat them as the app's own debugger and detach when done
