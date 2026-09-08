#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
// BRIDGE RELAY — the always-on, gateway-host half of the room.
//
// The Mac app's Room.swift already routes @pings between agent clones, but only
// while the app is open. This service does the SAME routing on the gateway host,
// so a lane can hand work to a teammate at 3am with nobody's laptop awake — which
// is the whole point of "an agent can ping another even if it is not running".
//
// It is deliberately NOT a second room. It owns ONE thing: performing the
// agent→agent delivery, with the same hop and rate ceilings Room.swift enforces.
// It does not handle Chancellor's own messages (the Mac sends those straight to a
// session), and it does not own the transcript (the Mac reads chat.history per
// session and displays it). Exactly one router may run per turn or a reply is
// delivered twice — see DEPLOY.md: enabling this service goes hand in hand with
// disabling Room.swift's relayPings on the Mac.
//
// WHY A LOOPBACK CLI CLIENT. Probed against the live gateway 2026-09-07: a
// cli/cli connection on 127.0.0.1 carrying the shared gateway.auth.token keeps
// its operator scopes with NO device pairing (shouldPreserveLocalCliSharedAuth-
// Scopes). So this needs no keychain, no approval, no second copy of ~/.ssh — it
// reads the token from the config it runs beside and connects to localhost.
//
// SCOPES. operator.read + operator.write is the whole of it. chat.send both
// delivers and runs a turn, and creates the session if it does not exist, so a
// ping to a never-launched clone brings it into being — verified on the wire.
// sessions.delete / chat.inject need operator.admin and this never calls them.
//
// STATE. state.json (BRIDGE_RELAY_STATE) is the durable membership definition:
//   { "projects": { "<id>": { "name": "...", "access": ["main","frontend-design",…] } } }
// It is hot-reloaded (fs.watch), so adding or removing an agent from a project is
// a file write and takes effect without a restart — the Mac's project editor will
// write it later; today it is seeded from the Mac's prefs.json. Routing state
// (high-water marks, preamble counters, hop depth, pause) is kept in the same
// file under "rooms" and persisted atomically.
// ─────────────────────────────────────────────────────────────────────────────
'use strict';

import { readFileSync, writeFileSync, renameSync, watch, existsSync, mkdirSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { dirname } from 'node:path';

const HOME = process.env.HOME || '/home/user';
const CONFIG = process.env.OPENCLAW_CONFIG || `${HOME}/.openclaw/openclaw.json`;
const STATE = process.env.BRIDGE_RELAY_STATE || `${HOME}/bridge-relay/state.json`;
const GATEWAY = process.env.BRIDGE_RELAY_GATEWAY || 'ws://127.0.0.1:18789/';

// ── constants, ported verbatim from Room.swift so the two routers agree ──────
const MAX_HOPS = 6;              // Chancellor's message is hop 0; each relay adds one
const MAX_RELAYS_PER_WINDOW = 14;
const RELAY_WINDOW_MS = 300_000; // 5 minutes, rolling, counted PER PROJECT
const REANCHOR_EVERY = 20;       // re-send the standing preamble every N deliveries
const BACKFILL_DEBOUNCE_MS = 1500;

const log = (...a) => console.log(new Date().toISOString(), ...a);

// ── pure routing logic (unit-tested by --selftest, no gateway needed) ────────

/** The clone's session key. Project is the LAST component, so the same agent in
 *  two projects is two sessions the gateway keeps apart. */
export function key(agentId, project) { return `agent:${agentId}:bridge:${project}`; }

/** {agent, project} for a Bridge room key, or null for anything else. A v1
 *  three-part key (agent:x:bridge) is deliberately not a room key. */
export function route(k) {
  const p = String(k).split(':');
  if (p.length !== 4 || p[0] !== 'agent' || p[2] !== 'bridge') return null;
  if (!p[1] || !p[3]) return null;
  return { agent: p[1], project: p[3] };
}

/** Every agent a reply addressed, resolved against the caller's allowed set (for
 *  a relay that is the project's access list), in order, deduped, self removed.
 *  EXACT match only: the old prefix match turned every id into a live prefix of
 *  any longer word ("@maintainer" → main), which hands a whole turn to a lane
 *  nobody addressed and starts a chain. A trailing hyphen is trimmed because the
 *  token class swallows it; everything else must match an id exactly. */
export function pings(text, access, excludingSelf) {
  const out = [];
  const re = /@([A-Za-z][A-Za-z0-9-]{1,39})/g;
  let m;
  while ((m = re.exec(String(text))) !== null) {
    const raw = m[1].toLowerCase().replace(/-+$/, '');
    const hit = access.find((a) => a === raw);
    if (!hit || hit === excludingSelf || out.includes(hit)) continue;
    out.push(hit);
  }
  return out;
}

/** The assistant's prose for one message; tool and thinking blocks dropped.
 *  Thinking is private reasoning and is never relayed, the same rule the
 *  transcript applies. */
export function plainText(message) {
  const c = message && message.content;
  if (typeof c === 'string') return c.trim();
  if (!Array.isArray(c)) return '';
  return c.filter((b) => b && b.type === 'text').map((b) => b.text || '').join('\n').trim();
}

/** The standing preamble, ported verbatim from Room.swift.preamble so a lane
 *  hears one convention whichever router spoke to it. Prepended on the first
 *  delivery to a session and every REANCHOR_EVERY after, to survive a compaction
 *  dropping the top of the window without paying for it every turn. */
export function preamble(target, project, projectName, access) {
  const mates = access.filter((a) => a !== target).map((a) => (a === 'main' ? 'main (Thuban)' : a)).join(', ');
  const others = mates || 'no other agents yet';
  const soul = `~/.openclaw/workspace/memory/bridge/${target}/SOUL.md`;
  const mem = `~/.openclaw/workspace/memory/bridge/${target}/MEMORY.md`;
  const shared = `~/.openclaw/workspace/memory/bridge/SHARED.md`;
  return `[Bridge room · project ${projectName}] You are the ${target} agent working in the `
    + `project ${projectName}, in a shared room with Chancellor and: ${others}. Everything said `
    + `here is shown to him in one transcript. To hand work to a teammate, write @<agent-id> `
    + `anywhere in your reply — Bridge relays your message to them and they take the next turn. `
    + `A reply with no @ goes to Chancellor only. Bridge does the routing: do not call session, `
    + `spawn or messaging tools for this. YOU CAN ONLY REACH AGENTS IN ${projectName} — an @ for `
    + `anyone else is not delivered, and there is no way to message another project. `
    + `MEMORY: ${soul} is who you are and ${mem} is what you have learned. BOTH ARE SHARED BY `
    + `EVERY CLONE OF ${target} IN EVERY PROJECT — the same two files you write when you work `
    + `anywhere else, so read them when you start and append what a future you would need, `
    + `wherever it is working. ${shared} is shared by every agent in every project — read it to `
    + `learn what the other projects are doing, and append anything they should know. Create any `
    + `of these if it is not there yet.`;
}

// ── state ────────────────────────────────────────────────────────────────────

function emptyState() { return { projects: {}, rooms: {} }; }

function loadState() {
  if (!existsSync(STATE)) return emptyState();
  try {
    const s = JSON.parse(readFileSync(STATE, 'utf8'));
    s.projects = s.projects || {};
    s.rooms = s.rooms || {};
    return s;
  } catch (e) { log('state load failed, starting empty:', e.message); return emptyState(); }
}

let state = loadState();
const relayTimes = Object.create(null); // projectId -> [epochMs], in memory only

function saveState() {
  try {
    mkdirSync(dirname(STATE), { recursive: true });
    const tmp = `${STATE}.tmp-${process.pid}`;
    writeFileSync(tmp, JSON.stringify(state, null, 2));
    renameSync(tmp, STATE);
  } catch (e) { log('state save failed:', e.message); }
}

const projectIds = () => Object.keys(state.projects || {});
const access = (project) => (state.projects[project] && state.projects[project].access) || [];
const projectName = (project) => (state.projects[project] && state.projects[project].name) || project;
const roomDoc = (project) => (state.rooms[project] = state.rooms[project] || { seen: {}, since: {}, hop: {}, paused: false });

/** Every clone session the relay watches: each project's main plus every agent
 *  it grants access, in every project. Over-watching an allowed-but-unlaunched
 *  agent is harmless — its history is empty until a delivery creates it. */
function watchedKeys() {
  const out = new Set();
  for (const p of projectIds()) {
    out.add(key('main', p));
    for (const a of access(p)) out.add(key(a, p));
  }
  return out;
}

// ── the gateway connection ────────────────────────────────────────────────────

const agentNames = new Map(); // id -> display name, from agents.list
const nameOf = (id) => agentNames.get(id) || id;

let ws = null;
let nextId = 0;
const pending = new Map();
const subscribed = new Set();
const backfillTimers = new Map();

function token() {
  const cfg = JSON.parse(readFileSync(CONFIG, 'utf8'));
  const t = cfg.gateway && cfg.gateway.auth && cfg.gateway.auth.token;
  if (!t) throw new Error('no gateway.auth.token in ' + CONFIG);
  return t;
}

function call(method, params) {
  return new Promise((resolve, reject) => {
    if (!ws || ws.readyState !== 1) return reject(new Error('socket not open'));
    const id = 'r' + (++nextId);
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ type: 'req', id, method, params }));
    setTimeout(() => { if (pending.delete(id)) reject(new Error(`${method} timed out`)); }, 30_000);
  });
}

function connect() {
  let tok;
  try { tok = token(); } catch (e) { log(e.message); setTimeout(connect, 5000); return; }

  ws = new WebSocket(GATEWAY);

  ws.onopen = () => log('socket open', GATEWAY);
  ws.onerror = (e) => log('socket error', e && e.message ? e.message : '');
  ws.onclose = () => { log('socket closed; reconnecting in 5s'); subscribed.clear(); ws = null; setTimeout(connect, 5000); };

  ws.onmessage = async (ev) => {
    let m; try { m = JSON.parse(ev.data); } catch { return; }

    if (m.type === 'event' && m.event === 'connect.challenge') {
      ws.send(JSON.stringify({
        type: 'req', id: 'connect', method: 'connect',
        params: {
          minProtocol: 4, maxProtocol: 4,
          client: { id: 'cli', version: '0.1.0', platform: 'linux', mode: 'cli' },
          role: 'operator', scopes: ['operator.read', 'operator.write'],
          caps: ['session-scoped-events'], commands: [], permissions: {},
          auth: { token: tok }, userAgent: 'bridge-relay/1.0',
        },
      }));
      return;
    }

    if (m.type === 'res' && m.id === 'connect') {
      if (!m.ok) { log('connect rejected:', m.error && m.error.message); ws.close(); return; }
      const scopes = (m.payload.auth && m.payload.auth.scopes) || [];
      log('hello-ok scopes=', JSON.stringify(scopes));
      if (!scopes.includes('operator.write')) { log('FATAL: no operator.write; relay cannot deliver'); ws.close(); return; }
      await onReady();
      return;
    }

    if (m.type === 'res' && pending.has(m.id)) {
      const { resolve, reject } = pending.get(m.id); pending.delete(m.id);
      m.ok ? resolve(m.payload) : reject(new Error(`${m.error && m.error.code}: ${m.error && m.error.message}`));
      return;
    }

    if (m.type === 'event') {
      const sk = m.payload && (m.payload.sessionKey || m.payload.key);
      if (sk && watchedKeys().has(sk)) scheduleBackfill(sk);
    }
  };
}

async function onReady() {
  // Cache display names.
  try {
    const a = await call('agents.list', {});
    for (const ag of (a.agents || [])) agentNames.set(ag.id, ag.name || ag.id);
  } catch (e) { log('agents.list failed (names will be ids):', e.message); }

  // Global changed-feed, so a new session or a change we did not subscribe to
  // still pokes us.
  try { await call('sessions.subscribe', { limit: 200, ownerFirst: true }); } catch (e) { log('sessions.subscribe failed:', e.message); }

  // SEED FIRST, then subscribe. Reading each watched session's history once with
  // no high-water mark seeds the mark and emits nothing (observe's first-sight
  // rule), so launching the relay against sessions that already hold @pings does
  // not pour history back out as a relay storm.
  for (const k of watchedKeys()) { await seed(k); await subscribeKey(k); }
  log('ready — watching', watchedKeys().size, 'sessions across', projectIds().length, 'projects');
}

async function subscribeKey(k) {
  if (subscribed.has(k)) return;
  try { await call('sessions.messages.subscribe', { key: k }); subscribed.add(k); }
  catch (e) { log('subscribe failed for', k, e.message); }
}

async function seed(k) {
  const r = route(k); if (!r) return;
  const doc = roomDoc(r.project);
  if (doc.seen[k] !== undefined) return; // already known
  try {
    const h = await call('chat.history', { sessionKey: k, limit: 60 });
    let maxSeq = 0;
    for (const msg of (h.messages || [])) {
      const seq = (msg.__openclaw && msg.__openclaw.seq) || 0;
      if (seq > maxSeq) maxSeq = seq;
    }
    doc.seen[k] = maxSeq;
    saveState();
  } catch (e) { log('seed failed for', k, e.message); }
}

function scheduleBackfill(k) {
  if (backfillTimers.has(k)) return;
  backfillTimers.set(k, setTimeout(() => { backfillTimers.delete(k); backfill(k).catch((e) => log('backfill', k, e.message)); }, BACKFILL_DEBOUNCE_MS));
}

async function backfill(k) {
  const h = await call('chat.history', { sessionKey: k, limit: 60 });
  observe(k, h.messages || []);
}

// ── the router ─────────────────────────────────────────────────────────────

function observe(k, messages) {
  const r = route(k); if (!r) return;
  const { agent: lane, project } = r;
  if (!state.projects[project]) return; // a session whose project was removed is not ours
  const doc = roomDoc(project);
  const high = doc.seen[k];

  let maxSeq = high || 0;
  const fresh = [];
  for (const msg of messages) {
    if (msg.role !== 'assistant') continue;
    const seq = (msg.__openclaw && msg.__openclaw.seq) || 0;
    if (seq > maxSeq) maxSeq = seq;
    if (high === undefined || seq <= high) continue;
    const text = plainText(msg);
    if (text) fresh.push(text);
  }

  // First sight: seed the mark, emit nothing (see onReady()).
  if (high === undefined) { doc.seen[k] = maxSeq; saveState(); return; }
  if (!fresh.length) return;
  doc.seen[k] = maxSeq;

  const hop = doc.hop[k] || 0;
  for (const text of fresh) relayPings(text, lane, project, hop);
  saveState();
}

function relayPings(text, lane, project, hop) {
  const targets = pings(text, access(project), lane);
  if (!targets.length) return;
  const doc = roomDoc(project);
  const nm = (t) => targets.map((x) => '@' + x).join(', ');

  if (doc.paused) { log(`[${project}] ${lane} pinged ${nm()} but room is paused`); return; }

  if (hop + 1 > MAX_HOPS) {
    log(`[${project}] ${lane} pinged ${nm()} at hop ${hop + 1}, past the ${MAX_HOPS}-hop ceiling — chain stops`);
    return;
  }

  const cutoff = Date.now() - RELAY_WINDOW_MS;
  const times = (relayTimes[project] || []).filter((t) => t >= cutoff);
  if (times.length + targets.length > MAX_RELAYS_PER_WINDOW) {
    relayTimes[project] = times;
    doc.paused = true;
    doc.pauseReason = `${MAX_RELAYS_PER_WINDOW} relays in ${RELAY_WINDOW_MS / 60000} minutes`;
    saveState();
    log(`[${project}] RELAY PAUSED: ${MAX_RELAYS_PER_WINDOW} hand-offs in ${RELAY_WINDOW_MS / 60000} min; ${lane}'s ping to ${nm()} not sent`);
    return;
  }

  for (const t of targets) {
    times.push(Date.now());
    relayTimes[project] = times;
    deliver(t, project, lane, text, hop + 1);
  }
}

async function deliver(target, project, sender, text, hop) {
  const body = String(text).trim();
  if (!body) return;
  // Isolation at the only door: a target outside this project's access list is
  // unreachable by construction, not by every caller remembering to check.
  if (!access(project).includes(target)) {
    log(`[${project}] refused delivery to @${target}: not in access list`);
    return;
  }
  const k = key(target, project);
  const doc = roomDoc(project);
  const n = doc.since[k] === undefined ? REANCHOR_EVERY : doc.since[k];
  const anchor = n >= REANCHOR_EVERY;
  const who = sender === 'chancellor' ? 'Chancellor' : `${nameOf(sender)} (@${sender})`;
  const header = `[room · ${projectName(project)}] ${who} → @${target}`;
  const wire = (anchor ? preamble(target, project, projectName(project), access(project)) + '\n\n' : '') + header + '\n' + body;

  doc.since[k] = anchor ? 1 : n + 1;
  doc.hop[k] = hop;
  saveState();

  try {
    await call('chat.send', { sessionKey: k, message: wire, idempotencyKey: `relay-${randomUUID()}` });
    await subscribeKey(k); // a freshly created session must be watched for its reply
    log(`[${project}] relayed ${sender} → @${target} at hop ${hop}`);
  } catch (e) {
    log(`[${project}] delivery to @${target} FAILED — ${e.message}`);
  }
}

// ── hot-reload membership ─────────────────────────────────────────────────────

let reloadTimer = null;
function watchState() {
  try {
    watch(dirname(STATE), (_e, f) => {
      if (f && !f.startsWith('state.json')) return;
      if (reloadTimer) return;
      reloadTimer = setTimeout(async () => {
        reloadTimer = null;
        const before = watchedKeys();
        state = loadState();
        const after = watchedKeys();
        for (const k of after) if (!before.has(k) && ws && ws.readyState === 1) { await seed(k); await subscribeKey(k); }
        log('state reloaded —', projectIds().length, 'projects,', after.size, 'watched sessions');
      }, 500);
    });
  } catch (e) { log('cannot watch state dir:', e.message); }
}

// ── selftest: pure logic, no gateway ───────────────────────────────────────────

function selftest() {
  let pass = 0, fail = 0;
  const eq = (name, got, want) => {
    const ok = JSON.stringify(got) === JSON.stringify(want);
    ok ? pass++ : fail++;
    console.log((ok ? 'PASS ' : 'FAIL ') + name + (ok ? '' : `  got=${JSON.stringify(got)} want=${JSON.stringify(want)}`));
  };
  const ACC = ['main', 'frontend-design', 'backend-design', 'full-stack'];

  eq('key', key('frontend-design', 'atlas'), 'agent:frontend-design:bridge:atlas');
  eq('route 4-part', route('agent:frontend-design:bridge:atlas'), { agent: 'frontend-design', project: 'atlas' });
  eq('route v1 3-part is not a room key', route('agent:main:bridge'), null);
  eq('route junk', route('nope'), null);

  eq('ping exact', pings('hand to @backend-design please', ACC, 'frontend-design'), ['backend-design']);
  eq('ping self excluded', pings('I @frontend-design will do it', ACC, 'frontend-design'), []);
  eq('ping two, in order, deduped', pings('@full-stack then @backend-design and @full-stack', ACC, 'main'), ['full-stack', 'backend-design']);
  eq('no prefix match: @maintainer is not main', pings('ping @maintainer', ACC, 'x'), []);
  eq('trailing punctuation ok', pings('@main. @backend-design,', ACC, 'x'), ['main', 'backend-design']);
  eq('trailing hyphen trimmed', pings('@full-stack- go', ACC, 'x'), ['full-stack']);
  eq('out-of-project name ignored', pings('@coursework help', ACC, 'x'), []);

  eq('plainText string', plainText({ content: '  hi  ' }), 'hi');
  eq('plainText blocks drop tool+thinking', plainText({ content: [{ type: 'thinking', text: 'no' }, { type: 'text', text: 'yes' }, { type: 'tool_use' }] }), 'yes');

  eq('preamble names teammates and project', /project Atlas/.test(preamble('frontend-design', 'atlas', 'Atlas', ACC)) && /main \(Thuban\), backend-design, full-stack/.test(preamble('frontend-design', 'atlas', 'Atlas', ACC)), true);
  eq('preamble scopes reach to project', /YOU CAN ONLY REACH AGENTS IN Atlas/.test(preamble('frontend-design', 'atlas', 'Atlas', ACC)), true);

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
}

// ── main ───────────────────────────────────────────────────────────────────
if (process.argv.includes('--selftest')) { selftest(); }
else { log('bridge relay starting'); watchState(); connect(); }
