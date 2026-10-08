// SMT 웹 번역 — 페이지 내용 스크립트(Chrome·Whale·Safari 공용, 최상위 프레임만).
// - 글자는 DOM 텍스트 노드 값만 바꾼다(innerHTML을 바꾸지 않음). 원문은 메모리에 두고 '원문 보기'로 되돌린다.
//   링크·버튼 등 요소는 그대로라 클릭·접근성이 유지된다.
// - 이미지 속 글자는 보이는 이미지 영역만 캡처·OCR해 이미지 위에 클릭 통과(pointer-events: none) 덮개로 그린다.
//   캡처 직전에는 기존 덮개를 숨겨 자기 번역을 다시 읽지 않는다. 결과가 오는 사이 스크롤·이동이 있었으면 버린다.
// - 자동 번역은 전역 자동 번역이 켜져 있고 이 사이트 접근 권한이 있을 때만, 스크롤·변경이 생기면 바로 보이는 부분만 번역한다.
//   전역 자동 번역은 번역 버튼을 누를 때 켜지고, 원문 보기를 누르면 꺼진다(배경 스크립트가 auto 값을 내려준다).
// - 결과는 항상 텍스트(textContent / nodeValue)로만 넣고 HTML로 해석하지 않는다. 번역 캐시는 메모리에만 둔다.
(() => {
  "use strict";
  // 권한 범위(<all_urls>)와 달리 일반 웹페이지(http/https)에서만 동작한다. 파일·브라우저 내부 페이지에서는 아무것도 하지 않는다.
  if (location.protocol !== "http:" && location.protocol !== "https:") return;
  if (globalThis.__smtWebTranslatorLoaded) return;
  globalThis.__smtWebTranslatorLoaded = true;

  const api = globalThis.browser ?? globalThis.chrome;
  const MAX_UNITS = 600;
  // 웹 번역 엔진(DeepL·Google·Papago)은 SMT가 조각마다 차례로 공식 페이지에 넣으므로 한 번에 적게 보낸다.
  const LOCAL_ENGINE = "apple";
  const MAX_EXTERNAL_UNITS = 120;
  const EXTERNAL_BATCH_TEXTS = 10;
  const EXTERNAL_BATCH_CHARS = 12000;
  const MAX_WALK = 40000;
  const BATCH_TEXTS = 120;
  const BATCH_CHARS = 30000;
  const MAX_TEXT = 5000;
  const CACHE_LIMIT = 4000;
  const RECORD_LIMIT = 30000;
  const MAX_IMAGES = 8;
  // Apple Intelligence 다듬기(기기 내, Mac 기본 번역 결과만): 이미 그려진 결과 뒤에 작은 후속 요청 하나만 보낸다.
  const MAX_REFINE_ITEMS = 8;
  const LETTER = /\p{L}/u;
  const SKIP_SELECTOR = [
    "script", "style", "noscript", "template", "textarea", "input", "select", "option", "code", "pre", "kbd",
    "samp", "var", "svg", "math", "canvas", "iframe", "object", "[translate='no']", ".notranslate",
    "[contenteditable='']", "[contenteditable='true']", "smt-translator-layer"
  ].join(",");

  const FONT_STYLES = ["auto", "gothic", "myeongjo", "gungseo", "hand"];

  const state = {
    auto: false,
    images: true,
    target: "ko",
    engine: LOCAL_ENGINE,
    fontStyle: "auto",
    view: "translated",
    pageGen: 0,   // 이동·언어 변경 때 증가: 이전 결과 모두 무효
    scrollGen: 0, // 스크롤·크기 변경 때 증가: 이전 이미지 결과 무효
    url: location.href,
    stopEpoch: 0, // 마지막 원문 보기(전역 끄기) 세대: 이보다 오래된 설정·번역 시작 요청은 무시한다
    running: false,
    rerun: false,
    rerunManual: false,
    timer: 0,
    status: "대기",
    error: "",
    warning: "",
    // SMT 엔진이 최근 응답에서 알려준, 지금 이 다듬기를 보낼 수 있는지(설정 켜짐 + 기기 내 모델 가능 + Mac 기본 번역).
    aiRefine: false
  };

  /** Text 노드 → { original, translated(null이면 원문 유지), target(엔진|언어), lang(판별 언어 코드|"unknown"|null(글자없음)|생략(구버전 응답)) } */
  const records = new Map();
  /** `${엔진|언어}\u0001${원문}` → 번역문(null이면 번역하지 않음). 메모리 LRU */
  const cache = new Map();
  /** 원문(trim) → 판별 언어 코드|"unknown"|null. target과 무관하므로 cache와 별도 LRU로 둔다. */
  const langCache = new Map();
  /** img 요소 → { key, box, offX, offY, w, h, elemW, elemH, langs({언어코드|"unknown": 개수}) } */
  const imageRecords = new Map();
  let ocrInFlight = false;
  // 확장 컨텍스트가 무효화된(업데이트·재설치로 이전 페이지의 content script가 끊어진) 뒤 한 번만 정지한다.
  let contextDead = false;

  // MARK: 공통

  function isContextInvalidError(error) {
    const message = (error && error.message) || String(error || "");
    return message.includes("Extension context invalidated") || message.includes("context invalidated");
  }

  /** 컨텍스트 무효화 뒤 한 번만: 자동/재실행 끄기, 세대 올려 응답 무효화, 타이머·감시·리스너 정리,
   *  자기 번역 DOM만(지금 값이 정확히 자기 번역문일 때만) 원문으로 복원, 자기 덮개·맵 비우기. 페이지 자체·내비게이션은 그대로 둔다. */
  function retire() {
    if (contextDead) return;
    contextDead = true;
    state.auto = false;
    state.rerun = false;
    state.rerunManual = false;
    state.running = false;
    state.pageGen += 1;
    state.scrollGen += 1;
    clearTimeout(state.timer);
    state.timer = 0;
    ocrInFlight = false;
    setObserving(false);
    removeEventListener("scroll", onScroll, { capture: true });
    removeEventListener("resize", onScroll);
    document.removeEventListener("fullscreenchange", onFullscreenChange);
    document.removeEventListener("webkitfullscreenchange", onFullscreenChange);
    removeEventListener("popstate", onHistoryChange);
    removeEventListener("hashchange", onHistoryChange);
    for (const [node, record] of records) {
      if (!node.isConnected) continue;
      if (record.translated !== null && node.nodeValue === record.translated) node.nodeValue = record.original;
    }
    clearImageOverlays();
    records.clear();
    cache.clear();
    langCache.clear();
  }

  function send(message) {
    if (contextDead) {
      const error = new Error("확장 기능 연결이 끊어졌습니다.");
      error.code = "contextinvalid";
      return Promise.reject(error);
    }
    // sendMessage 호출을 Promise 실행자 안에서 해야, 컨텍스트 무효화로 동기적으로 던지는 예외도
    // 거부(rejection)로 바뀌어 호출부의 .catch가 받을 수 있다(실행자 밖에서 호출하면 동기 예외가 그대로 샌다).
    return new Promise((resolve) => resolve(api.runtime.sendMessage(message)))
      .then((response) => {
        if (!response || response.ok !== true) {
          const error = new Error(response?.message || "");
          error.code = response?.code || "error";
          throw error;
        }
        return response;
      })
      .catch((error) => {
        if (!contextDead && isContextInvalidError(error)) retire();
        if (contextDead) error.code = "contextinvalid";
        throw error;
      });
  }

  function setStatus(text) {
    state.status = text;
  }

  /** 번역 결과를 구분하는 기준: 엔진과 번역 언어가 모두 같아야 같은 결과다. */
  function profile() {
    return `${state.engine}|${state.target}`;
  }

  function isExternal() {
    return state.engine !== LOCAL_ENGINE;
  }

  function cacheKey(text) {
    return `${profile()}\u0001${text}`;
  }

  function cachePut(text, value) {
    const key = cacheKey(text);
    cache.delete(key);
    cache.set(key, value);
    while (cache.size > CACHE_LIMIT) cache.delete(cache.keys().next().value);
  }

  function cacheGet(text) {
    const key = cacheKey(text);
    if (!cache.has(key)) return undefined;
    const value = cache.get(key);
    cache.delete(key);
    cache.set(key, value);
    return value;
  }

  // 서버가 langs를 보내지 않으면(구버전) 아무 것도 기록하지 않아 통계를 지어내지 않는다.
  function langPut(text, lang) {
    langCache.delete(text);
    langCache.set(text, lang);
    while (langCache.size > CACHE_LIMIT) langCache.delete(langCache.keys().next().value);
  }

  function langGet(text) {
    if (!langCache.has(text)) return undefined;
    const value = langCache.get(text);
    langCache.delete(text);
    langCache.set(text, value);
    return value;
  }

  function nextFrames(count) {
    return new Promise((resolve) => {
      const step = (n) => (n <= 0 ? resolve() : requestAnimationFrame(() => step(n - 1)));
      step(count);
    });
  }

  // MARK: 글꼴(고딕/명조/손글씨) — 패키지에 포함한 글꼴만 쓴다(온라인 Google Fonts·사용자 설치 글꼴 의존 안 함)

  const FONT_FILES = { gothic: "fonts/NanumGothic-Regular.ttf", myeongjo: "fonts/NanumMyeongjo-Regular.ttf", gungseo: "fonts/ChosunGs.ttf", hand: "fonts/NanumPenScript-Regular.ttf" };
  const FONT_FAMILIES = { gothic: "SMTNanumGothic", myeongjo: "SMTNanumMyeongjo", gungseo: "SMTChosunGungseo", hand: "SMTNanumPen" };
  const FONT_FALLBACKS = {
    gothic: "-apple-system,BlinkMacSystemFont,system-ui,sans-serif",
    myeongjo: "'Apple SD Gothic Neo',serif",
    gungseo: "serif",
    hand: "cursive"
  };
  const fontLoadPromises = new Map();
  const opticalScaleCache = new Map();
  const OPTICAL_SAMPLE = "가나다라마바사자차카파하";
  let opticalScratchCtx = null;

  /** 같은 CSS font-size라도 손글씨(NanumPenScript)는 고딕보다 실제 잉크(글자 획)가 작게 찍힌다.
   * 두 글꼴을 같은 px로 캔버스에 재서 실제 잉크 높이(actualBoundingBox) 비율을 구해, 손글씨가
   * 화면에서 체감상 더 작아 보이지 않도록 보정 배율을 만든다. 임의의 상수가 아니라 번들 글꼴 자신의
   * 실측 글리프 치수에서 나온 값이다. */
  function inkHeight(family, px) {
    if (!opticalScratchCtx) {
      const canvas = document.createElement("canvas");
      opticalScratchCtx = canvas.getContext("2d");
    }
    if (!opticalScratchCtx) return px;
    opticalScratchCtx.font = `${px}px "${family}"`;
    const metrics = opticalScratchCtx.measureText(OPTICAL_SAMPLE);
    const ascent = metrics.actualBoundingBoxAscent;
    const descent = metrics.actualBoundingBoxDescent;
    if (!Number.isFinite(ascent) || !Number.isFinite(descent) || ascent + descent <= 0) return px;
    return ascent + descent;
  }

  async function opticalScale(style) {
    if (style === "auto" || style === "gothic") return 1;
    if (opticalScaleCache.has(style)) return opticalScaleCache.get(style);
    await Promise.all([loadBundledFont("gothic"), loadBundledFont(style)]);
    const refHeight = inkHeight(FONT_FAMILIES.gothic, 100);
    const styleHeight = inkHeight(FONT_FAMILIES[style], 100);
    let scale = styleHeight > 0 ? refHeight / styleHeight : 1;
    if (!Number.isFinite(scale)) scale = 1;
    // 손글씨가 고딕보다 더 작게 찍힐 때만 키운다(1 미만이면 보정 불필요). 실측 오차로 인한 과도한
    // 확대를 막기 위해 1.8배까지만 허용한다.
    scale = Math.min(Math.max(scale, 1), 1.8);
    opticalScaleCache.set(style, scale);
    return scale;
  }

  /** 패키지에 포함한 글꼴 파일을 FontFace API로 한 번만 불러와 document.fonts에 더한다(온라인 요청 없음). */
  function loadBundledFont(style) {
    if (style === "auto") return Promise.resolve();
    if (fontLoadPromises.has(style)) return fontLoadPromises.get(style);
    const family = FONT_FAMILIES[style];
    const file = FONT_FILES[style];
    if (!family || !file) return Promise.resolve();
    const promise = Promise.resolve()
      .then(() => new FontFace(family, `url(${api.runtime.getURL(file)})`).load())
      .then((loaded) => { document.fonts.add(loaded); return true; })
      .catch(() => false);
    fontLoadPromises.set(style, promise);
    return promise;
  }

  /** 자동 글꼴일 때 원본 글자 특징(item.fs)으로 고른 갈래, 수동이면 사용자가 고른 갈래로 확정한다. 알 수 없는
   * 값·미판별은 고딕으로 대체한다(가짜로 정확히 식별한 척하지 않음). */
  function resolveFontStyle(itemFontStyle) {
    if (state.fontStyle !== "auto" && FONT_STYLES.includes(state.fontStyle)) return state.fontStyle;
    return itemFontStyle === "myeongjo" || itemFontStyle === "hand" ? itemFontStyle : "gothic";
  }

  function fontFamilyFor(style) {
    const family = FONT_FAMILIES[style] || FONT_FAMILIES.gothic;
    const fallback = FONT_FALLBACKS[style] || FONT_FALLBACKS.gothic;
    return `"${family}",${fallback}`;
  }

  let layerHost = null;
  let layerRoot = null;

  // 전체화면(:fullscreen)에 들어간 요소는 UA가 그 요소에 position:fixed를 주어 새 포함 블록이 되므로,
  // 덮개 호스트도 같은 요소 아래에 둬야 fixed 자식과 getBoundingClientRect() 좌표가 같은 기준으로 맞는다.
  function fullscreenTarget() {
    return document.fullscreenElement || document.webkitFullscreenElement || null;
  }

  function layer() {
    const parent = fullscreenTarget() || document.documentElement;
    if (layerHost && layerHost.isConnected) {
      if (layerHost.parentNode !== parent) parent.appendChild(layerHost);
      return layerRoot;
    }
    layerHost = document.createElement("smt-translator-layer");
    layerHost.style.cssText = "all: initial; position: fixed; left: 0; top: 0; width: 0; height: 0; " +
      "z-index: 2147483647; pointer-events: none; contain: layout style;";
    layerRoot = layerHost.attachShadow({ mode: "closed" });
    const style = document.createElement("style");
    style.textContent =
      ".img{position:absolute;pointer-events:none;overflow:hidden}" +
      ".mask{position:absolute;left:0;top:0;width:100%;height:100%;pointer-events:none}" +
      // 가운데 정렬 대신 원문 기준(가로쓰기는 좌상단, 세로쓰기는 우상단에서 시작)으로 맞춘다: 원본 가로
      // 내레이션은 보통 좌측 정렬, 세로쓰기 칸은 글자가 상단부터 고른 줄간격으로 내려간다(.vert가 override).
      ".t{position:absolute;box-sizing:border-box;overflow:hidden;pointer-events:none;user-select:none;" +
      "display:flex;align-items:flex-start;justify-content:flex-start;text-align:left;background:transparent;" +
      "font-family:-apple-system,BlinkMacSystemFont,system-ui,sans-serif;line-height:1.15;white-space:normal;" +
      "word-break:keep-all;overflow-wrap:anywhere;padding:0 1px}" +
      ".t.vert{justify-content:flex-start;align-items:flex-start}" +
      // .tt(안쪽 글자 상자)는 flex-shrink:0으로 바깥 flex가 줄여 넘침을 감추지 못하게 하고, overflow는 기본
      // visible로 둬 scrollWidth/scrollHeight가 바깥 .t(overflow:hidden, 가운데 정렬)의 뒤틀린 값 대신 글자
      // 자신의 실제 필요한 크기를 그대로 보여주게 한다(가운데 정렬된 내용은 앞쪽으로 넘친 만큼이 scrollWidth에
      // 반영되지 않을 수 있는 브라우저 동작을 피한다). 치수(width/height)는 fitFontSize가 측정 전에 직접 both 넣는다.
      ".tt{display:inline-block;flex-shrink:0;max-width:none;max-height:none}";
    layerRoot.appendChild(style);
    parent.appendChild(layerHost);
    applyLayerVisibility();
    return layerRoot;
  }

  function applyLayerVisibility() {
    if (layerHost) layerHost.style.visibility = state.view === "translated" ? "visible" : "hidden";
  }

  function clearImageOverlays() {
    for (const record of imageRecords.values()) record.box.remove();
    imageRecords.clear();
  }

  // MARK: 텍스트 수집(보이는 부분 위주)

  const range = document.createRange();

  function inBand(rect, margin) {
    return rect.width > 0 && rect.height > 0 && rect.bottom >= -margin && rect.top <= innerHeight + margin &&
      rect.right >= 0 && rect.left <= innerWidth;
  }

  function collectUnits() {
    const body = document.body;
    if (!body) return [];
    const margin = innerHeight * 0.5;
    const parentOK = new Map();
    const visible = [];
    const near = [];
    const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
    let walked = 0;
    for (let node = walker.nextNode(); node && walked < MAX_WALK; node = walker.nextNode()) {
      walked += 1;
      const value = node.nodeValue;
      if (!value || value.length < 2) continue;
      const record = records.get(node);
      let source = value;
      if (record) {
        if (record.target === profile() && (value === record.translated || (record.translated === null && value === record.original))) continue;
        if (value === record.translated) source = record.original;
        else if (value !== record.original) records.delete(node);
      }
      const trimmed = source.trim();
      if (trimmed.length < 2 || trimmed.length > MAX_TEXT || !LETTER.test(trimmed)) continue;
      const parent = node.parentElement;
      if (!parent) continue;
      let ok = parentOK.get(parent);
      if (ok === undefined) {
        ok = !parent.closest(SKIP_SELECTOR) && !parent.isContentEditable;
        parentOK.set(parent, ok);
      }
      if (!ok) continue;
      range.selectNodeContents(node);
      const rect = range.getBoundingClientRect();
      if (!inBand(rect, margin)) continue;
      const unit = { node, value, source, trimmed };
      if (rect.bottom >= 0 && rect.top <= innerHeight) visible.push(unit);
      else near.push(unit);
      if (visible.length >= MAX_UNITS) break;
    }
    return visible.concat(near).slice(0, MAX_UNITS);
  }

  function pruneRecords() {
    for (const node of records.keys()) {
      if (!node.isConnected) records.delete(node);
    }
    while (records.size > RECORD_LIMIT) records.delete(records.keys().next().value);
  }

  function applyUnit(unit, translatedTrimmed, lang) {
    if (unit.node.nodeValue !== unit.value) return; // 그사이 페이지가 바꿨으면 건드리지 않는다
    const lead = unit.source.match(/^\s*/)[0];
    const trail = unit.source.match(/\s*$/)[0];
    const translated = typeof translatedTrimmed === "string" && translatedTrimmed.length > 0 ? lead + translatedTrimmed + trail : null;
    const record = { original: unit.source, translated, target: profile() };
    if (lang !== undefined) record.lang = lang; // undefined면 그대로 두어(생략) 구버전 응답을 미판별로 둔갑시키지 않는다
    records.set(unit.node, record);
    const want = state.view === "translated" && translated !== null ? translated : unit.source;
    if (unit.node.nodeValue !== want) unit.node.nodeValue = want;
  }

  async function translateTextPass(pageGen) {
    pruneRecords();
    const units = isExternal() ? collectUnits().slice(0, MAX_EXTERNAL_UNITS) : collectUnits();
    const groups = new Map(); // 원문(trim) → [unit]
    for (const unit of units) {
      const cached = cacheGet(unit.trimmed);
      if (cached !== undefined) {
        applyUnit(unit, cached, langGet(unit.trimmed));
        continue;
      }
      if (!groups.has(unit.trimmed)) groups.set(unit.trimmed, []);
      groups.get(unit.trimmed).push(unit);
    }
    const texts = [...groups.keys()];
    const engine = state.engine;
    const maxTexts = isExternal() ? EXTERNAL_BATCH_TEXTS : BATCH_TEXTS;
    const maxChars = isExternal() ? EXTERNAL_BATCH_CHARS : BATCH_CHARS;
    // 다듬기 후속 요청 후보(이 패스에서 실제로 Mac 기본 번역을 거친 줄만, 작은 개수로 제한).
    const refineCandidates = [];
    let start = 0;
    while (start < texts.length) {
      const batch = [];
      let chars = 0;
      while (start < texts.length && batch.length < maxTexts && (batch.length === 0 || chars + texts[start].length <= maxChars)) {
        chars += texts[start].length;
        batch.push(texts[start]);
        start += 1;
      }
      if (!stillCurrent(pageGen)) return;
      const target = state.target;
      const response = await send({ cmd: "translate", target, engine, texts: batch });
      if (!stillCurrent(pageGen) || target !== state.target || engine !== state.engine) return;
      if (response.missing.length) state.warning = `언어 팩 필요: ${response.missing.join(", ")}`;
      if (response.warning) state.warning = response.warning;
      if (typeof response.aiRefine === "boolean") state.aiRefine = response.aiRefine;
      // langs는 입력과 같은 개수일 때만 쓴다(구버전 네이티브 앱이면 없음 → 언어 통계는 집계하지 않는다).
      const langs = Array.isArray(response.langs) && response.langs.length === batch.length ? response.langs : null;
      response.texts.forEach((value, index) => {
        cachePut(batch[index], value);
        const lang = langs ? langs[index] : undefined;
        if (langs) langPut(batch[index], lang);
        const unitsForText = groups.get(batch[index]) || [];
        for (const unit of unitsForText) applyUnit(unit, value, lang);
        if (typeof value === "string" && value && refineCandidates.length < MAX_REFINE_ITEMS && unitsForText[0]) {
          refineCandidates.push({ node: unitsForText[0].node, original: unitsForText[0].source, draft: value });
        }
      });
    }
    if (!isExternal() && state.aiRefine && refineCandidates.length) {
      refineTextCandidates(refineCandidates, pageGen).catch(() => {});
    }
  }

  /** 이미 그려진 DOM 텍스트 번역 중 일부만 다듬어 같은 노드 값만 바꾼다(새 번역으로 세지 않음).
   *  실패·거부·취소는 조용히 무시하고 기존 번역을 그대로 둔다. */
  async function refineTextCandidates(candidates, pageGen) {
    const items = candidates.map((c, index) => ({ k: `r${index}`, o: c.original, d: c.draft }));
    let response;
    try {
      response = await send({ cmd: "refine", target: state.target, engine: state.engine, items });
    } catch {
      return;
    }
    if (!stillCurrent(pageGen) || isExternal()) return;
    for (const item of response.items || []) {
      const index = Number(String(item.k).slice(1));
      const candidate = candidates[index];
      if (!candidate || `r${index}` !== item.k || !candidate.node.isConnected) continue;
      const record = records.get(candidate.node);
      if (!record || record.target !== profile() || record.original !== candidate.original) continue;
      const lead = candidate.original.match(/^\s*/)[0];
      const trail = candidate.original.match(/\s*$/)[0];
      const expectedCurrent = lead + candidate.draft + trail;
      if (record.translated !== expectedCurrent) continue; // 그사이 다시 번역되었거나 바뀜
      const refinedTrimmed = item.t.trim();
      if (!refinedTrimmed) continue;
      const refined = lead + refinedTrimmed + trail;
      record.translated = refined;
      if (state.view === "translated" && candidate.node.nodeValue === expectedCurrent) candidate.node.nodeValue = refined;
    }
  }

  // MARK: 이미지 OCR

  // 요청한 주소(src)와 실제로 그려진 주소(currentSrc)를 함께 쓴다. 새 src를 불러오는 동안 currentSrc는 이전 그림
  // 그대로일 수 있어 currentSrc만으로는 그림이 바뀐 것을 알 수 없다.
  function imageKey(img) {
    return `${profile()}|${img.src}|${img.currentSrc}`;
  }

  // getComputedStyle(img).opacity는 상속되지 않으므로 조상 요소가 opacity:0으로 숨긴 이미지도
  // img 자신의 opacity는 "1"로 읽혀 후보에서 걸러지지 않는다. display/visibility/opacity를
  // 이미지 자신부터 body까지 조상을 따라 올라가며 함께 확인한다.
  function isImageVisible(img) {
    for (let el = img; el instanceof Element; el = el.parentElement) {
      const style = getComputedStyle(el);
      if (style.display === "none" || style.visibility === "hidden" || style.opacity === "0") return false;
    }
    return true;
  }

  /** 기존 덮개 위치를 이미지 현재 위치에 맞추고, 크기가 바뀌었거나 사라졌거나 다른 그림을 불러오는 중이거나 숨겨진 이미지 덮개는 지운다. */
  function repositionOverlays() {
    for (const [img, record] of imageRecords) {
      const rect = img.isConnected ? img.getBoundingClientRect() : null;
      if (!rect || rect.width === 0 || Math.abs(rect.width - record.elemW) > 2 || Math.abs(rect.height - record.elemH) > 2 ||
          !img.complete || record.key !== imageKey(img) || !isImageVisible(img)) {
        record.box.remove();
        imageRecords.delete(img);
        continue;
      }
      record.box.style.left = `${rect.left + record.offX}px`;
      record.box.style.top = `${rect.top + record.offY}px`;
      record.box.style.display = "";
    }
  }

  function imageCandidates() {
    const list = [];
    for (const img of document.images) {
      if (!img.complete || img.naturalWidth < 64 || img.naturalHeight < 32) continue;
      const rect = img.getBoundingClientRect();
      if (rect.width < 80 || rect.height < 40) continue;
      const clip = {
        x: Math.max(0, rect.left), y: Math.max(0, rect.top),
        r: Math.min(innerWidth, rect.right), b: Math.min(innerHeight, rect.bottom)
      };
      const w = clip.r - clip.x;
      const h = clip.b - clip.y;
      if (w < 60 || h < 30 || w * h < rect.width * rect.height * 0.3) continue;
      if (img.closest(SKIP_SELECTOR)) continue;
      // 미리 불러 둔 다음 장처럼 투명하게 겹쳐 둔 이미지는 캡처에 그 위 다른 그림이 찍히므로 고르지 않는다.
      if (!isImageVisible(img)) continue;
      const existing = imageRecords.get(img);
      const offX = clip.x - rect.left;
      const offY = clip.y - rect.top;
      // 같은 이미지·같은 언어로 이미 그렸고, 그때 잘라낸 영역이 지금 보이는 영역을 덮으면 다시 하지 않는다.
      if (existing && existing.key === imageKey(img) && existing.offX <= offX + 1 && existing.offY <= offY + 1 &&
          existing.offX + existing.w >= offX + w - 1 && existing.offY + existing.h >= offY + h - 1) continue;
      list.push({ img, key: imageKey(img), rect, clip: { x: clip.x, y: clip.y, w, h }, area: w * h });
    }
    return list.sort((a, b) => b.area - a.area).slice(0, MAX_IMAGES);
  }

  // 세로쓰기 대상에 한글(완성형 음절 AC00-D7A3, 자모 1100-11FF/3130-318F)도 포함한다. 한자·가나만 보던
  // 기존 범위로는 한국어 번역문이 세로로 좁고 긴 상자에 들어가도 가로쓰기로만 그려졌다.
  const LETTER_CJK = /[ᄀ-ᇿ㄰-㆏가-힣぀-ヿ㐀-䶿一-鿿豈-﫿]/;

  // 말풍선은 여유 영역을 조금 허용한다. 글자를 잘라내거나 스크롤바 안에 가두지 않는다.
  function fitFontSize(div, text, minFont, preferredMax, vertical) {
    div.style.overflow = "visible";
    div.style.pointerEvents = "none";
    text.style.lineHeight = "1.15";
    text.style.transform = "";
    const image = div.parentElement;
    const extraWidth = vertical ? div.offsetLeft : image.clientWidth - div.offsetLeft - div.offsetWidth;
    const extraHeight = image.clientHeight - div.offsetTop - div.offsetHeight;
    const width = div.clientWidth + Math.min(minFont * 1.5, Math.max(0, extraWidth));
    const height = div.clientHeight + Math.min(minFont * 0.8, Math.max(0, extraHeight));
    if (vertical) {
      text.style.height = `${height}px`;
      text.style.width = "auto";
    } else {
      text.style.width = `${width}px`;
      text.style.height = "auto";
    }
    const fits = () => text.scrollWidth <= width + 1 && text.scrollHeight <= height + 1;
    div.style.fontSize = `${minFont}px`;
    const floor = fits() ? minFont : 4;
    let lo = floor;
    let hi = Math.max(minFont, preferredMax);
    div.style.fontSize = `${hi}px`;
    if (!fits()) {
      for (let iter = 0; iter < 7; iter += 1) {
        const mid = (lo + hi) / 2;
        div.style.fontSize = `${mid}px`;
        if (fits()) lo = mid; else hi = mid;
      }
      div.style.fontSize = `${Math.max(floor, Math.floor(lo))}px`;
    }
    // 아주 긴 번역도 여유 영역을 넘어 이웃 말풍선을 계속 덮지는 않게 한다.
    const scale = fits() ? 1 : Math.min(width / Math.max(1, text.scrollWidth), height / Math.max(1, text.scrollHeight));
    if (scale < 1) {
      text.style.transformOrigin = vertical ? "top right" : "top left";
      text.style.transform = `scale(${scale})`;
    }
    return parseFloat(div.style.fontSize) || minFont;
  }

  async function renderImage(candidate, items, langs, refineCandidates) {
    const { img, rect, clip } = candidate;
    const pageGen = state.pageGen, scrollGen = state.scrollGen, fontStyle = state.fontStyle;
    const previous = imageRecords.get(img);
    if (previous) previous.box.remove();
    const root = layer();
    const box = document.createElement("div");
    box.className = "img";
    box.style.left = `${clip.x}px`;
    box.style.top = `${clip.y}px`;
    box.style.width = `${clip.w}px`;
    box.style.height = `${clip.h}px`;
    root.appendChild(box);
    // 글꼴 로딩 중에도 기존 취소 경로가 이 상자를 제거할 수 있도록 먼저 등록한다.
    const record = {
      key: candidate.key, box,
      offX: clip.x - rect.left, offY: clip.y - rect.top, w: clip.w, h: clip.h,
      elemW: rect.width, elemH: rect.height,
      langs: langs && typeof langs === "object" ? langs : undefined,
      items
    };
    imageRecords.set(img, record);
    const renderCurrent = () => {
      if (stillCurrent(pageGen) && state.scrollGen === scrollGen && state.fontStyle === fontStyle &&
          imageRecords.get(img) === record && candidateUnchanged(candidate)) return true;
      box.remove();
      if (imageRecords.get(img) === record) imageRecords.delete(img);
      return false;
    };

    // 너무 작아 읽기 어려운 글자가 조용히 남지 않도록 최소 글자 크기를 12px로 둔다(0.6.2까지의 8px보다 큼).
    const MIN_FONT = 12;
    const MAX_FONT = 39;

    // 원본 글자를 가리는 배경은 보고된 글자 상자(item.g)에만, 이미지 하나당 캔버스 하나에 평면색으로 그린다.
    // 문단 전체 사각형이나 말풍선 테두리·그림까지 덮는 넓은 영역은 절대 칠하지 않는다. g가 없는 조각은
    // 마스킹을 건너뛴다(그 글자의 원본 픽셀은 그대로 남는다).
    const maskCanvas = document.createElement("canvas");
    maskCanvas.className = "mask";
    maskCanvas.width = Math.max(1, Math.round(clip.w));
    maskCanvas.height = Math.max(1, Math.round(clip.h));
    box.appendChild(maskCanvas);
    const maskCtx = maskCanvas.getContext("2d");
    if (maskCtx) {
      for (const item of items) {
        if (!Array.isArray(item.g) || !item.g.length) continue;
        maskCtx.fillStyle = item.bg;
        for (const g of item.g) {
          maskCtx.fillRect(g[0] * clip.w, g[1] * clip.h, g[2] * clip.w, g[3] * clip.h);
        }
      }
    }

    // 원본 글자 하나하나의 실제 잉크 상자(item.g) 중앙값으로 크기를 추정한다(문단 전체 상자보다 훨씬 고르다).
    // 구두점·후리가나 같은 작은 이상치(중앙값의 45% 미만)와 여러 글자가 뭉친 상자(칸 전체에 가까운 크기)는
    // 뺀 뒤 다시 중앙값을 낸다. 글자 상자가 없는 조각만 기존 문단 전체 추정(* 0.968, 0.5.5 기준 * 0.88에서
    // 0.6.2에서 10% 확대)으로 폴백한다.
    function glyphEstimate(item) {
      if (!Array.isArray(item.g) || item.g.length < 2) return null;
      const dims = [];
      for (const g of item.g) {
        const gw = g[2] * clip.w, gh = g[3] * clip.h;
        if (gw <= 0 || gh <= 0) continue;
        if (gw >= clip.w * 0.9 || gh >= clip.h * 0.9) continue; // 뭉친/전체 칸 상자 제외
        dims.push(Math.min(gw, gh));
      }
      if (dims.length < 2) return null;
      const sorted = dims.slice().sort((a, b) => a - b);
      const median = sorted[Math.floor(sorted.length / 2)];
      if (median <= 0) return null;
      const filtered = dims.filter((d) => d >= median * 0.45);
      if (!filtered.length) return null;
      filtered.sort((a, b) => a - b);
      return filtered[Math.floor(filtered.length / 2)];
    }

    const geoms = items.map((item) => {
      const w = item.w * clip.w, h = item.h * clip.h;
      const vertical = w > 0 && h / w > 1.6 && LETTER_CJK.test(item.t);
      const glyph = glyphEstimate(item);
      const estimate = glyph != null ? glyph : Math.min(w, h) * 0.968;
      return {
        w, h, vertical, estimate, cx: (item.x + item.w / 2) * clip.w,
        left: item.x * clip.w, top: item.y * clip.h, bottom: (item.y + item.h) * clip.h
      };
    });

    // 같은 말풍선의 인접한 세로쓰기 칸들은 서로 다른 글자 수/모양으로 geometry 추정이 들쭉날쭉해질 수 있다.
    // 가까이 붙어 있고(가로 간격이 자기 너비 이하) 세로로 많이 겹치는(70% 이상) 세로쓰기 칸끼리만, 그
    // 좁은 무리 안에서 추정치를 중앙값으로 맞춰 칸 사이 글자 크기 튐을 줄인다. 말풍선이 다르거나 세로쓰기가
    // 아니거나 겹침이 적은 칸은 건드리지 않는다(과도한 전역 폰트 통일 금지).
    const groupOf = geoms.map((_, i) => i);
    const find = (i) => { while (groupOf[i] !== i) i = groupOf[i]; return i; };
    for (let i = 0; i < geoms.length; i += 1) {
      if (!geoms[i].vertical) continue;
      for (let j = i + 1; j < geoms.length; j += 1) {
        if (!geoms[j].vertical) continue;
        const a = geoms[i], b = geoms[j];
        const gap = Math.abs(a.cx - b.cx);
        const closeEnough = gap <= Math.max(a.w, b.w) * 1.5;
        const overlap = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
        const minSpan = Math.min(a.bottom - a.top, b.bottom - b.top);
        const overlapsEnough = minSpan > 0 && overlap / minSpan >= 0.7;
        if (closeEnough && overlapsEnough) {
          const ra = find(i), rb = find(j);
          if (ra !== rb) groupOf[rb] = ra;
        }
      }
    }
    // 가로쓰기 내레이션도 같은 문단이면(바로 위/아래로 이어지고 왼쪽 시작선이 비슷하면) 같은 무리로 묶어
    // 최종 글자 크기 합의를 함께 받게 한다(네이티브 화면 캡처의 문단 묶기 기준과 같은 간격·정렬 허용치).
    for (let i = 0; i < geoms.length; i += 1) {
      if (geoms[i].vertical) continue;
      for (let j = i + 1; j < geoms.length; j += 1) {
        if (geoms[j].vertical) continue;
        const a = geoms[i], b = geoms[j];
        const [upper, lower] = a.top <= b.top ? [a, b] : [b, a];
        const gap = lower.top - upper.bottom;
        const heightRatio = lower.h / Math.max(upper.h, 0.0001);
        const alignedLeft = Math.abs(a.left - b.left) < Math.max(a.w, b.w) * 0.12;
        if (gap >= -upper.h * 0.3 && gap < upper.h * 0.9 && heightRatio > 0.65 && heightRatio < 1.5 && alignedLeft) {
          const ra = find(i), rb = find(j);
          if (ra !== rb) groupOf[rb] = ra;
        }
      }
    }
    const byRoot = new Map();
    geoms.forEach((_, i) => {
      const r = find(i);
      if (!byRoot.has(r)) byRoot.set(r, []);
      byRoot.get(r).push(i);
    });
    byRoot.forEach((idxs) => {
      if (idxs.length < 2) return;
      const sorted = idxs.map((i) => geoms[i].estimate).sort((x, y) => x - y);
      const median = sorted[Math.floor(sorted.length / 2)];
      idxs.forEach((i) => { geoms[i].estimate = median; });
    });

    // 번역 글자는 투명 배경으로 원문 위치에서 시작하며, 글자 영역을 조금 벗어날 수 있다.
    const divs = new Array(items.length);
    const texts = new Array(items.length);
    const fitted = new Array(items.length);
    for (let i = 0; i < items.length; i += 1) {
      const item = items[i];
      const div = document.createElement("div");
      div.className = "t";
      div.style.left = `${item.x * 100}%`;
      div.style.top = `${item.y * 100}%`;
      div.style.width = `${item.w * 100}%`;
      div.style.height = `${item.h * 100}%`;
      div.style.color = item.fg;

      const { vertical, estimate } = geoms[i];
      if (vertical) {
        div.classList.add("vert");
        div.style.writingMode = "vertical-rl";
        div.style.textOrientation = "upright";
      }
      const fontStyle = resolveFontStyle(item.fs);
      div.style.fontFamily = fontFamilyFor(fontStyle);
      // 글자는 안쪽 .tt에 넣는다: 이 요소의 scrollWidth/scrollHeight로 넘침을 재야 바깥 .t(overflow:hidden)의
      // 뒤틀린 scrollWidth/scrollHeight 대신 실제 필요한 크기를 알 수 있다(fitFontSize 참고).
      const text = document.createElement("span");
      text.className = "tt";
      text.textContent = item.t;
      div.appendChild(text);
      box.appendChild(div);
      if (refineCandidates && typeof item.o === "string" && item.o && refineCandidates.length < MAX_REFINE_ITEMS) {
        refineCandidates.push({ el: text, original: item.o, draft: item.t, items, index: i });
      }
      divs[i] = div;
      texts[i] = text;

      // 실제 쓰일 글꼴이 불러와진 뒤에 재야 fitFontSize의 측정(scrollWidth/scrollHeight)이 맞는다(비동기 webfont 로드 기다림).
      await loadBundledFont(fontStyle);
      if (!renderCurrent()) return;
      const scale = await opticalScale(fontStyle);
      if (!renderCurrent()) return;
      const scaledMin = Math.min(MAX_FONT - 1, Math.round(MIN_FONT * scale));
      const preferredMax = Math.min(MAX_FONT, Math.max(scaledMin, Math.round(estimate * scale)));
      fitted[i] = fitFontSize(div, text, scaledMin, preferredMax, vertical);
    }

    // 초기 추정치 합의만으로는 같은 문단 안에서 글자 수·칸 비율이 달라 최종 결과가 들쭉날쭉할 수 있다.
    // 실제로 맞춰진(fitted) 크기까지 같은 무리(byRoot) 안에서 다시 한번 합의한다: 무리의 가장 작은
    // 최종 크기로 맞추면(더 큰 칸은 그보다 작게 줄이는 것이므로 항상 들어간다) 한 문단 안 글자 크기가
    // 고르게 보인다. 의도적으로 다른 크기를 쓴 원본(제목·효과음 등, 다른 무리)은 건드리지 않는다.
    byRoot.forEach((idxs) => {
      if (idxs.length < 2) return;
      const minFitted = Math.min(...idxs.map((i) => fitted[i]));
      idxs.forEach((i) => {
        if (fitted[i] === minFitted) return;
        divs[i].style.overflow = "visible";
        divs[i].style.fontSize = `${minFitted}px`;
        fitted[i] = fitFontSize(divs[i], texts[i], minFitted, minFitted, geoms[i].vertical);
      });
    });

    renderCurrent();
  }

  /** 글꼴 설정이 바뀌었을 때 이미 그려진 이미지 덮개를 재캡처·재번역 없이 다시 그린다(글자색·마스킹·자리는 그대로). */
  function rerenderImageFonts() {
    for (const [img, record] of Array.from(imageRecords.entries())) {
      if (!img.isConnected || !Array.isArray(record.items)) continue;
      const rect = img.getBoundingClientRect();
      const candidate = {
        img, rect, key: record.key,
        clip: { x: rect.left + record.offX, y: rect.top + record.offY, w: record.w, h: record.h }
      };
      renderImage(candidate, record.items, record.langs, null).catch(() => {});
    }
  }

  /** 이미지 위 OCR 번역 글자 중 일부만 다듬어 같은 칸의 텍스트만 바꾼다(글꼴·위치·마스킹은 그대로).
   *  실패·거부·취소는 조용히 무시하고 기존 번역 글자를 그대로 둔다. */
  async function refineImageCandidates(candidates, pageGen, scrollGen) {
    const items = candidates.map((c, index) => ({ k: `i${index}`, o: c.original, d: c.draft }));
    let response;
    try {
      response = await send({ cmd: "refine", target: state.target, engine: state.engine, items });
    } catch {
      return;
    }
    if (!stillCurrent(pageGen) || state.scrollGen !== scrollGen || isExternal()) return;
    let changed = false;
    for (const item of response.items || []) {
      const index = Number(String(item.k).slice(1));
      const candidate = candidates[index];
      if (!candidate || `i${index}` !== item.k || !candidate.el.isConnected) continue;
      if (candidate.el.textContent !== candidate.draft) continue; // 그사이 다시 그려졌으면 건드리지 않는다
      const refined = item.t.trim();
      if (!refined) continue;
      candidate.el.textContent = refined;
      changed = true;
      // 캐시(record.items)도 같은 참조를 공유하므로 여기서 갱신해야, 글꼴만 바꿔 재캡처 없이 다시 그릴 때
      // (rerenderImageFonts) 다듬기 전 초안으로 되돌아가지 않는다.
      if (candidate.items && candidate.items[candidate.index]) candidate.items[candidate.index].t = refined;
    }
    if (changed) rerenderImageFonts();
  }

  // 뷰포트와 겹치는 넓이(px^2). 화면 밖이거나 가려진 부분은 0이 되어, 보이지 않는 광고 등에 걸린 애니메이션을
  // 기다리는 데 쓰지 않게 한다.
  function viewportOverlapArea(el) {
    const rect = el.getBoundingClientRect();
    const w = Math.max(0, Math.min(innerWidth, rect.right) - Math.max(0, rect.left));
    const h = Math.max(0, Math.min(innerHeight, rect.bottom) - Math.max(0, rect.top));
    return w * h;
  }

  // 이미지나 그 이미지를 담은 요소에 걸린 유한한 전환·애니메이션(장 넘김 슬라이드·페이드 등)이 끝나기를 기다린다.
  // DOM은 이미 새 그림을 가리켜도 화면에는 아직 이전 그림이 보이는 동안 캡처하지 않기 위해서다. 멈춰 둔 애니메이션에서
  // 영영 기다리지 않도록 각 애니메이션 자신의 남은 시간까지만 기다린다. 화면에 보이지 않거나 너무 작은 이미지(무관한
  // 광고 등)에 걸린 애니메이션은 기다리지 않는다(imageCandidates의 최소 크기 기준과 맞춘다).
  function imageAnimationsDone() {
    if (typeof document.getAnimations !== "function") return Promise.resolve();
    const waits = [];
    for (const animation of document.getAnimations()) {
      const target = animation.effect && animation.effect.target;
      if (!(target instanceof Element) || animation.playState !== "running") continue;
      const imgs = target.tagName === "IMG" ? [target] : target.querySelectorAll("img");
      const relevant = Array.from(imgs).some((candidateImg) =>
        isImageVisible(candidateImg) && viewportOverlapArea(candidateImg) >= 60 * 30);
      if (!relevant) continue;
      const end = animation.effect.getComputedTiming().endTime;
      if (!Number.isFinite(end)) continue;
      const left = (end - Number(animation.currentTime || 0)) / Math.abs(animation.playbackRate || 1);
      waits.push(Promise.race([
        animation.finished.catch(() => {}),
        new Promise((resolve) => setTimeout(resolve, Math.max(0, left)))
      ]));
    }
    return Promise.all(waits);
  }

  /** 후보를 고른 때와 같은 그림이 같은 자리에 다 불러와진 채로 있는지. */
  function candidateUnchanged(candidate) {
    const img = candidate.img;
    if (!img.isConnected || !img.complete || candidate.key !== imageKey(img)) return false;
    // 백그라운드 캡처 빈도 제한으로 기다리는 사이 보이지 않게 된(투명해지거나 숨겨진) 그림은 캡처에 찍히지 않는다.
    if (!isImageVisible(img)) return false;
    const now = img.getBoundingClientRect();
    return Math.abs(now.left - candidate.rect.left) <= 1 && Math.abs(now.top - candidate.rect.top) <= 1 &&
      Math.abs(now.width - candidate.rect.width) <= 1 && Math.abs(now.height - candidate.rect.height) <= 1;
  }

  async function imagePass(pageGen) {
    repositionOverlays();
    if (!state.images || document.visibilityState !== "visible") return;
    // 고르기 전에 화면 전환이 끝나기를 기다린다(끝난 뒤 자리에서 골라야 캡처와 맞는다).
    await imageAnimationsDone();
    if (!stillCurrent(pageGen) || document.visibilityState !== "visible") return;
    repositionOverlays();
    let candidates = imageCandidates();
    if (!candidates.length) return;
    const scrollGen = state.scrollGen;
    const sx = scrollX;
    const sy = scrollY;
    const viewport = { w: innerWidth, h: innerHeight };
    const target = state.target;
    const engine = state.engine;

    ocrInFlight = true;
    try {
      // complete는 데이터를 다 받았다는 뜻일 뿐 새 그림이 화면에 그려졌다는 뜻이 아니다(디코딩은 따로 늦게 끝날 수 있고,
      // 그동안 화면에는 이전 그림이 남을 수 있다). 디코딩이 끝난 뒤 프레임을 넘겨야 캡처에 새 그림이 찍힌다.
      // 디코딩이 실패한(깨졌거나 취소된) 그림은 화면에 제대로 그려지지 않으므로 애초에 캡처·OCR 대상에서 뺀다.
      const decoded = await Promise.all(candidates.map((c) => c.img.decode().then(() => true, () => false)));
      candidates = candidates.filter((c, index) => decoded[index]);
      if (!candidates.length) return;
      // 자기 덮개를 OCR하지 않도록 캡처 동안만 숨긴다.
      if (layerHost) layerHost.style.visibility = "hidden";
      let capture;
      try {
        await nextFrames(2);
        // 기다리는 사이 그림·자리가 바뀐 후보는 캡처에 다른 그림이 찍히므로 뺀다.
        candidates = candidates.filter(candidateUnchanged);
        if (!candidates.length || !stillCurrent(pageGen) || scrollGen !== state.scrollGen) return;
        capture = await send({ cmd: "capture" });
      } finally {
        applyLayerVisibility();
      }
      if (!stillCurrent(pageGen) || scrollGen !== state.scrollGen || scrollX !== sx || scrollY !== sy) return;
      // 백그라운드는 캡처 빈도 제한 때문에 찍기 전에 기다릴 수 있다. 그사이 바뀐 후보는 찍힌 그림과 맞지 않으므로 뺀다.
      candidates = candidates.filter(candidateUnchanged);
      if (!candidates.length) return;
      const regions = candidates.map((c, index) => ({ k: `i${index}`, x: c.clip.x, y: c.clip.y, w: c.clip.w, h: c.clip.h }));
      const response = await send({ cmd: "ocr", captureId: capture.captureId, target, engine, viewport, regions });
      // 결과가 오는 사이 스크롤·이동·언어·엔진 변경이 있었으면 위치가 맞지 않으므로 버린다.
      if (!stillCurrent(pageGen) || scrollGen !== state.scrollGen || target !== state.target || engine !== state.engine ||
          scrollX !== sx || scrollY !== sy) return;
      if (response.missing.length) state.warning = `언어 팩 필요: ${response.missing.join(", ")}`;
      if (response.warning) state.warning = response.warning;
      if (typeof response.aiRefine === "boolean") state.aiRefine = response.aiRefine;
      const imageRefineCandidates = [];
      for (const image of response.images) {
        const index = Number(String(image.k).slice(1));
        const candidate = candidates[index];
        if (!candidate || `i${index}` !== image.k) continue;
        // OCR을 기다리는 사이 이 이미지가 다른 그림으로 바뀌었거나(src·currentSrc) 새 그림을 불러오는 중이거나(!complete)
        // 자리·크기가 달라졌으면(같은 엘리먼트를 재사용하거나 옮기는 리더) 방금 받은 글자는 예전 그림 것이므로 버린다.
        if (!candidateUnchanged(candidate)) continue;
        await renderImage(candidate, image.items, image.langs, isExternal() ? null : imageRefineCandidates);
      }
      if (!isExternal() && state.aiRefine && imageRefineCandidates.length) {
        refineImageCandidates(imageRefineCandidates, pageGen, scrollGen).catch(() => {});
      }
    } finally {
      ocrInFlight = false;
    }
  }

  // MARK: 번역 실행

  /** 주소가 바뀌었으면(해시·pushState 포함) 이전 결과를 모두 무효화하고 true를 돌려준다. */
  function checkNavigation() {
    if (location.href === state.url) return false;
    state.url = location.href;
    state.pageGen += 1;
    clearImageOverlays();
    send({ cmd: "cancel" }).catch(() => {});
    return true;
  }

  // 진행 중인 패스가 await에서 돌아올 때마다 부른다. pushState처럼 이벤트 없는 이동은 여기서야 알 수 있으므로,
  // 그사이 주소가 바뀌었으면 결과를 버리고 이번 패스가 끝난 뒤 새 페이지로 한 번 더 돈다(자동 번역일 때만 실제로 돈다).
  function stillCurrent(pageGen) {
    if (contextDead) return false;
    if (checkNavigation()) state.rerun = true;
    return pageGen === state.pageGen;
  }

  async function runPass(manual = false) {
    if (contextDead) return;
    if (state.running) {
      state.rerun = true;
      if (manual) state.rerunManual = true; // 진행 중인 패스가 끝나면 수동 번역도 그대로 이어서 한다
      return;
    }
    if (!manual && (!state.auto || state.view !== "translated")) return;
    if (document.visibilityState !== "visible") return;
    checkNavigation();
    state.running = true;
    state.error = "";
    const pageGen = state.pageGen;
    try {
      setStatus("번역 중");
      await translateTextPass(pageGen);
      if (pageGen === state.pageGen) {
        if (state.images) setStatus("이미지 글자 확인 중");
        try {
          await imagePass(pageGen);
        } catch (error) {
          if (error.code !== "cancelled" && error.code !== "stale" && error.code !== "tab_hidden") {
            state.warning = `이미지: ${error.message}`;
          }
        }
      }
      if (pageGen === state.pageGen) setStatus("완료");
    } catch (error) {
      if (error.code !== "cancelled" && error.code !== "stale") {
        state.error = error.message || "번역하지 못했습니다.";
        setStatus("오류");
      }
    } finally {
      state.running = false;
      if (state.rerun) {
        const manualRerun = state.rerunManual;
        state.rerun = false;
        state.rerunManual = false;
        if (manualRerun) runPass(true);
        else schedule();
      }
    }
  }

  // 이미 대기 중인 실행이 있으면 다시 걸지 않는다(0ms 타이머를 계속 되돌려 끝없이 미루는 일을 막는다).
  // 실제 통과 중이면 runPass가 rerun 표시로 알아서 이어받으므로 여러 번 걸어도 안전하다.
  function schedule() {
    if (contextDead || state.timer) return;
    state.timer = setTimeout(() => {
      state.timer = 0;
      runPass(false);
    }, 0);
  }

  function setView(view) {
    if (state.view === view) return;
    state.view = view;
    for (const [node, record] of records) {
      if (!node.isConnected) {
        records.delete(node);
        continue;
      }
      if (record.translated === null) continue;
      const from = view === "translated" ? record.original : record.translated;
      const to = view === "translated" ? record.translated : record.original;
      if (node.nodeValue === from) node.nodeValue = to;
    }
    applyLayerVisibility();
    setStatus(view === "translated" ? "번역 표시" : "원문 표시");
  }

  // MARK: 변경 감시(자동 번역일 때만) — 자기 변경은 걸러 무한 반복을 막는다.

  // img/picture-source의 src·srcset이 바뀌면 그 이미지는 이제 다른 그림이므로(같은 엘리먼트를 재사용하는
  // 리더 등) 남은 덮개는 틀린 그림 위에 뜬 것이다. 지우고 진행 중 캡처·OCR은 scrollGen을 올려 무효화한다.
  function invalidateImage(img) {
    const record = imageRecords.get(img);
    if (record) {
      record.box.remove();
      imageRecords.delete(img);
    }
    state.scrollGen += 1;
    if (ocrInFlight) send({ cmd: "cancel", kind: "ocr" }).catch(() => {});
  }

  // 한 묶음 안의 변경을 끝까지 본다(앞쪽 글자 변경 때문에 뒤쪽 이미지 src 변경·제거를 놓치지 않게). 무효화는 수동 번역 뒤에도
  // 하고, 새 통과는 자동 번역일 때만 건다. 해시·pushState 이동도 대개 DOM 변경을 동반하므로 여기서 주소를 다시 확인한다.
  const observer = new MutationObserver((mutations) => {
    let changed = checkNavigation();
    let removed = false;
    for (const mutation of mutations) {
      if (mutation.type === "attributes") {
        const target = mutation.target;
        // 캡처 동안 숨김/보임을 스스로 토글하는 자기 덮개 호스트의 style 변화는 제 꼬리를 물어 무한히 다시 도는
        // 일을 막기 위해 여기서 완전히 무시한다(닫힌 Shadow DOM 안쪽은 애초에 이 감시 범위 밖이라 안전하다).
        if (target === layerHost) continue;
        const attr = mutation.attributeName;
        if (target.tagName === "IMG") {
          invalidateImage(target);
          changed = true;
        } else if (target.tagName === "SOURCE") {
          if (attr !== "src" && attr !== "srcset") continue;
          const picture = target.parentElement;
          const img = picture && picture.tagName === "PICTURE" ? picture.querySelector("img") : null;
          if (img) invalidateImage(img);
          changed = true;
        } else if (attr === "class" || attr === "style") {
          // pushState로 넘어가는 리더 등에서 미리 받아 둔 다음 그림을 보여줄 때 src는 그대로 두고 class/style만
          // 바꿔 보이기/숨기기를 토글하는 경우가 있다. src·srcset 감시만으로는 이런 전환을 전혀 보지 못하므로,
          // 이미지를 담은 요소(이미지 자신 포함 안 되는 경우만 여기로 옴)의 class/style 변화도 본다. 이미지와
          // 무관한 요소의 흔한 class 토글(테마·모달 등)까지 번역을 다시 걸지 않도록, 그 안에 실제 이미지가
          // 있을 때만(추적 중인 덮개가 있거나 img 자손이 있을 때만) 반응한다.
          let relevant = false;
          for (const img of imageRecords.keys()) {
            if (target.contains(img)) { invalidateImage(img); relevant = true; }
          }
          if (!relevant && target.querySelector("img")) relevant = true;
          if (relevant) changed = true;
        }
      } else if (mutation.type === "characterData") {
        const record = records.get(mutation.target);
        if (record && (mutation.target.nodeValue === record.translated || mutation.target.nodeValue === record.original)) continue;
        changed = true;
      } else {
        if (mutation.removedNodes.length) removed = true;
        for (const node of mutation.addedNodes) {
          if (node !== layerHost) changed = true;
        }
      }
    }
    // 문서에서 빠진 이미지의 덮개는 다음 통과를 기다리지 않고 바로 지운다.
    if (removed) {
      for (const [img, record] of imageRecords) {
        if (img.isConnected) continue;
        record.box.remove();
        imageRecords.delete(img);
      }
    }
    if (changed) onPageChanged();
  });
  let observing = false;

  function onPageChanged() {
    if (state.auto && state.view === "translated") schedule();
  }

  // 로딩 중이라 이번 통과에서 건너뛴 이미지(imageCandidates의 !img.complete)는 로드가 끝나야 OCR할 수 있으므로,
  // 캡처링으로 하위 img의 load를 받아 그때 한 번 더 통과를 건다(자동 번역 중일 때만).
  function onImageLoad(event) {
    if (event.target instanceof HTMLImageElement && state.auto && state.view === "translated") schedule();
  }

  function setObserving(on) {
    if (on && !observing && document.body) {
      observer.observe(document.body, {
        childList: true, subtree: true, characterData: true,
        attributes: true, attributeFilter: ["src", "srcset", "class", "style"]
      });
      document.addEventListener("load", onImageLoad, true);
      observing = true;
    } else if (!on && observing) {
      observer.disconnect();
      document.removeEventListener("load", onImageLoad, true);
      observing = false;
    }
  }

  // MARK: 스크롤·크기·표시 상태

  function onScroll(event) {
    state.scrollGen += 1;
    if (ocrInFlight) send({ cmd: "cancel", kind: "ocr" }).catch(() => {});
    // 안쪽 스크롤 영역이 움직이면 그 안 이미지 덮개는 위치가 어긋나므로 숨기고 다음 번역 때 다시 맞춘다.
    const scroller = event?.target;
    if (scroller instanceof Element) {
      for (const [img, record] of imageRecords) {
        if (scroller.contains(img)) record.box.style.display = "none";
      }
    }
    if (state.auto && state.view === "translated") schedule();
  }

  // 전체화면 들어가기/나가기: 좌표 기준(뷰포트 또는 전체화면 요소)이 바뀌므로 덮개 호스트를 그 아래로 옮기고,
  // 진행 중이던 캡처는 좌표가 안 맞을 것이므로 세대를 올려(스스로 무효화) 취소한다. 다음 통과에서 다시 잰다.
  function onFullscreenChange() {
    if (layerHost) {
      const parent = fullscreenTarget() || document.documentElement;
      if (layerHost.parentNode !== parent) parent.appendChild(layerHost);
    }
    state.scrollGen += 1;
    if (ocrInFlight) send({ cmd: "cancel", kind: "ocr" }).catch(() => {});
    // 좌표 기준 전체가 바뀌므로 숨기는 것만으로는 부족하다(크기가 우연히 비슷하면 다음 통과에서 옛 덮개를
    // 그대로 다시 보여줄 수 있다). 페이지 이동 때(checkNavigation)처럼 완전히 지우고 다음 통과에서 새로 그린다.
    clearImageOverlays();
    if (state.auto && state.view === "translated") schedule();
  }

  addEventListener("scroll", onScroll, { passive: true, capture: true });
  addEventListener("resize", onScroll, { passive: true });
  document.addEventListener("fullscreenchange", onFullscreenChange);
  document.addEventListener("webkitfullscreenchange", onFullscreenChange);
  function onHistoryChange() {
    checkNavigation();
    if (state.auto && state.view === "translated") schedule();
  }
  addEventListener("popstate", onHistoryChange);
  addEventListener("hashchange", onHistoryChange);
  addEventListener("pagehide", () => send({ cmd: "cancel" }).catch(() => {}));
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") {
      if (ocrInFlight) send({ cmd: "cancel", kind: "ocr" }).catch(() => {});
    } else if (state.auto && state.view === "translated") {
      schedule();
    }
  });

  // MARK: 확장 메시지

  // 텍스트 조각(레코드)과 OCR 문단(이미지 레코드)에 남아 있는 판별 언어만 센다. 글자 없음(null)·구버전 응답(생략)은
  // 집계하지 않아(거짓으로 채우지 않음) langCounts가 비면 null을 돌려준다.
  function snapshot() {
    let translated = 0;
    const langCounts = {};
    let hasLangData = false;
    for (const record of records.values()) {
      if (record.translated !== null) translated += 1;
      if (record.lang) {
        hasLangData = true;
        langCounts[record.lang] = (langCounts[record.lang] || 0) + 1;
      }
    }
    for (const record of imageRecords.values()) {
      if (!record.langs) continue;
      for (const [lang, count] of Object.entries(record.langs)) {
        const n = Number(count);
        if (!Number.isFinite(n) || n <= 0) continue;
        hasLangData = true;
        langCounts[lang] = (langCounts[lang] || 0) + n;
      }
    }
    return {
      ok: true, view: state.view, auto: state.auto, images: state.images, target: state.target, engine: state.engine,
      fontStyle: state.fontStyle,
      status: state.status, error: state.error, warning: state.warning, translated, imageCount: imageRecords.size,
      langCounts: hasLangData ? langCounts : null
    };
  }

  api.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (contextDead || sender.id !== api.runtime.id || !message || typeof message.cmd !== "string") return false;
    switch (message.cmd) {
      case "configure": {
        // 마지막 원문 보기보다 먼저 시작된 흐름이 늦게 보낸 설정은 자동 번역·번역 시작을 되살리지 못하게 버린다.
        if (!Number.isFinite(message.epoch) || message.epoch < state.stopEpoch) {
          sendResponse(snapshot());
          return false;
        }
        const targetChanged = typeof message.target === "string" && message.target !== state.target;
        const engineChanged = typeof message.engine === "string" && message.engine !== state.engine;
        const fontStyleChanged = typeof message.fontStyle === "string" && FONT_STYLES.includes(message.fontStyle) &&
          message.fontStyle !== state.fontStyle;
        state.auto = message.auto === true;
        state.images = message.images !== false;
        if (fontStyleChanged) {
          state.fontStyle = message.fontStyle;
          rerenderImageFonts(); // 재캡처·재번역 없이 이미 그려진 이미지 덮개만 새 글꼴로 다시 그린다
        }
        if (targetChanged || engineChanged) {
          if (targetChanged) state.target = message.target;
          if (engineChanged) state.engine = message.engine;
          state.pageGen += 1;
          state.warning = "";
          clearImageOverlays();
          send({ cmd: "cancel" }).catch(() => {});
        }
        // 수동 번역 뒤에도 감시는 켜 둔다: 페이지가 바뀌면 이전 결과를 지우는 데만 쓰고, 새 번역은 자동일 때만 한다.
        // 끄는 것은 원문 보기(toggleOriginal)뿐이다.
        if (state.auto || message.translateNow === true) setObserving(true);
        if (message.translateNow === true) {
          setView("translated");
          clearTimeout(state.timer);
          state.timer = 0;
          runPass(true);
        } else if (state.auto && state.view === "translated") {
          schedule();
        }
        sendResponse(snapshot());
        return false;
      }
      case "toggleOriginal":
        // 원문 보기는 항상 원문으로 되돌리고 이 페이지의 자동 번역을 끈다(다시 켜려면 번역 버튼).
        // 세대를 올려 이미 보낸 요청의 늦은 응답이 돌아와도 다시 칠하지 않게 한다.
        // 진행 중인 패스 뒤에 이어 하기로 한 재실행(수동 포함)도 취소한다.
        if (Number.isFinite(message.epoch)) state.stopEpoch = Math.max(state.stopEpoch, message.epoch);
        state.auto = false;
        state.rerun = false;
        state.rerunManual = false;
        setObserving(false);
        clearTimeout(state.timer);
        state.timer = 0;
        state.pageGen += 1;
        state.scrollGen += 1;
        // 원문 보기 동안은 감시하지 않으므로 그사이 바뀐 그림의 덮개가 다음 번역 때 잠깐이라도 다시 보이지 않게 지운다.
        clearImageOverlays();
        setView("original");
        sendResponse(snapshot());
        return false;
      case "state":
        sendResponse(snapshot());
        return false;
      default:
        return false;
    }
  });
})();
