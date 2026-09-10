// A fake Obsidian `app` for the JavaScript obsi.sh hands to `eval`. check-obsi.sh captures
// that code exactly as the wrapper builds it — through the stub client, never a copy — and
// runs it here, so the half of the wrapper that runs inside the app is checked on a runner
// that has no app.
//
//   node tests/fake-app.js CODE-FILE
//
// The vault below is small and made up, and every note is there for one question:
//
//   Sea/Coastlines.md  aliases as ONE string holding a comma; two properties saying "draft"
//   Sea/Smith.md       an alias LIST whose item holds a comma; `tags: a, b` as a string
//   Sea/Tagged.md      mixed-case `Tags` and `Aliases` keys; a tag item holding a space
//   Sea/Other.md       "draft" in a property other than status; an inline tag
//   Sea/Lone.md        linked to nothing, sharing only an inline tag with Tagged
//   Sea/Template.md    a nested tag, the same tag in two cases, a template placeholder
//                      and a number, which Obsidian's own count treats each its own way
//   Sea/Ignored.md     in the vault's excluded files, which Obsidian's own count skips
//
// `getTags()` is not computed here: it is written out by hand from Obsidian 1.13.4's rules,
// so it stands as an answer the wrapper's selftest has to reproduce rather than one it
// shares code with. FAKE_GETTAGS=drift makes it disagree by one, the way it would after an
// Obsidian update changed how it reads tags
//
// The shapes follow what Obsidian itself holds: `frontmatter` is the parsed YAML as written,
// `tags` are the inline ones with their `#`, and `resolvedLinks` has a key for every note,
// linked or not
'use strict'
const fs = require('fs')

const cache = {
  'Sea/Coastlines.md': { frontmatter: { aliases: 'coastline, shore', status: 'draft', owner: 'draft team' } },
  'Sea/Smith.md': { frontmatter: { aliases: ['Smith, John', 'Plain'], tags: 'a, b' }, tags: [{ tag: '#inline' }] },
  'Sea/Tagged.md': { frontmatter: { Tags: ['#x', 'y', 'two words'], Aliases: 'Upper case' } },
  'Sea/Other.md': { frontmatter: { status: 'done', note: 'draft' }, tags: [{ tag: '#y' }] },
  'Sea/Lone.md': { frontmatter: {}, tags: [{ tag: '#x' }] },
  'Sea/Template.md': { frontmatter: { tags: ['draft/idea', 'Draft', 'y{{date:YYYY}}', '123'] }, tags: [{ tag: '#draft' }] },
  'Sea/Ignored.md': { frontmatter: {}, tags: [{ tag: '#y' }] }
}

// Every occurrence counts and a nested tag counts toward its parent too: #draft/idea is one
// #draft/idea and one #draft, and with the inline #draft and the frontmatter Draft — one tag
// in two cases — #draft comes to 3. The placeholder and the number are no tags at all to
// Obsidian's count, and the excluded file is not counted
const obsidianTags = { '#inline': 1, '#x': 2, '#y': 2, '#draft/idea': 1, '#draft': 3 }
if (process.env.FAKE_GETTAGS === 'drift') obsidianTags['#x'] = 3
const files = Object.keys(cache).map(path => ({ path, basename: path.replace(/^.*\//, '').replace(/\.md$/, '') }))

global.app = {
  vault: {
    getMarkdownFiles: () => files,
    getAbstractFileByPath: path => files.find(f => f.path === path) || null
  },
  metadataCache: {
    getFileCache: f => cache[f.path] || null,
    getTags: () => Object.assign({}, obsidianTags),
    isUserIgnored: path => path === 'Sea/Ignored.md',
    resolvedLinks: {
      'Sea/Smith.md': { 'Sea/Coastlines.md': 1, 'Sea/Tagged.md': 1 },
      'Sea/Other.md': { 'Sea/Tagged.md': 1 },
      'Sea/Coastlines.md': {},
      'Sea/Tagged.md': {},
      'Sea/Lone.md': {},
      'Sea/Template.md': {},
      'Sea/Ignored.md': {}
    },
    unresolvedLinks: {}
  }
}

// Indirect eval, so the code sees only the globals — the same scope it gets inside the app
const code = fs.readFileSync(process.argv[2], 'utf8')
process.stdout.write(String((0, eval)(code)) + '\n')
