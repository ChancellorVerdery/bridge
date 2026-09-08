# Bridge relay — deploy

The always-on, gateway-host half of the room. It routes `@`-pings between agent
clones inside a project, with the same hop and rate ceilings `Room.swift`
enforces, so a lane can hand work to a teammate with no laptop awake.

## What it needs

- Runs on the gateway host (the home server), beside `~/.openclaw/openclaw.json`.
- Node ≥ 18 for the global `WebSocket` (verified on the host's v24.20). No npm
  dependencies — stdlib only.
- Reads `gateway.auth.token` from the config. A loopback `cli/cli` connection
  keeps its operator scopes with no device pairing, so nothing else is needed.
- `operator.read` + `operator.write`. It never calls `sessions.delete` or
  `chat.inject` (those need `operator.admin`).

## Files

    ~/bridge-relay/relay.mjs      the service
    ~/bridge-relay/state.json     membership + routing state (below)
    bridge-relay.service          systemd user unit

## state.json — the membership definition

    {
      "projects": {
        "<projectId>": { "name": "Bridge", "access": ["main","frontend-design", …] }
      },
      "rooms": { …written by the relay: seen / since / hop / paused… }
    }

`projects` is the durable answer to "which agents are in which project". It is
hot-reloaded on write (`fs.watch`), so adding or removing an agent is a file edit
and takes effect with no restart. The `<projectId>` MUST match the id the Mac
uses in its session keys (`agent:<agent>:bridge:<projectId>`) — today it is
seeded from the Mac's `prefs.json`. `rooms` is the relay's own bookkeeping; leave
it alone.

## Install (leave DISABLED until the Mac switch below)

    cp bridge-relay.service ~/.config/systemd/user/
    systemctl --user daemon-reload

## The one coupled change on the Mac — do this AND enable, together

There must be exactly ONE router. `Room.swift` already relays agent→agent while
the Mac app is open; this service does the same on the host. Running both
delivers every hand-off twice and bills it twice.

So before `systemctl --user enable --now bridge-relay.service`, gate the Mac's
relay off. In `Room.swift`, `relayPings(in:from:project:hop:)` is the only method
that performs an agent→agent delivery — everything else (Chancellor's sends, the
transcript, the handoff chips, the clone lifecycle) stays. Make its body a no-op
when an external relay owns routing, e.g. behind a `BRIDGE_EXTERNAL_RELAY`
launch flag or a Settings toggle:

    private func relayPings(in text: String, from lane: String, project: String, hop: Int) {
        if Self.externalRelay { return }   // the home server relay owns agent→agent routing
        … existing body …
    }

`observe`/`pings` stay as they are, so the Mac still draws the `→ @teammate`
chip on a reply; only the delivery moves off the Mac. Rebuild and reinstall the
app, then enable the service.

Do them in either order but close together: whichever router is the only one
running is correct; both running is the one bad state.

## Verify

    node relay.mjs --selftest      # 15 routing assertions, no gateway
    journalctl --user -u bridge-relay -f

A healthy start logs `hello-ok`, `ready — watching N sessions across M projects`,
and nothing else until an agent produces a turn with an in-project `@`.

## What is proven, and what is not

- Proven live on the gateway 2026-09-08: connect + scopes, `agents.list`,
  `sessions.subscribe`, per-session `chat.history` seeding, and first-sight
  emitting nothing. The delivery primitive (`chat.send` creates-and-runs a
  session) was proven by probe earlier.
- NOT yet exercised: a full agent→agent chain end to end. That spends real model
  turns and the clones have real tool access, so it wants a human watching — run
  it with Chancellor, once the Mac switch is in.
