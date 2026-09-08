/* Bridge — render layer.

   Lifted unchanged from Mission Control v4 apart from the edits marked
   `BRIDGE:` below. v4 was a prototype over a mock corpus; Bridge is the same
   view layer over the live OpenClaw Gateway, so what changed here is only what
   had to: the data is now empty until a socket delivers it, the simulator is
   gone, and entrance animations no longer replay on every render.

   v4 is v3's information architecture inside Atlas's shell. The IA did not
   change: navigator picks a project or tool, a tab strip picks an agent inside
   it, a subagent opens beside its parent. What changed is that the chrome is now
   Atlas's — .app / .sidebar / .nav__item / .topbar / .page-tabs / .action-btn,
   the classes and the stylesheet, not a lookalike.

   The one structural move worth naming: the agent selector *is* Atlas's
   .page-tabs, the same control Atlas uses for Sleep's Board|Settings and Study's
   Calculus 2|Physics 2. One sidebar level, one page-tabs level, no nested strip.

   No storage APIs anywhere: this is meant to survive being served under
   `Content-Security-Policy: sandbox allow-scripts`, where localStorage throws.
   All state is in memory.

   Where the data comes from, for real, now:
     connection      <- Swift's WebSocket lifecycle around sessions.subscribe
     agent.status    <- sessions.list row + sessions.changed
     agent.operation <- session.tool, phase "start" with no matching "end"
     agent.headline  <- session.observer digest, else the session label
     transcript      <- chat.history, then live session.tool events
     pendingInputs   <- durably admitted inputs (queued|picked_up|interrupted)

   All of it is mapped in live.js. Nothing in this file opens a socket or sees
   the auth token; see bridge-apple/PROTOCOL.md for the wire contract. */

'use strict';

/* ───────────────────────── tiny DOM helper ─────────────────────────
   Builds nodes rather than strings, so transcript content containing `<`
   — diffs, shell output, XML — can never break out into markup. */

function h(spec, attrs, ...kids) {
  const [tag, ...classes] = String(spec).split('.');
  const n = document.createElement(tag || 'div');
  if (classes.length) n.className = classes.join(' ');
  if (attrs && attrs.constructor === Object) {
    for (const [k, v] of Object.entries(attrs)) {
      if (v === null || v === undefined || v === false) continue;
      if (k === 'class') n.className += (n.className ? ' ' : '') + v;
      else if (k === 'text') n.textContent = v;
      else if (k === 'value') n.value = v;
      else if (k === 'html') n.innerHTML = v;
      else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
      else n.setAttribute(k, v === true ? '' : String(v));
    }
  } else if (attrs !== undefined && attrs !== null) {
    kids.unshift(attrs);
  }
  for (const kid of kids.flat(4)) {
    if (kid === null || kid === undefined || kid === false) continue;
    n.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return n;
}
const $ = (sel, root = document) => root.querySelector(sel);
/* Guarded: the smoke-test DOM shim has a window with no innerHeight, and a
   layout decision that throws under test is a layout decision nobody checks. */
const viewportH = () => (typeof window !== 'undefined' && window.innerHeight) || 1050;
const mount = (id, ...kids) => {
  const n = document.getElementById(id);
  if (!n) return null;
  n.textContent = '';
  for (const k of kids.flat(4)) if (k) n.append(k);
  return n;
};

/* ───────────────────────── clock ─────────────────────────
   Mock timestamps are seconds relative to page load; negative is the past. */

const T0 = Date.now();
const nowS = () => (Date.now() - T0) / 1000;

function fmtDur(sec) {
  const s = Math.max(0, Math.round(sec));
  if (s < 60) return s + 's';
  if (s < 3600) return Math.floor(s / 60) + 'm ' + String(s % 60).padStart(2, '0') + 's';
  if (s < 86400) return Math.floor(s / 3600) + 'h ' + String(Math.floor((s % 3600) / 60)).padStart(2, '0') + 'm';
  return Math.floor(s / 86400) + 'd ' + String(Math.floor((s % 86400) / 3600)).padStart(2, '0') + 'h';
}
const fmtAgo = (at) => fmtDur(nowS() - at) + ' ago';

/* ELAPSED, AND THE RULE THAT MAKES IT MEAN SOMETHING.

   Chancellor's spec, implemented literally: a RUNNING task ticks live from its
   start; a FINISHED one freezes at its total duration, permanently. "48m" for
   a task that took 48 minutes — never "2h ago", which is a fact about the clock
   rather than about the work, and which keeps changing for something that is
   over.

   The two are drawn differently on purpose: a live one carries a trailing "…"
   so a still frame of this screen still says which kind of number it is. */
function elapsedText(startedAt, endedAt, running) {
  if (startedAt === null || startedAt === undefined) return running ? 'starting…' : '—';
  if (running) return fmtDur(nowS() - startedAt) + '…';
  if (endedAt === null || endedAt === undefined) return '—';
  return fmtDur(Math.max(0, endedAt - startedAt));
}
const fmtNum = (n) => n.toLocaleString('en-US');
const clockAt = (at) => new Date(T0 + at * 1000)
  .toLocaleTimeString('en-US', { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' });

/* ───────────────────────── state ───────────────────────── */

const STALE_AFTER = 25;   // seconds of silence before a running agent is untrustworthy
const DEAD_AFTER  = 55;   // seconds after which we stop claiming to know anything

/* BRIDGE: every one of these was safe against a mock corpus that was fully
   populated at parse time. Bridge starts empty and fills in when the Gateway
   answers, so the first paint has no categories at all and each of them has to
   survive that. */
const S = {
  catId: null,
  tab: {},           // catId -> selected agent id
  sub: null,         // selected subagent id, which opens the split pane
  connection: 'live',
  notice: null,      // {k, text, code, agentId}
  paused: false,
  frozen: false,
  simOpen: false,
  spawnSeq: 0,
  draft: {},         // agent id -> composer text, so a split pane keeps both
  palHi: 0,          // highlighted row in the slash palette

  /* ── Phase B ── */
  view: 'sessions',  // 'sessions' | 'room' | 'inbox' | 'settings'
  write: null,       // the in-flight / just-answered gateway write — see live.js §W
  ping: {},          // catId -> agent id the composer is pinging, or null
  newName: '',       // the add-a-project field
  adding: null,      // 'project' | null
  removing: null,    // projectId whose "remove?" confirmation is showing
  access: null,      // projectId whose access picker is open
  killing: null,     // 'projectId::agentId' whose "kill?" confirmation is showing

  /* ── Phase C ── the room */
  roomDraft: '',     // the main chat composer
  roomPing: null,    // agent id the next message is addressed to; null = main
  answering: null,   // the in-flight question.resolve — see live.js §Q
};

const catById = (id) => CATEGORIES.find((c) => c.id === id);
/* BRIDGE: falls forward to the first live category when the selected one has
   gone away — a session group can be renamed or emptied while you are in it. */
const category = () => catById(S.catId) || CATEGORIES[0] || null;
const allAgents = () => CATEGORIES.flatMap((c) => c.agents);
const agentById = (id) => allAgents().find((a) => a.id === id);
const catOf = (id) => CATEGORIES.find((c) => c.agents.some((a) => a.id === id));

const isMain = (a) => a.agentId === 'main';
const tabAgents = (c) => c.agents.filter((a) => !a.parent);
const kidsOf = (c, id) => c.agents.filter((a) => a.parent === id);

/* The main session's children are, conceptually, every agent it spawned — which
   in this UI is every top-level agent, and those already have page-tabs. So the
   strip runs in two modes: a roster that navigates, or subagents that split the
   pane. */
function stripFor(c, a) {
  return isMain(a) ? { mode: 'roster', list: tabAgents(c).filter((x) => !isMain(x)) }
                   : { mode: 'sub', list: kidsOf(c, a.id) };
}

function currentTabId() {
  const c = category();
  if (!c) return null;
  const want = S.tab[c.id];
  if (want && c.agents.some((a) => a.id === want && !a.parent)) return want;
  const first = tabAgents(c)[0];
  return first ? first.id : null;
}
const currentAgent = () => { const id = currentTabId(); return id ? agentById(id) : null; };

const ACTIVE = new Set(['running', 'waiting']);
const staleFor = (a) => (a.status === 'running' ? nowS() - a.lastEventAt : 0);

/* A run is untrustworthy either because it personally went quiet, or because the
   stream feeding every run has stopped delivering. The second case must flag
   every running agent the instant we know, not 25s later: a header that says
   "stale" above page-tabs still drawing themselves as live is the exact lie this
   screen exists to prevent.

   A `waiting` agent is deliberately excluded. It is not silent because the
   stream broke; it is silent because it asked a question and is waiting for an
   answer. Flagging that as stale would train you to ignore the flag. */
const isStale = (a) => a.status === 'running' && (S.connection !== 'live' || staleFor(a) > STALE_AFTER);

function counts(list) {
  const c = { running: 0, waiting: 0, completed: 0, failed: 0, queued: 0, planned: 0 };
  for (const a of list) c[a.status] = (c[a.status] || 0) + 1;
  return c;
}

const STATUS_WORD = {
  running: 'working now', waiting: 'waiting on you', completed: 'finished clean',
  failed: 'failed', queued: 'no turn claimed', planned: 'not built yet',
};

function elapsedOf(a) {
  if (a.startedAt === null || a.startedAt === undefined) return null;
  return (a.endedAt ?? nowS()) - a.startedAt;
}
function costOf(a) {
  const rate = RATES[a.model] || 10;
  return (a.tokens.total / 1e6) * rate;
}

/* Atlas's own nav glyphs, lifted from its renderer.js unedited — same viewBox,
   same 1.6 stroke, same .nav__icon class the sidebar rules already target. */
const ICONS = {
  work: '<svg class="nav__icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="7" width="18" height="13" rx="2"/><path d="M8.5 7V5.5A1.5 1.5 0 0 1 10 4h4a1.5 1.5 0 0 1 1.5 1.5V7"/><path d="M3 12.5h18"/><path d="M12 11v3"/></svg>',
  notes: '<svg class="nav__icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M5 3.5h11l3.5 3.5v13.5a0.5 0.5 0 0 1-0.5 0.5H5a0.5 0.5 0 0 1-0.5-0.5v-16a0.5 0.5 0 0 1 0.5-0.5z"/><path d="M15.5 3.5V7.5h4"/><line x1="8" y1="11" x2="16" y2="11"/><line x1="8" y1="15" x2="13.5" y2="15"/></svg>',
  study: '<svg class="nav__icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 6.3C10.4 4.9 8.4 4.2 5.8 4.2c-1.1 0-2.2.15-3.3.5V19c1.1-.35 2.2-.5 3.3-.5 2.6 0 4.6.7 6.2 2.1 1.6-1.4 3.6-2.1 6.2-2.1 1.1 0 2.2.15 3.3.5V4.7c-1.1-.35-2.2-.5-3.3-.5-2.6 0-4.6.7-6.2 2.1z"/><line x1="12" y1="6.3" x2="12" y2="20.6"/></svg>',
  settings: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><line x1="4" y1="8" x2="20" y2="8"/><line x1="4" y1="16" x2="20" y2="16"/><circle cx="10" cy="8" r="2.2"/><circle cx="15" cy="16" r="2.2"/></svg>',
  // Two additions in Atlas's exact idiom — same viewBox, same 1.6 stroke, same
  // .nav__icon class the sidebar rules already target. Not lifted (Atlas has no
  // inbox), so they are authored to match rather than copied.
  inbox: '<svg class="nav__icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 13.5h4l1.2 2.2h6.6l1.2-2.2h4"/><path d="M5.4 5.2h13.2a1 1 0 0 1 .95.68l1.95 7.62v4a1 1 0 0 1-1 1H3.5a1 1 0 0 1-1-1v-4l1.95-7.62a1 1 0 0 1 .95-.68z"/></svg>',
  // Authored in Atlas's idiom rather than lifted — Atlas has no room — same
  // viewBox, same 1.6 stroke, same .nav__icon class the sidebar already targets.
  room: '<svg class="nav__icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M4 5.5h11a1.5 1.5 0 0 1 1.5 1.5v4.5A1.5 1.5 0 0 1 15 13H8.2L5 15.6V13H4a1.5 1.5 0 0 1-1.5-1.5V7A1.5 1.5 0 0 1 4 5.5z"/><path d="M18.5 9.5H20a1.5 1.5 0 0 1 1.5 1.5v4.5A1.5 1.5 0 0 1 20 17h-1v2.4L15.8 17h-4.3"/></svg>',
  gear: '<svg class="nav__icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3.1"/><path d="M12 2.6v2.3M12 19.1v2.3M21.4 12h-2.3M4.9 12H2.6M18.6 5.4l-1.6 1.6M7 17l-1.6 1.6M18.6 18.6 17 17M7 7 5.4 5.4"/></svg>',
};
const CAT_ICON = { atlasv4: 'work', calcnotes: 'notes', education: 'study' };
/* One kind of category now, so the crumb is a constant rather than a lookup
   that used to file Education under "Agents" when it missed. */
const CRUMB_KIND = 'Projects';

/* BRIDGE: LANES is rebuilt from the live session list on every snapshot, so a
   render that races a row's arrival must not throw on a missing entry. The
   fallback names the session by its key rather than inventing a label. */
const laneName = (a) => (LANES[a.agentId] && LANES[a.agentId].name)
  || String(a.id).split(':').pop().slice(0, 12);

/* ───────────────────────── small shared pieces ───────────────────────── */

function Status(status, aborted) {
  const label = aborted && status === 'failed' ? 'aborted' : status;
  return h('span.st', { 'data-s': status },
    status === 'completed' ? h('span.tick', '✓') : h('span.dot', {
      class: status === 'running' ? 'dot-ring' : (status === 'queued' || status === 'planned' ? 'dot-hollow' : ''),
    }),
    status === 'running' ? 'running' : label);
}

/* `stale` hollows the mark out rather than recolouring it. Brass is spoken for —
   it means "an agent is waiting on you" — and a stale run is not waiting on you,
   it is a run we have stopped hearing from. A hollow green ring reads as "claims
   to be running, unverified", which is exactly the claim being made.

   It has to reach the page-tabs and the roster, not just the pane. A header that
   says the stream is dead above a tab strip still painted solid green is the
   precise lie this screen exists to prevent, and v3's first stale screenshot
   had it. */
function TabMark(s, stale) {
  return s === 'completed' ? h('span.tick', '✓')
    : h('span.tmark', { 'data-s': s, 'data-stale': stale ? '1' : '0' });
}

/* The one header summary, carried from v2. Priority is the design: a stale
   stream outranks a headcount, because a headcount drawn from a stream you
   cannot trust is a lie told confidently. Only one form is ever on screen.
   Shaped as an Atlas .action-btn so it sits in the topbar's rhythm. */
function StateSummary(conn, c, worstStale) {
  const box = (k, title, ...kids) =>
    h('span.action-btn.mc-state.state', { 'data-k': k, title }, h('span.dot'), ...kids);
  if (conn === 'stale') {
    return box('fail', 'Socket is open but no events are arriving. Displayed run state cannot be trusted.',
      'stale — ', h('b', 'no events'), worstStale ? ' for ' + fmtDur(worstStale) : '');
  }
  if (conn === 'reconnecting') {
    return box('warn', 'Socket dropped — resubscribing, then backfilling via chat.history cursor',
      'reconnecting — ', h('b', 'backfilling'));
  }
  if (worstStale > STALE_AFTER) {
    return box('warn', 'A run claims to be active but has sent nothing recently. This view may be behind.',
      h('b', fmtDur(worstStale)), ' since the last event');
  }
  if (c.waiting) {
    return box('warn', 'Agents that stopped and are waiting on an answer from you',
      h('b', c.waiting), c.waiting === 1 ? ' agent waiting on you' : ' agents waiting on you');
  }
  return box('live', 'sessions.subscribe is open and events are arriving',
    h('b', c.running), ' running · ', h('b', c.queued), ' queued');
}

/* ───────────────────────── transcript entries ───────────────────────── */

function TxEntry(e) {
  switch (e.kind) {
    case 'user':
      return h('div.e-user', h('div.e-mark', '›'), h('div.e-text', e.text));
    // Marks are U+25CF / U+25B8 / U+21B3, not the U+23FA and U+23BF that Claude
    // Code uses. Those two render as tofu boxes in a bare Linux font set — which
    // the first screenshot pass showed plainly, and which no DOM assertion would
    // ever have caught. Distinct shapes rather than two circles is also a small
    // improvement: colour is doing less work.
    case 'assistant':
      return h('div.e-asst', h('div.e-mark', '●'), h('div.e-text', e.text));
    case 'relay': {
      const lane = LANES[e.lane];
      return h('div.e-relay', h('div.e-mark', '↳'),
        h('div', null,
          h('div.e-relay-l', h('button', { onclick: () => jumpToLane(e.lane) }, lane ? lane.name : e.lane)),
          h('div.e-text', e.text)));
    }
    case 'system':
      return h('div.e-sys', e.text, ' · ', h('span.e-time', clockAt(e.at)));
    case 'error':
      return h('div.e-err', e.text);
    case 'tool':
      return h('div.e-tool', { 'data-s': e.status === 'ok' ? 'ok' : 'err' },
        h('div.e-mark', '▸'),
        h('div', null,
          h('div.tool-call', h('b', null, e.name), h('span.tool-args', '(' + fmtArgs(e.args) + ')')),
          h('div.tool-res', e.result)));
    case 'diff':  return DiffBlock(e);
    case 'shell': return ShellBlock(e);
    case 'log':   return LogBlock(e);
    default:      return h('div.e-sys', e.kind);
  }
}

function fmtArgs(args) {
  return Object.entries(args).map(([k, v]) => {
    const val = typeof v === 'string' ? v : JSON.stringify(v);
    const short = val.length > 64 ? val.slice(0, 61) + '…' : val;
    return k === 'file_path' || k === 'command' ? short : k + ': ' + short;
  }).join(', ');
}

function DiffBlock(e) {
  const pre = h('pre');
  for (const hunk of e.hunks) {
    pre.append(h('span.dl', { 'data-t': 'h' }, hunk.header + '\n'));
    for (const l of hunk.lines) pre.append(h('span.dl', { 'data-t': l.t }, l.t + l.s + '\n'));
  }
  return h('div.blk',
    h('div.blk-h', h('b', null, e.file), h('span.spacer'),
      h('span.add', '+' + e.added), h('span.del', '−' + e.removed)),
    h('div.blk-b', pre));
}

function ShellBlock(e) {
  const pre = h('pre');
  pre.append(h('span.sh-cmd', e.cmd + '\n'));
  if (e.out) pre.append(h('span.sh-out', e.out + '\n'));
  return h('div.blk',
    h('div.blk-h', h('b', null, 'bash'), h('span.spacer'),
      h('span', { class: e.exit === 0 ? 'add' : 'del' }, 'exit ' + e.exit)),
    h('div.blk-b', pre));
}

function LogBlock(e) {
  const pre = h('pre');
  for (const l of e.lines) {
    pre.append(h('span.log-l', { 'data-bad': /✗|error|failed|→ expected/i.test(l) ? '1' : '0' }, l + '\n'));
  }
  if (e.tailing && !S.frozen && !S.paused) pre.append(h('span.log-cursor'));
  return h('div.blk',
    h('div.blk-h', h('b', null, e.title), h('span.spacer'),
      e.tailing ? h('span', { class: S.frozen ? 'del' : '' }, S.frozen ? 'tail interrupted' : 'tailing') : 'ended'),
    h('div.blk-b.log-b', { 'data-tail': e.tailing ? '1' : '0' }, pre));
}

/* ── the four states a sent message can actually reach ── */

function QueueItem(p) {
  const labels = { queued: 'queued', picked_up: 'picked up', delivered: 'delivered',
    interrupted: 'dropped', cancelled: 'dropped' };
  const detail = {
    queued: () => 'sent ' + fmtAgo(p.queuedAt) + ' · session had an active turn claim · waiting for the agent\'s next step',
    picked_up: () => 'queued ' + fmtAgo(p.queuedAt) + ' · picked up ' + fmtAgo(p.pickedUpAt) + ' · now in the transcript',
    delivered: () => 'delivered ' + fmtAgo(p.queuedAt) + ' · session was idle, started a new turn',
    interrupted: () => 'queued ' + fmtAgo(p.queuedAt) + ' · never acted on — ' + (p.reason || 'run ended first') + ' · retained for inspection',
    cancelled: () => 'queued ' + fmtAgo(p.queuedAt) + ' · cancelled before pickup · retained for inspection',
  }[p.state];
  const why = detail();
  return h('div.qi', { 'data-s': p.state, title: p.text + '\n\n' + why },
    h('div', null, h('div.qi-t', p.text), h('div.qi-m', why)),
    h('span.qi-s', labels[p.state]));
}

/* ───────────────────────── topbar ───────────────────────── */

/* Failure is the loudest thing on screen, and in this shell that means above the
   page title rather than inside the content. When nothing has failed the band
   does not exist and takes no height, so its appearance is itself the signal.
   It spans every category — switching away from a broken project should not make
   the project look fixed. */
function Alarm() {
  const rows = [];
  for (const c of CATEGORIES) {
    for (const a of c.agents) if (a.status === 'failed') rows.push([c, a]);
  }
  if (!rows.length) return null;
  const band = h('div.alarm', { 'data-enter': 'alarm:' + rows.map(([, a]) => a.id).join(',') },
    h('b', rows.length === 1 ? 'failed' : rows.length + ' failed'));
  // Each message is clipped to one line's worth. Two untruncated failures wrapped
  // the band to 70px, and a band that grows with the number of things wrong is a
  // band that pushes the work off screen exactly when you need it most.
  const clip = (s) => (s.length > 62 ? s.slice(0, 60).replace(/[\s,;—-]+$/, '') + '…' : s);
  rows.forEach(([c, a], i) => {
    if (i) band.append(h('span.alarm-sep', '/'));
    band.append(h('button.alarm-item', { title: a.error ? a.error.message : a.headline,
      onclick: () => jumpTo(c.id, a.id) },
      h('i', c.name + ' · '), clip(laneName(a) + ' — ' + (a.error ? a.error.message : a.headline))));
  });
  return band;
}

/* BRIDGE: v4's "Simulate" popover drove the mock corpus. There is no mock
   corpus, so it is gone rather than left as a dead button. */
/* There is no "Customize" any more. A project holds a FULL set of agent clones
   by definition — that is what makes it the unit of isolation — so a picker that
   let you deselect some of them would be a control for making the invariant
   false. Agents join a project by existing on the gateway; see
   `reconcileRosters` in live.js. */
function TopbarActions() {
  const live = allAgents().filter((a) => !a._placeholder);
  const c = counts(live);
  const worstStale = Math.max(0, ...live.filter((a) => a.status === 'running').map(staleFor));
  return [StateSummary(S.connection, c, worstStale)];
}

/* ───────────────────────── navigator ─────────────────────────
   Atlas's .nav__item, unchanged: icon, label, trailing dot, brass rail when
   active. The one addition is a mono status line under the name, because a
   navigator that cannot tell you which project is on fire is decoration. */

function Nav() {
  const nav = document.getElementById('nav');
  if (!nav) return;
  nav.textContent = '';

  /* The inbox sits ABOVE the sections, as its own item rather than inside one:
     it is not a project and it is not a tool, and filing it under either would
     say something false about what it is. The unread count rides on the sidebar
     item itself — Atlas already has .plug-badge for exactly this, and the nav
     rules already position it. */
  /* NO INBOX in the sidebar. The redesign's navigator is Projects and Tools
     only (design artifact + Chancellor's spec). The inbox view still exists in
     code but is no longer linked from the sidebar. */
  /* THERE IS NO "ROOM" ENTRY HERE, and that is the point of this pass. A room
     belongs to a PROJECT now — it is that project's first tab — so a single
     global Room in the sidebar would be a link to a conversation that no longer
     exists. Inbox is the only cross-project view, and it stays above the
     sections because it is not a project and filing it under one would say
     something false about what it is. */

  for (const sec of NAV_SECTIONS) {
    const box = h('div.nav__sec', h('p.nav__head', { 'data-enter': 'navhead:' + sec.title }, sec.title));
    for (const id of sec.ids) {
      const c = catById(id);
      if (!c) continue;
      const real = c.agents.filter((a) => !a._placeholder);
      const k = counts(real);
      const sub = h('span.nav__sub');
      const bits = [];
      if (k.running) bits.push(h('em', k.running + ' running'));
      if (k.waiting) bits.push(h('i', k.waiting + ' waiting'));
      // A project's line reports its ROOM and its clone count, because those
      // are the two things that tell you whether to open it. "no sessions" was
      // Phase B's answer and it is now always wrong in the same way: a project
      // always has its full set of clones, whether or not any has been spoken to.
      const room = typeof roomOf === 'function' ? roomOf(c.id) : null;
      if (room && room.messages.length) {
        const last = room.messages[room.messages.length - 1];
        const who = last.from === 'chancellor' ? 'you'
          : last.from === 'bridge' ? 'Bridge' : last.from;
        bits.push(room.messages.length + ' in room · last from ' + who);
      } else if (!bits.length) {
        bits.push(real.length ? 'idle' : 'nothing said yet');
      }
      // Two numbers, because they are two different facts now: who MAY work
      // here, and who actually is. "9 agents" was the old line and it was the
      // old assumption talking.
      if (c.access && c.access.length) {
        const live = (c.clones || []).length;
        bits.push(c.access.length + ' with access');
        bits.push(live ? live + ' launched' : 'none launched');
      }
      bits.forEach((b, i) => { if (i) sub.append(' · '); sub.append(b); });

      const active = c.id === S.catId && S.view === 'sessions';
      box.append(h('div.nav__wrap',
        h('a.nav__item', {
          class: active ? 'is-active' : '',
          href: '#/' + c.id,
          'aria-current': active ? 'true' : 'false',
          onclick: (ev) => { ev.preventDefault(); selectCat(c.id); },
        },
          h('span.mc-ico', { html: ICONS[CAT_ICON[c.id]] || ICONS.work }),
          h('span.nav__col',
            h('span.nav__row',
              h('span.nav__label', c.name),
              (room && room.paused) ? h('span.plug-badge.nav__fail', 'paused')
                : k.failed ? h('span.plug-badge.nav__fail', k.failed) : null),
            sub),
          h('span.nav__dot')),
        /* REMOVE. There was no way to remove a project at all — a list you can
           only add to is a list that fills with mistakes, and two of them
           ("Diagnostics", "Empty Project") had been sitting in this sidebar for
           days with no control that could take them out. Two-step, because
           removing a project drops its rooms with it and that is not something
           to do on one stray click. */
        S.removing === c.id
          ? h('div.nav__rm',
              h('span', 'Remove ' + c.name + ' and its rooms?'),
              h('button.add-go', { onclick: fromUser(() => { removeProject(c.id); }) }, 'Remove'),
              h('button.add-x', { onclick: () => { S.removing = null; renderAll(); } }, '×'))
          : h('button.nav__rm-b', {
              title: 'Remove ' + c.name,
              'aria-label': 'Remove ' + c.name,
              onclick: (ev) => { ev.preventDefault(); S.removing = c.id; renderAll(); },
            }, '×')));
    }

    /* Add a project. Inline in the section it adds to, because a "+" in a
       toolbar somewhere else is a control you have to go looking for.
       `fromUser` is not decoration: it sets the intent token that
       `projectCreate` requires, and it is the only place in the app that does.
       See live.js, door 2. */
    if (sec.add) {
      if (S.adding === sec.add) {
        const input = h('input.add-in', {
          value: S.newName, autofocus: true,
          placeholder: 'Project name…',
          oninput: (ev) => { S.newName = ev.target.value; },
          onkeydown: fromUser((ev) => {
            if (ev.key === 'Enter') { ev.preventDefault(); commitAdd(); }
            if (ev.key === 'Escape') { S.adding = null; S.newName = ''; renderAll(); }
          }),
        });
        box.append(h('div.add-row', input,
          h('button.add-go', { onclick: fromUser(() => commitAdd()) }, 'Add'),
          h('button.add-x', { onclick: () => { S.adding = null; S.newName = ''; renderAll(); } }, '×')));
      } else {
        box.append(h('button.nav__add', {
          onclick: () => { S.adding = sec.add; S.newName = ''; renderAll(); },
        }, h('span', '+'), 'New project'));
      }
    }
    nav.append(box);
  }

  /* TOOLS — a second section below Projects. A tool is NOT a project: it is a
     single-agent utility that, for now, opens a blank page. Its own section,
     its own create/remove, so the sidebar says plainly that the two are
     different kinds of thing. Tool ids are `t-…`, project ids `p-…`, so a
     shared S.removing / S.adding never confuses one for the other. */
  const toolBox = h('div.nav__sec', h('p.nav__head', { 'data-enter': 'navhead:Tools' }, 'Tools'));
  for (const t of (typeof PREFS !== 'undefined' ? PREFS.tools : [])) {
    const active = S.view === 'tool' && S.toolId === t.id;
    toolBox.append(h('div.nav__wrap',
      h('a.nav__item', {
        class: active ? 'is-active' : '',
        href: '#/tool/' + t.id,
        'aria-current': active ? 'true' : 'false',
        onclick: (ev) => { ev.preventDefault(); openTool(t.id); },
      },
        h('span.mc-ico', { html: ICONS.work }),
        h('span.nav__col',
          h('span.nav__row', h('span.nav__label', t.name)),
          h('span.nav__sub', 'tool · blank for now')),
        h('span.nav__dot')),
      S.removing === t.id
        ? h('div.nav__rm',
            h('span', 'Remove ' + t.name + '?'),
            h('button.add-go', { onclick: fromUser(() => { removeTool(t.id); }) }, 'Remove'),
            h('button.add-x', { onclick: () => { S.removing = null; renderAll(); } }, '×'))
        : h('button.nav__rm-b', {
            title: 'Remove ' + t.name,
            'aria-label': 'Remove ' + t.name,
            onclick: (ev) => { ev.preventDefault(); S.removing = t.id; renderAll(); },
          }, '×')));
  }
  if (S.adding === 'tool') {
    const input = h('input.add-in', {
      value: S.newName, autofocus: true,
      placeholder: 'Tool name…',
      oninput: (ev) => { S.newName = ev.target.value; },
      onkeydown: fromUser((ev) => {
        if (ev.key === 'Enter') { ev.preventDefault(); commitAdd(); }
        if (ev.key === 'Escape') { S.adding = null; S.newName = ''; renderAll(); }
      }),
    });
    toolBox.append(h('div.add-row', input,
      h('button.add-go', { onclick: fromUser(() => commitAdd()) }, 'Add'),
      h('button.add-x', { onclick: () => { S.adding = null; S.newName = ''; renderAll(); } }, '×')));
  } else {
    toolBox.append(h('button.nav__add', {
      onclick: () => { S.adding = 'tool'; S.newName = ''; renderAll(); },
    }, h('span', '+'), 'New tool'));
  }
  nav.append(toolBox);
}

/* The line under "Inbox". It reports the real shape of the feed rather than a
   single number, because "3" alone does not say three of what. */
function inboxSub() {
  if (typeof INBOX === 'undefined') return 'starting';
  const unread = inboxUnread();
  const m = INBOX.meta || {};
  if (!INBOX.length) return m.inFlight ? m.inFlight + ' in flight · none finished' : 'nothing yet';
  return (unread ? unread + ' unread · ' : '') + INBOX.length + ' completed';
}

/* BRIDGE: v4's foot said "prototype · mock corpus". This one has to be true, so
   it reports the live connection and the gateway build actually answering. */
function SidebarFoot() {
  const L = typeof LIVE === 'undefined' ? null : LIVE;
  const conn = L ? L.connection : 'connecting';
  const line2 = !L ? 'starting'
    : conn === 'live' ? 'gateway ' + (L.serverVersion || '·') + (L.readOnly ? ' · read-only' : '')
    : (L.detail || conn);
  mount('sidebar-foot',
    h('button.foot-set', {
      class: S.view === 'settings' ? 'is-active' : '',
      onclick: () => openSettings(),
    }, h('span.mc-ico', { html: ICONS.gear }), 'Settings'),
    h('div.mc-foot', { 'data-conn': conn },
    conn === 'live' ? 'Connected' : conn === 'reconnecting' ? 'Reconnecting…'
      : conn === 'connecting' ? 'Connecting…' : conn === 'stale' ? 'Stream stalled' : 'Not connected',
    h('br'), line2));
}

/* ───────────────────────── the agent selector ─────────────────────────
   This is Atlas's .page-tabs — literally the control that gives Sleep its
   Board | Settings and Study its Calculus 2 | Physics 2. Selection is carried by
   Atlas's brass .is-active exactly as Atlas draws it; run state is carried by
   the dot inside, so the two never fight for the same channel. */

function PageTabs(c) {
  const cur = currentTabId();
  const el = document.getElementById('page-tabs');
  if (!el) return;
  el.textContent = '';
  for (const a of tabAgents(c)) {
    const strip = stripFor(c, a);
    const stale = isStale(a);
    el.append(h('a.page-tab', {
      class: a.id === cur ? 'is-active' : '',
      href: '#/' + c.id + '/' + a.id,
      'data-s': a.status, 'data-id': a.id, 'data-stale': stale ? '1' : '0',
      'aria-current': a.id === cur ? 'page' : 'false',
      title: laneName(a) + ' — ' + (stale ? 'claims to be running, but has gone quiet' : STATUS_WORD[a.status]),
      onclick: (ev) => { ev.preventDefault(); selectTab(a.id); },
    },
      TabMark(a.status, stale),
      a.kind === 'room' ? 'Main' : laneName(a),
      strip.list.length ? h('span.tab-kids', strip.list.length) : null));
  }
  // The strip is capped at two rows (see .page-tabs in app.css), so on a
  // category with many sessions the active tab can land below the fold. A cap
  // that can hide the tab you are on is worse than the unbounded strip it
  // replaced, so it is scrolled into view — within the strip only, never the
  // page, which is why this is scrollTop arithmetic and not scrollIntoView.
  const act = el.querySelector('.page-tab.is-active');
  if (act && el.scrollHeight > el.clientHeight + 2) {
    const top = act.offsetTop - el.offsetTop;
    if (top < el.scrollTop) el.scrollTop = top;
    else if (top + act.offsetHeight > el.scrollTop + el.clientHeight) {
      el.scrollTop = top + act.offsetHeight - el.clientHeight;
    }
  }
}

/* ───────────────────────── subagent strip ───────────────────────── */

function Strip(c, a) {
  const { mode, list } = stripFor(c, a);
  const box = h('div.strip', { 'data-enter': 'strip:' + c.id + ':' + a.id });
  const head = h('div.strip-h',
    mode === 'roster' ? 'Sessions in ' + c.name : 'Subagents of ' + laneName(a),
    h('span.spacer'));
  if (mode === 'sub' && list.length) {
    head.append(h('em', S.sub ? 'showing one beside its parent' : 'click one to open it beside this transcript'));
  } else if (mode === 'roster') {
    head.append(h('em', 'spawned by this session · each has a tab above'));
  }
  /* THE WAY IN TO THE ACCESS PICKER. On the strip rather than in the room header
     because it renders on every tab in the project, and the decision it opens —
     kill this clone, or leave it idle — is one he makes while looking at the
     clone that just finished, not after navigating back to the room. */
  head.append(h('button.btn.strip-ag', {
    title: 'Who can work in ' + c.name + ', and what their clones are doing',
    onclick: () => { S.access = c.id; S.killing = null; renderAll(); },
  }, 'agents'));
  box.append(head);

  if (!list.length) {
    box.append(h('div.strip-none', mode === 'roster'
      ? 'No agents have been spawned in this category.'
      : a.status === 'planned'
        ? 'None — there is no session here yet, so there is nothing to spawn from.'
        : 'No subagents. This run has not spawned any child sessions.'));
    return box;
  }

  box.append(mode === 'roster'
    ? h('div.rost', list.map((k) => RosterRow(k)))
    : h('div.strip-row', list.map((k) => SubCard(c, k, mode))));
  return box;
}

/* Category roster: one line per agent, aligned so it can be scanned rather than
   read. Drawn as cards it measured 291px of a 963px viewport and left the main
   transcript two lines — see the note in app.css. */
function RosterRow(k) {
  const el = elapsedOf(k);
  const stale = isStale(k);
  return h('button.rost-row', {
    'data-s': k.status, 'data-id': k.id, 'data-stale': stale ? '1' : '0',
    title: laneName(k) + ' — ' + STATUS_WORD[k.status] + ' · open its tab',
    onclick: () => selectTab(k.id),
  },
    TabMark(k.status, stale),
    h('span.rost-n', laneName(k)),
    h('span.rost-h', k.headline),
    h('span.rost-t', el === null ? 'not started' : fmtDur(el)));
}

/* The strip item carries what Claude Code's subagent list withholds: the live
   operation. Prompt, tokens and elapsed are the floor — this is the ceiling in
   the space available, and one click gets you the whole transcript. */
function SubCard(c, k, mode) {
  const el = elapsedOf(k);
  const stale = isStale(k);
  const card = h('button.sub', {
    'data-s': k.status, 'data-mode': mode, 'data-id': k.id, 'data-stale': stale ? '1' : '0',
    'aria-pressed': mode === 'sub' && S.sub === k.id ? 'true' : 'false',
    title: mode === 'roster' ? 'Go to the ' + laneName(k) + ' tab' : 'Open beside the parent transcript',
    onclick: () => (mode === 'roster' ? selectTab(k.id) : toggleSub(k.id)),
  },
    h('div.sub-top',
      TabMark(k.status, stale),
      h('span.sub-name', laneName(k)),
      h('span.spacer'),
      h('span.sub-el', el === null ? 'not started' : fmtDur(el)),
      mode === 'roster' ? h('span.sub-go', '→') : null),
    h('div.sub-head', k.headline));

  const op = h('div.sub-op');
  if (k.status === 'running' && k.operation) {
    op.append(h('b', k.operation.label), h('span', k.operation.detail));
  } else if (k.status === 'waiting') {
    op.append(h('b', 'asked'), h('span', 'waiting ' + fmtDur(nowS() - k.question.askedAt) + ' for an answer'));
  } else if (k.status === 'failed') {
    op.append(h('b', 'failed'), h('span', k.error ? k.error.message : 'run ended badly'));
  } else if (k.status === 'completed') {
    op.append(h('span', 'finished · ' + fmtNum(k.tokens.total) + ' tokens'));
  } else if (k.status === 'planned') {
    op.append(h('span', 'no session created'));
  } else {
    op.append(h('span', 'no turn claimed'));
  }
  card.append(op);
  return card;
}

/* ───────────────────────── agent pane ───────────────────────── */

function Pane(a, role, c) {
  const pane = h('section.pane', { 'data-role': role, 'data-s': a.status, 'data-id': a.id });
  const laneLabel = laneName(a);
  const head = h('div.p-h');
  const par = role === 'sub' ? agentById(a.parent) : null;

  head.append(h('div.p-h-top',
    par ? h('button.crumb-back.crumb', { title: 'Back to ' + laneName(par),
      onclick: () => toggleSub(null) },
      h('span', '←'), h('span', laneName(par)), h('span', '/')) : null,
    h('span.p-title', laneLabel),
    Status(a.status, a.aborted),
    h('span.spacer'),
    // BRIDGE: abort needs operator.write. Offering a button whose only
    // possible outcome is a refusal is clutter; the composer already explains
    // the read-only connection once, where it belongs.
    a.status === 'running' && !(typeof LIVE !== 'undefined' && LIVE.readOnly)
      ? h('button.btn', { 'data-danger': '1', title: 'chat.abort — immediate, unlike a queued steer',
          onclick: () => abortRun(a) }, 'abort run')
      : null,
    role === 'sub' ? h('button.btn', { onclick: () => toggleSub(null) }, 'close') : null,
  ));

  // BRIDGE: the headline sits directly under the pane title, which is the
  // session's label. When they are the same sentence — a session with no
  // observer digest and no assistant turn yet — printing both is noise.
  if (a.headline && a.headline !== laneLabel) head.append(h('div.p-head', a.headline));

  // What it is doing right now.
  const op = h('div.p-op');
  if (a.status === 'running' && a.operation) {
    op.append(h('b', a.operation.label), h('span.p-op-d', a.operation.detail),
      h('span.p-op-t', '· ' + fmtDur(nowS() - a.operation.startedAt)));
  } else if (a.status === 'running') {
    op.append(h('b', 'thinking'), h('span.p-op-d', 'no tool call in flight'));
  } else if (a.status === 'waiting' && a.question) {
    // The Ask box directly below says "asked 4m ago · nothing is running" in its
    // own header. Printing it here as well cost 20px of transcript to repeat a
    // sentence the reader has not finished the first copy of.
    /* nothing: the Ask box carries it */
  } else if (a.status === 'waiting') {
    op.append(h('span.p-op-idle', 'stopped — nothing is running until you answer'));
  } else if (a.status === 'planned') {
    op.append(h('span.p-op-idle', 'no session exists for this agent'));
  } else if (a.status === 'queued') {
    op.append(h('span.p-op-idle', 'queued — no turn claimed yet'));
  } else {
    op.append(h('span.p-op-idle', a.status === 'failed' ? 'run ended · nothing in flight' : 'turn ended clean · nothing in flight'));
  }
  if (op.childNodes.length) head.append(op);
  pane.append(head);

  if (a.status === 'failed' && a.error) {
    pane.append(h('div.err-box', a.error.message,
      a.error.code ? h('code', null, '  exit ' + a.error.code) : null));
  }
  if (a.status === 'waiting' && a.question) pane.append(Ask(a));

  if (S.notice && S.notice.agentId === a.id) {
    pane.append(h('div.notice', { 'data-k': S.notice.k, 'data-enter': 'notice:' + a.id + ':' + S.notice.k },
      h('span.dot'), S.notice.text, S.notice.code ? h('code', null, ' ' + S.notice.code) : null));
  } else if (isStale(a)) {
    pane.append(h('div.notice', { 'data-k': staleFor(a) > DEAD_AFTER ? 'fail' : 'warn',
      'data-enter': 'stale:' + a.id }, h('span.dot'),
      'Last event ' + fmtDur(staleFor(a)) + ' ago while this run claims to be active. '
      + (staleFor(a) > DEAD_AFTER ? 'Treat everything below as out of date.' : 'This view may be behind.')));
  }

  if (a.status === 'planned') { pane.append(PlanBody(a)); pane.append(Foot(a, c, role)); return pane; }

  const tx = h('div.tx', { id: 'tx-' + role, 'data-agent': a.id });
  const entries = [...(a.transcript || [])].sort((x, y) => x.at - y.at);
  if (!entries.length) tx.append(h('div.empty', { 'data-enter': 'tx-empty:' + a.id },
    a.totalMessages ? 'Transcript not backfilled yet.' : 'No transcript yet — no turn has been claimed.'));
  for (const e of entries) tx.append(TxEntry(e));
  if (a.status === 'running' && a.operation) {
    tx.append(h('div.e-tool', h('div.e-mark', '▸'),
      h('div', null,
        h('div.tool-call', h('b', a.operation.label), h('span.tool-args', '(' + a.operation.detail + ')')),
        h('div.tool-res', 'running ' + fmtDur(nowS() - a.operation.startedAt) + '…'))));
  }
  pane.append(tx);
  pane.append(Foot(a, c, role));
  return pane;
}

/* The amber state, made actionable. An agent that has stopped to ask something
   and only shows you a colour is a differently-painted "running". */
function Ask(a) {
  const q = a.question;
  return h('div.ask', { 'data-enter': 'ask:' + a.id },
    h('div.ask-k', 'Waiting on you', h('span', 'asked ' + fmtAgo(q.askedAt) + ' · nothing is running')),
    h('div.ask-t', q.text),
    h('div.ask-row', q.options.map((o) =>
      h('button.ask-btn', { onclick: () => answer(a, o) }, o.label))));
}

/* Education. The real agent view, with the transcript replaced by written scope.
   Fabricating a tutoring session here would make the screenshot better and the
   prototype worse: it would be the one pane in this file lying about its state. */
function PlanBody(a) {
  const p = a.plan;
  if (!p) return h('div.plan', h('div.plan-lede', 'Planned. No session has been created for this agent.'));
  // A tool tab's placeholder carries only a purpose: it is stating what this
  // pane WOULD hold, which is the whole requirement for an empty tool tab. The
  // two-column form is for a real plan and is skipped when there is none.
  if (!p.willDo || !p.notBuilding) return h('div.plan', h('div.plan-lede', p.purpose));
  return h('div.plan',
    h('div.plan-lede', p.purpose),
    h('div.plan-cols',
      h('div.plan-col', { 'data-k': 'yes' }, h('h4', 'Will do'),
        // One child, not two. `li::before` is itself a grid item, so an extra
        // spacer span pushed the text into the 14px marker column and every
        // entry rendered one word per line.
        h('ul', p.willDo.map((t) => h('li', h('span', t))))),
      h('div.plan-col', { 'data-k': 'no' }, h('h4', 'Deliberately not building now'),
        h('ul', p.notBuilding.map((t) => h('li', h('span', t)))))));
}

/* ───────────────────────── the steering panel ─────────────────────────
   Prose steers the agent. A leading "/" turns it into a command line against
   this session — the palette lists only commands that actually run.

   Vertical order is the specification, not a preference:
     1 header · 2 queued messages · 3 commands · 4 input · 5 metadata strip. */

const COMMANDS = [
  { name: '/status',    args: '',      desc: 'Print run state, usage and the pending queue into the transcript' },
  { name: '/subagents', args: '',      desc: 'List this agent\'s children and what each is doing right now' },
  { name: '/model',     args: '<id>',  desc: 'Switch model for the next turn — opus-5, sonnet-5, haiku-4-5' },
  { name: '/compact',   args: '',      desc: 'Compact the context window and report what was reclaimed' },
  { name: '/abort',     args: '',      desc: 'chat.abort — stops the run now. Unlike a steer, this is not queued' },
  { name: '/clear',     args: '',      desc: 'Clear the composer and any transient notice' },
  { name: '/help',      args: '',      desc: 'List the commands this prototype actually implements' },
];
const matchCommands = (text) => {
  const word = text.split(/\s/)[0].toLowerCase();
  return COMMANDS.filter((c) => c.name.startsWith(word));
};

/* Where a bare message goes, resolved from the text as it is typed. Carried from
   v2 for the main session, where "@lane" is how you address one agent from the
   category-wide conversation. */
function routeFor(c, text) {
  const m = /(?:^|\s)@([a-z][a-z0-9-]*)/i.exec(text || '');
  const lane = m ? m[1].toLowerCase() : null;
  if (!lane) return { k: 'cast', text: 'the ' + c.name + ' main session — no agent\'s run is touched' };
  if (!LANES[lane]) return { k: 'cast', text: '@' + lane + ' is not a lane — this stays in the main session' };
  const a = tabAgents(c).find((x) => x.agentId === lane);
  if (!a) return { k: 'cast', text: LANES[lane].name + ' has no session in ' + c.name + ' — nothing to deliver to' };
  return a.status === 'running'
    ? { k: 'queue', text: LANES[lane].name + ' — mid-turn, so this is admitted to a pending queue and picked up at its next step' }
    : { k: 'cast', text: LANES[lane].name + ' — ' + STATUS_WORD[a.status] + ', so this is delivered immediately and starts a turn' };
}

/* 5 — the metadata strip. Labelled pairs in Atlas's mono label style, in the
   order Chancellor specified, sitting under the input rather than in a header
   card: elapsed · context · tokens · cost · model · tools & edits. */
function UsageStrip(a, c) {
  const el = elapsedOf(a);
  const pair = (label, value) => h('span', null, h('b', label), h('i', value));
  const use = h('div.p-use',
    pair('elapsed', elapsedText(a.startedAt, a.endedAt, a.status === 'running')),
    /* CONTEXT IS ONE NUMBER: THE TOKENS USED. No maximum, no fill bar, no
       percentage — Chancellor knows his models' context sizes, and a 3%-full
       meter is 40 pixels spent restating something he already knows while
       hiding the number he actually wanted.

       Phase B printed `contextTokens`, which is the resolved context WINDOW —
       it reads 1,000,000 on a 1m session and is not a usage figure at all. The
       used count is the row's `totalTokens`, which is what the gateway reports
       as the context the last turn actually occupied. A row mid-turn says
       totalTokensFresh: false and reports 0; a confident "0" on a session that
       has been working for half an hour is worse than a stated gap. */
    pair('context', a.tokensSettled ? fmtNum(a.tokens.total) + ' tokens' : 'not settled mid-turn'),
    pair('cost', a.tokensSettled ? '≈$' + costOf(a).toFixed(2) : '—'),
    pair('model', a.model),
    pair('tools & edits', fmtNum(a.tools) + ' · ' + fmtNum(a.edits) + ' edits'));
  // BRIDGE: v4 assembled a plausible-looking session key from three ids. The
  // real one arrives on the row, so it is printed verbatim; cwd is not on a
  // sessions.list row at all and says so rather than guessing.
  const where = h('div.p-use-2',
    h('span', null, h('b', 'session '), a.sessionKey || a.id),
    h('span', null, h('b', 'cwd '), a.cwd || 'not reported by the gateway'));
  return [use, where];
}

function Foot(a, c, role) {
  const box = h('div.foot');
  const running = a.status === 'running';
  const text = S.draft[a.id] || '';
  const cmdMode = text.startsWith('/');
  // PHASE B: the box is LIVE. Phase A disabled it because sending would need
  // operator.write and failing at submit time is worse than saying so up front.
  // That reasoning inverts once the send path is real: a disabled box cannot
  // demonstrate the refusal, and the refusal — with the exact scope on it — is
  // the actionable thing. So the composer sends for real, the gateway answers
  // FORBIDDEN, and WriteState below draws that answer. See live.js §W.
  const readOnly = typeof LIVE !== 'undefined' && LIVE.readOnly;
  const off = a.status === 'planned' || !a.sessionKey;

  /* 1 — header. */
  box.append(h('div.foot-h',
    // BRIDGE: a.agentId is the per-session lane key (`lane:<sessionKey>`), which
    // printed the whole key in the header. a.lane is the real agent id.
    isMain(a) ? 'Message ' + c.name : 'Steer ' + (a.lane || a.agentId),
    h('span.spacer'),
    h('em', off ? 'no session — nothing to send to'
      : running ? 'mid-turn — a plain message will queue'
      : a.status === 'waiting' ? 'waiting on you — a reply resumes the run'
      : 'no active turn — a message starts one')));

  /* 2 — queued messages. Ordered by what is still owed, not by clock: anything
     still queued outranks anything already dropped, which outranks anything
     already picked up and therefore visible in the transcript above.

     Capped at three. Left uncapped with a max-height, the fourth item was sliced
     through the middle of its own text — which reads as broken rather than as
     scrolled — and the queue ate the transcript it is supposed to annotate. What
     overflows is summarised rather than hidden, because a steering message you
     cannot see is the failure this panel exists to stop. */
  if (a.pendingInputs.length) {
    const rank = { queued: 0, interrupted: 1, cancelled: 1, picked_up: 2, delivered: 2 };
    const ordered = [...a.pendingInputs].sort((x, y) =>
      (rank[x.state] - rank[y.state]) || (y.queuedAt - x.queuedAt));
    // Three on a full-height screen, two on a short one. On a 900px laptop three
    // items plus the commands, the input, the warning and the metadata came to
    // 412px of steering panel over a 36px transcript, and pushed the foot off the
    // bottom of the viewport. What is folded away is still counted and named on
    // the line below, so nothing goes quiet.
    const cap = viewportH() < 940 ? 2 : 3;
    box.append(h('div.queue', ordered.slice(0, cap).map(QueueItem)));
    if (ordered.length > cap) {
      const rest = ordered.slice(cap);
      const nq = rest.filter((p) => p.state === 'queued').length;
      box.append(h('div.q-more', rest.length + ' earlier message' + (rest.length > 1 ? 's' : '')
        + (nq ? ' — ' + nq + ' still queued' : ' — all resolved') + '.'));
    }
  }

  /* 3 — commands. A permanent row of chips, so the slot is never empty; typing
     "/" replaces it with the filtered palette and its descriptions. */
  if (cmdMode && !off) {
    const hits = matchCommands(text);
    const pal = h('div.pal', { 'data-enter': 'pal:' + a.id });
    if (!hits.length) pal.append(h('div.pal-none', 'No command matches — this prototype implements seven.'));
    hits.forEach((cmd, i) => pal.append(h('button.pal-i', {
      'data-hi': i === Math.min(S.palHi, hits.length - 1) ? '1' : '0',
      onclick: () => { S.draft[a.id] = cmd.name + (cmd.args ? ' ' : ''); S.palHi = 0; renderAll(); },
    }, h('b', cmd.name + (cmd.args ? ' ' + cmd.args : '')), h('span', cmd.desc))));
    // The palette floats up out of the commands slot rather than displacing it.
    // In flow, seven rows of palette pushed the transcript down to 103px — which
    // is v3's exact defect, rediscovered in a new shell. The slot keeps the chip
    // row's height so nothing below it moves when the palette opens.
    box.append(h('div.pal-slot', pal));
  } else {
    box.append(h('div.cmds', h('span.cmds-l', 'commands'),
      COMMANDS.map((cmd) => h('button.cmd-chip', {
        disabled: off || null,
        title: cmd.desc,
        onclick: () => { if (off) return; S.draft[a.id] = cmd.name + (cmd.args ? ' ' : ''); S.palHi = 0; renderAll(); },
      }, cmd.name))));
  }

  /* 4 — the input. */
  const ta = h('textarea.ta', {
    id: 'cmd-' + role, rows: 1, value: text, disabled: off,
    placeholder: off ? 'This agent has no session yet.'
      : isMain(a) ? 'Message the category, @lane to address one, / for a command, hold space to talk…'
      : 'Steer this agent, / for a command, hold space to talk…',
    oninput: (ev) => { S.draft[a.id] = ev.target.value; S.palHi = 0; voiceAck(a.id); renderAll(); },
    onkeydown: (ev) => onComposerKey(ev, a, c),
    // Release ends the hold. Blur does too: a window that loses focus mid-hold
    // never delivers the keyup, and an open microphone nobody can see is the
    // one failure mode this feature must not have.
    onkeyup: (ev) => { if (ev.key === ' ') voiceStop(); },
    onblur: () => { if (VOICE.requestId) voiceStop(); },
  });
  box.append(h('div.compose-box', { 'data-cmd': cmdMode ? '1' : '0', 'data-off': off ? '1' : '0' },
    ta,
    h('button.send', { 'data-off': off ? '1' : '0', onclick: () => submitComposer(a, c) },
      cmdMode ? 'run' : running ? 'queue' : 'send')));
  const vs = VoiceState(a.id);
  if (vs) box.append(vs);
  const ws = WriteState(a);
  if (ws) box.append(ws);

  // The single most important sentence in this UI, and the reason a queued steer
  // is drawn as a queue rather than as a sent message.
  if (off) {
    box.append(h('div.note', h('b', '·'), 'There is no session to send to, so this box does nothing rather than pretending.'));
  } else if (cmdMode) {
    box.append(h('div.note', { 'data-k': 'info' }, h('b', '/'),
      'Commands act on this session directly and are not queued behind the run. Enter runs the highlighted command; Tab completes it.'));
  } else if (isMain(a)) {
    const r = routeFor(c, text);
    box.append(h('div.note', { 'data-k': r.k === 'queue' ? 'warn' : 'info' }, h('b', '→'), r.text));
  } else if (running) {
    /* The full statement once per screen. Printed at length in both panes of a
       split it is 100 words of identical warning stacked twice, which is how a
       sentence that matters gets trained into wallpaper.

       Same rule, one step further, on a short screen with a queue already on it:
       the queue above is showing the mechanism happening, item by item, with the
       real Gateway condition written on each one. Repeating it here at length
       costs 36px of transcript to say what the reader is already looking at. The
       long form is still what you get with an empty queue, which is the case
       where nothing else on screen explains it. */
    // The height test no longer waits for a queue to be on screen, and the
    // reason is a measurement rather than a preference. At 1440x900 with no
    // picker open and no queue, the composer measured foot=350 around ~380px of
    // content — footScrolls=true, send button behind an inner scrollbar, the
    // transcript already pinned at its 200px floor with nothing left to give.
    // The column is over-subscribed by roughly the difference between these two
    // strings. The existing `foot >= 300` assertion passed the whole time,
    // which is what a height proxy does when the real question is whether the
    // box scrolls.
    //
    // The short form keeps every load-bearing clause — not an interrupt, queued
    // to the next step, dropped if the run ends first — and points at the queue
    // for the rest. The long form is still what a window with room gets.
    const shortForm = role === 'sub' || viewportH() < 940;
    box.append(h('div.note', { 'data-k': 'warn' }, h('b', '⚠'), shortForm
      ? 'Not an interrupt — queued until this run\'s next step, and dropped if it ends first. See the queue above.'
      : 'This is not an interrupt. The message is admitted to a pending queue and the agent picks it up at its next step — usually after the current tool call returns. If the run ends or is aborted first, it is dropped and never acted on. Use abort run to stop work immediately.'));
  } else if (a.status === 'waiting') {
    box.append(h('div.note', h('b', '↩'),
      'This session has no active turn — it stopped to ask you something. A reply is delivered immediately and resumes the run from where it stopped.'));
  } else {
    box.append(h('div.note', { 'data-k': 'info' }, h('b', '↩'),
      'This session has no active turn, so the message is delivered immediately and starts a new one.'));
  }

  /* 5 — metadata, under the input. */
  for (const row of UsageStrip(a, c)) box.append(row);
  return box;
}

/* ───────────────────────── §P  ping bubbles ─────────────────────────

   The composer's target selector, and it is Atlas's .page-tab — the SAME
   control as the agent tab strip above, in the same two states, brass
   .is-active and all. Not a lookalike: same class, same stylesheet rule, so it
   cannot drift from the tabs it is echoing.

   THE ROUTING IT DEPICTS. Unpinged, a message goes to main — Thuban — who then
   pings whichever lane is needed. Pinged, it goes to that lane. That is a star:
   lanes answer main, and lanes do not talk to each other.

   THE PART THAT IS DEPICTION AND SAYS SO. Lane-to-lane routing needs
   tools.agentToAgent and tools.sessions.visibility in the gateway's config, and
   both keys are currently ABSENT — checked, not assumed. So the star is not
   merely the convention, it is the only thing the gateway permits, and a bubble
   cannot make a lane message another lane. The strip prints that under itself
   rather than implying a capability that would fail. Nothing here attempts to
   enable anything. */

/* PingBar — the agent-pane ping-button row — was removed. Agents are addressed
   by typing @<agent>, parsed at send time (routeFor for the note, Room.pings on
   the native side for delivery). submitComposer always sent to the pane's own
   session regardless of the selected bubble, so the buttons only ever drove a
   note; the note now explains the @ convention instead. */

/* ───────────────────────── §R  what the gateway said ─────────────────────────
   Every send ends here. Three states and no fourth: in flight, landed, refused.
   A refusal names the scope and the command, because "forbidden" on its own is
   something you can only complain about. */

function WriteState(a) {
  const w = S.write;
  if (!w || w.agentId !== a.id) return null;

  if (w.state === 'sending') {
    return h('div.wr', { 'data-k': 'wait', 'data-enter': 'wr:' + w.id },
      h('span.dot'), h('b', w.verb === 'abort' ? 'aborting…' : w.verb === 'queue' ? 'queueing…' : 'sending…'),
      h('span', 'waiting for the gateway to answer'));
  }

  if (w.state === 'sent') {
    return h('div.wr', { 'data-k': 'ok', 'data-enter': 'wr:' + w.id },
      h('span.dot'), h('b', w.queued ? 'queued' : 'delivered'),
      h('span', w.queued
        ? 'the session had an active turn — the agent picks this up at its next step'
        : 'the session was idle — this started a turn'));
  }

  // Refused. The actionable form.
  const scope = w.missingScope || (w.requiredScopes && w.requiredScopes[0]);
  const grant = scope ? 'openclaw devices approve <requestId> --scopes ' + scope : null;
  return h('div.wr', { 'data-k': 'fail', 'data-enter': 'wr:' + w.id },
    h('span.dot'),
    h('div.wr-b',
      h('div.wr-t', h('b', 'read-only: not sent'),
        h('span', w.code ? ' · ' + w.code : ''),
        h('span.spacer'),
        h('button.wr-x', { onclick: () => { S.write = null; renderAll(); } }, '×')),
      h('div.wr-m', w.message || 'the gateway refused the request'),
      // Tight on purpose. This banner lives inside the composer, and the
      // composer's height comes out of the transcript's — see the floor note in
      // app.css. Everything actionable is here; nothing is padding.
      scope ? h('div.wr-fix',
        h('span', 'Needs '), h('code', scope), h('span', '. On the gateway host:'),
        h('pre', 'openclaw devices list\nopenclaw devices approve <requestId> --scopes ' + scope),
        h('span.wr-warn', 'Widening the scope set makes a NEW pairing request — an approval '
          + 'cannot be widened in place. Your message is still in the box; nothing was queued.')) : null));
}

/* ───────────────────────── §C  THE ROOM ─────────────────────────

   The main chat. Bridge owns it, because OpenClaw does not have one: a session
   belongs to exactly one agent and an agent can only read its own transcript,
   so a room where nine agents hear each other is not something the gateway
   provides. Bridge relays into each agent's own persistent session and keeps
   the shared transcript here.

   THE ROUTING, WHICH IS CHANCELLOR'S SPEC AND IS IMPLEMENTED LITERALLY:

     no ping   -> main (Thuban), and only main. He sees every unpinged message.
     a ping    -> that lane, and main does NOT see it.
     agents ping each other — he pings frontend-design, frontend-design pings
       backend-design when its part is done, backend-design pings full-stack to
       tie it together. Collaboration, not one manager dispatching.
     everything appears HERE regardless of who it was addressed to. Pings
       control who takes a turn, not who is displayed.

   Bridge does the relaying; the agents do not call session tools, and
   `tools.agentToAgent` / `tools.sessions.visibility` stay off. See live.js §C
   and Room.swift for why that matters.

   The pane is built out of `.p-h` / `.tx` / `.foot` — the same three parts as
   an agent pane, carrying the same classes. Not for tidiness: it means the
   transcript floor that has now been broken four times is enforced here by the
   SAME rule and asserted by the SAME check, rather than by a second layout that
   has to be discovered to be wrong. */

const ROOM_ORIGIN = { chancellor: 'Chancellor', bridge: 'Bridge' };
const roomAt = (ms) => (ms - T0) / 1000;

/* THE SAME CONTROL, IN ITS TWO MODES.

   Chancellor asked for the ping bubbles to reuse `.page-tab.is-active` — the
   Atlas brass — because the tab strip and the ping bar are one control. They
   are written once, here, so that stays true by construction rather than by
   two implementations agreeing for now.

     mode 'ping' — selection sets who takes the next turn. Lives in the
       composer, where the decision is made.
     mode 'nav'  — selection opens that agent's underlying room thread. Lives in
       the topbar, where navigation lives.

   Both render `.page-tab`; both carry `.is-active` for the current selection;
   neither has a colour of its own. */
function AgentStrip(mode, cat) {
  const el = h('nav.page-tabs.agent-strip', { 'data-mode': mode });
  /* THE PROJECT'S OWN ACCESS LIST, and nothing wider. This strip is how a ping
     is chosen, so what it offers IS the set of agents reachable from here — and
     an agent in another project must not be offerable, because Room.deliver
     would refuse it and the refusal would read as Bridge being broken rather
     than as isolation working.

     ACCESS, not the launched clones. In 'ping' mode the point is who may be
     handed work, and handing work to an allowed agent launches it. The room
     payload's `access` is preferred because it is what Swift will actually
     enforce; the category's copy is the pre-connection fallback. */
  const room = roomOf(cat && cat.id);
  const ids = (room.access && room.access.length)
    ? room.access
    : ((cat && cat.access) || []);
  const byId = new Map((room.agents || []).map((a) => [a.id, a]));
  const roster = ids.map((id) => byId.get(id) || ({
    id, name: agentLabel(id), key: 'agent:' + id + ':bridge:' + (cat ? cat.id : ''),
  }));

  if (mode === 'ping') {
    el.append(h('button.page-tab.ping-b', {
      class: S.roomPing ? '' : 'is-active',
      'data-none': '1',
      'aria-pressed': S.roomPing ? 'false' : 'true',
      title: 'Unpinged. The message goes to this project’s main (Thuban) and to nobody else.',
      onclick: () => { S.roomPing = null; renderAll(); },
    }, 'no ping → main'));
  }

  for (const ag of roster) {
    if (mode === 'ping' && ag.id === 'main') continue;    // "no ping" already IS main
    const live = cat && cat.agents.find((a) => a.sessionKey === ag.key && !a.parent);
    const active = mode === 'ping' ? S.roomPing === ag.id : false;
    el.append(h(mode === 'ping' ? 'button.page-tab.ping-b' : 'a.page-tab', {
      class: active ? 'is-active' : '',
      href: mode === 'nav' && cat ? '#/' + cat.id : null,
      'aria-pressed': mode === 'ping' ? (active ? 'true' : 'false') : null,
      'data-id': ag.id,
      title: mode === 'ping'
        ? 'Ping ' + ag.id + ' — this message goes to that clone in ' + (cat ? cat.name : 'this project')
          + ', and main does not see it.'
        : (live ? 'Open ' + ag.name + '’s tab — the real session Bridge relays into.'
                : ag.name + ' has no session in this project yet. One is created the first '
                  + 'time it is pinged.'),
      onclick: (ev) => {
        ev.preventDefault();
        if (mode === 'ping') { S.roomPing = ag.id; renderAll(); return; }
        openRoomThread(cat, ag);
      },
    },
      live ? TabMark(live.status, isStale(live)) : h('span.tmark', { 'data-s': 'planned', 'data-stale': '0' }),
      ag.name,
      mode === 'nav' && live && live.totalMessages ? h('span.tab-kids', live.totalMessages) : null));
  }
  return el;
}

/* Open the tab behind one clone. A clone that has never been pinged has no
   session yet — `chat.send` creates it on first use — and saying so is better
   than navigating nowhere. */
function openRoomThread(cat, ag) {
  if (!cat) return;
  const live = cat.agents.find((a) => a.sessionKey === ag.key && !a.parent)
            || cat.agents.find((a) => a.lane === ag.id && !a.parent);
  // A placeholder IS a tab — the clone exists as a roster slot whether or not a
  // session has been created — so navigating to it is right, and the notice
  // below is only for a lane this project does not hold at all.
  if (!live) {
    S.notice = { k: 'info', agentId: null,
      text: ag.name + ' has no session in ' + cat.name + ' yet. Bridge creates ' + ag.key
        + ' the first time you ping that lane.' };
    renderAll();
    setTimeout(() => { S.notice = null; renderAll(); }, 6000);
    return;
  }
  jumpTo(cat.id, live.id);
}

/* THE ROOM IS A PROJECT'S FIRST TAB. It renders inside the ordinary sessions
   shell rather than as its own view, which is what makes "main FIRST, then one
   tab per agent" true of the actual markup: the room is tab zero, not a
   destination somewhere else in the app. */
function RoomView(cat) {
  const pane = h('section.pane.room', { 'data-role': 'room', 'data-project': cat.id });
  const room = roomOf(cat.id);
  const paused = room.paused;
  const nAgents = (cat.access || []).length;

  /* 1 — header. */
  const head = h('div.p-h');
  head.append(h('div.p-h-top',
    h('span.p-title', cat.name + ' · room'),
    h('span.st', { 'data-s': paused ? 'failed' : 'running' },
      h('span.dot', { class: paused ? '' : 'dot-ring' }),
      paused ? 'relay paused' : 'relay live'),
    h('span.spacer'),
    h('button.btn', {
      title: paused ? 'Resume agent-to-agent hand-offs in this project'
                    : 'Stop relaying agent pings here. Your own messages still send.',
      onclick: () => roomPause(cat.id, !paused),
    }, paused ? 'resume relay' : 'pause relay'),
    room.messages.length ? h('button.btn', {
      'data-danger': '1',
      title: 'Empty this project’s transcript. The clones’ own sessions are untouched.',
      onclick: () => roomClear(cat.id),
    }, 'clear') : null));

  head.append(h('div.p-head',
    'One transcript for ' + cat.name + ', ' + nAgents + ' agents with access. Unpinged goes to this '
    + 'project’s main; a ping goes to that clone and main does not see it. Everything said '
    + 'lands here. Agents in ' + cat.name + ' can only reach each other — there is no '
    + 'cross-project messaging.'));

  /* The relay budget, on screen rather than in a log. A chain of agents handing
     work to each other is money being spent with no human in the loop, so both
     bounds are visible before they bite and named when they do. Counted PER
     PROJECT: a runaway chain here does not pause work somewhere else. */
  head.append(h('div.p-op.room-budget',
    h('b', 'relay'),
    h('span.p-op-d', room.relaysInWindow + ' of ' + ROOM.maxRelays + ' in the last '
      + ROOM.relayWindowMin + ' min'),
    h('span.p-op-t', '· ceiling ' + ROOM.maxHops + ' hops')));
  pane.append(head);

  if (paused) {
    pane.append(h('div.notice', { 'data-k': 'warn', 'data-enter': 'room-paused' }, h('span.dot'),
      'Relay is paused' + (room.pauseReason ? ' (' + room.pauseReason + ')' : '')
      + '. Messages you send still go out; an agent pinging a teammate does not hand over.'));
  }
  if (S.notice && S.notice.agentId === null) {
    pane.append(h('div.notice', { 'data-k': S.notice.k, 'data-enter': 'room-note' },
      h('span.dot'), S.notice.text));
  }

  /* 2 — the transcript. Same class, same floor, same assertion as an agent pane. */
  const tx = h('div.tx', { id: 'tx-main', 'data-agent': '__room__' });
  if (!room.messages.length) {
    tx.append(h('div.empty', { 'data-enter': 'room-empty' },
      h('div', 'Nothing has been said in ' + cat.name + ' yet.'),
      h('div.mc-foot', 'A message with no @ goes to this project’s main. Type @<agent> to hand it '
        + 'straight to that agent instead — and they can hand it on from there, inside this '
        + 'project.')));
  }
  for (const m of room.messages) tx.append(RoomMsg(m));
  pane.append(tx);

  /* 3 — the composer. */
  pane.append(RoomFoot(cat));
  return pane;
}

function RoomMsg(m) {
  const mine = m.from === 'chancellor';
  const note = m.from === 'bridge';
  const who = ROOM_ORIGIN[m.from] || agentLabel(m.from);
  const box = h('div.rm', { 'data-from': note ? 'bridge' : mine ? 'me' : 'agent',
                            'data-kind': m.kind });
  box.append(h('div.rm-h',
    h('span.rm-who', who),
    !note && !mine ? h('span.rm-id', '@' + m.from) : null,
    // One chip per lane the turn was handed to. This is the fact the room
    // exists to make visible: who is expected to take the next turn.
    (m.to || []).map((t) => h('span.rm-to', { title: 'Bridge relayed this turn to ' + t + '.' },
      '→ @' + t)),
    h('span.spacer'),
    m.hop > 0 ? h('span.rm-hop', { title: 'Relay depth: ' + m.hop + ' hand-off'
      + (m.hop === 1 ? '' : 's') + ' from Chancellor’s message. Ceiling is ' + ROOM.maxHops + '.' },
      'hop ' + m.hop) : null,
    h('span.rm-t', clockAt(roomAt(m.at)))));
  box.append(h('div.rm-b', m.text));
  return box;
}

function RoomFoot(cat) {
  const box = h('div.foot');
  const room = roomOf(cat.id);
  // Where a message goes is parsed from its text at send time: an @<agent>
  // handle routes to that agent (main does not see it), no @ goes to main
  // (Thuban). There is NO ping-button row — you address by typing @. The header
  // reflects main, the default and the common case.
  const wantKey = 'agent:main:bridge:' + cat.id;
  const live = cat.agents.find((a) => a.sessionKey === wantKey && !a.parent);
  const running = !!(live && live.status === 'running');
  const readOnly = typeof LIVE !== 'undefined' && LIVE.readOnly;

  /* 1 — header. */
  box.append(h('div.foot-h', 'Message ' + cat.name,
    h('span.spacer'),
    h('em', readOnly ? 'read-only connection — a send will be refused'
      : running ? 'Thuban is mid-turn — an unaddressed message will queue'
      : 'no active turn — a message starts one')));

  /* 2 — the input. No ping buttons: you address an agent by typing @<agent>,
     and both @ and / open a live type-ahead list — the same palette the agent
     pane uses. renderAll on input is safe (captureUi/restoreUi keep the caret)
     and is what filters the list as you type. Typing @ lists this project's
     agents; typing / lists the commands. */
  const draft = S.roomDraft || '';
  const cmdMode = draft.startsWith('/');
  const atMatch = /(?:^|\s)@([a-z0-9-]*)$/i.exec(draft);      // an @token being typed at the end
  const roomAccess = (roomOf(cat.id).access && roomOf(cat.id).access.length)
    ? roomOf(cat.id).access : (cat.access || []);

  if (cmdMode) {
    const hits = matchCommands(draft);
    const pal = h('div.pal', { 'data-enter': 'pal:room' });
    if (!hits.length) pal.append(h('div.pal-none', 'No command matches — this prototype implements seven.'));
    hits.forEach((cmd) => pal.append(h('button.pal-i', {
      onclick: () => { S.roomDraft = cmd.name + (cmd.args ? ' ' : ''); renderAll(); },
    }, h('b', cmd.name + (cmd.args ? ' ' + cmd.args : '')), h('span', cmd.desc))));
    box.append(h('div.pal-slot', pal));
  } else if (atMatch) {
    const q = atMatch[1].toLowerCase();
    const hits = roomAccess.filter((id) => id.toLowerCase().startsWith(q));
    const pal = h('div.pal', { 'data-enter': 'pal:room-at' });
    if (!hits.length) pal.append(h('div.pal-none', 'No agent in ' + cat.name + ' matches @' + q + '.'));
    hits.forEach((id) => pal.append(h('button.pal-i', {
      onclick: () => { S.roomDraft = draft.replace(/@[a-z0-9-]*$/i, '@' + id + ' '); renderAll(); },
    }, h('b', '@' + id), h('span', id === 'main' ? 'Thuban — the unaddressed default' : agentLabel(id)))));
    box.append(h('div.pal-slot', pal));
  }

  const ta = h('textarea.ta', {
    id: 'cmd-main', rows: 1, value: draft,
    placeholder: 'Message ' + cat.name + ' — type @agent to address one, / for a command, hold space to talk…',
    oninput: (ev) => { S.roomDraft = ev.target.value; voiceAck('__room__'); renderAll(); },
    onkeydown: (ev) => onRoomKey(ev, cat),
    onkeyup: (ev) => { if (ev.key === ' ') voiceStop(); },
    onblur: () => { if (VOICE.requestId) voiceStop(); },
  });
  box.append(h('div.compose-box', { 'data-cmd': cmdMode ? '1' : '0', 'data-off': '0' },
    ta,
    h('button.send', { onclick: () => roomSend(cat.id) }, cmdMode ? 'run' : running ? 'queue' : 'send')));

  const v = VoiceState('__room__');
  if (v) box.append(v);

  /* 4 — how to address one agent, stated before you do. */
  box.append(h('div.note', { 'data-k': 'info' }, h('b', '@'),
    'Type @<agent> anywhere in a message to send it to that agent in ' + cat.name + ' alone — '
    + 'main (Thuban) does not see it, and it lands in that clone’s persistent thread. With no @, '
    + 'the message goes to main (Thuban) and to nobody else; he can hand it on by @-ing a '
    + 'teammate in his reply.'));

  const w = WriteState({ id: '__room__' });
  if (w) box.append(w);

  /* 5 — metadata. What the room costs, where it is kept, and where its agents
     remember things — the memory paths are the only place a reader can find out
     that memory follows the AGENT rather than the project, which is the one
     thing about this model that is genuinely surprising. */
  const pair = (label, value) => h('span', null, h('b', label), h('i', value));
  box.append(h('div.p-use',
    pair('messages', fmtNum(room.messages.length)),
    pair('access', String((cat.access || []).length)),
    pair('launched', String((cat.clones || []).length)),
    pair('relay', room.paused ? 'paused' : room.relaysInWindow + '/' + ROOM.maxRelays),
    pair('hop ceiling', String(ROOM.maxHops)),
    pair('voice', (LIVE.voice && LIVE.voice.route) === 'local'
      ? 'local · ' + (LIVE.voice.model || 'whisper')
      : 'gateway host (no local whisper)')));
  box.append(h('div.p-use-2',
    h('span', null, h('b', 'threads '), 'agent:<id>:bridge:' + cat.id + ', one per agent in this '
      + 'project, persistent and separate from every other project'),
    h('span', null, h('b', 'memory '), (ROOM.memoryRoot || '~/.openclaw/workspace/memory/bridge')
      + '/<agent>/{SOUL,MEMORY}.md — per AGENT, not per project: every clone of an agent shares '
      + 'these wherever it works · '
      + (ROOM.sharedMemory || '~/.openclaw/workspace/memory/bridge/SHARED.md') + ' shared by all'),
    h('span', null, h('b', 'routing '), 'Bridge relays as an operator client — agentToAgent stays off')));
  return box;
}

/* ── §V  hold space to talk ──
   The arming rule lives here because this is where the composer's value is:
   space starts a recording ONLY when the box is empty, so typing spaces still
   types spaces. Everything else is Swift's. */
function onRoomKey(ev, cat) {
  if (voiceArmed(ev, S.roomDraft)) { ev.preventDefault(); voiceStart('__room__'); return; }
  if (ev.key === 'Enter' && !ev.shiftKey) { ev.preventDefault(); roomSend(cat && cat.id); }
}

/* The recording indicator. It has to be unmistakable — an open microphone you
   have forgotten about is the failure mode — so it states the state, the
   elapsed hold, and which machine the audio will be transcribed on. */
function VoiceState(targetId) {
  if (VOICE.target !== targetId) return null;
  const st = VOICE.state;
  /* `done` IS NOT A STATE THIS DRAWS.

     Swift's last word on a hold that produced speech is `done` (Voice.swift
     emits `t.isEmpty ? "empty" : "done"` and then nothing), so VOICE.state sits
     on 'done' from the moment the sentence lands until the next hold starts.
     There was no branch for it here, so it fell through to the generic return
     below, where `st === 'recording' ? … : st === 'arming' ? … : 'transcribing'`
     labelled it TRANSCRIBING — and the composer then claimed, permanently and
     falsely, that whisper was still working. The one indicator whose whole job
     is to be unmistakable about an open microphone was the thing lying about it.

     Nothing is lost by drawing nothing: the transcript of a `done` is already
     in the box, and text appearing in the composer is the feedback. `empty` and
     `error` still draw, because for those two the banner is the ONLY report the
     user ever gets. */
  if (st === 'idle' || st === 'done') return null;
  if (st === 'error') {
    return h('div.wr', { 'data-k': 'fail', 'data-enter': 'voice-err' }, h('span.dot'),
      h('div.wr-b', h('div.wr-t', h('b', 'voice failed')), h('div.wr-m', VOICE.error || 'unknown error')));
  }
  if (st === 'empty') {
    return h('div.wr', { 'data-k': 'wait', 'data-enter': 'voice-empty' }, h('span.dot'),
      h('b', 'nothing heard'), h('span', 'the hold produced no speech — nothing was inserted'));
  }
  const label = st === 'recording' ? 'recording' : st === 'arming' ? 'opening the microphone' : 'transcribing';
  return h('div.wr.voice', { 'data-k': st === 'recording' ? 'rec' : 'wait', 'data-enter': 'voice:' + st },
    h('span.dot'), h('b', label),
    h('span', st === 'recording'
      ? 'release space to transcribe · ' + fmtDur(nowS() - VOICE.at)
      : st === 'transcribing'
        ? ((LIVE.voice && LIVE.voice.route) === 'local'
            ? 'on this Mac, with ' + (LIVE.voice.model || 'whisper')
            : 'on the gateway host — no local whisper model was found')
        : 'granting microphone access'));
}

/* Open a project's room — its first tab. Replaces `openRoom`, which went to a
   global room that no longer exists. */
function openProjectRoom(catId) {
  S.view = 'sessions';
  S.catId = catId;
  S.tab[catId] = catId + '::room';
  S.sub = null;
  renderAll();
}

/* ───────────────────────── the inbox ─────────────────────────

   Completions and questions. The honesty rule for this view is written up at
   §I in live.js and enforced here: an entry exists because a real task row said
   so, the question section states why it is empty instead of being empty and
   silent, and what was filtered out of the feed is counted at the bottom rather
   than quietly dropped. */

function InboxView() {
  const m = INBOX.meta || {};
  const unread = inboxUnread();
  const box = h('div.inbox');

  box.append(h('div.inbox-h',
    h('b', unread ? unread + ' unread' : 'All read'),
    h('span.spacer'),
    m.inFlight ? h('em', m.inFlight + ' task' + (m.inFlight === 1 ? '' : 's') + ' still running') : null,
    unread ? h('button.btn', { onclick: () => { markAllInboxRead(); renderAll(); } }, 'mark all read') : null));

  const completions = INBOX.filter((e) => e.kind === 'completion');
  const questions = INBOX.filter((e) => e.kind === 'question');

  /* ── completions ── */
  box.append(h('p.inbox-k', 'Completed tasks'));
  if (!completions.length) {
    box.append(h('div.strip-none', 'No delegated task has finished yet on this gateway.'));
  } else {
    box.append(h('div.inbox-list', completions.map(InboxRow)));
  }

  /* ── questions ──
     Real, and the most valuable thing in this view. A subagent calling ask_user
     raises a `question.requested` event on the gateway; until now it died unseen
     in a Control UI pane nobody had open. Bridge subscribes, draws the options
     inline, and resolves through `question.resolve`. */
  box.append(h('p.inbox-k', 'Questions'));
  if (questions.length) {
    box.append(h('div.inbox-list', questions.map(QuestionRow)));
  } else if (m.questionsPossible) {
    box.append(h('div.strip-none',
      'No agent is waiting on an answer. Bridge is subscribed to question.requested and holds '
      + 'operator.questions, so one appears here — with its options — the moment it is raised.'));
  } else {
    // The Phase B state, kept for the case where the scope is revoked: the
    // reason is specific and names what would have to change.
    box.append(h('div.inbox-why',
      h('b', 'Bridge cannot see questions on this connection.'),
      h('p', 'Listing or answering questions needs the operator.questions scope. This '
        + 'connection was granted ' + (LIVE.scopes.join(', ') || 'no scopes') + '. Approve the '
        + 'device for operator.questions on the gateway host and reconnect.')));
  }

  /* ── still running ──
     Not completions, and not filed as ones. They are here because a running
     delegation is what you open an inbox to check on, and because this is where
     the live half of the elapsed rule is visible: these tick, the ones above
     are frozen. */
  const live = INBOX.running || [];
  if (live.length) {
    box.append(h('p.inbox-k', 'Still running'));
    box.append(h('div.inbox-live', live.map((t) => h('div.ibl',
      h('span.tmark', { 'data-s': 'running', 'data-stale': '0' }),
      h('span.ibl-t', t.title),
      h('span.ibl-a', agentLabel(t.agentId)),
      h('span.spacer'),
      t.lastTool ? h('span.ibl-k', t.lastTool) : null,
      h('span.ibl-e', { title: 'Ticking from this task’s start. A finished task freezes at '
        + 'its total instead.' }, elapsedText(t.startedAt, null, true))))));
  }

  /* ── what is not shown ── */
  const foot = h('div.inbox-foot');
  if (m.automationRuns) {
    foot.append(h('span', h('b', m.automationRuns), ' automation run'
      + (m.automationRuns === 1 ? '' : 's') + ' (cron firings such as heartbeat-main) are not '
      + 'listed — they are scheduled jobs, not delegated tasks.'));
  }
  if (m.foldedChildren) {
    foot.append(h('span', h('b', m.foldedChildren), ' child task'
      + (m.foldedChildren === 1 ? '' : 's') + ' folded into their parent\'s entry: one entry per '
      + 'whole delegated task, not one per agent.'));
  }
  if (foot.childNodes.length) box.append(foot);
  return box;
}

function InboxRow(e) {
  const lane = agentLabel(e.agentId);
  const bad = e.status === 'failed' || e.status === 'error';
  return h('button.ibx', {
    'data-s': bad ? 'failed' : e.kind === 'question' ? 'waiting' : 'completed',
    'data-read': e.read ? '1' : '0',
    title: e.sessionKey ? 'Open ' + lane + ' — ' + e.sessionKey : 'This task kept no session to open',
    onclick: () => openInboxEntry(e),
  },
    h('div.ibx-top',
      e.read ? null : h('span.ibx-new'),
      TabMark(bad ? 'failed' : e.kind === 'question' ? 'waiting' : 'completed', false),
      h('span.ibx-t', e.title),
      h('span.spacer'),
      h('span.ibx-lane', lane),
      /* Chancellor's rule: a finished task shows how long it TOOK and freezes
         there. "2h ago" is a fact about the clock that keeps changing for work
         that is over; "48m" is a fact about the work and never moves again. */
      h('span.ibx-at', { title: e.startedAt !== null && e.startedAt !== undefined
          ? 'Total run time. Frozen — this task is finished.' : 'No start time on the task row.' },
        elapsedText(e.startedAt, e.endedAt, false))),
    // The summary, with its provenance. A finished task has no single field
    // holding what it concluded (see summaryForTask in live.js), so where this
    // text came from is part of the information: an opening note captioned as a
    // conclusion would be a small lie told on every row.
    e.summary ? h('div.ibx-s',
        e.summaryKind === 'opening' || e.summaryKind === 'terminal'
          ? h('span.ibx-src', e.summaryKind === 'opening' ? 'opening note · no closing summary recorded'
                                                          : 'gateway notice')
          : null,
        clipLine(e.summary, 260))
      : h('div.ibx-s.ibx-s-none',
        e.kind === 'question' ? 'No question text on the event.' : 'The task recorded no closing summary.'),
    e.blocked ? h('div.ibx-blocked', h('b', 'result never delivered'),
      e.error ? ' — ' + clipLine(e.error, 150) : '') : null,
    h('div.ibx-m',
      h('span', bad ? 'failed' : e.kind === 'question' ? 'waiting on you' : 'completed'),
      e.toolUseCount ? h('span', fmtNum(e.toolUseCount) + ' tool calls') : null,
      e.folded ? h('span', e.folded + ' child task' + (e.folded === 1 ? '' : 's') + ' folded in') : null,
      e.sessionKey ? h('span.ibx-go', 'open session →') : h('span', 'no session retained')));
}

/* One pending question, with its options as buttons.

   TWO IDS, AND THEY ARE DIFFERENT STRINGS. `e.id` is the record; `e.innerId` is
   the question inside it, and the answers map is keyed by the INNER one. Sending
   the record id there is accepted by the schema and answers nothing — a bug that
   looks exactly like success. Both are carried on the entry and both go over.

   A free-text question — no options, or `isOther` — gets a field. A secret
   question gets neither: its value is written into the gateway's secret store,
   and this is explicitly a screen other people can see. */
function QuestionRow(e) {
  const lane = agentLabel(e.agentId);
  const answering = S.answering && S.answering.questionId === e.id;
  const box = h('div.ibx.ibx-q', { 'data-s': 'waiting', 'data-read': '0' });

  box.append(h('div.ibx-top',
    h('span.ibx-new'),
    TabMark('waiting', false),
    h('span.ibx-t', e.title),
    h('span.spacer'),
    h('span.ibx-lane', lane),
    h('span.ibx-at', { title: 'This question expires and returns unanswered.' },
      e.expiresAt !== null && e.expiresAt !== undefined
        ? 'expires in ' + fmtDur(Math.max(0, e.expiresAt - nowS()))
        : 'asked ' + fmtAgo(e.at))));

  box.append(h('div.ibx-s', e.summary || 'No question text on the record.'));

  if (e.secret) {
    box.append(h('div.ibx-blocked', h('b', 'secret question'),
      ' — this asks for a value written into the gateway’s secret store. Bridge will not '
      + 'render a field for it: this is a screen other people can see. Answer it on the '
      + 'gateway host.'));
  } else if (answering && S.answering.state === 'sending') {
    box.append(h('div.wr', { 'data-k': 'wait' }, h('span.dot'), h('b', 'answering…'),
      h('span', 'sent “' + clipLine(S.answering.value, 40) + '” — waiting for the gateway')));
  } else {
    const row = h('div.ask-row');
    for (const o of e.options) {
      row.append(h('button.ask-btn', {
        title: o.description || ('Answer with “' + o.label + '”'),
        onclick: () => answerQuestion(e, o.label),
      }, o.label));
    }
    if (!e.options.length || e.other) {
      const inp = h('input.add-in.q-in', {
        placeholder: e.options.length ? 'or type your own answer…' : 'type your answer…',
        onkeydown: (ev) => {
          if (ev.key !== 'Enter') return;
          ev.preventDefault();
          const v = ev.target.value.trim();
          if (v) answerQuestion(e, v);
        },
      });
      row.append(inp);
      row.append(h('button.add-go', {
        onclick: (ev) => {
          const f = ev.target.parentNode.querySelector('.q-in');
          const v = f && f.value.trim();
          if (v) answerQuestion(e, v);
        },
      }, 'answer'));
    }
    box.append(row);
  }

  if (answering && S.answering.state === 'refused') {
    box.append(h('div.wr', { 'data-k': 'fail' }, h('span.dot'),
      h('div.wr-b', h('div.wr-t', h('b', 'not answered'),
        h('span', S.answering.code ? ' · ' + S.answering.code : '')),
        h('div.wr-m', S.answering.message || 'the gateway refused to resolve it'))));
  }

  box.append(h('div.ibx-m',
    h('span', 'waiting on you'),
    e.extra ? h('span', e.extra + ' more question' + (e.extra === 1 ? '' : 's') + ' on this record — '
      + 'answer them where they were asked') : null,
    e.multi ? h('span', 'multi-select — Bridge answers one option') : null,
    h('span.ibx-go', e.sessionKey || 'no session on the record')));
  return box;
}

const clipLine = (t, n) => {
  const one = String(t || '').replace(/\s+/g, ' ').trim();
  return one.length > n ? one.slice(0, n - 1) + '…' : one;
};

/* Clicking an entry goes to the agent and session it came from. The session may
   have been archived or rolled since the task ended, so a miss says so rather
   than navigating somewhere arbitrary. */
function openInboxEntry(e) {
  markInboxRead(e.id);
  const target = e.sessionKey && agentById(e.sessionKey);
  if (!target) {
    S.notice = { k: 'warn', agentId: null,
      text: 'That task\'s session (' + (e.sessionKey || 'none recorded')
        + ') is no longer in the gateway\'s session list, so there is nothing to open.' };
    renderAll();
    setTimeout(() => { S.notice = null; renderAll(); }, 5000);
    return;
  }
  const cat = catOf(e.sessionKey);
  S.view = 'sessions';
  jumpTo(cat.id, e.sessionKey);
}

/* ───────────────────────── settings ─────────────────────────
   A real page. Everything on it is either a live gateway fact or a preference
   that persists; nothing here is a mock control. */

function SettingsView() {
  const box = h('div.set');

  /* ── connection ── */
  box.append(SetSection('Connection', 'The socket, and how it gets there.',
    h('div.set-rows',
      SetRow('status', LIVE.connection + (LIVE.detail ? ' · ' + LIVE.detail : '')),
      SetRow('gateway build', LIVE.serverVersion || 'not reported yet'),
      SetRow('transport', 'ssh -L to 127.0.0.1:18789 on the gateway host')),
    h('div.set-field',
      h('label', { for: 'set-ssh' }, 'SSH host'),
      h('input.set-in', { id: 'set-ssh', value: PREFS.sshHost || LIVE.sshHost,
        placeholder: 'atlas',
        oninput: (ev) => { PREFS.sshHost = ev.target.value; },
        onchange: () => { savePrefs(); renderAll(); } }),
      h('button.btn', { onclick: () => { savePrefs(); bridgeSend({ t: 'reconnect' }); } }, 'reconnect')),
    h('p.set-note', 'A name resolved by your own ~/.ssh/config — which is where the '
      + 'atlas.local-then-cloudflared fallback lives. Bridge keeps no second copy of that '
      + 'configuration, so this is a host name and not a host, port, user and key. Changing it '
      + 'rebuilds the forward on the next connect.')));

  /* ── token ── */
  box.append(SetSection('Gateway token',
    'gateway.auth.token from ~/.openclaw/openclaw.json on the gateway host.',
    h('div.set-rows', SetRow('stored in keychain', LIVE.tokenPresent ? 'yes' : 'no — Bridge cannot connect without it')),
    h('div.set-field',
      h('button.btn', { 'data-go': '1', onclick: () => bridgeSend({ t: 'settings' }) },
        LIVE.tokenPresent ? 'Replace gateway token…' : 'Enter gateway token…')),
    h('p.set-note', 'This button opens a native macOS sheet, and that is deliberate rather than '
      + 'a shortcut. The field is a SecureField that writes straight to the Keychain in-process. '
      + 'There is no bridge message that carries a token and none that returns one, so the token '
      + 'never exists as a JavaScript string — the page you are reading cannot see it, and could '
      + 'not be made to leak it.')));

  /* ── scopes ── */
  const granted = LIVE.scopes || [];
  const rows = SCOPE_DOC.map((sc) => {
    const has = granted.includes(sc.id)
      || (sc.id !== 'operator.admin' && granted.includes('operator.admin'))
      || (sc.id === 'operator.read' && granted.includes('operator.write'));
    return h('div.scope', { 'data-has': has ? '1' : '0' },
      h('span.scope-m', has ? '✓' : '·'),
      h('span.scope-n', sc.id),
      h('span.scope-d', sc.what),
      h('span.scope-s', has ? 'granted' : 'not granted'));
  });
  box.append(SetSection('Granted scopes',
    'Read from the gateway\'s hello-ok on this connection — not from what Bridge asked for.',
    h('div.set-rows',
      SetRow('requested', (LIVE.requestedScopes || []).join(', ') || '—'),
      SetRow('granted', granted.join(', ') || 'none')),
    h('div.scopes', rows),
    h('p.set-note', 'Phase C raised the requested set to operator.read, operator.write and '
      + 'operator.questions — the three writes the room and the inbox actually are: relaying a '
      + 'message, steering a run, and answering an agent’s question. operator.approvals and '
      + 'operator.admin are deliberately NOT requested; an unused standing grant is one nobody '
      + 'audits. Raising the set made a NEW pairing request rather than widening the old '
      + 'approval, which is why this connection reconnected unscoped until it was approved.')));

  /* ── projects and their rooms ── */
  const projects = typeof PREFS !== 'undefined' ? PREFS.projects : [];
  const clones = projects.reduce((n, p) => n + ((p.clones || []).length), 0);
  const pausedIn = projects.filter((p) => roomOf(p.id).paused).map((p) => p.name);
  box.append(SetSection('Projects and rooms',
    'A project is the unit of isolation. Chancellor decides which agents may work in each '
    + 'one; a launched agent is a clone with its own session and this project\'s room.',
    h('div.set-rows',
      SetRow('projects', projects.length ? projects.map((p) => p.name).join(', ') : 'none yet'),
      SetRow('clones launched', clones + ' across ' + projects.length
        + (projects.length === 1 ? ' project' : ' projects')),
      SetRow('memory', 'per AGENT, not per project — every clone of an agent reads and writes '
        + ((typeof ROOM !== 'undefined' && ROOM.memoryRoot) || '~/.openclaw/workspace/memory/bridge')
        + '/<agentId>/{SOUL,MEMORY}.md'),
      SetRow('threads', 'agent:<id>:bridge:<projectId> — one persistent session per clone'),
      SetRow('relay', pausedIn.length ? 'paused in ' + pausedIn.join(', ') : 'live'),
      SetRow('hop ceiling', String((typeof ROOM !== 'undefined' && ROOM.maxHops) || 6)),
      SetRow('rate limit', ((typeof ROOM !== 'undefined' && ROOM.maxRelays) || 0)
        + ' relays per ' + ((typeof ROOM !== 'undefined' && ROOM.relayWindowMin) || 5)
        + ' minutes, counted per project'),
      SetRow('agent memory', (ROOM.memoryRoot || '~/.openclaw/workspace/memory/bridge')
        + '/<agentId>/{SOUL,MEMORY}.md — one identity per agent, shared by all its clones'),
      SetRow('shared memory', ROOM.sharedMemory || '~/.openclaw/workspace/memory/bridge/SHARED.md'),
      SetRow('store', '~/Library/Application Support/Bridge/{prefs,room}.json')),
    h('p.set-note', 'BRIDGE does the routing; the agents do not. A message with no ping goes to '
      + 'that project’s main alone; a pinged one goes to that clone and main does not see it; an '
      + 'agent that writes @lane in its reply hands the work over and Bridge delivers it. Every '
      + 'turn lands in that project’s transcript regardless of who it was addressed to.'),
    h('p.set-note', h('b', 'Isolation, and the one hole in it that is deliberate: '),
      'an agent can only reach agents inside its own project — a ping naming a lane in another '
      + 'project matches nothing and is not delivered. The exception is the shared memory file, '
      + 'which every clone in every project reads and appends to, so a lane working here knows '
      + 'the other projects exist. That is a choice, not an oversight.'),
    h('p.set-note', h('b', 'Projects are yours to make. '),
      'Nothing arriving from the gateway can create one: the sidebar is built from this '
      + 'preference document alone, the create path refuses to run unless a click on this '
      + 'window called it, and every write is normalised before it lands on disk.'),
    h('p.set-note', h('b', 'What this deliberately does not do: '),
      'it does not enable tools.agentToAgent or tools.sessions.visibility. Those would grant every '
      + 'lane on this host cross-transcript read access to every other session, permanently, to buy '
      + 'a routing feature. Relaying from an operator client that already holds operator.write needs '
      + 'neither. Bridge does not read or write the gateway’s configuration.'),
    h('p.set-note', h('b', 'Why there are two bounds: '),
      'a relay chain is agents spending money with no human in it. The hop ceiling stops a chain '
      + 'that keeps handing on; the rate limit stops one that loops. Tripping either is printed '
      + 'into the room transcript, never applied quietly — a silent cap reads as "the agents '
      + 'decided to stop", which is a lie about whose decision it was.')));

  /* ── voice ── */
  const V = LIVE.voice || {};
  box.append(SetSection('Voice',
    'Hold space in an empty composer to dictate.',
    h('div.set-rows',
      SetRow('transcription runs on', V.route === 'local' ? 'this Mac' : 'the gateway host'),
      SetRow('binary', V.binary || 'no local whisper found'),
      SetRow('model', V.model || '—'),
      SetRow('fallback', V.fallback || '—')),
    h('p.set-note', 'The arming rule is Claude Code’s and it is the whole feature: space starts a '
      + 'recording ONLY when the composer is empty, so the space bar is still the space bar. '
      + 'Release transcribes and INSERTS the text at the caret — dictation that sent itself would '
      + 'be dictation you cannot correct.'),
    h('p.set-note', 'Recording is native rather than getUserMedia, so no microphone stream exists '
      + 'inside the web view — the page sends the two strings "start" and "stop" and receives text. '
      + 'Transcription is local for the same reason it matters most: this is whatever is said out '
      + 'loud at the desk, and shipping it to a hosted API to save 400ms is a trade nobody asked '
      + 'for. Which machine actually ran it is printed above and on the composer, so "local" is '
      + 'never assumed.')));

  /* ── api keys ── */
  box.append(SetSection('API keys',
    'Not built. This section is a placeholder and says so.',
    h('div.set-stub',
      h('b', 'Nothing is stored here yet.'),
      h('p', 'Bridge holds exactly two secrets today, both in the macOS Keychain under '
        + 'net.myatlasapp.bridge: the gateway token above, and Bridge\'s own Ed25519 device key. '
        + 'Provider API keys (Anthropic, and anything else a lane uses) live in the gateway\'s '
        + 'own configuration on the Linux host and are not read, written or proxied by this app.'),
      h('p', 'When this section is built it will follow the token\'s pattern exactly — native '
        + 'entry, Keychain storage, no value ever crossing into the web view.'))));

  /* ── prefs ── */
  box.append(SetSection('Preferences', 'Where Bridge keeps what you chose.',
    h('div.set-rows',
      SetRow('store', LIVE.prefsPath || '~/Library/Application Support/Bridge/prefs.json'),
      SetRow('projects', String(PREFS.projects.length)),
      SetRow('document version', String(PREFS.version)),
      SetRow('inbox read marks', String(PREFS.inboxRead.length))),
    h('p.set-note', 'A JSON document, not UserDefaults: the shape is nested, the file is '
      + 'inspectable with cat, and it can be copied or deleted without arguing with cfprefsd\'s '
      + 'write cache. Writes are atomic, so a crash mid-save leaves the previous document rather '
      + 'than half of this one.')));

  return box;
}

const SCOPE_DOC = [
  { id: 'operator.read', what: 'sessions, transcripts, tasks, agents, groups — everything Bridge draws' },
  { id: 'operator.write', what: 'chat.send and chat.abort — steering, and the composer' },
  { id: 'operator.approvals', what: 'see and resolve approval requests' },
  { id: 'operator.questions', what: 'see and answer agent questions — the inbox\'s second half' },
  { id: 'operator.admin', what: 'config and updates. Bridge does not ask for this' },
];

const SetSection = (title, lede, ...kids) =>
  h('section.set-s', h('h3', title), lede ? h('p.set-lede', lede) : null, ...kids);
const SetRow = (k, v) => h('div.set-row', h('b', k), h('i', v));

/* ───────────────── ACCESS: WHO MAY WORK IN THIS PROJECT ─────────────────

   The previous pass deleted the picker that used to live here, on the reasoning
   that a project holds every agent by definition so a control for deselecting
   one was a control for making the invariant false. The invariant was the
   mistake. Chancellor decides who works in a project; this is where he decides
   it, and the two halves of that decision are drawn as two halves:

     ACCESS — may this agent work here at all. Ticking a name grants it; it does
       not start anything. Unticking revokes it AND kills the clone, because
       leaving a live session behind for an agent that has just been excluded is
       an access control that controls nothing.

     THE CLONE — has it actually been launched, and is it working or parked.
       Launch brings it into being. After a task, Idle keeps it and Kill ends
       it; both are here because both are his call and neither happens on its
       own. Bridge never reaps a clone he has not spoken about.

   `main` is fixed on. Its clone IS the room, so a project without it is a
   project whose room swallows everything typed into it. */

function AccessPanel(c) {
  const access = c.access || [];
  const clones = c.clones || [];
  const box = h('div.cust', { 'data-enter': 'cust:' + c.id });
  box.append(h('div.cust-h', 'Who can work in ', h('b', c.name),
    h('span.spacer'),
    h('button.btn', { onclick: () => { S.access = null; S.killing = null; renderAll(); } }, 'done')));

  if (!LIVE.agents.length) {
    box.append(h('div.strip-none', 'The gateway has not answered agents.list yet, so there is '
      + 'nothing to pick from. The agents already allowed in are still listed below.'));
  } else {
    box.append(h('div.cust-grid', LIVE.agents.map((ag) => {
      const on = access.includes(ag.id);
      const isMainAgent = ag.id === 'main';
      const st = cloneStateOf(c, ag.id);
      return h('button.cust-a', {
        'data-on': on ? '1' : '0',
        disabled: isMainAgent,
        title: isMainAgent
          ? 'main is always in a project: its clone is the room.'
          : (on ? 'Revoke ' + ag.id + '’s access to ' + c.name
                : 'Let ' + ag.id + ' work in ' + c.name),
        onclick: fromUser(() => { if (!isMainAgent) toggleAccess(c, ag.id); }),
      },
        h('span.cust-m', on ? '✓' : '+'),
        h('span.cust-n', ag.name),
        h('span.cust-i', ag.id),
        h('span.cust-l', { 'data-live': st === 'active' ? '1' : '0' },
          isMainAgent ? 'the room' : st ? (st === 'idle' ? 'launched · idle' : 'launched')
                                        : on ? 'not launched' : 'no access'));
    })));
  }

  /* THE CLONES, one row each, with the two decisions on them. Only agents with
     access appear: a clone of an excluded agent cannot exist, because revoking
     killed it. */
  const rows = h('div.cln');
  for (const id of access) {
    if (id === 'main') continue;
    const st = cloneStateOf(c, id);
    const key = c.id + '::' + id;
    const row = h('div.cln-r', { 'data-state': st || 'none' },
      h('span.cln-n', agentLabel(id)),
      h('span.cln-i', id),
      h('span.cln-s', st === 'idle' ? 'idle' : st ? 'launched' : 'not launched'),
      h('span.spacer'));
    if (!st) {
      row.append(h('button.btn', {
        title: 'Create ' + id + '’s clone in ' + c.name + ' — its own session, this project’s room.',
        onclick: () => cloneOp(c.id, id, 'launch'),
      }, 'Launch'));
    } else {
      row.append(h('button.btn', {
        title: st === 'idle'
          ? 'Put ' + id + ' back to work in ' + c.name + '.'
          : 'Stop what ' + id + ' is doing here and park it. Session and memory are kept.',
        onclick: () => cloneOp(c.id, id, st === 'idle' ? 'launch' : 'idle'),
      }, st === 'idle' ? 'Wake' : 'Idle'));
      /* KILL IS TWO-STEP. It deletes a gateway session and its transcript, which
         is not something to do on one stray click — the same reason removing a
         project is two-step. */
      if (S.killing === key) {
        row.append(h('span.cln-q', 'Delete this clone’s session?'),
          h('button.add-go', {
            onclick: () => { S.killing = null; cloneOp(c.id, id, 'kill'); },
          }, 'Kill'),
          h('button.add-x', { onclick: () => { S.killing = null; renderAll(); } }, '×'));
      } else {
        row.append(h('button.btn.cln-k', {
          title: 'End ' + id + ' in ' + c.name + ': its session here is deleted and its tab goes. '
            + 'Its memory is the agent’s own and is untouched.',
          onclick: () => { S.killing = key; renderAll(); },
        }, 'Kill'));
      }
    }
    rows.append(row);
  }
  if (access.length > 1) box.append(rows);

  /* Creating an AGENT is a different kind of act from letting one in, and the
     control says so instead of being absent. Disabled with the reason on it — a
     disabled control with no explanation is just a broken one. */
  box.append(h('div.cust-new',
    h('button.cust-a', { disabled: true, 'data-new': '1' },
      h('span.cust-m', '+'), h('span.cust-n', 'New agent…'),
      h('span.cust-i', 'disabled')),
    h('p.cust-why', h('b', 'Why this is off: '),
      'creating an agent writes the gateway\'s own configuration on the Linux host — a new '
      + 'agents entry, a workspace, an agent directory — and the gateway must be restarted to '
      + 'pick it up. That is Chancellor\'s call and a config change, not a click in a monitor. '
      + 'Bridge would also need operator.admin, which it deliberately does not request. '
      + 'Picking from the agents that already exist is what this panel does.')));

  const nLive = clones.length;
  box.append(h('p.cust-foot',
    access.length + ' of ' + (LIVE.agents.length || access.length) + ' agents may work in '
    + c.name + '; ' + (nLive ? nLive + ' launched here' : 'none launched yet') + '. Tabs are the '
    + 'room first, then one per launched clone — an agent with access that has not been launched '
    + 'has no session and no tab. Memory is NOT per project: every clone of an agent reads and '
    + 'writes the same SOUL.md and MEMORY.md wherever it works, so what it learned in another '
    + 'project it knows here.'));
  return box;
}

/* Grant or revoke, then rebuild. `accessToggle` is in live.js behind the intent
   gate, so every caller of this must be wrapped in `fromUser`. */
function toggleAccess(c, agentId) {
  if (!accessToggle(c.id, agentId)) return;
  buildCategories();
  renderAll();
}

/* CREATING A PROJECT CREATES AN EMPTY ONE — `projectCreate` does that part, in
   live.js, and it throws unless the intent token is set. Both callers of this
   function are wrapped in `fromUser`; nothing else calls it.

   It lands in the new project's room AND opens the access picker, because a
   project with nobody in it and no visible way to let anyone in is a dead end —
   which is exactly what the old picker-less flow produced. */
function commitAdd() {
  const name = (S.newName || '').trim();
  const kind = S.adding;         // 'project' (from NAV_SECTIONS) or 'tool'
  if (!name) { S.adding = null; renderAll(); return; }
  // A TOOL is not a project: create it and open its (blank) page. No room, no
  // clones, no picker — a tool is one agent and one page.
  if (kind === 'tool') {
    const id = toolCreate(name);
    S.adding = null; S.newName = '';
    if (!id) { renderAll(); return; }
    openTool(id);
    return;
  }
  const id = projectCreate(name);
  S.adding = null; S.newName = '';
  if (!id) { renderAll(); return; }
  buildCategories();
  S.view = 'sessions';
  S.catId = id;
  S.tab[id] = id + '::room';   // land in the new project's room, which is where
  S.access = id;               // you say the first thing to it, with the picker
  renderAll();                 // open so there is someone to say it to
}

/* Removing a project takes its rooms with it — Room.setProjects drops the
   transcripts on the native side, and the next `room` push rebuilds the page's
   map without them. Selection falls forward to whatever is left. */
function removeProject(id) {
  if (!projectRemove(id)) { S.removing = null; renderAll(); return; }
  S.removing = null;
  delete S.tab[id];
  buildCategories();
  if (S.catId === id) {
    S.catId = (CATEGORIES[0] && CATEGORIES[0].id) || null;
    S.sub = null;
  }
  renderAll();
}

function openInbox() { S.view = 'inbox'; S.removing = null; S.access = null; renderAll(); }
function openSettings() { S.view = 'settings'; S.removing = null; S.access = null; renderAll(); }
function openTool(id) { S.view = 'tool'; S.toolId = id; S.removing = null; S.access = null; renderAll(); }
function removeTool(id) {
  if (!toolRemove(id)) { S.removing = null; renderAll(); return; }
  S.removing = null;
  if (S.view === 'tool' && S.toolId === id) { S.view = 'sessions'; S.toolId = null; }
  renderAll();
}

/* ───────────────────────── render ───────────────────────── */

function renderAll() {
  const keep = captureUi();

  // Inbox and Settings are views, not categories: neither is a place sessions
  // live, and giving them a fake category would put them in the navigator's
  // section lists and into agentById's search.
  //
  // THERE IS NO 'room' VIEW. The room is a project's first tab and renders
  // through the ordinary sessions path below, which is what makes it genuinely
  // tab zero rather than a separate destination that merely looks like one.
  if (S.view === 'inbox') {
    return renderShellView('Inbox', 'Completions and questions', InboxView(), keep);
  }
  if (S.view === 'settings') {
    return renderShellView('Settings', 'Connection, token, scopes and preferences', SettingsView(), keep);
  }
  // A tool is a view like Inbox and Settings, not a category — it has no
  // sessions, so it must not go through the category path below. If its tool
  // was removed out from under it, fall back to the projects view.
  if (S.view === 'tool') {
    const tool = (typeof PREFS !== 'undefined' ? PREFS.tools : []).find((t) => t.id === S.toolId);
    if (tool) return renderToolView(tool, keep);
    S.view = 'sessions'; S.toolId = null;
  }

  const c = category();
  // Two different nothings, drawn differently. No projects is a state he fixes
  // by naming one; no snapshot yet is a state he waits out.
  if (!c) {
    return (typeof PREFS !== 'undefined' && PREFS.loaded && !PREFS.projects.length)
      ? renderNoProjects(keep) : renderWaiting();
  }
  // BRIDGE: S.catId starts null and category() falls forward to the first live
  // one. Write that back, or the hash this render syncs says "#/null/…".
  if (S.catId !== c.id) S.catId = c.id;
  const a = currentAgent();
  // A project with nothing in it is not "still connecting" — it is a project
  // you just made, and the only useful thing on screen is the way to fill it.
  if (!a) return renderEmptyCategory(c, keep);
  const sub = S.sub ? agentById(S.sub) : null;
  document.body.dataset.split = sub ? '1' : '0';

  Nav();
  SidebarFoot();

  const crumb = document.getElementById('crumb');
  if (crumb) crumb.textContent = 'Bridge / ' + CRUMB_KIND + ' / ' + c.name;
  const title = document.getElementById('title');
  if (title) title.textContent = c.name;
  // BRIDGE: a gateway session group has no repo or branch. v4 always printed
  // both; here they are appended only when the Gateway actually reports them.
  const sub2 = h('span', c.subtitle);
  if (c.repo) sub2.append('  ·  ', h('code', c.repo));
  if (c.branch) sub2.append('  ·  ', h('code', c.branch));
  mount('mc-sub', sub2);

  PageTabs(c);
  mount('topbar-actions', TopbarActions());
  mount('alarm', Alarm());

  // TAB ZERO IS THE ROOM. `a.kind === 'room'` is the only branch, and it swaps
  // the PANE alone: the strip, the split pane and the .tx floor are the ordinary
  // ones, which is the point. The room is not a special screen, it is this
  // project's first tab.
  //
  // The strip renders for the room too, and that is not cosmetic. A subagent
  // spawned by this project's `main` clone is parented to the room tab, so
  // skipping the strip here would leave those runs in the category with no way
  // on screen to reach them — visible in `agentById`, unreachable by clicking.
  const panes = h('div.panes', a.kind === 'room' ? RoomView(c) : Pane(a, 'main', c));
  if (sub) panes.append(Pane(sub, 'sub', c));

  /* data-cust is the access picker's open state, published to CSS: the panel
     overlays the work area and the composer gives up its prose while it is on
     screen. See `.work[data-cust="1"]`. */
  const showAccess = S.access === c.id;
  mount('content', h('div.work', { 'data-cust': showAccess ? '1' : '0' },
    showAccess ? AccessPanel(c) : null, Strip(c, a), panes));
  markEntrances();
  syncHash();
  restoreUi(keep);
}

/* Inbox and Settings share the shell: same sidebar, same topbar, one content
   block. Written once so the two cannot drift apart from the sessions view. */
/* A tool's page. Deliberately BLANK for now: a tool will become a single-agent
   surface, but until that agent is built the honest thing to show is an empty
   page that says what it is and what is coming — not a fake transcript or a
   borrowed project room. It sits in the same chrome as Inbox and Settings. */
function renderToolView(tool, keep) {
  return renderShellView(tool.name, 'Custom tool — nothing here yet', h('div.work',
    h('div.empty-cat', { 'data-enter': 'tool:' + tool.id },
      h('b', tool.name + ' is a blank tool.'),
      h('p', 'Tools are single-agent AI utilities you build — a study helper, a prelab writer. '
        + 'This one has no page yet: it is a placeholder you named so it holds its spot in the '
        + 'sidebar.'),
      h('p.empty-cat-w', h('b', 'Coming next: '),
        'one agent behind this page, run from here — not the team-of-agents room a project is.'))),
    keep);
}

function renderShellView(title, sub, body, keep, tabs) {
  Nav();
  SidebarFoot();
  const crumb = document.getElementById('crumb');
  if (crumb) crumb.textContent = 'Bridge / ' + title;
  const t = document.getElementById('title');
  if (t) t.textContent = title;
  mount('mc-sub', h('span', sub));
  // The room passes the agent strip in NAV mode; inbox and settings pass
  // nothing and the strip is emptied, as before.
  if (tabs) { const el = document.getElementById('page-tabs'); if (el) { el.textContent = ''; el.append(tabs); } }
  else mount('page-tabs');
  mount('topbar-actions', TopbarActions(null));
  mount('alarm', Alarm());
  mount('content', body);
  markEntrances();
  syncHash();
  if (keep) restoreUi(keep);
}

function renderEmptyCategory(c, keep) {
  Nav();
  SidebarFoot();
  if (S.catId !== c.id) S.catId = c.id;
  const crumb = document.getElementById('crumb');
  if (crumb) crumb.textContent = 'Bridge / ' + CRUMB_KIND + ' / ' + c.name;
  const t = document.getElementById('title');
  if (t) t.textContent = c.name;
  mount('mc-sub', h('span', c.subtitle));
  mount('page-tabs');
  mount('topbar-actions', TopbarActions());
  mount('alarm', Alarm());
  mount('content', h('div.work',
    h('div.empty-cat', { 'data-enter': 'emptycat:' + c.id },
      h('b', 'This project has no agents.'),
      h('p', 'A project is created with a full set of clones, so this state means the gateway '
        + 'has not answered agents.list yet. It fills in on its own the moment it does.'),
      h('p.empty-cat-w', h('b', 'Bridge does not create agents. '),
        'Creating one writes the gateway\'s own configuration on the Linux host — an agents '
        + 'entry, a workspace, an agent directory — and the gateway must be restarted to pick '
        + 'it up. That is Chancellor\'s call and a config change, not a click in a monitor. '
        + 'Bridge would also need operator.admin, which it deliberately does not request.'))));
  markEntrances();
  syncHash();
  if (keep) restoreUi(keep);
}

/* NO PROJECTS AT ALL. Distinct from "still connecting", and it must be: a fresh
   install and a broken socket look identical if both draw the same spinner, and
   only one of them is fixed by typing a name into the sidebar. */
function renderNoProjects(keep) {
  Nav();
  SidebarFoot();
  const crumb = document.getElementById('crumb');
  if (crumb) crumb.textContent = 'Bridge / Projects';
  const t = document.getElementById('title');
  if (t) t.textContent = 'No projects yet';
  mount('mc-sub', h('span', 'A project is the unit of isolation — it holds its own agents'));
  mount('page-tabs');
  mount('topbar-actions', TopbarActions());
  mount('alarm', Alarm());
  mount('content', h('div.work',
    h('div.empty-cat', { 'data-enter': 'noprojects' },
      h('b', 'Make a project to start.'),
      h('p', 'A project has its own room, and you choose which agents may work in it. Launching '
        + 'one makes a CLONE: the same agent in two projects is two separate sessions with two '
        + 'separate transcripts, so work in one cannot leak into the other. Their MEMORY is not '
        + 'separate — every clone of an agent reads and writes the same SOUL.md and MEMORY.md '
        + 'wherever it works, so an agent stays one agent. When a task is done you either kill '
        + 'the clone or leave it idle.'),
      h('p.empty-cat-w', h('b', 'You make projects. '),
        'Agents cannot — not by convention but in code: nothing arriving from the gateway can '
        + 'add one, and the create path refuses to run unless a click on this window is what '
        + 'called it.'),
      h('button.btn', { 'data-go': '1',
        onclick: () => { S.adding = 'project'; S.newName = ''; renderAll(); } },
        'New project'))));
  markEntrances();
  if (keep) restoreUi(keep);
}


/* BRIDGE: before the first snapshot lands there is nothing to draw. A blank
   window would be indistinguishable from a crashed one, so the wait — and any
   failure to connect — is drawn. */
function renderWaiting(c) {
  const L = typeof LIVE === 'undefined' ? null : LIVE;
  const bad = L && (L.connection === 'error' || L.connection === 'stale');
  Nav();
  SidebarFoot();
  const crumb = document.getElementById('crumb');
  if (crumb) crumb.textContent = 'Bridge';
  const title = document.getElementById('title');
  if (title) title.textContent = bad ? 'Not connected' : 'Connecting';
  mount('mc-sub', h('span', (L && L.detail) || 'opening the gateway subscription'));
  mount('page-tabs');
  mount('topbar-actions', TopbarActions(null));
  mount('alarm');
  mount('content', h('div.empty', { 'data-enter': 'boot' },
    h('div', bad
      ? 'Bridge could not reach the OpenClaw Gateway.'
      : c ? 'This group has no sessions the Gateway will show.'
      : 'Waiting for the session list.'),
    h('div.mc-foot', (L && L.detail) || '')));
  markEntrances();
}

/* ───────────────────────── entrance animations, once ─────────────────────────
   BRIDGE: renderAll() remounts whole subtrees on every state change, so an
   element whose entrance is declared on a plain selector replayed that entrance
   on every tick — the looping Chancellor saw after a page load. The animations
   are kept; app.css now hangs them on `.is-enter`, and `.is-enter` is added only
   when an element's key was absent from the PREVIOUS render. So: appears →
   animates, stays → still, goes away and comes back → animates again.

   The two `animation: … infinite` rules (.tmark[data-stale], .log-cursor) are
   live indicators, not entrances. They are not touched by any of this. */
/* An entrance must also survive a remount that happens WHILE IT IS PLAYING.
   live.js:1352 runs `setInterval(renderAll, 1000)`, and renderAll() remounts
   whole subtrees — so an element that appears at t=0 is replaced at the next
   tick by a fresh node with no `.is-enter`, and the old Set said its key was
   already "seen", so the class was never re-added. The animation was cut off
   mid-flight, and a notice that appeared just before a tick could show a few
   frames of a 0.2s fade or none at all. "Seen" is not "done".

   Keys are stamped with the time they first appeared. The class is re-applied
   to a remounted node while that stamp is still inside ENTER_HOLD_MS — 800ms,
   above the longest entrance app.css declares (`rise 0.6s 0.12s`). After the
   hold the entrance really is over, the key goes still, and the "does not
   replay on re-render" rule holds exactly as before. The stamp is carried
   forward, never refreshed, so a key present across many ticks cannot keep
   renewing its own entrance. */
const ENTER_HOLD_MS = 800;
let prevEnterKeys = new Map();
function markEntrances() {
  if (typeof document.querySelectorAll !== 'function') return;
  const now = new Map();
  const t = Date.now();
  for (const n of document.querySelectorAll('[data-enter]')) {
    const k = n.getAttribute('data-enter');
    const started = prevEnterKeys.has(k) ? prevEnterKeys.get(k) : t;
    now.set(k, started);
    if (t - started < ENTER_HOLD_MS) n.classList.add('is-enter');
  }
  prevEnterKeys = now;
}

/* A full re-render is cheap; preserving focus, caret and scroll is what makes it
   invisible. Cheaper than surgical DOM updates and far less bug-prone. */
function captureUi() {
  const el = document.activeElement;
  const keep = { scroll: {}, focus: null };
  // `agent` is carried so restoreUi can tell a re-render of the same transcript
  // from a switch to a different one. Without it, opening an agent lands you on
  // the oldest message in its history — which for a live run is the least
  // interesting thing it has ever said.
  for (const id of ['tx-main', 'tx-sub']) {
    const n = document.getElementById(id);
    if (n) keep.scroll[id] = { top: n.scrollTop, agent: n.getAttribute('data-agent'),
      atBottom: n.scrollHeight - n.scrollTop - n.clientHeight < 24 };
  }
  if (el && el.tagName === 'TEXTAREA' && el.id) {
    keep.focus = { id: el.id, start: el.selectionStart, end: el.selectionEnd };
  }
  return keep;
}
function restoreUi(keep) {
  for (const [id, v] of Object.entries(keep.scroll)) {
    const n = document.getElementById(id);
    if (!n) continue;
    const switched = n.getAttribute('data-agent') !== v.agent;
    n.scrollTop = (v.atBottom || switched) ? n.scrollHeight : v.top;
  }
  // A pane that did not exist on the previous render has no captured scroll at
  // all — a freshly opened subagent — and must also start at its tail.
  for (const id of ['tx-main', 'tx-sub']) {
    const n = document.getElementById(id);
    if (n && !(id in keep.scroll)) n.scrollTop = n.scrollHeight;
  }
  if (keep.focus) {
    const n = document.getElementById(keep.focus.id);
    if (n) {
      n.focus();
      try { n.setSelectionRange(keep.focus.start, keep.focus.end); } catch { /* not selectable */ }
    }
  }
  for (const n of document.querySelectorAll('.log-b[data-tail="1"]')) n.scrollTop = n.scrollHeight;
}

/* ───────────────────────── navigation ─────────────────────────
   Atlas is hash-routed and its nav items and page-tabs are real anchors with
   real hrefs. Keeping that means the markup is genuinely Atlas's rather than
   anchors with the hrefs filed off — and it makes every view here linkable.
   State is the source of truth; the hash is written to follow it. */

function hashNow() {
  if (S.view === 'inbox') return '#/inbox';
  if (S.view === 'settings') return '#/settings';
  return '#/' + S.catId + '/' + currentTabId() + (S.sub ? '/' + S.sub : '');
}
function syncHash() {
  if (typeof location === 'undefined' || typeof location.hash !== 'string') return;
  const want = hashNow();
  if (location.hash !== want) { try { location.hash = want; } catch { /* file:// */ } }
}
function applyHash() {
  if (typeof location === 'undefined') return;
  const [, catId, tabId, subId] = String(location.hash || '').split('/');
  if (catId === 'inbox') { if (S.view !== 'inbox') openInbox(); return; }
  if (catId === 'settings') { if (S.view !== 'settings') openSettings(); return; }
  if (!catId || !catById(catId)) return;
  if (S.view !== 'sessions') S.view = 'sessions';
  if (hashNow() === location.hash) return;   // already there; nothing to do
  S.catId = catId;
  if (tabId && catById(catId).agents.some((x) => x.id === tabId && !x.parent)) S.tab[catId] = tabId;
  S.sub = subId && agentById(subId) ? subId : null;
  renderAll();
}

function selectCat(id) {
  S.catId = id;
  S.sub = null;
  S.view = 'sessions';
  renderAll();
}
function selectTab(id) {
  S.tab[S.catId] = id;
  S.sub = null;
  renderAll();
}
function toggleSub(id) {
  S.sub = S.sub === id ? null : id;
  renderAll();
}
function jumpTo(catId, agentId) {
  S.view = 'sessions';
  S.catId = catId;
  const c = catById(catId);
  const a = c.agents.find((x) => x.id === agentId);
  if (a && a.parent) { S.tab[catId] = a.parent; S.sub = a.id; }
  else { S.tab[catId] = agentId; S.sub = null; }
  renderAll();
}
/* A lane named in the main transcript is a link to that lane's tab. */
function jumpToLane(lane) {
  const c = category();
  if (!c) return;
  // Matched on `.lane` — the AGENT id — because that is what a transcript names.
  // `.agentId` is a session-derived handle and never equals "frontend-design".
  const a = tabAgents(c).find((x) => x.lane === lane);
  if (a) selectTab(a.id);
}

if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') {
  window.addEventListener('hashchange', applyHash);
}
