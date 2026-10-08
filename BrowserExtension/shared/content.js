// SMT 웹 번역 — 페이지 내용 스크립트(Chrome·Whale·Safari 공용, 최상위 프레임만).
// - 글자는 DOM 텍스트 노드 값만 바꾼다(innerHTML을 바꾸지 않음). 원문은 메모리에 두고 '원문 보기'로 되돌린다.
//   링크·버튼 등 요소는 그대로라 클릭·접근성이 유지된다.
// - 이미지 속 글자는 보이는 이미지 영역만 캡처·OCR해 이미지 위에 클릭 통과(pointer-events: none) 덮개로 그린다.
//   캡처 직전에는 기존 덮개를 숨겨 자기 번역을 다시 읽지 않는다. 결과가 오는 사이 스크롤·이동이 있었으면 버린다.
// - 자동 번역은 사이트 권한 + 이 사이트 자동 번역을 켠 경우에만, 스크롤·변경이 멈추고 1초 뒤 보이는 부분만 번역한다.
// - 결과는 항상 텍스트(textContent / nodeValue)로만 넣고 HTML로 해석하지 않는다. 번역 캐시는 메모리에만 둔다.
(() => {
  "use strict";
  if (globalThis.__smtWebTranslatorLoaded) return;
  globalThis.__smtWebTranslatorLoaded = true;

  const api = globalThis.browser ?? globalThis.chrome;
  const IDLE_DELAY = 1000;
  const MAX_UNITS = 600;
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
    view: "translated",
    pageGen: 0,   // 이동·언어 변경 때 증가: 이전 결과 모두 무효
    scrollGen: 0, // 스크롤·크기 변경 때 증가: 이전 이미지 결과 무효
    url: location.href,
    running: false,
    rerun: false,
    timer: 0,
    status: "대기",
    error: "",
    warning: "",
    mutationBurst: 0,
    mutationWindowStart: 0
  };

  /** Text 노드 → { original, translated(null이면 원문 유지), target } */
  const records = new Map();
  /** `${target}\u0001${원문}` → 번역문(null이면 번역하지 않음). 메모리 LRU */
  const cache = new Map();
  /** img 요소 → { key, box, offX, offY, w, h, elemW, elemH } */
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

  function cacheKey(text) {
    return `${state.target}\u0001${text}`;
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

  function nextFrames(count) {
    return new Promise((resolve) => {
      const step = (n) => (n <= 0 ? resolve() : requestAnimationFrame(() => step(n - 1)));
      step(count);
    });
  }

  // MARK: 덮개 레이어(이미지 번역) — 닫힌 Shadow DOM, 클릭 통과

  let layerHost = null;
  let layerRoot = null;

  function layer() {
    if (layerHost && layerHost.isConnected) return layerRoot;
    layerHost = document.createElement("smt-translator-layer");
    layerHost.style.cssText = "all: initial; position: absolute; left: 0; top: 0; width: 0; height: 0; " +
      "z-index: 2147483647; pointer-events: none; contain: layout style;";
    layerRoot = layerHost.attachShadow({ mode: "closed" });
    const style = document.createElement("style");
    style.textContent =
      ".img{position:absolute;pointer-events:none;overflow:hidden}" +
      ".t{position:absolute;box-sizing:border-box;overflow:hidden;pointer-events:none;user-select:none;" +
      "font-family:-apple-system,BlinkMacSystemFont,system-ui,sans-serif;line-height:1.15;white-space:normal;" +
      "word-break:keep-all;overflow-wrap:anywhere;padding:0 1px;border-radius:2px}";
    layerRoot.appendChild(style);
    document.documentElement.appendChild(layerHost);
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
        if (record.target === state.target && (value === record.translated || (record.translated === null && value === record.original))) continue;
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

  function applyUnit(unit, translatedTrimmed) {
    if (unit.node.nodeValue !== unit.value) return; // 그사이 페이지가 바꿨으면 건드리지 않는다
    const lead = unit.source.match(/^\s*/)[0];
    const trail = unit.source.match(/\s*$/)[0];
    const translated = typeof translatedTrimmed === "string" && translatedTrimmed.length > 0 ? lead + translatedTrimmed + trail : null;
    records.set(unit.node, { original: unit.source, translated, target: state.target });
    const want = state.view === "translated" && translated !== null ? translated : unit.source;
    if (unit.node.nodeValue !== want) unit.node.nodeValue = want;
  }

  async function translateTextPass(pageGen) {
    pruneRecords();
    const units = collectUnits();
    const groups = new Map(); // 원문(trim) → [unit]
    for (const unit of units) {
      const cached = cacheGet(unit.trimmed);
      if (cached !== undefined) {
        applyUnit(unit, cached);
        continue;
      }
      if (!groups.has(unit.trimmed)) groups.set(unit.trimmed, []);
      groups.get(unit.trimmed).push(unit);
    }
    const texts = [...groups.keys()];
    let start = 0;
    while (start < texts.length) {
      const batch = [];
      let chars = 0;
      while (start < texts.length && batch.length < BATCH_TEXTS && (batch.length === 0 || chars + texts[start].length <= BATCH_CHARS)) {
        chars += texts[start].length;
        batch.push(texts[start]);
        start += 1;
      }
      if (pageGen !== state.pageGen) return;
      const target = state.target;
      const response = await send({ cmd: "translate", target, texts: batch });
      if (pageGen !== state.pageGen || target !== state.target) return;
      if (response.missing.length) state.warning = `언어 팩 필요: ${response.missing.join(", ")}`;
      response.texts.forEach((value, index) => {
        cachePut(batch[index], value);
        for (const unit of groups.get(batch[index]) || []) applyUnit(unit, value);
      });
    }
  }

  // MARK: 이미지 OCR

  function imageKey(img) {
    return `${state.target}|${img.currentSrc || img.src}`;
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
      record.box.style.left = `${rect.left + scrollX + record.offX}px`;
      record.box.style.top = `${rect.top + scrollY + record.offY}px`;
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
      list.push({ img, rect, clip: { x: clip.x, y: clip.y, w, h }, area: w * h });
    }
    return list.sort((a, b) => b.area - a.area).slice(0, MAX_IMAGES);
  }

  function renderImage(candidate, items, sx, sy) {
    const { img, rect, clip } = candidate;
    const previous = imageRecords.get(img);
    if (previous) previous.box.remove();
    const root = layer();
    const box = document.createElement("div");
    box.className = "img";
    box.style.left = `${clip.x + sx}px`;
    box.style.top = `${clip.y + sy}px`;
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
      elemW: rect.width, elemH: rect.height
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
      const response = await send({ cmd: "ocr", captureId: capture.captureId, target, viewport, regions });
      // 결과가 오는 사이 스크롤·이동·언어 변경이 있었으면 위치가 맞지 않으므로 버린다.
      if (scrollGen !== state.scrollGen || pageGen !== state.pageGen || target !== state.target ||
          scrollX !== sx || scrollY !== sy) return;
      if (response.missing.length) state.warning = `언어 팩 필요: ${response.missing.join(", ")}`;
      for (const image of response.images) {
        const index = Number(String(image.k).slice(1));
        const candidate = candidates[index];
        if (!candidate || `i${index}` !== image.k || !candidate.img.isConnected) continue;
        renderImage(candidate, image.items, sx, sy);
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
        state.rerun = false;
        schedule();
      }
    }
  }

  function schedule(delay = IDLE_DELAY) {
    clearTimeout(state.timer);
    state.timer = setTimeout(() => runPass(false), delay);
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

  const observer = new MutationObserver((mutations) => {
    if (!state.auto || state.view !== "translated") return;
    for (const mutation of mutations) {
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
    // 계속 바뀌는 페이지(시계·티커 등)는 10초에 8번 넘게 바뀌면 5초 간격으로 늦춘다.
    const now = Date.now();
    if (now - state.mutationWindowStart > 10000) {
      state.mutationWindowStart = now;
      state.mutationBurst = 0;
    }
    state.mutationBurst += 1;
    schedule(state.mutationBurst > 8 ? 5000 : IDLE_DELAY);
  }

  function setObserving(on) {
    if (on && !observing && document.body) {
      observer.observe(document.body, { childList: true, subtree: true, characterData: true });
      observing = true;
    } else if (!on && observing) {
      observer.disconnect();
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

  addEventListener("scroll", onScroll, { passive: true, capture: true });
  addEventListener("resize", onScroll, { passive: true });
  addEventListener("popstate", () => checkNavigation());
  addEventListener("pagehide", () => send({ cmd: "cancel" }).catch(() => {}));
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") {
      if (ocrInFlight) send({ cmd: "cancel", kind: "ocr" }).catch(() => {});
    } else if (state.auto && state.view === "translated") {
      schedule();
    }
  });

  // MARK: 확장 메시지

  function snapshot() {
    let translated = 0;
    for (const record of records.values()) if (record.translated !== null) translated += 1;
    return {
      ok: true, view: state.view, auto: state.auto, images: state.images, target: state.target,
      status: state.status, error: state.error, warning: state.warning, translated, imageCount: imageRecords.size
    };
  }

  api.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (sender.id !== api.runtime.id || !message || typeof message.cmd !== "string") return false;
    switch (message.cmd) {
      case "configure": {
        const targetChanged = typeof message.target === "string" && message.target !== state.target;
        state.auto = message.auto === true;
        state.images = message.images !== false;
        if (targetChanged) {
          state.target = message.target;
          state.pageGen += 1;
          state.warning = "";
          clearImageOverlays();
          send({ cmd: "cancel" }).catch(() => {});
        }
        setObserving(state.auto);
        if (message.translateNow === true) {
          setView("translated");
          clearTimeout(state.timer);
          runPass(true);
        } else if (state.auto && state.view === "translated") {
          schedule(targetChanged ? 0 : IDLE_DELAY);
        }
        sendResponse(snapshot());
        return false;
      }
      case "toggleOriginal":
        setView(state.view === "translated" ? "original" : "translated");
        if (state.view === "translated" && state.auto) schedule();
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
