import Foundation
import Network
import Security
import WebKit
import AppKit

// The runnable check behind everything in this app that is not a straight line:
// static serving, the traversal guard, the malformed-request path, a real page
// boot in an offscreen webview, the JS bridge actually delivering, and — when a
// token is present — a real handshake against the real Gateway through the real
// ssh forward.
//
// Run: bridge-apple/build.sh smoke   (launches the built .app with --smoke; no
// window is shown, activation policy is .prohibited)
//
// The live half is skipped, loudly, when there is no token in the Keychain, so
// the check is still useful on a machine that has not been set up — but it never
// reports a pass it did not perform.
/// Held for the lifetime of a --shot run: WKWebView keeps only a weak reference
/// to its script-message handler, and a deallocated coordinator silently stops
/// delivering, which would look like the page simply never talking back.
@MainActor private var shotCoordinator: BridgeWebView.Coordinator?
/// Held for the process lifetime: a DispatchSourceSignal that is released
/// stops delivering, silently.
@MainActor private var liveShotSource: DispatchSourceSignal?

@MainActor
enum Smoke {
    static func run(origin: URL) async -> Never {
        var failed = 0
        var skipped = 0
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            print("\(pass ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " - \(detail)")")
            if !pass { failed += 1 }
        }
        func skip(_ name: String, _ why: String) {
            print("SKIP \(name) - \(why)")
            skipped += 1
        }
        func request(_ path: String, method: String = "GET") async -> (Int, Data) {
            guard let url = URL(string: path, relativeTo: origin) else { return (0, Data()) }
            var req = URLRequest(url: url)
            req.httpMethod = method
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
            } catch { return (0, Data()) }
        }

        // ---- static serving -------------------------------------------------
        let (code, html) = await request("/")
        let page = String(decoding: html, as: UTF8.self)
        check("serves the bundled app", code == 200 && page.contains("<title>Bridge</title>"),
              "status=\(code)")
        check("the Atlas badge is gone", !page.contains("atlas-logo"))
        check("the wordmark is in the markup", page.contains("brand__name") && page.contains(">Bridge<"))
        let (miss, _) = await request("/definitely-not-a-file")
        check("plain misses answer 404", miss == 404, "status=\(miss)")
        // %2F-spliced dots survive URL parsing and must hit the containment guard
        let (trav, _) = await request("/assets%2F..%2F..%2F..%2Fetc%2Fhosts")
        check("path traversal is refused", trav == 403 || trav == 404, "status=\(trav)")

        // ---- malformed request must not take the server down -----------------
        let raw = await rawRequest(port: LocalServer.shared.port,
                                   "GET / HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n")
        check("negative Content-Length is rejected, not fatal", raw.contains("400"),
              "reply=\(raw.split(separator: "\r\n").first.map(String.init) ?? "<none>")")
        let (afterCode, _) = await request("/")
        check("server still serving after a malformed request", afterCode == 200, "status=\(afterCode)")

        // ---- the web layer boots and the bridge is installed -------------------
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        web.load(URLRequest(url: origin))
        var booted = false
        for _ in 0..<120 where !booted {
            booted = ((try? await web.evaluateJavaScript(
                "typeof window.__bridgeEmit === 'function' && !!document.getElementById('content')"
            )) as? Bool) ?? false
            if !booted { try? await Task.sleep(nanoseconds: 150_000_000) }
        }
        check("page boots and installs the JS bridge", booted)
        let secure = (try? await web.evaluateJavaScript(
            "typeof crypto.randomUUID === 'function'")) as? Bool ?? false
        check("origin is a secure context (crypto.randomUUID exists)", secure)

        // ---- the Study tool's scripts parse and wire their globals -----------
        // A syntax error in study.js / studyui.js would leave these undefined
        // even though the page still boots, so assert them explicitly. (The
        // grading money-path is checked in Node — study-selfcheck.cjs — because
        // it needs the ~1MB Compute Engine that studyui lazy-loads on open.)
        let studyWired = (try? await web.evaluateJavaScript(
            "!!(window.Study && typeof window.Study.checkPart === 'function' && typeof window.Study.partRule === 'function'"
            + " && window.StudyAI && typeof window.StudyAI.configured === 'function' && typeof window.StudyAI.chat === 'function'"
            + " && window.StudyUI && typeof window.StudyUI.attach === 'function')"
        )) as? Bool ?? false
        check("Study tool scripts load and expose Study / StudyAI / StudyUI", studyWired)

        // ---- a request id is an idempotency key, so it must survive a relaunch --
        //
        // Swift passes this id to the gateway verbatim as chat.send's
        // `idempotencyKey` (Gateway.sendMessage), and the gateway makes it the
        // run id verbatim and answers a repeat from cache:
        //
        //     const clientRunId = p.idempotencyKey;
        //     const cached = context.dedupe.get(`chat:${clientRunId}`);
        //     if (cached) { respond(cached.ok, cached.payload, cached.error,
        //                           { cached: true }); return false; }
        //
        // `ok: true`, and `return false` — the send never runs. Bridge would draw
        // that as sent and delete the draft. That is a fake success, which is the
        // one thing the whole write path is written not to be.
        //
        // The id was `'w' + (++writeSeq)` against a counter that starts at 0 in
        // every page load, so the first send after every relaunch was `w1`. The
        // dedupe key carries no sessionKey and the map lives as long as the
        // gateway process, which runs for days.
        //
        // This is asserted across TWO REAL PAGE LOADS rather than by inspecting
        // the string, because "two loads do not collide" is the property and a
        // single load cannot express it. A second throwaway WKWebView on the same
        // origin is a second load; the fixture below would have produced
        // ["w1","w2","v3"] from both of them.
        let mint = "JSON.stringify([reqId('w'), reqId('w'), reqId('v')])"
        let idsA = (try? await web.evaluateJavaScript(mint)) as? String ?? "[]"
        let web2 = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        web2.load(URLRequest(url: origin))
        var booted2 = false
        for _ in 0..<120 where !booted2 {
            booted2 = ((try? await web2.evaluateJavaScript(
                "typeof window.__bridgeEmit === 'function'")) as? Bool) ?? false
            if !booted2 { try? await Task.sleep(nanoseconds: 150_000_000) }
        }
        let idsB = (try? await web2.evaluateJavaScript(mint)) as? String ?? "[]"
        func idList(_ j: String) -> [String] {
            ((try? JSONSerialization.jsonObject(with: Data(j.utf8))) as? [String]) ?? []
        }
        let listA = idList(idsA), listB = idList(idsB)
        check("a second page load boots too", booted2 && listA.count == 3 && listB.count == 3,
              "A=\(idsA) B=\(idsB)")
        check("request ids from two page loads do not collide",
              !listA.isEmpty && Set(listA).isDisjoint(with: Set(listB)),
              "A=\(idsA) B=\(idsB)")
        // Within one load they must still be distinct and still carry the counter,
        // which is what correlates an answer back to the composer that asked.
        check("and they are still distinct, and still ordered, within one load",
              Set(listA).count == 3 && listA[0].hasPrefix("w1-") && listA[1].hasPrefix("w2-"),
              "A=\(idsA)")
        // The room mints its own, on the Swift side, for the same wire field.
        check("a room id carries a per-process nonce too",
              Room.shared.debugNewId().split(separator: "-").count == 3,
              Room.shared.debugNewId())
        // web2 was a second page load and nothing else; every check that wanted
        // it has now run. Tear it down before the rest of the suite measures
        // `web`: two live WKWebViews on one origin share a WebContent process,
        // and this one goes on running the app's 1s render timer forever.
        // Hygiene, not a fix — the entrance failure ~40 lines down was first
        // blamed on this and that was WRONG; see the note there for what it
        // actually was. Left in because a second page nobody reads should not
        // keep re-rendering behind the suite either way.
        web2.stopLoading()
        web2.loadHTMLString("", baseURL: nil)

        // A whitespace-only send used to vanish inside Gateway.sendMessage: it
        // returned on the empty-text guard without emitting anything, while the
        // page sat in 'sending' behind a 31s timeout. Asserted here because a
        // fix with no check is how every bug in this file came back.
        //
        // This needs no network and no live gateway: the guard fires before
        // `call`, so nothing leaves the process, and Gateway.shared is not
        // started until much later in this suite.
        let prevOnEmit = Gateway.shared.onEmit
        var emptyResult: [String: Any]?
        Gateway.shared.onEmit = { m in
            if (m["type"] as? String) == "writeResult" { emptyResult = m }
        }
        Gateway.shared.sendMessage(sessionKey: "agent:smoke:one", text: "   \n\t  ",
                                   queueMode: "", requestId: "w-empty-1")
        for _ in 0..<40 where emptyResult == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        Gateway.shared.onEmit = prevOnEmit
        check("a whitespace-only send is refused out loud, not silently dropped",
              emptyResult != nil,
              emptyResult == nil ? "no writeResult - the composer would spin for 31s" : "got one")
        check("and that refusal names the request it answers, and says why",
              (emptyResult?["requestId"] as? String) == "w-empty-1"
              && (emptyResult?["ok"] as? Bool) == false
              && (emptyResult?["code"] as? String) == "EMPTY_MESSAGE",
              "requestId=\(emptyResult?["requestId"] as? String ?? "nil") "
              + "ok=\(emptyResult?["ok"] as? Bool ?? true) "
              + "code=\(emptyResult?["code"] as? String ?? "nil")")

        // The mock corpus is gone: nothing renders until a snapshot arrives.
        let empty = (try? await web.evaluateJavaScript("CATEGORIES.length")) as? Int ?? -1
        check("no mock corpus is compiled in", empty == 0, "CATEGORIES.length=\(empty)")

        // ---- the bridge actually delivers, and the view shapes it -------------
        // AN UNCAUGHT RENDER ERROR USED TO BE INVISIBLE HERE.
        //
        // `renderAll` builds a view and mounts it; if anything on that path
        // throws, the DOM keeps the PREVIOUS view and every assertion after it
        // fails as "the element is missing" — which is true, and says nothing
        // about the cause. Three separate failures in this suite were one
        // exception wearing three costumes. Collected here and asserted at the
        // end, so the suite reports the error rather than its symptoms.
        _ = try? await web.evaluateJavaScript("""
          // Tab zero is the room, and a room draws only its own notices — so a
          // notice addressed to `agents[0]` renders nowhere and every entrance
          // assertion below would fail for a routing reason rather than an
          // animation one. These want an ordinary agent pane.
          window.__firstAgentTab = function () {
            for (const c of CATEGORIES) {
              const a = c.agents.find(x => !x.parent && x.kind !== 'room');
              if (a) { S.view = 'sessions'; S.catId = c.id; S.tab[c.id] = a.id; return a.id; }
            }
            return null;
          };
          window.__errs = [];
          window.addEventListener('error', function (e) {
            window.__errs.push(String((e.error && e.error.stack) || e.message));
          });
          true
        """)

        // A SESSION NO LONGER MAKES A CATEGORY. It appears because a project
        // rosters its agent and the session is that clone's — so the fixture now
        // supplies the project too, and the session key is a clone key. This is
        // the smallest complete shape the app can draw anything from, which is
        // exactly what this section is for.
        let fixture = """
        window.__bridgeEmit({type:'status',connection:'live',detail:'smoke',readOnly:true,serverVersion:'0.0.0'});
        window.__bridgeEmit({type:'agents',agents:[{id:'main',name:'Thuban'},{id:'smoke',name:'Smoke'}]});
        window.__bridgeEmit({type:'prefs',path:'/tmp/smoke-prefs.json',prefs:{
          version:2,sshHost:'atlas',inboxRead:[],
          projects:[{id:'p-smoke',name:'Smoke',access:['main','smoke'],
                    clones:[{id:'smoke',state:'active'}]}]}});
        window.__bridgeEmit({type:'sessions',rows:[
          {key:'agent:smoke:bridge:p-smoke',agentId:'smoke',label:'Smoke session',
           status:'running',hasActiveRun:true,model:'claude-opus-5',contextTokens:10,totalTokens:20,
           updatedAt:Date.now(),lastInteractionAt:Date.now(),startedAt:Date.now()-1000,isMain:false}]});
        window.__bridgeEmit({type:'history',sessionKey:'agent:smoke:bridge:p-smoke',totalMessages:40,messages:[
          {role:'user',content:'hello',timestamp:Date.now()-900},
          {role:'assistant',content:[{type:'text',text:'hi'}],timestamp:Date.now()-800},
          // A deliberately tall transcript: the pane must scroll it, not grow to
          // fit it and push the composer off the bottom of the window.
          ...Array.from({length:40},(_, i)=>({role:'assistant',
            content:[{type:'text',text:'line '+i+' '+'x'.repeat(400)}],timestamp:Date.now()-700+i}))]});
        // Land on the AGENT tab rather than the project's room: everything below
        // measures a session pane, and tab zero is the room.
        S.view='sessions'; S.catId='p-smoke'; S.tab['p-smoke']='agent:smoke:bridge:p-smoke';
        S.sub=null; renderAll();
        true
        """
        _ = try? await web.evaluateJavaScript(fixture)
        try? await Task.sleep(nanoseconds: 400_000_000)
        let cats = (try? await web.evaluateJavaScript("CATEGORIES.length")) as? Int ?? 0
        check("a bridge snapshot becomes a category", cats == 1, "CATEGORIES.length=\(cats)")
        // Across ALL tabs, not the first one: tab zero is the room now, so
        // querying `.page-tab` alone would test the room's label and pass or
        // fail for a reason that has nothing to do with sessions.
        let tabText = (try? await web.evaluateJavaScript(
            "[...document.querySelectorAll('.page-tab')].map(t => t.textContent).join(' | ')")) as? String ?? ""
        check("the session is drawn as a tab, labelled by its gateway label",
              tabText.contains("Smoke session"), "tabs=\(tabText)")
        check("and the project's room is the first tab, labelled Main",
              tabText.hasPrefix("Main"), "tabs=\(tabText)")
        let txt = (try? await web.evaluateJavaScript(
            "document.querySelector('.tx') ? document.querySelector('.tx').textContent : ''")) as? String ?? ""
        check("the transcript renders both messages", txt.contains("hello") && txt.contains("hi"))

        // ---- entrance animations play once, not on every render ---------------
        // The regression this app was asked to fix: renderAll() remounts whole
        // subtrees, so an entrance declared on a plain selector replays forever.
        // The snapshot above was this content's FIRST render, so those elements
        // should be carrying .is-enter right now — and a re-render of the same
        // content must add none. Both halves matter: an assertion that only
        // checked the second would also pass if the animations were deleted.
        let first = (try? await web.evaluateJavaScript(
            "document.querySelectorAll('.is-enter').length")) as? Int ?? -1
        check("entrance animations play on first mount", first > 0, "is-enter=\(first)")
        // A remount that happens WHILE an entrance is still playing must keep
        // it. This is the defect pass 7 found and deliberately left: the
        // one-second `setInterval(renderAll)` in live.js replaces a
        // still-animating node with a fresh one, and the old "key already
        // seen" rule meant .is-enter was never re-added — the animation was
        // cut off mid-flight, sometimes before a single frame of a 0.2s fade.
        //
        // Measured in ONE evaluation: introduce an element, render, count,
        // remount, count again. JavaScript is single-threaded so the interval
        // cannot interleave, and the elapsed time is ~0ms, well inside
        // ENTER_HOLD_MS — so this asks about the hold and nothing else. A
        // sleep-based version would be asking about the clock instead.
        let holdJSON = (try? await web.evaluateJavaScript(
            "S.notice={k:'info',agentId:__firstAgentTab(),text:'hold'};"
            + " renderAll();"
            + " var a=document.querySelectorAll('.notice.is-enter').length;"
            + " renderAll();"
            + " var b=document.querySelectorAll('.notice.is-enter').length;"
            + " S.notice=null; renderAll();"
            + " JSON.stringify({a:a,b:b})")) as? String ?? "{}"
        let heldA = holdJSON.contains("\"a\":1")
        let heldB = holdJSON.contains("\"b\":1")
        check("an entrance is still playing after the render that introduced it",
              heldA, "hold=\(holdJSON)")
        check("and a remount mid-flight does not cut that entrance off",
              heldB, "hold=\(holdJSON)")

        // …and once the entrance is over the element goes still. Past
        // ENTER_HOLD_MS (800ms) a re-render of unchanged content must add
        // nothing — the original rule, now stated against the clock it was
        // always implicitly about. Render and count in one evaluation so a
        // tick cannot land between them.
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        let after = (try? await web.evaluateJavaScript(
            "renderAll(); document.querySelectorAll('.is-enter').length")) as? Int ?? -2
        check("entrance animations do not replay once they are over", after == 0, "is-enter=\(after)")
        // …and an element that genuinely appears later still gets its entrance.
        //
        // THIS ASSERTION WAS NEVER RELIABLE, and it took a build to see it.
        // It read `?? 0` — the same value a genuinely missing entrance produces,
        // so a lost measurement was indistinguishable from a product defect
        // (its two neighbours above use -1 and -2 for exactly that reason).
        // Under a distinct -3 sentinel it reported a real, stable zero, and the
        // diagnostic below said why:
        //
        //   notices:1  enters:0  keys:[…,"notice:agent:smoke:one:warn"]
        //
        // The notice HAD rendered, with the right key — but nothing anywhere on
        // the page carried .is-enter. markEntrances() had already consumed that
        // key. live.js:1352 runs `setInterval(renderAll, 1000)`: the tick after
        // the render that introduces the notice remounts the subtree — a fresh
        // node, no class — and by then the key is in prevEnterKeys, so the
        // entrance is never re-added. The class does not come back.
        //
        // So the check only ever passed if it sampled inside the gap between
        // its own render and the next tick. That is most of a ~15% window, and
        // pass 6 was blamed for losing a coin toss the baseline happened to win.
        //
        // The fix is to stop racing the timer rather than to widen the window:
        // set the notice, render, and COUNT in ONE evaluation. JavaScript is
        // single-threaded, so the interval cannot interleave with it, and the
        // measurement is of the render it is actually about. Polling was worse
        // than the fixed sleep it replaced — once a tick eats the key, no later
        // sample can ever see it.
        let reappear = (try? await web.evaluateJavaScript(
            "S.notice={k:'warn',agentId:__firstAgentTab(),text:'smoke'};"
            + " renderAll();"
            + " document.querySelectorAll('.notice.is-enter').length")) as? Int ?? -3
        // On failure, say what the page actually held: a bare count cannot tell
        // "the notice never rendered" from "it rendered but its key was already
        // seen", and those have opposite fixes. That distinction is what found
        // the timer.
        let why = (try? await web.evaluateJavaScript(
            "JSON.stringify({notices:document.querySelectorAll('.notice').length,"
            + "enters:document.querySelectorAll('.is-enter').length,"
            + "keys:[...document.querySelectorAll('[data-enter]')]"
            + ".map(n=>n.getAttribute('data-enter')).slice(0,14),"
            + "noticeAgent:(S.notice&&S.notice.agentId)||null,"
            + "cat0:(CATEGORIES[0]&&CATEGORIES[0].agents[0]&&CATEGORIES[0].agents[0].id)||null,"
            + "view:S.view||null})")) as? String ?? "{}"
        check("a newly appearing element still animates in", reappear == 1,
              reappear == -3 ? "MEASUREMENT NEVER RAN - evaluateJavaScript returned nil"
                             : "notice.is-enter=\(reappear) \(why)")
        // ---- geometry: the composer must survive a tall transcript -----------
        // v3 and v4 both shipped a build where something above the transcript
        // grew and squeezed it to a few lines. The mirror of that bug is a
        // transcript that grows and pushes the composer off the bottom, which is
        // worse: the control you need is simply not on screen. Both are one
        // assertion — measure, do not eyeball.
        let geo = (try? await web.evaluateJavaScript("""
          (function(){
            const r = (s) => { const n = document.querySelector(s); return n ? n.getBoundingClientRect() : null; };
            const c = r('.content'), tx = r('.tx'), foot = r('.foot');
            return JSON.stringify({
              viewport: window.innerHeight,
              content: c ? Math.round(c.height) : -1,
              tx: tx ? Math.round(tx.height) : -1,
              footBottom: foot ? Math.round(foot.bottom) : -1,
              contentBottom: c ? Math.round(c.bottom) : -1,
              scrolls: tx ? document.querySelector('.tx').scrollHeight > document.querySelector('.tx').clientHeight + 4 : false
            });
          })()
        """)) as? String ?? "{}"
        let g = (try? JSONSerialization.jsonObject(with: Data(geo.utf8))) as? [String: Any] ?? [:]
        let viewport = g["viewport"] as? Int ?? 0
        let txH = g["tx"] as? Int ?? -1
        let footBottom = g["footBottom"] as? Int ?? -1
        let scrolls = g["scrolls"] as? Bool ?? false
        check("a tall transcript scrolls instead of growing the pane", scrolls, geo)
        check("the composer stays inside the window", footBottom > 0 && footBottom <= viewport + 2, geo)
        check("the transcript keeps a usable floor", txH >= 200, geo)

        // …and the deliberate infinite ones are still declared.
        let liveAnim = (try? await web.evaluateJavaScript(
            "[...document.styleSheets].flatMap(s=>{try{return [...s.cssRules]}catch(e){return []}})"
            + ".filter(r=>r.style && /infinite/.test(r.style.animation||'')).length")) as? Int ?? 0
        check("the two live indicators are still infinite", liveAnim >= 2, "found \(liveAnim)")

        // ---- PHASE B ----------------------------------------------------------
        //
        // Every new view is asserted here and screenshotted by --shot, which
        // drives the same WKWebView through the same JS. One tool measures and
        // photographs, so the two cannot disagree about what is on screen.

        // Preferences: the store is Swift's, and a round-trip through it is the
        // only proof that "persists across launches" is true rather than hoped.
        var probe = Prefs()
        probe.sshHost = "smoke-host"
        probe.projects = [Prefs.Project(id: "p-smoke", name: "Smoke Project",
                                        access: ["main", "frontend-design"])]
        probe.inboxRead = ["t-read"]
        let before = Prefs.current
        check("prefs save reports success", Prefs.save(probe))
        // Re-read from DISK, not from the in-process cache: a cache that never
        // hit the file would pass a naive round-trip and lose everything on quit.
        let onDisk = (try? Data(contentsOf: Prefs.url))
            .flatMap { try? JSONDecoder().decode(Prefs.self, from: $0) }
        check("prefs survive a real write to disk", onDisk == probe,
              "path=\(Prefs.url.path) got=\(onDisk.map { $0.sshHost } ?? "<nil>")")
        check("prefs directory is Application Support",
              Prefs.url.path.contains("Application Support/Bridge/prefs.json"), Prefs.url.path)
        _ = Prefs.save(before)   // leave the user's real preferences as they were

        // ── PASS 5: a failed write must not destroy what was already there ───
        //
        // Both stores had the same defect from opposite directions: prefs
        // believed a document it had not written, and the keychain deleted a
        // secret it then failed to replace. Neither is reachable on a healthy
        // Mac, which is exactly why neither was ever measured — so both failures
        // are supplied here, and the shipping code is what runs against them.

        // Point the store at a directory that cannot be created. Room's store
        // hangs off the same directory, so nothing may touch the room between
        // these two lines and the restore below.
        let realPrefsDir = Prefs.directoryOverride
        let known = Prefs.current
        Prefs.directoryOverride = URL(fileURLWithPath: "/dev/null/not-a-directory")
        var poison = Prefs()
        poison.sshHost = "never-written"
        poison.projects = [Prefs.Project(id: "p-lost", name: "Lost", access: [])]
        let saved = Prefs.save(poison)
        Prefs.directoryOverride = realPrefsDir
        check("a prefs save that cannot write reports failure", !saved)
        check("and Prefs.current still matches the disk instead of the lost write",
              Prefs.current == known && Prefs.current.sshHost != "never-written",
              "sshHost=\(Prefs.current.sshHost) projects=\(Prefs.current.projects.map { $0.id })")
        let strays = ((try? FileManager.default.contentsOfDirectory(atPath: Prefs.directory.path)) ?? [])
            .filter { $0.hasPrefix("prefs.json.tmp-") || $0.hasPrefix("room.json.tmp-") }
        check("and no scratch file is left behind by any save so far",
              strays.isEmpty, "strays=\(strays)")

        // The keychain, against the REAL keychain, on a scratch item — never the
        // gateway token and never the device key. `addOverride` fails only the
        // new write; the restore goes through the real SecItemAdd, which is the
        // half being measured.
        let scratch = Keychain.Item.gatewayToken
        let liveToken = Keychain.get(scratch)
        let original = Data("pass5-original-secret".utf8)
        _ = Keychain.set(scratch, original)
        Keychain.addOverride = { _ in errSecParam }
        let wrote = Keychain.set(scratch, Data("pass5-replacement".utf8))
        Keychain.addOverride = nil
        let survived = Keychain.get(scratch)
        check("a keychain write that fails reports failure", !wrote)
        check("and the secret it was replacing is still there",
              survived == original,
              survived.map { String(decoding: $0, as: UTF8.self) } ?? "GONE")
        // Put the user's real token back exactly as it was, or remove the
        // scratch value if he had none.
        if let liveToken { _ = Keychain.set(scratch, liveToken) } else { Keychain.delete(scratch) }
        check("and the user's own token is left exactly as it was",
              Keychain.get(scratch) == liveToken,
              liveToken == nil ? "none stored, none left" : "restored \(liveToken!.count) bytes")

        // A queued reconnect that has been overtaken must not open a second
        // socket. The generation rule is the whole of the fix; the socket count
        // it produces is in /tmp/fd5/reconnect.swift, measured on the two
        // functions lifted verbatim.
        check("a queued gateway retry still runs when nothing overtook it",
              Gateway.retryStillApplies(scheduled: 7, current: 7, stopped: false))
        check("but not after Reconnect or a token save moved the generation on",
              !Gateway.retryStillApplies(scheduled: 7, current: 9, stopped: false))
        check("and not after stop()",
              !Gateway.retryStillApplies(scheduled: 7, current: 7, stopped: true))

        // The screenshot tooling writes to the REAL preference document — the
        // `emptyproject` view pushes a project through `savePrefs()`, and
        // `project` rewrites one of his rosters — and until this pass nothing
        // put it back. `p-shotempty` / "Empty Project" was in his live
        // prefs.json when this pass started, left there by a screenshot run.
        let shotSnapshot = Prefs.current
        var polluted = shotSnapshot
        polluted.projects.append(Prefs.Project(id: "p-shotempty-fixture", name: "Empty Project",
                                               access: []))
        check("a shot view can write into the real preference document",
              Prefs.save(polluted) && Prefs.current.projects.contains { $0.id == "p-shotempty-fixture" })
        check("and the shot restore puts it back, on disk and in memory",
              Smoke.restoreShotPrefs(shotSnapshot) && Prefs.current == shotSnapshot,
              "projects=\(Prefs.current.projects.map { $0.id })")
        let reread = (try? Data(contentsOf: Prefs.url))
            .flatMap { try? JSONDecoder().decode(Prefs.self, from: $0) }
        check("and the file on disk is his document again, not the shot's",
              reread == shotSnapshot,
              "onDisk=\(reread.map { $0.projects.map { $0.id }.joined(separator: ",") } ?? "<nil>")")
        check("and a restore with nothing to undo is a no-op",
              !Smoke.restoreShotPrefs(shotSnapshot))

        // The Phase B fixture: agents, groups, a task ledger and prefs, in the
        // shapes the gateway actually produces (see PROTOCOL.md §11).
        let phaseB = """
        window.__bridgeEmit({type:'status',connection:'live',detail:'smoke',readOnly:true,
          scopes:['operator.read'],requestedScopes:['operator.read'],sshHost:'atlas',
          tokenPresent:true,serverVersion:'2026.8.1'});
        window.__bridgeEmit({type:'agents',agents:[
          {id:'main',name:'Thuban'},{id:'frontend-design',name:'Frontend Design'},
          {id:'backend-design',name:'Backend Design'},{id:'coursework',name:'Coursework'},
          {id:'macos-expert',name:'macOS Expert'}]});
        window.__bridgeEmit({type:'groups',groups:[{name:'Bridge',position:0}]});
        window.__bridgeEmit({type:'prefs',path:'/tmp/prefs.json',tokenPresent:true,prefs:{
          version:2,sshHost:'atlas',inboxRead:['done-old'],
          projects:[{id:'p-bridge',name:'Bridge',
                     access:['main','frontend-design','backend-design','coursework','macos-expert'],
                     clones:[{id:'frontend-design',state:'active'},
                             {id:'backend-design',state:'active'},
                             {id:'coursework',state:'active'},
                             {id:'macos-expert',state:'active'}]},
                    {id:'p-atlas',name:'Atlas',
                     access:['main','frontend-design','backend-design','coursework','macos-expert'],
                     clones:[{id:'frontend-design',state:'active'},
                             {id:'backend-design',state:'active'},
                             {id:'coursework',state:'active'},
                             {id:'macos-expert',state:'active'}]}]}});
        // Real clone sessions, so the projects are not made entirely of
        // placeholders. The keys are `agent:<id>:bridge:<projectId>` because
        // that is the only way a session belongs to a project now.
        window.__bridgeEmit({type:'sessions',rows:[
          {key:'agent:main:bridge:p-bridge',agentId:'main',label:'Bridge · main',
           status:'idle',model:'claude-opus-5',contextTokens:120,totalTokens:900,
           updatedAt:Date.now(),lastInteractionAt:Date.now(),startedAt:Date.now()-9000,isMain:true},
          {key:'agent:frontend-design:bridge:p-bridge',agentId:'frontend-design',
           label:'Bridge · frontend',status:'running',hasActiveRun:true,model:'claude-opus-5',
           contextTokens:340,totalTokens:5200,
           updatedAt:Date.now(),lastInteractionAt:Date.now(),startedAt:Date.now()-4000,isMain:false},
          {key:'agent:backend-design:bridge:p-atlas',agentId:'backend-design',
           label:'Atlas · backend',status:'completed',model:'claude-sonnet-5',
           contextTokens:80,totalTokens:410,
           updatedAt:Date.now(),lastInteractionAt:Date.now(),startedAt:Date.now()-8000,isMain:false}]});
        // The child session the completed inbox task names. Emitted here so the
        // summary-provenance checks below do not depend on a fixture in another
        // section keeping its session key.
        window.__bridgeEmit({type:'history',sessionKey:'agent:smoke:one',totalMessages:3,messages:[
          {role:'user',content:'build phase A',timestamp:Date.now()-3000},
          {role:'assistant',content:[{type:'text',text:'I will start by reading the protocol.'}],
           timestamp:Date.now()-2000},
          {role:'assistant',content:[{type:'text',text:'Done: the native app is built, signed and running against the live gateway.'}],
           timestamp:Date.now()-1000}]});
        window.__bridgeEmit({type:'history',sessionKey:'agent:frontend-design:bridge:p-bridge',
          totalMessages:2,messages:[
          {role:'user',content:'take the composer',timestamp:Date.now()-900},
          {role:'assistant',content:[{type:'text',text:'on it'}],timestamp:Date.now()-800}]});
        window.__bridgeEmit({type:'tasks',replace:true,tasks:[
          // a whole delegated task that finished -> ONE entry
          {id:'done-new',kind:'subagent',status:'completed',title:'Phase A — native Mac app',
           agentId:'frontend-design',ownerKey:'agent:main:main',
           childSessionKey:'agent:smoke:one',toolUseCount:42,
           lastActivity:'Shipped and running on live gateway data.',updatedAt:Date.now()-60000},
          // its child -> folded into the parent, NOT its own entry
          {id:'child-of',kind:'subagent',status:'completed',title:'child of the above',
           agentId:'macos-expert',ownerKey:'agent:smoke:one',
           childSessionKey:'agent:smoke:kid',updatedAt:Date.now()-50000},
          // already read -> counted, not unread. Also the summary-provenance
          // case: no child transcript, only an OPENING note, so the row must
          // label it rather than passing it off as a conclusion.
          {id:'done-old',kind:'subagent',status:'failed',title:'CalcNotes — paper',
           agentId:'frontend-design',ownerKey:'agent:main:main',
           childSessionKey:'agent:smoke:gone',
           progressSummary:'I will start by reading the brief.',
           terminalOutcome:'blocked',error:'delivery failed before reaching the requester',
           updatedAt:Date.now()-90000},
          // cron noise -> filtered out of the feed and counted in the footer
          {id:'cron-1',kind:'automation_run',status:'completed',title:'heartbeat-main',
           agentId:'main',updatedAt:Date.now()-30000},
          // THE ROW THAT EMPTIED THE WHOLE INBOX. A real `kind: "cli"` task on
          // this gateway — the overnight watchdog tick — carries the SAME key as
          // both its owner and its child. Phase B built the child-key set from
          // every row, so agent:main:main became "somebody's child session", and
          // every delegated task owned by main was folded away as nested. The
          // inbox reported thirty completions as zero. Without this row in the
          // fixture the bug is invisible, which is exactly how it shipped.
          {id:'self-ref',kind:'cli',status:'failed',title:'Overnight watchdog tick',
           agentId:'main',ownerKey:'agent:main:main',childSessionKey:'agent:main:main',
           updatedAt:Date.now()-70000},
          // still running -> not a completion
          {id:'live-1',kind:'subagent',status:'running',title:'Phase B',
           agentId:'frontend-design',ownerKey:'agent:main:main',
           childSessionKey:'agent:smoke:two',updatedAt:Date.now()}]});
        true
        """
        _ = try? await web.evaluateJavaScript(phaseB)
        try? await Task.sleep(nanoseconds: 400_000_000)

        // ---- inbox -------------------------------------------------------------
        let ibx = (try? await web.evaluateJavaScript("""
          JSON.stringify({ entries: INBOX.length, unread: inboxUnread(),
            ids: INBOX.map(e => e.id), meta: INBOX.meta })
        """)) as? String ?? "{}"
        let I = (try? JSONSerialization.jsonObject(with: Data(ibx.utf8))) as? [String: Any] ?? [:]
        let ids = I["ids"] as? [String] ?? []
        let meta = I["meta"] as? [String: Any] ?? [:]
        // The rule, asserted rather than described: one entry per WHOLE task.
        // 'self-ref' is a root too — it is a real terminal delegated row — but
        // the point of this check is that it does NOT swallow the other two.
        check("one inbox entry per whole delegated task",
              ids.sorted() == ["done-new", "done-old", "self-ref"], ibx)
        check("a self-referential task row does not reparent everything else",
              ids.contains("done-new") && ids.contains("done-old"), ibx)
        check("a child task folds into its parent rather than adding an entry",
              (meta["foldedChildren"] as? Int ?? 0) == 1, ibx)
        check("cron automation runs are excluded and counted",
              (meta["automationRuns"] as? Int ?? 0) == 1, ibx)
        check("a running task is not a completion", !ids.contains("live-1"), ibx)
        check("read state comes from prefs", (I["unread"] as? Int ?? -1) == 2, ibx)

        // Summary provenance. A finished task carries no field for what it
        // concluded; the closing text is the last assistant message in the
        // child session. Ranking these wrong would caption every completed task
        // with how it STARTED, which is the defect this asserts against.
        let prov = (try? await web.evaluateJavaScript("""
          JSON.stringify(INBOX.filter(e=>e.kind==='completion')
            .map(e=>({id:e.id,k:e.summaryKind,blocked:!!e.blocked,s:(e.summary||'').slice(0,24)})))
        """)) as? String ?? "[]"
        let PV = (try? JSONSerialization.jsonObject(with: Data(prov.utf8))) as? [[String: Any]] ?? []
        let byId = Dictionary(uniqueKeysWithValues: PV.compactMap { r -> (String, [String: Any])? in
            (r["id"] as? String).map { ($0, r) } })
        check("a closing summary is read from the child session transcript",
              byId["done-new"]?["k"] as? String == "closing", prov)
        check("an opening note is labelled as one, not passed off as a conclusion",
              byId["done-old"]?["k"] as? String == "opening", prov)
        check("a task that finished but never delivered says so",
              byId["done-old"]?["blocked"] as? Bool == true, prov)

        _ = try? await web.evaluateJavaScript("openInbox(); true")
        try? await Task.sleep(nanoseconds: 250_000_000)
        let ibxDom = (try? await web.evaluateJavaScript("""
          JSON.stringify({ rows: document.querySelectorAll('.ibx').length,
            badge: (document.querySelector('.nav__unread')||{}).textContent || '',
            why: !!document.querySelector('.inbox-why'),
            srcTags: document.querySelectorAll('.ibx-src').length,
            blocked: document.querySelectorAll('.ibx-blocked').length,
            invented: document.querySelectorAll('.ibx[data-s="waiting"]').length })
        """)) as? String ?? "{}"
        let D = (try? JSONSerialization.jsonObject(with: Data(ibxDom.utf8))) as? [String: Any] ?? [:]
        check("the inbox draws its entries", (D["rows"] as? Int ?? 0) == 3, ibxDom)
        check("there is no unread badge in the sidebar — the Inbox link was removed",
              (D["badge"] as? String ?? "x") == "", ibxDom)
        check("the empty question state explains itself", (D["why"] as? Bool ?? false), ibxDom)
        // The honesty constraint, as an assertion: no question entry may exist,
        // because no question event can arrive on an operator.read connection.
        check("no question entry is fabricated", (D["invented"] as? Int ?? -1) == 0, ibxDom)
        check("the provenance tag is drawn when the summary is not a conclusion",
              (D["srcTags"] as? Int ?? 0) == 1, ibxDom)
        check("an undelivered result is drawn", (D["blocked"] as? Int ?? 0) == 1, ibxDom)

        // The launch ordering trap: preferences (and therefore tool tabs) arrive
        // before the session list. The first paint must not land on a tool tab
        // full of placeholders while real sessions exist.
        let landing = (try? await web.evaluateJavaScript("""
          (function(){
            const c = catById(S.catId);
            return JSON.stringify({ id: S.catId, kind: c ? c.kind : null,
              real: c ? c.agents.filter(a => !a._placeholder).length : -1 });
          })()
        """)) as? String ?? "{}"
        let L = (try? JSONSerialization.jsonObject(with: Data(landing.utf8))) as? [String: Any] ?? [:]
        check("first paint lands on a category with real sessions",
              (L["real"] as? Int ?? 0) > 0, landing)

        // ---- roster ------------------------------------------------------------
        _ = try? await web.evaluateJavaScript("selectCat('p-bridge'); true")
        try? await Task.sleep(nanoseconds: 250_000_000)
        let rost = (try? await web.evaluateJavaScript("""
          JSON.stringify({ tabs: [...document.querySelectorAll('.page-tab')].map(t => t.textContent),
            lanes: catById('p-bridge').agents.map(a => a.lane) })
        """)) as? String ?? "{}"
        let R = (try? JSONSerialization.jsonObject(with: Data(rost.utf8))) as? [String: Any] ?? [:]
        let lanes = R["lanes"] as? [String] ?? []
        // Main first, because main's tab is the room, then the launched clones
        // in clone order.
        check("a project's tabs are main first, then one per launched clone",
              lanes.first == "main" && Set(lanes) == Set(["main", "frontend-design",
                "backend-design", "coursework", "macos-expert"]), rost)

        // Breadcrumbs. Phase A had two category kinds; Phase B has three, and the
        // old ternary filed the Education tool tab under "Agents".
        let crumbs = (try? await web.evaluateJavaScript("""
          (function(){
            const out = {};
            for (const c of CATEGORIES) {
              selectCat(c.id);
              out[c.kind] = (document.getElementById('crumb').textContent || '').split(' / ')[1] || '';
            }
            selectCat('p-bridge');
            return JSON.stringify(out);
          })()
        """)) as? String ?? "{}"
        let CR = (try? JSONSerialization.jsonObject(with: Data(crumbs.utf8))) as? [String: Any] ?? [:]
        // One kind of category, so the breadcrumb is a constant. The old bug —
        // a ternary that filed the Education tool tab under "Agents" — is not
        // reachable because neither of those things exists.
        check("every breadcrumb says Projects, because that is all there is",
              CR.count == 1 && (CR["project"] as? String ?? "") == "Projects", crumbs)

        // ---- no ping buttons; you address by typing @ --------------------------
        // The ping-button row was removed on Chancellor's instruction: a message
        // is addressed by typing @<agent> into the composer, so there are no
        // .ping-b bubbles anywhere in the app.
        let ping = (try? await web.evaluateJavaScript("""
          (function(){
            return JSON.stringify({ bubbles: document.querySelectorAll('.ping-b').length });
          })()
        """)) as? String ?? "{}"
        let P = (try? JSONSerialization.jsonObject(with: Data(ping.utf8))) as? [String: Any] ?? [:]
        check("there are NO ping buttons anywhere — addressing is by typing @",
              (P["bubbles"] as? Int ?? -1) == 0, ping)

        // ---- steering: refused, loudly ----------------------------------------
        // The send path is real. Under operator.read the gateway answers
        // FORBIDDEN, and the UI must render THAT — never a silent no-op and
        // never a fake success.
        // Stand in for the native shell. The real __bridgeSend is injected by
        // BridgeWebView's user script; this bare WKWebView has no such config,
        // and without a stub every send fails at the bridge instead of at the
        // gateway — which would test the wrong refusal entirely.
        _ = try? await web.evaluateJavaScript("""
          window.__bridgeSend = function (m) { window.__sent = (window.__sent||[]).concat([m]); };
          // Focus a tab that actually has a session behind it. A rostered
          // placeholder has no sessionKey, and the composer for one correctly
          // refuses before the wire — which is not the state under test.
          //
          // AND NOT THE ROOM. Tab zero carries a sessionKey too (this project's
          // main clone) but renders a room: no agent composer, no context strip,
          // no `S.draft`. Focusing it silently measured the wrong pane and every
          // send, refusal and settings assertion downstream failed for that one
          // reason rather than for anything they were written to catch.
          window.__focusReal = function () {
            for (const c of CATEGORIES) {
              const a = c.agents.find(x => x.sessionKey && !x.parent && x.kind !== 'room');
              if (!a) continue;
              S.view='sessions'; S.catId=c.id; S.tab[c.id]=a.id; S.sub=null;
              renderAll();
              return a.id;
            }
            return null;
          };
          true
        """)
        let focused = (try? await web.evaluateJavaScript("window.__focusReal()")) as? String
        check("a session with a real gateway key is reachable", focused != nil,
              "focused=\(focused ?? "<none>")")
        try? await Task.sleep(nanoseconds: 200_000_000)

        let refusal = (try? await web.evaluateJavaScript("""
          (function(){
            const a = agentById(currentTabId());
            S.draft[a.id] = 'steer this run';
            submitComposer(a);
            const sending = !!document.querySelector('.wr[data-k="wait"]');
            const wentOut = (window.__sent||[]).some(m => m.t === 'send' && m.sessionKey === a.sessionKey);
            onWriteResult(S.write.id, { state:'refused', code:'FORBIDDEN',
              message:'missing scope: operator.write', missingScope:'operator.write',
              requiredScopes:['operator.write'] });
            const box = document.querySelector('.wr[data-k="fail"]');
            return JSON.stringify({ sending, wentOut, refused: !!box,
              text: box ? box.textContent : '',
              draftKept: (S.draft[a.id]||'') === 'steer this run' });
          })()
        """)) as? String ?? "{}"
        let F = (try? JSONSerialization.jsonObject(with: Data(refusal.utf8))) as? [String: Any] ?? [:]
        let ftext = F["text"] as? String ?? ""
        // The message must actually leave for the gateway. A UI that drew a
        // refusal without ever sending would pass every other check here.
        check("the message is actually sent to the gateway", (F["wentOut"] as? Bool ?? false), refusal)
        check("a send shows an in-flight state, not nothing", (F["sending"] as? Bool ?? false), refusal)
        check("a refusal is rendered", (F["refused"] as? Bool ?? false), refusal)
        check("the refusal names the exact missing scope", ftext.contains("operator.write"), ftext)
        check("the refusal gives the command that grants it",
              ftext.contains("openclaw devices approve"), ftext)
        check("a refused message is not lost from the composer",
              (F["draftKept"] as? Bool ?? false), refusal)

        // ---- settings ----------------------------------------------------------
        let setOpen = (try? await web.evaluateJavaScript(
            "(function(){ try { openSettings(); return 'ok'; }"
            + " catch (e) { return 'THREW ' + (e && (e.stack || e.message) || e); } })()"))
            as? String ?? "<nil>"
        check("opening settings does not throw", setOpen == "ok", setOpen)
        try? await Task.sleep(nanoseconds: 250_000_000)
        let setDom = (try? await web.evaluateJavaScript("""
          JSON.stringify({ sections: document.querySelectorAll('.set-s').length,
            scopes: document.querySelectorAll('.scope').length,
            granted: document.querySelectorAll('.scope[data-has="1"]').length,
            text: document.querySelector('.set') ? document.querySelector('.set').textContent : '' })
        """)) as? String ?? "{}"
        let ST = (try? JSONSerialization.jsonObject(with: Data(setDom.utf8))) as? [String: Any] ?? [:]
        let stext = ST["text"] as? String ?? ""
        check("settings is a real page, not a placeholder", (ST["sections"] as? Int ?? 0) >= 5, setDom)
        check("settings lists the granted scopes from the gateway",
              (ST["scopes"] as? Int ?? 0) == 5 && (ST["granted"] as? Int ?? 0) == 1, setDom)
        check("settings offers token entry and an ssh host", stext.contains("gateway token")
              && stext.contains("SSH host"), "len=\(stext.count)")
        check("settings has an API-keys section that says it is a placeholder",
              stext.contains("API keys") && stext.contains("Nothing is stored here yet"), "len=\(stext.count)")

        // ---- geometry, every new view, one pinned viewport ---------------------
        // The transcript-pane collapse has now shipped three times (104px, 36px,
        // a 2364px overflow). The ping bar and the write banner both add height
        // INSIDE the composer, which is exactly the shape of that bug, so the
        // floor is re-asserted with them on screen rather than assumed to hold.
        for view in ["inbox", "settings", "sessions"] {
            let enter = ["inbox": "openInbox(); true",
                         "settings": "openSettings(); true",
                         // A rostered placeholder renders a plan, not a
                         // transcript, and measuring the transcript floor on a
                         // pane that has no transcript measures nothing.
                         "sessions": "S.view='sessions'; window.__focusReal(); true"][view] ?? "true"
            _ = try? await web.evaluateJavaScript(enter)
            try? await Task.sleep(nanoseconds: 200_000_000)
            let m = (try? await web.evaluateJavaScript("""
              (function(){
                const r=(s)=>{const n=document.querySelector(s);return n?n.getBoundingClientRect():null};
                const c=r('.content'), tx=r('.tx'), foot=r('.foot'), ping=r('.ping-wrap');
                return JSON.stringify({ viewport: window.innerHeight,
                  contentBottom: c?Math.round(c.bottom):-1, contentH: c?Math.round(c.height):-1,
                  tx: tx?Math.round(tx.height):-1, ping: ping?Math.round(ping.height):0,
                  footBottom: foot?Math.round(foot.bottom):-1, footH: foot?Math.round(foot.height):-1,
                  footScrolls: foot?(document.querySelector('.foot').scrollHeight > document.querySelector('.foot').clientHeight+4):false,
                  footNatural: foot?document.querySelector('.foot').scrollHeight:-1,
                  overflowX: document.documentElement.scrollWidth - document.documentElement.clientWidth });
              })()
            """)) as? String ?? "{}"
            let G = (try? JSONSerialization.jsonObject(with: Data(m.utf8))) as? [String: Any] ?? [:]
            let vp = G["viewport"] as? Int ?? 0
            let cb = G["contentBottom"] as? Int ?? -1
            check("\(view): content stays inside the window", cb > 0 && cb <= vp + 2, m)
            check("\(view): nothing overflows horizontally", (G["overflowX"] as? Int ?? 1) <= 0, m)
            if view == "sessions" {
                let txh = G["tx"] as? Int ?? -1
                let fb = G["footBottom"] as? Int ?? -1
                check("sessions: there is no ping bar — addressing is by typing @", (G["ping"] as? Int ?? -1) == 0, m)
                check("sessions: the composer stays inside the window", fb > 0 && fb <= vp + 2, m)
                check("sessions: the transcript keeps its floor", txh >= 200,
                      "tx=\(txh) floor=200 " + m)
                // The mirror assertion, and the reason the first fix here was
                // wrong: the composer must not be silently clipped either. Its
                // natural height is ~380px, so anything under 300 means the
                // flex algorithm is eating it rather than capping it.
                // `foot >= 300` is a PROXY, and it passed for as long as this
                // check has existed while the composer scrolled its own content
                // at 1440x900: foot=350 around ~380px of content, send button
                // behind an inner scrollbar, transcript already pinned at its
                // floor with nothing left to give. The height stays as context;
                // the assertion is now the boolean §11.9 defines as "crushed".
                let footH = G["footH"] as? Int ?? -1
                check("sessions: the composer does not scroll its own content",
                      (G["footScrolls"] as? Bool ?? false) == false, "foot=\(footH) " + m)
                // WAS `footH >= 300`, AND THE COMMENT ABOVE ALREADY CALLED THAT
                // A PROXY. The pass-12 short-window shed made the proxy wrong in
                // the direction proxies always go wrong: this web view is 900px
                // tall, the shed arms below 940, so the composer's natural
                // height here is now 300 rather than ~354 and it correctly
                // measures 285 with `footScrolls: false`. A literal 300 read
                // that as a crush. It was not one — the composer is shorter
                // because it is asking for less, which is the entire point of
                // the fix. The magic number is replaced by the quantity it was
                // standing in for, so the check now moves with the layout
                // instead of having to be re-tuned every time the composer
                // legitimately changes height.
                let footNat = G["footNatural"] as? Int ?? -1
                check("sessions: the composer is not itself crushed", footH >= footNat - 4,
                      "foot=\(footH) natural=\(footNat) " + m)
            }
        }


        // ---- THE SIXTH COLLAPSE: the ordinary composer, at heights nobody ran --
        //
        // The loop above measures the plain composer at ONE viewport — whatever
        // this web view happens to be, 1440x900 — and `--shot` measures it at
        // one more, the pinned 1600x1000. Eleven passes of geometry, two window
        // sizes, and the picker was the only thing ever swept across heights.
        //
        // At 1180x760 the sessions composer scrolled its own content: foot=213
        // around a natural 262, transcript pinned at exactly 200, send button
        // behind an inner scrollbar. `ping` and `voice` did the same. Not a new
        // regression — .foot's comment describes this as its intended escape
        // valve, while the floor guard calls it a broken layout. The two rules
        // had simply never been evaluated at a height where they disagree.
        //
        // No picker here, deliberately: the picker check above already covers
        // the picker, and the bug being fixed is the ORDINARY composer, which is
        // the one every message is typed into.
        let frameBeforeHeights = web.frame
        for hh in [1200, 1000, 900, 860, 800, 760] {
            web.frame = CGRect(x: 0, y: 0, width: 1180, height: hh)
            web.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 250_000_000)
            _ = try? await web.evaluateJavaScript("S.view='sessions'; window.__focusReal(); true")
            try? await Task.sleep(nanoseconds: 250_000_000)
            let hm = (try? await web.evaluateJavaScript(Smoke.measureJS)) as? String ?? "{}"
            let H = (try? JSONSerialization.jsonObject(with: Data(hm.utf8))) as? [String: Any] ?? [:]
            let vp = (H["viewport"] as? [Int])?.last ?? 0
            let txh = H["tx"] as? Int ?? -1
            let fh = H["footH"] as? Int ?? -1
            let nat = H["footNatural"] as? Int ?? -1
            let rows = H["footRows"] as? String ?? ""
            check("composer@\(hh): the viewport really is \(hh)px", vp == hh, "viewport=\(vp)")
            check("composer@\(hh): the transcript keeps its 200px floor", txh >= 200,
                  "tx=\(txh) " + hm)
            // footNatural is the height the composer wants; footH is what it
            // got. Equal means it got all of it — the same boolean as
            // `footScrolls`, stated as arithmetic so a failure says how much
            // was taken.
            //
            // THE SPLIT AT 900 IS NOT A FUDGE, AND IT IS WORTH BEING EXACT
            // ABOUT WHY. Shedding prose buys 54px: the composer's natural
            // height falls from 354 to 300. That closes the debt completely at
            // 900 (was 325 of 354, now 301 of 300). It cannot close it at 760,
            // where the debt is 115px, because what is left is 300px of
            // CONTROLS — header 13, slash chips 22, ping bubbles 62, the input
            // and SEND 45, and an 84px write banner with its own fix button.
            // 200px of transcript plus 300px of controls plus the pane header
            // does not fit in 760px. Nothing is left to shed that is not a
            // control, so below 900 the two rules genuinely cannot both hold
            // and something has to give: either the transcript drops under its
            // floor or the composer scrolls. That is Chancellor's call, not
            // this pass's, and it is written up rather than silently decided.
            //
            // So the assertion says the true thing at each height. At and above
            // 900 the composer gets everything it wants. Below it, the weaker
            // claim that is still worth holding: whatever scrolled away is a
            // CONTROL, never prose — the shed really happened, and the composer
            // is not scrolling a metadata strip out of view.
            if hh >= 900 {
                check("composer@\(hh): the composer is not crushed — it gets the height it needs",
                      fh >= nat - 4, "foot=\(fh) natural=\(nat) tx=\(txh) rows=\(rows)")
            } else {
                // `footRows` lists every child of .foot including the hidden
                // ones, which report height 0 rather than disappearing from the
                // list — so the shed is asserted as "those rows are collapsed",
                // not "those rows are absent". The absence spelling was the
                // first version of this check and it failed on a tree where the
                // fix was working correctly, which is the right way round for a
                // wrong assertion to fail.
                //
                // `note` is expected to SURVIVE here: the sessions fixture's
                // note is a warn, and warns are exempt on purpose.
                check("composer@\(hh): the composer has shed its prose — only controls are left to scroll",
                      nat > 0 && nat <= 305
                        && rows.contains("p-use:0") && rows.contains("p-use-2:0"),
                      "foot=\(fh) natural=\(nat) tx=\(txh) rows=\(rows)")
            }
            // The send button is the point. A composer that fits but has scrolled
            // its input out of view is the fifth collapse again.
            let sendVisible = (try? await web.evaluateJavaScript("""
              (function(){
                const b=document.querySelector('.foot .send'), f=document.querySelector('.foot');
                if(!b||!f) return false;
                const r=b.getBoundingClientRect(), fr=f.getBoundingClientRect();
                return r.bottom <= fr.bottom + 1 && r.top >= fr.top - 1 && r.bottom <= window.innerHeight + 1;
              })()
            """)) as? Bool ?? false
            check("composer@\(hh): the SEND button is inside the composer and on screen",
                  sendVisible, "foot=\(fh) natural=\(nat) rows=\(rows)")
        }
        // WHAT THE FIX IS NOT ALLOWED TO DO. The shed list is prose only, and a
        // `warn` note is not prose — it is a report about the message that is
        // about to be sent. Hiding a queue warning to win 18px would trade a
        // layout bug for a correctness one, which is the trap the ping bubbles
        // were kept out of in the picker fix. Asserted at the shortest height,
        // where the shedding is definitely active.
        web.frame = CGRect(x: 0, y: 0, width: 1180, height: 760)
        web.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 250_000_000)
        let warnKept = (try? await web.evaluateJavaScript("""
          (function(){
            S.view='sessions'; window.__focusReal(); renderAll();
            const f=document.querySelector('.foot'); if(!f) return 'nofoot';
            const n=document.createElement('div');
            n.className='note'; n.setAttribute('data-k','warn');
            n.textContent='a queue warning that must survive a short window';
            f.appendChild(n);
            const shown=getComputedStyle(n).display!=='none';
            const plain=document.createElement('div');
            plain.className='note'; plain.textContent='prose that may be shed';
            f.appendChild(plain);
            const plainShown=getComputedStyle(plain).display!=='none';
            const strip=document.querySelector('.foot .p-use');
            const stripShown=strip?getComputedStyle(strip).display!=='none':false;
            n.remove(); plain.remove();
            return JSON.stringify({warn:shown, plain:plainShown, strip:stripShown});
          })()
        """)) as? String ?? "{}"
        let W = (try? JSONSerialization.jsonObject(with: Data(warnKept.utf8))) as? [String: Any] ?? [:]
        check("a warn note survives the short-window shed", (W["warn"] as? Bool ?? false), warnKept)
        check("and the prose the shed is for is actually shed",
              (W["plain"] as? Bool ?? true) == false && (W["strip"] as? Bool ?? true) == false, warnKept)
        web.frame = frameBeforeHeights
        web.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 250_000_000)

        // Both fixtures below write through the REAL preference store — that is
        // the point of them, since the access picker's whole job is to persist a
        // choice — so the document is snapshotted here and put back afterwards.
        // A test that leaves an access override and a stub project in
        // Chancellor's prefs.json has changed the app it was measuring.
        let prefsBeforePicker = Prefs.current

        // ---- THE SIDEBAR, EXACTLY ---------------------------------------------
        //
        // The sidebar's structure, asserted directly, because "the sidebar has no
        // Room entry" is the kind of claim that is true the day it is written and
        // quietly false four passes later. The access picker it used to sit
        // beside is back — see the clone-lifecycle section — but it is a panel in
        // the work area, not a part of this.
        let sidebar = (try? await web.evaluateJavaScript("""
          (function(){
            renderAll();
            const nav = document.getElementById('nav');
            const heads = [...nav.querySelectorAll('.nav__head')].map(n => n.textContent.trim());
            const labels = [...nav.querySelectorAll('.nav__label')].map(n => n.textContent.trim());
            return JSON.stringify({
              heads, labels,
              sections: NAV_SECTIONS.map(s => s.title),
              addButtons: [...nav.querySelectorAll('.nav__add')].map(n => n.textContent.trim()),
              removeButtons: nav.querySelectorAll('.nav__rm-b').length,
              projects: PREFS.projects.map(p => p.id),
              kinds: [...new Set(CATEGORIES.map(c => c.kind))],
            });
          })()
        """)) as? String ?? "{}"
        let SB = (try? JSONSerialization.jsonObject(with: Data(sidebar.utf8))) as? [String: Any] ?? [:]
        let sbHeads = SB["heads"] as? [String] ?? []
        let sbLabels = SB["labels"] as? [String] ?? []
        let sbSections = SB["sections"] as? [String] ?? []

        // NAV_SECTIONS still holds only Projects; the Tools section is rendered
        // separately below it, so the rendered sidebar shows two heads.
        check("the sidebar has a Projects section, then a Tools section",
              sbSections == ["Projects"] && sbHeads == ["Projects", "Tools"], sidebar)
        // Room used to be a sidebar entry; it is a project's first tab now.
        check("there is NO Room entry in the sidebar",
              !sbLabels.contains("Room"), sidebar)
        check("there is NO top-level agent list",
              !sbHeads.contains("Agents")
              && !sbLabels.contains("Frontend Design")
              && !sbLabels.contains("Backend Design")
              && !sbLabels.contains("Full Stack"), sidebar)
        check("there IS a Tools section now, separate from Projects — a tool is not a project",
              sbHeads.contains("Tools") && sbHeads != ["Tools"], sidebar)
        check("every category in the sidebar is a project",
              (SB["kinds"] as? [String] ?? []) == ["project"], sidebar)
        check("there is no Inbox in the sidebar — Projects and Tools only",
              !sbLabels.contains("Inbox"), sidebar)

        // ADD AND REMOVE. There was no way to remove a project at all — the gap
        // he called out — so the control's existence is asserted, not just its
        // effect.
        check("there is a working control to ADD a project",
              (SB["addButtons"] as? [String] ?? []).contains { $0.contains("New project") }, sidebar)
        check("and one to REMOVE each project, which did not exist before",
              (SB["removeButtons"] as? Int ?? 0) == (SB["projects"] as? [String] ?? []).count
              && (SB["removeButtons"] as? Int ?? 0) > 0, sidebar)

        // ---- main FIRST, then one tab per agent -------------------------------
        let tabs = (try? await web.evaluateJavaScript("""
          (function(){
            const c = CATEGORIES[0];
            if (!c) return JSON.stringify({});
            // Forget any remembered tab first. `selectCat` deliberately returns
            // you to the tab you were last on in that project; what is asserted
            // here is where a project you have NOT been inside opens.
            delete S.tab[c.id];
            S.view='sessions'; S.sub=null; selectCat(c.id);
            const strip = [...document.querySelectorAll('#page-tabs .page-tab')]
              .map(n => n.getAttribute('data-id'));
            const tabsInOrder = c.agents.filter(a => !a.parent);
            return JSON.stringify({
              id: c.id,
              first: tabsInOrder[0] ? tabsInOrder[0].id : null,
              firstKind: tabsInOrder[0] ? (tabsInOrder[0].kind || 'agent') : null,
              firstLane: tabsInOrder[0] ? tabsInOrder[0].lane : null,
              lanes: tabsInOrder.map(a => a.lane),
              access: c.access,
              clones: (c.clones||[]).map(x => x.id),
              strip,
              roomRendered: !!document.querySelector('.pane.room'),
              roomProject: (document.querySelector('.pane.room')||{getAttribute:()=>null})
                             .getAttribute('data-project'),
            });
          })()
        """)) as? String ?? "{}"
        let TB = (try? JSONSerialization.jsonObject(with: Data(tabs.utf8))) as? [String: Any] ?? [:]
        let tbLanes = TB["lanes"] as? [String] ?? []
        let tbAccess = TB["access"] as? [String] ?? []
        let tbClones = TB["clones"] as? [String] ?? []
        check("a project's FIRST tab is main, and it is the room",
              TB["firstKind"] as? String == "room" && TB["firstLane"] as? String == "main",
              tabs)
        check("selecting a project lands in that project's room",
              (TB["roomRendered"] as? Bool) == true
              && TB["roomProject"] as? String == TB["id"] as? String, tabs)
        // TABS ARE THE ROOM PLUS THE LAUNCHED CLONES — not the access list.
        // An agent Chancellor has allowed in but never launched has no session,
        // so a tab for it would be a tab for something that does not exist.
        check("and then there is one tab per LAUNCHED CLONE, main first",
              tbLanes == ["main"] + tbClones,
              "lanes=\(tbLanes) clones=\(tbClones) access=\(tbAccess)")
        check("an agent with access but no clone gets no tab",
              Set(tbAccess).subtracting(Set(tbLanes)).isEmpty
                || Set(tbAccess).subtracting(Set(tbLanes)).allSatisfy { !tbClones.contains($0) },
              "access=\(tbAccess) lanes=\(tbLanes)")
        let roomIsTab = (try? await web.evaluateJavaScript("S.view === 'sessions'")) as? Bool ?? false
        check("the room is a tab rather than a separate view", roomIsTab)

        // ---- AGENTS CANNOT CREATE PROJECTS ------------------------------------
        //
        // Enforced in code at three doors, and each one is asserted. A rule this
        // shape is exactly the sort that decays into a comment, and the two
        // projects he never made — "Diagnostics" (a gateway group) and "Empty
        // Project" (a screenshot fixture) — are what that decay looked like.
        let gate = (try? await web.evaluateJavaScript("""
          (function(){
            const before = PREFS.projects.length;
            const out = { before };

            // DOOR 1 — provenance. A gateway group, and a session carrying a
            // category, are the two paths anything on the wire ever had. Both
            // used to mint a project on sight.
            window.__bridgeEmit({type:'groups',groups:[
              {name:'Diagnostics',position:0},{name:'Invented By An Agent',position:1}]});
            window.__bridgeEmit({type:'sessions',rows:[
              {key:'agent:smoke:gate',agentId:'smoke',label:'x',category:'Smuggled',
               status:'idle',updatedAt:Date.now(),lastInteractionAt:Date.now(),isMain:false}]});
            buildCategories();
            out.afterWire = PREFS.projects.length;
            out.catIds = CATEGORIES.map(c => c.id);

            // DOOR 2 — intent. Calling the mutator from anywhere that is not a
            // DOM handler throws rather than quietly working.
            try { projectCreate('Smuggled By An Agent'); out.threw = false; }
            catch (e) { out.threw = true; out.msg = String(e.message || e); }
            out.afterDirect = PREFS.projects.length;

            // …and the same call WITH intent works, so the gate is a gate and
            // not a wall.
            const id = fromUser(() => projectCreate('Smoke Gate Project'))();
            out.made = id;
            out.afterUser = PREFS.projects.length;
            out.access = (PREFS.projects.find(p => p.id === id) || {}).access || [];
            out.clones = (PREFS.projects.find(p => p.id === id) || {}).clones || [];
            out.agentCount = LIVE.agents.length;

            // Removing is gated the same way, in both directions.
            try { projectRemove(id); out.rmThrew = false; }
            catch (e) { out.rmThrew = true; }
            out.afterDirectRemove = PREFS.projects.length;
            fromUser(() => projectRemove(id))();
            out.afterUserRemove = PREFS.projects.length;
            return JSON.stringify(out);
          })()
        """)) as? String ?? "{}"
        let G = (try? JSONSerialization.jsonObject(with: Data(gate.utf8))) as? [String: Any] ?? [:]
        let gBefore = G["before"] as? Int ?? -1
        check("DOOR 1: a gateway session group does not become a project",
              G["afterWire"] as? Int == gBefore, gate)
        check("DOOR 1: and neither does a session carrying a category nobody made",
              !((G["catIds"] as? [String] ?? []).contains { $0.contains("diagnostics")
                                                          || $0.contains("smuggled")
                                                          || $0.contains("invented") }), gate)
        check("DOOR 2: creating a project from outside a user gesture THROWS",
              (G["threw"] as? Bool) == true
              && (G["msg"] as? String ?? "").contains("not by anything on the gateway"), gate)
        check("DOOR 2: and it changes nothing when it does",
              G["afterDirect"] as? Int == gBefore, gate)
        check("DOOR 2: removing a project from outside a user gesture also throws",
              (G["rmThrew"] as? Bool) == true, gate)
        // A NEW PROJECT IS EMPTY BUT FOR ITS ROOM. The previous pass copied every
        // agent on the gateway into it, which both made the choice for him and
        // minted a live clone key per agent for a project nobody had said
        // anything about yet.
        check("a project HE makes starts with only its room, and nobody launched",
              G["afterUser"] as? Int == gBefore + 1
              && (G["access"] as? [String] ?? []) == ["main"]
              && (G["clones"] as? [[String: Any]] ?? []).isEmpty, gate)
        check("and removing it, as him, actually removes it",
              G["afterUserRemove"] as? Int == gBefore, gate)

        // DOOR 3 — the store. Whatever the page sends, what lands on disk is a
        // document whose projects all have ids this app mints. Asserted against
        // the real Prefs, in Swift, because that is where the door is.
        var smuggled = Prefs.current
        smuggled.projects.append(Prefs.Project(id: "agent-made-this", name: "Smuggled",
                                               access: ["main"]))
        smuggled.projects.append(Prefs.Project(id: "p-shotempty", name: "Empty Project",
                                               access: []))
        smuggled.projects.append(Prefs.Project(id: "p-ok-shape", name: "  ", access: ["main"]))
        let cleaned = Prefs.sanitized(smuggled)
        check("DOOR 3: a project id this app could not have minted is dropped on save",
              !cleaned.projects.contains { $0.id == "agent-made-this" },
              "ids=\(cleaned.projects.map { $0.id })")
        check("DOOR 3: and so is the screenshot fixture that was in his real sidebar",
              !cleaned.projects.contains { $0.id == "p-shotempty" },
              "ids=\(cleaned.projects.map { $0.id })")
        check("DOOR 3: and a project with no name, which nothing could label",
              !cleaned.projects.contains { $0.id == "p-ok-shape" },
              "ids=\(cleaned.projects.map { $0.id })")
        check("a valid project id is accepted, so door 3 is a filter and not a wall",
              Prefs.isValidProjectID("p-bridge") && Prefs.isValidProjectID("p-calc-notes-2")
              && !Prefs.isValidProjectID("g-bridge") && !Prefs.isValidProjectID("tool-education")
              && !Prefs.isValidProjectID("p-Bridge") && !Prefs.isValidProjectID("p-"))

        // ---- the v1 -> v2 migration -------------------------------------------
        //
        // His real prefs.json is a v1 document with tool tabs, `g-` ids and a
        // leaked fixture in it. The migration is what makes the upgrade a fact
        // on disk rather than a thing the reader does every launch.
        let v1 = """
        {"version":1,"sshHost":"atlas","inboxRead":["a","a","b"],
         "projects":[{"id":"g-bridge","name":"Bridge","note":"","roster":["frontend-design","main"]},
                     {"id":"g-atlas","name":"Atlas","note":"","roster":["main"]},
                     {"id":"p-shotempty","name":"Empty Project","note":"","roster":[]}],
         "toolTabs":[{"id":"tool-education","name":"Education","note":"n","roster":["coursework"]}]}
        """
        let migrated = (try? JSONDecoder().decode(Prefs.self, from: Data(v1.utf8)))
            .map { Prefs.sanitized($0) }
        // THREE, not two: v1's two gateway-adopted projects plus its one tool
        // tab, which is a project now rather than something deleted on upgrade.
        check("a v1 preference document still decodes rather than resetting his projects",
              migrated != nil && (migrated?.projects.count ?? 0) == 3,
              "ids=\(migrated?.projects.map { $0.id } ?? [])")
        check("the migration renames gateway-adopted and tool-tab ids into minted ones",
              migrated?.projects.map { $0.id } == ["p-bridge", "p-atlas", "p-education"],
              "ids=\(migrated?.projects.map { $0.id } ?? [])")
        check("the migration drops the leaked screenshot project",
              !(migrated?.projects.contains { $0.name == "Empty Project" } ?? true))
        // Tool tabs are gone as a FIELD, so the proof is that the re-encoded
        // document has no such key rather than that a value is empty.
        let reEncoded = migrated.flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check("the migrated document is v3 and carries no toolTabs or roster key at all",
              (migrated?.version ?? 0) == 3 && !reEncoded.contains("toolTabs")
              && !reEncoded.contains("roster") && !reEncoded.contains("note"),
              reEncoded)
        check("and it puts main first in every access list it carries over",
              migrated?.projects.allSatisfy { $0.access.first == "main" } ?? false,
              "access=\(migrated?.projects.map { $0.access } ?? [])")
        // THE CORRECTION, ASSERTED AGAINST HIS OWN DOCUMENT'S SHAPE. v1's
        // `roster` is what he had chosen, so it becomes `access` verbatim — and
        // it must NOT be widened to every agent, which is what the previous pass
        // did on load.
        check("a v1 roster becomes the ACCESS list unchanged, not a full agent set",
              migrated?.projects.first { $0.id == "p-bridge" }?.access
                == ["main", "frontend-design"],
              "bridge=\(migrated?.projects.first { $0.id == "p-bridge" }?.access ?? [])")
        check("and nothing is launched by a migration: access is not a clone set",
              migrated?.projects.allSatisfy { $0.clones.isEmpty } ?? false,
              "clones=\(migrated?.projects.map { $0.clones.count } ?? [])")
        // A v1 TOOL TAB IS A PROJECT NOW, rather than being deleted. It was a
        // name plus a chosen set of agents, which is exactly what a project is
        // under v3, and "Education" was one he had actually built.
        let edu = migrated?.projects.first { $0.id == "p-education" }
        check("a v1 tool tab is carried across as a project rather than dropped",
              edu != nil && edu?.name == "Education"
              && edu?.access == ["main", "coursework"],
              "edu=\(String(describing: edu))")
        check("normalising an access list is idempotent and deduplicates",
              Prefs.normalisedAccess(["frontend-design", "main", "frontend-design", "main"])
                == ["main", "frontend-design"])
        check("normalising an access list always yields main, because the room needs it",
              Prefs.normalisedAccess([]) == ["main"]
              && Prefs.normalisedAccess(["frontend-design"]) == ["main", "frontend-design"])
        check("a clone of an agent without access is dropped on save, so revoking kills it",
              Prefs.normalisedClones([Prefs.Clone(id: "frontend-design"),
                                      Prefs.Clone(id: "backend-design")],
                                     access: ["main", "frontend-design"]).map { $0.id }
                == ["frontend-design"])
        check("main is never a clone: its session is the room",
              Prefs.normalisedClones([Prefs.Clone(id: "main")], access: ["main"]).isEmpty)
        check("an unknown clone state is stored as active rather than kept as junk",
              Prefs.normalisedClones([Prefs.Clone(id: "frontend-design", state: "wat")],
                                     access: ["main", "frontend-design"]).first?.state == "active")
        check("a document that needs no migration is left exactly alone",
              Prefs.sanitized(cleaned) == cleaned)
        web.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        web.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 200_000_000)
        // ---- THE TAB STRIP IS A COST, AND IT IS NOW A BOUNDED ONE -------------
        //
        // Found by the new `--size` sweep against the LIVE gateway, not here:
        // `--view sessions --size 1440x900` landed on a category with sixteen
        // open sessions, the strip wrapped to four rows, `.content` measured
        // 592px instead of 756, and the composer scrolled at 236px around 246 —
        // send button below the fold, transcript already at its floor. Nothing
        // in the pane had changed; the header took 164px and the pane paid.
        //
        // So the pane's height was a function of how many sessions the gateway
        // happened to have open, which is not a property a floor can survive.
        // Sixteen rows go in here because one does not reproduce it.
        // A crowded strip is now a big ROSTER rather than many loose sessions:
        // tabs come from the project's clone set, so sixteen sessions carrying a
        // category produce nothing at all. Sixteen agents go in here because one
        // does not reproduce it.
        let manyTabs = """
        (function(){
          const lanes = Array.from({length:16},(_,i)=>'many-lane-'+i);
          window.__bridgeEmit({type:'agents',agents:[{id:'main',name:'Thuban'}].concat(
            lanes.map(id=>({id,name:'A fairly long agent label '+id})))});
          window.__bridgeEmit({type:'prefs',path:'/tmp/smoke-prefs.json',prefs:{
            version:2,sshHost:'atlas',inboxRead:[],
            projects:[{id:'p-many',name:'Many',access:['main'].concat(lanes),
                      clones:lanes.map(id=>({id,state:'active'}))}]}});
          window.__bridgeEmit({type:'sessions',rows:lanes.map((id,i)=>(
            {key:'agent:'+id+':bridge:p-many',agentId:id,
             label:'A fairly long session label '+i,
             status:'running',hasActiveRun:true,model:'claude-opus-5',
             contextTokens:10,totalTokens:20,updatedAt:Date.now(),
             lastInteractionAt:Date.now(),startedAt:Date.now()-1000,isMain:false}))});
          return true;
        })()
        """
        _ = try? await web.evaluateJavaScript(manyTabs)
        try? await Task.sleep(nanoseconds: 400_000_000)
        _ = try? await web.evaluateJavaScript("S.view='sessions'; window.__focusReal(); true")
        try? await Task.sleep(nanoseconds: 300_000_000)
        let strip = (try? await web.evaluateJavaScript("""
          (function(){
            const el=document.getElementById('page-tabs');
            const c=document.querySelector('.content'), f=document.querySelector('.foot');
            const act=el?el.querySelector('.page-tab.is-active'):null;
            return JSON.stringify({ tabs: el?el.children.length:0,
              stripH: el?Math.round(el.getBoundingClientRect().height):-1,
              stripScrolls: el?el.scrollHeight>el.clientHeight+2:false,
              overflowXStyle: el?getComputedStyle(el).overflowX:'',
              activeVisible: (function(){
                if(!act||!el) return false;
                const a=act.getBoundingClientRect(), e=el.getBoundingClientRect();
                return a.bottom<=e.bottom+1 && a.top>=e.top-1;
              })(),
              contentH: c?Math.round(c.getBoundingClientRect().height):-1,
              footScrolls: f?(f.scrollHeight>f.clientHeight+4):false });
          })()
        """)) as? String ?? "{}"
        let SP = (try? JSONSerialization.jsonObject(with: Data(strip.utf8))) as? [String: Any] ?? [:]
        check("many tabs: the fixture really produced a crowded strip",
              (SP["tabs"] as? Int ?? 0) >= 16, strip)
        check("many tabs: and they are the project's clone set, room included",
              (SP["tabs"] as? Int ?? 0) == 17, strip)
        check("many tabs: the folder-tab strip stays a single row", (SP["stripH"] as? Int ?? 999) <= 45, strip)
        check("many tabs: the strip scrolls horizontally rather than clipping or wrapping",
              (SP["overflowXStyle"] as? String) == "auto", strip)
        // A cap that can hide the tab you are on is worse than the unbounded
        // strip it replaced, so this half is not optional.
        check("many tabs: the active tab is still visible inside the cap",
              (SP["activeVisible"] as? Bool) == true, strip)
        check("many tabs: the composer does not scroll because of the header",
              (SP["footScrolls"] as? Bool) == false, strip)

        // The many-tabs fixture replaced the page's project list with `p-many`.
        // Put the Phase B projects back before anything downstream asks for
        // `p-bridge` — the room section does, and a missing project there fails
        // as "the room drew nothing", which is a true statement about a cause
        // three hundred lines away.
        _ = try? await web.evaluateJavaScript("""
          window.__bridgeEmit({type:'agents',agents:[
            {id:'main',name:'Thuban'},{id:'frontend-design',name:'Frontend Design'},
            {id:'backend-design',name:'Backend Design'},{id:'coursework',name:'Coursework'},
            {id:'macos-expert',name:'macOS Expert'}]});
          window.__bridgeEmit({type:'prefs',path:'/tmp/smoke-prefs.json',prefs:{
            version:2,sshHost:'atlas',inboxRead:['done-old'],
            projects:[{id:'p-bridge',name:'Bridge',
                       access:['main','frontend-design','backend-design','coursework','macos-expert'],
                       clones:[{id:'frontend-design',state:'active'},
                               {id:'backend-design',state:'active'},
                               {id:'coursework',state:'active'},
                               {id:'macos-expert',state:'active'}]},
                      {id:'p-atlas',name:'Atlas',
                       access:['main','frontend-design','backend-design','coursework','macos-expert'],
                       clones:[{id:'frontend-design',state:'active'},
                               {id:'backend-design',state:'active'},
                               {id:'coursework',state:'active'},
                               {id:'macos-expert',state:'active'}]}]}});
          // …and the clone sessions with them. `type:'sessions'` is a whole
          // replacement, so the many-tabs fixture wiped these; without them
          // every project is placeholders, `__focusReal` finds no agent pane at
          // all, and the checks after this measure the room's metadata row
          // while claiming to measure a session's.
          window.__bridgeEmit({type:'sessions',rows:[
            {key:'agent:main:bridge:p-bridge',agentId:'main',label:'Bridge · main',
             status:'idle',model:'claude-opus-5',contextTokens:120,totalTokens:900,
             updatedAt:Date.now(),lastInteractionAt:Date.now(),startedAt:Date.now()-9000,isMain:true},
            {key:'agent:frontend-design:bridge:p-bridge',agentId:'frontend-design',
             label:'Bridge · frontend',status:'running',hasActiveRun:true,model:'claude-opus-5',
             contextTokens:340,totalTokens:5200,
             updatedAt:Date.now(),lastInteractionAt:Date.now(),startedAt:Date.now()-4000,isMain:false},
            {key:'agent:backend-design:bridge:p-atlas',agentId:'backend-design',
             label:'Atlas · backend',status:'completed',model:'claude-sonnet-5',
             contextTokens:80,totalTokens:410,
             updatedAt:Date.now(),lastInteractionAt:Date.now(),startedAt:Date.now()-8000,isMain:false}]});
          buildCategories(); renderAll(); true
        """)
        try? await Task.sleep(nanoseconds: 250_000_000)

        _ = Prefs.save(prefsBeforePicker)   // leave the real preferences as they were
        check("the picker fixtures left the preference document unchanged",
              Prefs.current == prefsBeforePicker,
              "projects=\(Prefs.current.projects.map { $0.id })")

        // ═══════════════════════ PHASE C ═══════════════════════
        //
        // The room, the question path, the elapsed rule and hold-to-talk. The
        // pure routing decisions are asserted in Swift against Room's own
        // functions; everything that is a rendering decision is asserted in the
        // page, in the same WKWebView --shot photographs.

        // ---- ping parsing: who takes the next turn ---------------------------
        let roster = ["main", "frontend-design", "backend-design", "full-stack",
                      "cybersecurity", "coursework", "linux-expert", "macos-expert", "windows-expert"]
        check("a ping is parsed out of an agent's reply",
              Room.pings(in: "Done with the CSS. @backend-design your turn.",
                         agents: roster, excluding: "frontend-design") == ["backend-design"])
        // The exact trap: a shorter agent id is a prefix of a longer one, and a
        // naive match files @full-stack under nothing or under a wrong lane.
        check("a hyphenated id is matched whole, not truncated",
              Room.pings(in: "@full-stack please tie these together",
                         agents: roster, excluding: "main") == ["full-stack"])
        check("several pings in one reply are relayed in order",
              Room.pings(in: "@backend-design first, then @cybersecurity for a look",
                         agents: roster, excluding: "main") == ["backend-design", "cybersecurity"])
        // The prefix trap. `hasPrefix` made every agent id a live prefix of any
        // longer word, so an ordinary English sentence could hand a whole reply
        // to a lane nobody addressed and start a relay chain off it.
        check("a longer word that merely STARTS with an agent id is not a ping",
              Room.pings(in: "ask the @maintainer to look at it", agents: roster,
                         excluding: "main") == [])
        check("@mainline is not @main",
              Room.pings(in: "the @mainline build is green", agents: roster,
                         excluding: "backend-design") == [])
        check("a real ping still resolves next to that word",
              Room.pings(in: "the @mainline build is green, @main please look",
                         agents: roster, excluding: "backend-design") == ["main"])
        check("trailing punctuation still pings",
              Room.pings(in: "handing to @backend-design.", agents: roster,
                         excluding: "main") == ["backend-design"])
        check("a trailing hyphen still pings",
              Room.pings(in: "over to @full-stack- now", agents: roster,
                         excluding: "main") == ["full-stack"])

        check("an agent pinging itself is not a hand-off",
              Room.pings(in: "note to self @frontend-design", agents: roster,
                         excluding: "frontend-design").isEmpty)
        check("the same ping twice is one hand-off",
              Room.pings(in: "@coursework and again @coursework", agents: roster,
                         excluding: "main") == ["coursework"])
        check("an @ that is not an agent is not a ping",
              Room.pings(in: "email alex@example.com about it", agents: roster,
                         excluding: "main").isEmpty)
        check("a clone session key names its agent AND its project",
              Room.key("frontend-design", project: "p-bridge")
                == "agent:frontend-design:bridge:p-bridge"
              && Room.route(fromRoomKey: "agent:frontend-design:bridge:p-bridge")?.agent
                == "frontend-design"
              && Room.route(fromRoomKey: "agent:frontend-design:bridge:p-bridge")?.project
                == "p-bridge")
        // THE SAME AGENT IN TWO PROJECTS IS TWO SESSIONS. This is the whole
        // isolation claim reduced to the one string it actually rests on: if
        // these ever collide, two projects share a transcript and nothing else
        // in the app would notice.
        check("the same agent in two projects is two different sessions",
              Room.key("frontend-design", project: "p-bridge")
                != Room.key("frontend-design", project: "p-calcnotes"))
        check("an ordinary session key is not mistaken for a clone key",
              Room.route(fromRoomKey: "agent:main:main") == nil)
        check("a v1 three-part room key is no longer a clone key",
              Room.route(fromRoomKey: "agent:main:bridge") == nil)
        check("a clone key with an empty project is not a clone key",
              Room.route(fromRoomKey: "agent:main:bridge:") == nil)
        check("thinking is never relayed",
              Room.plainText(["role": "assistant", "content": [
                ["type": "thinking", "text": "private"],
                ["type": "text", "text": "said out loud"]]]) == "said out loud")

        // ---- project isolation ------------------------------------------------
        //
        // Two projects, both holding `frontend-design` and `backend-design`, and
        // one holding a lane the other does not. Everything below runs against
        // Room's real routing rather than a model of it.
        // POINT THE ROOM STORE AT SCRATCH FOR THIS WHOLE SECTION.
        //
        // These fixtures create projects, say things in them and remove them
        // again — against the REAL `room.json`, next to a Bridge that is very
        // likely open on his desk holding its own copy in memory. Restoring
        // afterwards is not enough when something else is writing the same file:
        // the two races and the loser is whichever wrote first. `Room.url` hangs
        // off `Prefs.directory`, so overriding the directory moves the whole
        // section somewhere disposable, and the assertion below is that his file
        // was never touched rather than that it was put back.
        let realDir = Prefs.directoryOverride
        let roomBytesBefore = try? Data(contentsOf: Room.url)
        Prefs.directoryOverride = URL(fileURLWithPath:
            NSTemporaryDirectory() + "bridge-smoke-\(UUID().uuidString.prefix(8))")
        let roomStoreBefore = Room.shared.store
        let projectsBefore = Room.shared.projects
        let pA = "p-smoke-alpha", pB = "p-smoke-beta"
        Room.shared.setAgents(roster.map { (id: $0, name: $0) })
        Room.shared.setProjects([
            Prefs.Project(id: pA, name: "Alpha",
                          access: ["main", "frontend-design", "backend-design"],
                          clones: [Prefs.Clone(id: "frontend-design")]),
            Prefs.Project(id: pB, name: "Beta",
                          access: ["main", "frontend-design", "cybersecurity"]),
        ])

        check("a project's ACCESS LIST is the set an agent in it can reach",
              Room.shared.access(of: pA) == ["main", "frontend-design", "backend-design"])
        check("a project nobody made has no access list, so it is unroutable",
              Room.shared.access(of: "p-does-not-exist").isEmpty)
        // ACCESS IS NOT THE CLONE SET. This is the assumption the previous pass
        // made — that a project holds a clone of everything in it — stated as
        // the thing that must NOT be true.
        check("access is not the clone set: an agent may be allowed in and not launched",
              Room.shared.access(of: pA).count == 3
              && Room.shared.clones(of: pA).map { $0.id } == ["frontend-design"]
              && !Room.shared.isLaunched("backend-design", project: pA),
              "access=\(Room.shared.access(of: pA)) clones=\(Room.shared.clones(of: pA).map { $0.id })")
        check("and the tabs are the room first, then only the launched clones",
              Room.shared.tabs(of: pA) == ["main", "frontend-design"],
              "tabs=\(Room.shared.tabs(of: pA))")
        check("only sessions that exist are subscribed, so an unlaunched agent has no key",
              Room.shared.keys.contains(Room.key("frontend-design", project: pA))
              && !Room.shared.keys.contains(Room.key("backend-design", project: pA))
              && Room.shared.keys.contains(Room.key("main", project: pA)),
              "keys=\(Room.shared.keys)")

        // A PING IS RESOLVED AGAINST THE PROJECT'S ROSTER, NOT THE GATEWAY'S
        // AGENT LIST. `cybersecurity` is a real agent and is in Beta; from
        // inside Alpha it must resolve to nothing at all.
        check("a ping naming a lane outside the project resolves to nothing",
              Room.pings(in: "@cybersecurity can you review this",
                         agents: Room.shared.access(of: pA), excluding: "frontend-design").isEmpty)
        check("and the same ping inside the project that HAS that lane resolves",
              Room.pings(in: "@cybersecurity can you review this",
                         agents: Room.shared.access(of: pB),
                         excluding: "frontend-design") == ["cybersecurity"])

        // …and the enforcement, at the door rather than at the parser: even a
        // caller that hands `deliver` a target directly cannot reach out of the
        // project. This is what makes "no cross-project messaging" a property of
        // the code and not of every call site remembering.
        let crossBefore = Room.shared.doc(pA).messages.count
        let crossWire = Room.shared.deliver(to: "cybersecurity", project: pA,
                                            from: "frontend-design", text: "reach across", hop: 1)
        let crossRow = Room.shared.doc(pA).messages.last
        check("deliver REFUSES a target that is not in the project",
              crossWire == nil, "wire=\(crossWire ?? "nil")")
        check("and it says so in that project's transcript rather than failing silently",
              Room.shared.doc(pA).messages.count == crossBefore + 1
              && crossRow?.kind == "error"
              && (crossRow?.text ?? "").contains("only reach agents inside their own project"),
              "kind=\(crossRow?.kind ?? "nil") text=\(crossRow?.text ?? "")")
        check("a refused cross-project send reaches the other project not at all",
              Room.shared.doc(pB).messages.isEmpty,
              "beta=\(Room.shared.doc(pB).messages.count)")
        check("deliver into a project that does not exist is refused outright",
              Room.shared.deliver(to: "main", project: "p-does-not-exist",
                                  from: "chancellor", text: "hello", hop: 0) == nil)

        // The preamble is the only place a clone learns the rules it is inside,
        // so what it states is asserted rather than assumed.
        let pre = Room.shared.preamble(for: "frontend-design", project: pA)
        check("the preamble names the project the clone is working in",
              pre.contains("project Alpha"), pre)
        check("the preamble names only that project's teammates",
              pre.contains("backend-design") && !pre.contains("cybersecurity"), pre)
        check("the preamble states that reach stops at the project boundary",
              pre.contains("ONLY REACH AGENTS IN Alpha"), pre)
        // MEMORY FOLLOWS THE AGENT, NOT THE PROJECT. The previous pass gave each
        // clone a file scoped to (project, agent), which made the same agent a
        // different one in every project. These assert the correction directly:
        // the paths must not contain a project id at all, and the preamble a
        // clone reads in Alpha must name the same two files as the one it reads
        // in Beta.
        check("the preamble names the agent's soul and memory files",
              pre.contains(Room.soulPath(agent: "frontend-design"))
              && pre.contains(Room.memoryPath(agent: "frontend-design")), pre)
        check("and says both are shared by every clone of that agent everywhere",
              pre.contains("SHARED BY EVERY CLONE OF frontend-design IN EVERY PROJECT"), pre)
        check("an agent's memory paths carry no project id at all",
              !Room.memoryPath(agent: "frontend-design").contains(pA)
              && !Room.memoryPath(agent: "frontend-design").contains(pB)
              && !Room.soulPath(agent: "frontend-design").contains(pA)
              && !Room.soulPath(agent: "frontend-design").contains(pB),
              Room.memoryPath(agent: "frontend-design"))
        let preB = Room.shared.preamble(for: "frontend-design", project: pB)
        check("the SAME agent in two projects is told the SAME two memory files",
              preB.contains(Room.soulPath(agent: "frontend-design"))
              && preB.contains(Room.memoryPath(agent: "frontend-design")))
        check("two DIFFERENT agents do not share a memory file",
              Room.memoryPath(agent: "frontend-design") != Room.memoryPath(agent: "backend-design")
              && Room.soulPath(agent: "frontend-design") != Room.memoryPath(agent: "frontend-design"))
        check("and the ONE shared memory file every clone in every project uses",
              pre.contains(Room.sharedMemoryPath)
              && pre.contains("shared by every agent in every project"), pre)
        check("the shared memory file is the same one from either project",
              !Room.sharedMemoryPath.contains(pA) && !Room.sharedMemoryPath.contains(pB))

        // Rooms are per project: a transcript, a pause and a rate limit in one
        // say nothing about the other.
        Room.shared.note("alpha only", project: pA, kind: "note")
        check("a note lands in its own project's room and nowhere else",
              Room.shared.doc(pA).messages.last?.text == "alpha only"
              && Room.shared.doc(pB).messages.isEmpty)
        Room.shared.setPaused(true, project: pA)
        check("pausing one project's relay leaves the other running",
              Room.shared.doc(pA).paused && !Room.shared.doc(pB).paused)
        Room.shared.setPaused(false, project: pA)

        // Removing a project takes its room with it. A project recreated under
        // the same name must not inherit a conversation from a previous life.
        Room.shared.setProjects([Prefs.Project(id: pB, name: "Beta",
                                               access: ["main", "frontend-design", "cybersecurity"])])
        check("removing a project drops its room",
              Room.shared.doc(pA).messages.isEmpty && Room.shared.project(pA) == nil,
              "alpha=\(Room.shared.doc(pA).messages.count)")
        check("and leaves the other project's room untouched",
              Room.shared.project(pB) != nil)

        // ---- THE LIFE OF A CLONE ----------------------------------------------
        //
        // Access is a permission; a clone is a thing that exists. Launching makes
        // one, and when a task is finished Chancellor either parks it or ends it.
        // Both are his decision, so both are asserted to be reachable and to do
        // different things — and nothing here is asserted to happen on its own,
        // because nothing does: Bridge never reaps a clone he has not spoken
        // about.
        //
        // The gateway half of `kill` (chat.abort, then sessions.delete) is NOT
        // exercised here. The socket is not up in this section, and a smoke run
        // that deletes sessions on his live gateway to prove it can is a worse
        // trade than leaving one arrow undrawn. What is asserted is everything
        // Bridge itself decides: the clone set, the tabs, the subscriptions and
        // the transcript.
        let pL = "p-smoke-life"
        Room.shared.setProjects([Prefs.Project(id: pL, name: "Life",
                                               access: ["main", "frontend-design",
                                                        "backend-design"])])
        check("a project starts with nobody launched, however many have access",
              Room.shared.clones(of: pL).isEmpty && Room.shared.access(of: pL).count == 3
              && Room.shared.tabs(of: pL) == ["main"],
              "tabs=\(Room.shared.tabs(of: pL))")

        Room.shared.launch("frontend-design", project: pL)
        check("launching an agent with access makes a clone, and it is active",
              Room.shared.cloneState("frontend-design", project: pL) == "active"
              && Room.shared.tabs(of: pL) == ["main", "frontend-design"],
              "clones=\(Room.shared.clones(of: pL))")
        check("and launching it says so in the project's room",
              (Room.shared.doc(pL).messages.last?.text ?? "").contains("Launched @frontend-design"),
              Room.shared.doc(pL).messages.last?.text ?? "<none>")
        check("a launched clone is subscribed; an agent merely allowed in is not",
              Room.shared.keys.contains(Room.key("frontend-design", project: pL))
              && !Room.shared.keys.contains(Room.key("backend-design", project: pL)))

        // LAUNCHING IS BOUNDED BY ACCESS. This is the same door `deliver` uses,
        // checked again here because a launch is the thing that creates the
        // session — a launch that skipped the check would be a way in that
        // routing never sees.
        let outsiderBefore = Room.shared.clones(of: pL).count
        Room.shared.launch("cybersecurity", project: pL)
        check("launching an agent WITHOUT access is refused and creates nothing",
              Room.shared.clones(of: pL).count == outsiderBefore
              && Room.shared.cloneState("cybersecurity", project: pL) == nil
              && (Room.shared.doc(pL).messages.last?.text ?? "").contains("has not been given access"),
              Room.shared.doc(pL).messages.last?.text ?? "<none>")

        // IDLE. Kept, not killed: same clone, same session key, still a tab.
        Room.shared.setIdle("frontend-design", project: pL)
        check("idling a clone parks it without removing it",
              Room.shared.cloneState("frontend-design", project: pL) == "idle"
              && Room.shared.tabs(of: pL) == ["main", "frontend-design"]
              && Room.shared.keys.contains(Room.key("frontend-design", project: pL)))
        check("and it says which of the two things happened, in that project's room",
              (Room.shared.doc(pL).messages.last?.text ?? "").contains("is idle in Life"),
              Room.shared.doc(pL).messages.last?.text ?? "<none>")

        // A PING WAKES A PARKED CLONE. "Idle" is a rest state, not a refusal —
        // otherwise parking a clone would quietly break the room for it.
        let wake = Room.shared.deliver(to: "frontend-design", project: pL,
                                       from: "chancellor", text: "back to it", hop: 0)
        check("delivering to an idle clone wakes it rather than being refused",
              wake != nil && Room.shared.cloneState("frontend-design", project: pL) == "active")

        // DELIVERY LAUNCHES AN AGENT THAT HAS ACCESS. A teammate handed work by
        // an @ping must not need a separate click first.
        let relayed = Room.shared.deliver(to: "backend-design", project: pL,
                                          from: "frontend-design", text: "your half", hop: 1)
        check("delivering to an allowed agent that was never launched launches it",
              relayed != nil
              && Room.shared.cloneState("backend-design", project: pL) == "active"
              && Room.shared.tabs(of: pL) == ["main", "frontend-design", "backend-design"],
              "tabs=\(Room.shared.tabs(of: pL))")

        // KILL. The clone ends; the AGENT does not.
        Room.shared.kill("backend-design", project: pL)
        check("killing a clone removes it, its tab and its subscription",
              Room.shared.cloneState("backend-design", project: pL) == nil
              && Room.shared.tabs(of: pL) == ["main", "frontend-design"]
              && !Room.shared.keys.contains(Room.key("backend-design", project: pL)),
              "tabs=\(Room.shared.tabs(of: pL))")
        check("killing a clone leaves the agent's ACCESS alone, so it can be launched again",
              Room.shared.access(of: pL).contains("backend-design"))
        check("and it says the agent's own memory was not touched",
              (Room.shared.doc(pL).messages.last?.text ?? "").contains("memory is untouched"),
              Room.shared.doc(pL).messages.last?.text ?? "<none>")
        check("a killed clone's high-water mark goes with it, so a relaunch is not deaf",
              Room.shared.doc(pL).seen[Room.key("backend-design", project: pL)] == nil)
        Room.shared.launch("backend-design", project: pL)
        check("and launching it again brings a clone back",
              Room.shared.cloneState("backend-design", project: pL) == "active")

        // MAIN IS NOT A CLONE AND CANNOT BE ENDED. Its session is the room, so
        // killing it would mean deleting the project's conversation through a
        // control that says it is deleting one agent's.
        Room.shared.kill("main", project: pL)
        Room.shared.setIdle("main", project: pL)
        check("main cannot be killed or parked: its session is the room itself",
              Room.shared.tabs(of: pL).first == "main"
              && Room.shared.cloneState("main", project: pL) == "active"
              && !Room.shared.clones(of: pL).contains { $0.id == "main" })

        // ---- first sight of a session must not replay its history ------------
        //
        // The failure this guards is specific and was reachable: a room session
        // that already had 40 turns in it before the room existed would, on the
        // first backfill, pour all 40 into the transcript and re-fire every ping
        // inside them — a relay storm out of history, on launch.
        let pProbe = "p-smoke-probe"
        Room.shared.setProjects([Prefs.Project(id: pProbe, name: "Probe", access: roster)])
        // A key no real agent owns, so this reads none of Chancellor's state.
        //
        // The first version of this check used a real room key and passed once,
        // then failed on the next run — because the LIVE section below connects,
        // subscribes to every clone session, and seeds `seen[key] = 0` for each.
        // The second run then had a mark of 0 rather than nil and the "first
        // sight" branch was never taken. The test was reading ambient state;
        // that is a bad test, not a bad behaviour, and a unique key is the fix.
        let probeLane = "smoke-\(UUID().uuidString.prefix(8).lowercased())"
        Room.shared.setProjects([Prefs.Project(id: pProbe, name: "Probe",
                                               access: roster + [probeLane],
                                               clones: [Prefs.Clone(id: probeLane)])])
        let probeKey = Room.key(probeLane, project: pProbe)
        let history: [[String: Any]] = [
            ["role": "assistant", "content": [["type": "text", "text": "old turn @backend-design"]],
             "__openclaw": ["seq": 7]],
        ]
        Room.shared.observe(key: probeKey, messages: history)
        check("first sight of a clone session seeds the mark and emits nothing",
              Room.shared.doc(pProbe).messages.isEmpty
              && Room.shared.doc(pProbe).seen[probeKey] == 7,
              "seen=\(Room.shared.doc(pProbe).seen[probeKey].map(String.init) ?? "nil")")
        // …and a turn ABOVE the mark does land.
        Room.shared.observe(key: probeKey, messages: history + [
            ["role": "assistant", "content": [["type": "text", "text": "new turn"]],
             "__openclaw": ["seq": 8]]])
        check("a turn above the high-water mark enters that project's room",
              Room.shared.doc(pProbe).messages.count == 1
              && Room.shared.doc(pProbe).messages.last?.text == "new turn",
              "n=\(Room.shared.doc(pProbe).messages.count)")
        // A backfill for a project that no longer exists is not ours to take in.
        let goneKey = Room.key("main", project: "p-smoke-removed")
        Room.shared.observe(key: goneKey, messages: [
            ["role": "assistant", "content": [["type": "text", "text": "orphan"]],
             "__openclaw": ["seq": 1]]])
        check("a backfill for a removed project is ignored, not filed somewhere",
              Room.shared.doc("p-smoke-removed").messages.isEmpty
              && Room.shared.doc(pProbe).messages.count == 1)
        // …and the case the broken version of this test walked into. A clone
        // session that does not exist yet answers chat.history with nothing, so
        // it is seeded at 0 — which is correct, there is nothing to replay — and
        // the turns it produces once it DOES exist must still arrive. Getting
        // this wrong either loses every turn in a freshly created thread (seed
        // too high) or replays history on every launch (never seed).
        let freshLane = "smoke-\(UUID().uuidString.prefix(8).lowercased())"
        Room.shared.setProjects([Prefs.Project(id: pProbe, name: "Probe",
                                               access: roster + [probeLane, freshLane],
                                               clones: [Prefs.Clone(id: probeLane),
                                                        Prefs.Clone(id: freshLane)])])
        let freshKey = Room.key(freshLane, project: pProbe)
        let midpoint = Room.shared.doc(pProbe).messages.count
        Room.shared.observe(key: freshKey, messages: [])
        check("a clone session that does not exist yet seeds at zero",
              Room.shared.doc(pProbe).seen[freshKey] == 0
              && Room.shared.doc(pProbe).messages.count == midpoint,
              "seen=\(Room.shared.doc(pProbe).seen[freshKey].map(String.init) ?? "nil")")
        Room.shared.observe(key: freshKey, messages: [
            ["role": "assistant", "content": [["type": "text", "text": "first turn ever"]],
             "__openclaw": ["seq": 1]]])
        check("the first turn in a newly created clone thread still arrives",
              Room.shared.doc(pProbe).messages.count == midpoint + 1
              && Room.shared.doc(pProbe).messages.last?.text == "first turn ever",
              "n=\(Room.shared.doc(pProbe).messages.count) midpoint=\(midpoint)")

        // ---- a relay that never left the socket must not read as delivered ----
        //
        // deliver() recorded the turn, handed the text to Gateway and returned.
        // If the socket was down the frame was dropped and the 30s timeout went
        // to the PAGE as a writeResult; the room, which draws from its own
        // document, kept showing a hand-off with a target chip that had reached
        // nobody. Gateway now routes every `room-` write result back into the
        // room, and a failure is a visible row rather than nothing.
        let beforeFail = Room.shared.doc(pProbe).messages.count
        Room.shared.debugTrackInflight(requestId: "room-smoke-fail",
                                       project: pProbe, target: "backend-design")
        Room.shared.sendFailed(requestId: "room-smoke-fail",
                               code: "TIMEOUT", message: "chat.send did not answer within 30s")
        let failRow = Room.shared.doc(pProbe).messages.last
        check("a room send that did not land says so in the transcript",
              Room.shared.doc(pProbe).messages.count == beforeFail + 1 && failRow?.kind == "error",
              "n=\(Room.shared.doc(pProbe).messages.count) kind=\(failRow?.kind ?? "nil")")
        check("and it names the failure rather than just failing",
              (failRow?.text ?? "").contains("TIMEOUT")
              && (failRow?.text ?? "").contains("never reached the gateway"),
              failRow?.text ?? "")
        check("and it names the lane it did not reach",
              (failRow?.text ?? "").contains("@backend-design"), failRow?.text ?? "")
        // A failure for a request nobody is holding has no project to be
        // reported into, and inventing one would tell him a lie about which room
        // lost a message.
        let beforeOrphan = Room.shared.doc(pProbe).messages.count
        Room.shared.sendFailed(requestId: "room-not-a-real-request",
                               code: "TIMEOUT", message: "unheld")
        check("a failure for an untracked request is dropped, not blamed on a room",
              Room.shared.doc(pProbe).messages.count == beforeOrphan)
        // The success path is silent, which is the point: a landed relay is the
        // turn already in the transcript, not a second row about it.
        let beforeLanded = Room.shared.doc(pProbe).messages.count
        Room.shared.sendLanded(requestId: "room-smoke-fail")
        check("a relay that landed adds no second row",
              Room.shared.doc(pProbe).messages.count == beforeLanded,
              "n=\(Room.shared.doc(pProbe).messages.count)")

        // ORDER MATTERS, AND IT IS THIS WAY ROUND.
        //
        // `setProjects` PRUNES: it drops the room of any project not in the list
        // it is given, which is what makes removing a project remove its
        // transcript. So restoring projects after restoring the store deletes
        // exactly the rooms the restore just put back — and it did, for any room
        // belonging to a project the PAGE had created through the real prefs
        // bridge (the fixtures do: `reconcileRosters` saves, and BridgeApp's
        // `prefs` case hands the result straight to `setProjects`). `restore` is
        // the last word on the store, so it goes last.
        Room.shared.setProjects(projectsBefore)
        Room.shared.restore(roomStoreBefore)
        Prefs.directoryOverride = realDir
        check("the isolation fixtures put Room's store back",
              Room.shared.store == roomStoreBefore,
              "beforeRooms=\(roomStoreBefore.rooms.keys.sorted()) beforeV=\(roomStoreBefore.version) "
              + "afterRooms=\(Room.shared.store.rooms.keys.sorted()) afterV=\(Room.shared.store.version)")
        check("and its project list back",
              Room.shared.projects == projectsBefore,
              "before=\(projectsBefore.map { $0.id }) after=\(Room.shared.projects.map { $0.id })")
        let roomBytesAfter = try? Data(contentsOf: Room.url)
        check("and never touched his real room.json at all",
              roomBytesAfter == roomBytesBefore,
              "before=\(roomBytesBefore?.count ?? -1) after=\(roomBytesAfter?.count ?? -1)")

        // ---- the room, rendered ----------------------------------------------
        // The payload is now keyed by PROJECT, and the fixture carries TWO of
        // them: one with the exchange in it and one empty. A one-project fixture
        // cannot tell the difference between "this project's room" and "the
        // room", which is the exact distinction this pass introduced.
        let roomFixture = """
        window.__bridgeEmit({type:'room', maxHops:6, maxRelays:14, relayWindowMin:5,
          sharedMemory:'~/.openclaw/workspace/memory/bridge/SHARED.md',
          memoryRoot:'~/.openclaw/workspace/memory/bridge',
          rooms:{
            'p-bridge':{
              paused:false, pauseReason:'', relaysInWindow:2,
              access:['main','frontend-design','backend-design','coursework'],
              agents:[{id:'main',name:'Thuban',key:'agent:main:bridge:p-bridge'},
                      {id:'frontend-design',name:'Frontend Design',
                       key:'agent:frontend-design:bridge:p-bridge'},
                      {id:'backend-design',name:'Backend Design',
                       key:'agent:backend-design:bridge:p-bridge'},
                      {id:'coursework',name:'Coursework',key:'agent:coursework:bridge:p-bridge'}],
              messages:[
                {id:'m1',at:Date.now()-40000,from:'chancellor',to:['frontend-design'],
                 text:'Build the composer for the room.',kind:'say',hop:0},
                // One turn, two hand-offs. The row must show BOTH — collapsing a
                // reply's targets to the first one loses the second silently.
                {id:'m2',at:Date.now()-30000,from:'frontend-design',
                 to:['backend-design','coursework'],
                 text:'Composer is in. @backend-design rate limit, @coursework review.',
                 kind:'say',hop:1},
                {id:'m3',at:Date.now()-20000,from:'backend-design',to:[],
                 text:'Rate limit landed. Nothing else needed from me.',kind:'say',hop:2},
                {id:'m4',at:Date.now()-10000,from:'bridge',to:[],
                 text:'Relay paused: too many hand-offs.',kind:'note',hop:0}]},
            'p-atlas':{ paused:false, pauseReason:'', relaysInWindow:0, agents:[], messages:[] }}});
        S.roomPing = null;
        openProjectRoom('p-bridge');
        true
        """
        _ = try? await web.evaluateJavaScript(roomFixture)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let roomDom = (try? await web.evaluateJavaScript("""
          (function(){
            const r=(s)=>{const n=document.querySelector(s);return n?n.getBoundingClientRect():null};
            const tx=r('.tx'), foot=r('.foot'), c=r('.content');
            return JSON.stringify({
              rows: document.querySelectorAll('.rm').length,
              handoffs: [...document.querySelectorAll('.rm-to')].map(n=>n.textContent),
              hops: [...document.querySelectorAll('.rm-hop')].map(n=>n.textContent),
              navTabs: document.querySelectorAll('#page-tabs .page-tab').length,
              pingTabs: document.querySelectorAll('.foot .ping-b').length,
              noteText: (document.querySelector('.foot .note')||{}).textContent||'',
              viewport: window.innerHeight,
              tx: tx?Math.round(tx.height):-1, footH: foot?Math.round(foot.height):-1,
              footBottom: foot?Math.round(foot.bottom):-1,
              footScrolls: foot?(document.querySelector('.foot').scrollHeight
                                 > document.querySelector('.foot').clientHeight+4):false,
              footNatural: foot?document.querySelector('.foot').scrollHeight:-1,
              contentBottom: c?Math.round(c.bottom):-1,
              overflowX: document.documentElement.scrollWidth - document.documentElement.clientWidth });
          })()
        """)) as? String ?? "{}"
        let RM = (try? JSONSerialization.jsonObject(with: Data(roomDom.utf8))) as? [String: Any] ?? [:]
        check("the room draws every turn regardless of who it was addressed to",
              (RM["rows"] as? Int ?? 0) == 4, roomDom)
        check("every hand-off in a turn is named, not just the first",
              (RM["handoffs"] as? [String] ?? [])
                == ["→ @frontend-design", "→ @backend-design", "→ @coursework"], roomDom)
        check("a turn that hands off to nobody shows no target chip",
              (RM["handoffs"] as? [String] ?? []).count == 3, roomDom)
        check("hop depth is drawn only once a message is no longer Chancellor's",
              (RM["hops"] as? [String] ?? []) == ["hop 1", "hop 2"], roomDom)
        // The topbar is the project's page-tabs now — the room plus one per
        // agent — rather than a second copy of the agent strip. Five tabs for
        // the five-agent fixture: room, and four launched clones after main.
        check("the topbar carries the project's tabs while its room is open",
              (RM["navTabs"] as? Int ?? 0) == 5, roomDom)
        // No ping buttons in the room composer: you address a teammate by typing
        // @<agent>, the same handle the relay parses out of a reply.
        check("the room composer has no ping buttons",
              (RM["pingTabs"] as? Int ?? -1) == 0, roomDom)
        check("the composer explains that you address an agent by typing @",
              (RM["noteText"] as? String ?? "").contains("Type @")
              && (RM["noteText"] as? String ?? "").contains("main (Thuban)"), roomDom)

        // Geometry. The room has a taller composer than an agent pane — the ping
        // bar, the note, two metadata rows — which is the exact shape of the bug
        // that has now collapsed this transcript four times.
        let rvp = RM["viewport"] as? Int ?? 0
        check("room: the transcript keeps its floor", (RM["tx"] as? Int ?? -1) >= 200, roomDom)
        // THE MIRROR ASSERTION, CALIBRATED TO THIS COMPOSER RATHER THAN THE
        // OTHER ONE. An agent pane's composer is ~380px natural — queue,
        // command chips, palette slot, warning — so its check is `>= 300`. The
        // room's is ~208px natural, because it has none of those: a header, the
        // ping bar, the input, one note and two metadata rows. Asserting 300
        // here failed on a composer that was not crushed at all, which is a
        // check measuring the wrong thing rather than a layout that is wrong.
        //
        // "Crushed" has an exact meaning and this is it: the flex algorithm took
        // height the composer needed, so it now has an inner scrollbar and the
        // send button is behind it. That is what is asserted, plus a sanity
        // floor that everything named above is actually present.
        //
        // AND THE SANITY FLOOR IS NOW THE NATURAL HEIGHT, NOT A THIRD HAND-TUNED
        // NUMBER. This is the second time this literal has gone stale: 300 was
        // wrong because the room composer is shorter than an agent pane's, 180
        // became wrong when pass 12's short-window shed dropped this composer's
        // natural height from 208 to 129 at the 900px web view — footScrolls
        // false, nothing crushed, the assertion red anyway. Re-tuning it a third
        // time would just schedule the next failure. `footNatural` is the
        // quantity every one of these numbers was approximating.
        let roomNat = RM["footNatural"] as? Int ?? -1
        let roomFootH = RM["footH"] as? Int ?? -1
        check("room: the composer is not crushed",
              (RM["footScrolls"] as? Bool ?? true) == false
                && roomNat > 0 && roomFootH >= roomNat - 4,
              "foot=\(roomFootH) natural=\(roomNat) " + roomDom)
        check("room: the composer stays inside the window",
              (RM["footBottom"] as? Int ?? -1) > 0 && (RM["footBottom"] as? Int ?? 0) <= rvp + 2, roomDom)
        check("room: nothing overflows horizontally", (RM["overflowX"] as? Int ?? 1) <= 0, roomDom)

        // Addressing by typing @: the routing the ping buttons used to do is now
        // parsed from the text at send time. Stub the bridge to capture what
        // roomSend hands over, for an @-addressed message and a bare one.
        let roomPing = (try? await web.evaluateJavaScript("""
          (function(){
            const sent=[]; const real=window.__bridgeSend;
            window.__bridgeSend=(m)=>{ sent.push(m); return true; };
            S.roomDraft='rate limit please @backend-design'; roomSend('p-bridge');
            S.roomDraft='just a note for the room'; roomSend('p-bridge');
            window.__bridgeSend=real;
            const rs=sent.filter(x=>x.t==='room.send');
            return JSON.stringify({
              addressed: rs[0]?rs[0].ping:'MISSING',
              bare: rs[1]?(rs[1].ping===null?'null':rs[1].ping):'MISSING',
              note: (document.querySelector('.foot .note')||{}).textContent||'' });
          })()
        """)) as? String ?? "{}"
        let RP = (try? JSONSerialization.jsonObject(with: Data(roomPing.utf8))) as? [String: Any] ?? [:]
        check("typing @backend-design addresses that agent",
              (RP["addressed"] as? String ?? "") == "backend-design", roomPing)
        check("a message with no @ goes to main",
              (RP["bare"] as? String ?? "") == "null", roomPing)
        check("the composer note explains the @ convention",
              (RP["note"] as? String ?? "").contains("Type @"), roomPing)

        // ---- questions: the real record, the real two ids ---------------------
        let qFixture = """
        window.__bridgeEmit({type:'questions', replace:true, questions:[{
          id:'ask_1234567890abcdef1234567890abcdef', status:'pending',
          agentId:'backend-design', sessionKey:'agent:backend-design:bridge',
          createdAtMs: Date.now()-5000, expiresAtMs: Date.now()+880000,
          questions:[{questionId:'q-schema', header:'Schema choice',
            question:'Store the room transcript in SQLite or as JSON on disk?',
            options:[{label:'SQLite',description:'queryable'},{label:'JSON',description:'inspectable'}],
            multiSelect:false, isSecret:false, isOther:true}]}]});
        openInbox();
        true
        """
        _ = try? await web.evaluateJavaScript(qFixture)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let qDom = (try? await web.evaluateJavaScript("""
          JSON.stringify({ rows: document.querySelectorAll('.ibx-q').length,
            buttons: [...document.querySelectorAll('.ibx-q .ask-btn')].map(b=>b.textContent),
            freeText: document.querySelectorAll('.ibx-q .q-in').length,
            unread: (document.querySelector('.nav__unread')||{}).textContent||'0',
            why: !!document.querySelector('.inbox-why'),
            text: (document.querySelector('.ibx-q')||{}).textContent||'' })
        """)) as? String ?? "{}"
        let QD = (try? JSONSerialization.jsonObject(with: Data(qDom.utf8))) as? [String: Any] ?? [:]
        check("a real question is drawn in the inbox", (QD["rows"] as? Int ?? 0) == 1, qDom)
        check("its options are rendered as buttons",
              (QD["buttons"] as? [String] ?? []) == ["SQLite", "JSON"], qDom)
        check("an isOther question also offers a free-text answer",
              (QD["freeText"] as? Int ?? 0) == 1, qDom)
        check("a pending question shows its expiry", (QD["text"] as? String ?? "").contains("expires in"), qDom)
        check("the Phase B 'no question can arrive' panel is gone once one has",
              !(QD["why"] as? Bool ?? true), qDom)
        check("the question states what it is asking",
              (QD["text"] as? String ?? "").contains("SQLite or as JSON"), qDom)

        // THE TWO IDS. `question.resolve`'s answers map is keyed by the INNER
        // questionId; sending the record id there is accepted and answers
        // nothing. This asserts what actually goes on the wire.
        let qSend = (try? await web.evaluateJavaScript("""
          (function(){
            window.__sent = [];
            document.querySelector('.ibx-q .ask-btn').click();
            const m = (window.__sent||[]).find(x=>x.t==='question.resolve') || {};
            return JSON.stringify({ id: m.id||'', questionId: m.questionId||'', value: m.value||'',
              inFlight: !!document.querySelector('.ibx-q .wr[data-k="wait"]') });
          })()
        """)) as? String ?? "{}"
        let QS = (try? JSONSerialization.jsonObject(with: Data(qSend.utf8))) as? [String: Any] ?? [:]
        check("answering sends the RECORD id",
              (QS["id"] as? String ?? "") == "ask_1234567890abcdef1234567890abcdef", qSend)
        check("answering sends the INNER question id, which is a different string",
              (QS["questionId"] as? String ?? "") == "q-schema", qSend)
        check("answering sends the chosen option label", (QS["value"] as? String ?? "") == "SQLite", qSend)
        check("answering shows an in-flight state", (QS["inFlight"] as? Bool ?? false), qSend)
        // Answered elsewhere -> the row goes, rather than keeping a button whose
        // only possible outcome is QUESTION_ALREADY_TERMINAL.
        _ = try? await web.evaluateJavaScript("""
          window.__bridgeEmit({type:'questionResolved',id:'ask_1234567890abcdef1234567890abcdef',
            status:'answered'}); true
        """)
        try? await Task.sleep(nanoseconds: 250_000_000)
        let qGone = (try? await web.evaluateJavaScript(
            "document.querySelectorAll('.ibx-q').length")) as? Int ?? -1
        check("a question resolved anywhere disappears here", qGone == 0, "rows=\(qGone)")

        // ---- elapsed: running ticks, finished freezes -------------------------
        let elapsed = (try? await web.evaluateJavaScript("""
          JSON.stringify({ running: elapsedText(-100, null, true),
                           finished: elapsedText(-3000, -120, false),
                           unstarted: elapsedText(null, null, false),
                           frozenAgain: elapsedText(-3000, -120, false) })
        """)) as? String ?? "{}"
        let EL = (try? JSONSerialization.jsonObject(with: Data(elapsed.utf8))) as? [String: Any] ?? [:]
        check("a running task ticks from its start and says so",
              (EL["running"] as? String ?? "").hasSuffix("…"), elapsed)
        // 2880s between start and end -> 48m. The number is the WORK's duration,
        // and it must not contain "ago" — that is a fact about the clock.
        check("a finished task freezes at its total duration",
              (EL["finished"] as? String ?? "") == "48m 00s"
              && !(EL["finished"] as? String ?? "").contains("ago"), elapsed)
        check("the frozen total does not move", (EL["finished"] as? String ?? "x")
              == (EL["frozenAgain"] as? String ?? "y"), elapsed)
        check("a task that never started says so rather than showing 0s",
              (EL["unstarted"] as? String ?? "") == "—", elapsed)

        // ---- context: the used count, alone -----------------------------------
        _ = try? await web.evaluateJavaScript("S.view='sessions'; window.__focusReal(); true")
        try? await Task.sleep(nanoseconds: 250_000_000)
        let ctx = (try? await web.evaluateJavaScript("""
          (function(){
            const u = document.querySelector('.p-use');
            return JSON.stringify({ text: u?u.textContent:'',
              bars: document.querySelectorAll('.p-use progress, .p-use meter, .ctx-bar').length });
          })()
        """)) as? String ?? "{}"
        let CX = (try? JSONSerialization.jsonObject(with: Data(ctx.utf8))) as? [String: Any] ?? [:]
        let ctext = CX["text"] as? String ?? ""
        check("context is labelled and shows a token count", ctext.contains("context"), ctext)
        check("no context maximum is printed", !ctext.contains("context window"), ctext)
        check("no percentage and no fill bar", !ctext.contains("%") && (CX["bars"] as? Int ?? 1) == 0, ctext)

        // Everything the error trap caught, named. This runs late so it covers
        // every render above it.
        let errs = (try? await web.evaluateJavaScript(
            "JSON.stringify(window.__errs || [])")) as? String ?? "[]"
        check("no render threw an uncaught exception anywhere in this run",
              errs == "[]", errs)

        // ---- hold space to talk: the arming rule ------------------------------
        //
        // The one thing about this feature that is easy to get wrong and
        // impossible to miss when it is: space must still type a space once
        // there is anything in the box.
        let armed = (try? await web.evaluateJavaScript("""
          (function(){
            const ev = (k, extra) => Object.assign({key:k, repeat:false, metaKey:false,
              ctrlKey:false, altKey:false}, extra||{});
            return JSON.stringify({
              emptyArms:        voiceArmed(ev(' '), ''),
              nonEmptyDoesNot:  voiceArmed(ev(' '), 'hello'),
              oneCharDoesNot:   voiceArmed(ev(' '), ' '),
              repeatDoesNot:    voiceArmed(ev(' ', {repeat:true}), ''),
              modifierDoesNot:  voiceArmed(ev(' ', {metaKey:true}), ''),
              otherKeyDoesNot:  voiceArmed(ev('a'), '') });
          })()
        """)) as? String ?? "{}"
        let AR = (try? JSONSerialization.jsonObject(with: Data(armed.utf8))) as? [String: Any] ?? [:]
        check("space in an EMPTY composer arms dictation", (AR["emptyArms"] as? Bool ?? false), armed)
        check("space in a non-empty composer types a space", !(AR["nonEmptyDoesNot"] as? Bool ?? true), armed)
        check("even one existing character disarms it", !(AR["oneCharDoesNot"] as? Bool ?? true), armed)
        check("key repeat does not re-arm mid-hold", !(AR["repeatDoesNot"] as? Bool ?? true), armed)
        check("a modified space is a shortcut, not dictation", !(AR["modifierDoesNot"] as? Bool ?? true), armed)
        check("no other key arms it", !(AR["otherKeyDoesNot"] as? Bool ?? true), armed)
        // ---- hold space to talk: a hold that is superseded still delivers -----
        //
        // The arming rule above is why the space bar still works. THIS is why
        // the second sentence you dictate does not eat the first.
        //
        // Releasing space leaves the composer empty, which re-arms it instantly,
        // while whisper is still working on the hold just released. Press space
        // again — two sentences, the ordinary way — and the first hold's result
        // came back to a page whose VOICE.requestId had already moved on. The
        // old guard covered the indicator and the text with one `break`, so the
        // sentence was discarded with no text and no error.
        //
        // Driven through the REAL page functions, not a model of them: the same
        // voiceStart / voiceStop / __bridgeEmit the app uses. The room case is
        // in here because the routing claim is the interesting half — a late
        // answer must land in the box it was SPOKEN at, not in whatever is on
        // screen when it arrives.
        let vseq = (try? await web.evaluateJavaScript("""
          (function(){
            const snapDraft = JSON.stringify(S.draft), snapRoom = S.roomDraft;
            const rid = () => VOICE.requestId;
            S.draft = {}; S.roomDraft = '';
            VOICE.state='idle'; VOICE.requestId=null; VOICE.target=null;
            VOICE.pending = Object.create(null);
            const emit = (m) => window.__bridgeEmit(Object.assign({type:'voice'}, m));

            voiceStart('lane-a');            const a = rid();
            emit({requestId:a, state:'recording'});
            voiceStop();                     // released; whisper still running
            voiceStart('lane-b');            const b = rid();
            emit({requestId:b, state:'recording'});
            const midState = VOICE.state;
            emit({requestId:a, state:'done', text:'the superseded sentence'});
            const laneA = S.draft['lane-a'] || '';
            const indicatorHeld = VOICE.state;

            // and a hold dictated AT THE ROOM, answered after the user moved on
            VOICE.state='idle'; VOICE.requestId=null;
            voiceStart('__room__');          const c = rid();
            emit({requestId:c, state:'recording'});
            voiceStop();
            voiceStart('lane-c');            const d = rid();
            emit({requestId:d, state:'recording'});
            emit({requestId:c, state:'done', text:'spoken at the room'});

            const out = JSON.stringify({
              laneA, indicatorHeld, midState,
              roomGot: S.roomDraft || '',
              laneCGot: S.draft['lane-c'] || '',
              pendingLeft: Object.keys(VOICE.pending).length });
            S.draft = JSON.parse(snapDraft); S.roomDraft = snapRoom;
            VOICE.state='idle'; VOICE.requestId=null; VOICE.target=null;
            VOICE.pending = Object.create(null);
            renderAll();
            return out;
          })()
        """)) as? String ?? "{}"
        let VS = (try? JSONSerialization.jsonObject(with: Data(vseq.utf8))) as? [String: Any] ?? [:]
        check("a hold superseded by the next one still delivers its text",
              (VS["laneA"] as? String) == "the superseded sentence", vseq)
        check("and its late answer does not wipe the live hold's indicator",
              (VS["indicatorHeld"] as? String) == "recording"
                && (VS["midState"] as? String) == "recording", vseq)
        check("a late transcript lands in the composer it was spoken at",
              (VS["roomGot"] as? String) == "spoken at the room"
                && (VS["laneCGot"] as? String ?? "").isEmpty, vseq)
        // ---- hold space to talk: one release must send exactly one stop -------
        //
        // The superseded-hold case above is a hold that loses its place to the
        // NEXT hold. This is the same sentence lost with no next hold at all.
        //
        // One release fires keyup. If the user then clicks anything - the send
        // button beside the box is the obvious one - the composer also fires
        // blur, and the blur handler's only guard is that a requestId exists.
        // It does: voiceStop leaves it set so the answer can be correlated, and
        // whisper is still running. So one hold sent two `voice stop` messages.
        //
        // Voice.swift `stop(requestId:)` clears `active` on the first. The
        // second fails `guard active == requestId` and takes the
        // no-matching-start path, which answers `idle` - terminal - so the page
        // retired VOICE.pending[rid] before the `done` carrying the text ever
        // arrived, and dropped the sentence with no text and no error.
        //
        // The fixture drives the REAL voiceStart/voiceStop and stubs
        // window.__bridgeSend to count what actually went to Swift. The `idle`
        // is emitted if and only if a second stop was sent, which is Voice.swift
        // `stop()`'s own rule restated - so a regression re-arms the trap rather
        // than quietly walking past it.
        let vdup = (try? await web.evaluateJavaScript("""
          (function(){
            const snapDraft = JSON.stringify(S.draft), snapRoom = S.roomDraft;
            const realSend = window.__bridgeSend;
            const sent = [];
            window.__bridgeSend = (m) => { sent.push(m); };
            S.draft = {}; S.roomDraft = '';
            VOICE.state='idle'; VOICE.requestId=null; VOICE.target=null;
            VOICE.pending = Object.create(null);
            const emit = (m) => window.__bridgeEmit(Object.assign({type:'voice'}, m));

            voiceStart('lane-r');            const r = VOICE.requestId;
            emit({requestId:r, state:'recording'});
            voiceStop();                     // keyup: space released
            voiceStop();                     // blur: the click onto `send`
            const stops = sent.filter((m) => m && m.t === 'voice'
                                          && m.phase === 'stop'
                                          && m.requestId === r).length;
            // Voice.swift answers a stop with no matching start by emitting idle.
            if (stops > 1) emit({requestId:r, state:'idle'});
            emit({requestId:r, state:'done', text:'the sentence I clicked away from'});

            const out = JSON.stringify({
              stops,
              got: S.draft['lane-r'] || '',
              endState: VOICE.state,
              ridCleared: VOICE.requestId === null,
              pendingLeft: Object.keys(VOICE.pending).length });
            window.__bridgeSend = realSend;
            S.draft = JSON.parse(snapDraft); S.roomDraft = snapRoom;
            VOICE.state='idle'; VOICE.requestId=null; VOICE.target=null;
            VOICE.pending = Object.create(null);
            renderAll();
            return out;
          })()
        """)) as? String ?? "{}"
        let VD = (try? JSONSerialization.jsonObject(with: Data(vdup.utf8))) as? [String: Any] ?? [:]
        check("one release sends exactly one voice stop",
              (VD["stops"] as? Int ?? 0) == 1, vdup)
        check("a hold released onto a click still delivers its sentence",
              (VD["got"] as? String) == "the sentence I clicked away from", vdup)
        check("and that hold retires cleanly - indicator done, nothing left pending",
              (VD["endState"] as? String) == "done"
                && (VD["ridCleared"] as? Bool ?? false)
                && (VD["pendingLeft"] as? Int ?? 1) == 0, vdup)

        // ---- the indicator a finished dictation leaves behind ----------------
        //
        // The block above ends with endState == "done" and calls that clean.
        // It is clean in the model and was not clean on screen. Voice.swift
        // emits `done` and then nothing — there is no trailing `idle` — so
        // VOICE.state rests on 'done' until the next hold. VoiceState() had a
        // branch for 'idle', 'error' and 'empty' and none for 'done', so 'done'
        // fell through to the generic tail whose label expression reads
        //   st === 'recording' ? 'recording' : st === 'arming' ? … : 'transcribing'
        // and the composer went on announcing TRANSCRIBING, with the whisper
        // model named beside it, for as long as the window stayed open.
        //
        // Nine passes measured this composer and none of them looked at it. The
        // assertion is on the rendered text for that reason: `endState=="done"`
        // was true both before and after the fix and says nothing about what is
        // drawn, which is where the whole defect lived.
        let vind = (try? await web.evaluateJavaScript("""
          (function(){
            const snapDraft = JSON.stringify(S.draft);
            const realSend = window.__bridgeSend;
            window.__bridgeSend = () => {};   // no microphone is opened here
            S.draft = {};
            VOICE.state='idle'; VOICE.requestId=null; VOICE.target=null;
            VOICE.pending = Object.create(null);
            const emit = (m) => window.__bridgeEmit(Object.assign({type:'voice'}, m));
            const txt = (n) => n ? (n.textContent || '').trim() : null;

            voiceStart('lane-v');            const r = VOICE.requestId;
            emit({requestId:r, state:'recording'});
            const during = txt(VoiceState('lane-v'));
            voiceStop();
            emit({requestId:r, state:'transcribing'});
            const mid = txt(VoiceState('lane-v'));
            emit({requestId:r, state:'done', text:'the sentence that landed'});
            const after = txt(VoiceState('lane-v'));

            const out = JSON.stringify({
              during: during, mid: mid, after: after,
              got: S.draft['lane-v'] || '', endState: VOICE.state });
            window.__bridgeSend = realSend;
            S.draft = JSON.parse(snapDraft);
            VOICE.state='idle'; VOICE.requestId=null; VOICE.target=null;
            VOICE.pending = Object.create(null);
            renderAll();
            return out;
          })()
        """)) as? String ?? "{}"
        let VI = (try? JSONSerialization.jsonObject(with: Data(vind.utf8))) as? [String: Any] ?? [:]
        // Kept deliberately although it passes on both sides: it is the guard
        // against "fixing" the stuck banner by never drawing the indicator at
        // all, which would hide an open microphone — strictly worse than the bug.
        check("an open microphone is announced while it is open",
              (VI["during"] as? String ?? "").contains("recording"), vind)
        check("and the wait for whisper is announced while it is waiting",
              (VI["mid"] as? String ?? "").contains("transcribing"), vind)
        check("a finished dictation leaves no indicator behind",
              VI["after"] is NSNull || VI["after"] == nil, vind)
        check("a finished dictation never claims to still be transcribing",
              !((VI["after"] as? String ?? "").contains("transcribing"))
                && (VI["got"] as? String) == "the sentence that landed", vind)

        // ---- and the two notices that outlive everything ---------------------
        //
        // Pass 10 stopped drawing `done` and left `empty` and `error` alone,
        // on the grounds that for those two the banner is the only report the
        // user gets. True, and it is not an argument for keeping them on screen
        // forever — which is what "nothing clears them but the next hold" means
        // for someone who holds space once, hears nothing, and types instead.
        //
        // The frame that is actually wrong: `nothing heard — the hold produced
        // no speech, nothing was inserted` sitting above a composer the user
        // has since typed a sentence into by hand. The notice is about the
        // hold; on screen it reads as being about the text under it.
        //
        // Asserted through voiceAck, which is what the composer's oninput now
        // calls, and asserted on the RENDERED node rather than on VOICE.state,
        // for the reason the block above exists.
        let vack = (try? await web.evaluateJavaScript("""
          (function(){
            const snap = JSON.stringify(S.draft);
            VOICE.state='idle'; VOICE.requestId=null; VOICE.target=null;
            const txt = (n) => n ? (n.textContent || '').trim() : null;
            // Tolerant so this fixture is runnable on the PRE-FIX tree, where
            // voiceAck does not exist yet: the three guards then still report,
            // and only the three defect assertions fail.
            const ack = (t) => (typeof voiceAck === 'function') ? voiceAck(t) : false;
            const put = (st) => { VOICE.target='lane-a'; VOICE.state=st;
                                  VOICE.error = st==='error' ? 'the microphone is in use by another app' : null; };

            put('empty');
            const emptyShown = txt(VoiceState('lane-a'));
            const otherLane  = txt(VoiceState('lane-b'));     // must never draw here
            const ackedOther = ack('lane-b');            // typing in a DIFFERENT composer
            const afterOther = txt(VoiceState('lane-a'));     // ...must not clear this one
            const ackedEmpty = ack('lane-a');
            const afterEmpty = txt(VoiceState('lane-a'));

            put('error');
            const errShown = txt(VoiceState('lane-a'));
            ack('lane-a');
            const afterErr = txt(VoiceState('lane-a'));

            // An open microphone is not dismissible by typing.
            VOICE.target='lane-a'; VOICE.state='recording'; VOICE.at = nowS();
            const ackedRec = ack('lane-a');
            const afterRec = txt(VoiceState('lane-a'));
            VOICE.target='lane-a'; VOICE.state='transcribing';
            ack('lane-a');
            const afterTx = txt(VoiceState('lane-a'));

            const out = JSON.stringify({
              emptyShown: emptyShown, otherLane: otherLane,
              ackedOther: ackedOther, afterOther: afterOther,
              ackedEmpty: ackedEmpty, afterEmpty: afterEmpty,
              errShown: errShown, afterErr: afterErr,
              ackedRec: ackedRec, afterRec: afterRec, afterTx: afterTx });
            VOICE.state='idle'; VOICE.requestId=null; VOICE.target=null; VOICE.error=null;
            S.draft = JSON.parse(snap);
            renderAll();
            return out;
          })()
        """)) as? String ?? "{}"
        let VA = (try? JSONSerialization.jsonObject(with: Data(vack.utf8))) as? [String: Any] ?? [:]
        // Guards. These pass on both sides and are the point: the wrong fix for
        // a notice that overstays is to stop drawing it, and that would take
        // the only report of a failed dictation with it.
        check("a hold that heard nothing still says so",
              (VA["emptyShown"] as? String ?? "").contains("nothing heard"), vack)
        check("and a failed hold still reports the reason",
              (VA["errShown"] as? String ?? "").contains("microphone is in use"), vack)
        check("an open microphone cannot be typed away",
              (VA["ackedRec"] as? Bool ?? true) == false
                && (VA["afterRec"] as? String ?? "").contains("recording")
                && (VA["afterTx"] as? String ?? "").contains("transcribing"), vack)
        // The defect.
        check("a nothing-heard notice is retired when the user types instead",
              (VA["ackedEmpty"] as? Bool ?? false)
                && (VA["afterEmpty"] is NSNull || VA["afterEmpty"] == nil), vack)
        check("and a voice error is retired the same way",
              VA["afterErr"] is NSNull || VA["afterErr"] == nil, vack)
        check("typing in one composer does not clear another composer's notice",
              (VA["ackedOther"] as? Bool ?? true) == false
                && (VA["otherLane"] is NSNull || VA["otherLane"] == nil)
                && (VA["afterOther"] as? String ?? "").contains("nothing heard"), vack)
        // Two left, and both are correct: the lane-b hold and the lane-c hold
        // were never given a terminal state by this fixture — which is exactly
        // the "still in flight" case the map exists to hold. The four that DID
        // resolve are gone.
        check("resolved holds are dropped from the in-flight map",
              (VS["pendingLeft"] as? Int) == 2, vseq)

        // ---- the navigation policy is an allow-list ---------------------------
        //
        // The rule is "Bridge never navigates away from its own origin". The
        // old guard fell through to .allow for every scheme that was not http
        // or https, so file:, data:, javascript: and blob: were all permitted —
        // the precise set the rule exists to exclude. Asserted by scheme now,
        // because a comment is not an enforcement mechanism.
        let nav = BridgeWebView.Coordinator()
        func policy(_ raw: String) async -> WKNavigationActionPolicy {
            await withCheckedContinuation { cont in
                nav.webView(web, decidePolicyFor: TestNavigationAction(url: URL(string: raw)!)) {
                    cont.resume(returning: $0)
                }
            }
        }
        let ownOrigin = await policy("http://127.0.0.1:\(LocalServer.shared.port)/index.html")
        check("its own origin still loads", ownOrigin == .allow, "\(ownOrigin.rawValue)")
        var refused: [String] = []
        for raw in ["file:///etc/passwd",
                    "data:text/html,<h1>not%20bridge",
                    "javascript:alert(1)",
                    "blob:http://127.0.0.1/9f2",
                    "ftp://example.com/x"] {
            if await policy(raw) != .cancel { refused.append(raw) }
        }
        check("file:, data:, javascript:, blob: and unknown schemes are refused",
              refused.isEmpty, refused.isEmpty ? "5 schemes cancelled" : "ALLOWED: \(refused)")
        let ext = await policy("https://claw.myatlasapp.net/")
        check("an outbound https link is cancelled here and handed to the browser",
              ext == .cancel, "\(ext.rawValue)")

        // ---- the two child-process shapes, driven against real children -------
        //
        // Neither defect is visible in anything the app prints. One is a hung
        // thread and no transcript; the other is a pinned CPU core. Both are
        // exercised against real /bin/sh children rather than modelled.

        // A child that floods stderr while its answer is on stdout. Reading
        // stdout to EOF first deadlocks: the child blocks on a full 64 KiB
        // stderr pipe and never closes stdout. That is whisper-cli's exact shape
        // — model-load and timing chatter on stderr, transcript on stdout — so
        // the failure was a hold that produced no text, ever, and leaked a
        // thread each time it happened.
        let flood = "yes 'stderr noise to fill the pipe buffer' | head -20000 1>&2; echo TRANSCRIPT"
        let runBox = LineBox()
        Voice.shared.run(URL(fileURLWithPath: "/bin/sh"), ["-c", flood]) { out, _ in
            runBox.set(out ?? "")
        }
        for _ in 0..<80 where !runBox.settled { try? await Task.sleep(nanoseconds: 100_000_000) }
        let gotTranscript = runBox.value.trimmingCharacters(in: .whitespacesAndNewlines)
        check("a subprocess that floods stderr does not deadlock the read",
              runBox.settled && gotTranscript == "TRANSCRIPT",
              runBox.settled ? "stdout=\(gotTranscript)" : "STILL BLOCKED after 8s - the deadlock is back")

        // The ssh stderr handler must RELEASE ITSELF once the write end closes.
        // A readabilityHandler that is never cleared is re-signalled with empty
        // data forever — measured on this Mac at 741,795 invocations in the
        // first second after the child exited, which is a pinned core for as
        // long as the pipe lives. ssh dying on its own (wifi drop,
        // ServerAliveCountMax, laptop sleep) reaches exactly that state, and
        // nothing in terminationHandler releases the process. The handler being
        // nil afterwards IS the property; a count would only be a proxy for it.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "echo 'ssh: connect to host atlas port 22: Network is unreachable' 1>&2"]
        let cerr = Pipe()
        child.standardError = cerr
        let said = LineBox()
        Tunnel.drainStderr(cerr.fileHandleForReading) { said.set($0) }
        try? child.run()
        child.waitUntilExit()
        for _ in 0..<40 where cerr.fileHandleForReading.readabilityHandler != nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let handlerReleased = cerr.fileHandleForReading.readabilityHandler == nil
        check("the ssh stderr handler releases itself at EOF instead of spinning",
              handlerReleased,
              handlerReleased ? "released"
                              : "STILL ATTACHED after 2s - every empty wake is a busy loop")
        check("and it still reports what ssh actually said",
              said.value.contains("Network is unreachable"), "last=\(said.value)")

        check("dictation has a transcription route", !Voice.describe().isEmpty,
              "route=\(Voice.describe()["route"] as? String ?? "?") "
              + "model=\(Voice.describe()["model"] as? String ?? "-")")
        if Voice.localAvailable {
            check("whisper runs on this Mac", true,
                  "\(Voice.binary?.path ?? "") + \(Voice.model?.lastPathComponent ?? "")")
        } else {
            skip("local whisper", "no whisper binary or model — dictation falls back to the gateway host")
        }

        // ---- an empty tool tab states what it would hold -----------------------
        let toolTab = (try? await web.evaluateJavaScript("""
          (function(){
            const c = CATEGORIES.find(x=>x.kind==='tool');
            if (!c) return JSON.stringify({none:true});
            S.view='sessions'; S.catId=c.id; S.sub=null; renderAll();
            const body = document.querySelector('.content');
            return JSON.stringify({ blank: (body.textContent||'').trim().length < 40,
              says: (body.textContent||'').length,
              hasPlan: !!document.querySelector('.plan, .empty-cat') });
          })()
        """)) as? String ?? "{}"
        let TT = (try? JSONSerialization.jsonObject(with: Data(toolTab.utf8))) as? [String: Any] ?? [:]
        if TT["none"] as? Bool == true {
            skip("an empty tool tab explains itself", "no tool tab in this build's prefs")
        } else {
            check("an empty tool tab is never blank", !(TT["blank"] as? Bool ?? true), toolTab)
            check("an empty tool tab says what it would hold", (TT["hasPlan"] as? Bool ?? false), toolTab)
        }

        // ---- live gateway ------------------------------------------------------
        if Keychain.token == nil {
            skip("live gateway handshake", "no token in the keychain (run Bridge --set-token)")
            skip("live session list", "no token in the keychain")
        } else {
            var status = ""
            var sessions = 0
            var detail = ""
            let done = expectLive { s, n, d in status = s; sessions = n; detail = d }
            Gateway.shared.start()
            _ = await done()
            check("live gateway handshake", status == "live", "status=\(status) detail=\(detail)")
            check("live session list is non-empty", sessions > 0, "\(sessions) sessions")
            if sessions > 0 { print("     sessions reported: \(sessions)") }
            Gateway.shared.stop()
        }
        // exit() below runs no termination handler, so the forward is torn down
        // here explicitly. The wrapper in Tunnel.swift is the belt; this is the
        // braces, and it keeps the port free for the next run immediately rather
        // than whenever the pipe happens to close.
        Tunnel.shared.stop()

        print(failed == 0 ? "\nsmoke: all good\(skipped > 0 ? " (\(skipped) skipped)" : "")"
                          : "\nsmoke: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    // ---- screenshot ---------------------------------------------------------
    //
    // `Bridge --shot <path>` boots the real app against the real Gateway, waits
    // for live data to land, and writes a PNG of what it actually drew. It
    // exists because a UI claim you have not looked at is not a claim, and
    // because `screencapture` of another app's window needs a Screen Recording
    // grant this machine has not given — this needs nothing.
    /// The JS that puts the app into each screenshot-able view. Keyed by the
    /// name passed as `--view`. These run against LIVE gateway data — the only
    /// synthetic values anywhere here are the two that cannot be real on an
    /// operator.read connection, and both are marked.
    static let views: [String: String] = [
        "sessions": "S.view='sessions'; renderAll(); true",

        "inbox": "openInbox(); true",

        "settings": "openSettings(); true",

        // The room with an "@" typed, so the agent type-ahead popover is open.
        // In-memory only: it sets S.roomDraft and re-renders, writing nothing.
        "roomat": """
          (function(){
            const c = CATEGORIES[0]; if (!c) return false;
            S.view = 'sessions'; S.catId = c.id; S.tab[c.id] = c.id + '::room'; S.sub = null;
            S.roomDraft = '@'; renderAll();
            return true;
          })()
        """,

        // The Tools section and a tool's blank page. The demo tool is pushed
        // into the IN-MEMORY mirror only — no savePrefs, so nothing is written
        // to disk and no real document is touched by taking this shot.
        "tool": """
          (function(){
            if (!PREFS.tools.some(function(t){ return t.id === 't-demo'; }))
              PREFS.tools.push({ id: 't-demo', name: 'Study Helper' });
            openTool('t-demo');
            return true;
          })()
        """,

        // A project with a customized roster, and the picker open beside it.
        // The roster is written through the real prefs path, so this is also a
        // live exercise of the persistence store.
        "project": """
          (function(){
            // Prefer a category that has a REAL session in it. A rostered
            // placeholder renders a plan rather than a transcript, so a project
            // full of them has no .tx and no .foot — and the floor guard would
            // read tx=-1, skip both checks, and report a clean shot of a view
            // where the bug it exists to catch cannot appear.
            const c = CATEGORIES.find(x => x.kind === 'project'
                                        && x.agents.some(a => a.sessionKey && !a.parent))
                   || CATEGORIES.find(x => x.kind === 'project' && x.agents.length)
                   || CATEGORIES.find(x => x.kind === 'project');
            if (!c) return false;
            // No access rewrite: this shot photographs the project as it really
            // is, on one of its agent tabs rather than its room, since the room
            // has its own view below. The picker has its own shot.
            const real = c.agents.find(a => a.sessionKey && !a.parent && a.kind !== 'room');
            S.view = 'sessions'; S.catId = c.id; S.sub = null;
            if (real) S.tab[c.id] = real.id;
            renderAll();
            return true;
          })()
        """,

        // A BRAND NEW PROJECT, created exactly the way the "New project" button
        // creates one — through `fromUser` and `projectCreate`, so this view is
        // also a live exercise of the intent gate rather than a mock of it. What
        // it photographs is the state right after creation: the full clone set
        // already rostered, every tab a placeholder, and the room waiting for
        // the first thing said to it.
        //
        // It writes to the REAL preference document, so both shot paths snapshot
        // and restore it — see `restorePrefs` in `shot()`. The previous version
        // of this view pushed `p-shotempty` straight into PREFS and left it
        // there; that project sat in Chancellor's live sidebar for days.
        "emptyproject": """
          (function(){
            const id = fromUser(() => projectCreate('Shot Fixture Project'))();
            if (!id) return false;
            buildCategories();
            S.view = 'sessions'; S.catId = id; S.tab[id] = id + '::room'; S.sub = null;
            renderAll();
            return !!document.querySelector('.pane.room');
          })()
        """,

        // A LIVE MCP TOOL RESULT, which the last pass could only assert.
        //
        // `decodeEncodedBlocks` was written against an MCP result observed in
        // the app's own screenshot rendering as literal `[{"type":"text",…}]`.
        // Ten unit assertions cover the function; none of them proves that what
        // reaches the transcript from a real gateway is the decoded form, and
        // the after-shot last time had moved on to prose with no tool block on
        // screen. This view goes looking through the LIVE corpus for a tool row
        // whose name starts `mcp__`, focuses the session it is in, scrolls it
        // into view, and writes what it found to `window.__shotNote` — which
        // `shot()` prints. A raw `[{` still in `.tool-res` is the defect,
        // visible in both the line and the PNG.
        "mcptool": """
          (function(){
            window.__shotNote = '';
            for (const c of CATEGORIES) for (const a of c.agents) {
              if (!a.sessionKey) continue;
              const tl = (a.transcript || []).filter(e => e.kind === 'tool'
                                                     && /^mcp__/.test(e.name || ''));
              if (!tl.length) continue;
              S.view='sessions'; S.catId=c.id; S.tab[c.id]=a.id; S.sub=null;
              renderAll();
              const rows = [...document.querySelectorAll('.tool-call b')]
                .filter(b => /^mcp__/.test(b.textContent||''));
              const raw = rows.map(b => {
                const holder = b.parentElement && b.parentElement.parentElement;
                const res = holder ? holder.querySelector('.tool-res') : null;
                return res ? (res.textContent||'').trim() : '';
              });
              const encoded = raw.filter(t => t.slice(0,2) === '[{');
              if (rows[0]) rows[0].scrollIntoView({block:'center'});
              window.__shotNote = 'session=' + a.id + ' mcpRows=' + rows.length
                + ' stillEncoded=' + encoded.length
                + ' firstResult=' + JSON.stringify((raw[0]||'').slice(0,90));
              return true;
            }
            window.__shotNote = 'no session in the live corpus has an mcp__ tool row in its tail';
            return false;
          })()
        """,

        // ── PHASE C ──

        // The room, with a real relayed exchange in it. The messages are the
        // ones Room.swift has actually persisted; if the room is empty this
        // still shoots the empty state, which is a real state and says so.
        "room": """
          (function(){
            const c = CATEGORIES[0];
            if (!c) return false;
            S.roomPing=null;
            openProjectRoom(c.id);
            const tx = document.getElementById('tx-main');
            if (tx) tx.scrollTop = tx.scrollHeight;
            return true;
          })()
        """,

        // The room with a lane pinged — the brass .page-tab.is-active on the
        // ping bar, and the note under the composer stating where it goes.
        "ping": """
          (function(){
            
            const c = CATEGORIES[0];
            if (!c) return false;
            openProjectRoom(c.id);
            const ag = (c.access||[]).find(id=>id!=='main');
            if (ag) S.roomPing = ag;
            S.roomDraft = 'Take the CSS side of this and hand it on when you are done.';
            renderAll();
            const b = document.querySelector('.ping-b.is-active');
            if (b) b.scrollIntoView({block:'center'});
            return !!ag;
          })()
        """,

        // A question with its options as buttons. If a real one is pending it is
        // drawn; the smoke test raises a REAL question through the gateway to
        // exercise this end to end rather than injecting one here.
        "question": """
          (function(){ openInbox(); return (INBOX.filter(e=>e.kind==='question').length>0); })()
        """,

        // THE VOICE INDICATOR, PHOTOGRAPHED — three passes after it was first
        // listed as the one claim that could not be made.
        //
        // No microphone is opened: `window.__bridgeSend` is stubbed for the two
        // lines that would reach Swift, and the states come back through the
        // real `window.__bridgeEmit` path exactly as Voice.swift sends them. So
        // this photographs the real renderer driven by the real state machine,
        // on a real session, with nothing recording.
        //
        // Two views because the bug is a DIFFERENCE between two frames: the
        // indicator must be there during the hold and gone after it. One frame
        // cannot show that, and the frame that was never taken is the one that
        // was wrong.
        "voice": """
          (function(){
            const a = CATEGORIES.flatMap(c=>c.agents).find(x => x.sessionKey && !x.parent);
            if (!a) return false;
            const c = catOf(a.id);
            S.view='sessions'; S.catId=c.id; S.tab[c.id]=a.id; S.sub=null;
            const realSend = window.__bridgeSend;
            window.__bridgeSend = () => {};
            VOICE.state='idle'; VOICE.requestId=null; VOICE.target=null;
            VOICE.pending = Object.create(null);
            voiceStart(a.id);
            window.__bridgeEmit({type:'voice', requestId: VOICE.requestId, state:'recording'});
            window.__bridgeSend = realSend;
            renderAll();
            const n = document.querySelector('.wr.voice');
            if (n) n.scrollIntoView({block:'center'});
            window.__shotNote = 'during the hold, indicator='
              + (n ? JSON.stringify((n.textContent||'').trim()) : 'ABSENT - the open mic is not announced');
            return !!n;
          })()
        """,

        // The same composer one `done` later. A `.wr.voice` node here is the
        // defect, and it reads TRANSCRIBING in the PNG.
        "voicedone": """
          (function(){
            const a = CATEGORIES.flatMap(c=>c.agents).find(x => x.sessionKey && !x.parent);
            if (!a) return false;
            const c = catOf(a.id);
            S.view='sessions'; S.catId=c.id; S.tab[c.id]=a.id; S.sub=null;
            const realSend = window.__bridgeSend;
            window.__bridgeSend = () => {};
            VOICE.state='idle'; VOICE.requestId=null; VOICE.target=null;
            VOICE.pending = Object.create(null);
            voiceStart(a.id);
            const r = VOICE.requestId;
            window.__bridgeEmit({type:'voice', requestId:r, state:'recording'});
            voiceStop();
            window.__bridgeEmit({type:'voice', requestId:r, state:'transcribing'});
            window.__bridgeEmit({type:'voice', requestId:r, state:'done',
                                 text:'a dictated sentence, already delivered'});
            window.__bridgeSend = realSend;
            renderAll();
            const n = document.querySelector('.wr.voice');
            window.__shotNote = 'after done, indicator='
              + (n ? JSON.stringify((n.textContent||'').trim()) + ' <-- STUCK' : 'gone (correct)')
              + ' draftTail=' + JSON.stringify(String(S.draft[a.id]||'').slice(-38));
            return !n;
          })()
        """,

        // THE NOTICE THAT OUTLIVED THE HOLD.
        //
        // Two frames again, for the same reason as `voice`/`voicedone`: the bug
        // is the difference between them. `voiceempty` must SHOW the banner —
        // if that frame is ever blank the fix has eaten the only report a
        // failed dictation has. `voiceemptytyped` is the frame that was wrong:
        // the same composer after the user gave up and typed the sentence, with
        // `nothing was inserted` still standing over inserted text.
        //
        // The typing is a real `input` event dispatched at the real textarea,
        // so it goes through the composer's own oninput. Setting S.draft
        // directly would bypass the exact line under test.
        "voiceempty": """
          (function(){
            const a = CATEGORIES.flatMap(c=>c.agents).find(x => x.sessionKey && !x.parent);
            if (!a) return false;
            const c = catOf(a.id);
            S.view='sessions'; S.catId=c.id; S.tab[c.id]=a.id; S.sub=null;
            S.draft[a.id] = '';
            VOICE.target=a.id; VOICE.state='empty'; VOICE.error=null; VOICE.requestId=null;
            renderAll();
            const n = document.querySelector('.wr[data-enter="voice-empty"]');
            if (n) n.scrollIntoView({block:'center'});
            window.__shotNote = 'a hold that heard nothing, notice='
              + (n ? JSON.stringify((n.textContent||'').trim()) : 'ABSENT - the failed hold is not reported at all');
            return !!n;
          })()
        """,

        "voiceemptytyped": """
          (function(){
            const a = CATEGORIES.flatMap(c=>c.agents).find(x => x.sessionKey && !x.parent);
            if (!a) return false;
            const c = catOf(a.id);
            S.view='sessions'; S.catId=c.id; S.tab[c.id]=a.id; S.sub=null;
            S.draft[a.id] = '';
            VOICE.target=a.id; VOICE.state='empty'; VOICE.error=null; VOICE.requestId=null;
            renderAll();
            const ta = document.querySelector('.foot textarea.ta');
            if (!ta) return false;
            ta.value = 'so I typed it by hand instead';
            ta.dispatchEvent(new Event('input', {bubbles:true}));
            renderAll();
            const n = document.querySelector('.wr[data-enter="voice-empty"]');
            if (n) n.scrollIntoView({block:'center'});
            const ta2 = document.querySelector('.foot textarea.ta');
            window.__shotNote = 'after typing by hand, notice='
              + (n ? JSON.stringify((n.textContent||'').trim()) + ' <-- STALE, over text that WAS inserted'
                   : 'gone (correct)')
              + ' box=' + JSON.stringify(ta2 ? String(ta2.value||'') : '')
              + ' state=' + VOICE.state;
            return !n;
          })()
        """,

        // The steering refusal. The send is REAL — chat.send goes out over the
        // live socket against a real session key, and the gateway's own
        // FORBIDDEN answer is what lands in the banner. Nothing is faked here;
        // that is the entire point of the shot.
        "refusal": """
          (function(){
            const a = CATEGORIES.flatMap(c=>c.agents).find(x => x.sessionKey);
            if (!a) return false;
            const c = catOf(a.id);
            S.view='sessions'; S.catId=c.id; S.tab[c.id]=a.id; S.sub=null;
            S.draft[a.id] = 'Please summarise where this run got to.';
            renderAll();
            submitComposer(a);
            return true;
          })()
        """,
    ]

    /// Set by `shot` when a measured view breaks the transcript or composer
    /// floor, so the exit code can carry it.
    private static var floorFailed = false

    static func shot(origin: URL, path: String, settle: TimeInterval = 22) async -> Never {
        // `--size WxH`. The pinned 1600x1000 stays the default, because a shot
        // whose viewport moves between runs is not a baseline. But the fix for
        // the fifth collapse is a `vh` cap, and a vh cap is precisely the claim
        // that cannot be checked at one height: the previous pass could only
        // record "correct by construction, measured at 1000px". This is how the
        // other heights get measured instead of reasoned about.
        var shotW = 1600, shotH = 1000
        if let si = CommandLine.arguments.firstIndex(of: "--size"),
           si + 1 < CommandLine.arguments.count {
            let parts = CommandLine.arguments[si + 1].lowercased().split(separator: "x")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
               w >= 480, h >= 480, w <= 6000, h <= 6000 {
                shotW = w; shotH = h
            } else {
                print("WARN could not read --size '\(CommandLine.arguments[si + 1])' — using 1600x1000")
            }
        }
        let frame = NSRect(x: 0, y: 0, width: shotW, height: shotH)
        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Bridge"
        window.backgroundColor = NSColor(srgbRed: 0x09 / 255, green: 0x0B / 255, blue: 0x11 / 255, alpha: 1)

        // The SAME configuration the real shell builds, not a bare one. A shot
        // taken against a WKWebView without the user script has no
        // __bridgeSend, so the page never receives its preferences — no tool
        // tabs, no rosters — and the screenshot would show a different app from
        // the one that ships. Faithful or it is not evidence.
        let coordinator = BridgeWebView.Coordinator()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(coordinator, name: "bridge")
        config.userContentController.addUserScript(WKUserScript(
            source: """
            window.__BRIDGE_NATIVE__ = { platform: 'macos' };
            window.__bridgeReady = function () {
              window.webkit.messageHandlers.bridge.postMessage({ t: 'ready' });
            };
            window.__bridgeSend = function (msg) {
              try { window.webkit.messageHandlers.bridge.postMessage(msg); } catch (e) {}
            };
            """,
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: frame, configuration: config)
        web.navigationDelegate = coordinator
        coordinator.webView = web
        shotCoordinator = coordinator
        web.underPageBackgroundColor = window.backgroundColor
        window.contentView = web
        window.orderFrontRegardless()
        window.displayIfNeeded()
        ActiveWebView.shared.attach(web)

        Gateway.shared.onEmit = { msg in ActiveWebView.shared.emit(msg) }
        web.load(URLRequest(url: origin))
        // Same readiness rule as the real shell: wait for live.js, then release
        // anything Gateway produced during the boot race.
        for _ in 0..<80 {
            let up = ((try? await web.evaluateJavaScript("typeof window.__bridgeEmit === 'function'")) as? Bool) ?? false
            if up { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        ActiveWebView.shared.markReady()
        // Hand over the stored preferences explicitly rather than waiting on the
        // ready round-trip, whose timing is not worth depending on in a
        // screenshot run. This is the real document from disk.
        ActiveWebView.shared.emit([
            "type": "prefs",
            "prefs": Prefs.asDictionary(Prefs.current),
            "path": Prefs.url.path,
            "tokenPresent": Keychain.token != nil,
        ])
        Gateway.shared.start()

        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))

        // Put the app into the requested view, then MEASURE IT — with the same
        // WKWebView that is about to be photographed. Two tools that disagree
        // about the layout is how the transcript-collapse bug survived three
        // rounds of "it looks fine".
        let args = CommandLine.arguments
        var viewName = "sessions"
        if let vi = args.firstIndex(of: "--view"), vi + 1 < args.count { viewName = args[vi + 1] }
        // THE SHOT VIEWS WRITE TO THE REAL PREFERENCE DOCUMENT, and until now
        // nothing put it back. `emptyproject` pushes a project through
        // `savePrefs()`; `project` calls `prefUpsert` on one of HIS categories
        // and rewrites its roster to the first three lanes it finds. Both go
        // over the real bridge to `case "prefs"` and land in prefs.json.
        //
        // The evidence was in his own file: `p-shotempty` / "Empty Project" was
        // sitting in Chancellor's sidebar, left there by a screenshot run. The
        // comment above `emptyproject` already claimed "the smoke suite
        // snapshots and restores the preference document around it" — true of
        // `--smoke`, which does exactly that, and never true here.
        let prefsBeforeShot = Prefs.current
        func restorePrefs() { _ = Smoke.restoreShotPrefs(prefsBeforeShot) }
        if let js = views[viewName] {
            let ok = (try? await web.evaluateJavaScript(js)) as? Bool
            if ok == false { print("WARN view '\(viewName)' had no data to show") }
            // The refusal shot has to wait for the gateway to actually answer.
            try? await Task.sleep(nanoseconds: viewName == "refusal" ? 4_000_000_000 : 900_000_000)
        } else {
            print("WARN unknown --view '\(viewName)' — showing sessions")
        }

        let measured = (try? await web.evaluateJavaScript(measureJS)) as? String ?? "{}"
        print("view=\(viewName) measured=\(measured)")

        // A BLANK PAGE USED TO PASS THE FLOOR GUARD, and this pass hit it by
        // accident rather than by looking for it.
        //
        // `build.sh mac` deletes dist/ out of every Bridge.app under build/ so
        // the folder reference is re-copied — the glob matches the DEBUG bundle
        // too. Take a shot with the debug binary after a release build and the
        // web view has no app to load. It rendered nothing, measureJS threw,
        // `measured` fell back to "{}", tx and footH came out -1, and the guard
        // read -1 as "this view has no transcript pane" and printed floor=ok.
        // Ten green shots of an empty window.
        //
        // -1 has to keep meaning "not present" — inbox and settings genuinely
        // have no composer — so the fix is to check that the measurement
        // happened at all before trusting any absence in it. A viewport is
        // something every page has.
        let measurementOK =
            ((try? JSONSerialization.jsonObject(with: Data(measured.utf8))) as? [String: Any]) != nil
            && measured.contains("\"viewport\"")
        if !measurementOK {
            print("floor=FAIL view=\(viewName): the page did not measure — "
                  + "measureJS returned \(measured). The web view is probably empty; "
                  + "if a release build ran since the last debug build, dist/ was "
                  + "deleted out of the debug bundle and it needs rebuilding.")
            floorFailed = true
        }

        // A SCREENSHOT THAT DOES NOT CHECK ITSELF IS A SCREENSHOT NOBODY READS.
        //
        // Nine views were shot, measured and photographed before the fifth
        // collapse was noticed, and it was noticed by a human looking at one of
        // the PNGs — not by any of the numbers printed beside them, all of which
        // were within their bounds. The project view read tx=200, footBottom=1000
        // and looked fine as a line of JSON while its send button sat below the
        // fold. So the floor is now enforced HERE, on every view that has a
        // composer, in the same call that takes the picture.
        //
        // Both directions are checked, because they fail in opposite ways and
        // fixing one has twice produced the other (§9C):
        //   * transcript below its floor  -> the collapse, rounds one to four
        //   * composer scrolling its own content -> the collapse, round five
        // A view with no transcript pane (inbox, settings) reports -1 and is
        // skipped rather than being failed for a pane it does not have.
        // Only when the page actually measured. `{}` parses as a valid empty
        // object, so this block used to run on a blank page too and print
        // `floor=ok ... tx=-1 foot=-1` on the line directly after the FAIL —
        // the same view reported both ways, with the green line last. Anything
        // reading the tail of the log, or grepping for floor=ok, saw a pass.
        if measurementOK,
           let d = measured.data(using: .utf8),
           let g = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let tx = g["tx"] as? Int ?? -1
            let footH = g["footH"] as? Int ?? -1
            let footBottom = g["footBottom"] as? Int ?? -1
            let footScrolls = g["footScrolls"] as? Bool ?? false
            var problems: [String] = []
            if tx >= 0 && tx < 200 { problems.append("transcript \(tx)px is under its 200px floor") }
            if footH >= 0 && footScrolls {
                problems.append("composer scrolls its own content at \(footH)px — the send button is below the fold")
            }
            // Against the ACTUAL viewport, not the literal 1000. With --size in
            // the harness a hardcoded bound is worse than no bound: it passes
            // every shorter window trivially and fails every taller one for
            // being taller, and either way it has stopped measuring the thing
            // it names.
            let vpH = (g["viewport"] as? [Int])?.last ?? shotH
            if footBottom > 0 && footBottom > vpH + 2 {
                problems.append("composer bottom \(footBottom) is outside the \(vpH)px window")
            }
            if problems.isEmpty {
                print("floor=ok view=\(viewName) size=\(shotW)x\(shotH) tx=\(tx) foot=\(footH) footScrolls=false")
            } else {
                print("floor=FAIL view=\(viewName): " + problems.joined(separator: "; "))
                floorFailed = true
            }
        }

        // A view may leave one line of its own findings behind. The floor guard
        // reports geometry; this is for the views whose point is not geometry —
        // `mcptool` uses it to say whether a live MCP result is still arriving
        // JSON-encoded, which is a claim a screenshot alone answers slowly.
        if let note = (try? await web.evaluateJavaScript("window.__shotNote || ''")) as? String,
           !note.isEmpty {
            print("note view=\(viewName) \(note)")
        }

        let cats = (try? await web.evaluateJavaScript("CATEGORIES.length")) as? Int ?? 0
        let agents = (try? await web.evaluateJavaScript(
            "CATEGORIES.reduce((n,c)=>n+c.agents.length,0)")) as? Int ?? 0
        let names = (try? await web.evaluateJavaScript(
            "CATEGORIES.map(c=>c.name+'('+c.agents.length+')').join(', ')")) as? String ?? ""
        print("categories=\(cats) sessions=\(agents)")
        print("groups: \(names)")

        web.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let cfg = WKSnapshotConfiguration()
        cfg.rect = web.bounds
        cfg.afterScreenUpdates = true
        let image: NSImage? = await withCheckedContinuation { c in
            web.takeSnapshot(with: cfg) { img, err in
                if let err { NSLog("bridge: snapshot failed: \(err.localizedDescription)") }
                c.resume(returning: img)
            }
        }
        guard let image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("FAIL could not snapshot the web view")
            restorePrefs(); exit(1)
        }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch {
            print("FAIL could not write \(path): \(error)"); restorePrefs(); exit(1)
        }
        print("wrote \(path) (\(png.count) bytes, \(Int(image.size.width))x\(Int(image.size.height)))")
        Gateway.shared.stop()
        Tunnel.shared.stop()
        restorePrefs()
        // A floor violation is a FAILED shot, not a note under a successful one.
        // The PNG is still written — looking at it is how the last one was
        // found — but the exit code says the layout is broken so a loop over the
        // views cannot report nine successes with a broken composer among them.
        exit(agents > 0 && !floorFailed ? 0 : 1)
    }


    // ---- photographing the RUNNING app ---------------------------------------
    //
    // `--shot` launches a second copy of the app to photograph it. That is real
    // evidence — same binary, same page, same live gateway — but it is not the
    // window that is actually open on Chancellor's desk, and the difference is
    // worth closing.
    //
    // `screencapture -l <windowid>` would do it and does not work here:
    //
    //     $ screencapture -x -o -l 7561 /tmp/win.png
    //     could not create image from window
    //
    // macOS requires a Screen Recording grant for that, per capturing process,
    // and the process running these commands does not have one. It is a TCC
    // grant, which means a GUI approval by hand — it cannot be given from here,
    // and TCC.db is SIP-protected. So the running app photographs ITSELF, which
    // needs no grant at all: a WKWebView can always snapshot its own contents.
    //
    //     kill -USR1 $(pgrep -f 'Bridge.app/Contents/MacOS/Bridge')
    //
    // …after writing {view, path} to shot-request.json. The measurement is taken
    // through the SAME WKWebView in the SAME call, and written beside the PNG:
    // CDP and --screenshot at different viewports produced disagreeing numbers
    // once already, and two tools that disagree about the layout is how the
    // transcript collapse survived three rounds of "it looks fine".
    static var shotRequestURL: URL { Prefs.directory.appendingPathComponent("shot-request.json") }

    static func installLiveShotHandler() {
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { Task { @MainActor in await Smoke.liveShot() } }
        src.resume()
        liveShotSource = src
    }

    static func liveShot() async {
        guard let web = ActiveWebView.shared.webView else { NSLog("bridge: no web view to shoot"); return }
        let req = (try? Data(contentsOf: shotRequestURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let viewName = req["view"] as? String ?? "sessions"
        let path = req["path"] as? String
            ?? (NSHomeDirectory() + "/Desktop/Bridge/shots/live-\(viewName).png")

        // Same as --shot, and it matters more here: this runs inside the window
        // on his desk, so a view that adds a project adds it to the app he is
        // looking at. Restored at the end, and the page is handed the restored
        // document so the sidebar goes back with the file.
        let prefsBeforeShot = Prefs.current
        defer {
            if Smoke.restoreShotPrefs(prefsBeforeShot) {
                // Hand the restored document back to the page too, so the
                // sidebar in front of him goes back with the file.
                ActiveWebView.shared.emit([
                    "type": "prefs", "prefs": Prefs.asDictionary(prefsBeforeShot),
                    "path": Prefs.url.path, "tokenPresent": Keychain.token != nil,
                ])
            }
        }
        if let js = views[viewName] { _ = try? await web.evaluateJavaScript(js) }
        try? await Task.sleep(nanoseconds: 900_000_000)

        // An optional selector to CLICK before measuring. This exists so that a
        // control can be exercised in the app that is actually running, through
        // its own handler and against the live gateway, rather than only having
        // its wire shape asserted in a fixture. Answering a question is the case
        // it was added for: the smoke test proves Bridge sends the right two ids,
        // and this proves the button on screen sends them to a real gateway and
        // that the gateway takes the answer.
        if let sel = req["click"] as? String, !sel.isEmpty {
            let clicked = (try? await web.evaluateJavaScript(
                "(function(){const n=document.querySelector(\(BridgeWebView.Coordinator.jsQuote(sel)));"
                + "if(!n) return false; n.click(); return true;})()")) as? Bool ?? false
            NSLog("bridge: live shot clicked \(sel): \(clicked)")
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }

        let measured = (try? await web.evaluateJavaScript(measureJS)) as? String ?? "{}"
        web.layoutSubtreeIfNeeded()
        web.window?.displayIfNeeded()

        let cfg = WKSnapshotConfiguration()
        cfg.rect = web.bounds
        cfg.afterScreenUpdates = true
        let image: NSImage? = await withCheckedContinuation { c in
            web.takeSnapshot(with: cfg) { img, err in
                if let err { NSLog("bridge: live snapshot failed: \(err.localizedDescription)") }
                c.resume(returning: img)
            }
        }
        guard let image, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            NSLog("bridge: live snapshot produced no image"); return
        }
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        do { try png.write(to: URL(fileURLWithPath: path)) } catch {
            NSLog("bridge: could not write \(path): \(error)"); return
        }
        // Beside the image, the geometry of the thing in it, from the same call.
        let side = path + ".json"
        try? Data(("{\"view\":\"\(viewName)\",\"bytes\":\(png.count),"
                   + "\"px\":[\(Int(image.size.width)),\(Int(image.size.height))],"
                   + "\"measured\":\(measured)}").utf8).write(to: URL(fileURLWithPath: side))
        NSLog("bridge: live shot \(viewName) -> \(path) (\(png.count) bytes) \(measured)")
    }

    /// Put the preference document back the way a shot found it. Returns true if
    /// something actually had to be undone, which is the signal the live shot
    /// uses to decide whether the page needs telling.
    ///
    /// Its own function so the round-trip can be asserted against the real store
    /// in `--smoke`: the end-to-end proof would be a shot run, and a shot run
    /// from a non-GUI context renders a blank page (categories=0, measured={})
    /// and so mutates nothing either way — it cannot tell the two behaviours
    /// apart. See NIGHT-NOTES pass 5.
    @discardableResult
    static func restoreShotPrefs(_ snapshot: Prefs) -> Bool {
        guard Prefs.current != snapshot else { return false }
        _ = Prefs.save(snapshot)
        return true
    }

    /// One measurement expression, used by --shot AND by the live shot, so a
    /// screenshot and the numbers printed next to it cannot come from different
    /// notions of what was on screen.
    static let measureJS = """
      (function(){
        const r=(s)=>{const n=document.querySelector(s);return n?n.getBoundingClientRect():null};
        const c=r('.content'), tx=r('.tx'), foot=r('.foot');
        const de=document.documentElement;
        return JSON.stringify({ viewport:[window.innerWidth, window.innerHeight],
          contentH: c?Math.round(c.height):-1, contentBottom: c?Math.round(c.bottom):-1,
          tx: tx?Math.round(tx.height):-1, footH: foot?Math.round(foot.height):-1,
          footBottom: foot?Math.round(foot.bottom):-1,
          /* THE FIELD THAT WOULD HAVE CAUGHT THE FIFTH COLLAPSE.
             The project view measured tx=200 and footBottom=1000 — a transcript
             at its floor and a composer inside the window, which is everything
             the old checks looked at, and both passed. The composer was still
             unusable: .foot had shrunk to 117px around ~380px of content, so the
             text input and the send button were below the fold inside .foot's
             own scroll region. "Crushed" has an exact meaning (§11.9) and it is
             this boolean, not a height. Heights are a proxy; this is the thing. */
          footScrolls: foot?(document.querySelector('.foot').scrollHeight
                             > document.querySelector('.foot').clientHeight+4):false,
          /* HOW MUCH THE COMPOSER ACTUALLY WANTS, and what is asking for it.
             `footScrolls` says the box is crushed; it does not say by how much
             or by whom, and three passes have now answered that question by
             trimming whatever had most recently been added — which is how §9C's
             two wrong fixes happened. scrollHeight is the natural height, the
             difference is the exact debt, and the breakdown names the rows that
             owe it. A number nobody has to infer. */
          footNatural: foot?document.querySelector('.foot').scrollHeight:-1,
          footRows: foot?[...document.querySelector('.foot').children].map(
            n=>(n.className||'?').split(' ')[0]+':'+Math.round(n.getBoundingClientRect().height)
          ).join(' '):'',
          /* Which lane the ping bar has selected — 'none' is a real answer, not
             a missing one. `pingActive` counts .is-active buttons and is 1 in
             BOTH the room and ping shots, because "no ping -> main" carries
             is-active when nothing is pinged. So the two shots were measuring
             as identical and the ping shot proved nothing it was taken to prove. */
          pingSel: (document.querySelector('.ping-b.is-active[data-id]')||{}).getAttribute
                   ? document.querySelector('.ping-b.is-active[data-id]').getAttribute('data-id')
                   : 'none',
          roomH: (function(){const n=r('.pane.room');return n?Math.round(n.height):-1})(),
          overflowX: de.scrollWidth - de.clientWidth,
          /* PIXEL PROBE (pass 12, temporary): text clipped by its own box.
             Every layout defect found in passes 3, 10 and 11 was found by a
             human looking at a PNG, never by the numbers printed beside it.
             This is the cheapest class of that defect a machine can see:
             content wider or taller than the box drawing it, with no scrollbar
             and no ellipsis to say the truncation was meant. */
          clip: (function(){
            const nm=(n)=>{const c=n.className; const s=(c&&c.baseVal!==undefined)?c.baseVal:c;
                           return (s&&String(s).trim().split(' ')[0])||n.tagName.toLowerCase()};
            const out=[];
            document.querySelectorAll('body *').forEach(n=>{
              const cs=getComputedStyle(n);
              if(cs.display==='none'||cs.visibility==='hidden') return;
              if(n.clientWidth===0&&n.clientHeight===0) return;
              const rc=n.getBoundingClientRect();
              if(rc.width===0||rc.height===0) return;
              const scrollable=(o)=>o==='auto'||o==='scroll';
              const dx=n.scrollWidth-n.clientWidth, dy=n.scrollHeight-n.clientHeight;
              if(dx>1&&!scrollable(cs.overflowX)&&cs.textOverflow!=='ellipsis')
                out.push('x/'+nm(n)+'/'+dx);
              if(dy>1&&!scrollable(cs.overflowY)&&cs.overflowY==='hidden')
                out.push('y/'+nm(n)+'/'+dy);
            });
            return out.slice(0,14).join(' ');
          })(),
          view: S.view,
          roomRows: document.querySelectorAll('.rm').length,
          inboxRows: document.querySelectorAll('.ibx').length,
          questionRows: document.querySelectorAll('.ibx-q').length,
          unread: (document.querySelector('.nav__unread')||{}).textContent||'0',
          pingActive: document.querySelectorAll('.ping-b.is-active').length,
          navTabs: document.querySelectorAll('#page-tabs .page-tab').length,
          tabs: [...document.querySelectorAll('#page-tabs .page-tab')].map(t=>t.textContent) });
      })()
    """

    /// Watches Gateway's emit stream until it reaches a terminal state or 75s.
    private static func expectLive(_ report: @escaping (String, Int, String) -> Void) -> () async -> Void {
        var status = "connecting"
        var sessions = 0
        var detail = ""
        let sem = DispatchSemaphore(value: 0)
        var signalled = false
        Gateway.shared.onEmit = { msg in
            ActiveWebView.shared.emit(msg)
            switch msg["type"] as? String {
            case "status":
                status = msg["connection"] as? String ?? status
                detail = msg["detail"] as? String ?? detail
                if status == "error", !signalled { signalled = true; sem.signal() }
            case "sessions":
                sessions = (msg["rows"] as? [[String: Any]])?.count ?? 0
                if !signalled { signalled = true; sem.signal() }
            default: break
            }
        }
        return {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    _ = sem.wait(timeout: .now() + 75)
                    report(status, sessions, detail)
                    c.resume()
                }
            }
        }
    }

    /// A raw one-shot TCP request so the check can send bytes URLSession refuses to.
    static func rawRequest(port: UInt16, _ text: String) async -> String {
        await withCheckedContinuation { cont in
            guard let p = NWEndpoint.Port(rawValue: port) else { cont.resume(returning: ""); return }
            let conn = NWConnection(host: "127.0.0.1", port: p, using: .tcp)
            var done = false
            let finish: (String) -> Void = { s in
                if !done { done = true; conn.cancel(); cont.resume(returning: s) }
            }
            conn.stateUpdateHandler = { state in
                if case .ready = state {
                    conn.send(content: Data(text.utf8), completion: .contentProcessed { _ in
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                            finish(data.map { String(decoding: $0, as: UTF8.self) } ?? "")
                        }
                    })
                } else if case .failed = state { finish("") }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish("") }
        }
    }
}


/// A one-slot mailbox for a value produced on another queue. Its own lock
/// because both writers here run off the main actor.
final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _v = ""
    private var _settled = false
    var value: String { lock.lock(); defer { lock.unlock() }; return _v }
    var settled: Bool { lock.lock(); defer { lock.unlock() }; return _settled }
    func set(_ s: String) { lock.lock(); _v = s; _settled = true; lock.unlock() }
}


/// A WKNavigationAction carrying only the URL, which is all the policy method
/// reads. WKNavigationAction's `request` is get-only, so the check needs a
/// subclass rather than an instance.
final class TestNavigationAction: WKNavigationAction {
    private let target: URL
    init(url: URL) { self.target = url; super.init() }
    override var request: URLRequest { URLRequest(url: target) }
}
