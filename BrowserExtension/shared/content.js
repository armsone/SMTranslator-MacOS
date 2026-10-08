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
  const LETTER = /\p{L}/u;
  const SKIP_SELECTOR = [
    "script", "style", "noscript", "template", "textarea", "input", "select", "option", "code", "pre", "kbd",
    "samp", "var", "svg", "math", "canvas", "iframe", "object", "[translate='no']", ".notranslate",
    "[contenteditable='']", "[contenteditable='true']", "smt-translator-layer"
  ].join(",");

  const state = {
    auto: false,
    images: true,
    target: "ko",
    engine: LOCAL_ENGINE,
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
    warning: ""
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

  // MARK: 공통

  function send(message) {
    return Promise.resolve(api.runtime.sendMessage(message)).then((response) => {
      if (!response || response.ok !== true) {
        const error = new Error(response?.message || "");
        error.code = response?.code || "error";
        throw error;
      }
      return response;
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

  // MARK: 덮개 레이어(이미지 번역) — 닫힌 Shadow DOM, 클릭 통과

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
      ".t{position:absolute;box-sizing:border-box;overflow:hidden;pointer-events:none;user-select:none;" +
      "font-family:-apple-system,BlinkMacSystemFont,system-ui,sans-serif;line-height:1.15;white-space:normal;" +
      "word-break:keep-all;overflow-wrap:anywhere;padding:0 1px;border-radius:2px}";
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
    let start = 0;
    while (start < texts.length) {
      const batch = [];
      let chars = 0;
      while (start < texts.length && batch.length < maxTexts && (batch.length === 0 || chars + texts[start].length <= maxChars)) {
        chars += texts[start].length;
        batch.push(texts[start]);
        start += 1;
      }
      if (pageGen !== state.pageGen) return;
      const target = state.target;
      const response = await send({ cmd: "translate", target, engine, texts: batch });
      if (pageGen !== state.pageGen || target !== state.target || engine !== state.engine) return;
      if (response.missing.length) state.warning = `언어 팩 필요: ${response.missing.join(", ")}`;
      if (response.warning) state.warning = response.warning;
      // langs는 입력과 같은 개수일 때만 쓴다(구버전 네이티브 앱이면 없음 → 언어 통계는 집계하지 않는다).
      const langs = Array.isArray(response.langs) && response.langs.length === batch.length ? response.langs : null;
      response.texts.forEach((value, index) => {
        cachePut(batch[index], value);
        const lang = langs ? langs[index] : undefined;
        if (langs) langPut(batch[index], lang);
        for (const unit of groups.get(batch[index]) || []) applyUnit(unit, value, lang);
      });
    }
  }

  // MARK: 이미지 OCR

  function imageKey(img) {
    return `${profile()}|${img.currentSrc || img.src}`;
  }

  /** 기존 덮개 위치를 이미지 현재 위치에 맞추고, 크기가 바뀌었거나 사라진 이미지 덮개는 지운다. */
  function repositionOverlays() {
    for (const [img, record] of imageRecords) {
      const rect = img.isConnected ? img.getBoundingClientRect() : null;
      if (!rect || rect.width === 0 || Math.abs(rect.width - record.elemW) > 2 || Math.abs(rect.height - record.elemH) > 2 ||
          record.key !== imageKey(img)) {
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
      if (getComputedStyle(img).visibility === "hidden") continue;
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

  function renderImage(candidate, items, langs) {
    const { img, rect, clip } = candidate;
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
    for (const item of items) {
      const div = document.createElement("div");
      div.className = "t";
      div.style.left = `${item.x * 100}%`;
      div.style.top = `${item.y * 100}%`;
      div.style.width = `${item.w * 100}%`;
      div.style.height = `${item.h * 100}%`;
      div.style.background = item.bg;
      div.style.color = item.fg;
      let size = Math.max(9, Math.min(36, item.h * clip.h * 0.78));
      div.style.fontSize = `${size}px`;
      div.textContent = item.t;
      box.appendChild(div);
      for (let i = 0; i < 6 && (div.scrollHeight > div.clientHeight + 1 || div.scrollWidth > div.clientWidth + 1) && size > 8; i += 1) {
        size *= 0.85;
        div.style.fontSize = `${size}px`;
      }
    }
    imageRecords.set(img, {
      key: imageKey(img), box,
      offX: clip.x - rect.left, offY: clip.y - rect.top, w: clip.w, h: clip.h,
      elemW: rect.width, elemH: rect.height,
      langs: langs && typeof langs === "object" ? langs : undefined // 구버전 응답이면 생략: 미판별로 둔갑시키지 않는다
    });
  }

  async function imagePass(pageGen) {
    repositionOverlays();
    if (!state.images || document.visibilityState !== "visible") return;
    const candidates = imageCandidates();
    if (!candidates.length) return;
    const scrollGen = state.scrollGen;
    const sx = scrollX;
    const sy = scrollY;
    const viewport = { w: innerWidth, h: innerHeight };
    const regions = candidates.map((c, index) => ({ k: `i${index}`, x: c.clip.x, y: c.clip.y, w: c.clip.w, h: c.clip.h }));
    const target = state.target;
    const engine = state.engine;

    ocrInFlight = true;
    try {
      // 자기 덮개를 OCR하지 않도록 캡처 동안만 숨긴다.
      if (layerHost) layerHost.style.visibility = "hidden";
      await nextFrames(2);
      let capture;
      try {
        capture = await send({ cmd: "capture" });
      } finally {
        applyLayerVisibility();
      }
      if (scrollGen !== state.scrollGen || pageGen !== state.pageGen || scrollX !== sx || scrollY !== sy) return;
      const response = await send({ cmd: "ocr", captureId: capture.captureId, target, engine, viewport, regions });
      // 결과가 오는 사이 스크롤·이동·언어·엔진 변경이 있었으면 위치가 맞지 않으므로 버린다.
      if (scrollGen !== state.scrollGen || pageGen !== state.pageGen || target !== state.target || engine !== state.engine ||
          scrollX !== sx || scrollY !== sy) return;
      if (response.missing.length) state.warning = `언어 팩 필요: ${response.missing.join(", ")}`;
      if (response.warning) state.warning = response.warning;
      for (const image of response.images) {
        const index = Number(String(image.k).slice(1));
        const candidate = candidates[index];
        if (!candidate || `i${index}` !== image.k || !candidate.img.isConnected) continue;
        // 캡처를 보낸 뒤 OCR 응답이 오기까지 사이에 이 이미지의 currentSrc가 바뀌었으면(같은 엘리먼트를 재사용하는
        // 리더에서 다음/이전 이미지로 넘어간 경우) 방금 받은 글자는 이제는 없는 예전 이미지 것이므로 버린다.
        if (candidate.key !== imageKey(candidate.img)) continue;
        renderImage(candidate, image.items, image.langs);
      }
    } finally {
      ocrInFlight = false;
    }
  }

  // MARK: 번역 실행

  function checkNavigation() {
    if (location.href === state.url) return;
    state.url = location.href;
    state.pageGen += 1;
    clearImageOverlays();
    send({ cmd: "cancel" }).catch(() => {});
  }

  async function runPass(manual = false) {
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
    if (state.timer) return;
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

  const observer = new MutationObserver((mutations) => {
    if (!state.auto || state.view !== "translated") return;
    for (const mutation of mutations) {
      if (mutation.type === "attributes") {
        const target = mutation.target;
        if (target.tagName === "IMG") invalidateImage(target);
        else if (target.tagName === "SOURCE") {
          const picture = target.parentElement;
          const img = picture && picture.tagName === "PICTURE" ? picture.querySelector("img") : null;
          if (img) invalidateImage(img);
        }
        return onPageChanged();
      }
      if (mutation.type === "characterData") {
        const record = records.get(mutation.target);
        if (record && (mutation.target.nodeValue === record.translated || mutation.target.nodeValue === record.original)) continue;
        return onPageChanged();
      }
      for (const node of mutation.addedNodes) {
        if (node !== layerHost) return onPageChanged();
      }
    }
  });
  let observing = false;

  function onPageChanged() {
    schedule();
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
        attributes: true, attributeFilter: ["src", "srcset"]
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
  addEventListener("popstate", () => {
    checkNavigation();
    if (state.auto && state.view === "translated") schedule();
  });
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
      status: state.status, error: state.error, warning: state.warning, translated, imageCount: imageRecords.size,
      langCounts: hasLangData ? langCounts : null
    };
  }

  api.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (sender.id !== api.runtime.id || !message || typeof message.cmd !== "string") return false;
    switch (message.cmd) {
      case "configure": {
        // 마지막 원문 보기보다 먼저 시작된 흐름이 늦게 보낸 설정은 자동 번역·번역 시작을 되살리지 못하게 버린다.
        if (!Number.isFinite(message.epoch) || message.epoch < state.stopEpoch) {
          sendResponse(snapshot());
          return false;
        }
        const targetChanged = typeof message.target === "string" && message.target !== state.target;
        const engineChanged = typeof message.engine === "string" && message.engine !== state.engine;
        state.auto = message.auto === true;
        state.images = message.images !== false;
        if (targetChanged || engineChanged) {
          if (targetChanged) state.target = message.target;
          if (engineChanged) state.engine = message.engine;
          state.pageGen += 1;
          state.warning = "";
          clearImageOverlays();
          send({ cmd: "cancel" }).catch(() => {});
        }
        setObserving(state.auto);
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
