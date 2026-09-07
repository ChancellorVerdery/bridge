/* Lift the Atlas design system into atlas.css, verbatim.

   The point of this file is that "verbatim" is a checkable claim rather than
   something I typed and hope I typed right. It parses Atlas's own styles.css
   into top-level blocks and copies out the ones named below, byte for byte,
   comments and all. Nothing here rewrites a declaration. Anything Mission
   Control needs that Atlas does not have goes in app.css, under its own
   heading, so the boundary between "lifted" and "authored" stays legible.

   Run:  node mkatlas.js [path-to-atlas-styles.css]
   Verify: node mkatlas.js --check   (re-extracts and diffs against atlas.css) */

const fs = require('fs');
const path = require('path');

const SRC = process.argv.find((a) => a.endsWith('.css')) || '/tmp/atlas-ref/styles.css';

/* Selectors to lift, in the order they should appear. A leading "@" matches an
   at-rule's prelude. Every one of these must be found or the build fails —
   silently shipping a shell missing .page-tab would be the whole point lost. */
const WANT = [
  ':root',
  '*',                       // box-sizing + the scrollbar-hiding pair
  '::-webkit-scrollbar',
  'html, body',
  'body',
  ':focus-visible',
  '.app',
  '.sidebar',
  '.sidebar__head',
  '.sidebar__body',
  '.sidebar__foot',
  '.brand',
  '.brand__mark',
  '.brand__img',
  '.brand__name',
  '.nav',
  '.nav__head',
  '.nav__item',
  '.nav__item:hover',
  '.nav__icon',
  '.nav__item:hover .nav__icon',
  '.nav__label',
  '.nav__dot',
  '.nav__item.is-active',
  '.nav__item.is-active::before',
  '.nav__item.is-active .nav__icon',
  '.nav__item.is-active .nav__dot',
  '.main',
  '.topbar',
  '.crumb',
  '.title',
  '.topbar__actions',
  '.page-tabs',
  '.page-tabs:empty',
  '.page-tab',
  '.page-tab:hover',
  '.page-tab.is-active',
  '.action-btn',
  '.action-btn svg',
  '.action-btn:hover',
  '.action-btn.is-active',
  '.content',
  '.content::-webkit-scrollbar',
  '.empty',
  '.plug-badge',
  '@keyframes rise',
  '@keyframes float',
  '@keyframes fade',
  '@keyframes pop',
];

/* A tiny top-level CSS splitter. Tracks brace depth, string state and comments
   so a "{" inside a url() or a comment cannot end a block early. Keeps the
   comment that immediately precedes a rule attached to it — Atlas's comments
   carry the reasoning, and dropping them would be lifting the shape without
   the argument. */
function blocks(css) {
  const out = [];
  let i = 0, depth = 0, start = 0, sel = null, inStr = null, inCom = false;
  let lastEnd = 0, curLead = '', selStart = 0, preStart = 0;
  while (i < css.length) {
    const c = css[i], c2 = css.slice(i, i + 2);
    if (inCom) { if (c2 === '*/') { inCom = false; i += 2; continue; } i++; continue; }
    if (inStr) { if (c === '\\') { i += 2; continue; } if (c === inStr) inStr = null; i++; continue; }
    if (c2 === '/*') { inCom = true; i += 2; continue; }
    if (c === '"' || c === "'") { inStr = c; i++; continue; }
    if (c === '{') {
      if (depth === 0) {
        // The prelude is everything since the last block ended, which includes
        // any section comment sitting above this rule. The selector is that
        // prelude with the comments taken out; the comments themselves are kept
        // separately so they can be carried across with the rule.
        preStart = i;
        const pre = css.slice(start, i);
        sel = pre.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\s+/g, ' ').trim();
        const lead = /((?:\/\*[\s\S]*?\*\/\s*)+)\s*[^*\/]*$/.exec(pre);
        curLead = lead ? lead[1].trim() : '';
        // Where the selector text itself starts, so the emitted rule is the
        // selector + body and never the section banner glued onto it.
        const after = /\*\/\s*/g;
        let last = 0, m;
        while ((m = after.exec(pre))) last = m.index + m[0].length;
        selStart = start + last;
      }
      depth++; i++; continue;
    }
    if (c === '}') {
      depth--;
      if (depth === 0) {
        out.push({ sel, lead: curLead, text: css.slice(selStart, i + 1).trim() });
        lastEnd = i + 1;
        start = i + 1;
        sel = null; curLead = ''; selStart = 0;
      }
      i++; continue;
    }
    if (depth === 0 && c === ';') { start = i + 1; lastEnd = i + 1; i++; continue; }
    i++;
  }
  return out;
}

function build() {
  const css = fs.readFileSync(SRC, 'utf8');
  const all = blocks(css);
  const byS = new Map();
  for (const b of all) if (!byS.has(b.sel)) byS.set(b.sel, []);
  for (const b of all) byS.get(b.sel).push(b);

  const missing = [];
  const parts = [];
  for (const want of WANT) {
    const hits = byS.get(want);
    if (!hits) { missing.push(want); continue; }
    for (const b of hits) parts.push((b.lead ? b.lead + '\n' : '') + b.text);
  }
  if (missing.length) throw new Error('not found in ' + SRC + ': ' + missing.join(', '));

  const head = [
    '/* ══ ATLAS, VERBATIM ══════════════════════════════════════════════════════',
    '',
    '   Every rule below this line was copied out of the Atlas control UI\'s own',
    '   styles.css by mkatlas.js, unedited — tokens, shell, nav, topbar, page-tabs,',
    '   buttons, fields, keyframes. The comments are Atlas\'s too. Mission Control',
    '   is not styled *like* Atlas here; it is running Atlas\'s stylesheet.',
    '',
    '   Anything Mission Control needs that Atlas does not ship lives in app.css.',
    '   Regenerate with:  node mkatlas.js /path/to/atlas/styles.css',
    '   ═══════════════════════════════════════════════════════════════════════ */',
    '',
  ].join('\n');

  return head + '\n' + parts.join('\n\n') + '\n';
}

const OUT = path.join(__dirname, 'atlas.css');
const built = build();

if (process.argv.includes('--check')) {
  const have = fs.readFileSync(OUT, 'utf8');
  if (have !== built) { console.error('atlas.css DIFFERS from a fresh extraction'); process.exit(1); }
  console.log('atlas.css matches a fresh verbatim extraction from ' + SRC);
} else {
  fs.writeFileSync(OUT, built);
  console.log('atlas.css  ' + WANT.length + ' selectors  ' + built.length + ' bytes');
}
