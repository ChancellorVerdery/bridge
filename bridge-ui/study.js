/* Study tool — data layer + grading, ported from Atlas's study plugin
   (atlas-ui/src/page/study.js). Tabs = courses; each holds a question bank and
   per-category accuracy and the chat transcript. Store `bridge.study.v1` in
   localStorage — this Mac only, not synced to the gateway.

   TWO CHANGES from Atlas: (1) no ES modules — everything hangs off the global
   `Study` object, because Bridge's UI is flat vanilla JS with no bundler.
   (2) the ~1MB Compute Engine is the VENDORED global `window.ComputeEngine`
   (lazy-loaded by studyui.js before any grading call) rather than a bundler's
   dynamic import. The grading tiers are otherwise a verbatim lift — it is the
   money path, so it is not rewritten.

   The AI calls (tutor chat / answer judge / extraction) do NOT live here: in
   Atlas they were dev-server middleware; in Bridge they are gateway turns, and
   they live in live.js as `window.StudyAI` because they need the socket. */

(function () {
  'use strict';

  const KEY = 'bridge.study.v1';

  const uid = (p) => `${p}-${Date.now().toString(36)}${Math.random().toString(36).slice(2, 7)}`;

  // ---- store ---------------------------------------------------------------

  // Claude sometimes double-escapes its JSON strings: the text arrives holding
  // literal backslash-n pairs where newlines were meant, and doubled
  // backslashes before LaTeX commands ("\\sqrt"), which MathLive renders as a
  // row break plus italic letters. Repair deterministically; applied in every
  // normalizer, so already-stored corrupted text heals on load.

  // Math-safe half: \\<letter or ,;:!> → \<…>. A real row separator (matrix \\)
  // is followed by whitespace/&, never directly by a letter or spacing command.
  // For bare-LaTeX fields (answers) — never converts \n, which may open \nabla.
  const fixSlashes = (s) => String(s ?? '').replace(/\\\\(?=[a-zA-Z,;:!])/g, '\\');

  // Prose half: backslash-n means nothing OUTSIDE math, so there it is always a
  // mistyped newline; INSIDE $…$/$$…$$ segments it may open \nabla/\neq/\nu and
  // is left alone. For prose fields: intros, prompts, chat.
  const MATH_SEG = /(\$\$[\s\S]*?\$\$|\$[^$\n]*\$)/;
  const fixEscapes = (s) => fixSlashes(s)
    .split(MATH_SEG)
    .map((seg, i) => (i % 2 ? seg : seg.replace(/\\n/g, '\n')))
    .join('');

  const CHECKS = new Set(['equiv', 'numeric', 'form']);

  function normPart(p) {
    let kind = p?.kind === 'text' ? 'text' : p?.kind === 'choice' ? 'choice' : 'math';
    let options = [];
    let answer = String(p?.answer ?? '');
    if (kind === 'choice') {
      options = (Array.isArray(p?.options) ? p.options : [])
        .map((o) => ({ text: fixEscapes(o?.text), figure: String(o?.figure ?? '') }))
        .filter((o) => o.text || o.figure);
      if (options.length < 2) { kind = 'text'; options = []; } // a "choice" with one option is just a question
      else answer = String(Math.min(Math.max(Math.trunc(+answer) || 0, 0), options.length - 1));
    }
    return {
      prompt: fixEscapes(p?.prompt),
      kind,
      answer: kind === 'choice' ? answer : fixSlashes(answer), // answers are bare LaTeX — math-safe repair only
      check: kind === 'text' ? 'text' : kind === 'choice' ? 'choice' : CHECKS.has(p?.check) ? p.check : 'equiv',
      tolerancePct: Number.isFinite(+p?.tolerancePct) && +p.tolerancePct > 0 ? +p.tolerancePct : 1,
      form: String(p?.form ?? ''),
      options,
    };
  }

  function normQuestion(q) {
    return {
      id: typeof q?.id === 'string' && q.id ? q.id : uid('q'),
      category: String(q?.category ?? '').toLowerCase().trim() || 'general',
      intro: fixEscapes(q?.intro),
      figures: (Array.isArray(q?.figures) ? q.figures : []).map(String).filter(Boolean),
      parts: (Array.isArray(q?.parts) && q.parts.length ? q.parts : [{}]).map(normPart),
    };
  }

  function normTab(t) {
    const tab = {
      id: typeof t?.id === 'string' && t.id ? t.id : uid('t'),
      name: String(t?.name ?? 'Course'),
      questions: (Array.isArray(t?.questions) ? t.questions : []).map(normQuestion),
      catStats: {},
      chat: (Array.isArray(t?.chat) ? t.chat : [])
        .filter((m) => m && typeof m.text === 'string')
        .map((m) => ({ role: ['tutor', 'you', 'result', 'sys'].includes(m.role) ? m.role : 'sys', text: fixEscapes(m.text) })),
      activeQ: null,
    };
    for (const [k, v] of Object.entries(t?.catStats && typeof t.catStats === 'object' ? t.catStats : {})) {
      const attempts = Math.max(Math.trunc(+v?.attempts) || 0, 0);
      if (attempts) tab.catStats[k] = { attempts, correct: Math.min(Math.max(Math.trunc(+v?.correct) || 0, 0), attempts) };
    }
    if (t?.activeQ && typeof t.activeQ === 'object') {
      tab.activeQ = normQuestion(t.activeQ);
      tab.activeQ.bankId = typeof t.activeQ.bankId === 'string' ? t.activeQ.bankId : null;
      tab.activeQ.given = Array.isArray(t.activeQ.given) ? t.activeQ.given.map((g) => String(g ?? '')) : [];
      // retry state: a missed question stays open (the tutor coaches through it)
      tab.activeQ.attempts = Math.max(Math.trunc(+t.activeQ.attempts) || 0, 0);
      tab.activeQ.verdicts = Array.isArray(t.activeQ.verdicts) ? t.activeQ.verdicts.map((v) => (v === 'correct' ? 'correct' : 'incorrect')) : null;
      tab.activeQ.vnotes = Array.isArray(t.activeQ.vnotes) ? t.activeQ.vnotes.map(String) : [];
    }
    return tab;
  }

  function loadStudy() {
    let s;
    try { s = JSON.parse(localStorage.getItem(KEY)) || {}; } catch { s = {}; }
    const out = { tabs: (Array.isArray(s.tabs) ? s.tabs : []).map(normTab), active: typeof s.active === 'string' ? s.active : '' };
    if (!out.tabs.some((t) => t.id === out.active)) out.active = out.tabs[0]?.id || '';
    return out;
  }

  function saveStudy(s) {
    for (const t of s.tabs) if (t.chat.length > 60) t.chat = t.chat.slice(-60); // cap transcripts
    const str = JSON.stringify(s);
    localStorage.setItem(KEY, str);
    // Mirror to Bridge's native file store — the WebView is ephemeral, so this
    // (not localStorage) is what actually survives a relaunch.
    if (typeof window.__studyPersist === 'function') window.__studyPersist(str);
  }

  const newTab = (name) => normTab({ name });

  // ---- category accuracy ---------------------------------------------------

  function recordCat(tab, category, correct) {
    const c = (tab.catStats[category] ??= { attempts: 0, correct: 0 });
    c.attempts++;
    if (correct) c.correct++;
  }

  const catPct = (stat) => (stat?.attempts ? Math.round((100 * stat.correct) / stat.attempts) : null);

  // ---- grading -------------------------------------------------------------
  // Tier 1: Compute Engine symbolic equality (partial fractions ≡ combined
  // form, trig identities, ½ ≡ 0.5 …). Tier 2: numeric sampling — isEqual
  // returns undefined (not false) when it can't prove equality, so random-point
  // evaluation settles most wrong answers instantly and free. Tier 3 ('unsure')
  // is the caller's cue to ask the AI judge (form requirements, unparseable
  // input, text answers beyond exact match).

  // The vendored Compute Engine is the global window.ComputeEngine, injected by
  // studyui.js's loadStudyDeps() before any grading call. These memoize the
  // engine instance the way Atlas's dynamic import did.
  let cePromise = null;
  const getCE = () => (cePromise ??= Promise.resolve(new window.ComputeEngine.ComputeEngine()));

  // Second engine at 30-digit precision with a tight tolerance, used only to
  // settle "exact value wanted, decimal offered": the default engine's isEqual
  // compares constants at ~1e-10 tolerance and happily declares
  // 3.1415926536 ≡ π.
  let ceStrictPromise = null;
  const getStrictCE = () => (ceStrictPromise ??= Promise.resolve((() => {
    const ce = new window.ComputeEngine.ComputeEngine();
    ce.precision = 30;
    ce.tolerance = 1e-25;
    return ce;
  })()));

  const finite = (x) => typeof x === 'number' && isFinite(x);
  const numOK = (v) => v && finite(v.re) && finite(v.im ?? 0);

  // Sign of variable v on probe k. The first probes are DETERMINISTIC — all
  // positive, then all negative, then alternating — so an answer that agrees
  // only on one side of zero (x vs \sqrt{x^2}) is refuted every time instead of
  // slipping through whenever a random run happens to draw 5 positives.
  const probeSign = (k, i) => (k === 0 ? 1 : k === 1 ? -1 : k < 6 ? ((k + i) % 2 ? -1 : 1) : (Math.random() < 0.5 ? -1 : 1));

  // Compare a and b at sample points over the union of their unknowns.
  // 'incorrect' on any confident mismatch, 'correct' after enough agreeing
  // samples, 'unsure' when the expressions won't evaluate numerically.
  function sampleCompare(a, b) {
    const vars = [...new Set([...a.unknowns, ...b.unknowns])];
    let agreed = 0;
    for (let k = 0; k < 14 && agreed < 5; k++) {
      const at = {};
      vars.forEach((v, i) => { at[v] = probeSign(k, i) * (Math.random() * 2.5 + 0.3); });
      let av, bv;
      try { av = a.subs(at).N(); bv = b.subs(at).N(); } catch { return 'unsure'; }
      if (!numOK(av) || !numOK(bv)) continue; // outside the domain here — reprobe
      const scale = Math.max(1, Math.hypot(bv.re, bv.im ?? 0));
      // 1e-9 (not 1e-6): a calculator-rounded decimal like 0.333333x is NOT
      // "any equivalent form" of x/3, but float noise never reaches this size.
      if (Math.hypot(av.re - bv.re, (av.im ?? 0) - (bv.im ?? 0)) > 1e-9 * scale) return 'incorrect';
      agreed++;
    }
    return agreed >= 3 ? 'correct' : 'unsure';
  }

  // ± has no single value: Compute Engine parses \pm 3 as a Measurement whose
  // N() is the CENTRE (0), which would mark both real roots wrong and the
  // meaningless midpoint right. Structural equality still settles ± vs the same
  // ±; anything else is a judgement call about how much of the answer is there.
  const HAS_PM = /\\pm|\\mp/;

  async function checkMath(expected, given, check, tolerancePct) {
    const ce = await getCE();
    let a, b;
    try { a = ce.parse(String(given)); b = ce.parse(String(expected)); } catch { return 'unsure'; }
    if (!a.isValid || !b.isValid) return 'unsure';
    // Exact value wanted but a bare decimal offered against a symbolic key:
    // BOTH default tiers lie here — isEqual's ~1e-10 tolerance declares
    // 3.1415926536 ≡ π, and sampling can't tell them apart either. The strict
    // engine settles it exactly: truly-equal decimals (0.5 vs ½) pass, rounded
    // approximations of an exact value are simply incorrect. (± keys skip this
    // — a decimal could match one root, which is the judge's call below.)
    if (check === 'equiv' && /^-?\d+\.\d+$/.test(String(given).trim())
      && /[a-zA-Z\\]/.test(String(expected)) && !HAS_PM.test(String(expected))) {
      const sce = await getStrictCE();
      const eq = sce.parse(String(given)).isEqual(sce.parse(String(expected)));
      return eq === true ? 'correct' : eq === false ? 'incorrect' : 'unsure';
    }
    if (a.isEqual(b) === true) return check === 'form' ? 'unsure' : 'correct';
    if (HAS_PM.test(String(expected)) || HAS_PM.test(String(given))) return 'unsure';
    if (check === 'numeric') {
      const av = a.N(), bv = b.N();
      if (!numOK(av) || !numOK(bv)) return 'unsure';
      const tol = (Number(tolerancePct) > 0 ? Number(tolerancePct) : 1) / 100;
      // hypot over re AND im: comparing real parts alone graded 5i ≡ 3i correct.
      const scale = Math.hypot(bv.re, bv.im ?? 0);
      return Math.hypot(av.re - bv.re, (av.im ?? 0) - (bv.im ?? 0)) <= Math.max(scale * tol, 1e-9) ? 'correct' : 'incorrect';
    }
    const verdict = sampleCompare(a, b);
    // 'form': equivalence is necessary but not sufficient — an equivalent answer
    // still needs the judge to confirm it's written in the required form.
    if (check === 'form' && verdict === 'correct') return 'unsure';
    return verdict;
  }

  const normText = (s) => String(s ?? '').toLowerCase().replace(/\s+/g, ' ').trim().replace(/[.?!]+$/, '');

  // Exact (normalized) text match is definitive; anything else goes to the
  // judge — synonyms and equivalent phrasing are a language call, not ours.
  const checkText = (expected, given) => (normText(expected) === normText(given) ? 'correct' : 'unsure');

  async function checkPart(part, given) {
    if (!String(given ?? '').trim()) return 'incorrect';
    if (part.kind === 'choice') return String(given).trim() === part.answer ? 'correct' : 'incorrect';
    return part.kind === 'text' ? checkText(part.answer, given) : checkMath(part.answer, given, part.check, part.tolerancePct);
  }

  // Human rule for the AI judge (and the bank UI's check badge).
  const partRule = (part) =>
    part.kind === 'choice' ? 'multiple choice — the selected option must match'
      : part.kind === 'text' ? 'short text answer — accept equivalent phrasing/synonyms'
        : part.check === 'numeric' ? `decimal/rounded answer expected, within ${part.tolerancePct}%`
          : part.check === 'form' ? `must be written ${part.form || 'in the requested form'}; any other form is wrong even if equivalent`
            : 'EXACT value required — any mathematically equivalent exact form counts, but a rounded decimal approximation is incorrect';

  window.Study = {
    KEY, uid, fixSlashes, fixEscapes,
    normPart, normQuestion, normTab,
    loadStudy, saveStudy, newTab,
    recordCat, catPct,
    checkMath, checkText, checkPart, partRule,
  };
})();
