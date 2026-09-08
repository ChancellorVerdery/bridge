/* Study tool — UI, ported from Atlas's study plugin (atlas-ui/src/page/
   studyui.js) and reskinned to Bridge's terminal look. Two views: a tutor
   CHAT (agent-backed — the gateway coursework clone) and a question BANK
   (authored here, graded locally by the vendored Compute Engine). Flashcards
   are NOT part of this: Atlas split them into a separate "ladder" plugin in
   2026-08, so the faithful port of the study plugin is chat + bank.

   DIFFERENCES from Atlas, all forced by Bridge's shape:
   • No ES modules / no bundler — this is one flat IIFE exposing window.StudyUI,
     and it pulls the math+markdown pipeline (studyjobs.js's stMD/inlineMath),
     the view.js helpers (renderMath/fitEquations/tuneMathFields) and
     canvasui.js's sanitizeHTML in as private functions rather than importing.
   • The ~1MB Compute Engine + MathLive + marked are VENDORED and lazy-loaded
     on first open (loadDeps) — Bridge should not pay ~2.8MB on every launch for
     a tool most sessions never touch.
   • The tutor turn and the answer judge were dev-server middleware in Atlas;
     here they are gateway turns behind window.StudyAI (live.js), which resolves
     a Promise when the run completes so tutorTurn/checkAnswers keep their
     `await` shape.
   • FILE EXTRACTION is deferred: the native shell's send carries text only
     (no attachment path), so "upload material → AI extracts questions" cannot
     be honoured yet. The bank toolbar says so; manual authoring is the path. */

(function () {
  'use strict';

  const D = window.Study; // the data/grading layer

  /* ───────────── vendored deps, lazy-loaded once ───────────── */

  let depsPromise = null;
  const injectScript = (src) => new Promise((res, rej) => {
    const s = document.createElement('script');
    s.src = src; s.onload = () => res(); s.onerror = () => rej(new Error('failed to load ' + src));
    document.head.appendChild(s);
  });
  const injectCSS = (href) => { const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = href; document.head.appendChild(l); };

  function loadDeps() {
    if (depsPromise) return depsPromise;
    depsPromise = (async () => {
      injectCSS('vendor/mathlive-static.css');
      injectCSS('vendor/mathlive-fonts.css');
      // Compute Engine and marked are independent; MathLive is needed before we
      // can touch MathfieldElement. Load them together.
      await Promise.all([
        injectScript('vendor/compute-engine.js'),
        injectScript('vendor/marked.js'),
        injectScript('vendor/mathlive.min.js'),
      ]);
      // Self-host: the @font-face lives in the CSS we just loaded (vendor/fonts),
      // so stop MathLive injecting its own font/sound loaders that would 404.
      try {
        const MF = window.MathLive && window.MathLive.MathfieldElement;
        if (MF) { MF.fontsDirectory = null; MF.soundsDirectory = null; }
        // Trim the virtual keyboard to math-only layers. Every device already
        // has letters and digits on its physical keyboard, so the VK only needs
        // the symbols and Greek it can't type — not the numeric/qwerty layouts.
        if (window.mathVirtualKeyboard) window.mathVirtualKeyboard.layouts = ['symbols', 'greek'];
      } catch { /* older builds expose it differently; the CSS still covers fonts */ }
    })();
    return depsPromise;
  }
  const depsReady = () => !!(window.MathLive && window.ComputeEngine && window.marked);

  /* ───────────── math + markdown pipeline (studyjobs.js) ───────────── */

  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  // canvasui.js sanitizeHTML — self-contained, pure DOM.
  function sanitizeHTML(html) {
    const t = document.createElement('template');
    t.innerHTML = html;
    t.content.querySelectorAll('script,iframe,object,embed,link,meta,style,form').forEach((n) => n.remove());
    for (const n of t.content.querySelectorAll('*')) {
      for (const a of [...n.attributes]) {
        const url = /^(href|src|xlink:href|formaction)$/i.test(a.name) ? a.value.replace(/[\t\n\r\0]/g, '').trim() : '';
        if (/^on/i.test(a.name) || /^(javascript|vbscript):/i.test(url) || (/^href$/i.test(a.name) && /^data:/i.test(url))) n.removeAttribute(a.name);
      }
    }
    return t.innerHTML;
  }

  // view.js math helpers.
  const STRETCHY_ACCENTS = ['overrightarrow', 'overleftarrow', 'overleftrightarrow', 'widehat', 'widetilde', 'overline', 'overbrace', 'overparen'];
  function fixAccentSubscript(latex) {
    const s = String(latex ?? '');
    let out = '', i = 0;
    while (i < s.length) {
      let matched = false;
      if (s[i] === '\\') {
        for (const cmd of STRETCHY_ACCENTS) {
          if (!s.startsWith('\\' + cmd + '{', i)) continue;
          let depth = 0, j = i + cmd.length + 1;
          for (; j < s.length; j++) { if (s[j] === '{') depth++; else if (s[j] === '}' && --depth === 0) break; }
          if (j < s.length && (s[j + 1] === '_' || s[j + 1] === '^')) { out += '{' + s.slice(i, j + 1) + '}'; i = j + 1; matched = true; }
          break;
        }
      }
      if (!matched) { out += s[i]; i++; }
    }
    return out;
  }
  const renderMath = (latex) => {
    try { return `<div class="eq-render"><span class="eq-render__inner">${window.MathLive.convertLatexToMarkup(fixAccentSubscript(latex))}</span></div>`; }
    catch { return `<div class="eq-render eq-render--invalid">${esc(latex)}</div>`; }
  };
  function fitEq(el) {
    const inner = el.querySelector(':scope > .eq-render__inner');
    if (!inner) return;
    const natural = inner.scrollWidth, avail = el.clientWidth;
    if (!natural || !avail) return;
    const scale = Math.min(1, avail / natural);
    if (scale >= 0.999) { inner.style.transform = ''; el.style.height = ''; return; }
    inner.style.transform = `scale(${scale})`;
    const cs = getComputedStyle(el);
    const padY = parseFloat(cs.paddingTop) + parseFloat(cs.paddingBottom);
    el.style.height = `${inner.offsetHeight * scale + padY}px`;
  }
  let eqObserver = null;
  function fitEquations(rootEl) {
    if (!eqObserver) eqObserver = new ResizeObserver((entries) => { for (const e of entries) fitEq(e.target); });
    eqObserver.disconnect();
    for (const el of rootEl.querySelectorAll('.eq-render:not(.eq-render--invalid)')) { fitEq(el); eqObserver.observe(el); }
  }
  const MENU_KEEP_IDS = new Set(['add-row-above', 'add-row-below', 'add-column-before', 'add-column-after', 'delete-row', 'delete-column', 'insert-matrix', 'insert', 'accent', 'cut', 'copy', 'paste', 'select-all']);
  function pruneMenuItems(items) {
    const kept = (items ?? []).filter((it) => it.type === 'divider' || (it.id ? MENU_KEEP_IDS.has(it.id) : it.submenuClass === 'border-submenu'));
    const out = [];
    for (const it of kept) { if (it.type === 'divider' && (!out.length || out[out.length - 1].type === 'divider')) continue; out.push(it); }
    if (out[out.length - 1]?.type === 'divider') out.pop();
    return out.map((it) => (it.id === 'copy' && it.submenu ? { ...it, submenu: it.submenu.filter((s) => s.keyboardShortcut === 'meta+C') } : it));
  }
  function tuneMathFields(rootEl) {
    for (const mf of rootEl.querySelectorAll('math-field')) {
      mf.mathModeSpace = '\\;';
      mf.inlineShortcuts = { ...mf.inlineShortcuts, '-+': '\\mp', arccot: '\\operatorname{arccot}', arcsinh: '\\operatorname{arcsinh}', arccoth: '\\operatorname{arccoth}' };
      mf.mode = 'math';
      try { mf.menuItems = pruneMenuItems(mf.menuItems); } catch { /* not mounted yet */ }
    }
  }

  const fixDots = (latex) => latex.replace(/\\dotsb\b/g, '\\cdots').replace(/\\dots[cmio]?\b/g, '\\ldots');
  const inlineMath = (latex) => {
    try { return `<span class="nt-math">${window.MathLive.convertLatexToMarkup(fixDots(D.fixSlashes(latex)).trim(), { defaultMode: 'textstyle' })}</span>`; }
    catch { return esc(latex); }
  };
  const mathMarkup = (latex, block) => (block ? renderMath(fixDots(latex)) : inlineMath(latex));
  const INLINE_MATH = /\$(?![\s$])([^\n$]*[^\s$])\$/g;
  function stMD(text) {
    if (!depsReady()) return esc(text); // before MathLive/marked land, show plain
    const math = [];
    const src = D.fixEscapes(text)
      .replace(/\\\[([\s\S]+?)\\\]/g, (m, l) => `$$${l}$$`)
      .replace(/\\\(([\s\S]+?)\\\)/g, (m, l) => `$${l.replace(/\n/g, ' ')}$`)
      .replace(/\$\$([\s\S]+?)\$\$/g, (m, l) => `STMATH${math.push(mathMarkup(l, true)) - 1}STMATH`)
      .replace(INLINE_MATH, (m, l) => `STMATH${math.push(mathMarkup(l, false)) - 1}STMATH`);
    const html = window.marked.parse(src)
      .replace(/<p>STMATH(\d+)STMATH<\/p>/g, (m, i) => math[Number(i)])
      .replace(/STMATH(\d+)STMATH/g, (m, i) => math[Number(i)]);
    return sanitizeHTML(html);
  }

  /* ───────────── session state ───────────── */

  const ui = { tool: 'study', rename: null, modal: null, busy: false, focusChat: false };
  let pageRoot = null;
  let toolId = null;

  const AI = () => window.StudyAI;
  const aiOn = () => !!(AI() && AI().configured());

  const curTab = (s) => s.tabs.find((t) => t.id === s.active) || s.tabs[0] || null;
  function pushSys(tabId, text) {
    const s = D.loadStudy();
    const t = s.tabs.find((x) => x.id === tabId);
    if (!t) return;
    t.chat.push({ role: 'sys', text });
    D.saveStudy(s);
  }

  /* ───────────── focus preservation across full re-renders ───────────── */

  function captureFocus() {
    const el = document.activeElement;
    if (!el || !pageRoot.contains(el)) return null;
    let sel = null;
    if (el.id) sel = '#' + el.id;
    else if (el.classList.contains('st-answer') && el.dataset.part != null) sel = `.st-answer[data-part="${el.dataset.part}"]`;
    else return null;
    let range = null;
    try { range = [el.selectionStart, el.selectionEnd]; } catch { /* math-field: no text-selection API */ }
    return { sel, range };
  }
  function restoreFocus(f) {
    if (!f) return;
    const el = pageRoot.querySelector(f.sel);
    if (!el) return;
    try { el.focus(); } catch { /* */ }
    if (f.range) { try { el.setSelectionRange(f.range[0], f.range[1]); } catch { /* */ } }
  }

  /* ───────────── render ───────────── */

  function render() {
    if (!pageRoot) return;
    const f = captureFocus();
    const s = D.loadStudy();
    if (!s.tabs.length) {
      pageRoot.innerHTML = emptyHTML();
      return;
    }
    const tab = curTab(s);
    const views = { study: studyView, bank: bankView };
    pageRoot.innerHTML = `<div class="st">
      ${tabsBar(s)}
      ${toolsBar(tab)}
      <div class="st-view">${(views[ui.tool] || studyView)(tab, s)}</div>
    </div>`;
    if (depsReady()) { tuneMathFields(pageRoot); fitEquations(pageRoot); }
    const msgs = pageRoot.querySelector('#st-msgs');
    if (msgs) msgs.scrollTop = msgs.scrollHeight;
    if (ui.rename != null) { const inp = pageRoot.querySelector('#st-rename'); if (inp) { inp.focus(); inp.select(); } }
    else if (ui.focusChat) { const c = pageRoot.querySelector('#st-chat-in'); if (c) { c.focus(); ui.focusChat = false; } }
    else restoreFocus(f);
  }

  function emptyHTML() {
    return `<div class="st st--empty">
      <div class="st-empty">
        <b>No courses yet.</b>
        <p>Add a course to start a question bank and a tutor chat for it.</p>
        <button type="button" class="st-btn" data-st="tab-add">+ New course</button>
      </div>
    </div>`;
  }

  /* ---- course tabs (folder tabs, Bridge look) ---- */

  const tabBtnHTML = (t, active) => `<button type="button" class="st-tab${active ? ' is-active' : ''}" data-st="tab-pick" data-id="${t.id}">
    <span class="st-tab__name" data-st="${active ? 'tab-rename' : 'tab-pick'}" data-id="${t.id}">${esc(t.name)}</span>
    ${active ? `<span class="st-tab__x" data-st="tab-del" data-id="${t.id}" aria-label="Delete course">×</span>` : ''}
  </button>`;

  function tabsBar(s) {
    return `<div class="st-tabs">
      ${s.tabs.map((t) => (ui.rename === t.id && t.id === s.active
      ? `<span class="st-tab is-active st-tab--edit"><input id="st-rename" class="st-tab__in" value="${esc(t.name)}"></span>`
      : tabBtnHTML(t, t.id === s.active))).join('')}
      <button type="button" class="st-tab st-tab--add" data-st="tab-add" aria-label="New course">+</button>
    </div>`;
  }

  function toolsBar(tab) {
    const n = tab ? tab.questions.length : 0;
    return `<div class="st-tools">
      <button type="button" class="st-pill${ui.tool === 'study' ? ' is-on' : ''}" data-st="tool" data-tool="study">Tutor</button>
      <button type="button" class="st-pill${ui.tool === 'bank' ? ' is-on' : ''}" data-st="tool" data-tool="bank">Question bank (${n})</button>
    </div>`;
  }

  /* ───────────── view 1 — tutor chat ───────────── */

  const MSG_CLS = { tutor: 'st-msg--tutor', you: 'st-msg--you', result: 'st-msg--result', sys: 'st-msg--sys' };
  const NO_AI_MSG = 'The tutor runs on the coursework agent through the gateway. Bridge is not connected to the gateway right now, so the tutor is offline — the question bank and local grading still work.';

  function studyView(tab, s) {
    const busy = ui.busy;
    const on = aiOn();
    const msgs = tab.chat.length
      ? tab.chat.map((m) => `<div class="st-msg ${MSG_CLS[m.role] || 'st-msg--sys'}">${stMD(m.text)}</div>`).join('')
      : `<div class="st-msg st-msg--sys">Ask the tutor anything about <b>${esc(tab.name)}</b> — or press <b>Quiz me</b> to pull a question from this course's bank and work it here.</div>`;
    return `<div class="st-chat">
      <div class="st-msgs" id="st-msgs">
        ${msgs}
        ${tab.activeQ ? qCardHTML(tab.activeQ, busy) : ''}
        ${busy ? `<div class="st-msg st-busy">${esc(busyLine())}</div>` : ''}
        ${!on ? `<div class="st-msg st-msg--sys">${NO_AI_MSG}</div>` : ''}
      </div>
      <div class="st-compose">
        <input id="st-chat-in" class="st-field" placeholder="${on ? 'Message the tutor…' : 'Tutor offline — gateway not connected'}" ${busy || !on ? 'disabled' : ''}>
        <button type="button" class="st-btn" data-st="chat-send" ${busy || !on ? 'disabled' : ''}>Send</button>
        <button type="button" class="st-btn st-btn--ghost" data-st="chat-quiz" ${busy || !tab.questions.length ? 'disabled' : ''} title="${tab.questions.length ? '' : 'Add questions to the bank first'}">Quiz me</button>
        <button type="button" class="st-btn st-btn--ghost" data-st="chat-clear" ${busy || !tab.chat.length ? 'disabled' : ''}>Clear</button>
      </div>
    </div>`;
  }

  const busyLine = () => (ui.busy === 'grading' ? 'Grading…' : 'Tutor is thinking…');

  const figsHTML = (q) => (q.figures && q.figures.length ? `<div class="st-qfigs">${q.figures.map((f) => `<img class="st-qfig" src="${esc(f)}" alt="figure">`).join('')}</div>` : '');

  function choiceHTML(p, i, given, frozen) {
    return `<div class="st-choices" data-part="${i}">
      ${p.options.map((o, k) => `<label class="st-choice${String(given) === String(k) ? ' is-picked' : ''}">
        <input type="radio" name="st-p${i}" value="${k}"${String(given) === String(k) ? ' checked' : ''}${frozen ? ' disabled' : ''}>
        ${o.figure ? `<img class="st-choice__img" src="${esc(o.figure)}" alt="option">` : ''}
        ${o.text ? `<span class="st-choice__txt">${stMD(o.text)}</span>` : ''}
      </label>`).join('')}
    </div>`;
  }

  function qCardHTML(q, frozen) {
    const parts = q.parts.map((p, i) => {
      const given = q.given?.[i] ?? '';
      let field;
      if (p.kind === 'choice') field = choiceHTML(p, i, given, frozen);
      else if (p.kind === 'math') field = `<math-field class="pw-mathfield st-answer" data-part="${i}" math-virtual-keyboard-policy="manual" ${frozen ? 'read-only' : ''}>${esc(given)}</math-field>`;
      else field = `<input class="st-field st-answer" data-part="${i}" value="${esc(given)}" ${frozen ? 'disabled' : ''}>`;
      const v = q.verdicts?.[i];
      const chip = v ? `<span class="st-vchip st-vchip--${v === 'correct' ? 'ok' : 'no'}">${v === 'correct' ? '✔' : '✘'} ${v}</span>` : '';
      const note = q.vnotes?.[i] ? `<div class="st-part__hint">${esc(q.vnotes[i])}</div>` : '';
      return `<div class="st-part">
        ${p.prompt ? `<div class="st-part__prompt">${stMD(p.prompt)}</div>` : ''}
        ${field}${chip}${note}
        <div class="st-part__hint st-part__rule">${esc(D.partRule(p))}</div>
      </div>`;
    }).join('');
    return `<div class="st-qcard">
      <div class="st-qhead"><span class="st-cat">${esc(q.category)}</span>${q.bankId ? '' : '<span class="st-gen">generated</span>'}</div>
      ${q.intro ? `<div class="st-qintro">${stMD(q.intro)}</div>` : ''}
      ${figsHTML(q)}
      ${parts}
      <div class="st-qacts">
        ${frozen ? '' : '<button type="button" class="st-btn" data-st="q-check">Check</button>'}
        ${!q.bankId && !frozen ? '<button type="button" class="st-btn st-btn--ghost" data-st="q-keep">Save to bank</button>' : ''}
        <button type="button" class="st-btn st-btn--ghost" data-st="q-close">Close</button>
      </div>
    </div>`;
  }

  /* ---- chat actions ---- */

  async function doSend(text) {
    const s = D.loadStudy();
    const tab = curTab(s);
    if (!tab || ui.busy || !aiOn()) return;
    const msg = String(text ?? '').trim();
    if (!msg) return;
    tab.chat.push({ role: 'you', text: msg });
    D.saveStudy(s);
    ui.focusChat = true;
    render();
    await tutorTurn(tab.id, msg);
  }

  // Compose the context the tutor needs on the FIRST turn of a fresh session;
  // afterwards the gateway session retains its own history, so later turns send
  // just the message.
  function tutorPreamble(tab) {
    return `You are a patient tutor helping a student with the course "${tab.name}". `
      + `Explain clearly, use $…$ / $$…$$ LaTeX for math, and when the student asks for a practice problem, `
      + `you MAY pose one by ending your reply with a fenced json block like:\n`
      + '```json\n{"question":{"category":"...","intro":"...","parts":[{"prompt":"...","kind":"math","answer":"<LaTeX>","check":"equiv"}]}}\n```\n'
      + `Only include that block when actually posing a gradeable problem.`;
  }

  async function tutorTurn(tabId, userMsg, opts) {
    ui.busy = true; render();
    let replyText = '';
    try {
      const s0 = D.loadStudy();
      const tab0 = s0.tabs.find((x) => x.id === tabId);
      const preamble = (opts && opts.preamble) || (tab0 && tab0.chat.filter((m) => m.role === 'tutor').length === 0 ? tutorPreamble(tab0) : '');
      const prompt = preamble ? preamble + '\n\n---\n\n' + userMsg : userMsg;
      replyText = await AI().chat(prompt);
    } catch (err) {
      pushSys(tabId, 'Tutor error: ' + (err && err.message ? err.message : String(err)));
      ui.busy = false; ui.focusChat = true; render();
      return;
    }
    const s = D.loadStudy();
    const tab = s.tabs.find((x) => x.id === tabId);
    if (!tab) { ui.busy = false; render(); return; }
    const { message, question } = splitReply(replyText);
    tab.chat.push({ role: 'tutor', text: message || replyText });
    if (question) {
      const bq = tab.questions.find((x) => x.id === question.id);
      tab.activeQ = D.normQuestion(bq || question);
      tab.activeQ.bankId = bq ? bq.id : null;
      tab.activeQ.given = []; tab.activeQ.attempts = 0; tab.activeQ.verdicts = null; tab.activeQ.vnotes = [];
    }
    D.saveStudy(s);
    ui.busy = false; ui.focusChat = true; render();
  }

  // The tutor may end a reply with a ```json {question:{…}} block. Pull it off
  // the prose and parse it; on any failure the whole reply is just prose.
  function splitReply(text) {
    const t = String(text || '');
    const m = t.match(/```json\s*([\s\S]*?)```\s*$/);
    if (!m) return { message: t, question: null };
    try {
      const obj = JSON.parse(m[1]);
      if (obj && obj.question) return { message: t.slice(0, m.index).trim(), question: obj.question };
    } catch { /* not valid — leave it in the prose */ }
    return { message: t, question: null };
  }

  // Quiz me: pull a random question from this course's local bank (no agent
  // needed — the bank + local grading are the reliable loop).
  function quizMe() {
    const s = D.loadStudy();
    const tab = curTab(s);
    if (!tab || !tab.questions.length) return;
    const q = tab.questions[Math.floor(Math.random() * tab.questions.length)];
    tab.activeQ = D.normQuestion(q);
    tab.activeQ.bankId = q.id;
    tab.activeQ.given = []; tab.activeQ.attempts = 0; tab.activeQ.verdicts = null; tab.activeQ.vnotes = [];
    D.saveStudy(s);
    render();
  }

  const vMark = (v) => (v === 'correct' ? '✔ correct' : '✘ incorrect');
  function resultText(q, verdicts, notes, ok, attempt) {
    const lines = q.parts.map((p, i) => {
      const g = q.given?.[i] ?? '';
      const shown = p.kind === 'choice' ? (p.options[Number(g)]?.text || `option ${Number(g) + 1}`) : (p.kind === 'math' ? `$${g}$` : g);
      return `- ${q.parts.length > 1 ? `(${String.fromCharCode(97 + i)}) ` : ''}${vMark(verdicts[i])} — you answered ${shown || '(blank)'}${notes[i] ? `; ${notes[i]}` : ''}`;
    });
    const head = ok ? `**All correct.**` : (attempt > 1 ? `**Not yet — attempt ${attempt}.**` : `**Some parts are off.**`);
    return head + '\n' + lines.join('\n');
  }

  async function checkAnswers() {
    const s0 = D.loadStudy();
    const tab0 = curTab(s0);
    if (!tab0 || !tab0.activeQ || ui.busy) return;
    // read the fields into given[]
    for (const el of pageRoot.querySelectorAll('.st-answer')) tab0.activeQ.given[Number(el.dataset.part)] = el.value ?? '';
    for (const box of pageRoot.querySelectorAll('.st-choices')) {
      const i = Number(box.dataset.part);
      const picked = box.querySelector('input:checked');
      tab0.activeQ.given[i] = picked ? picked.value : '';
    }
    D.saveStudy(s0);
    ui.busy = 'grading'; render();

    const q = D.normQuestion(tab0.activeQ);
    q.given = tab0.activeQ.given.slice();
    const verdicts = [], notes = [];
    const unsure = [];
    for (let i = 0; i < q.parts.length; i++) {
      const v = await D.checkPart(q.parts[i], q.given[i]);
      verdicts[i] = v; notes[i] = '';
      if (v === 'unsure') unsure.push(i);
    }
    // Tier 3 — the AI judge (gateway), best-effort. If it is unavailable or
    // does not return usable verdicts, an unsure answer is marked incorrect,
    // exactly as Atlas falls back.
    if (unsure.length && aiOn()) {
      try {
        const items = unsure.map((i) => ({ n: i, question: q.intro, expected: q.parts[i].answer, given: q.given[i], rule: D.partRule(q.parts[i]) }));
        const res = await AI().judge(items);
        for (const vr of (res && res.verdicts) || []) {
          if (typeof vr.n !== 'number') continue;
          verdicts[vr.n] = vr.correct ? 'correct' : 'incorrect';
          if (vr.note) notes[vr.n] = String(vr.note);
        }
      } catch { /* fall through to the incorrect default below */ }
    }
    for (let i = 0; i < verdicts.length; i++) if (verdicts[i] === 'unsure') verdicts[i] = 'incorrect';
    const ok = verdicts.every((v) => v === 'correct');

    const s = D.loadStudy();
    const tab = s.tabs.find((x) => x.id === tab0.id);
    if (!tab || !tab.activeQ) { ui.busy = false; render(); return; }
    const first = (tab.activeQ.attempts || 0) === 0;
    if (first) D.recordCat(tab, q.category, ok);
    tab.activeQ.attempts = (tab.activeQ.attempts || 0) + 1;
    tab.chat.push({ role: 'result', text: resultText(q, verdicts, notes, ok, tab.activeQ.attempts) });
    if (ok) tab.activeQ = null;
    else { tab.activeQ.verdicts = verdicts; tab.activeQ.vnotes = notes; }
    D.saveStudy(s);
    ui.busy = false; render();
  }

  function keepGenerated() {
    const s = D.loadStudy();
    const tab = curTab(s);
    if (!tab || !tab.activeQ || tab.activeQ.bankId) return;
    const q = D.normQuestion(tab.activeQ);
    tab.questions.push(q);
    tab.activeQ.bankId = q.id;
    D.saveStudy(s);
    render();
  }

  /* ───────────── view 2 — question bank ───────────── */

  const ruleBadge = (p) => p.kind === 'choice' ? `choice of ${p.options.length}`
    : p.kind === 'text' ? 'text'
      : p.check === 'numeric' ? `decimal ±${p.tolerancePct}%`
        : p.check === 'form' ? `form: ${p.form || 'as requested'}` : 'exact value';

  const partAnswerHTML = (p) => p.kind === 'choice' ? (p.options[Number(p.answer)]?.text ? stMD(p.options[Number(p.answer)].text) : `option ${Number(p.answer) + 1}`)
    : p.kind === 'math' ? inlineMath(p.answer) : esc(p.answer);

  function bankView(tab) {
    const byCat = {};
    for (const q of tab.questions) (byCat[q.category] ??= []).push(q);
    const cats = Object.keys(byCat).sort();
    return `<div class="st-bank">
      <div class="st-banktools">
        <button type="button" class="st-btn" data-st="q-add">+ Add question</button>
        <span class="st-note">AI extraction from uploaded files is not available in Bridge yet (the gateway send carries text only). Author questions here — the tutor grades them.</span>
      </div>
      ${tab.questions.length ? cats.map((c) => catSection(c, byCat[c], tab.catStats[c])).join('') : '<div class="st-empty"><b>This bank is empty.</b><p>Add a question, or ask the tutor to <b>Quiz me</b> once there is one.</p></div>'}
    </div>`;
  }

  function catSection(cat, qs, stat) {
    const pct = D.catPct(stat);
    return `<section class="st-catsec">
      <div class="st-cathead">
        <span class="st-cathead__name">${esc(cat)}</span>
        <span class="st-count">${qs.length} question${qs.length === 1 ? '' : 's'}</span>
        ${pct == null ? '<span class="st-acc st-acc--none">not attempted</span>' : `<span class="st-acc${pct < 60 ? ' is-low' : ''}">${pct}% accuracy</span>`}
      </div>
      ${qs.map((q) => `<div class="st-qrow">
        <div class="st-qrow__body">
          ${q.intro ? `<div class="st-qintro">${stMD(q.intro)}</div>` : ''}
          ${figsHTML(q)}
          ${q.parts.map((p, i) => `<div class="st-ans">
            ${p.prompt ? `<span class="st-ans__p">${stMD(p.prompt)}</span>` : ''}
            <span class="st-ans__a">${partAnswerHTML(p)}</span>
            <span class="st-ans__rule">${esc(ruleBadge(p))}</span>
          </div>`).join('')}
        </div>
        <div class="st-qrow__acts">
          <button type="button" class="st-iconbtn" data-st="q-edit" data-id="${q.id}" aria-label="Edit">✎</button>
          <button type="button" class="st-iconbtn" data-st="q-del" data-id="${q.id}" aria-label="Delete">×</button>
        </div>
      </div>`).join('')}
    </section>`;
  }

  /* ───────────── question editor modal ───────────── */

  let overlay = null;
  function openModal(m) {
    ui.modal = m;
    if (!overlay) {
      overlay = document.createElement('div');
      overlay.className = 'st-overlay';
      overlay.addEventListener('click', onModalClick);
      overlay.addEventListener('input', onModalInput);
      overlay.addEventListener('change', onModalInput);
      document.body.appendChild(overlay);
    }
    renderModal();
  }
  function closeModal() {
    if (overlay) { overlay.remove(); overlay = null; }
    ui.modal = null;
  }

  /* ---- confirm-deletion modal ----
     WKWebView here implements no runJavaScriptConfirmPanel, so window.confirm()
     just returns false and a native confirm never appears — which is why the
     delete buttons "did nothing". Route deletes through this in-page modal. */
  let confirmOverlay = null;
  function closeConfirm() { if (confirmOverlay) { confirmOverlay.remove(); confirmOverlay = null; } }
  function askConfirm(message, onYes) {
    closeConfirm();
    confirmOverlay = document.createElement('div');
    confirmOverlay.className = 'st-overlay st-overlay--confirm';
    confirmOverlay.innerHTML = `<div class="st-panel st-panel--sm"><div class="st-confirm">
      <p>${esc(message)}</p>
      <div class="st-confirm__acts">
        <button type="button" class="st-btn st-btn--ghost" data-cf="no">Cancel</button>
        <button type="button" class="st-btn st-btn--danger" data-cf="yes">Delete</button>
      </div>
    </div></div>`;
    confirmOverlay.addEventListener('click', (e) => {
      if (e.target === confirmOverlay) { closeConfirm(); return; } // click the backdrop = cancel
      const b = e.target.closest('[data-cf]');
      if (!b) return;
      const yes = b.dataset.cf === 'yes';
      closeConfirm();
      if (yes) onYes();
    });
    document.body.appendChild(confirmOverlay);
    const yesBtn = confirmOverlay.querySelector('[data-cf="yes"]');
    if (yesBtn) yesBtn.focus();
  }
  function renderModal() {
    if (!overlay || !ui.modal) return;
    overlay.innerHTML = `<div class="st-panel">
      <div class="st-panel__head"><b>${ui.modal.id ? 'Edit question' : 'Add question'}</b><button type="button" class="st-iconbtn" data-st="m-close" aria-label="Close">×</button></div>
      <div class="st-panel__body">${qEditorHTML(ui.modal)}</div>
    </div>`;
    if (depsReady()) { tuneMathFields(overlay); fitEquations(overlay); }
  }
  const KINDS = [['math', 'Math'], ['text', 'Text'], ['choice', 'Multiple choice']];
  const MATH_CHECKS = [['equiv', 'exact / equivalent'], ['numeric', 'decimal within tolerance'], ['form', 'specific form required']];
  function qEditorHTML(m) {
    const d = m.draft;
    return `${m.error ? `<p class="st-err">${esc(m.error)}</p>` : ''}
      <label class="st-flabel">Category<input class="st-field" data-stf="cat" value="${esc(d.category || '')}" placeholder="e.g. derivatives"></label>
      <label class="st-flabel">Intro / stem (optional)<textarea class="st-field" data-stf="intro" rows="2" placeholder="Shared setup — supports $…$ math">${esc(d.intro || '')}</textarea></label>
      <div class="st-pedit-list">
        ${d.parts.map((p, i) => `<div class="st-pedit" data-i="${i}">
          <div class="st-pedit__head">
            <span>Part ${d.parts.length > 1 ? String.fromCharCode(97 + i) : ''}</span>
            <select class="st-field st-field--sel" data-stf="kind" data-i="${i}">${KINDS.map(([k, l]) => `<option value="${k}"${p.kind === k ? ' selected' : ''}>${l}</option>`).join('')}</select>
            ${p.kind === 'math' ? `<select class="st-field st-field--sel" data-stf="check" data-i="${i}">${MATH_CHECKS.map(([k, l]) => `<option value="${k}"${p.check === k ? ' selected' : ''}>${l}</option>`).join('')}</select>` : ''}
            ${p.kind === 'math' && p.check === 'numeric' ? `<label class="st-tol">±<input class="st-field" data-stf="tol" data-i="${i}" value="${esc(p.tolerancePct || 1)}" style="width:3.4em">%</label>` : ''}
            ${d.parts.length > 1 ? `<button type="button" class="st-iconbtn" data-st="p-del" data-i="${i}" aria-label="Remove part">×</button>` : ''}
          </div>
          <input class="st-field" data-stf="prompt" data-i="${i}" value="${esc(p.prompt || '')}" placeholder="Prompt for this part (optional)">
          ${p.kind === 'math' && p.check === 'form' ? `<input class="st-field" data-stf="form" data-i="${i}" value="${esc(p.form || '')}" placeholder="required form, e.g. a+bi">` : ''}
          <div class="st-pedit__ans">
            ${p.kind === 'choice' ? choiceEditorHTML(p, i)
        : p.kind === 'math' ? `<math-field class="pw-mathfield" data-stf="p-answer" data-i="${i}" math-virtual-keyboard-policy="manual">${esc(p.answer || '')}</math-field>`
          : `<input class="st-field" data-stf="p-answer" data-i="${i}" value="${esc(p.answer || '')}" placeholder="answer">`}
          </div>
        </div>`).join('')}
      </div>
      <div class="st-panel__acts">
        <button type="button" class="st-btn st-btn--ghost" data-st="p-add">+ Add part</button>
        <button type="button" class="st-btn" data-st="m-save">${m.id ? 'Save changes' : 'Add to bank'}</button>
      </div>`;
  }
  function choiceEditorHTML(p, i) {
    const opts = p.options && p.options.length ? p.options : [{ text: '' }, { text: '' }];
    return `<div class="st-choice-edit" data-i="${i}">
      ${opts.map((o, k) => `<label class="st-choice-edit__row">
        <input type="radio" name="st-correct-${i}" data-stf="p-correct" data-i="${i}" data-k="${k}"${String(p.answer) === String(k) ? ' checked' : ''}>
        <input class="st-field" data-stf="p-opt" data-i="${i}" data-k="${k}" value="${esc(o.text || '')}" placeholder="option ${k + 1}">
      </label>`).join('')}
      <button type="button" class="st-btn st-btn--ghost st-btn--sm" data-st="opt-add" data-i="${i}">+ option</button>
    </div>`;
  }
  function blankDraft() { return { category: '', intro: '', parts: [{ kind: 'math', check: 'equiv', tolerancePct: 1, form: '', answer: '', options: [], prompt: '' }] }; }
  function saveQuestion() {
    const m = ui.modal; if (!m) return;
    // read draft from the DOM
    readDraftFromDOM(m);
    const d = m.draft;
    if (!d.parts.some((p) => (p.kind === 'choice' ? p.options.some((o) => o.text) : String(p.answer).trim()))) { m.error = 'Give at least one part an answer.'; renderModal(); return; }
    const s = D.loadStudy();
    const tab = curTab(s);
    if (!tab) return;
    const q = D.normQuestion({ id: m.id || undefined, category: d.category, intro: d.intro, parts: d.parts });
    const idx = tab.questions.findIndex((x) => x.id === q.id);
    if (idx >= 0) tab.questions[idx] = q; else tab.questions.push(q);
    D.saveStudy(s);
    closeModal();
    render();
  }
  function readDraftFromDOM(m) {
    if (!overlay) return;
    const d = m.draft;
    const catEl = overlay.querySelector('[data-stf="cat"]'); if (catEl) d.category = catEl.value;
    const introEl = overlay.querySelector('[data-stf="intro"]'); if (introEl) d.intro = introEl.value;
    overlay.querySelectorAll('.st-pedit').forEach((pe) => {
      const i = Number(pe.dataset.i); const p = d.parts[i]; if (!p) return;
      const promptEl = pe.querySelector('[data-stf="prompt"]'); if (promptEl) p.prompt = promptEl.value;
      const ansEl = pe.querySelector('[data-stf="p-answer"]'); if (ansEl) p.answer = ansEl.value ?? '';
      const formEl = pe.querySelector('[data-stf="form"]'); if (formEl) p.form = formEl.value;
      const tolEl = pe.querySelector('[data-stf="tol"]'); if (tolEl) p.tolerancePct = Number(tolEl.value) || 1;
      if (p.kind === 'choice') {
        const opts = [];
        pe.querySelectorAll('[data-stf="p-opt"]').forEach((o) => { opts[Number(o.dataset.k)] = { text: o.value }; });
        p.options = opts.filter(Boolean);
        const correct = pe.querySelector('[data-stf="p-correct"]:checked');
        p.answer = correct ? correct.dataset.k : '0';
      }
    });
  }

  /* ───────────── event delegation ───────────── */

  async function onClick(e) {
    const t = e.target.closest('[data-st]');
    if (!t) return;
    const st = t.dataset.st, id = t.dataset.id, i = t.dataset.i != null ? Number(t.dataset.i) : null;
    const s = D.loadStudy();
    const tab = curTab(s);
    switch (st) {
      case 'tab-add': { const n = D.newTab('New course'); const s2 = D.loadStudy(); s2.tabs.push(n); s2.active = n.id; D.saveStudy(s2); ui.rename = n.id; render(); break; }
      case 'tab-pick': { if (id && id !== s.active) { s.active = id; D.saveStudy(s); ui.tool = 'study'; render(); } break; }
      case 'tab-rename': { ui.rename = id; render(); break; }
      case 'tab-del': {
        e.stopPropagation();
        const doomed = D.loadStudy().tabs.find((x) => x.id === id);
        askConfirm('Delete “' + (doomed ? doomed.name : 'this course') + '”? Its question bank and tutor chat go with it. This cannot be undone.', () => {
          const s2 = D.loadStudy(); s2.tabs = s2.tabs.filter((x) => x.id !== id); if (s2.active === id) s2.active = s2.tabs[0]?.id || ''; D.saveStudy(s2); render();
        });
        break;
      }
      case 'tool': { ui.tool = t.dataset.tool === 'bank' ? 'bank' : 'study'; render(); break; }
      case 'chat-send': { const inp = pageRoot.querySelector('#st-chat-in'); await doSend(inp ? inp.value : ''); break; }
      case 'chat-quiz': { quizMe(); break; }
      case 'chat-clear': { const s2 = D.loadStudy(); const tb = curTab(s2); if (tb) { tb.chat = []; tb.activeQ = null; D.saveStudy(s2); render(); } break; }
      case 'q-check': { await checkAnswers(); break; }
      case 'q-keep': { keepGenerated(); break; }
      case 'q-close': { const s2 = D.loadStudy(); const tb = curTab(s2); if (tb) { tb.activeQ = null; D.saveStudy(s2); render(); } break; }
      case 'q-add': { openModal({ id: null, draft: blankDraft(), error: '' }); break; }
      case 'q-edit': { const q = tab && tab.questions.find((x) => x.id === id); if (q) openModal({ id: q.id, draft: draftFromQ(q), error: '' }); break; }
      case 'q-del': {
        askConfirm('Delete this question from the bank? This cannot be undone.', () => {
          const s2 = D.loadStudy(); const tb = curTab(s2); if (tb) { tb.questions = tb.questions.filter((x) => x.id !== id); D.saveStudy(s2); render(); }
        });
        break;
      }
      default: break;
    }
  }

  function draftFromQ(q) {
    return { category: q.category, intro: q.intro, parts: q.parts.map((p) => ({ kind: p.kind, check: p.check, tolerancePct: p.tolerancePct, form: p.form, answer: p.answer, options: p.options.map((o) => ({ text: o.text })), prompt: p.prompt })) };
  }

  function onInput(e) {
    // per-keystroke persistence of activeQ answers, so a re-render doesn't drop them
    if (e.target.classList && e.target.classList.contains('st-answer') && e.target.dataset.part != null) {
      const s = D.loadStudy(); const tab = curTab(s);
      if (tab && tab.activeQ) { tab.activeQ.given[Number(e.target.dataset.part)] = e.target.value ?? ''; D.saveStudy(s); }
    }
  }
  function onChange(e) {
    if (e.target.type === 'radio' && e.target.closest('.st-choices')) {
      const box = e.target.closest('.st-choices'); const s = D.loadStudy(); const tab = curTab(s);
      if (tab && tab.activeQ) { tab.activeQ.given[Number(box.dataset.part)] = e.target.value; D.saveStudy(s); }
    }
  }
  function onDblClick(e) {
    const name = e.target.closest('.st-tab__name');
    if (name && name.dataset.id) { ui.rename = name.dataset.id; render(); }
  }
  function commitRename(value) {
    if (ui.rename == null) return;
    const s = D.loadStudy(); const t = s.tabs.find((x) => x.id === ui.rename);
    if (t) { t.name = String(value || '').trim() || t.name; D.saveStudy(s); }
    ui.rename = null; render();
  }

  /* ---- modal events ---- */

  function onModalClick(e) {
    const t = e.target.closest('[data-st]'); if (!t) return;
    const st = t.dataset.st, i = t.dataset.i != null ? Number(t.dataset.i) : null;
    switch (st) {
      case 'm-close': closeModal(); render(); break;
      case 'p-add': { readDraftFromDOM(ui.modal); ui.modal.draft.parts.push({ kind: 'math', check: 'equiv', tolerancePct: 1, form: '', answer: '', options: [], prompt: '' }); renderModal(); break; }
      case 'p-del': { readDraftFromDOM(ui.modal); ui.modal.draft.parts.splice(i, 1); renderModal(); break; }
      case 'opt-add': { readDraftFromDOM(ui.modal); const p = ui.modal.draft.parts[i]; (p.options ||= []).push({ text: '' }); renderModal(); break; }
      case 'm-save': saveQuestion(); break;
      default: break;
    }
  }
  function onModalInput(e) {
    const m = ui.modal; if (!m) return;
    const stf = e.target.dataset.stf; const i = e.target.dataset.i != null ? Number(e.target.dataset.i) : null;
    if (stf === 'kind') { readDraftFromDOM(m); m.draft.parts[i].kind = e.target.value; if (e.target.value === 'choice' && !(m.draft.parts[i].options || []).length) m.draft.parts[i].options = [{ text: '' }, { text: '' }]; renderModal(); return; }
    if (stf === 'check') { readDraftFromDOM(m); m.draft.parts[i].check = e.target.value; renderModal(); return; }
    // other fields are read on save / on structural change
  }

  /* ───────────── document-level key handling ───────────── */

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && confirmOverlay) { e.preventDefault(); closeConfirm(); return; }
    if (!pageRoot) return;
    if (e.target.id === 'st-chat-in' && e.key === 'Enter') { e.preventDefault(); doSend(e.target.value); return; }
    if (e.target.id === 'st-rename') {
      if (e.key === 'Enter') { e.preventDefault(); commitRename(e.target.value); }
      else if (e.key === 'Escape') { e.preventDefault(); ui.rename = null; render(); }
      return;
    }
    if (e.target.classList && e.target.classList.contains('st-answer') && e.key === 'Enter' && e.target.tagName !== 'MATH-FIELD') { e.preventDefault(); checkAnswers(); return; }
    if (e.key === 'Escape' && ui.modal) { closeModal(); render(); }
  });

  /* ───────────── entry points (called by app.js) ───────────── */

  window.StudyUI = {
    // Build (or rebuild for a different tool) the persistent study page inside
    // `root`. app.js keeps `root` across re-renders and only calls this on a
    // real (re)entry, so the live math-fields are not blown away by the app's
    // per-event render cadence.
    attach(root, opts) {
      pageRoot = root;
      toolId = opts && opts.toolId;
      root.onclick = onClick;
      root.oninput = onInput;
      root.onchange = onChange;
      root.ondblclick = onDblClick;
      if (AI() && AI().setTool) AI().setTool(toolId);
      if (depsReady()) render();
      else { render(); loadDeps().then(() => render()).catch(() => render()); }
    },
    // Called on each app render while the study tool is already mounted: nothing
    // to rebuild (the page renders on its own actions and awaited gateway
    // turns), but keep the hook so app.js has a stable contract.
    sync() { /* intentionally light — see attach() */ },
    // The native store arrived (boot seed / reconnect) after the page mounted —
    // re-render so the freshly-seeded localStorage is reflected.
    reload() { if (pageRoot && pageRoot.isConnected) render(); },
    mounted() { return !!(pageRoot && pageRoot.isConnected); },
    toolId() { return toolId; },
  };
})();
