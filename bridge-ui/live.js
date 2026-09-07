/* Bridge — the live client's view half.

   Swift owns the socket. This file owns the SHAPE. Everything below turns what
   the Gateway actually reports into exactly the objects data.js documents, so
   the render layer (app.js) is unchanged from the Mission Control prototype
   apart from the guards it needed to survive an empty first paint.

   The boundary is deliberate and worth stating, because it is the thing a Phase
   B reader will want to know:

     Swift  — connects, authenticates, subscribes, backfills, reconnects, and
              hands over trimmed gateway objects. It never renders and never
              lets the token near this file. See bridge-apple/Gateway.swift.
     here   — maps gateway objects onto data.js's contract and calls renderAll.
              It has no network access of its own and no token.

   Messages arrive through window.__bridgeEmit(obj), which Swift calls with
   evaluateJavaScript. Nothing here ever opens a socket.

   The stream is lossy by contract — the Gateway drops event frames for slow
   subscribers rather than closing them — so nothing here treats events as an
   append-only log. Session rows and transcripts are REPLACED wholesale from
   sessions.list / chat.history; live events only decorate the tail between
   backfills, and a reconnect refetches rather than resumes. */

'use strict';

/* ───────────────────────── incoming state ─────────────────────────
   The raw gateway projections, keyed by real sessionKey. Rebuilt into
   CATEGORIES on every change; never rendered directly. */

const LIVE = {
  rows: new Map(),        // sessionKey -> trimmed sessions.list row
  history: new Map(),     // sessionKey -> { messages, pendingInputs, totalMessages }
  toolRuns: new Map(),    // sessionKey -> Map(toolCallId -> {name,args,result,status,at,phase})
  lastEvent: new Map(),   // sessionKey -> epoch ms of the most recent live event
  serverVersion: null,
  connection: 'connecting',
  detail: 'starting',
  readOnly: true,         // Phase A holds operator.read only — see PROTOCOL.md

  /* ── Phase B ── every one of these is a real gateway projection. */
  agents: [],             // agents.list — the roster picker's source of truth
  groups: [],             // sessions.groups.list — the gateway's own groups
  tasks: new Map(),       // taskId -> tasks.list row / task event. The inbox.
  questions: new Map(),   // record id -> the gateway's own question record. §Q
  scopes: [],             // what this connection was actually granted
  requestedScopes: [],
  sshHost: 'atlas',
  tokenPresent: false,
  prefsPath: '',
  /* Which machine dictation runs on, from Voice.describe(). Stated on screen
     rather than assumed: "local" and "gateway" send the audio to different
     computers and that is the user's business, not an implementation detail. */
  voice: { route: '', binary: '', model: '', fallback: '' },
  // (no `writes` map: it was written on every writeResult and read nowhere, so
  //  it grew for the life of the page. The live value goes to onWriteResult,
  //  which is what actually draws it.)
};

/* ───────────────────────── preferences ─────────────────────────
   Owned by Swift (Prefs.swift, a JSON document under Application Support) and
   mirrored here. The page never invents a default it then saves: PREFS stays
   empty until the native side hands over the stored document on `ready`, so a
   first paint that races the load cannot overwrite last week's projects with
   this second's blanks. */

const PREFS = { loaded: false, version: 1, sshHost: 'atlas', projects: [], toolTabs: [], inboxRead: [] };

function savePrefs() {
  if (!PREFS.loaded) return;            // never write back what was never read
  if (typeof window === 'undefined' || !window.__bridgeSend) return;
  window.__bridgeSend({ t: 'prefs', prefs: {
    version: PREFS.version, sshHost: PREFS.sshHost,
    projects: PREFS.projects, toolTabs: PREFS.toolTabs, inboxRead: PREFS.inboxRead,
  } });
}

/* The roster / note record for a category, whether it is a gateway group
   (id `g-…`), a project made here (`p-…`) or a tool tab (`tool-…`). */
function prefFor(catId) {
  const list = catId.startsWith('tool-') ? PREFS.toolTabs : PREFS.projects;
  return list.find((x) => x.id === catId) || null;
}
function prefUpsert(catId, name, patch) {
  const list = catId.startsWith('tool-') ? PREFS.toolTabs : PREFS.projects;
  let rec = list.find((x) => x.id === catId);
  if (!rec) { rec = { id: catId, name, roster: [], note: '' }; list.push(rec); }
  Object.assign(rec, patch);
  savePrefs();
  return rec;
}

/* app.js's clock is seconds relative to page load; the Gateway speaks epoch ms. */
const T_EPOCH0 = Date.now();
const atOf = (ms) => (typeof ms === 'number' && isFinite(ms) ? (ms - T_EPOCH0) / 1000 : null);

/* ───────────────────────── lanes ─────────────────────────
   LANES is what app.js prints on a tab, a roster row and a subagent card. One
   entry per live session, because in Bridge a tab IS a session — labelling
   every frontend-design tab "Frontend Design" would make the strip unreadable.
   The glyph keeps the real agent id visible. */

const GLYPHS = {
  main: 'MAIN', 'frontend-design': 'FE', 'backend-design': 'BE', 'full-stack': 'FS',
  cybersecurity: 'SEC', coursework: 'CW', 'macos-expert': 'MAC', 'linux-expert': 'LNX',
  'windows-expert': 'WIN',
};
function glyphFor(agentId) {
  if (GLYPHS[agentId]) return GLYPHS[agentId];
  const parts = String(agentId || '?').split(/[-_]/).filter(Boolean);
  return (parts.length > 1 ? parts.map((p) => p[0]).join('') : String(agentId).slice(0, 3)).toUpperCase();
}
const titleCase = (s) => String(s || '').split('-').map((w) => w.slice(0, 1).toUpperCase() + w.slice(1)).join(' ');

/* A session's tab label. The Gateway's own label is the honest one; sessions
   that never got one fall back to their key's tail rather than to a guess. */
function laneNameFor(row) {
  const label = row.label || row.displayName;
  if (label && label.trim()) return label.trim();
  const tail = String(row.key).split(':').pop();
  return titleCase(row.agentId) + ' · ' + tail.slice(0, 8);
}

/* ───────────────────────── status ─────────────────────────
   The mock vocabulary app.js renders is running | waiting | completed | failed |
   queued | planned. Mapped from the row's own authoritative fields.

   `waiting` is NOT synthesised. It means "an agent stopped and is waiting on a
   human answer", which in the Gateway is an approval or a question event this
   read-only Phase A client does not subscribe to. Painting an idle session amber
   because it merely looks stopped would be exactly the lie this screen exists to
   prevent, so Bridge does not do it. */
function statusOf(row) {
  if (row.hasActiveRun) return 'running';
  if (row.lastRunError) return 'failed';
  if (row.status === 'error' || row.status === 'failed') return 'failed';
  if (row.status === 'done') return 'completed';
  return 'queued';
}

/* ───────────────────────── transcript ─────────────────────────
   chat.history is display-normalized already. A message is either
   { role:'user', content:'…' } or { role:'assistant', content:[blocks] }, where
   a block is text / thinking / tool_use / tool_result. */

const EDIT_TOOLS = new Set(['Edit', 'Write', 'NotebookEdit', 'MultiEdit', 'str_replace_editor']);

/* An MCP tool's result arrives with `content` as a STRING that is itself the
   JSON encoding of a block array, rather than as the block array chat.history
   uses everywhere else. Read straight off the running app: an
   `mcp__openclaw__exec` result rendered into the transcript as the literal text

     [{"type":"text","text":"Warning: tools.exec.pathPrepend is ignored…\n75: …"}]

   — brackets, quotes, and \n escapes and all, several hundred characters of
   JSON punctuation standing where the output should be. blockText already
   unwraps a real array; this unwraps the encoded one.

   The guard is deliberately narrow, because the thing on the other side of
   being wrong here is mangling legitimate output: a shell command that prints
   JSON must come through byte for byte. So this only fires on an ARRAY whose
   every element carries the block discriminator `type` AND a payload — the
   shape the wire actually sends. A bare JSON array of records fails that test
   and is left exactly as it arrived. */
function decodeEncodedBlocks(s) {
  const t = s.trim();
  if (t.charCodeAt(0) !== 91 /* [ */) return s;      // cheap reject, not a parse
  let v;
  try { v = JSON.parse(t); } catch (e) { return s; }
  if (!Array.isArray(v) || !v.length) return s;
  if (!v.every((x) => x && typeof x.type === 'string'
                   && (typeof x.text === 'string' || x.content !== undefined))) return s;
  const out = v.map(blockText).filter(Boolean).join('\n');
  return out || s;
}

function blockText(b) {
  if (typeof b === 'string') return decodeEncodedBlocks(b);
  if (b && typeof b.text === 'string') return b.text;
  if (b && typeof b.content === 'string') return decodeEncodedBlocks(b.content);
  if (b && Array.isArray(b.content)) return b.content.map(blockText).filter(Boolean).join('\n');
  return '';
}

/* Bash is rendered through app.js's shell block rather than the one-line tool
   row: a 64-character truncation of a real command is worse than useless, and
   the block already exists and already renders stdout. */
function toolEntry(at, name, args, result, isError) {
  if (name === 'Bash' && args && typeof args.command === 'string') {
    return { kind: 'shell', at, cmd: args.command, out: result || '', exit: isError ? 1 : 0 };
  }
  return {
    kind: 'tool', at, name: name || 'tool', args: args && typeof args === 'object' ? args : {},
    result: result === undefined || result === null || result === '' ? (isError ? 'failed' : 'ok') : String(result),
    status: isError ? 'err' : 'ok',
  };
}

/* Long tool output makes the transcript unreadable and is not what this screen
   is for — it is a monitor, not a log viewer. Clipped with the clipping named. */
function clip(s, n) {
  const t = String(s == null ? '' : s);
  return t.length > n ? t.slice(0, n) + '\n… ' + (t.length - n) + ' more characters' : t;
}

function transcriptFor(key) {
  const h = LIVE.history.get(key);
  const out = [];
  const pendingTools = new Map();   // toolCallId -> entry index in `out`

  for (const m of (h && h.messages) || []) {
    const at = atOf(m.timestamp) ?? 0;
    if (typeof m.content === 'string') {
      if (m.content.trim()) out.push({ kind: m.role === 'user' ? 'user' : 'assistant', at, text: m.content });
      continue;
    }
    for (const b of Array.isArray(m.content) ? m.content : []) {
      const type = b && b.type;
      if (type === 'text') {
        const t = blockText(b);
        if (t.trim()) out.push({ kind: m.role === 'user' ? 'user' : 'assistant', at, text: t });
      } else if (type === 'tool_use' || type === 'tool_call') {
        const args = b.arguments || b.input || {};
        const entry = toolEntry(at, b.name, args, '', false);
        entry.__pending = true;
        pendingTools.set(b.id || b.toolCallId, out.length);
        out.push(entry);
      } else if (type === 'tool_result') {
        const idx = pendingTools.get(b.tool_use_id || b.toolCallId || b.id);
        const text = clip(blockText(b), 1400);
        if (idx !== undefined) {
          const e = out[idx];
          delete e.__pending;
          if (e.kind === 'shell') { e.out = text; e.exit = b.is_error ? 1 : 0; }
          else { e.result = text || (b.is_error ? 'failed' : 'ok'); e.status = b.is_error ? 'err' : 'ok'; }
        } else if (text.trim()) {
          out.push({ kind: 'system', at, text: clip(text, 300) });
        }
      }
      // `thinking` blocks are deliberately dropped: they are the model's private
      // reasoning, not session state, and this is a screen someone else can see.
    }
  }

  // A tool call whose result never arrived (run still in flight, or the history
  // page cut between the call and its result) says so rather than showing "ok".
  for (const e of out) {
    if (!e.__pending) continue;
    delete e.__pending;
    if (e.kind === 'shell') e.out = '';
    else { e.result = 'no result recorded'; e.status = 'ok'; }
  }

  // Live tool events arriving after the last backfill.
  const runs = LIVE.toolRuns.get(key);
  if (runs) {
    for (const t of runs.values()) {
      if (t.merged) continue;
      // DECODED HERE TOO, and the omission was caught by a screenshot of the
      // live app rather than by any unit test.
      //
      // `decodeEncodedBlocks` was added for MCP results that arrive as a string
      // holding the JSON encoding of a block array, and it was wired into
      // `blockText` — which covers the chat.history path and ONLY that path.
      // A live `session.tool` event's result never passes through blockText: it
      // comes off the JS bridge already a string and went straight into the
      // row. So every MCP tool call still in flight, or newer than the last
      // backfill, rendered as literal [{"type":"text","text":"…"}] — which is
      // exactly the defect the decode was written to fix, in the half of the
      // pipeline nobody re-checked.
      //
      // Measured, before: `--view mcptool` reported mcpRows=4 stillEncoded=4 on
      // a live session. The previous pass recorded "the decode works on live
      // data" as ASSERTED, and it was wrong.
      out.push(toolEntry(t.at, t.name, t.args,
                         clip(decodeEncodedBlocks(String(t.result || '')), 1400),
                         t.status === 'err'));
    }
  }
  return out;
}

function countTools(entries) {
  let tools = 0, edits = 0;
  for (const e of entries) {
    if (e.kind === 'tool') { tools++; if (EDIT_TOOLS.has(e.name)) edits++; }
    else if (e.kind === 'shell') tools++;
  }
  return { tools, edits };
}

/* The headline under the pane title. The session label is ALREADY the tab
   label and the pane title, so falling back to it printed the same sentence
   three times in a column. The observer digest is the right answer when the
   Gateway has produced one; otherwise the last thing the agent actually said is
   the honest one-line summary of what this session is doing. */
function headlineFor(row, h) {
  const digest = row.observerDigest && row.observerDigest.headline;
  if (digest) return digest;
  const msgs = (h && h.messages) || [];
  for (let i = msgs.length - 1; i >= 0; i--) {
    const m = msgs[i];
    if (m.role !== 'assistant') continue;
    const text = Array.isArray(m.content)
      ? m.content.filter((b) => b && b.type === 'text').map((b) => b.text || '').join(' ')
      : (typeof m.content === 'string' ? m.content : '');
    const line = String(text).split('\n').map((l) => l.trim())
      .find((l) => l && !/^[#>*_`-]+$/.test(l));
    if (line) return clip(line.replace(/^#+\s*/, '').replace(/\*\*/g, ''), 130);
  }
  return row.label || row.displayName || titleCase(row.agentId) + ' session';
}

/* The one operation in flight: a session.tool start with no matching end. */
function operationFor(key) {
  const runs = LIVE.toolRuns.get(key);
  if (!runs) return null;
  let best = null;
  for (const t of runs.values()) {
    if (t.phase !== 'start') continue;
    if (!best || t.at > best.at) best = t;
  }
  if (!best) return null;
  const args = best.args || {};
  const detail = args.description || args.file_path || args.pattern || args.command
    || args.path || args.query || Object.values(args).find((v) => typeof v === 'string') || '';
  return { label: best.name, detail: clip(String(detail), 70).split('\n')[0], startedAt: best.at };
}

/* ───────────────────────── §I  the inbox ─────────────────────────

   Two entry types, and they are on very different footing. Read this before
   changing anything here, because half of it is a deliberate absence.

   COMPLETIONS are real. `tasks.list` answers under operator.read — verified
   against the live gateway, not assumed — and it is a ledger of DELEGATIONS,
   one row per delegated task rather than one per agent. That granularity is
   exactly Chancellor's rule: "not every agent, only the whole task".

   Two filters turn that ledger into the rule:

     * kind. `automation_run` rows are cron firings — 60-odd `heartbeat-main`
       entries in the live corpus. A heartbeat is not a delegated task and an
       inbox that lists them is an inbox nobody opens. They are counted and
       named in the footer rather than silently dropped.
     * roots. When a lane spawns its own child, that child is another task row
       whose ownerKey is the parent's session. Those fold into the parent, so a
       task tree contributes ONE entry — the parent's final summary, not each
       child's. `childOf` below is that test, computed over the whole ledger.

   QUESTIONS ARE REAL NOW, and this is the single most valuable thing in
   Phase C. Phase B built the receiver and could not reach it: `question.list`
   answered FORBIDDEN / missing scope: operator.questions, so the section stated
   why it was empty instead of being empty and silent.

   Phase C holds the scope. The mechanism is shipped in this gateway build and
   was read off its own source rather than inferred:

     question.list    -> { questions: [record] }
     question.get     -> { question: record }
     question.resolve -> { id, answers: { answers: { <innerId>: [value] } } }
     question.requested / question.resolved as events

   A record is

     { id, questions: [{ questionId, header, question,
                         options: [{ label, description? }],
                         multiSelect?, isSecret?, isOther? }],
       agentId?, sessionKey?, runId?, createdAtMs, expiresAtMs,
       status: "pending" | "answered" | "cancelled" | "expired" }

   TWO IDS, AND THEY ARE NOT THE SAME STRING. `record.id` addresses the record;
   `record.questions[i].questionId` keys the answers map. Resolving with the
   wrong one is accepted by the schema and answers nothing, which is the exact
   shape of a bug that looks like it worked. Both are carried on every entry.

   A question that has gone terminal is dropped rather than shown greyed: it can
   be answered somewhere else (the Control UI, a Discord button) while this
   window is open, and a stale button that silently fails is worse than a row
   that disappeared. `question.resolved` removes it, and every resolve re-reads
   question.list rather than trusting the local edit.

   Secret questions are NOT rendered. A secret-store question expects a value
   that is written straight into the gateway's secret store, and this screen —
   which is explicitly a screen other people can see — is the wrong surface for
   one. It is listed with its header and a line saying to answer it elsewhere. */

const INBOX = [];

const TASK_DONE = new Set(['completed', 'failed', 'cancelled', 'error', 'aborted']);

function buildInbox() {
  const all = [...LIVE.tasks.values()];
  const delegated = all.filter((t) => t.kind !== 'automation_run');

  /* Every session key that is some other DELEGATED task's child. A task owned
     by one of these is nested and belongs to that parent's entry.

     TWO FIXES HERE, AND THE FIRST ONE WAS HIDING THE ENTIRE INBOX.

     Phase B built this set from `all` — every task row, including the cron and
     cli kinds it then filtered back out. On this gateway there is exactly one
     `kind: "cli"` row, the overnight watchdog tick, and it carries

         ownerKey        = agent:main:main
         childSessionKey = agent:main:main

     …the same key in both. That put `agent:main:main` into childKeys, and
     `agent:main:main` is the owner of 25 of the 33 delegated tasks on this host.
     Every one of them was therefore classified as somebody's child and folded
     away, leaving ONE root — and an inbox that said "No delegated task has
     finished yet on this gateway" while thirty completed ones sat behind the
     sentence. It was found by looking at the screen: a footer reporting 25
     folded children above an empty list is not a consistent story.

       * The child set must come from the SAME corpus being classified. A row
         that is excluded from the feed must not get to reparent rows that are
         in it.
       * A self-referential row is nobody's parent and nobody's child. A task
         whose child session IS its owner session did not spawn anything.

     With both applied: 31 roots, 30 of them terminal, 2 genuinely folded. */
  const childKeys = new Set(delegated
    .filter((t) => t.childSessionKey && t.childSessionKey !== t.ownerKey)
    .map((t) => t.childSessionKey));
  const isRoot = (t) => !t.ownerKey || !childKeys.has(t.ownerKey);
  const roots = delegated.filter(isRoot);
  const nested = new Map();               // ownerKey -> count of folded children
  for (const t of delegated) {
    if (isRoot(t)) continue;
    nested.set(t.ownerKey, (nested.get(t.ownerKey) || 0) + 1);
  }

  const read = new Set(PREFS.inboxRead);
  const out = [];
  for (const t of roots) {
    if (!TASK_DONE.has(t.status)) continue;          // a completion, not a start
    const sum = summaryForTask(t);
    out.push({
      id: t.id,
      kind: 'completion',
      status: t.status,
      title: t.title || '(untitled task)',
      agentId: t.agentId || '?',
      sessionKey: t.childSessionKey || t.sessionKey || '',
      parentKey: t.ownerKey || t.sessionKey || '',
      summary: sum.text,
      summaryKind: sum.kind,
      // A task can finish and still never deliver its result. That is a
      // separate fact from success or failure and the row says so.
      blocked: t.terminalOutcome === 'blocked',
      error: typeof t.error === 'string' ? t.error : null,
      toolUseCount: t.toolUseCount || 0,
      folded: nested.get(t.childSessionKey) || 0,
      at: atOf(t.endedAt || t.updatedAt || t.createdAt) ?? 0,
      /* ELAPSED, PER CHANCELLOR'S RULE. A finished task freezes at how long it
         TOOK — "48m", forever — rather than drifting into "2h ago", which is a
         fact about the clock and not about the work. `endedAt` is not always
         set on a task row, so `updatedAt` is the documented fallback; where
         neither start nor end exists the row says so instead of showing 0s. */
      startedAt: atOf(t.startedAt || t.createdAt),
      endedAt: atOf(t.endedAt || t.updatedAt),
      running: false,
      read: read.has(t.id),
    });
  }

  /* Tasks still in flight, kept separate. They are not completions and must not
     be filed as ones — but their elapsed time is the half of the rule that
     ticks, and a running delegation is exactly what you open an inbox to check
     on. They are listed under their own heading and never counted as unread. */
  INBOX.running = roots
    .filter((t) => !TASK_DONE.has(t.status))
    .map((t) => ({
      id: t.id, title: t.title || '(untitled task)', agentId: t.agentId || '?',
      sessionKey: t.childSessionKey || t.sessionKey || '',
      startedAt: atOf(t.startedAt || t.createdAt), endedAt: null, running: true,
      toolUseCount: t.toolUseCount || 0,
      lastTool: t.lastToolName || '',
      summary: (t.lastActivity || t.progressSummary || '').trim(),
    }))
    .sort((a, b) => (a.startedAt ?? 0) - (b.startedAt ?? 0));

  // Questions. Real records from the gateway, one entry per PENDING record.
  for (const rec of LIVE.questions.values()) {
    if (rec.status && rec.status !== 'pending') continue;
    const qs = Array.isArray(rec.questions) ? rec.questions : [];
    const first = qs[0] || {};
    out.push({
      id: rec.id,
      kind: 'question',
      status: 'waiting',
      title: first.header || 'Agent has a question',
      agentId: rec.agentId || '?',
      sessionKey: rec.sessionKey || '',
      parentKey: '',
      summary: first.question || '',
      summaryKind: 'question',
      toolUseCount: 0,
      folded: 0,
      // Questions are never marked read by looking at them. An unanswered
      // question is still owed an answer, and letting it stop counting because
      // the inbox was open once is how it gets forgotten.
      read: false,
      at: atOf(rec.createdAtMs) ?? 0,
      expiresAt: atOf(rec.expiresAtMs),
      record: rec,
      questions: qs,
      // A record can hold several questions. The inbox answers ONE — the
      // gateway's own single-question resolution path is what every channel
      // uses — and says so when there are more.
      extra: Math.max(0, qs.length - 1),
      secret: !!first.isSecret,
      multi: !!first.multiSelect,
      other: !!first.isOther,
      options: Array.isArray(first.options) ? first.options : [],
      innerId: first.questionId || '',
    });
  }

  out.sort((a, b) => b.at - a.at);
  const running = INBOX.running || [];
  INBOX.length = 0;
  INBOX.push(...out);
  INBOX.running = running;
  // Counters the footer prints, so what was filtered is stated rather than
  // quietly missing.
  INBOX.meta = {
    automationRuns: all.length - delegated.length,
    inFlight: roots.filter((t) => !TASK_DONE.has(t.status)).length,
    foldedChildren: [...nested.values()].reduce((n, x) => n + x, 0),
    questionsPossible: LIVE.scopes.includes('operator.questions')
      || LIVE.scopes.includes('operator.admin'),
    questionsPending: [...LIVE.questions.values()].filter((r) => !r.status || r.status === 'pending').length,
  };
}

/* WHAT A FINISHED TASK ACTUALLY CONCLUDED.

   There is no single field for this, which is worth stating plainly because the
   obvious guess is wrong. Measured across the 19 real delegated tasks on this
   gateway:

     lastActivity     present on RUNNING tasks only — undefined once one ends.
     progressSummary  13 of 19. It is the agent's OPENING note ("I'll start with
                      reconnaissance before writing any code…"), not a
                      conclusion. Printing it as the completion summary would
                      caption every finished task with how it began.
     terminalSummary  2 of 19, and in BOTH it was a delivery-failure notice
                      ("Required completion delivery failed before reaching the
                      requester…") rather than anything the agent wrote.

   The text does exist: it is the last thing the agent said in the child session
   the task ran in, which is the most literal reading of "the parent agent's
   final summary". Gateway.swift backfills chat.history for those sessions so
   this usually resolves.

   Each source is ranked and LABELLED, so the inbox never presents an opening
   note as a conclusion. */
function summaryForTask(t) {
  const key = t.childSessionKey;
  const h = key && LIVE.history.get(key);
  if (h && h.messages && h.messages.length) {
    for (let i = h.messages.length - 1; i >= 0; i--) {
      const m = h.messages[i];
      if (m.role !== 'assistant') continue;
      const text = Array.isArray(m.content)
        ? m.content.filter((b) => b && b.type === 'text').map((b) => b.text || '').join(' ')
        : (typeof m.content === 'string' ? m.content : '');
      if (String(text).trim()) return { text: String(text).trim(), kind: 'closing' };
    }
  }
  if (t.terminalSummary) return { text: t.terminalSummary.trim(), kind: 'terminal' };
  if (t.progressSummary) return { text: t.progressSummary.trim(), kind: 'opening' };
  if (t.lastActivity) return { text: t.lastActivity.trim(), kind: 'activity' };
  return { text: '', kind: 'none' };
}

/* A pending question counts as unread until it is ANSWERED, not until it is
   looked at — see the `read: false` above. Completions use the read marks. */
const inboxUnread = () => INBOX.filter((e) => !e.read).length;

function markInboxRead(id) {
  if (PREFS.inboxRead.includes(id)) return;
  PREFS.inboxRead.push(id);
  // Bounded: this list only ever grows, and it is a set of ids nobody reads
  // back beyond membership.
  if (PREFS.inboxRead.length > 500) PREFS.inboxRead = PREFS.inboxRead.slice(-500);
  savePrefs();
  buildInbox();
}
function markAllInboxRead() {
  for (const e of INBOX) if (!PREFS.inboxRead.includes(e.id)) PREFS.inboxRead.push(e.id);
  if (PREFS.inboxRead.length > 500) PREFS.inboxRead = PREFS.inboxRead.slice(-500);
  savePrefs();
  buildInbox();
}

/* ───────────────────────── row -> agent ───────────────────────── */

function agentFor(row) {
  const key = row.key;
  const entries = transcriptFor(key);
  const { tools, edits } = countTools(entries);
  const status = statusOf(row);
  const h = LIVE.history.get(key);
  const started = atOf(row.startedAt);
  const liveAt = LIVE.lastEvent.get(key);

  return {
    id: key,
    sessionKey: key,
    sessionId: row.sessionId || null,
    agentId: row.isMain ? 'main' : 'lane:' + key,
    lane: row.agentId,
    parent: null,                                  // filled by buildCategories
    status,
    aborted: !!row.abortedLastRun,
    headline: headlineFor(row, h),
    operation: status === 'running' ? operationFor(key) : null,
    startedAt: started,
    endedAt: status === 'running' ? null
      : (started !== null && row.runtimeMs ? started + row.runtimeMs / 1000 : atOf(row.updatedAt)),
    lastEventAt: atOf(liveAt || row.lastInteractionAt || row.updatedAt) ?? 0,
    // ctx is the resolved context WINDOW, not tokens in context — see the
    // label in app.js's UsageStrip. total is cumulative usage for the session.
    tokens: { ctx: row.contextTokens || 0, total: row.totalTokens || 0 },
    // The row says whether its token count is current. Mid-turn it is not, and
    // the strip prints a gap rather than a confident zero.
    tokensSettled: row.totalTokensFresh !== false || (row.totalTokens || 0) > 0,
    model: row.model || 'unknown',
    cwd: row.cwd || null,
    tools, edits,
    transcript: entries,
    pendingInputs: ((h && h.pendingInputs) || []).map((p) => ({
      id: p.id, text: p.text || '', state: p.state || 'queued',
      queuedAt: atOf(p.queuedAt || p.createdAt) ?? 0,
      pickedUpAt: atOf(p.pickedUpAt) ?? 0,
      reason: p.reason || null,
    })),
    error: row.lastRunError
      ? { message: typeof row.lastRunError === 'string' ? row.lastRunError
            : (row.lastRunError.message || 'run ended badly'),
          code: (row.lastRunError && row.lastRunError.code) || null }
      : null,
    totalMessages: (h && h.totalMessages) || 0,
    _row: row,
  };
}

/* ───────────────────────── categories ─────────────────────────
   Three sections, all drawn from real facts:

     Projects — the gateway's own session groups (`sessions.groups.list`, which
                is what the `category` field on a row refers to), plus any
                project made here. A gateway group with no live sessions still
                appears: it exists on the gateway whether or not anything is
                running in it, and hiding it would make "add a project" look
                like it did nothing.
     Tools    — Bridge's own tool tabs, from prefs. Education ships as the first.
     Agents   — one per agent id, holding that agent's ungrouped sessions. Kept
                from Phase A: a live session that belongs to no group still has
                to be reachable, and dropping it would be a regression.

   A SESSION APPEARS IN EXACTLY ONE CATEGORY. app.js's agentById searches every
   category and returns the first hit, so the same session in two places makes
   navigation ambiguous — which is also why a tool tab does not adopt sessions
   that already belong to a project. See rosterApply below.

   ROSTERS. A category with an empty roster shows every session it holds, which
   is Phase A's behaviour and stays the default. A category with a roster shows
   the chosen agents as its top tabs: each agent's sessions here if it has any,
   and otherwise one placeholder tab that says so rather than a tab that is
   missing without explanation. */

/* A tab for a rostered agent with no session behind it. `planned` is app.js's
   existing vocabulary for "no session exists", and PlanBody already renders it
   honestly, so this reuses that rather than inventing a seventh status. */
function placeholderAgent(agentId, catId, why) {
  const meta = LIVE.agents.find((x) => x.id === agentId);
  return {
    id: 'none:' + catId + ':' + agentId,
    sessionKey: null, sessionId: null,
    agentId: 'none:' + catId + ':' + agentId,
    lane: agentId,
    parent: null,
    status: 'planned',
    aborted: false,
    headline: why,
    operation: null,
    startedAt: null, endedAt: null, lastEventAt: 0,
    tokens: { ctx: 0, total: 0 }, tokensSettled: true,
    model: (meta && meta.model) || 'unknown',
    cwd: (meta && meta.workspace) || null,
    tools: 0, edits: 0,
    transcript: [], pendingInputs: [],
    error: null, totalMessages: 0,
    plan: null,
    _row: { key: null, agentId },
    _placeholder: true,
  };
}

/* Apply a category's roster to the sessions it holds. */
function rosterApply(cat, roster) {
  if (!roster || !roster.length) return cat.agents;
  const keep = cat.agents.filter((a) => roster.includes(a.lane));
  const have = new Set(keep.map((a) => a.lane));
  const out = [...keep];
  for (const id of roster) {
    if (have.has(id)) continue;
    const ph = placeholderAgent(id, cat.id, 'No session for this agent in ' + cat.name + ' yet.');
    // The empty pane has to say what it would hold. A tool tab carries that
    // sentence as data (Prefs.defaultToolTabs writes Education's); a project
    // falls back to the general one. Either way the pane is never blank.
    ph.plan = { purpose: cat.note || (cat.kind === 'tool'
      ? cat.name + ' has no session for ' + agentLabel(id) + '. Nothing inside a tool tab is '
        + 'built in this version — this tab is the agent, its roster slot, and the session it '
        + 'would open. Selecting it once a session exists shows that session\'s real transcript.'
      : agentLabel(id) + ' is rostered for ' + cat.name + ' but has no session in this project. '
        + 'It gets a tab so the roster is visibly complete rather than silently short.') };
    out.push(ph);
  }
  // Roster order is the user's chosen tab order, and placeholders sort with it.
  return out.sort((a, b) => roster.indexOf(a.lane) - roster.indexOf(b.lane));
}

function buildCategories() {
  const rows = [...LIVE.rows.values()]
    .filter((r) => !r.archived)
    .sort((a, b) => (b.lastInteractionAt || b.updatedAt || 0) - (a.lastInteractionAt || a.updatedAt || 0));

  const groups = new Map();   // catId -> { id, name, kind, rows: [] }
  const put = (id, name, kind, row) => {
    if (!groups.has(id)) groups.set(id, { id, name, kind, rows: [] });
    if (row) groups.get(id).rows.push(row);
  };

  // Every gateway group, whether or not it currently holds a session.
  for (const g of LIVE.groups) put('g-' + slug(g.name), g.name, 'project', null);
  for (const row of rows) {
    if (row.category) put('g-' + slug(row.category), row.category, 'project', row);
    else put('a-' + slug(row.agentId), titleCase(row.agentId), 'agent', row);
  }
  // Projects made in Bridge. They hold no gateway sessions of their own — a
  // session joins a group by carrying its `category`, and setting that needs
  // operator.write — so they are real, persistent, rosterable, and honest about
  // being empty until that scope exists. The UI says exactly this.
  for (const proj of PREFS.projects) {
    if (proj.id.startsWith('p-')) put(proj.id, proj.name, 'project', null);
  }
  for (const tab of PREFS.toolTabs) put(tab.id, tab.name, 'tool', null);

  const cats = [];
  for (const g of groups.values()) {
    const keys = new Set(g.rows.map((r) => r.key));
    const agents = g.rows.map(agentFor);
    for (const a of agents) {
      const parentKey = a._row.parentSessionKey || a._row.spawnedBy;
      if (parentKey && parentKey !== a.id && keys.has(parentKey)) a.parent = parentKey;
    }
    const cat = { id: g.id, name: g.name, kind: g.kind, repo: null, branch: null,
                  planned: false, agents };
    const rec = prefFor(g.id);
    cat.roster = (rec && rec.roster) || [];
    cat.note = (rec && rec.note) || '';
    cat.local = g.id.startsWith('p-');
    cat.agents = rosterApply(cat, cat.roster);

    const real = cat.agents.filter((a) => !a._placeholder);
    const running = real.filter((a) => a.status === 'running').length;
    const failed = real.filter((a) => a.status === 'failed').length;
    const n = real.length;
    cat.subtitle = (n ? n + (n === 1 ? ' session' : ' sessions') : 'no sessions')
      + (running ? ' · ' + running + ' running' : '')
      + (failed ? ' · ' + failed + ' failed' : '')
      + (cat.roster.length ? ' · roster of ' + cat.roster.length : '');
    cats.push(cat);
  }

  // Projects, then tools, then agent lanes; inside each, busiest first.
  const order = (c) => (c.kind === 'project' ? 0 : c.kind === 'tool' ? 1 : 2);
  cats.sort((a, b) => order(a) - order(b)
    || (b.agents.filter((x) => x.status === 'running').length - a.agents.filter((x) => x.status === 'running').length)
    || a.name.localeCompare(b.name));

  // LANES, rebuilt to exactly the set of live sessions.
  for (const k of Object.keys(LANES)) delete LANES[k];
  for (const c of cats) {
    for (const a of c.agents) {
      LANES[a.agentId] = { name: a._placeholder ? agentLabel(a.lane) : laneNameFor(a._row),
                           glyph: glyphFor(a.lane) };
    }
  }
  // Every real agent on the gateway is addressable by its own id too — that is
  // what a ping bubble targets, and what "@lane" resolves against.
  for (const a of LIVE.agents) if (!LANES[a.id]) LANES[a.id] = { name: a.name, glyph: glyphFor(a.id) };

  CATEGORIES.length = 0;
  CATEGORIES.push(...cats);
  /* First paint lands on whatever is actually happening. Two ordering traps
     here, and Phase B walked into the second one:

       1. `hasActiveRun` is per-turn, so a busy session can read idle for the
          second the snapshot is taken — hence "running, else most recently
          touched", and only ever on the FIRST snapshot: after that the
          selection is the user's and is not moved.
       2. `cats.length` is not the same as "there is anything to look at".
          Preferences arrive before the session list does, and prefs alone
          produce the tool tabs — so the first non-empty build can be nothing
          but Education, full of rostered placeholders. Bridge duly picked it
          and every launch opened on an empty tab while 27 live sessions sat
          one click away. The gate is a real session, not a category. */
  const hasReal = cats.some((c) => c.agents.some((a) => !a._placeholder));
  if (!pickedInitial && hasReal) {
    pickedInitial = true;
    const busy = cats.find((c) => c.agents.some((a) => a.status === 'running' && !a._placeholder));
    const anyReal = cats.find((c) => c.agents.some((a) => !a._placeholder));
    S.catId = (busy || anyReal || cats[0]).id;
  }
  NAV_SECTIONS.length = 0;
  const ids = (k) => cats.filter((c) => c.kind === k).map((c) => c.id);
  NAV_SECTIONS.push({ title: 'Projects', ids: ids('project'), add: 'project' });
  NAV_SECTIONS.push({ title: 'Tools', ids: ids('tool'), add: 'tool' });
  const lanes = ids('agent');
  if (lanes.length) NAV_SECTIONS.push({ title: 'Agents', ids: lanes });
  buildInbox();
}

/* The display name for an agent id, from agents.list when the gateway has
   answered and from the id itself when it has not. */
function agentLabel(agentId) {
  const a = LIVE.agents.find((x) => x.id === agentId);
  return (a && a.name) || titleCase(agentId);
}

let pickedInitial = false;
const slug = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'x';

/* ───────────────────────── §C  the room ─────────────────────────

   Bridge IS the room. There is no multi-agent room in OpenClaw — a session
   belongs to one agent and an agent sees only its own transcript — so the
   shared main chat is Bridge's own object, owned by Room.swift, persisted next
   to prefs, and mirrored here.

   Nothing in this file routes anything. Swift decides which session key a ping
   means, whether the standing preamble is due, and what goes into the shared
   transcript; the page sends "this text, pinging that agent" and draws what
   comes back. Putting the routing on the native side is what lets Bridge relay
   as an operator client holding operator.write, instead of switching on
   tools.agentToAgent and tools.sessions.visibility — which would grant every
   lane on the host cross-transcript read access forever to buy a routing
   feature. Neither key is set and Bridge does not write gateway config.

   THE RULES, WHICH ARE CHANCELLOR'S AND ARE IMPLEMENTED LITERALLY:

     * no ping   -> main (Thuban) alone. He sees every unpinged message.
     * a ping    -> that agent alone. main does NOT see it.
     * agents ping each other. Bridge parses the ping out of an agent's reply
       and hands the work to the named lane.
     * everything appears here regardless of who it was addressed to. Pings
       control who TAKES A TURN, not who is displayed.

   The relay bounds — hop ceiling and rolling rate limit — are enforced in
   Swift and REPORTED here, because a chain of agents spending money without a
   human in it is not something to cap quietly. */

const ROOM = {
  messages: [],
  paused: false,
  pauseReason: '',
  agents: [],          // [{id, name, key}] — the gateway's real roster
  maxHops: 6,
  maxRelays: 0,
  relayWindowMin: 5,
  relaysInWindow: 0,
  loaded: false,
};

function roomSend() {
  const text = (S.roomDraft || '').trim();
  if (!text) return;
  const ping = S.roomPing || null;
  if (!bridgeSend({ t: 'room.send', text, ping })) {
    ROOM.messages = ROOM.messages.concat([{
      id: 'local-' + Date.now(), at: Date.now(), from: 'bridge', to: null, kind: 'error', hop: 0,
      text: 'Bridge is not running inside the native shell, so there is no socket to relay on.',
    }]);
  }
  S.roomDraft = '';
  renderAll();
}
const roomPause = (p) => bridgeSend({ t: 'room.pause', paused: p });
const roomClear = () => bridgeSend({ t: 'room.clear' });

/* ───────────────────────── §Q  answering a question ─────────────────────────
   Two ids, and they are different strings: the RECORD id addresses the record,
   the INNER questionId keys the answers map. Both go over. */

function answerQuestion(entry, value) {
  if (!entry || !entry.innerId) return;
  const id = reqId('q');
  S.answering = { id, questionId: entry.id, value, state: 'sending', at: nowS() };
  if (!bridgeSend({ t: 'question.resolve', requestId: id, id: entry.id,
                    questionId: entry.innerId, value })) {
    S.answering = { ...S.answering, state: 'refused',
      message: 'Bridge is not running inside the native shell.' };
  }
  renderAll();
  setTimeout(() => {
    if (S.answering && S.answering.id === id && S.answering.state === 'sending') {
      S.answering = { ...S.answering, state: 'refused', code: 'TIMEOUT',
        message: 'The gateway did not answer within 30s.' };
      renderAll();
    }
  }, 31000);
}

/* ───────────────────────── §V  hold space to talk ─────────────────────────

   The page's whole part in this is two strings. It never opens a microphone,
   never holds audio, and never sees a model: `voice start` / `voice stop` go to
   Swift, and finished text comes back. See Voice.swift for why the recording is
   native rather than getUserMedia.

   THE ARMING RULE IS THE FEATURE. Space-hold triggers ONLY when the composer is
   empty — Claude Code's rule, and the reason the space bar still works as the
   space bar. `voiceArmed` is that condition and nothing else calls into Swift
   without passing it. */

const VOICE = { state: 'idle', requestId: null, error: null, route: '', at: 0, target: null,
  /* requestId -> the composer that hold was dictated INTO. A hold's transcript
     belongs to the box it was spoken at, not to whatever is on screen when
     whisper happens to finish — and whisper routinely finishes AFTER the next
     hold has begun, because releasing space leaves the composer empty and so
     re-arms it immediately. Keyed by request rather than read off VOICE.target
     for exactly that reason. Entries are deleted on every terminal state. */
  pending: Object.create(null) };

/* True when a space keydown in this composer should start recording rather than
   type a space: the box must be EMPTY, no modifier held, and not a repeat. */
function voiceArmed(ev, value) {
  return ev.key === ' '
    && !ev.repeat
    && !ev.metaKey && !ev.ctrlKey && !ev.altKey
    && String(value || '').length === 0;
}

function voiceStart(targetId) {
  if (VOICE.state === 'recording' || VOICE.state === 'arming') return;
  const id = reqId('v');
  VOICE.requestId = id;
  VOICE.target = targetId;
  VOICE.pending[id] = targetId;
  /* Bounded, because a hold whose answer never comes back from Swift would
     otherwise leave an entry behind for the life of the window. Eight is far
     more than can ever be genuinely in flight — dictation is serial. */
  const ids = Object.keys(VOICE.pending);
  if (ids.length > 8) delete VOICE.pending[ids[0]];
  VOICE.state = 'arming';
  VOICE.error = null;
  VOICE.at = nowS();
  if (!bridgeSend({ t: 'voice', phase: 'start', requestId: id })) {
    VOICE.state = 'error';
    VOICE.error = 'Voice needs the native shell — there is no microphone in a browser tab here.';
  }
  renderAll();
}

function voiceStop() {
  if (!VOICE.requestId) return;
  /* A HOLD IS STOPPED ONCE.

     One release fires keyup, and if the user then clicks anywhere - the send
     button, another lane, the room - it fires blur too. The blur handler's only
     guard is that a requestId exists, and it still does: `voiceStop` leaves it
     set so the answer can be correlated, and whisper takes a second or more.
     So an ordinary "dictate, release, click send" sent TWO `voice stop`
     messages for one hold.

     Swift's `stop(requestId:)` clears `active` on the first one. The second
     fails its `guard active == requestId` and goes down the no-matching-start
     path, which answers `idle`. `idle` is terminal, so the page deleted
     VOICE.pending[rid] - and when the real `done` arrived a second later with
     the sentence in it, `rid in VOICE.pending` was false and the text was
     dropped on the floor. No text, no error, no indication it had ever been
     recorded: the exact silent loss the pending map above was written to end,
     reached through a different door - not the request id moving on, but the
     request being retired early by its own duplicate stop.

     'transcribing' means the stop is already with Swift. There is nothing a
     second one can achieve except un-remember the answer. */
  if (VOICE.state === 'transcribing') return;
  bridgeSend({ t: 'voice', phase: 'stop', requestId: VOICE.requestId });
  if (VOICE.state === 'recording' || VOICE.state === 'arming') VOICE.state = 'transcribing';
  renderAll();
}

/* A TERMINAL NOTICE IS NOT PERMANENT.

   `empty` and `error` are the two states VoiceState still draws after a hold
   is over, and correctly: for those two the banner is the ONLY report the user
   ever gets, so it cannot be dropped the way `done` is. But "the only report"
   and "on screen forever" are different requirements, and only the first one
   was ever wanted.

   Nothing cleared them except the next hold. So `nothing heard — the hold
   produced no speech, nothing was inserted` sat in the composer while the user
   typed the sentence by hand underneath it, still claiming nothing had been
   inserted, about text that plainly had been. It also kept its ~40px of the
   composer's height for the rest of the window's life, in the one column this
   project has already measured as over-subscribed.

   So the notice is retired by the next thing the user does in the composer it
   belongs to. That is bounded, needs no timer to arm and no cleanup to forget,
   and it is an acknowledgement in the only sense that matters: you have read it
   and moved on.

   ONLY the two terminal notices. `recording`, `arming` and `transcribing` are
   deliberately not dismissible — an open microphone you can type away is the
   exact failure mode the indicator exists to prevent. Returns true if something
   was actually cleared, so callers that do not otherwise repaint can. */
function voiceAck(targetId) {
  if (VOICE.target !== targetId) return false;
  if (VOICE.state !== 'empty' && VOICE.state !== 'error') return false;
  VOICE.state = 'idle';
  VOICE.error = null;
  return true;
}

/* Text arrives from Swift and is INSERTED, never sent. Dictation that submits
   itself is dictation you cannot correct. */
function voiceInsert(text, target) {
  const t = String(text || '').trim();
  if (!t) return;
  if (target === undefined) target = VOICE.target;
  if (target === '__room__') S.roomDraft = ((S.roomDraft || '') + ' ' + t).trim();
  else if (target) S.draft[target] = ((S.draft[target] || '') + ' ' + t).trim();
}

/* ───────────────────────── the bridge ─────────────────────────
   Swift calls window.__bridgeEmit for every message. Renders are coalesced onto
   an animation frame: a busy session can produce a tool event every few hundred
   milliseconds and a full re-render per event is wasted work. */

let renderQueued = false;
function scheduleRender() {
  if (renderQueued) return;
  renderQueued = true;
  // setTimeout, not requestAnimationFrame: an offscreen WKWebView — which is
  // exactly what the smoke test drives, and what a fully occluded window is —
  // never paints, so rAF never fires and the view silently stops updating.
  setTimeout(() => {
    renderQueued = false;
    buildCategories();
    if (typeof renderAll === 'function') renderAll();
  }, 16);
}

window.__bridgeEmit = function (msg) {
  try {
    switch (msg.type) {
      case 'status':
        LIVE.connection = msg.connection;
        LIVE.detail = msg.detail || '';
        LIVE.readOnly = msg.readOnly !== false;
        if (Array.isArray(msg.scopes)) LIVE.scopes = msg.scopes;
        if (Array.isArray(msg.requestedScopes)) LIVE.requestedScopes = msg.requestedScopes;
        if (msg.sshHost) LIVE.sshHost = msg.sshHost;
        if (typeof msg.tokenPresent === 'boolean') LIVE.tokenPresent = msg.tokenPresent;
        if (msg.serverVersion) LIVE.serverVersion = msg.serverVersion;
        if (typeof S !== 'undefined') S.connection = msg.connection;
        break;

      case 'prefs': {
        // The stored document, from Swift. This is the ONLY thing that sets
        // PREFS.loaded, and savePrefs() refuses to write until it is set — so
        // the boot race cannot round-trip an empty document over real data.
        const p = msg.prefs || {};
        PREFS.version = p.version || 1;
        PREFS.sshHost = p.sshHost || 'atlas';
        PREFS.projects = Array.isArray(p.projects) ? p.projects : [];
        PREFS.toolTabs = Array.isArray(p.toolTabs) ? p.toolTabs : [];
        PREFS.inboxRead = Array.isArray(p.inboxRead) ? p.inboxRead : [];
        PREFS.loaded = true;
        LIVE.prefsPath = msg.path || '';
        if (msg.voice) LIVE.voice = msg.voice;
        if (typeof msg.tokenPresent === 'boolean') LIVE.tokenPresent = msg.tokenPresent;
        break;
      }

      case 'agents':
        LIVE.agents = (msg.agents || []).slice().sort((a, b) => {
          // main first — it is the one every unpinged message goes to — then
          // alphabetical, so the picker does not reorder itself as the gateway
          // reports things in a different order.
          if (a.id === 'main') return -1;
          if (b.id === 'main') return 1;
          return String(a.name || a.id).localeCompare(String(b.name || b.id));
        });
        break;

      case 'groups':
        LIVE.groups = (msg.groups || []).slice()
          .sort((a, b) => (a.position || 0) - (b.position || 0));
        break;

      case 'tasks':
        if (msg.replace) LIVE.tasks.clear();
        for (const t of msg.tasks || []) if (t && t.id) LIVE.tasks.set(t.id, t);
        break;

      case 'questions': {
        // The gateway's own records, whole. `replace` distinguishes the
        // question.list snapshot from a single question.requested arrival.
        if (msg.replace) LIVE.questions.clear();
        for (const r of msg.questions || []) if (r && r.id) LIVE.questions.set(r.id, r);
        break;
      }

      case 'questionResolved':
        // question.resolved carries { id, status } — not a record. Answered
        // somewhere else counts: the row goes, rather than keeping a button
        // whose only possible outcome is QUESTION_ALREADY_TERMINAL.
        LIVE.questions.delete(msg.id);
        if (S.answering && S.answering.questionId === msg.id) S.answering = null;
        break;

      case 'room': {
        ROOM.messages = msg.messages || [];
        ROOM.paused = !!msg.paused;
        ROOM.pauseReason = msg.pauseReason || '';
        ROOM.agents = msg.agents || [];
        ROOM.maxHops = msg.maxHops || ROOM.maxHops;
        ROOM.maxRelays = msg.maxRelays || 0;
        ROOM.relayWindowMin = msg.relayWindowMin || 5;
        ROOM.relaysInWindow = msg.relaysInWindow || 0;
        ROOM.loaded = true;
        break;
      }

      case 'voice': {
        const rid = msg.requestId;
        const terminal = msg.state === 'done' || msg.state === 'idle'
                      || msg.state === 'error' || msg.state === 'empty';

        // TEXT IS DELIVERED FOR EVERY HOLD THAT PRODUCED IT — current or not.
        //
        // This used to be one guard for both concerns, and it lost dictation.
        // Release space and the composer is empty again, so the space bar is
        // armed again immediately, while whisper is still working on the hold
        // you just released. Press it again — the ordinary way anyone dictates
        // two sentences — and VOICE.requestId moves to the new hold. The old
        // hold's `done` then failed `msg.requestId !== VOICE.requestId`, broke
        // out before voiceInsert, and the sentence was gone: no text, no error,
        // no indication it had ever been recorded.
        //
        // The insert is routed by the REQUEST's own remembered target, so a
        // late answer lands in the composer it was spoken at even if the user
        // has since moved to a different lane or to the room.
        if (msg.state === 'done' && rid && rid in VOICE.pending)
          voiceInsert(msg.text, VOICE.pending[rid]);
        if (terminal && rid) delete VOICE.pending[rid];

        // Only the hold that is actually in flight may move the INDICATOR. A
        // late answer from a previous hold must not wipe the new one's
        // recording state — which is what the original guard was for, and is
        // all it should ever have covered.
        if (rid && VOICE.requestId && rid !== VOICE.requestId) break;
        VOICE.state = msg.state || 'idle';
        VOICE.error = msg.error || null;
        if (msg.route) VOICE.route = msg.route;
        if (terminal) VOICE.requestId = null;
        break;
      }

      case 'writeResult': {
        // The gateway answered a chat.send / chat.abort. Under operator.read
        // this is always a refusal, and the refusal is the product: it carries
        // the exact missing scope, which the UI turns into an instruction.
        const w = {
          state: msg.ok ? 'sent' : 'refused',
          method: msg.method,
          sessionKey: msg.sessionKey,
          code: msg.code || null,
          message: msg.message || null,
          missingScope: msg.missingScope || null,
          requiredScopes: msg.requiredScopes || [],
          queued: msg.queued === true,
          at: Date.now(),
        };
        if (typeof onWriteResult === 'function') onWriteResult(msg.requestId, w);
        break;
      }

      case 'sessions': {
        // Full replacement — sessions.list is the canonical index, and a
        // sessions.changed event only tells us the cache is invalid.
        LIVE.rows.clear();
        for (const r of msg.rows) LIVE.rows.set(r.key, r);
        break;
      }

      case 'history': {
        // Full replacement for one session. Backfill, not append: the event
        // stream drops frames, so a reconnect must re-read rather than resume.
        LIVE.history.set(msg.sessionKey, {
          messages: msg.messages || [],
          pendingInputs: (msg.pendingInputs && msg.pendingInputs.items) || msg.pendingInputs || [],
          totalMessages: msg.totalMessages || 0,
        });
        // Everything before this backfill is now in the transcript proper.
        LIVE.toolRuns.delete(msg.sessionKey);
        break;
      }

      case 'tool': {
        const key = msg.sessionKey;
        if (!LIVE.toolRuns.has(key)) LIVE.toolRuns.set(key, new Map());
        const runs = LIVE.toolRuns.get(key);
        const id = msg.toolCallId || ('t' + msg.seq);
        const prev = runs.get(id) || {};
        runs.set(id, {
          name: msg.name || prev.name || 'tool',
          args: msg.args || prev.args || {},
          result: msg.result !== undefined ? msg.result : prev.result,
          status: msg.isError ? 'err' : (prev.status || 'ok'),
          at: prev.at !== undefined ? prev.at : (atOf(msg.ts) ?? 0),
          phase: msg.phase || 'start',
        });
        LIVE.lastEvent.set(key, msg.ts);
        break;
      }

      case 'activity':
        LIVE.lastEvent.set(msg.sessionKey, msg.ts);
        break;

      default:
        return;
    }
  } catch (e) {
    // A malformed frame must not take the window down; say so on screen instead.
    LIVE.connection = 'stale';
    LIVE.detail = 'bridge decode error: ' + (e && e.message);
    if (typeof S !== 'undefined') S.connection = 'stale';
  }
  scheduleRender();
};

/* The native shell announces itself the same way Atlas's does, so the page can
   tell "running inside Bridge" from "opened in a browser for a look". */
window.__BRIDGE_NATIVE__ = window.__BRIDGE_NATIVE__ || null;

/* Nothing is on screen until Swift says something. Paint the waiting state so a
   failed connect is visible rather than a blank window. */
buildCategories();
if (typeof renderAll === 'function') renderAll();

/* ───────────────────────── §W  the write path ─────────────────────────

   Phase A defined these as refusals and never touched the wire, because the
   composer was disabled and could not be reached. Phase B does the opposite,
   and the difference is the point of the feature:

     THE MESSAGE IS ACTUALLY SENT. chat.send goes out over the real socket
     against the real session key. The gateway answers

         FORBIDDEN — missing scope: operator.write

     and THAT is what the screen draws: the specific code, the specific missing
     scope, and the one command that grants it.

   The two failure shapes this is not allowed to have are a silent no-op and a
   fake success, and both were easy to write by accident. A pre-flight check on
   LIVE.readOnly that returned early would be the first; optimistically pushing
   the message into the transcript would be the second. Neither happens: nothing
   is added to any transcript until the gateway says it landed, and every send
   ends in a state that came back from the gateway.

   Requests are correlated by id so two composers cannot claim each other's
   answer, and a send that never answers becomes a timeout rather than a
   spinner that runs forever. */

let writeSeq = 0;

/* A REQUEST ID IS ALSO AN IDEMPOTENCY KEY, so a counter alone is not enough.
   Swift hands this id to the gateway verbatim as chat.send's `idempotencyKey`
   (Gateway.sendMessage: `let idem = requestId.isEmpty ? uuid : requestId`), and
   the gateway makes it the run id verbatim —

     const clientRunId = p.idempotencyKey;                 chat-send-session.ts
     const cached = context.dedupe.get(`chat:${clientRunId}`);
     if (cached) { respond(cached.ok, cached.payload, cached.error,
                           { cached: true }); return false; }

   — so a repeated key is answered `ok: true` from cache and the message is
   never sent. That dedupe key has no sessionKey in it and the map lives as long
   as the gateway process, which runs for days.

   `writeSeq` restarts at 0 on every page load, so the first send after a
   relaunch was ALWAYS `w1`. Measured, two loads of this file's own minting:

     page load 1: w1 w2 v3 w4
     page load 2: w1 w2 v3 w4      COLLIDING IDEMPOTENCY KEYS

   The nonce is drawn once per load and makes the pair unique. The counter stays
   because it is what correlates the answer back to the composer that asked, and
   it stays readable in a log. */
const LOAD_NONCE = (() => {
  try { return crypto.randomUUID().slice(0, 8); } catch (e) {}
  return Math.random().toString(36).slice(2, 10);
})();
const reqId = (prefix) => prefix + (++writeSeq) + '-' + LOAD_NONCE;

function bridgeSend(msg) {
  if (typeof window === 'undefined' || !window.__bridgeSend) return false;
  window.__bridgeSend(msg);
  return true;
}

/* Where a message goes, and under which of the two verbs. This is the
   SEND-vs-QUEUE distinction, and it is a real gateway behaviour rather than a
   label: a session with an active run admits the message to a pending queue and
   picks it up at its next step; a stopped one takes it immediately and starts a
   turn. */
const queueModeFor = (a) => (a && a.status === 'running' ? 'queue' : '');

function startWrite(a, verb, send) {
  const id = reqId('w');
  S.write = { id, agentId: a && a.id, verb, state: 'sending', at: nowS() };
  if (!send(id)) {
    S.write = { id, agentId: a && a.id, verb, state: 'refused', at: nowS(),
      message: 'Bridge is not running inside the native shell, so there is no socket to send on.' };
  }
  renderAll();
  // A request that never answers must not leave the UI claiming to be sending.
  setTimeout(() => {
    if (S.write && S.write.id === id && S.write.state === 'sending') {
      S.write = { ...S.write, state: 'refused', code: 'TIMEOUT',
        message: 'The gateway did not answer within 30s.' };
      renderAll();
    }
  }, 31000);
  return id;
}

/* Swift's answer, correlated back to the composer that asked. */
function onWriteResult(requestId, w) {
  if (!S.write || S.write.id !== requestId) return;
  S.write = { ...S.write, ...w, state: w.state };
  if (w.state === 'sent') {
    // Only now is the draft gone. A send that was refused keeps the text, so a
    // granted scope is one click away from retrying rather than a retype.
    if (S.write.agentId) delete S.draft[S.write.agentId];
    setTimeout(() => { if (S.write && S.write.id === requestId) { S.write = null; renderAll(); } }, 4000);
  }
  renderAll();
}

function submitComposer(a) {
  const text = (S.draft[a.id] || '').trim();
  if (!text) return;
  if (!a.sessionKey) {
    S.write = { id: 'w0', agentId: a.id, verb: 'send', state: 'refused',
      message: 'This tab has no gateway session behind it, so there is nothing to send to.' };
    renderAll();
    return;
  }
  const queueMode = queueModeFor(a);
  startWrite(a, queueMode === 'queue' ? 'queue' : 'send', (id) => bridgeSend({
    t: 'send', requestId: id, sessionKey: a.sessionKey, text, queueMode,
  }));
}

function abortRun(a) {
  if (!a.sessionKey) return;
  startWrite(a, 'abort', (id) => bridgeSend({ t: 'abort', requestId: id, sessionKey: a.sessionKey }));
}

/* Answering a question needs operator.questions, and no question can arrive on
   this connection anyway. The button is still wired: it sends the answer as an
   ordinary steer, which is what it would be, and surfaces the same refusal. */
function answer(a, option) {
  S.draft[a.id] = option && option.label ? option.label : '';
  submitComposer(a);
}

function onComposerKey(ev, a) {
  // Hold space to talk, under the same arming rule as the room composer: only
  // when THIS box is empty. A per-composer draft means the check has to read
  // this agent's draft, not a global one — otherwise typing in one pane arms or
  // disarms dictation in the other.
  if (voiceArmed(ev, S.draft[a.id])) { ev.preventDefault(); voiceStart(a.id); return; }
  if (ev.key === 'Enter' && !ev.shiftKey) { ev.preventDefault(); submitComposer(a); }
}

/* ───────────────────────── boot ─────────────────────────
   One second is the resolution of every duration on screen — "elapsed", "4m
   12s ago", "running 8s…". Without a tick those freeze between gateway events,
   which on an idle session is minutes of a clock that has stopped. */

if (typeof document !== 'undefined' && typeof setInterval === 'function') {
  setInterval(() => { if (typeof renderAll === 'function') renderAll(); }, 1000);
  if (typeof applyHash === 'function') applyHash();
}
