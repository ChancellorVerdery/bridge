/* Bridge — the view layer's data contract.

   Mission Control shipped this file full of a mock corpus. Bridge keeps the
   SHAPE and throws the corpus away: every container below starts empty and is
   filled, in place, by live.js from what the OpenClaw Gateway actually reports.
   `const` with in-place mutation is deliberate — app.js resolves CATEGORIES /
   LANES on every call, so replacing the *contents* is enough and nothing has to
   re-bind.

   Where each field comes from on the wire (see bridge-apple/PROTOCOL.md):

     lane                 <- session row .agentId                (LANES key is
                             per-session so a tab can be labelled by session)
     agent.id             <- session row .key      (the real gateway sessionKey)
     agent.status         <- .hasActiveRun / .status / .lastRunError
     agent.headline       <- .observerDigest.headline, else .label
     agent.operation      <- session.tool event, phase "start" without an "end"
     agent.tokens         <- .contextTokens / .totalTokens
     agent.transcript[]   <- chat.history messages, then live session.message /
                             session.tool events appended
     agent.pendingInputs  <- chat.history .pendingInputs.items

   A transcript entry is one of:
     { kind:'user',      at, text }
     { kind:'assistant', at, text }
     { kind:'tool',      at, name, args, result, status:'ok'|'err' }
     { kind:'shell',     at, cmd, out, exit }
     { kind:'system',    at, text }
     { kind:'error',     at, text }
   `at` is seconds relative to page load, negative for the past — app.js's clock.
   diff / log / relay entries are part of the contract app.js already renders;
   Phase A does not synthesise them from gateway data. */

'use strict';

/* laneKey -> { name, glyph }. One entry per live session plus 'main'. */
const LANES = {};

/* [{ id, name, subtitle, repo, branch, planned?, agents:[…] }] */
const CATEGORIES = [];

/* [{ title, ids:[categoryId] }] — the two sidebar sections. */
const NAV_SECTIONS = [];

/* $ per million tokens, for the cost readout. Unknown models fall back to 10. */
const RATES = { 'claude-opus-5': 22, 'claude-sonnet-5': 6, 'claude-haiku-4-5': 1.2 };
