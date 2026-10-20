#!/usr/bin/env node
// Gate cross-file markdown anchors — the ones markdownlint cannot see.
//
// MD051 (link-fragments) only evaluates a fragment when the link destination `startsWith("#")`, so
// `form-reference.md#some-heading` is never examined. The lean-rule ↔ `*-reference.md` convention in this directory
// manufactures those links by design (the injected rule deep-links into its never-injected companion), so a heading
// rename in a reference file silently points every agent at nothing while `pnpm check` stays green — and a
// convention with no gate regrows.
//
// Same-file `#frag` links ARE covered by MD051. This checks them anyway: the target is then the linking file itself,
// so the extra cost is nil, and one tool answers "is this anchor real?" for both link shapes.
//
// The slug algorithm is deliberately NOT reimplemented — it is where a hand-rolled checker silently disagrees with
// the linter that ships (an em dash leaves a double hyphen; the U+FE0F in `⚠️` survives the `\p{Mark}` class and
// prefixes the slug with an invisible character). Instead every fragment is validated BY MD051: the target file's
// content is linted with one probe link appended per fragment, and a probe MD051 flags is a broken anchor. Heading
// slugging, duplicate-heading `-1`/`-2` suffixes, `{#custom}` anchors, HTML `id=`/`name=` anchors, raw vs
// percent-encoded non-ASCII, and the `#L12-L34` line-fragment exemption all follow from the installed markdownlint
// rather than from a copy that drifts from it.
//
// Relative `.md` destinations with NO fragment are checked for existence only — markdownlint has no rule for that
// either, and the machinery is already here.
//
// Not covered: non-`.md` targets, external URLs, and raw HTML links (`<a href="…">`) — the harvest reads
// markdownlint's link and definition tokens, and an inline HTML anchor is neither.

import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const SCRIPT_REL = 'scripts/check-anchors.mjs'
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const CONFIG_REL = '.markdownlint-cli2.jsonc'

// Appended to every target alongside the real probes. If MD051 does NOT flag it, the appended block never reached the
// linter as markdown (an unclosed code fence at end of file, a broken markdownlint install) — which would otherwise
// report every fragment in that file as valid. The whole point of this script is that it must fail loudly instead of
// passing quietly.
const SENTINEL = '#bf-check-anchors-sentinel-this-fragment-must-never-resolve'

// markdownlint, micromatch and jsonc-parser are exact-pinned dependencies of markdownlint-cli2 and pnpm does not
// hoist them, so they resolve through the cli2 package's REAL path — resolution from the symlink in node_modules/
// never reaches the .pnpm store. Deliberately ONLY from there, never from this script's own require root: the premise
// of this gate is that fragments are adjudicated by the same markdownlint `check-markdown` runs, and a hoisted second
// copy at a different version would quietly disagree with it.
function loadDeps() {
  const cli2 = join(ROOT, 'node_modules', 'markdownlint-cli2', 'package.json')
  if (!existsSync(cli2)) {
    return { error: `no markdownlint-cli2 under ${ROOT}/node_modules — run \`pnpm install\` first` }
  }
  const req = createRequire(realpathSync(cli2))
  try {
    return {
      jsoncPath: req.resolve('jsonc-parser'),
      lintPath: req.resolve('markdownlint/sync'),
      micromatchPath: req.resolve('micromatch'),
    }
  } catch (err) {
    return {
      error:
        `could not resolve markdownlint / micromatch / jsonc-parser from the installed markdownlint-cli2 (${err.message.split('\n')[0]}). ` +
        'This gate borrows all three from markdownlint-cli2, which pins them exactly, so that fragments are judged by ' +
        `the same linter \`check-markdown\` runs. A cli2 upgrade that drops one is the cause — add it to the root ` +
        'package.json devDependencies at the version cli2 pins, and update loadDeps() in this script.',
    }
  }
}

const deps = loadDeps()
if (deps.error) {
  console.error(`✗ ${deps.error}`)
  process.exit(1)
}
const { lint } = await import(deps.lintPath)
const { default: micromatch } = await import(deps.micromatchPath)
const { parse: parseJsonc } = await import(deps.jsoncPath)

// Emits one "error" per link/definition destination so the harvest reuses markdownlint's parser: destinations inside
// code fences, reference definitions, angle-bracket and escaped forms are then all classified exactly as the linter
// classifies them. Nested image subtrees are skipped — an image fragment is not a navigable anchor.
const harvestRule = {
  description: 'Harvest link destinations',
  function: (params, onError) => {
    const descend = (tokens, types, out = []) => {
      for (const token of tokens) {
        if (token.type === 'image') continue
        if (types.includes(token.type)) out.push(token)
        if (token.children) descend(token.children, types, out)
      }
      return out
    }
    const containers = descend(params.parsers.micromark.tokens, ['link', 'definition'])
    for (const container of containers) {
      const type =
        container.type === 'link' ? 'resourceDestinationString' : 'definitionDestinationString'
      for (const destination of descend(container.children, [type])) {
        const text = descend(destination.children, ['characterEscapeValue', 'data'])
          .map((token) => token.text)
          .join('')
        if (text) onError({ detail: text, lineNumber: destination.startLine })
      }
    }
  },
  names: ['BF-ANCHOR-HARVEST'],
  parser: 'micromark',
  tags: ['links'],
}

function readConfig() {
  const file = join(ROOT, CONFIG_REL)
  if (!existsSync(file))
    return {
      error: `✗ no ${CONFIG_REL} at ${ROOT} — this script mirrors markdownlint's file scope and cannot guess it`,
    }
  const errors = []
  const parsed = parseJsonc(readFileSync(file, 'utf8'), errors, { allowTrailingComma: true })
  if (errors.length > 0)
    return { error: `✗ unparseable ${CONFIG_REL} (${errors.length} JSONC error(s))` }
  const ignores = Array.isArray(parsed?.ignores) ? parsed.ignores : []
  // MD051's own options (ignore_case, ignored_pattern) carry over so the probes agree with the repo's linting; the
  // rule itself is forced on, because a repo that switched MD051 off still needs its cross-file anchors gated.
  const md051 = parsed?.config?.MD051
  return { ignores, md051: md051 && typeof md051 === 'object' ? md051 : true }
}

// `.git` and `node_modules` are pruned for walk cost, not scope: markdownlint's own `ignores` already excludes
// node_modules, and a `.md` inside `.git` is not authored content.
const PRUNE = new Set(['.git', 'node_modules'])

// Symlinks are FOLLOWED, mirroring markdownlint-cli2, which globs with fast-glob's default
// `followSymbolicLinks: true` — a symlinked `.md`, or a symlinked directory of them, IS linted.
// `Dirent.isFile()`/`isDirectory()` are both false for a symlink, so
// classifying by dirent alone would skip exactly those files and report a false "0 broken"; statSync resolves them
// instead. The ancestor chain, not a global seen-set, guards recursion: a link back up its own tree must stop, while
// `docs-link -> docs` must still be walked twice, because markdownlint lints both paths.
function discover(root, ignores) {
  // Ignored subtrees are pruned DURING the walk rather than filtered after it. The walk would otherwise descend into
  // .claude/worktrees/** and packages/e2e/test-results/**, where a worktree reap or a Playwright run deletes
  // directories mid-read, and an ENOENT there would abort an unrelated build. Only `<dir>/**` globs prune, because
  // only they are guaranteed to exclude everything the pruned directory holds.
  const prunable = ignores.filter((glob) => glob.endsWith('/**')).map((glob) => glob.slice(0, -3))
  const found = []
  const walk = (dir, prefix, ancestors) => {
    let entries
    try {
      entries = readdirSync(dir, { withFileTypes: true })
    } catch {
      return // markdownlint-cli2 globs with suppressErrors: true; an unreadable directory is not this gate's failure
    }
    for (const entry of entries) {
      const rel = prefix ? `${prefix}/${entry.name}` : entry.name
      const abs = join(dir, entry.name)
      let node = entry
      if (entry.isSymbolicLink()) {
        try {
          node = statSync(abs)
        } catch {
          continue // dangling link; fast-glob yields nothing for it either
        }
      }
      if (node.isDirectory()) {
        if (PRUNE.has(entry.name)) continue
        if (micromatch.isMatch(rel, prunable, { dot: true })) continue
        let real
        try {
          real = realpathSync(abs)
        } catch {
          continue
        }
        if (ancestors.has(real)) continue
        ancestors.add(real)
        walk(abs, rel, ancestors)
        ancestors.delete(real)
      } else if (node.isFile() && entry.name.endsWith('.md')) {
        found.push(rel)
      }
    }
  }
  walk(root, '', new Set([realpathSync(root)]))
  // `dot: true` matches markdownlint-cli2's own globbing, which is why `.claude/**` ignores apply at all.
  return micromatch(found, ['**/*.md', ...ignores.map((glob) => `!${glob}`)], { dot: true }).sort()
}

// APFS and HFS+ resolve paths case-insensitively, so existsSync accepts `TARGET.md` for a file named `target.md` —
// a link that then 404s on Linux and on GitHub. Match every segment against its parent directory's real entry names.
function makeResolver(root) {
  const cache = new Map()
  const namesIn = (dirRel) => {
    if (!cache.has(dirRel)) {
      let names = null
      try {
        names = new Set(readdirSync(join(root, dirRel)))
      } catch {
        names = null
      }
      cache.set(dirRel, names)
    }
    return cache.get(dirRel)
  }
  return (rel) => {
    let dir = ''
    for (const segment of rel.split('/')) {
      const names = namesIn(dir)
      if (!names?.has(segment)) return false
      dir = dir ? `${dir}/${segment}` : segment
    }
    try {
      return statSync(join(root, rel)).isFile()
    } catch {
      return false
    }
  }
}

const SCHEME_RE = /^[a-z][a-z0-9+.-]*:/iu

// Returns a link descriptor, or a string naming the category this script deliberately does not gate — so the caller
// can report the un-gated surface instead of letting it read as clean. `fragment` is null for a destination that is
// only checked to exist.
function classify(file, dest) {
  if (SCHEME_RE.test(dest) || dest.startsWith('//')) return 'external'
  const hash = dest.indexOf('#')
  const hasFragment = hash >= 0 && hash < dest.length - 1
  const fragment = hasFragment ? dest.slice(hash) : null
  const pathPart = (hash < 0 ? dest : dest.slice(0, hash)).replace(/\?.*$/u, '')
  if (pathPart === '') return hasFragment ? { fragment, sameFile: true, target: file } : 'empty'
  if (!pathPart.endsWith('.md')) return 'non-markdown'
  let decoded = pathPart
  try {
    decoded = decodeURIComponent(pathPart)
  } catch {
    // a malformed %-escape is not a path we can resolve; fall through to the literal form
  }
  // `join` normalizes `..`, so a destination that climbs past the repo root comes back with a leading `../`.
  const target = decoded.startsWith('/')
    ? decoded.slice(1)
    : join(dirname(file), decoded).split(sep).join('/')
  return { fragment, sameFile: false, target }
}

function harvest(root, files) {
  const strings = {}
  for (const file of files) strings[file] = readFileSync(join(root, file), 'utf8')
  // noInlineConfig: an inline `<!-- markdownlint-disable -->` must not be able to hide links from this gate.
  const results = lint({
    config: { 'BF-ANCHOR-HARVEST': true, default: false },
    customRules: [harvestRule],
    noInlineConfig: true,
    strings,
  })
  const links = []
  const skipped = new Map()
  for (const [file, errors] of Object.entries(results)) {
    for (const error of errors) {
      const parsed = classify(file, error.errorDetail)
      if (typeof parsed === 'string') {
        skipped.set(parsed, (skipped.get(parsed) ?? 0) + 1)
        continue
      }
      links.push({ dest: error.errorDetail, file, line: error.lineNumber, ...parsed })
    }
  }
  return { links, skipped }
}

const escapeFragment = (fragment) => fragment.replace(/[\\<>]/gu, (char) => `\\${char}`)

// Validates one target's fragments by letting MD051 answer: append a probe link per fragment to the target's own
// content and lint the result. Throws when the sentinel probe is not flagged — see SENTINEL.
function validate(root, target, fragments, md051) {
  const lines = readFileSync(join(root, target), 'utf8').split('\n')
  if (lines.at(-1) !== '') lines.push('')
  const probes = [...fragments, SENTINEL]
  const lineOf = new Map()
  for (const [index, fragment] of probes.entries()) {
    lines.push('', `[probe${index}](<${escapeFragment(fragment)}>)`)
    lineOf.set(lines.length, fragment)
  }
  const results = lint({
    config: { default: false, MD051: md051 },
    noInlineConfig: true,
    strings: { probe: lines.join('\n') },
  })
  const flagged = new Map()
  for (const error of results.probe) {
    const fragment = lineOf.get(error.lineNumber)
    if (fragment !== undefined) flagged.set(fragment, error.errorDetail ?? null)
  }
  if (!flagged.has(SENTINEL)) {
    // The remediation is to fix the TARGET, never to exclude it: link targets are read straight from disk, so
    // `ignores` in .markdownlint-cli2.jsonc has no effect on which files reach this function.
    throw new Error(
      `MD051 did not flag the sentinel probe appended to ${target}, so this fragment was never actually checked. ` +
        `The appended block did not reach the linter as markdown — most likely ${target} ends inside an unclosed ` +
        `code fence. Close it, or point the link at a file that parses. Excluding ${target} via the ${CONFIG_REL} ` +
        '`ignores` list does NOT help; this gate resolves link targets on disk regardless of it.',
    )
  }
  flagged.delete(SENTINEL)
  return flagged
}

const emptyResult = (files, links, skipped) => ({
  broken: [],
  code: 1,
  crossFile: 0,
  files,
  links,
  skipped,
  targets: 0,
})

// `quiet` suppresses per-run reporting for the self-test, which asserts on the returned shape instead.
function check({ root, ignores, md051, quiet = false }) {
  const files = discover(root, ignores)
  if (files.length === 0) {
    console.error(
      `✗ discovered 0 markdown file(s) under ${root} — the scope is wrong, not the tree; refusing to report success`,
    )
    return emptyResult(files, [], new Map())
  }
  const { links, skipped } = harvest(root, files)
  if (links.length === 0) {
    console.error(
      `✗ scanned ${files.length} file(s) and found 0 checkable link(s) — refusing to report success`,
    )
    return emptyResult(files, links, skipped)
  }

  const byTarget = new Map()
  for (const link of links) {
    if (!byTarget.has(link.target)) byTarget.set(link.target, [])
    byTarget.get(link.target).push(link)
  }

  const resolvesExactly = makeResolver(root)
  const broken = []
  const breakAll = (targetLinks, reason) => {
    for (const link of targetLinks) broken.push({ ...link, reason })
  }
  for (const [target, targetLinks] of byTarget) {
    // A `..` chain that climbs past the repo root resolves against whatever happens to sit outside it — for a
    // worktree under .claude/worktrees/, the main checkout — so the same link passes here and 404s in CI.
    if (target.startsWith('../')) {
      breakAll(targetLinks, `target resolves outside the repository root: ${target}`)
      continue
    }
    if (!resolvesExactly(target)) {
      breakAll(targetLinks, `target file not found: ${target}`)
      continue
    }
    const fragments = [...new Set(targetLinks.map((link) => link.fragment))].filter(
      (fragment) => fragment !== null,
    )
    if (fragments.length === 0) continue
    let flagged
    try {
      flagged = validate(root, target, fragments, md051)
    } catch (err) {
      // One unparseable target must not discard the findings for every target after it.
      breakAll(
        targetLinks.filter((link) => link.fragment !== null),
        err.message,
      )
      continue
    }
    for (const link of targetLinks) {
      if (link.fragment === null || !flagged.has(link.fragment)) continue
      const detail = flagged.get(link.fragment)
      broken.push({
        ...link,
        reason: detail ? `${detail} (in ${target})` : `fragment not found in ${target}`,
      })
    }
  }

  const anchors = links.filter((link) => link.fragment !== null)
  const crossFile = anchors.filter((link) => !link.sameFile).length
  if (!quiet) {
    for (const link of broken.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line)) {
      console.error(`    ${link.file}:${link.line} -> ${link.dest}   (${link.reason})`)
    }
    const skips = [...skipped.entries()]
      .sort((a, b) => b[1] - a[1])
      .map(([reason, count]) => `${count} ${reason}`)
    const skipTotal = [...skipped.values()].reduce((sum, count) => sum + count, 0)
    const summary =
      `${files.length} file(s) scanned, ${links.length} link(s) checked across ${byTarget.size} target(s) — ` +
      `${anchors.length} anchor(s) (${crossFile} cross-file, ${anchors.length - crossFile} same-file) ` +
      `plus ${links.length - anchors.length} existence-only; ` +
      `${skipTotal} destination(s) not gated (${skips.join(', ') || 'none'})`
    if (broken.length > 0) console.error(`✗ markdown anchors: ${summary} — ${broken.length} broken`)
    else console.log(`✓ markdown anchors: ${summary} — 0 broken`)
  }
  return {
    broken,
    code: broken.length > 0 ? 1 : 0,
    crossFile,
    files,
    links,
    skipped,
    targets: byTarget.size,
  }
}

const FIXTURES = {
  'linkfarm/extra.md': [
    '# Extra',
    '',
    '[via symlinked dir](../target.md#totally-bogus-anchor)',
    '',
  ].join('\n'),
  'nested/source.md': [
    '# Source',
    '',
    '## Local Heading',
    '',
    '[ok cross](../target.md#color-literals--map-to-a-palette-token)',
    '',
    '[bad cross](../target.md#renamed-laterr)',
    '',
    '[missing file](../gone.md#anything)',
    '',
    '[ok dup](../target.md#dup-1)',
    '',
    '[bad dup](../target.md#dup-2)',
    '',
    '[ok encoded](../target.md#caf%C3%A9-na%C3%AFve)',
    '',
    '[ok same-file](#local-heading)',
    '',
    '[bad same-file](#no-such-heading)',
    '',
    '[external](https://example.com/x.md#whatever)',
    '',
    '[ok fragment-less](../target.md)',
    '',
    '[bad fragment-less](../vanished.md)',
    '',
    '[bad escape](../../../../outside.md#anything)',
    '',
    '[bad case](../TARGET.md#dup-1)',
    '',
    '```md',
    '[in a fence](../target.md#not-a-real-anchor)',
    '```',
    '',
  ].join('\n'),
  'target.md': [
    '# Target',
    '',
    '## Color literals — map to a palette token',
    '',
    '## Renamed Later',
    '',
    '## Dup',
    '',
    '## Dup',
    '',
    '## Café naïve',
    '',
  ].join('\n'),
}

// `mirror` proves a symlinked DIRECTORY is walked (markdownlint lints through it) and `aliased.md` proves a
// symlinked FILE is; both are invisible to a dirent-only classification.
const FIXTURE_SYMLINKS = { 'aliased.md': 'target.md', mirror: 'linkfarm' }

const EXPECTED_BROKEN = [
  'linkfarm/extra.md:3 -> ../target.md#totally-bogus-anchor',
  'mirror/extra.md:3 -> ../target.md#totally-bogus-anchor',
  'nested/source.md:7 -> ../target.md#renamed-laterr',
  'nested/source.md:9 -> ../gone.md#anything',
  'nested/source.md:13 -> ../target.md#dup-2',
  'nested/source.md:19 -> #no-such-heading',
  'nested/source.md:25 -> ../vanished.md',
  'nested/source.md:27 -> ../../../../outside.md#anything',
  'nested/source.md:29 -> ../TARGET.md#dup-1',
]

function selfTest() {
  const scratch = join(ROOT, 'tmp')
  mkdirSync(scratch, { recursive: true })
  const dir = mkdtempSync(join(scratch, 'check-anchors-selftest-'))
  try {
    for (const [rel, content] of Object.entries(FIXTURES)) {
      mkdirSync(dirname(join(dir, rel)), { recursive: true })
      writeFileSync(join(dir, rel), content)
    }
    for (const [rel, target] of Object.entries(FIXTURE_SYMLINKS))
      symlinkSync(target, join(dir, rel))
    const result = check({ ignores: [], md051: true, quiet: true, root: dir })
    console.log(`self-test fixture: ${relative(ROOT, dir)}`)
    console.log(
      `  ${result.files.length} file(s), ${result.links.length} link(s) (${result.crossFile} cross-file), ${result.targets} target(s)`,
    )
    for (const link of result.broken)
      console.log(`  flagged  ${link.file}:${link.line} -> ${link.dest}   (${link.reason})`)

    const failures = []
    const actual = result.broken.map((link) => `${link.file}:${link.line} -> ${link.dest}`).sort()
    const expected = [...EXPECTED_BROKEN].sort()
    for (const entry of expected)
      if (!actual.includes(entry)) failures.push(`expected broken, not flagged: ${entry}`)
    for (const entry of actual)
      if (!expected.includes(entry)) failures.push(`flagged but should be clean: ${entry}`)
    for (const rel of ['aliased.md', 'mirror/extra.md'])
      if (!result.files.includes(rel))
        failures.push(`symlinked markdown not discovered: ${rel} — markdownlint would lint it`)
    if (
      result.broken.some(
        (link) =>
          link.dest === '../gone.md#anything' && !link.reason.startsWith('target file not found'),
      )
    )
      failures.push('missing target file was not reported as a missing file')
    if (result.crossFile < 5)
      failures.push(`expected at least 5 cross-file links, harvested ${result.crossFile}`)

    if (failures.length > 0) {
      for (const failure of failures) console.error(`✗ ${failure}`)
      console.error(`✗ self-test FAILED — ${SCRIPT_REL} does not detect what it claims to`)
      return 1
    }
    console.log(
      `✓ self-test passed — ${expected.length} deliberate break(s) flagged, everything else clean`,
    )
    return 0
  } finally {
    rmSync(dir, { force: true, recursive: true })
  }
}

const USAGE = [
  `usage: node ${SCRIPT_REL} [--self-test]`,
  '  (no argument)  gate: validate every cross-file and same-file markdown anchor in the repo',
  '  --self-test    negative control: assert the checker flags known-broken fixtures',
].join('\n')

const args = process.argv.slice(2)
const unknown = args.filter((arg) => arg !== '--self-test')
if (unknown.length > 0) {
  console.error(`✗ unrecognized argument(s): ${unknown.join(' ')}`)
  console.error(USAGE)
  process.exit(1)
}

if (args.includes('--self-test')) process.exit(selfTest())

const { error, ignores, md051 } = readConfig()
if (error) {
  console.error(error)
  process.exit(1)
}

try {
  process.exit(check({ ignores, md051, root: ROOT }).code)
} catch (err) {
  console.error(`✗ ${err.message}`)
  process.exit(1)
}
