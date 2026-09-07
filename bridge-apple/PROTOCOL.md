# Bridge ↔ OpenClaw Gateway — the wire contract

Everything below was established against the live Gateway (`2026.8.1`,
protocol 4) on 2026-09-06, from `openclaw/docs/gateway/{protocol,clients}.md`
plus a probe client run against the real socket. Where the docs and the running
gateway disagreed, the running gateway wins and the difference is called out.

Phase B should not have to rediscover any of this.

---

## 1. Transport

The Gateway binds `127.0.0.1:18789` on the Linux host **and nowhere else**:

```
LISTEN 0  511  127.0.0.1:18789  0.0.0.0:*
LISTEN 0  511      [::1]:18789     [::]:*
```

The Mac cannot reach that port directly and **must not be given a way to**.
`gateway.controlUi.allowedOrigins` is `["https://claw.myatlasapp.net"]`; the
correct answer is not to widen it.

Bridge opens an SSH local forward instead (`Tunnel.swift`):

```
/usr/bin/ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  -L <127.0.0.1:18790-18799>:127.0.0.1:18789 atlas
```

`atlas` resolves from the user's own `~/.ssh/config`, which tries `atlas.local`
over the LAN and falls back to a cloudflared tunnel off it. Bridge keeps no
second copy of that configuration.

Two consequences worth knowing:

* The app **cannot be sandboxed**. App Sandbox forbids both spawning `ssh` and
  reading `~/.ssh/config`. `Bridge.entitlements` sets `app-sandbox` false and
  says why.
* A GUI app inherits a bare `PATH`, and the `atlas` host's `ProxyCommand` shells
  out to `nc` and to `cloudflared` under Homebrew. `Tunnel.swift` appends
  `/opt/homebrew/bin:/usr/local/bin`. Without it the forward works on the LAN
  and fails off it — the worst possible time to find out.

`BRIDGE_GATEWAY_PORT=<n>` skips the child process entirely and connects to an
already-forwarded local port.

The WebSocket endpoint is the **root path**: `ws://127.0.0.1:<local>/`.
`/ws` and `/gateway` also upgrade, but `/` is what the reference client uses.

### Why the socket is native

A page served from Bridge's own loopback origin would send an `Origin` header
and be refused by `allowedOrigins`. A native client sends no `Origin`, is
classified by `isNativeAppUiClient` (client id `openclaw-macos`, mode `ui`), and
is not subject to the browser-origin check at all. That is the entire reason
`Gateway.swift` exists in Swift rather than in `live.js`.

---

## 2. Handshake

Frames are JSON text:

| kind     | shape                                                |
| -------- | ---------------------------------------------------- |
| request  | `{type:"req", id, method, params}`                   |
| response | `{type:"res", id, ok, payload \| error}`             |
| event    | `{type:"event", event, payload, seq?, stateVersion?}` |

The Gateway speaks first:

```json
{"type":"event","event":"connect.challenge","payload":{"nonce":"…","ts":1788737000000}}
```

The client's **first frame must be `connect`**. Pre-auth frames are capped at
64 KiB.

### 2.1 `client.id` and `client.mode` are closed enums

This is the first thing that will bite. Sending anything else fails with:

```
INVALID_REQUEST: invalid connect params:
  at /client/id: must be equal to one of the allowed values;
  at /client/mode: must be equal to one of the allowed values
```

Valid ids (`packages/gateway-protocol/src/client-info.ts`):
`webchat-ui`, `openclaw-control-ui`, `openclaw-browser-copilot`, `openclaw-tui`,
`webchat`, `cli`, `gateway-client`, **`openclaw-macos`**, `openclaw-linux`,
`openclaw-ios`, `openclaw-watchos`, `openclaw-android`, `node-host`,
`openclaw-worker`, `test`, `fingerprint`, `openclaw-probe`.

Valid modes: `webchat`, `cli`, **`ui`**, `backend`, `node`, `worker`, `probe`,
`test`.

Bridge uses `openclaw-macos` + `ui`, which together satisfy
`isNativeAppUiClient`.

### 2.2 A bare token authenticates but is granted NO scopes

This is the trap, and the docs do not state it plainly. A `connect` carrying
`auth.token` (the shared `gateway.auth.token`) and **no device block** succeeds:

```json
"auth": { "role": "operator", "scopes": [] }
```

`role: "operator"`, `hello-ok`, no error — and then every single read fails:

```json
{"code":"FORBIDDEN","message":"missing scope: operator.read",
 "details":{"code":"MISSING_SCOPE","missingScope":"operator.read",
            "requiredScopes":["operator.read"]}}
```

Scopes are granted to a **paired device**, not to a shared secret. Only a
`cli`+`cli` client on a loopback connection keeps shared-auth scopes without one
(`shouldPreserveLocalCliSharedAuthScopes`).

`Gateway.onHello` treats "connected with an empty scope set" as an error state
with its own message, because authenticated-but-unscoped otherwise looks exactly
like success until twenty MISSING_SCOPE lines scroll past.

### 2.3 Device identity

Ed25519. Persisted in the Keychain (`Keychain.Item.deviceKey`), created once.

* `device.id` = SHA-256 of the **raw 32-byte public key**, lowercase hex
* `device.publicKey` = raw 32 bytes, **base64url**, unpadded
* `device.signedAt` = the challenge's `ts` (not local time)
* `device.nonce` = the challenge's `nonce`
* `device.signature` = base64url Ed25519 over the **v3 payload**, which is these
  eleven fields joined by `|`:

```
v3 | deviceId | clientId | clientMode | role | scopes.join(",") |
   signedAtMs | token | nonce | platform | deviceFamily
```

`platform` and `deviceFamily` are lowercased (`normalizeDeviceMetadataForAuth`);
an absent `deviceFamily` is the empty string, and the field is still present.
Bridge sends `…|macos|`. A v2 payload (the same list without `v3`, `platform`
and `deviceFamily`) is still accepted as a fallback by the Gateway.

### 2.4 Pairing

On a loopback + shared-secret connection the Gateway performs **silent local
pairing** (`shouldAllowSilentLocalPairing`, reason `scope-upgrade`), so the
first connect is approved automatically and `hello-ok.auth.deviceToken` comes
back immediately. Because Bridge's socket terminates on the Gateway host's own
loopback via the SSH forward, this is the path it takes — no manual approval was
needed.

Off that path the Gateway answers `PAIRING_REQUIRED`, and the device must be
approved once on the Gateway host:

```
openclaw devices list
openclaw devices approve <requestId>
```

`Gateway.swift` names this case explicitly rather than reporting a generic
failure.

### 2.5 Capabilities

`connect.params.caps` grants nothing but gates delivery:

> **`tool-events` gates live tool-execution streaming.** The Gateway registers
> only connections that advertise this capability as recipients for a run's
> structured tool events. Without it, the connection receives no live tool
> events **and the handshake does not report an error.**

Bridge advertises `["tool-events", "session-scoped-events"]`. Drop `tool-events`
and the transcript silently stops showing tool calls with nothing in any log.

Full registry: `agent-kind`, `approvals`, `exec-approvals`, `inline-widgets`,
`run-tool-bindings`, `session-scoped-events`, `plugin-approvals`,
`task-suggestions`, `terminal-offset-seq`, `tool-events`, `ui-commands`,
`usage-refreshing`.

### 2.6 `hello-ok`, observed

```
protocol: 4
server:   { version: "2026.8.1", buildId, bootId, connId }
auth:     { role: "operator", scopes: ["operator.read"], deviceToken: "<43 chars>" }
policy:   { maxPayload: 26214400, maxBufferedBytes: 52428800,
            tickIntervalMs: 30000, attachments: {…},
            allowedSessionVisibilities: ["shared","read-only","suggest","draft"] }
features: { methods: 371 of them, events: 54 of them }
snapshot: { presence, health, stateVersion, uptimeMs, appliedConfigHash,
            sessionDefaults, updateAvailable }
```

`hello-ok.auth.deviceToken` is the reusable credential for the same device+role.
Bridge does not currently persist it — the shared token plus the device key
reconnects fine — and Phase B should only start persisting it if it also handles
rotation and revocation.

---

## 3. Scopes

| Scope                | What Bridge would need it for                            |
| -------------------- | -------------------------------------------------------- |
| `operator.read`      | **Phase A.** `sessions.list/subscribe`, `sessions.messages.subscribe`, `chat.history`, all read events |
| `operator.write`     | Phase B. `chat.send`, `sessions.send`, `sessions.abort`, `sessions.patch` |
| `operator.approvals` | Phase B, if Bridge is to show and resolve approvals. Also required (with `operator.admin`, or on a paired device) for `sessions.messages.subscribe({includeApprovals:true})` |
| `operator.questions` | Phase B, if Bridge answers interactive questions |
| `operator.admin`     | Config, updates, reserved namespaces. Bridge should not ask for it |

`operator.write` satisfies `operator.read`. `operator.admin` satisfies
everything.

Phase A requests **`operator.read` only**, and the composer in the UI is
disabled with that stated on screen rather than failing at submit time. Note
that raising the requested scope set creates a **new pending pairing request** —
a scope upgrade is not free, and token rotation cannot widen an approved
pairing.

---

## 4. Methods Bridge uses

### `sessions.subscribe`

```json
{"limit": 60, "ownerFirst": true}
```

Registers the subscription **before** projecting the list, so one call is both
the subscribe and the snapshot: the response is `{subscribed: true, list}` where
`list` is a normal `SessionsListResult`. Calling with `{}` returns only
`{subscribed: true}` and reads no snapshot.

`list.sessions` is the row array; `list` also carries `totalCount`,
`limitApplied`, `nextOffset`, `hasMore`, `owners`, `defaults`.

The subscription ends when the client disconnects. **A reconnect requires a new
subscription and a new snapshot** — there is no resume.

### `chat.history`

```json
{"sessionKey": "<key>", "limit": 60}
```

Returns `{sessionKey, sessionId, messages, pendingInputs, deltaCursor, hasMore,
totalMessages, defaults, sessionInfo, thinkingLevel, inFlightRun}`.

Display-normalized for UI clients: inline directive tags stripped, plain-text
tool-call XML stripped, pure `NO_REPLY` rows omitted, oversized rows replaced
with placeholders.

`pendingInputs` is `{items: [...], total: n}` — **not** a bare array.

### `sessions.messages.subscribe`

```json
{"key": "<key>"}        →  {"subscribed": true, "key": "<key>"}
```

Note `key`, not `sessionKey`. Per-session; not sticky across reconnects.

### `sessions.list`

Same params as `sessions.subscribe`. Used only when a `sessions.changed` event
arrives without a row.

---

## 5. Message shapes

### 5.1 A `chat.history` message

`role: "user"` with a plain string:

```json
{"role":"user","content":"…","timestamp":1788735000000,
 "idempotencyKey":"…","__openclaw":{"id":"…","seq":6,"transcriptPosition":{…}}}
```

`role: "assistant"` with content **blocks**:

```json
{"role":"assistant",
 "content":[{"type":"text","text":"…"}],
 "stopReason":"stop","api":"cli","provider":"claude-cli","model":"claude-opus-5",
 "usage":{"input":2,"output":2,"totalTokens":66901,"cacheRead":66056,
          "cacheWrite":841,"cost":{…}},
 "timestamp":1788735545790,"__openclaw":{…}}
```

Tool calls are blocks in the same array:

```json
{"type":"tool_use","id":"toolu_…","name":"Bash","caller":{…},"arguments":{…}}
```

with results as `{"type":"tool_result","tool_use_id":"toolu_…","content":…,
"is_error":false}`. `live.js` pairs them by id; a `tool_use` whose result never
arrives is rendered as "no result recorded" rather than as a success.

`thinking` blocks are dropped by `live.js` on purpose — private reasoning is not
session state, and this is a screen other people can see.

### 5.2 `session.tool`

```json
{"runId":"…","stream":"tool",
 "data":{"phase":"start","name":"Bash","toolCallId":"toolu_…","args":{…}},
 "sessionKey":"…","agentId":"frontend-design","seq":175,"ts":1788737845613,
 "spawnedBy":"agent:main:main","isHeartbeat":false,
 "session":{ …the entire session row, again… }}
```

`phase` is `start` then `end`. **Every one of these carries a full copy of the
session row** — roughly 4 KB per event. `Gateway.trimRow` / `trimArgs` exist
because forwarding that verbatim across the JS bridge is most of the CPU the app
would otherwise spend.

A `start` with no matching `end` is what the UI draws as the live operation.

### 5.3 `session.message`

```json
{"sessionKey":"…","senderIsOwner":true,"agentId":"main",
 "message":{ …the same shape as a chat.history message… },
 "messageId":"…","messageSeq":389,
 "session":{ …full row… }}
```

Bridge treats this as **"something changed"** and re-reads `chat.history` rather
than appending the delta. Reconciling one event against a page fetched under a
different normalization is how transcripts go subtly wrong, and the stream is
lossy anyway (§6).

### 5.4 `session.operation` — not observed

Documented, and advertised in `hello-ok.features.events`, but never fired in a
20-minute window across 21 subscribed sessions with several active runs. Bridge
derives the in-flight operation from unmatched `session.tool` starts instead.
Phase B should not assume it will arrive.

### 5.5 `sessions.changed`

```json
{"sessionKey":"…","agentId":"main","phase":"message","ts":…,
 "messageId":"…","messageSeq":387,"session":{ …full row… }}
```

Usually carries the whole updated row — take it and patch. When it does **not**,
it is a delete notification or a rowless global invalidation and the cached
index is untrustworthy: re-read `sessions.list`.

A key-only delete event must never be treated as "remove this key" — a
replacement generation can share the key.

### 5.6 Everything else on the wire

Observed over 15 minutes with all 21 sessions subscribed:

| event                   | count | note                                          |
| ----------------------- | ----: | --------------------------------------------- |
| `heartbeat`             |  1056 | every few seconds; ignore                     |
| `agent`                 |   384 | `stream: "thinking"` etc.; useful only as an activity ping |
| `task`                  |   107 | subagent task lifecycle — Phase B's inbox      |
| `session.tool`          |    66 |                                               |
| `health`                |    44 | full gateway health snapshot, large            |
| `chat`                  |    34 |                                               |
| `tick`                  |    30 | keepalive, `policy.tickIntervalMs` = 30 s      |
| `sessions.changed`      |    27 |                                               |
| `session.message`       |     7 |                                               |
| `presence` / `cron` / `chat.metadata.changed` / `skills.changed` | few | |

`session.approval`, `session.observer` and `question.*` did not fire in that
window; `session.observer` needs the observer digest to be produced, and the
approval families need the `includeApprovals` opt-in Phase A does not hold the
scope for.

---

## 6. The stream is lossy. Reconcile, do not accumulate.

From `docs/gateway/protocol.md`:

> Operator event frames are best effort and **drop for slow subscribers** rather
> than closing their socket.

So Bridge never treats events as an append-only log:

* `sessions.list` / `sessions.subscribe` is the **canonical index**. Rows are
  replaced wholesale, or patched from the row the event carried.
* `chat.history` is the **canonical transcript**. It is re-read (debounced to
  once per session per 3 s) whenever an event suggests the transcript moved.
  A `history` message on the JS bridge **replaces** that session's transcript
  and clears the live tool-event tail that was standing in for it.
* Live `session.tool` events only decorate the tail *between* backfills.
* A reconnect **re-subscribes and re-fetches**. It does not resume.

`chat.history` also supports an opaque `deltaCursor` for catch-up
(`{kind:"delta", messages, deltaCursor}` on success, `{kind:"reset"}` when the
cursor is stale, crossed a compaction, or is more than 200 events / 1 MB
behind). Bridge does not use it yet: at `limit: 60` a full tail is cheap and has
one fewer failure mode. It is the obvious optimisation if Phase B raises the
history limit.

---

## 7. The JS bridge

Swift → page only, via `evaluateJavaScript("window.__bridgeEmit(JSON.parse(…))")`.
The page's only inbound message is `{t:"ready"}`. **No method returns the token,
and no method opens a socket.**

| `type`     | fields                                                      |
| ---------- | ----------------------------------------------------------- |
| `status`   | `connection` (`connecting`/`live`/`reconnecting`/`stale`/`error`), `detail`, `readOnly`, `serverVersion` |
| `sessions` | `rows[]` — trimmed session rows, full replacement            |
| `history`  | `sessionKey`, `messages[]`, `pendingInputs[]`, `totalMessages` — full replacement for one session |
| `tool`     | `sessionKey`, `phase`, `name`, `toolCallId`, `args`, `result?`, `isError?`, `seq`, `ts` |
| `activity` | `sessionKey`, `ts` — "this session is alive", nothing more   |

`live.js` maps these onto the shapes `data.js` documents. That file is the
contract between the two halves; read it before changing either.

---

## 8. The token

`gateway.auth.token` from `~/.openclaw/openclaw.json` on the Gateway host.

* Stored **only** in the macOS Keychain, service `net.myatlasapp.bridge`,
  account `gatewayToken`, accessible after first unlock.
* Entered once, either in Settings (⌘,) or non-interactively:

  ```bash
  ssh atlas 'node -e "process.stdout.write(require(process.env.HOME+\"/.openclaw/openclaw.json\").gateway.auth.token)"' \
    | Bridge.app/Contents/MacOS/Bridge --set-token
  ```

  It is piped, so it never lands in a shell history, an argv, or a log.
* **Bridge must write the item itself.** An item created by `security
  add-generic-password` in a terminal has that process in its ACL and the first
  read from Bridge raises a keychain prompt; an item Bridge created is read
  silently.
* It is never logged, never written to a file, and never crosses into the web
  view. `Gateway.swift` is the only file that reads it.

---

## 9. Phase B, as built

Phase A guessed at some of this. What follows was measured against the live
gateway on 2026-09-06 with a probe client before any of it was written, and the
measurements are the point — three of the five things Phase A expected to need a
wider scope turned out to answer under `operator.read`, and one thing it hoped
for turned out to be impossible.

### 9.1 What answers under `operator.read`

| method | answers? | Bridge uses it for |
| ------ | -------- | ------------------ |
| `agents.list` | **yes** | the Customize roster picker — the real agent list |
| `sessions.groups.list` | **yes** | Projects, including groups with no live session |
| `tasks.list` | **yes** | the inbox's completion feed |
| `question.list` | no — `operator.questions` | — |
| `approval.history` | no — `operator.approvals` | — |
| `chat.send` / `sessions.send` / `chat.abort` | no — `operator.write` | the refusal state |
| `sessions.groups.put` | no — `operator.write` | why a project is local-only |
| `agents.summary`, `config.agents.list`, `agent.list` | no — `operator.admin` | — |

`agents.list` returns `{defaultId, agents:[{id, name, identity, workspace,
model, …}]}`. Nine agents on this gateway: `main` (Thuban), `backend-design`,
`coursework`, `cybersecurity`, `frontend-design`, `full-stack`, `linux-expert`,
`macos-expert`, `windows-expert`.

`sessions.groups.list` returns `{groups:[{name, position}], sectionOrder}` —
name and position only, no session keys. The membership is the `category` field
on each session row, which is what Phase A already grouped by.

### 9.2 `tasks.list` is the inbox, and it is a delegation ledger

This is the single most useful finding for Phase B. `tasks.list` answers under
`operator.read` and returns one row **per delegated task**, not per agent:

```json
{"id":"f16ee339-…","taskId":"f16ee339-…","kind":"subagent","runtime":"subagent",
 "status":"running","title":"Bridge — Phase B: inbox, projects, roster, …",
 "agentId":"frontend-design",
 "sessionKey":"agent:main:main",
 "childSessionKey":"agent:frontend-design:dashboard:5d8f3154-…",
 "ownerKey":"agent:main:main","runId":"…","flowId":"…",
 "createdAt":…,"updatedAt":…,"startedAt":…,
 "toolUseCount":18,"lastToolName":"Bash","lastActivity":"…the agent's last line…"}
```

`limit` is accepted; 100 rows came back unfiltered. Two things about the corpus
matter, and both shape the inbox:

* **`kind` separates work from noise.** `subagent` rows are delegations.
  `automation_run` rows are cron firings — in the live corpus roughly 60 of 100
  rows are `heartbeat-main`. An inbox that lists those is an inbox nobody opens.
  Bridge excludes them and prints the count it excluded.
* **A task tree is several rows.** When a lane spawns its own child, that child
  is another row whose `ownerKey` is the parent's `childSessionKey`. So "one
  entry per whole task, not per agent" is computable: a row is a **root** when
  its `ownerKey` is not any other row's `childSessionKey`. Bridge shows roots
  with a terminal status, folds the rest into the parent's entry, and says how
  many it folded.

`lastActivity` is the agent's own closing text and is what the completion
summary prints. `endedAt` is not always present; `updatedAt` is the fallback.

Live movement arrives as the `task` event, whose payload is the same shape, so
it patches straight into the same index.

### 9.3 Questions cannot arrive, and this was verified twice over

> **Superseded by §11.4.** Both blocks named below were real in Phase B and
> both are gone: Bridge now holds `operator.questions`, and `question.request`
> turns out to be a working sender. A question raised on this gateway now
> reaches the inbox and is answered from it. Kept because the reasoning was
> right at the time and the measurements are still the record of what was
> true under `operator.read`.

Bridge renders a question entry type and `Gateway.swift` handles
`question.requested` / `question.resolved`. Neither can fire here, for two
independent reasons:

1. **Scope.** `question.list` on an `operator.read` connection answers
   `FORBIDDEN — missing scope: operator.questions`. The event family needs the
   same grant.
2. **No sender.** Even with the scope, a subagent has no working path to raise
   a question. A visible-spawn child can call `ask_user`, but the prompt is
   delivered to the session's bound channel; a subagent has no channel binding,
   so it renders only in that child's own Control UI pane and returns
   `{"status":"no_answer"}` after the full timeout. It reaches nobody.

So the receiver is built and the sender does not exist. The UI says exactly
that rather than showing an empty box, and nothing synthesises an arrival.

### 9.4 Steering: the exact refusal, and the exact grant

> **Superseded by §11.1 and §11.2.** The scope was raised and granted, and
> the refusal path stays in the code because it is still the right rendering
> of any FORBIDDEN. Read §11.2 before trusting this section: the send it
> describes was ALSO missing a required parameter, which the scope refusal
> hid completely.

`chat.send` is implemented and **actually sent**. Bridge continues to request
`operator.read` only — deliberately, because widening the requested scope set
creates a *new* pending pairing request (§3) and would break the working
connection this app runs on. The gateway answers, verbatim:

```json
{"code":"FORBIDDEN","message":"missing scope: operator.write",
 "details":{"code":"MISSING_SCOPE","missingScope":"operator.write",
            "requiredScopes":["operator.write"]}}
```

`sessions.send` and `chat.abort` answer identically.

**The scope required is `operator.write`.** To grant it, on the gateway host:

```bash
openclaw devices list                                   # find Bridge's requestId
openclaw devices approve <requestId> --scopes operator.write
```

Then set `Gateway.requestedScopes = ["operator.write"]` in `Gateway.swift` and
reconnect. Note the ordering trap: raising `requestedScopes` first produces a
**new** pairing request rather than widening the existing approval, so the
approve step is against whatever `devices list` shows *after* the reconnect.
`operator.write` satisfies `operator.read`, so nothing else changes.

The refusal is surfaced in the composer with the code, the missing scope and the
command above. It is never a silent no-op and never a fake success: the message
stays in the box, nothing is queued, and nothing is written to the transcript.

### 9.5 Lane-to-lane routing is off

> **Still true, and now deliberate — see §11.5.** Neither key is set, and
> Phase C does not set them. Bridge relays lane-to-lane ITSELF, as an
> operator client holding `operator.write`, which needs no gateway config
> change and grants no lane read access to another lane's transcript.

`tools.agentToAgent` and `tools.sessions` are both **absent** from
`~/.openclaw/openclaw.json` on the gateway host — checked directly, not inferred.
So the star topology the ping bubbles depict (lanes answer main; lanes do not
address each other) is what the gateway actually permits, not merely a
convention. Bridge labels this on screen and changes no gateway config.

### 9.6 Projects are local, and why

Creating a gateway session group, or filing a session into one, is
`sessions.groups.put` / a session `category` write — both `operator.write`. So a
project created in Bridge is a **local** grouping that rosters agents and
persists; it cannot yet move live gateway sessions into itself. Gateway groups
that already exist are read and shown alongside. The UI states the difference.

---

## 9A. Preferences

`~/Library/Application Support/Bridge/prefs.json`, written by `Prefs.swift`.

A JSON document rather than `UserDefaults`: the shape is nested (projects and
tool tabs each hold a roster), the file is inspectable with `cat` and copyable
between machines, and it avoids `cfprefsd`'s write cache, where a save can lose
a race with a process that exits. `UserDefaults` keeps exactly one thing, the
WKWebView page zoom, which was already there and is a single scalar.

Writes are atomic — temp file, then `replaceItemAt` — so a crash mid-save leaves
the previous document rather than half of the new one.

```json
{ "version": 1, "sshHost": "atlas",
  "projects": [{ "id": "g-bridge", "name": "Bridge",
                 "roster": ["frontend-design"], "note": "" }],
  "toolTabs": [{ "id": "tool-education", "name": "Education",
                 "roster": ["coursework","main","frontend-design"], "note": "…" }],
  "inboxRead": ["<taskId>", "…"] }
```

`id` is the category id, so a `g-…` entry is a roster override on a gateway
group and a `p-…` entry is a project made in Bridge. `inboxRead` is Bridge's
own: the gateway has no notion of "Chancellor has looked at this".

---

## 9B. The JS bridge, inbound

Phase A's channel was one-way; the page's only message was `{t:"ready"}`. Phase B
widens it to five, under one rule:

> **Nothing the page can send returns a secret, and nothing it can send carries
> one.**

| `t` | payload | effect |
| --- | ------- | ------ |
| `ready` | — | page is up; Swift replies with the stored prefs |
| `prefs` | `{prefs}` — the whole document | validated, then saved atomically |
| `send` | `{requestId, sessionKey, text, queueMode}` | `chat.send` |
| `abort` | `{requestId, sessionKey}` | `chat.abort` |
| `settings` | — | opens the **native** token sheet |
| `reconnect` | — | drops and rebuilds the socket |

Outbound gains `agents`, `groups`, `tasks`, `question`, `prefs` and
`writeResult`; `status` gains `scopes`, `requestedScopes`, `sshHost` and
`tokenPresent`.

**There is deliberately no `setToken` message.** The brief asked Settings to
offer token entry, and the easy implementation is a web field that posts its
value. That would put the token in a WKWebView heap as a JavaScript string and
quietly falsify §8's claim in the other direction. Instead the web Settings page
shows whether a token is stored and its button opens the native `SecureField`
sheet, which writes to the Keychain in-process. Token entry is real; the token
never enters JS.

---

## 9C. The transcript floor, fixed at the root

This pane has now collapsed four times — 104px, 36px, a 2364px overflow, and in
Phase B a 94px squeeze from the steering-refusal banner. The first three were
each fixed by trimming whatever had just grown. The cause was structural:

* `.foot` was `flex: none`, so the composer took whatever height it wanted;
* `.tx` was `flex: 1 1 auto`, so its flex-basis was its *content* height —
  thousands of pixels on a real run. When the pane overflowed, the shrink
  algorithm distributes in proportion to basis, so the transcript absorbed
  essentially all of it and the composer none.

Two wrong fixes are recorded here because both look right:

* `.foot { flex: 0 1 auto }` alone — transcript recovered to 482px, but the
  composer was now shrunk in *every* case, to 184px of its natural ~380px,
  hiding the send button behind an inner scrollbar.
* `.foot { max-height: 62% }` — never resolved at all, because the containing
  block is itself flex-sized. The cap silently did nothing; transcript 120px.

The pair that works is `.tx { flex: 1 1 0; min-height: 200px }` against
`.foot { flex: 0 1 auto; min-height: 0; overflow-y: auto }`. Basis 0 means the
transcript grows into what is left rather than competing for it, so the
composer keeps its natural height until the transcript is at its floor, and only
then shrinks and scrolls. Measured at a 900px viewport:

| state | transcript | composer |
| ----- | ---------: | -------: |
| ordinary | 285px | natural |
| ping bar + refusal banner | 200px (floor) | 350px, scrolls |

Both are asserted in `Smoke.swift`, along with the mirror assertion that the
composer is not itself crushed (`foot >= 300`).

---

## 9D. Running the checks

```bash
bridge-apple/build.sh smoke        # 59 assertions, incl. a real gateway handshake
bridge-apple/build.sh mac          # release .app

# every new view, measured and photographed by the same WKWebView
Bridge.app/Contents/MacOS/Bridge --shot out.png --view inbox
#   views: sessions | inbox | settings | project | ping | tool | refusal
```

`--shot` prints a `measured=` line with the geometry of the view it just wrote,
so the screenshot and the measurement cannot disagree about what was on screen.

`build.sh` now exports Homebrew's bin onto `PATH`. A login shell finds `node`
for `mkatlas.js --check`; a non-interactive one inherits `/usr/bin:/bin` and
fails with "node: command not found", which reads as a broken toolchain rather
than a broken PATH. Same fix, same reason, as `Tunnel.swift`'s PATH line.

---

## 11. Phase C, as built — Bridge is the room

Phase B could not write. Phase C can, and the three things that unlocked were
each measured against the live gateway before a line of them was written. What
follows is the part a Phase D reader should not have to rediscover.

### 11.1 Scopes: what was raised, and what it cost

`Gateway.requestedScopes` is now

```swift
["operator.read", "operator.write", "operator.questions"]
```

`operator.approvals` and `operator.admin` are deliberately absent. Bridge shows
approvals it happens to see and does not resolve them, and an unused standing
grant is one nobody audits.

Raising the set made a **new** pairing request, exactly as §3 says — the existing
approval was not widened in place. Confirmed on the gateway host:

```
$ openclaw devices list
openclaw-macos  3b4c3eec…  operator  operator.read, operator.write, operator.questions
```

`operator.write` satisfies `operator.read`, so nothing else changed.

### 11.2 `chat.send` requires `idempotencyKey`, and Phase B did not send it

**This is the trap of Phase C, and it was invisible for as long as the
connection was read-only.**

```
INVALID_REQUEST: invalid chat.send params:
  must have required property 'idempotencyKey'
```

Under `operator.read` the scope check fires first, so every send came back
`FORBIDDEN / missing scope: operator.write` — the exact refusal Phase B's UI was
built to draw, and a perfectly convincing one. The moment `operator.write`
landed, the same code would have started failing with the line above: a bug
wearing a refusal's clothes, in the one code path that had looked most thoroughly
tested.

The value doubles as the run id the gateway echoes back:

```json
→ {"method":"chat.send","params":{"sessionKey":"…","message":"…",
                                  "idempotencyKey":"bridge-relay-test-1"}}
← {"runId":"bridge-relay-test-1","status":"started"}
```

The user message is stored with `idempotencyKey: "<key>:user"` and the assistant
reply with `"cli-assistant:<key>"`.

### 11.3 `chat.send` CREATES a session that does not exist

The finding the whole room rests on. Sending to a key nothing has ever used does
not fail — it creates the session and runs a turn:

```
→ chat.send { sessionKey: "agent:frontend-design:bridge:probe", … }
← { runId: …, status: "started" }
→ chat.history { sessionKey: "agent:frontend-design:bridge:probe" }
← messages: [ {role:"user",…}, {role:"assistant",content:[{type:"text",text:"PROBE_OK"}]} ]
```

So Bridge needs no provisioning step for its per-agent room threads, and
attempts none. `chat.history` against a key that does not exist yet answers with
an empty message list rather than an error.

*(That probe session is still on the gateway. It cost one turn and is harmless;
delete it if the session list matters more than the record.)*

### 11.4 Questions are real, and the two ids are different strings

Read off the gateway's own `question-manager` and `server-methods/question.ts`,
then exercised end to end.

| method | params | answers |
| ------ | ------ | ------- |
| `question.list` | `{}` | `{questions: [record]}` |
| `question.get` | `{id}` | `{question: record}` |
| `question.resolve` | `{id, answers: {answers: {<innerId>: [value]}}, resolvedBy?}` | — |
| `question.resolve` | `{id, cancel: true, resolvedBy?}` | — |
| `question.waitAnswer` | `{id, timeoutMs}` | `{status, answers?}` |
| `question.request` | `{questions, agentId?, sessionKey?, timeoutMs?, id?}` | `{id, expiresAtMs}` |

A record:

```json
{ "id": "5e757ac3-…",
  "questions": [ { "questionId": "room_store", "header": "Room store",
                   "question": "…",
                   "options": [ {"label":"…","description":"…"} ],
                   "multiSelect": false, "isSecret": false, "isOther": true } ],
  "agentId": "frontend-design", "sessionKey": "agent:frontend-design:bridge",
  "createdAtMs": …, "expiresAtMs": …, "status": "pending" }
```

**`record.id` addresses the record; `record.questions[i].questionId` keys the
answers map.** They are different strings, the schema accepts either, and using
the wrong one answers nothing — a failure that looks exactly like success.
`Smoke.swift` asserts both go on the wire.

Two constraints the schema enforces and the error message does not advertise
until you hit them:

* `questionId` must match `^[a-z][a-z0-9_]*$` — no hyphens.
* `header` is capped at **12 characters**.

Events: `question.requested` carries the **whole record**; `question.resolved`
carries only `{id, status, answers?}`. Phase B flattened the requested event to
five fields, which was enough to prove the wire and not enough to draw a
question — the options live inside `questions[]`.

Terminal records are dropped after a 15s grace (`QUESTION_RESOLVED_ENTRY_GRACE_MS`),
after which `question.get` answers `QUESTION_NOT_FOUND`. Use `question.waitAnswer`
to observe an answer rather than racing that window.

Verified live: a question was raised through `question.request`, appeared in the
running app's inbox with its options as buttons, was answered by clicking one in
that window, and the gateway returned

```json
{"status":"answered","answers":{"answers":{"relay_cap":["Keep 6"]}}}
```

`question.request` also means Bridge *could* raise questions itself — Phase B's
"the receiver exists and the sender does not" is now only half true.

### 11.5 The room

`Room.swift`. One persistent session per agent, `agent:<agentId>:bridge`, and
one shared transcript Bridge owns at
`~/Library/Application Support/Bridge/room.json`.

Routing, implemented literally:

* no ping → `main` alone;
* a ping → that lane alone, and `main` does not see it;
* an agent that writes `@lane` in its reply hands the work over, and Bridge
  relays it;
* every turn lands in the one transcript regardless of who it was addressed to.

**Bridge relays; the agents do not.** `tools.agentToAgent` and
`tools.sessions.visibility` remain unset — enabling them would grant every lane
on the host cross-transcript read access to every other session, permanently, to
buy a routing feature that an operator client holding `operator.write` already
has. Bridge reads and writes no gateway configuration.

Three things that are not obvious:

* **Relay from the BACKFILL, not from events.** §6 applies: `session.message`
  drops for slow subscribers, so an event-driven relay silently loses turns.
  `Room.observe` reads each `chat.history` backfill and takes anything above a
  persisted per-session high-water mark.
* **Seed the mark on first sight and emit nothing.** A room session that already
  had 40 turns would otherwise pour all 40 into the transcript on launch and
  re-fire every ping inside them — a relay storm out of history. A session that
  does not exist yet seeds at 0, which is correct: there is nothing to replay,
  and its first real turn still arrives.
* **The preamble is not sent every turn.** The session is persistent, so the
  convention is in context after the first message. It goes out on the first
  message to a session and re-anchors every 20 turns, which covers a compaction
  dropping the top of the window without paying for it constantly.

Both bounds — a 6-hop ceiling and 14 relays per 5 minutes — are enforced in
Swift and **printed into the room transcript** when they bite. A silent cap reads
as "the agents decided to stop", which is a lie about whose decision it was.

Verified live: one seeded message produced a three-hop exchange
(frontend-design → backend-design → frontend-design → backend-design) that
terminated on its own when the last reply pinged nobody.

### 11.6 The inbox bug that hid the inbox

Phase B's root-task detection built its child-key set from **every** task row,
including the `automation_run` and `cli` kinds it then filtered back out. This
gateway has exactly one `kind: "cli"` row — the overnight watchdog tick — and it
carries the same key as both its owner and its child:

```json
{"kind":"cli","ownerKey":"agent:main:main","childSessionKey":"agent:main:main"}
```

That put `agent:main:main` into the child set, and `agent:main:main` owns 25 of
the 33 delegated tasks on this host. All 25 were classified as somebody's child
and folded away, leaving one root — and an inbox reading *"No delegated task has
finished yet on this gateway"* above a footer saying 25 children had been folded
into their parents. It was found by looking at the screen: those two sentences
cannot both be true.

The fix is two rules, both in `buildInbox`:

* the child set comes from the **same corpus being classified** — a row excluded
  from the feed does not get to reparent rows that are in it;
* a **self-referential** row is nobody's parent and nobody's child.

31 roots, 30 terminal, 2 genuinely folded. The inbox went from 1 entry to 22.

### 11.7 Voice

`Voice.swift`. Hold SPACE in an **empty** composer to record; release to
transcribe and insert.

* The arming rule is the feature. Without "only when empty" the space bar stops
  being the space bar. Asserted six ways in `Smoke.swift`.
* Recording is native (`AVAudioRecorder`, 16 kHz mono 16-bit LinearPCM — exactly
  what whisper wants). The page's whole part is the strings `start` and `stop`;
  no microphone stream ever exists inside the web view.
* Transcription is local: `/opt/homebrew/bin/whisper-cli` against
  `~/Library/Application Support/Bridge/models/ggml-small.en.bin`. `-nt -np`.
* The fallback is the gateway host's `~/.local/bin/transcribe` (faster-whisper)
  over the same ssh path, used **only** when the local binary or model is
  missing. Which one ran is reported on every result and printed in Settings, so
  "local" is never assumed.
* `INFOPLIST_KEY_NSMicrophoneUsageDescription` is set in `project.pbxproj`;
  without it the process is killed on first `AVCaptureDevice` access.
* `Tunnel.pathEnv` is shared with `Tunnel.swift` rather than copied — the
  off-LAN `ProxyCommand` PATH problem is the same problem for `scp` and `ssh`
  here, and two copies that drift is how it breaks somewhere nobody looks.

### 11.8 Photographing the app that is actually running

`screencapture -l <windowid>` does not work from an agent session on this Mac:

```
$ screencapture -x -o -l 7561 /tmp/win.png
could not create image from window
```

macOS requires a **Screen Recording** grant per capturing process. That is a TCC
approval given by hand in System Settings; it cannot be granted from a shell and
`TCC.db` is SIP-protected. `pyobjc-framework-Quartz` does not help — the window
id is easy to get (a 12-line Swift script using `CGWindowListCopyWindowInfo`
does it with no dependency at all); it is the *capture* that is refused.

So the running app photographs itself, which needs no grant:

```bash
cat > ~/Library/Application\ Support/Bridge/shot-request.json <<< \
  '{"view":"room","path":"…/live-room.png","click":".ibx-q .ask-btn"}'
kill -USR1 $(pgrep -f 'Bridge.app/Contents/MacOS/Bridge')
```

`Smoke.installLiveShotHandler` switches the live window to the named view,
optionally clicks one selector, measures with `Smoke.measureJS`, snapshots, and
writes both the PNG and `<path>.json` holding the geometry. `--shot` uses the
same `views` map and the same `measureJS`, so a screenshot and the numbers
printed beside it cannot come from different notions of what was on screen.

The optional `click` is why the question path could be proven rather than
asserted: the button was pressed in the window on his desk, against the live
gateway, and the gateway returned the answer.

### 11.9 Running the checks

```bash
bridge-apple/build.sh smoke     # 123 assertions, incl. a real gateway handshake
bridge-apple/build.sh mac       # release .app

# every view, measured and photographed by the same WKWebView
Bridge.app/Contents/MacOS/Bridge --shot out.png --view room
#   views: sessions | room | ping | inbox | question | settings | project | tool | refusal
```

The transcript floor is asserted on **every** view that has one, including the
room — whose composer is ~208px natural, not the agent pane's ~380px. The first
version of that check reused the agent pane's `>= 300` and failed on a composer
that was not crushed at all. "Crushed" has an exact meaning and the check now
uses it: the composer has an inner scrollbar, so the send button is behind it.

---

## 12. Reference packages

`@openclaw/gateway-protocol` (schemas, validators, types, `protocol.schema.json`)
and `@openclaw/gateway-client` (reference Node client, plus a browser-safe
entry). They ship with OpenClaw release trains and may 404 on npm before a
package-bearing release. This client was written against the docs and the wire,
not against them, but they are the right thing to check a change against — the
identical definitions are readable in the installed CLI at
`~/.npm-global/lib/node_modules/openclaw/dist/client-info-*.js` and
`device-auth-*.js`.
