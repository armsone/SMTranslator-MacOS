// Barobogi 웹 번역 — 페이지 내용 스크립트(Chrome·Whale·Safari 공용, 최상위 프레임만).
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
  // 확장 교체 뒤 이전 실행의 메모리는 사라져도 페이지 덮개는 남을 수 있다.
  // 새 실행이 이전 번역을 OCR 원문으로 읽지 않도록 제품이 만든 덮개만 제거한다.
  document.querySelectorAll("smt-translator-layer, smt-translator-calibration").forEach((host) => host.remove());

  const api = globalThis.browser ?? globalThis.chrome;
  const MAX_UNITS = 600;
  // 웹 번역 엔진(DeepL·Google·Papago)은 Barobogi가 조각마다 차례로 공식 페이지에 넣으므로 한 번에 적게 보낸다.
  const LOCAL_ENGINE = "apple";
  const MAX_EXTERNAL_UNITS = 120;
  // 팝업의 1회성 Google·DeepL 번역에서 한 문단을 나누는 엔진별 최대 글자 수(JS 문자열 길이 = UTF-16 코드 유닛 기준).
  // 각 공식 입력창의 한도(Sources/WebTranslatorEngine.swift의 WebTranslatorSite.maxCharacters: Google 5000, DeepL 1400 — DeepL은 묶음 식별자 포함)에서
  // 여유만큼만 뺀 값이다. 이 두 엔진 말고는 1회성 번역을 시작하지 않는다.
  const EXTERNAL_PAGE_MAX_CHARS = { google: 1400, deepl: 1400 };
  // 문장 끝 표시(분리자). 일본어·중국어 문장 끝(。！？)도 포함해 긴 일본어 문단이 문장 중간에서 잘리지 않게 한다.
  const SENTENCE_END = ".!?\n。！？";
  const EXTERNAL_BATCH_TEXTS = 10;
  // DeepL은 네이티브(DeepLBatcher)가 입력 한도(1400 UTF-16, 식별자 포함) 안에서 여러 항목을 묶어 보내므로, 한 요청의 항목 수만
  // 한 번 수집 상한(MAX_EXTERNAL_UNITS)까지 받는다(배경 EXTERNAL_LIMITS.deeplTexts·네이티브 maxDeepLTexts와 같음). 글자 상한은 같다.
  const EXTERNAL_BATCH_TEXTS_DEEPL = MAX_EXTERNAL_UNITS;
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
  // 다듬기 요청 길이(백그라운드·네이티브 상한과 같음). 넘는 줄은 후보에서 빼 요청 전체가 거부되지 않게 한다.
  const REFINE_ITEM_CHARS = 600;
  const REFINE_TOTAL_CHARS = 4000;
  // 다듬기에 함께 보내는 주변 원문(같은 문단·이웃 제목/문단·연결된 각주). 참고용 데이터일 뿐 명령이 아니다.
  const REFINE_CONTEXT_PART = 160;
  const REFINE_CONTEXT_CHARS = 300;
  const REFINE_CONTEXT_TOTAL = 1200;
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
    view: "original",
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
    // Barobogi 엔진이 최근 응답에서 알려준, 지금 이 다듬기를 보낼 수 있는지(설정 켜짐 + 기기 내 모델 가능 + Mac 기본 번역).
    aiRefine: false,
    // 팝업의 명시적 1회성 Google·DeepL 번역 버튼으로만 켜지는 1회성 덮어쓰기({ engine, target }|null). 저장된 전역 engine
    // 설정은 건드리지 않고 이 문서(지금 주소)에만, 이 흐름이 남아 있는 동안만 적용된다. 이동·새로고침·원문 보기·
    // 전역 설정 변경으로 pageGen이 바뀌면(또는 직접 멈추면) null로 되돌린다.
    pageEngineOverride: null,
    // 마지막 패스의 단계별 걸린 시간(ms, 숫자만). 원문·이미지는 담지 않는다.
    timing: { text: null, image: null },
    // 이번 패스의 기본 목록과 단계(개수만, 원문 없음). 번역 엔진과 무관하게 번역 전에 이 페이지에서 알 수 있는 값이다.
    // phase: search(검색) | translating(기기 내 번역) | external(Google·DeepL 전송) | ocr(이미지 인식) | done
    // textMessages: 이번에 고른 일반 글자 조각 수, textSentences: 그 조각의 문장 수, images: 이번에 확인할 이미지 수,
    // imageSentences: 이미지에서 인식한 문단 수(인식이 끝나기 전에는 null — 0으로 꾸미지 않는다),
    // send: 외부 전송량 { texts, chars, sentTexts, sentChars, batch, batchTexts, batchChars }(Google·DeepL 일반 글자만)
    inventory: null,
    // 지금 보여 줄 번역 동작(클릭 또는 자동 실행의 실제 시작부터 기본 번역+다듬기가 끝날 때까지)의 경과·단계 기록(숫자만).
    action: null,
    // 팝업 클릭으로 받은, 다음 runPass(true)가 이어받을 동작(클릭 시각 포함). 지금 실행 중인 패스의 동작은 passAction.
    pendingAction: null,
    passAction: null,
    // 외부 번역 시간 한도를 넘겨 중단한 문서 주소: 사용자가 다시 누르거나 이동할 때까지 자동 재실행(다른 엔진 대체 포함)을 하지 않는다.
    holdUrl: null
  };

  // MARK: 번역 동작 시간(경과·단계별 구간, 숫자만 — 원문·주소·이미지는 담지 않는다)
  // startedAt은 Date.now() 시각이다. 팝업·배경·내용 스크립트가 같은 Mac 시계를 쓰므로 팝업을 닫았다 열어도 같은 기준으로 잰다.
  // stages: [{ s: 단계 이름, a: 시작(ms, startedAt 기준), b: 끝(ms)|null(진행 중) }] — 실제 단계가 바뀌는 자리에서만 기록한다.
  // 단계: start(클릭→실행 시작) search(검색) text(온보드 번역) external(외부 서비스 일반 글자) capture(이미지 확인·캡처)
  //       ocr(이미지 요청 왕복) render(그리기) refine(패스가 끝난 뒤 남은 AI 다듬기)
  const ACTION_ID = /^[A-Za-z0-9-]{1,40}$/;
  const ACTION_MAX_AGE = 120000;
  const ACTION_MAX_STAGES = 32;
  // 클릭부터 결과를 그릴 때까지 전체 한도를 두는 외부 엔진(배경이 판정하고 넘으면 허용을 거둔다). Google·온보드는 두지 않는다.
  const ACTION_DEADLINE_MS = {};
  let actionSeq = 0;

  /** 팝업이 보낸 클릭 시각: 지금보다 미래(1초 넘게)이거나 2분보다 오래된 값은 믿지 않고 지금 시각을 쓴다. */
  function clickTime(value) {
    const now = Date.now();
    return Number.isFinite(value) && value <= now + 1000 && value >= now - ACTION_MAX_AGE ? Math.min(value, now) : now;
  }

  /** source: click(버튼) | open(팝업을 열며 실행 — 실제 할 일이 생길 때만 보이는 동작이 된다) | auto(자동 실행) */
  function newAction(startedAt, source, id = null) {
    actionSeq += 1;
    return { id: typeof id === "string" && ACTION_ID.test(id) ? id : `a${Date.now().toString(36)}-${actionSeq}`,
             startedAt, source, provisional: source !== "click", gen: null, engine: null, token: null, deadline: false,
             stages: [], outcome: null, endedAt: null, stopStage: null, waitRefine: false, inventory: null,
             timing: { text: null, image: null } };
  }

  function markStage(action, name) {
    if (!action || action.outcome !== null) return;
    const at = Date.now() - action.startedAt;
    const last = action.stages[action.stages.length - 1];
    if (last && last.b === null) {
      if (last.s === name) return;
      last.b = at;
    }
    if (action.stages.length < ACTION_MAX_STAGES) action.stages.push({ s: name, a: at, b: null });
  }

  /** 동작을 끝낸다(경과를 그 자리에서 멈춘다). outcome: done | timeout | error | cancelled. 이미 끝났으면 바꾸지 않는다. */
  function finishAction(action, outcome, stopStage = null, endedAt = null) {
    if (!action || action.outcome !== null) return;
    const at = Number.isFinite(endedAt) ? endedAt : Date.now() - action.startedAt;
    const last = action.stages[action.stages.length - 1];
    if (last && last.b === null) last.b = Math.max(last.a, at);
    action.outcome = outcome;
    action.endedAt = at;
    action.stopStage = stopStage;
    const inventory = inventoryOf(action.gen);
    if (inventory) action.inventory = { textMessages: inventory.textMessages, textSentences: inventory.textSentences,
                                        images: inventory.images, imageSentences: inventory.imageSentences,
                                        send: inventory.send ? { ...inventory.send } : null };
  }

  /** runPass 시작: 클릭으로 받은 동작을 이어받거나 자동 실행 동작을 새로 만든다. 클릭 동작만 바로 보이는 동작이 된다. */
  function adoptAction(manual) {
    let action = manual ? state.pendingAction : null;
    state.pendingAction = null;
    if (!action || Date.now() - action.startedAt > ACTION_MAX_AGE) action = newAction(Date.now(), "auto");
    const override = state.pageEngineOverride;
    action.gen = state.pageGen;
    action.engine = override ? override.engine : state.engine;
    action.token = override ? override.token : null;
    action.deadline = !!override && Object.hasOwn(ACTION_DEADLINE_MS, override.engine);
    const lead = Date.now() - action.startedAt;
    if (lead > 0 && !action.stages.length) action.stages.push({ s: "start", a: 0, b: lead });
    markStage(action, "search");
    state.passAction = action;
    if (!action.provisional) commitAction(action);
    return action;
  }

  /** 실제로 할 일(번역 요청·이미지 인식)이 생긴 동작을 지금 보여 줄 동작으로 정한다. 할 일이 없는 자동 패스는 이전 동작의
   *  경과를 덮지 않는다. 시간 한도가 있는 외부 엔진이면 배경에 시작을 알린다(배경이 클릭 때 이미 시작했으면 그대로 둔다). */
  function commitAction(action) {
    if (!action || action.outcome !== null) return;
    if (state.action === action && !action.provisional) return;
    action.provisional = false;
    const previous = state.action;
    if (previous && previous !== action && previous.outcome === null) {
      finishAction(previous, previous.waitRefine ? "done" : "cancelled");
    }
    state.action = action;
    if (action.deadline && action.token) {
      send({ cmd: "externalActionStart", engine: action.engine, token: action.token, action: action.id,
             startedAt: action.startedAt }).catch(() => {});
    }
  }

  /** 배경이 외부 번역 시간 한도를 넘겼다고 판정했을 때: 이 동작을 '초과'로 멈추고, 허용(토큰)을 이미 거둔 1회성 번역을 끝낸다.
   *  늦게 오는 결과는 세대가 바뀌어 모두 버려진다. 다른 엔진으로 바꿔 다시 하거나 자동으로 재시도하지 않는다. */
  function applyDeadline(token, actionId, nativeStage, endedAt) {
    const override = state.pageEngineOverride;
    // 이전 패스가 끝나기를 기다리느라 아직 이어받지 못한 클릭 동작도 여기서 초과로 끝내 보이게 한다.
    const pending = state.pendingAction && state.pendingAction.id === actionId && override && override.token === token
      ? state.pendingAction : null;
    if (pending) {
      state.pendingAction = null;
      Object.assign(pending, { provisional: false, gen: state.pageGen, engine: override.engine, token, deadline: true });
      if (Date.now() - pending.startedAt > 0) pending.stages.push({ s: "start", a: 0, b: null });
      if (state.action && state.action.outcome === null) finishAction(state.action, "cancelled");
      state.action = pending;
    }
    const candidates = [pending, state.passAction, state.action];
    const action = candidates.find((a) => a && a.id === actionId && a.token === token) || null;
    if (action) {
      // 배경의 취소가 이 알림보다 먼저 도착해 '중단'으로 끝났으면 실제 원인인 시간 초과로 바로잡는다.
      if (action.outcome === "cancelled") action.outcome = null;
      const contentStage = action.stages.length ? action.stages[action.stages.length - 1].s : null;
      finishAction(action, "timeout", { content: contentStage, native: nativeStage }, endedAt);
      if (state.action !== action && !action.provisional) state.action = action;
    }
    if (!override || override.token !== token) return;
    state.pageEngineOverride = null; // 배경이 이미 허용을 지웠다
    state.pageGen += 1;
    state.scrollGen += 1;
    state.rerun = false;
    state.rerunManual = false;
    clearTimeout(state.timer);
    state.timer = 0;
    // 그림은 원문으로 되돌리지 않는다: 이번 기준으로 그린 덮개는 지우고, 같은 그림·같은 자리에 유효한 이전 성공 덮개(남겨 둔 것과
    // 이번에 대신했던 사본)만 남긴다. 이전 덮개가 없던 그림의 원문 가림은 보장하지 않는다. 일반 글자는 기존대로 원문으로 되돌린다.
    const kept = retainHeldOverlays(true);
    revertForeignRecords();
    state.warning = kept ? HELD_KEPT_WARNING : "";
    state.holdUrl = location.href;
    // 남긴 덮개가 보이려면 번역 보기여야 한다(이 문서는 holdUrl로 자동 재실행·다른 엔진 대체를 하지 않는다). '원문 보기'를 누르면
    // 기존대로 모두 지운다. 남긴 덮개가 없으면 기존대로 원문 보기로 둔다.
    if (!kept) setView("original");
    setStatus("시간 초과");
    reportProgress();
  }

  const SENTENCE_PART = new RegExp(`[^${SENTENCE_END}]+`, "g");
  /** 문장 끝 표시(. ! ? 줄바꿈 。！？)로 나눈 조각 중 글자가 있는 것의 수. 글자가 있으면 최소 1문장이다. */
  function sentenceCount(text) {
    return (String(text).match(SENTENCE_PART) || []).filter((part) => LETTER.test(part)).length;
  }

  /** 그 세대(pageGen)에서 시작한 패스의 목록. 이동·원문 보기·엔진 변경으로 세대가 바뀌었으면 null. */
  function inventoryOf(pageGen) {
    return state.inventory && state.inventory.gen === pageGen ? state.inventory : null;
  }

  /** 지금 패스의 목록만 고친다(다른 패스가 시작돼 목록이 바뀌었으면 늦은 값은 버린다). */
  function updateInventory(inventory, changes) {
    if (inventory && state.inventory === inventory) Object.assign(inventory, changes);
  }

  // pageGen(세대) → 그 세대에서 띄워 보낸(아직 끝나지 않은) 다듬기(refine) 요청 수. runPass가 끝난 뒤에도 다듬기가
  // 이어지는 동안 팝업 스피너를 계속 띄우기 위해 쓴다. 세대가 지난 다듬기는 끝나도 지금 세대 카운트를 건드리지 않는다.
  const refinePending = new Map();
  // pageGen → 그 세대에서 다듬는 중인 문장(항목) 수. 팝업의 'Apple Intelligence 문장 다듬기' 개수 표시에만 쓴다.
  const refineItemsPending = new Map();

  function beginRefine(pageGen, items = 0) {
    refinePending.set(pageGen, (refinePending.get(pageGen) || 0) + 1);
    refineItemsPending.set(pageGen, (refineItemsPending.get(pageGen) || 0) + items);
    reportProgress();
  }

  function endRefine(pageGen, items = 0) {
    const next = (refinePending.get(pageGen) || 0) - 1;
    if (next <= 0) refinePending.delete(pageGen);
    else refinePending.set(pageGen, next);
    const left = (refineItemsPending.get(pageGen) || 0) - items;
    if (next <= 0 || left <= 0) refineItemsPending.delete(pageGen);
    else refineItemsPending.set(pageGen, left);
    // 패스가 끝난 뒤 다듬기만 기다리던 동작은 마지막 다듬기가 끝날 때 멈춘다(세대가 바뀌었으면 중단).
    const action = state.action;
    if (next <= 0 && action && action.waitRefine && action.gen === pageGen && action.outcome === null) {
      finishAction(action, pageGen === state.pageGen ? "done" : "cancelled");
    }
    reportProgress();
  }

  /** 지금 실제로 번역·OCR·다듬기 중인지(단순 자동 감시 대기는 포함 안 함). 팝업 스피너·배지가 이 값만 본다. */
  function isBusy() {
    return state.running || (refinePending.get(state.pageGen) || 0) > 0;
  }

  /** Text 노드 → { original, translated(null이면 원문 유지), target(엔진|언어), lang(판별 언어 코드|"unknown"|null(글자없음)|생략(구버전 응답)) } */
  const records = new Map();
  /** `${엔진|언어}\u0001${원문}` → 번역문(null이면 번역하지 않음). 메모리 LRU */
  const cache = new Map();
  /** 원문(trim) → 판별 언어 코드|"unknown"|null. target과 무관하므로 cache와 별도 LRU로 둔다. */
  const langCache = new Map();
  /** img 요소(조각 묶음이면 맨 위 조각) → { key, members(실제 img들), box, offX, offY, w, h, elemW, elemH,
   *  langs({언어코드|"unknown": 개수}) }. offX·offY·elemW·elemH는 묶음이면 조각 합집합 기준이다. */
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
    state.pageEngineOverride = null;
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
    for (const node of Array.from(fontSpans.keys())) removeFontSpan(node);
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

  /** 번역 결과를 구분하는 기준: 엔진과 번역 언어가 모두 같아야 같은 결과다. 1회성 Google·DeepL 덮어쓰기가
   *  있으면 그 엔진|언어를 쓴다 — 저장된 전역 엔진과는 다른 캐시 키라 서로 섞이지 않고, 덮어쓰기가 끝나면
   *  (pageEngineOverride = null) 자연히 전역 엔진 쪼으로 되돌아간다(이 노드가 다시 collectUnits에 걸림). */
  function profile() {
    const override = state.pageEngineOverride;
    return override ? `${override.engine}|${override.target}` : `${state.engine}|${state.target}`;
  }

  /** 1회성 Google·DeepL 덮어쓰기를 끝낸다. 배경에도 알려 이 문서의 허용 토큰을 지우게 한다(허용이 남지 않게). */
  function endPageOverride() {
    const override = state.pageEngineOverride;
    if (!override) return;
    state.pageEngineOverride = null;
    if (!contextDead) send({ cmd: "endExternalPage", token: override.token }).catch(() => {});
  }

  /** 지금 기준(profile(): 엔진|언어)과 다른 기준으로 번역해 둔 글자를 원문으로 되돌린다. 1회성 Google·DeepL 번역를 켜고 끄거나
   *  언어·엔진을 바꿀 때 이전 결과와 새 결과가 한 화면에 섞이지 않게 한다. 새 기준으로 다시 번역되면 그때 바뀐다. */
  function revertForeignRecords() {
    const current = profile();
    for (const [node, record] of records) {
      if (record.target === current) continue;
      if (node.isConnected && record.translated !== null && node.nodeValue === record.translated) node.nodeValue = record.original;
      removeFontSpan(node);
      records.delete(node);
    }
  }

  function isExternal() {
    return state.pageEngineOverride !== null || state.engine !== LOCAL_ENGINE;
  }

  /** 자동 번역(전역)처럼 스크롤·DOM 변화에 계속 반응해도 되는지. 전역 자동 번역이 켜져 있거나, 'Google로
   *  보기' 1회성 덮어쓰기가 지금 진행 중일 때(그래야 스크롤해 새로 보이는 문단도 이어서 보낸다)만 true다. */
  function isAutoLike() {
    return (state.auto || state.pageEngineOverride !== null) && state.view === "translated";
  }

  /** 한 문단(텍스트 노드) 원문을 모두 이어 붙이면 원문과 똑같아지는 조각들로 나눈다. 문장 경계(. ! ? 줄바꿈)를
   *  먼저 쓰고, 한 문장이 한도를 넘으면 낱말 경계(공백)로, 그래도 넘으면 글자 그대로 자른다. 분리자(공백·마침표
   *  등)는 버리지 않고 조각 안에 그대로 남겨 그대로 이어 붙이면 원문이 된다. max가 Infinity이면 그대로 돌려준다
   *  (전역 로컬 번역 등 이 함수를 쓰지 않는 경로는 동작이 바뀌지 않는다). */
  function chunkParagraph(text, max) {
    if (text.length <= max) return [text];
    const sentences = text.match(new RegExp(`[^${SENTENCE_END}]+[${SENTENCE_END}]*|[${SENTENCE_END}]+`, "g")) || [text];
    const chunks = [];
    let buffer = "";
    const flush = () => { if (buffer) { chunks.push(buffer); buffer = ""; } };
    for (const sentence of sentences) {
      if (sentence.length > max) {
        flush();
        const words = sentence.match(/\S+\s*|\s+/g) || [sentence];
        for (const word of words) {
          if (word.length > max) {
            let i = 0;
            while (i < word.length) {
              let end = Math.min(i + max, word.length);
              // 분리 자리가 대체쌍(서로게이트 페어)의 두 번째 코드 유닛이면 한 유닛 앞으로 물려 글자를 반으로 쪼개지 않는다.
              if (end < word.length && end > i && word.charCodeAt(end - 1) >= 0xD800 && word.charCodeAt(end - 1) <= 0xDBFF) end -= 1;
              chunks.push(word.slice(i, end));
              i = end;
            }
          } else if (buffer.length + word.length > max) {
            flush();
            buffer = word;
          } else {
            buffer += word;
          }
        }
      } else if (buffer.length + sentence.length > max) {
        flush();
        buffer = sentence;
      } else {
        buffer += sentence;
      }
    }
    flush();
    return chunks;
  }

  /** 나눈 조각의 번역을 이어 붙일 때 원문 조각 앞뒤의 공백·줄바꿈(분리자)을 되살린다(엔진은 결과 앞뒤 공백을 지운다).
   *  원문이 공백 없이 이어지는 일본어·중국어 문장 끝(。！？)이면 번역문 끝에 띄어쓰기 하나를 둔다(다음 조각과 붙지 않게).
   *  조각이 하나면 그대로 돌려준다. */
  function keepEdges(part, value, count) {
    if (count <= 1 || typeof value !== "string") return value;
    const lead = part.match(/^\s*/)[0];
    const trail = part.match(/\s*$/)[0];
    const core = value.trim();
    const spacer = !trail && /[。！？]$/.test(part) && !/[\u3000-\u303f\uff01-\uff1f]$/.test(core) ? " " : "";
    return lead + core + (trail || spacer);
  }

  /** 외부 엔진 한 요청의 항목 수 상한(DeepL만 MAX_EXTERNAL_UNITS, 그 밖은 기존 10). */
  function externalBatchTexts(engine) {
    return engine === "deepl" ? EXTERNAL_BATCH_TEXTS_DEEPL : EXTERNAL_BATCH_TEXTS;
  }

  /** texts[start]부터 항목 수·글자 수(UTF-16) 상한 안에서 다음 묶음을 고른다. 첫 항목은 혼자라도 넣는다(기존 규칙 그대로). */
  function nextBatch(texts, start, maxTexts, maxChars) {
    const batch = [];
    let chars = 0;
    let next = start;
    while (next < texts.length && batch.length < maxTexts && (batch.length === 0 || chars + texts[next].length <= maxChars)) {
      chars += texts[next].length;
      batch.push(texts[next]);
      next += 1;
    }
    return { batch, chars, next };
  }

  /** 한 요청 목록: 일반 글자 조각(순서 그대로) 뒤에, 재사용할 그림의 인식 원문 중 목록에 아직 없고 캐시(isCached)에도 없는 것만
   *  한 번씩 붙인다. 같은 원문은 한 번만 보내고 결과는 원문 문자열로 각 노드·각 그림 항목에 되돌린다. */
  function mergeSendList(textParts, imageSources, isCached) {
    const list = textParts.slice();
    const seen = new Set(list);
    for (const source of imageSources) {
      if (seen.has(source) || isCached(source)) continue;
      seen.add(source);
      list.push(source);
    }
    return list;
  }

  /** 그림 항목에 붙일 수 있는 번역(비지 않은 글자, 길이 상한 안)만 남기고 나머지는 실패(null). */
  function imageTranslation(value) {
    return typeof value === "string" && value.trim().length > 0 && value.length <= MAX_TEXT ? value : null;
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
  // 번들 글꼴(FontFace)이 아직 못 불러와졌을 때만 잠깐 쓰이는 대체 글꼴. 명조에 고딕 계열 글꼴(Apple SD Gothic
  // Neo)을 폴백으로 뒀던 이전 버그는 로딩이 늦어지면 "명조"를 골라도 고딕처럼 보이게 했다. 모든 갈래의 폴백은
  // 번들 글꼴과 같은 계열(세리프/산세리프/필기체)이어야 한다.
  const FONT_FALLBACKS = {
    gothic: "-apple-system,BlinkMacSystemFont,system-ui,sans-serif",
    myeongjo: "serif",
    gungseo: "serif",
    hand: "cursive"
  };
  const fontLoadPromises = new Map();
  /** 패키지에 포함한 글꼴 파일을 FontFace API로 한 번만 불러와 document.fonts에 더한다(온라인 요청 없음).
   *  불러오기에 실패하면 캐시에 남기지 않는다: 일시적 오류(확장 업데이트 중 리소스 접근 실패 등)로 한 번
   *  실패했다고 그 글꼴을 이 페이지 생애 동안 영영 못 쓰는 것으로 단정하지 않고, 다음 요청에서 다시 시도한다. */
  function loadBundledFont(style) {
    if (style === "auto") return Promise.resolve(true);
    const cached = fontLoadPromises.get(style);
    if (cached) return cached;
    const family = FONT_FAMILIES[style];
    const file = FONT_FILES[style];
    if (!family || !file) return Promise.resolve(false);
    const promise = Promise.resolve()
      .then(() => new FontFace(family, `url(${api.runtime.getURL(file)})`).load())
      .then((loaded) => { document.fonts.add(loaded); return true; })
      .catch(() => { fontLoadPromises.delete(style); return false; });
    fontLoadPromises.set(style, promise);
    return promise;
  }

  // MARK: 일반 DOM 번역문에 선택한 글꼴 적용 — 번역된 글자만(상위 요소·아이콘·컨트롤은 그대로) 작은 인라인
  // <span>으로 감싸 font-family만 준다. 텍스트 노드 자신·그 nodeValue는 번역 로직이 그대로 쓰므로(원문 복원 등)
  // 감시자(observer)가 보는 건 이 span 추가/제거뿐이며, 같은 노드에 두 번 감싸지 않아 되돌이 반복을 만들지 않는다.
  const FONT_SPAN_CLASS = "smt-translator-font";
  const fontSpans = new Map(); // Text 노드 → 감싼 span

  function ensureFontSpan(node) {
    let span = fontSpans.get(node);
    if (span && span.isConnected && span.parentNode && node.parentNode === span) return span;
    if (span) fontSpans.delete(node);
    const parent = node.parentNode;
    if (!parent) return null;
    span = document.createElement("span");
    span.className = FONT_SPAN_CLASS;
    span.style.cssText = "all: unset; display: inline; unicode-bidi: isolate;";
    parent.insertBefore(span, node);
    span.appendChild(node);
    fontSpans.set(node, span);
    return span;
  }

  function removeFontSpan(node) {
    const span = fontSpans.get(node);
    if (!span) return;
    fontSpans.delete(node);
    if (span.parentNode && node.parentNode === span) span.parentNode.insertBefore(node, span);
    if (span.parentNode) span.remove();
  }

  /** 번역된 텍스트 노드 하나에 선택한 글꼴을 적용(또는 자동이면 원래 글꼴로 되돌림)한다. */
  function applyNodeFont(node, style) {
    if (style === "auto" || !FONT_STYLES.includes(style)) {
      removeFontSpan(node);
      return;
    }
    if (!node.isConnected) return;
    const span = ensureFontSpan(node);
    if (!span) return;
    span.style.fontFamily = fontFamilyFor(style);
    loadBundledFont(style).catch(() => {});
  }

  /** 글꼴 설정이 바뀌었을 때 이미 번역되어 보이는 텍스트 노드만 재캡처·재번역 없이 다시 글꼴을 입힌다. */
  function rerenderTextFonts() {
    for (const [node, record] of records) {
      if (!node.isConnected || record.translated === null) continue;
      if (state.view !== "translated" || node.nodeValue !== record.translated) continue;
      applyNodeFont(node, state.fontStyle);
    }
  }

  /** 자동 글꼴일 때 원본 글자 특징(item.fs)으로 고른 갈래, 수동이면 사용자가 고른 갈래로 확정한다. 알 수 없는
   * 값·미판별은 고딕으로 대체한다(가짜로 정확히 식별한 척하지 않음). */
  function resolveFontStyle(itemFontStyle) {
    if (state.fontStyle !== "auto" && FONT_STYLES.includes(state.fontStyle)) return state.fontStyle;
    return itemFontStyle === "myeongjo" || itemFontStyle === "gungseo" || itemFontStyle === "hand" ? itemFontStyle : "gothic";
  }

  /** 글자색과 대비되는 테두리색(검정/흰색). 형식이 틀리면 흰색. */
  function contrastColor(hex) {
    if (typeof hex !== "string" || !/^#[0-9A-Fa-f]{6}$/.test(hex)) return "#FFFFFF";
    const n = parseInt(hex.slice(1), 16);
    const luminance = (0.299 * (n >> 16) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255)) / 255;
    return luminance > 0.55 ? "#000000" : "#FFFFFF";
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
      "z-index: 2147483647; pointer-events: none; contain: layout style; color-scheme: only light;";
    layerRoot = layerHost.attachShadow({ mode: "closed" });
    const style = document.createElement("style");
    style.textContent =
      ":host,.img,.mask,.t,.tt{color-scheme:only light}" +
      ".img{position:absolute;pointer-events:none;overflow:hidden}" +
      ".mask{position:absolute;left:0;top:0;width:100%;height:100%;pointer-events:none}" +
      // 가운데 정렬 대신 원문 기준(가로쓰기는 좌상단, 세로쓰기는 우상단에서 시작)으로 맞춘다: 원본 가로
      // 내레이션은 보통 좌측 정렬, 세로쓰기 칸은 글자가 상단부터 고른 줄간격으로 내려간다(.vert가 override).
      ".t{position:absolute;box-sizing:border-box;overflow:hidden;pointer-events:none;user-select:none;" +
      "display:flex;align-items:flex-start;justify-content:flex-start;text-align:left;background:transparent;" +
      "font-family:-apple-system,BlinkMacSystemFont,system-ui,sans-serif;line-height:1.15;white-space:normal;" +
      "word-break:keep-all;overflow-wrap:anywhere;padding:0 1px}" +
      ".t.vert{justify-content:flex-start;align-items:center}" +
      // 세로쓰기 말풍선에 가로로 쓰는 번역(한국어 등)은 말풍선 가운데에 가운데 맞춤으로 둔다.
      ".t.ctr{justify-content:center;align-items:center;text-align:center}" +
      // .tt(안쪽 글자 상자)는 flex-shrink:0으로 바깥 flex가 줄여 넘침을 감추지 못하게 하고, overflow는 기본
      // visible로 둬 scrollWidth/scrollHeight가 바깥 .t(overflow:hidden, 가운데 정렬)의 뒤틀린 값 대신 글자
      // 자신의 실제 필요한 크기를 그대로 보여주게 한다(가운데 정렬된 내용은 앞쪽으로 넘친 만큼이 scrollWidth에
      // 반영되지 않을 수 있는 브라우저 동작을 피한다). 치수(width/height)는 fitFontSize가 측정 전에 직접 both 넣는다.
      ".tt{display:inline-block;flex-shrink:0;max-width:none;max-height:none}" +
      // 번역 실패 항목은 원문 자리를 채우는 글자를 그리지 않고(원문 가림만 유지), 그림마다 작게 한 번만 알린다.
      ".fail{position:absolute;right:2px;bottom:2px;max-width:70%;padding:1px 5px;border-radius:3px;" +
      "background:rgba(0,0,0,.72);color:#fff;font:11px -apple-system,BlinkMacSystemFont,system-ui,sans-serif;" +
      "line-height:1.3;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;pointer-events:none}";
    layerRoot.appendChild(style);
    parent.appendChild(layerHost);
    applyLayerVisibility();
    return layerRoot;
  }

  // 캡처하는 동안은 원문/번역 전환(setView)이나 덮개 생성(layer)이 덮개를 다시 보이게 하지 않는다(캡처에 자기 덮개가 찍히지 않게).
  let captureHidden = false;

  function applyLayerVisibility() {
    if (layerHost) layerHost.style.visibility = state.view === "translated" && !captureHidden ? "visible" : "hidden";
  }

  // MARK: 캡처 밝기 보정 견본 — 보이는 탭 캡처가 화면보다 어둡게 찍히는 환경이 있어(원인 미확정) 캡처하는 동안만 화면
  // 가장자리에 검정(0)·회색(128)·흰색(255) 세 칸을 CSS로 정확히 그린다. 자리는 백그라운드가 같은 캡처에만 묶어 네이티브로
  // 넘기고, 네이티브는 CSS 값과 그 자리의 실제 캡처 픽셀 값 쌍으로만 밝기를 되돌린다(그림 속 색을 흰색으로 짐작하지 않음).
  // 번역 덮개와 다른 호스트라 캡처 동안 덮개를 숨겨도 보이며, 캡처가 끝나면 바로 지운다. 이미지 바이트는 다루지 않는다.
  const CAL_CELL = 18;
  const CAL_LEVELS = [0, 128, 255];
  const CAL_INSET = 2;
  let calibrationHost = null;

  /** 네 모서리 중 이미지 후보와 겹치지 않는(겹치면 가장 적게 겹치는) 자리. 너무 좁은 화면이면 null. */
  function calibrationSpot(candidates) {
    const w = CAL_CELL * CAL_LEVELS.length, h = CAL_CELL;
    const right = Math.min(innerWidth, document.documentElement.clientWidth || innerWidth);
    const bottom = Math.min(innerHeight, document.documentElement.clientHeight || innerHeight);
    if (right < w + CAL_INSET * 2 || bottom < h + CAL_INSET * 2) return null;
    const margin = 8;
    let best = null;
    for (const [x, y] of [[right - w - CAL_INSET, bottom - h - CAL_INSET], [CAL_INSET, bottom - h - CAL_INSET],
      [right - w - CAL_INSET, CAL_INSET], [CAL_INSET, CAL_INSET]]) {
      let overlap = 0;
      for (const c of candidates) {
        const ox = Math.min(x + w + margin, c.clip.x + c.clip.w) - Math.max(x - margin, c.clip.x);
        const oy = Math.min(y + h + margin, c.clip.y + c.clip.h) - Math.max(y - margin, c.clip.y);
        if (ox > 0 && oy > 0) overlap += ox * oy;
      }
      if (!best || overlap < best.overlap) best = { x, y, w, h, overlap };
      if (overlap === 0) break;
    }
    return best;
  }

  function showCalibration(spot) {
    removeCalibration();
    const host = document.createElement("smt-translator-calibration");
    host.style.cssText = `all: initial; position: fixed; left: ${spot.x}px; top: ${spot.y}px; width: ${spot.w}px; ` +
      `height: ${spot.h}px; display: block; z-index: 2147483647; pointer-events: none; contain: strict; color-scheme: only light;`;
    const root = host.attachShadow({ mode: "closed" });
    CAL_LEVELS.forEach((level, index) => {
      const cell = document.createElement("div");
      cell.style.cssText = `all: initial; position: absolute; top: 0; left: ${index * CAL_CELL}px; width: ${CAL_CELL}px; ` +
        `height: ${CAL_CELL}px; background: rgb(${level},${level},${level}); forced-color-adjust: none; color-scheme: only light;`;
      root.appendChild(cell);
    });
    (fullscreenTarget() || document.documentElement).appendChild(host);
    calibrationHost = host;
    return host;
  }

  /** 그린 견본이 고른 자리 그대로 있는지(페이지 확대·변형으로 어긋나면 그 자리를 보내지 않는다). */
  function calibrationPlaced(host, spot) {
    if (!host.isConnected) return false;
    const r = host.getBoundingClientRect();
    return Math.abs(r.left - spot.x) <= 0.5 && Math.abs(r.top - spot.y) <= 0.5 &&
      Math.abs(r.width - spot.w) <= 0.5 && Math.abs(r.height - spot.h) <= 0.5;
  }

  function removeCalibration() {
    if (calibrationHost) calibrationHost.remove();
    calibrationHost = null;
  }

  function clearImageOverlays() {
    for (const record of imageRecords.values()) record.box.remove();
    imageRecords.clear();
    overlayEpoch += 1;
  }

  // MARK: 텍스트 수집(보이는 부분 위주)

  const range = document.createRange();

  function inBand(rect, margin) {
    return rect.width > 0 && rect.height > 0 && rect.bottom >= -margin && rect.top <= innerHeight + margin &&
      rect.right >= 0 && rect.left <= innerWidth;
  }

  // 코드 예제 바로 위 언어 선택 탭(예: 코드 블록 옆 "Python" 드롭다운)의 단어 하나는 코드 언어 이름이므로 번역하지 않는다.
  // 근거는 좁게 잡는다: 단어 하나 + 버튼·탭·선택 컨트롤 안 + 그 컨트롤을 감싼 가장 가까운 묶음에 코드 블록(pre)이 있고
  // 그 묶음이 사실상 코드 예제 카드일 때(코드 밖 글자가 짧음)만. 본문·메뉴 속 같은 단어(Go·Rust 등)는 그대로 번역한다.
  const SINGLE_TOKEN = /^[\p{L}\p{N}][\p{L}\p{N}+#.\-]{0,23}$/u;
  const LABEL_CONTROL = "button,[role='button'],[role='tab'],[role='combobox'],[aria-haspopup],[role='option'],[role='menuitemradio']";
  function isCodeLanguageLabel(parent, trimmed) {
    if (!SINGLE_TOKEN.test(trimmed)) return false;
    const control = parent.closest(LABEL_CONTROL);
    if (!control) return false;
    let el = control.parentElement;
    for (let depth = 0; depth < 6 && el && el !== document.body; depth += 1, el = el.parentElement) {
      const blocks = el.querySelectorAll("pre");
      if (blocks.length) {
        const codeChars = [...blocks].reduce((total, block) => total + block.textContent.length, 0);
        return el.textContent.length - codeChars <= 400;
      }
    }
    return false;
  }

  // 모델 카드의 큰 이름도 이미지가 아니라 DOM 글자일 수 있다. 같은 작은 링크 안의 버전 붙은
  // 제품명에 다시 나온 단어만 이름으로 보존한다(일반 본문의 단어 뜻풀이는 막지 않는다).
  function isProductNameLabel(parent, trimmed) {
    if (!/^[A-Za-z][A-Za-z0-9.+\-]{1,23}$/.test(trimmed)) return false;
    const card = parent.closest("a[href]");
    if (!card || card.textContent.length > 600) return false;
    const source = originalTextOf(card, 600, " ");
    const word = trimmed.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    return new RegExp(`(^|\\s)\\S*\\d\\S*\\s+${word}($|[^\\p{L}\\p{N}])`, "u").test(source);
  }

  /** done(배열)을 주면 지금 번역 설정으로 이미 처리한(번역했거나 원문 유지로 정한) 조각도 같은 기준(같은 범위·같은 제외 규칙,
   *  최대 MAX_UNITS)으로 그 배열에 모은다. 목록(인벤토리) 집계에만 쓰며, 돌려주는 작업 대상은 done이 없을 때와 같다. */
  function collectUnits(done = null) {
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
      let finished = false;
      if (record) {
        if (record.target === profile() && (value === record.translated || (record.translated === null && value === record.original))) {
          if (!done || done.length >= MAX_UNITS) continue;
          finished = true;
          source = record.original;
        } else if (value === record.translated) source = record.original;
        else if (value !== record.original) records.delete(node);
      }
      const trimmed = source.trim();
      if (trimmed.length < 2 || trimmed.length > MAX_TEXT || !LETTER.test(trimmed)) continue;
      const parent = node.parentElement;
      if (!parent) continue;
      let ok = parentOK.get(parent);
      if (ok === undefined) {
        ok = !parent.closest(SKIP_SELECTOR) && !parent.isContentEditable;
        // 사라진 도구·거의 투명한 뷰어 식별 문자열은 위치 상자가 남아 있어도 번역하지 않는다.
        for (let el = parent; ok && el; el = el.parentElement) {
          const style = getComputedStyle(el);
          if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse" ||
              Number(style.opacity) <= 0.01 || style.contentVisibility === "hidden") ok = false;
        }
        parentOK.set(parent, ok);
      }
      if (!ok) continue;
      if (isCodeLanguageLabel(parent, trimmed) || isProductNameLabel(parent, trimmed)) continue;
      range.selectNodeContents(node);
      const rect = range.getBoundingClientRect();
      if (!inBand(rect, margin)) continue;
      const unit = { node, value, source, trimmed };
      if (finished) {
        done.push(unit);
        continue;
      }
      if (rect.bottom >= 0 && rect.top <= innerHeight) visible.push(unit);
      else near.push(unit);
      if (visible.length >= MAX_UNITS) break;
    }
    return visible.concat(near).slice(0, MAX_UNITS);
  }

  function pruneRecords() {
    for (const node of records.keys()) {
      if (!node.isConnected) { records.delete(node); removeFontSpan(node); }
    }
    while (records.size > RECORD_LIMIT) {
      const node = records.keys().next().value;
      records.delete(node);
      removeFontSpan(node);
    }
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
    if (state.view === "translated" && translated !== null) applyNodeFont(unit.node, state.fontStyle);
    else removeFontSpan(unit.node);
  }

  /** shared(선택): 같은 패스의 그림 재사용과 나누는 상태 { override, held: Map(인식 원문 → 번역|null) }. 1회성 번역이면 재사용할
   *  그림(reusableRecord로 확인한 남겨 둔 덮개)의 인식 원문을 일반 글자와 같은 요청 목록에 합쳐 보내고, 결과를 held에 남긴다. */
  async function translateTextPass(pageGen, shared = null) {
    pruneRecords();
    const override = state.pageEngineOverride;
    const external = isExternal();
    // 목록은 화면 근처의 실제 원문 조각 전체로 센다: 이번에 보낼 조각과 지금 설정으로 이미 처리한 조각을 함께 센다
    // (이미 다 번역한 뒤의 자동 패스가 일반 글자를 0으로 덮지 않게). 문장 수 기준(sentenceCount)은 그대로다.
    const done = [];
    const units = external ? collectUnits(done).slice(0, MAX_EXTERNAL_UNITS) : collectUnits(done);
    const inventory = inventoryOf(pageGen);
    const counted = units.concat(done);
    updateInventory(inventory, { textMessages: counted.length,
                                 textSentences: counted.reduce((sum, unit) => sum + sentenceCount(unit.trimmed), 0) });
    // 1회성 Google·DeepL 번역(override)일 때만 문단을 그 엔진의 한도 이하 조각으로 나눈다(JS 문자열 길이 기준, 분리자 보존 —
    // 조각을 그대로 이어 붙이면 원문과 같다). 그 밖의 경로는 chunkParagraph(text, Infinity) === [text]라 그대로다.
    const chunkMax = override ? EXTERNAL_PAGE_MAX_CHARS[override.engine] || 0 : Infinity;
    if (!(chunkMax > 0)) return null;
    const groups = new Map(); // 보낼 조각 글자 → [{ unit, index }]
    const pending = new Map(); // unit → { parts, resultParts }(끝까지 조각이 모이면 한 번에 적용)
    for (const unit of units) {
      if (!override) {
        const cached = cacheGet(unit.trimmed);
        if (cached !== undefined) {
          applyUnit(unit, cached, langGet(unit.trimmed));
          continue;
        }
      }
      const parts = chunkParagraph(unit.trimmed, chunkMax);
      const resultParts = new Array(parts.length).fill(undefined);
      parts.forEach((part, index) => {
        // 글자 없는 조각(문장 사이 공백·기호만)은 보내지 않고 그대로 둔다(엔진이 번역하지 않아 문단 전체가 실패로 남지 않게).
        if (parts.length > 1 && !LETTER.test(part)) { resultParts[index] = part; return; }
        const cached = cacheGet(part);
        if (cached !== undefined) resultParts[index] = keepEdges(part, cached, parts.length);
      });
      if (resultParts.every((value) => value !== undefined)) {
        applyUnit(unit, resultParts.join("").trimEnd(), parts.length === 1 ? langGet(unit.trimmed) : undefined);
        continue;
      }
      pending.set(unit, { parts, resultParts });
      parts.forEach((part, index) => {
        if (resultParts[index] !== undefined) return;
        if (!groups.has(part)) groups.set(part, []);
        groups.get(part).push({ unit, index });
      });
    }
    // 1회성 번역: 이미 검증한 남겨 둔 그림(재캡처·재인식 없이 재사용)의 인식 원문을 같은 요청 목록에 합친다. 일반 글자와 같은
    // 원문이면 한 번만 보내고, 지금 기준(profile) 캐시에 있으면 보내지 않는다. 새 그림의 인식(OCR)은 여기서 보내지 않는다.
    const heldSources = override && shared && shared.override === override ? new Set(heldReuseSources()) : new Set();
    const texts = mergeSendList([...groups.keys()], heldSources, (source) => cacheGet(source) !== undefined);
    const engine = override ? override.engine : state.engine;
    const target = override ? override.target : state.target;
    const maxTexts = external ? externalBatchTexts(engine) : BATCH_TEXTS;
    const maxChars = external ? EXTERNAL_BATCH_CHARS : BATCH_CHARS;
    // 다듬기 후속 요청 후보(이 패스에서 실제로 Mac 기본 번역을 거친, 조각 내지 않은 줄만). 아래에서 작은 개수만 고른다.
    const refinePool = [];
    // 단계별 걸린 시간(ms, 숫자만 — 원문은 담지 않음). 팝업 상태(snapshot)로만 확인할 수 있다.
    const textTiming = { batches: 0, roundtrip: 0, native: 0 };
    state.timing.text = textTiming;
    const action = state.passAction && state.passAction.gen === pageGen ? state.passAction : null;
    if (texts.length) {
      // 실제로 보낼 글자가 생겼다: 이 패스의 동작을 보여 줄 동작으로 정하고 번역 단계로 넘어간다.
      commitAction(action);
      if (action) {
        action.timing.text = textTiming;
        markStage(action, external ? "external" : "text");
      }
      // 보낼 조각 수와 글자 수(JS 문자열 길이 = UTF-16)를 보내기 전에 알린다. 외부 엔진이면 묶음마다 보낸 양을 더한다.
      updateInventory(inventory, {
        phase: external ? "external" : "translating",
        send: { texts: texts.length, chars: texts.reduce((sum, text) => sum + text.length, 0), sentTexts: 0, sentChars: 0,
                batch: 0, batchTexts: 0, batchChars: 0 }
      });
    }
    function consume(batch, response) {
      if (!stillCurrent(pageGen) || state.pageEngineOverride !== override) return;
      if (response.missing.length) state.warning = `언어 팩 필요: ${response.missing.join(", ")}`;
      if (response.warning) state.warning = response.warning;
      if (typeof response.aiRefine === "boolean") state.aiRefine = response.aiRefine;
      // langs는 입력과 같은 개수일 때만 쓴다(구버전 네이티브 앱이면 없음 → 언어 통계는 집계하지 않는다). 조각 낸
      // 문단은 조각마다 다른 언어로 보일 수 있어 통계에 넣지 않는다(override에서만 조각이 생긴다).
      const langs = !override && Array.isArray(response.langs) && response.langs.length === batch.length ? response.langs : null;
      response.texts.forEach((value, index) => {
        const ok = typeof value === "string";
        // 실패(null/미번역)는 캐시에 남기지 않는다 — 다음에 다시 시도하게 하며, 빈 문자열을 "성공한 번역"으로
        // 오인해 조각을 합칠 때 그 부분만 조용히 사라지지 않게 한다(원래 문제: null → "" → join 시 글자 소실).
        if (ok) cachePut(batch[index], value);
        // 같은 요청에 합친 그림 원문의 결과(이 패스에서만 쓰고, 실패도 남겨 같은 패스에서 다시 보내지 않는다).
        if (heldSources.has(batch[index])) shared.held.set(batch[index], imageTranslation(value));
        const lang = langs ? langs[index] : undefined;
        if (ok && langs) langPut(batch[index], lang);
        for (const { unit, index: partIndex } of groups.get(batch[index]) || []) {
          const entry = pending.get(unit);
          if (!entry) continue;
          // 실패한 조각은 원문 그대로 채워 둔다(합친 글자 수는 항상 원문과 같아 어딘가 비는 일이 없다). 전체를
          // 번역으로 적용할지는 failed 플래그로 따로 판단한다.
          entry.resultParts[partIndex] = ok ? keepEdges(entry.parts[partIndex], value, entry.parts.length) : entry.parts[partIndex];
          if (!ok) entry.failed = true;
          if (entry.resultParts.every((v) => v !== undefined)) {
            pending.delete(unit);
            if (entry.failed) {
              // 조각 중 하나라도 실패하면 번역 절반만 보여주지 않고 이 문단 전체를 원문으로 유지한다.
              state.warning = "일부 문단을 번역하지 못해 원문을 유지했습니다. 다시 시도하면 이어서 번역합니다.";
              applyUnit(unit, null, undefined);
              continue;
            }
            const joined = entry.resultParts.join("").trimEnd();
            applyUnit(unit, joined, entry.parts.length === 1 ? lang : undefined);
            if (joined && entry.parts.length === 1) refinePool.push({ node: unit.node, original: unit.source, draft: joined });
          }
        }
      });
    }
    // 처음 보는 그림은 인식 뒤 일반 글자와 같이 보내므로 외부 서비스 준비를 두 번 기다리지 않는다.
    // 기존 그림 재사용과 큰 일반 글자 묶음은 이전 검증 경로를 유지한다.
    if (override && shared && texts.length && texts.length <= maxTexts &&
        texts.reduce((sum, text) => sum + text.length, 0) <= maxChars && !heldSources.size &&
        state.images && imageCandidates().some((candidate) => !reusableRecord(candidate))) {
      const deferred = {
        texts, done: false,
        consume(response) {
          if (deferred.done) return;
          if (!Array.isArray(response.texts) || response.texts.length !== texts.length) throw new Error("번역 응답 형식이 올바르지 않습니다.");
          consume(texts, response);
          textTiming.batches += 1;
          // 합친 이미지 요청의 시간은 imageTiming에 있다. 일반 글자 단독 시간처럼 중복 표시하지 않는다.
          if (!Array.isArray(response.images) && response.timing && Number.isInteger(response.timing.translate)) textTiming.native += response.timing.translate;
          const sendInfo = inventory && state.inventory === inventory ? inventory.send : null;
          const chars = texts.reduce((sum, text) => sum + text.length, 0);
          if (sendInfo) Object.assign(sendInfo, { batch: sendInfo.batch + 1, batchTexts: texts.length, batchChars: chars,
                                                sentTexts: sendInfo.sentTexts + texts.length, sentChars: sendInfo.sentChars + chars });
          deferred.done = true;
        },
        async flush() {
          if (deferred.done || !stillCurrent(pageGen) || state.pageEngineOverride !== override) return;
          const sentAt = performance.now();
          const response = await send({ cmd: "translatePageExternal", engine, target, texts, token: override.token,
                                        ...(action ? { action: action.id } : {}) });
          textTiming.roundtrip += Math.round(performance.now() - sentAt);
          deferred.consume(response);
        }
      };
      shared.deferred = deferred;
      return null;
    }
    let start = 0;
    while (start < texts.length) {
      const { batch, chars, next } = nextBatch(texts, start, maxTexts, maxChars);
      start = next;
      if (!stillCurrent(pageGen) || state.pageEngineOverride !== override) return;
      const sendInfo = inventory && state.inventory === inventory ? inventory.send : null;
      if (sendInfo) Object.assign(sendInfo, { batch: sendInfo.batch + 1, batchTexts: batch.length, batchChars: chars });
      const sentAt = performance.now();
      const actionId = action ? { action: action.id } : {};
      const response = await send(override
        ? { cmd: "translatePageExternal", engine, target, texts: batch, token: override.token, ...actionId }
        : { cmd: "translate", target, engine, texts: batch, ...actionId });
      textTiming.batches += 1;
      textTiming.roundtrip += Math.round(performance.now() - sentAt);
      if (sendInfo) Object.assign(sendInfo, { sentTexts: sendInfo.sentTexts + batch.length, sentChars: sendInfo.sentChars + chars });
      if (response.timing && Number.isInteger(response.timing.translate)) textTiming.native += response.timing.translate;
      if (!stillCurrent(pageGen) || state.pageEngineOverride !== override ||
          target !== (override ? override.target : state.target) || engine !== (override ? override.engine : state.engine)) return;
      consume(batch, response);
    }
    // 메뉴·탭의 단어 하나(띄어 쓰는 문자)는 다듬을 문장이 아니므로 고르지 않는다(이전에는 화면 위쪽 메뉴 단어가
    // 8칸을 먼저 채워 제목·본문·각주 문장이 다듬기에 닿지 못했다). 길이 상한을 넘는 줄도 빼 요청 전체 거부를 막는다.
    const refineCandidates = [];
    let refineChars = 0;
    // 제목·각주를 포함한 제목 블록을 먼저 다듬는다. 위쪽 메뉴가 한정된 칸을 차지해 문서 아래 각주가
    // 영구히 제외되지 않도록 하며, 같은 우선순위에서는 기존 문서 순서를 유지한다.
    const prioritizedRefinePool = refinePool.slice().sort((a, b) =>
      Number(!a.node.parentElement?.closest("h1,h2,h3,h4,h5,h6")) -
      Number(!b.node.parentElement?.closest("h1,h2,h3,h4,h5,h6")));
    for (const candidate of prioritizedRefinePool) {
      if (refineCandidates.length >= MAX_REFINE_ITEMS) break;
      if (isSpacedSingleWord(candidate.original)) continue;
      if (candidate.original.trim().length <= 12 && candidate.node.parentElement?.closest("button,a,[role='button'],[role='tab'],[role='menuitem']")) continue;
      const size = candidate.original.length + candidate.draft.length;
      if (candidate.original.length > REFINE_ITEM_CHARS || candidate.draft.length > REFINE_ITEM_CHARS ||
          refineChars + size > REFINE_TOTAL_CHARS) continue;
      refineChars += size;
      refineCandidates.push(candidate);
    }
    // 다듬기(기기 내 언어 모델)는 이미지 글자 인식·번역과 같은 기기 자원을 다투므로, 바로 보내지 않고 이번 패스의
    // 이미지 처리가 끝난 뒤 runPass가 보낸다(그동안 화면에는 이미 번역문이 보인다).
    return !external && state.aiRefine && refineCandidates.length ? refineCandidates : null;
  }

  // MARK: 다듬기 문맥
  // 텍스트 노드마다 따로 번역하면 제목·본문·각주(예: 본문 "raised … series A¹"와 각주의 "at a … valuation")의 관계가
  // 끊겨 뜻이 틀어질 수 있다. 다듬기 요청에만 같은 문단·이웃 블록·연결된 각주의 원문을 짧게 붙여 원문 기준으로
  // 고칠 근거를 준다. 페이지 레이아웃·링크·코드는 건드리지 않고, 붙인 원문은 저장하지 않는다.

  const BLOCK_TAGS = "p,li,h1,h2,h3,h4,h5,h6,dt,dd,td,th,caption,figcaption,blockquote,summary,legend";

  /** 띄어 쓰는 문자(라틴·그리스·키릴 등)로 된 단어 하나인지(네이티브 AppleBrowserRefiner.isSingleWord와 같은 기준). */
  function isSpacedSingleWord(text) {
    const trimmed = text.trim();
    return trimmed.length > 0 && !/\s/.test(trimmed) && /^[\u0000-ԯ]+$/.test(trimmed);
  }

  /** 요소 안 글자를 번역 전 원문으로 모은다(이미 번역한 노드는 기록해 둔 원문). 위첨자(각주 번호)는 [n]으로 표시한다. */
  function originalTextOf(el, limit, separator = "") {
    const parts = [];
    let length = 0;
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node && length < limit; node = walker.nextNode()) {
      if (node.parentElement && node.parentElement.closest("script,style,noscript,template,smt-translator-layer")) continue;
      const record = records.get(node);
      let value = record && node.nodeValue === record.translated ? record.original : node.nodeValue;
      if (node.parentElement && node.parentElement.closest("sup") && value.trim()) value = `[${value.trim()}]`;
      parts.push(value);
      length += value.length;
    }
    return parts.join(separator).replace(/\s+/g, " ").trim().slice(0, limit);
  }

  /** 글자를 담은 가장 가까운 블록(문단·제목·목록 항목 등). 태그로 못 찾으면 inline이 아닌 가까운 조상. */
  function blockOf(el) {
    if (!el) return null;
    const tagged = el.closest(BLOCK_TAGS);
    if (tagged) return tagged;
    for (let depth = 0; el && el !== document.body && depth < 6; depth += 1, el = el.parentElement) {
      if (!getComputedStyle(el).display.startsWith("inline")) return el;
    }
    return null;
  }

  /** 블록 바로 앞/뒤의 글자 있는 형제 블록(제목 ↔ 첫 문단). 형제가 없으면 한 단계 위에서 찾는다. */
  function neighborBlock(block, forward) {
    for (let el = block, depth = 0; el && el !== document.body && depth < 2; el = el.parentElement, depth += 1) {
      let sibling = forward ? el.nextElementSibling : el.previousElementSibling;
      for (let step = 0; sibling && step < 2; step += 1) {
        if (!sibling.matches("script,style,noscript,template,smt-translator-layer") && LETTER.test(sibling.textContent)) return sibling;
        sibling = forward ? sibling.nextElementSibling : sibling.previousElementSibling;
      }
    }
    return null;
  }

  /** 문서 안 #id 링크로 이어진 각주와 본문: 이 블록이 가리키는 각주, 이 블록(또는 감싼 요소)을 가리키는 본문 블록. */
  function footnoteBlocks(block) {
    const found = [];
    const link = block.querySelector("a[href^='#']");
    const id = link && link.getAttribute("href").slice(1);
    if (id) {
      const target = document.getElementById(decodeURIComponent(id));
      if (target && !target.contains(block) && !block.contains(target)) found.push(blockOf(target) || target);
    }
    for (let el = block, depth = 0; el && el !== document.body && depth < 3; el = el.parentElement, depth += 1) {
      if (!el.id) continue;
      const ref = document.querySelector(`a[href="#${CSS.escape(el.id)}"]`);
      if (ref && !el.contains(ref)) { found.push(blockOf(ref) || ref); break; }
    }
    return found;
  }

  /** 텍스트 노드 하나의 다듬기 문맥(원문): 자기 문단 전체(조각일 때) → 연결된 각주/본문 → 앞 블록 → 뒤 블록. */
  function textRefineContext(node, original) {
    try {
      const block = node.isConnected ? blockOf(node.parentElement) : null;
      if (!block) return "";
      const own = original.replace(/\s+/g, " ").trim();
      const parts = [];
      const blockText = originalTextOf(block, REFINE_CONTEXT_PART);
      if (blockText && blockText !== own) parts.push(blockText);
      for (const el of [...footnoteBlocks(block), neighborBlock(block, false), neighborBlock(block, true)]) {
        if (!el || el.contains(block)) continue;
        const text = originalTextOf(el, REFINE_CONTEXT_PART);
        if (text && text !== own && !parts.includes(text)) parts.push(text);
      }
      return parts.join(" | ").slice(0, REFINE_CONTEXT_CHARS);
    } catch {
      return "";
    }
  }

  /** 다듬기 항목에 문맥(c)을 붙인다. 비었거나 전체 상한을 넘는 문맥은 생략한다(그 항목은 문맥 없이 다듬는다). */
  function withRefineContext(items, contexts) {
    let total = 0;
    return items.map((item, index) => {
      const context = (contexts[index] || "").slice(0, REFINE_CONTEXT_CHARS);
      if (!context || total + context.length > REFINE_CONTEXT_TOTAL) return item;
      total += context.length;
      return { ...item, c: context };
    });
  }

  /** 이미 그려진 DOM 텍스트 번역 중 일부만 다듬어 같은 노드 값만 바꾼다(새 번역으로 세지 않음).
   *  실패·거부·취소는 조용히 무시하고 기존 번역을 그대로 둔다. */
  async function refineTextCandidates(candidates, pageGen, supplied = null) {
    const items = withRefineContext(candidates.map((c, index) => ({ k: `r${index}`, o: c.original, d: c.draft })),
      candidates.map((c) => textRefineContext(c.node, c.original)));
    let response;
    try {
      response = await (supplied || send({ cmd: "refine", target: state.target, engine: state.engine, items }));
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
  // 조각 묶음은 모든 조각의 주소를 차례로 이어 키로 쓴다(조각 하나만 바뀌어도 다른 그림). 조각 하나면 그 img 하나의 키다.
  function membersKey(members) {
    return `${profile()}|${members.map((m) => `${m.src}|${m.currentSrc}`).join("|")}`;
  }

  /** 번역 설정과 무관한 그림 신원: 모든 조각의 주소·그려진 주소·원본 크기. 번역 서비스를 바꿀 때 같은 그림인지 가리는 데만 쓴다. */
  function sourceKey(members) {
    return members.map((m) => `${m.src}|${m.currentSrc}|${m.naturalWidth}x${m.naturalHeight}`).join("|");
  }

  // 네이티브는 인식 원문(o)을 700자까지만 보낸다(배경도 UTF-16 700자로 자른다). 그 길이에 닿은 항목은 원문 전체라는 보장이
  // 없으므로 그 그림은 재사용하지 않고 다시 인식한다.
  const REUSE_SOURCE_MAX = 700;

  /** 번역 서비스를 바꿀 때 남겨 둔(held) 덮개 기록 중, 이 후보와 같은 그림·같은 자리·다 그려진 결과라 원문 인식과 복원 조각을
   *  그대로 다시 쓸 수 있는 기록. 하나라도 어긋나면 null(정상 캡처·인식). */
  function reusableRecord(candidate) {
    const record = imageRecords.get(candidate.img);
    if (!record || !record.held || !record.done || record.held.url !== location.href || !record.box.isConnected) return null;
    const members = candidate.members || [candidate.img];
    if (record.members.length !== members.length || record.members.some((m, i) => m !== members[i])) return null;
    if (record.source !== sourceKey(members) || !members.every((m) => m.isConnected && m.complete)) return null;
    const { rect, clip } = candidate;
    if (Math.abs(rect.width - record.elemW) > 2 || Math.abs(rect.height - record.elemH) > 2) return null;
    // 그때 인식한 영역이 지금 보이는 영역을 덮어야 한다(이미 그린 그림을 다시 하지 않는 기존 기준과 같다).
    const offX = clip.x - rect.left, offY = clip.y - rect.top;
    if (!(record.offX <= offX + 1 && record.offY <= offY + 1 &&
          record.offX + record.w >= offX + clip.w - 1 && record.offY + record.h >= offY + clip.h - 1)) return null;
    if (!Array.isArray(record.items) || !Array.isArray(record.patches) || record.patches.length !== record.items.length) return null;
    for (const item of record.items) {
      if (!item || typeof item.o !== "string" || !item.o.trim()) return null;
      if (item.o.length >= REUSE_SOURCE_MAX || Array.from(item.o).length >= REUSE_SOURCE_MAX) return null;
    }
    return record;
  }

  /** 1회성 번역 패스에서 지금 재사용할 수 있는 남겨 둔 그림(imagePass와 같은 후보·같은 reusableRecord 기준)의 인식 원문(o) 목록.
   *  지난번 실제로 그린 항목의 원문만이며 이전 번역문(t)은 담지 않는다. 남겨 둔 덮개가 없으면 후보를 찾지 않는다. */
  function heldReuseSources() {
    if (!state.pageEngineOverride || !state.images || document.visibilityState !== "visible") return [];
    if (![...imageRecords.values()].some((record) => record.held)) return [];
    repositionOverlays();
    const sources = [];
    for (const candidate of imageCandidates()) {
      const record = reusableRecord(candidate);
      if (record) for (const item of record.items) sources.push(item.o);
    }
    return sources;
  }

  // 덮개를 모두 지우는 경로(원문 보기·전역 끄기·이동·설정 변경·중지·전체화면)와 그림 변경 때 올린다. 그리다 그만둔 그림에 이전
  // 성공 덮개를 되살릴 때 이 값이 그대로일 때만 되살린다(사용자가 지운 덮개를 다시 띄우지 않게).
  let overlayEpoch = 0;

  /** 남겨 둔(held) 이전 성공 덮개가 지금도 같은 문서·같은 img 연결·같은 그림(sourceKey)·같은 크기·보이는 상태 그대로인지. 맞으면
   *  자리를 지금 위치로 맞추고 true. 이전 성공(record.done)이고 원문 가림 정보(items·patches)를 가진 기록만 해당한다. */
  function heldStillValid(img, record) {
    if (!record || !record.held || !record.done || record.held.url !== location.href) return false;
    if (!Array.isArray(record.items) || !Array.isArray(record.patches)) return false;
    if (record.source !== sourceKey(record.members)) return false;
    if (!record.members.every((m) => m.isConnected && m.complete && isImageVisible(m))) return false;
    const geometry = recordGeometry(img, record);
    const rect = geometry ? geometry.rect : null;
    if (!rect || rect.width <= 0 || Math.abs(rect.width - record.elemW) > 2 || Math.abs(rect.height - record.elemH) > 2) return false;
    record.box.style.left = `${rect.left + record.offX}px`;
    record.box.style.top = `${rect.top + record.offY}px`;
    record.box.style.display = "";
    return true;
  }

  /** 이전 성공 덮개(held)를 그 img 자리에 다시 붙인다. heldStillValid를 지킬 때만. */
  function restoreHeld(img, prior) {
    if (!heldStillValid(img, prior)) return false;
    if (!prior.box.isConnected) layer().appendChild(prior.box);
    imageRecords.set(img, prior);
    return true;
  }

  /** 새 서비스 번역이 실패하거나 시간 한도를 넘겼을 때: 원문 그림으로 되돌리지 않고, 남겨 둔 이전 성공 덮개 중 heldStillValid를
   *  지키는 것만 그대로 둔다(나머지는 지운다). swapBack이면(시간 초과로 1회성 기준이 끝날 때) 이번 기준으로 그린(그리던) 덮개는
   *  지우고, 같은 그림에 대신했던 이전 성공 덮개 사본(record.prior, 메모리에만)이 유효하면 그것으로 되돌린다. 이전 덮개가 없던
   *  그림은 지운다(원문 가림을 보장하지 않는다). swapBack이 아니면 지금 기준으로 그린 덮개는 그대로 둔다. 남긴 이전 덮개 수를 돌려준다. */
  function retainHeldOverlays(swapBack) {
    let kept = 0;
    for (const [img, record] of Array.from(imageRecords.entries())) {
      if (!record.held && !swapBack) continue;
      if (record.held && record.box.isConnected && heldStillValid(img, record)) {
        kept += 1;
        continue;
      }
      record.box.remove();
      imageRecords.delete(img);
      if (!record.held && record.prior && restoreHeld(img, record.prior)) kept += 1;
    }
    return kept;
  }

  /** 이번 동작이 완료로 확정된 뒤에는 되돌릴 일이 없으므로 이전 성공 덮개 사본을 놓는다(메모리 정리). */
  function dropPriors() {
    for (const record of imageRecords.values()) record.prior = null;
  }

  /** 이전 성공 덮개를 남겨 둔 채 실패·초과로 끝났음을 알리는 고정 문구(원문·주소는 담지 않는다). */
  const HELD_KEPT_WARNING = "그림은 이전에 그린 번역을 유지합니다(이번 번역 아님 · 원문 보기로 지움)";

  /** 번역 서비스를 바꿀 때: 다 그려진 덮개는 지우지 않고 남겨(held) 새 번역이 올 때까지 원문 글자를 계속 가린다. 원문 인식과
   *  복원 조각은 재사용 후보가 된다. 그리는 중이던(덜 된) 덮개는 지운다. */
  function holdImageOverlays() {
    for (const [img, record] of Array.from(imageRecords.entries())) {
      if (record.done && record.box.isConnected && Array.isArray(record.items) && Array.isArray(record.patches)) {
        record.held = { url: location.href };
        record.prior = null;
        continue;
      }
      record.box.remove();
      imageRecords.delete(img);
    }
  }

  /** 남겨 둔(held) 덮개를 지운다. inViewOnly면 지금 화면에 걸친 것만(이번 패스에서 새 번역으로 바꾸지 못한 것). */
  function dropHeldImages(inViewOnly) {
    for (const [img, record] of Array.from(imageRecords.entries())) {
      if (!record.held) continue;
      if (inViewOnly) {
        const r = record.box.getBoundingClientRect();
        if (r.width <= 0 || r.height <= 0 || r.bottom <= 0 || r.top >= innerHeight || r.right <= 0 || r.left >= innerWidth) continue;
      }
      record.box.remove();
      imageRecords.delete(img);
    }
  }

  function unionRect(rects) {
    const left = Math.min(...rects.map((r) => r.left)), top = Math.min(...rects.map((r) => r.top));
    const right = Math.max(...rects.map((r) => r.right)), bottom = Math.max(...rects.map((r) => r.bottom));
    return { left, top, right, bottom, width: right - left, height: bottom - top };
  }

  // 한 장의 그림을 세로로 잘라 이어 붙인 img 조각들과 빈틈 없는 좌우 펼침 두 장(뷰어가 큰 페이지를 여러 장으로 나눠 그리는 경우)은 따로 OCR하면
  // 경계에 걸친 글자가 끊기므로 한 후보로 묶는다. 조각 가까이의 첫 공통 조상(4단계 안)이 2~8장만 담고 글자가 거의
  // 없으며, 모든 조각이 다 불러와져 보이고, 같은 왼쪽·너비로 거의 빈틈 없이(간격 3px 이하, 겹침 4px 이하) 위아래로
  // 이어질 때만 묶는다. 이웃 페이지·갤러리·본문을 함께 담은 조상이거나 하나라도 어긋나면 null(기존 단일 이미지 처리).
  const STRIP_MAX = 8;

  function verticalImageStrip(img) {
    let ancestor = img.parentElement;
    for (let depth = 0; ancestor && ancestor !== document.body && depth < 4; ancestor = ancestor.parentElement, depth += 1) {
      const imgs = ancestor.getElementsByTagName("img");
      if (imgs.length < 2) continue;
      if (imgs.length > STRIP_MAX || ancestor.textContent.trim().length > 40) return null;
      const members = Array.from(imgs);
      for (const m of members) {
        if (!m.complete || !m.naturalWidth || !m.naturalHeight || m.closest(SKIP_SELECTOR) || !isImageVisible(m)) return null;
      }
      const pairs = members.map((m) => ({ m, r: m.getBoundingClientRect() })).sort((a, b) => a.r.top - b.r.top);
      // 펼친 만화의 좌우 두 장에 걸친 큰 제목도 한 번에 읽는다. 높이·위쪽 경계가 같고 빈틈 없이 맞닿은
      // 큰 두 장만 허용한다. 작은 아이콘·나란한 썸네일·간격 있는 갤러리는 묶지 않는다.
      if (pairs.length === 2) {
        const horizontal = [...pairs].sort((a, b) => a.r.left - b.r.left);
        const [left, right] = horizontal.map((p) => p.r);
        const gap = right.left - left.right;
        if (left.width >= 300 && right.width >= 300 && left.height >= 400 && right.height >= 400 &&
            Math.abs(left.top - right.top) <= 2 && Math.abs(left.height - right.height) <= 2 && gap >= -4 && gap <= 3) {
          return { members: horizontal.map((p) => p.m), rects: horizontal.map((p) => p.r) };
        }
      }
      const first = pairs[0].r;
      for (let i = 0; i < pairs.length; i += 1) {
        const r = pairs[i].r;
        if (r.width <= 0 || r.height <= 0 || Math.abs(r.left - first.left) > 2 || Math.abs(r.width - first.width) > 2) return null;
        if (i > 0) {
          const gap = r.top - pairs[i - 1].r.bottom;
          if (gap > 3 || gap < -4) return null;
        }
      }
      return { members: pairs.map((p) => p.m), rects: pairs.map((p) => p.r) };
    }
    return null;
  }

  function imageStrip(img) {
    const own = verticalImageStrip(img);
    let ancestor = img.parentElement;
    for (let depth = 0; ancestor && ancestor !== document.body && depth < 4; ancestor = ancestor.parentElement, depth += 1) {
      const all = Array.from(ancestor.getElementsByTagName("img"));
      if (all.length > 48 || ancestor.textContent.trim().length > 40) break;
      const seen = new Set(), pages = [];
      for (const member of all) {
        const r = member.getBoundingClientRect();
        if (seen.has(member) || Math.min(innerWidth, r.right) - Math.max(0, r.left) < r.width * 0.3 || r.bottom <= 0 || r.top >= innerHeight ||
            !member.complete || !member.naturalWidth || member.closest(SKIP_SELECTOR) || !isImageVisible(member)) continue;
        const strip = verticalImageStrip(member);
        const members = strip ? strip.members : [member];
        members.forEach((m) => seen.add(m));
        const rects = strip ? strip.rects : [r];
        pages.push({ members, rects, rect: unionRect(rects) });
      }
      if (pages.length !== 2) continue;
      pages.sort((a, b) => a.rect.left - b.rect.left);
      const [left, right] = pages.map((p) => p.rect), gap = right.left - left.right;
      if (left.width < 300 || right.width < 300 || left.height < 400 || right.height < 400 ||
          Math.abs(left.top - right.top) > 2 || Math.abs(left.height - right.height) > 2 || gap < -4 || gap > 3) continue;
      const members = pages.flatMap((p) => p.members);
      if (!members.includes(img) || members.length > STRIP_MAX) continue;
      return { members, rects: pages.flatMap((p) => p.rects) };
    }
    return own;
  }

  /** 덮개 기록의 지금 자리(묶음이면 조각 합집합). 묶음이 깨졌거나 조각이 바뀌었거나 사라졌으면 null. */
  function recordGeometry(img, record) {
    const members = record.members;
    if (members.length > 1) {
      const strip = img.isConnected ? imageStrip(img) : null;
      if (!strip || strip.members.length !== members.length || strip.members.some((m, i) => m !== members[i])) return null;
      return { rect: unionRect(strip.rects), rects: strip.rects };
    }
    if (!img.isConnected) return null;
    const rect = img.getBoundingClientRect();
    return { rect, rects: [rect] };
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

  // 뷰어의 메뉴가 그림을 잠시 어둡게 만든 상태를 배경색으로 저장하지 않는다.
  function isImageCaptureReady(img) {
    for (let el = img; el instanceof Element; el = el.parentElement) {
      const style = getComputedStyle(el);
      if (Number(style.opacity) < 0.98) return false;
      for (const match of style.filter.matchAll(/brightness\(([^)]+)\)/g)) {
        const value = match[1].trim();
        const amount = parseFloat(value) / (value.endsWith("%") ? 100 : 1);
        if (Number.isFinite(amount) && amount < 0.98) return false;
      }
    }
    return true;
  }

  // MARK: 그림 위를 덮은 막 — 뷰어가 메뉴를 띄우는 동안 그림의 조상이 아닌 별도 요소(반투명 검정 막·그라데이션·
  // backdrop-filter, 또는 조상의 ::before/::after)로 그림 전체를 어둡게 덮는 경우가 있다. 조상의 opacity/filter만 보는
  // isImageCaptureReady로는 보이지 않고, 밝기 보정 견본은 그 막보다 위(최상단)에 그려져 막의 영향을 받지 않으므로 보정도
  // 되지 않는다. 그대로 캡처하면 흰 말풍선이 회색으로 찍혀 회색 복원 조각·배경색이 남는다. 그림 위 여러 지점에서 실제로
  // 그림보다 위에 칠해진 층을 찾아, 지점의 과반이 덮였으면 그 그림은 이번에 캡처하지 않고 막이 바뀔 때 다시 시도한다.
  const COVER_PROBE = [0.2, 0.5, 0.8];
  const COVER_MIN_ALPHA = 0.05;
  // 마지막 확인에서 그림을 덮고 있던 요소(이 요소나 그 조상의 변화·제거·전환 끝에서 다시 시도한다).
  let imageCovers = new Set();
  let coverProbeSheet = null;

  function colorAlpha(color) {
    if (!color || color === "transparent") return 0;
    const m = /\(([^)]*)\)/.exec(color);
    if (!m) return 1;
    const slash = m[1].split("/");
    const parts = slash.length > 1 ? [slash[1]] : m[1].split(",");
    if (slash.length === 1 && parts.length < 4) return 1;
    const value = parts[parts.length - 1].trim();
    const alpha = parseFloat(value) / (value.endsWith("%") ? 100 : 1);
    return Number.isFinite(alpha) ? alpha : 1;
  }

  /** 이 스타일의 상자가 아래 그림을 가리거나 물들이는 정도(0~1, 요소 자신의 opacity 제외). */
  function paintAlpha(style) {
    if (style.display === "none" || style.visibility === "hidden") return 0;
    const backdrop = style.backdropFilter || style.webkitBackdropFilter || "none";
    if (backdrop !== "none" || style.backgroundImage !== "none") return 1;
    return colorAlpha(style.backgroundColor);
  }

  /** 그림보다 위에 찍힌 요소 el이 그림 위에 칠하는 층의 실제 불투명도. 그림을 담은 조상이면 자기 상자는 그림 아래이므로
   *  위에 올라온 ::before/::after만 본다. */
  function coverAlpha(el, members) {
    const holds = (node) => members.some((m) => node.contains(m));
    const ancestor = holds(el);
    let chain = 1;
    if (!ancestor) {
      for (let node = el; node instanceof Element && !holds(node); node = node.parentElement) {
        chain *= Number(getComputedStyle(node).opacity);
      }
    }
    if (!(chain >= COVER_MIN_ALPHA)) return 0;
    let alpha = ancestor ? 0 : chain * paintAlpha(getComputedStyle(el));
    for (const pseudo of ["::before", "::after"]) {
      const style = getComputedStyle(el, pseudo);
      if (style.content === "none" || style.content === "normal") continue;
      alpha = Math.max(alpha, chain * Number(style.opacity) * paintAlpha(style));
    }
    return alpha;
  }

  /** 그림 위 지점의 과반이 그림보다 위의 칠해진 층에 덮인 후보. 덮은 요소는 imageCovers에 모은다. pointer-events:none인
   *  막도 찾도록 확인하는 동안만(같은 동기 구간, 화면에 그려지지 않음) 문서에 pointer-events:auto 규칙을 붙였다 뗀다.
   *  adoptedStyleSheets는 DOM을 바꾸지 않아 페이지·자기 변경 감시에 걸리지 않는다. */
  function coveredCandidates(list) {
    const covered = new Set();
    if (!list.length || typeof document.elementsFromPoint !== "function") return covered;
    let previousSheets = null;
    try {
      if (typeof CSSStyleSheet === "function" && "adoptedStyleSheets" in document) {
        if (!coverProbeSheet) {
          coverProbeSheet = new CSSStyleSheet();
          coverProbeSheet.replaceSync("*,*::before,*::after{pointer-events:auto!important}");
        }
        previousSheets = document.adoptedStyleSheets;
        document.adoptedStyleSheets = [...previousSheets, coverProbeSheet];
      }
    } catch {
      previousSheets = null;
    }
    try {
      for (const candidate of list) {
        const members = candidate.members || [candidate.img];
        const { x, y, w, h } = candidate.clip;
        let probed = 0;
        const found = [];
        for (const fy of COVER_PROBE) {
          for (const fx of COVER_PROBE) {
            const stack = document.elementsFromPoint(x + w * fx, y + h * fy);
            const at = stack.findIndex((el) => members.includes(el));
            if (at < 0) continue;
            probed += 1;
            for (let k = 0; k < at; k += 1) {
              const el = stack[k];
              if (el.nodeName.startsWith("SMT-TRANSLATOR-")) continue;
              if (coverAlpha(el, members) >= COVER_MIN_ALPHA) { found.push(el); break; }
            }
          }
        }
        if (probed && found.length * 2 > probed) {
          covered.add(candidate);
          found.forEach((el) => imageCovers.add(el));
        }
      }
    } finally {
      if (previousSheets) {
        try { document.adoptedStyleSheets = previousSheets; } catch {}
      }
    }
    return covered;
  }

  function touchesImageCover(node) {
    if (!(node instanceof Element)) return false;
    for (const cover of imageCovers) {
      if (node === cover || node.contains(cover)) return true;
    }
    return false;
  }

  /** 그림·자리가 그대로이고, 조상이 어둡게 하지 않고, 위에 덮은 막도 없는 후보만 남긴다. */
  function captureReadyCandidates(list) {
    const ready = list.filter((candidate) => candidateUnchanged(candidate) && candidate.members.every(isImageCaptureReady));
    const covered = coveredCandidates(ready);
    return ready.filter((candidate) => !covered.has(candidate));
  }

  /** 기존 덮개 위치를 이미지 현재 위치에 맞추고, 크기가 바뀌었거나 사라졌거나 다른 그림을 불러오는 중이거나 숨겨진 이미지 덮개는 지운다. */
  function repositionOverlays() {
    for (const [img, record] of imageRecords) {
      const geometry = recordGeometry(img, record);
      const rect = geometry ? geometry.rect : null;
      if (!rect || rect.width === 0 || Math.abs(rect.width - record.elemW) > 2 || Math.abs(rect.height - record.elemH) > 2 ||
          !img.complete || !isImageVisible(img) ||
          (record.held ? record.source !== sourceKey(record.members) : record.key !== membersKey(record.members))) {
        record.box.remove();
        imageRecords.delete(img);
        continue;
      }
      record.box.style.left = `${rect.left + record.offX}px`;
      record.box.style.top = `${rect.top + record.offY}px`;
      record.box.style.display = "";
    }
  }

  /** includeStable이 거짓이면(기본, 실제 작업 대상) 이미 그려 둔 그대로인 그림은 뺀다. 참이면(인벤토리 집계용) 그런
   *  그림도 candidate.stable = true로 포함해, 새로 할 일이 없어도 화면에 보이는 그림 전체를 센다. */
  function imageCandidates(includeStable = false) {
    imageCovers = new Set();
    const list = [];
    const grouped = new Set();
    for (const img of document.images) {
      if (grouped.has(img) || !img.complete) continue;
      const own = img.getBoundingClientRect();
      // 화면과 겹치지 않는 그림은 단일로도 고르지 않으므로 묶음도 보이는 조각 쪽에서만 찾는다.
      if (own.bottom <= 0 || own.top >= innerHeight || own.right <= 0 || own.left >= innerWidth) continue;
      const strip = imageStrip(img);
      if (strip) strip.members.forEach((m) => grouped.add(m));
      else if (img.naturalWidth < 64 || img.naturalHeight < 32) continue;
      const members = strip ? strip.members : [img];
      const rects = strip ? strip.rects : [own];
      const rect = strip ? unionRect(rects) : own;
      if (rect.width < 80 || rect.height < 40) continue;
      const clip = {
        x: Math.max(0, rect.left), y: Math.max(0, rect.top),
        r: Math.min(innerWidth, rect.right), b: Math.min(innerHeight, rect.bottom)
      };
      const w = clip.r - clip.x;
      const h = clip.b - clip.y;
      // 묶음은 화면보다 길 수 있으므로 보이는 비율을 화면 높이까지만 따진다.
      const fullH = strip ? Math.min(rect.height, innerHeight) : rect.height;
      if (w < 60 || h < 30 || w * h < rect.width * fullH * 0.3) continue;
      // 묶음 조각은 imageStrip이 이미 확인했다.
      if (!strip && img.closest(SKIP_SELECTOR)) continue;
      // 미리 불러 둔 다음 장처럼 투명하게 겹쳐 둔 이미지는 캡처에 그 위 다른 그림이 찍히므로 고르지 않는다.
      if (!strip && !isImageVisible(img)) continue;
      if (!members.every(isImageCaptureReady)) continue;
      const anchor = members[0];
      const key = membersKey(members);
      const existing = imageRecords.get(anchor);
      const offX = clip.x - rect.left;
      const offY = clip.y - rect.top;
      // 같은 이미지·같은 언어로 이미 그렸고, 그때 잘라낸 영역이 지금 보이는 영역을 덮으면 다시 하지 않는다.
      // 번역 서비스를 바꿀 때 남겨 둔(held) 덮개는 새 서비스로 아직 번역하지 않았으므로 그대로인 그림으로 치지 않는다.
      const stable = existing && !existing.held && existing.key === key && existing.offX <= offX + 1 && existing.offY <= offY + 1 &&
          existing.offX + existing.w >= offX + w - 1 && existing.offY + existing.h >= offY + h - 1;
      if (stable && !includeStable) continue;
      list.push({ img: anchor, members, rects, key, rect, clip: { x: clip.x, y: clip.y, w, h }, area: w * h, stable });
    }
    const covered = coveredCandidates(list);
    return list.filter((candidate) => !covered.has(candidate)).sort((a, b) => b.area - a.area).slice(0, MAX_IMAGES);
  }

  /** 지금 화면에 보이는 그림 전체(이미 그린 그림 포함)의 수와, 그중 인식까지 끝난 그림들의 문단 수 합. 아직 인식하지
   *  않은(혹은 다시 해야 할) 그림이 하나라도 있으면 문단 수는 null(확인 중)을 돌려준다 — 모르는 값을 0으로 꾸미지 않는다.
   *  번역 서비스를 바꿔 원문 인식을 재사용할 그림은 이미 인식이 끝난 그림으로 센다. */
  function imageInventory() {
    repositionOverlays();
    const candidates = imageCandidates(true);
    let sentences = 0, pending = false;
    for (const candidate of candidates) {
      const existing = candidate.stable ? imageRecords.get(candidate.img)
        : (state.pageEngineOverride ? reusableRecord(candidate) : null);
      if (existing && Array.isArray(existing.items)) sentences += existing.items.length;
      else pending = true;
    }
    return { images: candidates.length, imageSentences: candidates.length ? (pending ? null : sentences) : 0 };
  }

  // 세로쓰기 대상에 한글(완성형 음절 AC00-D7A3, 자모 1100-11FF/3130-318F)도 포함한다. 한자·가나만 보던
  // 기존 범위로는 한국어 번역문이 세로로 좁고 긴 상자에 들어가도 가로쓰기로만 그려졌다.
  const LETTER_CJK = /[ᄀ-ᇿ㄰-㆏가-힣぀-ヿ㐀-䶿一-鿿豈-﫿]/;

  // 읽을 수 있는 최소 번역 글자 크기(px). 이보다 줄이거나 확대/축소 변환으로 억지로 맞추지 않는다. 그래도 넘치면
  // 배경색 판을 깔아 원래 자리에서 이어지게 둔다(작아서 못 읽는 글자보다 조금 넘치더라도 읽히는 글자가 낫다).
  const READABLE_MIN_FONT = 11;

  /** div 안에 text가 들어가는 가장 큰 글자 크기(minFont~preferredMax)를 찾는다. minFont에서도 넘치면 { size: minFont,
   *  fits: false }를 돌려준다(호출자가 넘침 표시를 정한다). 소수점 치수를 정수로 버리지 않는다(좁은 칸이 0px로 재지지 않게). */
  function fitFontSize(div, text, minFont, preferredMax, vertical) {
    div.style.overflow = "visible";
    div.style.pointerEvents = "none";
    const title = !vertical && div.classList.contains("ctr") && text.style.whiteSpace === "nowrap";
    // 손글씨는 같은 em에서도 실제 획 높이가 고딕보다 작다. 같은 줄 높이를 쓰면 줄/세로 칼럼 사이가 과하게 벌어진다.
    const hand = div.style.fontFamily.includes(FONT_FAMILIES.hand) &&
      !/[぀-ヿ㐀-䶿一-鿿豈-﫿]/.test(text.textContent) &&
      Array.from(document.fonts).some((face) => face.family === FONT_FAMILIES.hand && face.status === "loaded");
    text.style.lineHeight = hand ? "0.9" : title ? "1" : "1.15";
    // 세로 손글씨는 작은 획에도 한 칸 전체를 진행하므로 글자·단어 사이의 빈 칸을 줄인다.
    text.style.letterSpacing = hand && vertical ? "-0.12em" : "normal";
    text.style.wordSpacing = hand && vertical ? "-0.25em" : "normal";
    text.style.transform = "";
    const box = div.getBoundingClientRect();
    // 손글씨의 획과 테두리는 글자 진행 폭 밖으로 돌출하므로 안쪽 안전 여백까지 함께 측정한다.
    const inset = title ? Math.max(1, Math.min(3, preferredMax * 0.04))
      : Math.max(1, Math.min(18, preferredMax * 0.12, Math.min(box.width, box.height) * 0.12));
    text.style.boxSizing = "border-box";
    text.style.padding = `${inset}px`;
    const width = Math.max(1, div.clientWidth), height = Math.max(1, div.clientHeight);
    if (vertical) {
      text.style.height = `${height}px`;
      text.style.width = "auto";
    } else {
      text.style.width = `${width}px`;
      text.style.height = "auto";
    }
    // 가운데 맞춘 긴 제목은 왼쪽으로 넘친 폭이 scrollWidth에 잡히지 않는다.
    // 실제 텍스트 범위도 재서 양쪽 끝과 세로 끝이 배치 칸 안에 들어가는지 확인한다.
    const range = document.createRange();
    range.selectNodeContents(text);
    const fits = () => {
      if (text.scrollWidth > width + 1 || text.scrollHeight > height + 1) return false;
      const ink = range.getBoundingClientRect();
      return ink.left >= box.left + inset - 1 && ink.right <= box.right - inset + 1 &&
        ink.top >= box.top - 1 && ink.bottom <= box.bottom + 1;
    };
    const top = Math.max(minFont, preferredMax);
    div.style.fontSize = `${top}px`;
    if (fits()) return { size: top, fits: true };
    div.style.fontSize = `${minFont}px`;
    if (!fits()) return { size: minFont, fits: false };
    let lo = minFont, hi = top;
    for (let iter = 0; iter < 8 && hi - lo > 0.5; iter += 1) {
      const mid = (lo + hi) / 2;
      div.style.fontSize = `${mid}px`;
      if (fits()) lo = mid; else hi = mid;
    }
    const size = Math.floor(lo * 2) / 2;
    div.style.fontSize = `${size}px`;
    return { size, fits: true };
  }

  /** 네이티브가 보낸 원문 가림 조각(PNG 바이트, data: URL)을 메모리에서 바로 디코딩한다(페이지 CSP·네트워크와 무관). */
  async function decodePatch(m) {
    if (!m || typeof m.d !== "string" || !m.d.startsWith("data:image/png;base64,") ||
        ![m.x, m.y, m.w, m.h].every(Number.isFinite) || m.w <= 0 || m.h <= 0) return null;
    try {
      const binary = atob(m.d.slice("data:image/png;base64,".length));
      const bytes = new Uint8Array(binary.length);
      for (let k = 0; k < binary.length; k += 1) bytes[k] = binary.charCodeAt(k);
      return await createImageBitmap(new Blob([bytes], { type: "image/png" }));
    } catch {
      return null;
    }
  }

  // 번역문에 남은 원문: 일본어가 아닌 대상 언어에서 가나(장음 부호·가운뎃점 제외)는 번역되지 않은 원문이다. 한자를 쓰지
  // 않는 대상 언어에서는 원문의 한자 두 글자 이상이 그대로 옮겨진 것도 남은 원문으로 본다(일부만 번역해 돌려준 경우).
  const KANA_RESIDUE = /[ぁ-ゖゝ-ゟァ-ヺヽ-ヿㇰ-ㇿｦ-ｯｱ-ﾝ]/u;

  function untranslatedResidue(original, translated, target) {
    const text = String(translated || "");
    if (!/^ja/.test(target) && KANA_RESIDUE.test(text)) return true;
    if (/^(ja|zh)/.test(target) || typeof original !== "string" || !original) return false;
    return (text.match(/\p{Script=Han}{2,}/gu) || []).some((run) => original.includes(run));
  }

  /** 번역 실패·원문 그대로이거나 원문이 섞여 돌아온 결과도 원본 이미지 글자를 그대로 노출하지 않는다(번역 확인 필요로 표시). */
  function markUnresolved(items, renderTarget) {
    const sameText = (text) => String(text || "").normalize("NFKC").replace(/\s+/gu, "").toLocaleLowerCase();
    return items.map((item) => {
      const unresolved = !item.t || untranslatedResidue(item.o, item.t, renderTarget) ||
        (/^ko/.test(renderTarget) && item.o && sameText(item.o) === sameText(item.t) &&
        /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]/u.test(item.o));
      return unresolved ? { ...item, t: "번역 확인 필요", unresolved: true } : item;
    });
  }

  /** 번역 서비스를 바꿀 때 남겨 둔(held) 덮개는 새 덮개의 원문 가림이 붙을 때까지 두고(기다리는 동안 원문 글자가 드러나지
   *  않게), 새 덮개를 다 그렸거나 그리기를 그만두면 반드시 지운다. */
  /** 새 덮개를 끝까지 그리지 못했으면(세대·스크롤·글꼴 변경 등으로 그만둠) 덮개를 모두 지우는 경로(overlayEpoch)가 없었고 그 자리가
   *  비어 있을 때만, 같은 그림·같은 자리 조건(heldStillValid)을 지키는 이전 성공 덮개를 되살린다(원문 그림이 다시 드러나지 않게).
   *  끝까지 그린 새 덮개는 이전 덮개 사본(prior, 메모리에만)을 가진다: 이번 동작이 시간 초과로 끝나면 그 사본으로 되돌린다. */
  async function renderImage(candidate, items, langs, refineCandidates, cachedPatches) {
    const previous = imageRecords.get(candidate.img);
    const held = previous && previous.held ? previous : null;
    const heldBox = held ? held.box : null;
    const epoch = overlayEpoch;
    // 같은 그림을 다시 그릴 때(글꼴 변경 등)는 앞 덮개가 가진 이전 성공 사본을 이어받는다.
    const prior = held || (previous && previous.prior) || null;
    try {
      return await drawImage(candidate, items, langs, refineCandidates, cachedPatches, heldBox, prior);
    } finally {
      if (heldBox) heldBox.remove();
      const drawn = imageRecords.get(candidate.img);
      if (held && !drawn && epoch === overlayEpoch && state.view === "translated") restoreHeld(candidate.img, held);
    }
  }

  async function drawImage(candidate, items, langs, refineCandidates, cachedPatches, heldBox, prior = null) {
    const renderTarget = state.pageEngineOverride ? state.pageEngineOverride.target : state.target;
    if (!cachedPatches) items = markUnresolved(items, renderTarget);
    const { img, rect, clip } = candidate;
    const pageGen = state.pageGen, scrollGen = state.scrollGen, fontStyle = state.fontStyle;
    const previous = imageRecords.get(img);
    if (previous && previous.box !== heldBox) previous.box.remove();
    const members = candidate.members || [img];
    // 묶이기 전(어느 조각이 아직 불러오던 때) 조각 하나로 그린 덮개는 이 묶음 덮개와 겹치므로 지운다.
    for (const member of members) {
      const stale = member !== img ? imageRecords.get(member) : null;
      if (stale) { stale.box.remove(); imageRecords.delete(member); }
    }
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
      key: candidate.key, source: sourceKey(members), members, box,
      offX: clip.x - rect.left, offY: clip.y - rect.top, w: clip.w, h: clip.h,
      elemW: rect.width, elemH: rect.height,
      langs: langs && typeof langs === "object" ? langs : undefined,
      items,
      patches: null,
      done: false, // 끝까지 그렸을 때만 true(번역 서비스를 바꿀 때 재사용 후보가 된다)
      // 이 그림에 대신한 이전 성공 덮개(남겨 둔 기록, 메모리에만). 시간 초과 때만 되돌리는 데 쓰고 완료로 확정되면 놓는다.
      prior
    };
    imageRecords.set(img, record);
    const renderCurrent = () => {
      if (stillCurrent(pageGen) && state.scrollGen === scrollGen && state.fontStyle === fontStyle &&
          imageRecords.get(img) === record && candidateUnchanged(candidate)) return true;
      box.remove();
      if (imageRecords.get(img) === record) imageRecords.delete(img);
      return false;
    };

    const MIN_FONT = READABLE_MIN_FONT;
    const MAX_FONT = 240;

    // 원문 가림: 네이티브가 원문 글자(후리가나 포함)를 주변 배경으로 메운 불투명 조각(item.m)을 그 자리에 그린다.
    // 조각 밖 픽셀은 투명이라 원본 그림이 그대로 보인다. 조각이 없거나(응답 크기 상한 등) 디코딩에 실패한 항목만
    // 인식한 문단 배경색(item.bg)으로 글자 상자(item.g)와 함께 지운 상자(item.cv)를 불투명하게 가린다(대체 경로,
    // 그림을 되살린 것처럼 꾸미지 않는 단색 가림). 반투명은 쓰지 않는다(원문이 비치므로).
    // 캔버스는 기기 픽셀 해상도로 만들어 Retina에서 조각 가장자리가 흐려져 원문 테두리가 비치지 않게 한다.
    const dpr = Math.max(1, Math.min(4, Number(window.devicePixelRatio) || 1));
    const maskCanvas = document.createElement("canvas");
    maskCanvas.className = "mask";
    maskCanvas.width = Math.max(1, Math.round(clip.w * dpr));
    maskCanvas.height = Math.max(1, Math.round(clip.h * dpr));
    const maskCtx = maskCanvas.getContext("2d");
    const patches = cachedPatches ||
      (typeof createImageBitmap === "function" ? await Promise.all(items.map((item) => decodePatch(item.m))) : items.map(() => null));
    record.patches = patches;
    if (!renderCurrent()) return;
    const restored = items.map((_, i) => Boolean(maskCtx && patches[i]));
    if (maskCtx) {
      maskCtx.setTransform(dpr, 0, 0, dpr, 0, 0);
      for (let i = 0; i < items.length; i += 1) {
        // 복원 조각의 투명 부분이나 놓친 획에서도 원문이 비치지 않도록 글자 자리를 먼저 가린다.
        // 인식 상자 밖을 짐작으로 넓혀 그림 위에 큰 단색 상자를 덮지 않는다. 놓친 장식 글자는 네이티브가
        // 실제 검출(문서 인식 + 레거시 줄 검출 보충)로 상자를 찾아 보낸다.
        const item = items[i];
        const color = typeof item.bg === "string" && /^#[0-9A-Fa-f]{6}$/.test(item.bg) ? item.bg : "#FFFFFF";
        const glyphs = (Array.isArray(item.g) ? item.g : []).concat(Array.isArray(item.cv) ? item.cv : []);
        const boxes = glyphs.length ? glyphs : [[item.x, item.y, item.w, item.h]];
        const sizes = boxes.map((g) => Math.max(g[2] * clip.w, g[3] * clip.h)).sort((a, b) => a - b);
        // 번짐·압축 잡음까지 가리도록 글자 크기의 8%(최소 1.5px)만큼 넓혀 채운다.
        const pad = Math.max(1.5, (sizes[Math.floor(sizes.length / 2)] || 0) * 0.08);
        maskCtx.fillStyle = color;
        if (restored[i]) continue;
        for (const g of boxes) {
          if (!g.every(Number.isFinite) || g[2] <= 0 || g[3] <= 0) continue;
          maskCtx.fillRect(g[0] * clip.w - pad, g[1] * clip.h - pad, g[2] * clip.w + pad * 2, g[3] * clip.h + pad * 2);
        }
      }
      for (let i = 0; i < items.length; i += 1) {
        if (!restored[i]) continue;
        const m = items[i].m;
        maskCtx.drawImage(patches[i], m.x * clip.w, m.y * clip.h, m.w * clip.w, m.h * clip.h);
      }
      // 원본 img와 같은 표시 경로를 써 브라우저가 캔버스만 어둡게 바꾸는 색 차이를 피한다.
      const maskImage = document.createElement("img");
      maskImage.className = "mask";
      maskImage.alt = "";
      maskImage.src = maskCanvas.toDataURL("image/png");
      let displayMask = maskImage;
      try { await maskImage.decode(); } catch { displayMask = maskCanvas; }
      if (!renderCurrent()) return;
      box.appendChild(displayMask);
      if (heldBox) heldBox.remove();
    }

    // 원본 글자 하나하나의 실제 잉크 상자(item.g, 네이티브가 실제 잉크로 좁힌 상자) 중앙값으로 원본 글자 크기를
    // 잰다(문단 전체 상자보다 훨씬 고르다). 가나·한자는 정사각형에 가까우므로 긴 변을 쓴다(장음 부호 "ー"처럼
    // 납작한 글자도 긴 변은 글자 크기와 같다). 구두점·후리가나 같은 작은 이상치(중앙값의 45% 미만)와 여러 글자가
    // 뭉친 상자(칸 전체에 가까운 크기)는 뺀 뒤 다시 중앙값을 낸다. 글자 상자가 없는 조각만 문단 전체 추정으로 폴백한다.
    // 네이티브가 본문 글자 표시(item.gl: g와 같은 순서, "1"=글자·숫자)를 보냈으면 크기는 그 글자들로만 잰다: 짧은 조각에서
    // 말줄임표·가운뎃점 같은 작은 상자가 큰 글자 하나보다 많아 중앙값을 끌어내리지 않게 한다.
    function bodyGlyphSize(list) {
      const sorted = list.slice().sort((a, b) => a - b);
      // 바로 아래 글자의 두 배를 넘는 맨 큰 상자는 붙어 잡힌 잡음·장식 글자로 보고 뺀다(표본이 셋 이상일 때만).
      while (sorted.length >= 3 && sorted[sorted.length - 1] > sorted[sorted.length - 2] * 2) sorted.pop();
      // 후리가나·작은 가나가 본문보다 많아도 본문 크기가 이기도록 상위 사분위 기준 60% 이상만 남겨 중앙값을 낸다.
      const ref = sorted[Math.floor((sorted.length - 1) * 0.75)];
      const body = sorted.filter((d) => d >= ref * 0.6);
      return body[Math.floor(body.length / 2)];
    }

    function glyphEstimate(item, vertical) {
      if (!Array.isArray(item.g) || !item.g.length) return null;
      const flags = typeof item.gl === "string" && item.gl.length === item.g.length ? item.gl : null;
      // 원문 진행 방향에 수직인치수으로 글자 크기를 잰다. 좁은 장식 가나와 장음 부호도
      // 가로 제목에서는 높이가 본문 크기다. 짧은 변을 쓰면 큰 제목이 절반 이하로 줄었다.
      const cjk = LETTER_CJK.test(item.o || item.t);
      const dims = [], letters = [];
      item.g.forEach((g, index) => {
        const gw = g[2] * clip.w, gh = g[3] * clip.h;
        if (gw <= 0 || gh <= 0) return;
        if (gw >= clip.w * 0.9 || gh >= clip.h * 0.9) return; // 뭉친/전체 칸 상자 제외
        const size = cjk ? (vertical ? gw : gh) : Math.max(gw, gh);
        dims.push(size);
        if (flags && flags[index] === "1") letters.push(size);
      });
      // 본문 글자가 하나뿐이어도(예: "え…") 그 실측 크기를 쓴다.
      if (letters.length) return bodyGlyphSize(letters);
      if (dims.length < 2) return null;
      const sorted = dims.slice().sort((a, b) => a - b);
      const median = sorted[Math.floor(sorted.length / 2)];
      if (median <= 0) return null;
      const filtered = dims.filter((d) => d >= median * 0.45);
      if (!filtered.length) return null;
      filtered.sort((a, b) => a - b);
      return filtered[Math.floor(filtered.length / 2)];
    }

    // 원문 쓰기 방향은 원본 글자가 이어지는 방향(연속한 글자 중심의 이동)으로 정한다. 글자 상자가 2개 미만일 때만
    // 문단 상자 비율로 폴백한다. 여러 줄 세로쓰기의 줄바꿈 점프는 중앙값에서 묻힌다.
    function isVerticalFlow(item, w, h) {
      if (!LETTER_CJK.test(item.o || item.t)) return false;
      if (Array.isArray(item.g) && item.g.length >= 2) {
        const dx = [], dy = [];
        for (let k = 1; k < item.g.length; k += 1) {
          const a = item.g[k - 1], b = item.g[k];
          dx.push(Math.abs((b[0] + b[2] / 2 - a[0] - a[2] / 2) * clip.w));
          dy.push(Math.abs((b[1] + b[3] / 2 - a[1] - a[3] / 2) * clip.h));
        }
        const median = (list) => list.slice().sort((x, y) => x - y)[Math.floor(list.length / 2)];
        const across = median(dx), down = median(dy);
        return down === across ? w > 0 && h / w > 1.6 : down > across;
      }
      return w > 0 && h / w > 1.6;
    }

    // 번역 글자를 세로로 쓸 수 있는 언어(일본어·중국어)만 원문 세로쓰기를 따른다. 한국어 등은 말풍선 안에서 가로로,
    // 가운데 맞춤으로 쓴다(세로 칸 너비에 갇혀 글자가 작아지지 않게). 다만 가로로 쓰면 세로보다 많이 작아지는 좁은 칸만
    // 세로로 둔다(아래 배치에서 실제로 재 고른다).
    const geoms = items.map((item) => {
      const w = item.w * clip.w, h = item.h * clip.h;
      const sourceVertical = isVerticalFlow(item, w, h);
      const glyph = glyphEstimate(item, sourceVertical);
      // estimate는 원본 글자의 잉크 크기(px)다. 폴백(문단 상자)은 글자 칸 크기이므로 잉크 비율(약 0.88)을 곱한다.
      const estimate = glyph != null ? glyph : Math.min(w, h) * 0.968 * 0.88;
      return {
        w, h, sourceVertical, vertical: sourceVertical, estimate, cx: (item.x + item.w / 2) * clip.w,
        left: item.x * clip.w, top: item.y * clip.h, bottom: (item.y + item.h) * clip.h
      };
    });

    // 같은 말풍선의 인접한 세로쓰기 칸들(네이티브가 한 문단으로 합치지 못한 칸)은 글자 크기 추정이 들쭉날쭉할 수 있다.
    // 가까이 붙어 있고 세로로 많이 겹치는(70% 이상) 세로쓰기 칸끼리만 같은 무리로 묶어 최종 크기를 맞춘다.
    const groupOf = geoms.map((_, i) => i);
    const find = (i) => { while (groupOf[i] !== i) i = groupOf[i]; return i; };
    for (let i = 0; i < geoms.length; i += 1) {
      if (!geoms[i].sourceVertical) continue;
      for (let j = i + 1; j < geoms.length; j += 1) {
        if (!geoms[j].sourceVertical) continue;
        const a = geoms[i], b = geoms[j];
        const gap = Math.abs(a.cx - b.cx);
        const closeEnough = gap <= Math.max(a.w, b.w) * 1.5;
        const overlap = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
        const minSpan = Math.min(a.bottom - a.top, b.bottom - b.top);
        const overlapsEnough = minSpan > 0 && overlap / minSpan >= 0.7;
        // 실측 원본 글자 크기가 다른 칸(제목과 부제, 본문과 후리가나)은 같은 무리로 묶지 않는다.
        const similarSize = Math.max(a.estimate, b.estimate) <= Math.min(a.estimate, b.estimate) * 1.3;
        if (closeEnough && overlapsEnough && similarSize) {
          const ra = find(i), rb = find(j);
          if (ra !== rb) groupOf[rb] = ra;
        }
      }
    }
    // 가로쓰기 내레이션도 같은 문단이면(바로 위/아래로 이어지고 왼쪽 시작선이 비슷하면) 같은 무리로 묶는다.
    for (let i = 0; i < geoms.length; i += 1) {
      if (geoms[i].sourceVertical) continue;
      for (let j = i + 1; j < geoms.length; j += 1) {
        if (geoms[j].sourceVertical) continue;
        const a = geoms[i], b = geoms[j];
        const [upper, lower] = a.top <= b.top ? [a, b] : [b, a];
        const gap = lower.top - upper.bottom;
        const heightRatio = lower.h / Math.max(upper.h, 0.0001);
        const alignedLeft = Math.abs(a.left - b.left) < Math.max(a.w, b.w) * 0.12;
        const similarSize = Math.max(a.estimate, b.estimate) <= Math.min(a.estimate, b.estimate) * 1.3;
        // 오른쪽을 맞춘 짧은 부제의 다음 줄도 같은 문단이다. 한 줄/두 줄로 잡힌
        // 상자의 높이 차이 때문에 각 줄을 따로 좁게 축소하지 않도록 한다.
        const overlap = Math.min(a.left + a.w, b.left + b.w) - Math.max(a.left, b.left);
        const alignedRight = Math.abs(a.left + a.w - b.left - b.w) < Math.max(a.w, b.w) * 0.12;
        const rightAlignedBody = alignedRight && overlap >= Math.min(a.w, b.w) * 0.7 &&
          Math.max(a.estimate, b.estimate) < 40 && a.h <= a.estimate * 3 && b.h <= b.estimate * 3;
        const minimumGap = rightAlignedBody ? -Math.min(a.h, b.h) * 0.5 : -upper.h * 0.3;
        if (gap >= minimumGap && gap < upper.h * 0.9 && similarSize &&
            ((heightRatio > 0.65 && heightRatio < 1.5 && alignedLeft) || rightAlignedBody)) {
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
    // 같은 무리는 원본 판정 갈래·굵기도 다수결로 맞춘다. 사용자가 고른 글꼴(수동)은 resolveFontStyle에서 항상 이긴다.
    const groupFs = items.map((item) => item.fs);
    const groupFw = items.map((item) => item.fw === 700);
    byRoot.forEach((idxs) => {
      if (idxs.length < 2) return;
      const sorted = idxs.map((i) => geoms[i].estimate).sort((x, y) => x - y);
      const median = sorted[Math.floor(sorted.length / 2)];
      idxs.forEach((i) => { geoms[i].estimate = median; });
      const votes = new Map();
      idxs.forEach((i) => { if (typeof items[i].fs === "string") votes.set(items[i].fs, (votes.get(items[i].fs) || 0) + 1); });
      let top = null;
      votes.forEach((count, style) => { if (!top || count > votes.get(top)) top = style; });
      const bold = idxs.filter((i) => items[i].fw === 700).length * 2 >= idxs.length;
      idxs.forEach((i) => { if (top) groupFs[i] = top; groupFw[i] = bold; });
    });

    // 여유 공간도 이웃과 함께 배정한다. 각 칸이 독립적으로 넓어지면 이웃 칸을 덮는다. 세로쓰기 원문(말풍선)은 칸 둘레의
    // 말풍선 안쪽 여백(글자 크기의 절반 남짓)까지, 가로쓰기는 오른쪽·아래로 조금 넓힌다.
    const bounds = geoms.map((g) => {
      const room = g.sourceVertical || g.estimate < 40 ? Math.max(MIN_FONT, g.estimate) : 0;
      return g.sourceVertical ? {
        left: Math.max(0, g.left - room * 0.6),
        right: Math.min(clip.w, g.left + g.w + room * 0.4),
        top: Math.max(0, g.top - room * 0.2),
        bottom: Math.min(clip.h, g.bottom + room * 0.6)
      } : {
        left: g.left,
        right: Math.min(clip.w, g.left + g.w + room * 1.2),
        top: g.top,
        bottom: Math.min(clip.h, g.bottom + room * 0.8)
      };
    });
    for (let i = 0; i < bounds.length; i += 1) {
      for (let j = i + 1; j < bounds.length; j += 1) {
        const a = bounds[i], b = bounds[j];
        const left = Math.max(a.left, b.left), right = Math.min(a.right, b.right);
        const top = Math.max(a.top, b.top), bottom = Math.min(a.bottom, b.bottom);
        if (left >= right || top >= bottom) continue;
        const ga = geoms[i], gb = geoms[j];
        // OCR 원래 영역이 중첩되면 번역 위치를 중간선으로 잘라 옮기지 않는다.
        // 서로 떨어진 원문 영역의 추가 여백만 나누어 원래 시작점을 보존한다.
        const originalOverlap = ga.left < gb.left + gb.w && ga.left + ga.w > gb.left &&
            ga.top < gb.bottom && ga.bottom > gb.top;
        const stackedBody = !ga.sourceVertical && !gb.sourceVertical && ga.estimate < 40 && gb.estimate < 40 &&
          Math.min(ga.left + ga.w, gb.left + gb.w) - Math.max(ga.left, gb.left) > Math.min(ga.w, gb.w) * 0.5 &&
          Math.abs(ga.top + ga.h / 2 - gb.top - gb.h / 2) > Math.min(ga.h, gb.h) * 0.3;
        if (originalOverlap && !stackedBody) continue;
        const ay = ga.top + ga.h / 2, by = gb.top + gb.h / 2;
        const separatedX = ga.left + ga.w <= gb.left || gb.left + gb.w <= ga.left;
        const separatedY = ga.bottom <= gb.top || gb.bottom <= ga.top;
        // 길이가 다른 이웃 세로 열은 중심 거리 대신 원문이 실제로 떨어진 방향의 여백만 나눈다.
        if (separatedX && (!separatedY || Math.abs(ga.cx - gb.cx) >= Math.abs(ay - by))) {
          const [before, after, first, second] = ga.cx <= gb.cx ? [a, b, ga, gb] : [b, a, gb, ga];
          const low = Math.max(left, first.left + first.w);
          const high = Math.min(right, second.left);
          if (low > high) continue;
          const split = Math.max(low, Math.min(high, (ga.cx + gb.cx) / 2));
          before.right = split;
          after.left = split;
        } else if (separatedY) {
          const [before, after, first, second] = ay <= by ? [a, b, ga, gb] : [b, a, gb, ga];
          const low = Math.max(top, first.bottom);
          const high = Math.min(bottom, second.top);
          if (low > high) continue;
          const split = Math.max(low, Math.min(high, (ay + by) / 2));
          before.bottom = split;
          after.top = split;
        } else if (stackedBody) {
          const split = Math.max(top, Math.min(bottom, (ay + by) / 2));
          const [before, after] = ay <= by ? [a, b] : [b, a];
          before.bottom = split;
          after.top = split;
        }
      }
    }

    // 실제 쓰일 글꼴을 모두 한 번에(병렬로) 불러온 뒤에 잰다. 항목마다 차례로 기다리지 않는다.
    const styles = items.map((_, i) => resolveFontStyle(groupFs[i]));
    const uniqueStyles = [...new Set(styles)];
    await Promise.all(uniqueStyles.map((style) => loadBundledFont(style)));
    if (!renderCurrent()) return;

    // 같은 무리(같은 말풍선의 이어지는 세로 칸·같은 문단의 가로 줄)는 칸마다 따로 쓰지 않고 읽는 순서대로 이어, 그 칸들의
    // 영역을 합친 한 곳에 한 글자 크기로 쓴다. 칸마다 따로 맞추면 원문보다 긴 번역 조각만 좁은 칸에 갇혀 작아지고 짧은
    // 조각은 커져, 한 말풍선 안에서 크기가 들쭉날쭉하고 한두 낱말짜리 줄이 생겼다. 합친 영역이 무리 밖 다른 칸의 영역을
    // 덮으면 합치지 않는다(다른 말풍선·그림 쪽 글자로 넓히지 않음). 번역 확인 필요 표시가 낀 무리도 합치지 않는다.
    // 번역은 칸마다 따로 한 그대로이고(다른 칸 글자를 섞지 않음), 다듬기도 칸마다 자기 조각만 바꾼다.
    const joiner = /^(ja|zh)/.test(renderTarget) ? "" : " ";
    const overlapArea = (a, b) => Math.max(0, Math.min(a.right, b.right) - Math.max(a.left, b.left)) *
      Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top));
    const units = [];
    const unitOf = new Array(items.length);
    const addUnit = (members, area) => {
      units.push({ members, area: { ...area }, vertical: geoms[members[0]].sourceVertical, parts: [] });
      members.forEach((i) => { unitOf[i] = units.length - 1; });
    };
    byRoot.forEach((idxs) => {
      if (idxs.length >= 2 && idxs.every((i) => !items[i].unresolved)) {
        const vertical = geoms[idxs[0]].sourceVertical;
        // 세로쓰기는 오른쪽 칸부터(같은 칸이면 위부터), 가로쓰기는 위 줄부터(같은 줄이면 왼쪽부터) 읽는다.
        const members = idxs.slice().sort((a, b) => {
          const ga = geoms[a], gb = geoms[b];
          const tolerance = Math.max(ga.estimate, gb.estimate) * 0.5;
          if (vertical) return Math.abs(ga.cx - gb.cx) > tolerance ? gb.cx - ga.cx : ga.top - gb.top;
          return Math.abs(ga.top - gb.top) > tolerance ? ga.top - gb.top : ga.left - gb.left;
        });
        // 떨어진 짧은 가로 줄(메뉴 선택지 등)을 문단으로 합치면 줄간격이 바뀌어 두 번째 줄이 위로 올라간다.
        // 원문 줄 사이에 글자 높이 절반 가까운 빈 공간이 있으면 각 줄의 원래 시작점을 유지한다.
        const detachedRows = !vertical && members.every((j) => typeof items[j].o === "string" &&
          Array.from(items[j].o.replace(/\s/g, "")).length <= 12) && members.slice(1).every((i, k) => {
          const a = geoms[members[k]], b = geoms[i];
          return b.top - a.bottom >= Math.min(a.h, b.h) * 0.45;
        });
        if (detachedRows) { idxs.forEach((i) => addUnit([i], bounds[i])); return; }
        const area = members.reduce((u, i) => ({
          left: Math.min(u.left, bounds[i].left), right: Math.max(u.right, bounds[i].right),
          top: Math.min(u.top, bounds[i].top), bottom: Math.max(u.bottom, bounds[i].bottom)
        }), { ...bounds[members[0]] });
        // 제목의 아래쪽 여백이 문단 맨 위에 조금 닿으면 그 얇은 띠만 제외한다.
        // 각 원문 줄의 중심은 유지하고, 중앙을 가로지르는 다른 글자 영역은 합치지 않는다.
        if (!vertical) {
          const smallest = Math.min(...members.map((i) => geoms[i].estimate));
          const originalTop = area.top;
          for (let j = 0; j < bounds.length; j += 1) {
            if (members.includes(j)) continue;
            const b = bounds[j];
            if (overlapArea(area, b) <= 1 || b.top > area.top || b.bottom <= area.top) continue;
            const nextTop = b.bottom + 1;
            if (nextTop - originalTop > smallest * 0.5) continue;
            const centersInside = members.every((i) => {
              const g = geoms[i];
              return g.cx >= area.left && g.cx <= area.right &&
                g.top + g.h / 2 >= nextTop && g.top + g.h / 2 <= area.bottom;
            });
            if (centersInside && area.bottom - nextTop >= MIN_FONT * 1.15 + 2) area.top = nextTop;
          }
        }
        const intrudes = bounds.some((b, j) => !members.includes(j) &&
          overlapArea(area, b) > 1);
        if (!intrudes) { addUnit(members, area); return; }
      }
      idxs.forEach((i) => addUnit([i], bounds[i]));
    });

    // 원문 가림은 유지하되, 최종 번역 칸끼리는 공간을 나눈다. OCR의
    // 겹친 상자를 앞 단계에서 보존한 경우도 실제 글자가 서로 덮지 않게 한다.
    for (let i = 0; i < units.length; i += 1) {
      for (let j = i + 1; j < units.length; j += 1) {
        const a = units[i].area, b = units[j].area;
        const left = Math.max(a.left, b.left), right = Math.min(a.right, b.right);
        const top = Math.max(a.top, b.top), bottom = Math.min(a.bottom, b.bottom);
        if (right - left <= 1 || bottom - top <= 1) continue;
        const ga = geoms[units[i].members[0]], gb = geoms[units[j].members[0]];
        const ay = ga.top + ga.h / 2, by = gb.top + gb.h / 2;
        // 거의 동일한 OCR 상자는 위치만으로 읽기 순서를 추정하지 않는다.
        if (Math.abs(ga.cx - gb.cx) < 1 && Math.abs(ay - by) < 1) continue;
        const neighboringVerticalColumns = ga.sourceVertical && gb.sourceVertical &&
          Math.abs(ga.cx - gb.cx) >= Math.min(ga.w, gb.w) * 0.5;
        const stackedHorizontalRows = !ga.sourceVertical && !gb.sourceVertical &&
          Math.min(ga.left + ga.w, gb.left + gb.w) - Math.max(ga.left, gb.left) >= Math.min(ga.w, gb.w) * 0.5 &&
          Math.abs(ay - by) >= Math.min(ga.h, gb.h) * 0.5;
        const sideBySide = neighboringVerticalColumns ||
          (!stackedHorizontalRows && Math.abs(ga.cx - gb.cx) >= Math.abs(ay - by));
        const nextA = { ...a }, nextB = { ...b };
        if (sideBySide) {
          const split = Math.max(left, Math.min(right, (ga.cx + gb.cx) / 2));
          const [before, after] = ga.cx <= gb.cx ? [nextA, nextB] : [nextB, nextA];
          before.right = split;
          after.left = split;
        } else {
          const split = Math.max(top, Math.min(bottom, (ay + by) / 2));
          const [before, after] = ay <= by ? [nextA, nextB] : [nextB, nextA];
          before.bottom = split;
          after.top = split;
        }
        // 합친 문단의 첫 줄만 보고 자르면 다른 원문 줄의 자리를 잃는다. 모든 원문 중심을 유지할 때만 여백을 나눈다.
        const keepsAnchors = (unit, area) => unit.members.every((m) => {
          const g = geoms[m], y = g.top + g.h / 2;
          const keepsVerticalExtent = !g.sourceVertical ||
            (g.top >= area.top && g.bottom <= area.bottom);
          const keepsHorizontalExtent = g.sourceVertical ||
            (g.left >= area.left && g.left + g.w <= area.right);
          return keepsVerticalExtent && keepsHorizontalExtent &&
            g.cx >= area.left && g.cx <= area.right && y >= area.top && y <= area.bottom;
        });
        if (keepsAnchors(units[i], nextA) && keepsAnchors(units[j], nextB)) {
          Object.assign(a, nextA);
          Object.assign(b, nextB);
        }
      }
    }

    const place = (div, area) => {
      div.style.left = `${area.left}px`;
      div.style.top = `${area.top}px`;
      div.style.width = `${Math.max(0, area.right - area.left)}px`;
      div.style.height = `${Math.max(0, area.bottom - area.top)}px`;
    };
    // 번역 언어·문장 길이와 관계없이 원문 쓰기 방향을 유지한다. 세로 원문은 세로로, 가로 원문은 가로로 크기와 줄바꿈만 맞춘다.
    const setOrientation = (div, vertical, centered) => {
      div.classList.toggle("vert", vertical);
      div.classList.toggle("ctr", centered);
      div.style.writingMode = vertical ? "vertical-rl" : "";
      div.style.textOrientation = vertical ? "upright" : "";
    };

    // 번역 글자는 투명 배경으로 원문 위치에서 시작한다.
    for (const unit of units) {
      const lead = unit.members[0];
      const item = items[lead];
      const div = document.createElement("div");
      div.className = "t";
      place(div, unit.area);
      div.style.color = contrastColor(item.bg);
      // 캔버스 2D 컨텍스트를 못 만든 드문 경우에만 마지막 안전망으로 글자 영역 전체를 배경색으로 불투명하게 덮는다.
      if (!maskCtx) div.style.background = typeof item.bg === "string" && /^#[0-9A-Fa-f]{6}$/.test(item.bg) ? item.bg : "#FFFFFF";
      // 원본이 굵은 글씨면 굵게(번들 글꼴은 Regular뿐이라 브라우저 합성 굵기). 테두리는 크기를 맞춘 뒤 아래에서 준다.
      if (groupFw[lead]) div.style.fontWeight = "700";
      const fontStyle = styles[lead];
      div.style.fontFamily = fontFamilyFor(fontStyle);
      // 글자는 안쪽 .tt에 넣는다: 이 요소의 scrollWidth/scrollHeight로 넘침을 재야 바깥 .t(overflow:hidden)의
      // 뒤틀린 값 대신 실제 필요한 크기를 알 수 있다(fitFontSize 참고). 합친 무리는 칸마다 안쪽 조각(span)을 따로 둬
      // 다듬기가 자기 칸 글자만 바꾸게 한다.
      const text = document.createElement("span");
      text.className = "tt";
      // 실패한 항목은 원문 자리에 글자를 그리지 않는다(원문 가림만 유지). 상자를 가득 채우는 거대한 안내문
      // 대신 그림마다 작은 알림 하나(.fail)로 충분히 알린다. 원문은 노출하지 않는다.
      if (!item.unresolved) {
        if (unit.members.length === 1) {
          text.textContent = item.t;
          unit.parts.push(text);
        } else {
          unit.members.forEach((i, k) => {
            if (k) text.appendChild(document.createTextNode(joiner));
            const part = document.createElement("span");
            part.textContent = items[i].t;
            text.appendChild(part);
            unit.parts.push(part);
          });
        }
      }
      div.appendChild(text);
      box.appendChild(div);
      unit.div = div;
      unit.text = text;
      if (item.unresolved) {
        setOrientation(div, unit.vertical, false);
        unit.estimate = geoms[lead].estimate;
        unit.minFont = MIN_FONT;
        unit.preferredMax = MIN_FONT;
        unit.fitted = { size: MIN_FONT, fits: true };
        continue;
      }
      unit.members.forEach((i, k) => {
        const member = items[i];
        if (refineCandidates && !member.unresolved && typeof member.o === "string" && member.o &&
            member.o.length <= REFINE_ITEM_CHARS && member.t.length <= REFINE_ITEM_CHARS) {
          refineCandidates.push({ el: unit.parts[k], original: member.o, draft: member.t, items, index: i, img: candidate.img,
            group: byRoot.get(find(i)) || [i], sourceSize: geoms[i].estimate });
        }
      });

      // 원본에서 잰 글자 크기를 상한으로 쓴다. 글꼴 잉크 비율로 나누거나 손글씨 최소 크기를 확대하면
      // 원본보다 큰 글자가 나와 좁은 칸을 넘쳤다. 공간이 부족하면 이 상한에서 더 줄인다.
      const { estimate } = geoms[lead];
      const sourcePx = Math.max(1, estimate);
      const scaledMin = Math.min(MIN_FONT, Math.max(1, Math.floor(sourcePx)));
      unit.estimate = estimate;
      unit.minFont = scaledMin;
      unit.preferredMax = Math.min(MAX_FONT, Math.max(scaledMin, Math.round(sourcePx)));
      // 짧고 큰 가로 제목은 원문 영역의 가운데에 둔다. 본문·세로쓰기는 원래 시작점을 유지한다.
      const title = !unit.vertical && estimate >= 40 && text.textContent.length <= 30 &&
        (unit.area.right - unit.area.left) >= (unit.area.bottom - unit.area.top) * 1.6;
      unit.title = title;
      // 원문이 한 줄인 좁은 세로 말풍선은 번역도 한 줄로 맞춘다. 여러 줄을
      // 허용하면 크기 맞춤이 왼쪽 새 칸으로 넘겨 말풍선 테두리 밖에 글자를 놓는다.
      const verticalXs = (item.g || []).filter((_, i) => !item.gl || item.gl[i] === "1")
        .map((g) => (g[0] + g[2] / 2) * clip.w);
      const singleVerticalColumn = unit.vertical && unit.members.length === 1 && geoms[lead].w <= estimate * 1.8 &&
        verticalXs.length > 0 && Math.max(...verticalXs) - Math.min(...verticalXs) <= estimate * 0.65;
      unit.singleVerticalColumn = singleVerticalColumn;
      text.style.whiteSpace = title || singleVerticalColumn ? "nowrap" : "normal";
      setOrientation(div, unit.vertical, title);
      unit.fitted = fitFontSize(div, text, unit.minFont, unit.preferredMax, unit.vertical);
      // 디버그용(제품 UI 아님): 원본 판정 갈래·최종 갈래·원본 글자 잉크 크기·목표 크기·원문 가림 방식·합친 칸 수
      div.dataset.fs = typeof item.fs === "string" ? item.fs : "";
      div.dataset.style = fontStyle;
      div.dataset.srcInk = String(Math.round(estimate));
      div.dataset.srcPx = String(Math.round(sourcePx));
      div.dataset.restored = unit.members.every((i) => restored[i]) ? "1" : "f";
      if (unit.members.length > 1) div.dataset.members = String(unit.members.length);
      const uncovered = unit.members.reduce((sum, i) => sum + (Number.isInteger(items[i].uc) && items[i].uc > 0 ? items[i].uc : 0), 0);
      if (uncovered > 0) div.dataset.uncovered = String(uncovered);
    }

    // 실패한 항목이 있으면 그림마다 작은 알림 하나만 덧붙인다(항목마다 거대한 글자를 반복해 그리지 않음).
    if (items.some((it) => it.unresolved)) {
      const fail = document.createElement("div");
      fail.className = "fail";
      fail.textContent = "번역 확인 필요";
      box.appendChild(fail);
    }

    // 번역문이 원문보다 길어 원래 글자 크기의 75%보다 작게 들어간 영역만, 읽는 방향으로 이어지는 빈자리까지 조금 넓혀
    // 다시 맞춘다. 다른 영역(다른 칸·다른 말풍선의 글자 자리)에는 들어가지 않는다. 말풍선 테두리를 픽셀로 알 수 없으므로
    // 세로쓰기는 원래 높이 그대로 왼쪽(다음 줄)으로 원래 글자 두 줄까지, 가로쓰기는 오른쪽으로 영역 너비의 50%·
    // 아래로 원래 글자 두 줄까지만 넓힌다. 넓혀도 커지지 않으면 원래 영역으로 되돌린다.
    units.forEach((unit, u) => {
      if (unit.title || (unit.fitted.fits && unit.fitted.size >= unit.preferredMax * 0.75)) return;
      const a = unit.area;
      const others = units.filter((_, v) => v !== u).map((other) => other.area);
      const lines = Math.max(MIN_FONT, unit.estimate) * 1.2 * 2;
      const growBottom = (r, limit) => others.reduce((edge, o) =>
        (o.left < r.right && o.right > r.left && o.bottom > r.bottom ? Math.min(edge, Math.max(r.bottom, o.top)) : edge), limit);
      const growLeft = (r, limit) => others.reduce((edge, o) =>
        (o.top < r.bottom && o.bottom > r.top && o.left < r.left ? Math.max(edge, Math.min(r.left, o.right)) : edge), limit);
      const growRight = (r, limit) => others.reduce((edge, o) =>
        (o.top < r.bottom && o.bottom > r.top && o.right > r.right ? Math.min(edge, Math.max(r.right, o.left)) : edge), limit);
      const next = { ...a };
      if (unit.vertical) {
        // 세로쓰기는 원래 높이를 지킨다(아래로 늘리면 말풍선 밖으로 나간다). 다음 줄 방향(왼쪽)으로만 두 줄까지 넓힌다.
        next.left = growLeft(next, Math.max(0, a.left - lines));
      } else {
        next.right = growRight(next, Math.min(clip.w, a.right + (a.right - a.left) * 0.5));
        next.bottom = growBottom(next, Math.min(clip.h, a.bottom + lines));
      }
      if (next.bottom - a.bottom < 1 && a.left - next.left < 1 && next.right - a.right < 1) return;
      place(unit.div, next);
      const result = fitFontSize(unit.div, unit.text, unit.minFont, unit.preferredMax, unit.vertical);
      if (result.size > unit.fitted.size || (result.fits && !unit.fitted.fits)) {
        unit.area = next;
        unit.fitted = result;
        unit.div.dataset.grown = "1";
      } else {
        place(unit.div, a);
        unit.fitted = fitFontSize(unit.div, unit.text, unit.minFont, unit.preferredMax, unit.vertical);
      }
    });

    // 한 줄 제목·세로 대사의 번역이 길면 방향과 영역을 유지한 채 줄바꿈을 허용한다.
    // 최소 글씨에서도 실패한 nowrap를 계속 유지하면 끝부분을 숨기게 된다.
    for (const unit of units) {
      if (!unit.fitted.fits && unit.text.style.whiteSpace === "nowrap") {
        unit.text.style.whiteSpace = "normal";
        unit.fitted = fitFontSize(unit.div, unit.text, unit.minFont, unit.preferredMax, unit.vertical);
      }
    }

    // 합치지 못한 무리(다른 칸 영역과 겹치거나 번역 확인 필요가 낀 무리)는 기존처럼 칸마다 맞춘 크기의 중앙값을 넘지 않게
    // 맞춘다. 가장 작은 칸 하나가 문단 전체를 끌어내리지 않으며, 중앙값보다 작게 들어간 칸은 자기 크기를 그대로 둔다.
    byRoot.forEach((idxs) => {
      const ids = [...new Set(idxs.map((i) => unitOf[i]))];
      if (ids.length < 2) return;
      const sorted = ids.map((u) => units[u].fitted.size).sort((a, b) => a - b);
      const median = sorted[Math.floor(sorted.length / 2)];
      ids.forEach((u) => {
        const unit = units[u];
        if (unit.fitted.size <= median) return;
        unit.fitted = fitFontSize(unit.div, unit.text, Math.min(unit.minFont, median), median, unit.vertical);
      });
    });

    // 테두리: 복원 배경 안에서도 대비가 유지되도록 글자색 반대의 얇은 테두리를 준다. 바깥에만 그려 획이 가늘어지지
    // 않는다. 읽을 수 있는 최소 크기에서도 넘친 항목은 넘친 부분이 그림 위에서도 읽히도록 인식한 배경색 판을 깐다.
    for (const unit of units) {
      const item = items[unit.members[0]];
      const { div, text, fitted } = unit;
      const stroke = div.style.color === "rgb(255, 255, 255)" || div.style.color === "white" || div.style.color === "#FFFFFF" ? "#303030" : "#FFFFFF";
      if (stroke) {
        const inset = parseFloat(text.style.padding) || 1;
        const r = Math.min(inset / 3, Math.max(1, Math.min(1.5, fitted.size * 0.025)));
        const offsets = [[r, 0], [-r, 0], [0, r], [0, -r], [r, r], [-r, -r], [r, -r], [-r, r]];
        text.style.textShadow = offsets.map(([x, y]) => `${x}px ${y}px 0 ${stroke}`).join(",") + `,0 0 ${r * 2}px ${stroke}`;
      }
      if (!fitted.fits) {
        const plate = typeof item.bg === "string" && /^#[0-9A-Fa-f]{6}$/.test(item.bg) ? item.bg : "#FFFFFF";
        text.style.background = plate;
        text.style.borderRadius = "3px";
        text.style.boxDecorationBreak = "clone";
        text.style.webkitBoxDecorationBreak = "clone";
        div.dataset.overflow = "1";
      }
      // 한 열 세로글은 추가 여백의 중앙이 아니라 원문 열의 중심에 둔다.
      // 실제 글자 폭까지 확인해 칸 밖으로 나갈 이동은 허용하지 않는다.
      if (unit.singleVerticalColumn && text.style.whiteSpace === "nowrap" && fitted.fits) {
        const frame = div.getBoundingClientRect(), ink = text.getBoundingClientRect();
        const desired = frame.left + geoms[unit.members[0]].cx - unit.area.left;
        const low = frame.left + ink.width / 2, high = frame.right - ink.width / 2;
        if (low <= high) {
          const center = Math.max(low, Math.min(high, desired));
          text.style.transform = `translateX(${center - ink.left - ink.width / 2}px)`;
        }
      }
      div.style.overflow = "hidden"; // 최종 맞춤 뒤 글자·외곽선이 이웃 칸을 덮지 않게 한다.
      div.dataset.px = String(fitted.size);
      div.dataset.fw = groupFw[unit.members[0]] ? "700" : "400";
      div.dataset.vertical = unit.vertical ? "1" : "0";
    }

    if (renderCurrent()) record.done = true;
  }

  /** 이미 그려진 이미지 덮개를 재캡처·재번역 없이 다시 그린다(글자색·원문 가림 조각·자리는 그대로, 조각은 다시
   *  디코딩하지 않는다). imgs를 주면 그 이미지들만, 없으면 전부. */
  function rerenderImageRecords(imgs) {
    for (const [img, record] of Array.from(imageRecords.entries())) {
      if (imgs && !imgs.has(img)) continue;
      // 남겨 둔(held) 덮개는 새 서비스 번역으로 다시 그릴 때 지금 글꼴을 쓴다(이전 서비스 번역으로 다시 그리지 않는다).
      if (record.held || !img.isConnected || !Array.isArray(record.items)) continue;
      const geometry = recordGeometry(img, record);
      if (!geometry) continue;
      const { rect, rects } = geometry;
      const candidate = {
        img, members: record.members, rects, rect, key: record.key,
        clip: { x: rect.left + record.offX, y: rect.top + record.offY, w: record.w, h: record.h }
      };
      renderImage(candidate, record.items, record.langs, null, record.patches || undefined).catch(() => {});
    }
  }

  /** 글꼴 설정이 바뀌었을 때 이미 그려진 이미지 덮개를 모두 다시 그린다. */
  function rerenderImageFonts() {
    rerenderImageRecords(null);
  }

  /** 이미지 위 OCR 번역 글자 중 일부만 다듬어 같은 칸의 텍스트만 바꾼다(글꼴·위치·마스킹은 그대로).
   *  실패·거부·취소는 조용히 무시하고 기존 번역 글자를 그대로 둔다. */
  async function refineImageCandidates(candidates, pageGen, scrollGen, supplied = null) {
    const items = withRefineContext(candidates.map((c, index) => ({ k: `i${index}`, o: c.original, d: c.draft })),
      candidates.map(imageRefineContext));
    let response;
    try {
      response = await (supplied || send({ cmd: "refine", target: state.target, engine: state.engine, items }));
    } catch {
      return;
    }
    if (!stillCurrent(pageGen) || state.scrollGen !== scrollGen || isExternal()) return;
    const changed = new Set();
    for (const item of response.items || []) {
      const index = Number(String(item.k).slice(1));
      const candidate = candidates[index];
      if (!candidate || `i${index}` !== item.k || !candidate.el.isConnected) continue;
      if (candidate.el.textContent !== candidate.draft) continue; // 그사이 다시 그려졌으면 건드리지 않는다
      const refined = item.t.trim();
      // 다듬기가 원문을 되살려 돌려주면(가나·원문 한자 잔여) 초안을 그대로 둔다.
      if (!refined || untranslatedResidue(candidate.original, refined, state.target)) continue;
      candidate.el.textContent = refined;
      if (candidate.img) changed.add(candidate.img);
      // 캐시(record.items)도 같은 참조를 공유하므로 여기서 갱신해야, 글꼴만 바꿔 재캡처 없이 다시 그릴 때
      // (rerenderImageFonts) 다듬기 전 초안으로 되돌아가지 않는다.
      if (candidate.items && candidate.items[candidate.index]) candidate.items[candidate.index].t = refined;
    }
    // 다듬은 글자가 바뀐 이미지만 크기를 다시 맞춘다(다른 이미지·원문 가림 조각은 다시 그리지 않는다).
    if (changed.size) rerenderImageRecords(changed);
  }

  // 같은 번역 패스의 이미지와 일반 글자를 함께 보내 세션 준비·추론을 두 번 기다리지 않는다.
  // 기존 항목/글자 상한을 유지하고, 각 결과의 세대·노드·스크롤 검증은 원래 적용 함수가 맡는다.
  async function refinePageCandidates(image, text, pageGen) {
    // 이름도 함께 넘겨 네이티브의 다른 항목 이름 혼입 검사를 유지한다(이름 자체는 추론에서 제외됨).
    const images = image?.candidates || [];
    const texts = text || [];
    const items = withRefineContext([
      ...images.map((c, i) => ({ k: `i${i}`, o: c.original, d: c.draft })),
      ...texts.map((c, i) => ({ k: `r${i}`, o: c.original, d: c.draft })),
    ], [...images.map(imageRefineContext), ...texts.map((c) => textRefineContext(c.node, c.original))]);
    if (!items.length || !stillCurrent(pageGen) || isExternal()) return;
    const batches = [];
    let batch = [], chars = 0;
    for (const item of items) {
      const size = item.o.length + item.d.length;
      if (batch.length && (batch.length >= MAX_REFINE_ITEMS * 2 || chars + size > REFINE_TOTAL_CHARS)) {
        batches.push(batch); batch = []; chars = 0;
      }
      batch.push(item); chars += size;
    }
    if (batch.length) batches.push(batch);
    beginRefine(pageGen, items.length);
    try {
      const response = Promise.all(batches.map((part) =>
        send({ cmd: "refine", target: state.target, engine: state.engine, items: part }).catch(() => ({ items: [] }))
      )).then((results) => ({ items: results.flatMap((r) => r.items || []) }));
      await Promise.all([
        refineImageCandidates(images, pageGen, image?.scrollGen, response),
        refineTextCandidates(texts, pageGen, response),
      ]);
    } finally { endRefine(pageGen, items.length); }
  }

  // 이미지 속 단어 하나가 그 이미지의 대체 텍스트(alt)에 있거나, 이미지를 담은 작은 카드의 원문 설명에서 버전이 붙은
  // 모델명 바로 뒤 이름(예: "GPT-6 Luna"의 "Luna")으로 나오면 제품·모델 이름이므로 번역 덮개를 그리지 않는다(원본 그림
  // 글자 유지). 카드 설명은 이미 번역됐을 수 있어 기록해 둔 원문으로 본다. 근거가 없는 단어는 그대로 번역한다.
  /** 이미지를 담은 작은 카드(조상 4단계 안, 글자 600자 이하)의 원문 글자. */
  function imageCardText(img) {
    let card = "";
    for (let el = img.parentElement, depth = 0; el && el !== document.body && depth < 4; el = el.parentElement, depth += 1) {
      if (el.textContent.length > 600) break;
      card = originalTextOf(el, 600, " ");
    }
    return card;
  }

  /** 이미지 속 글자 한 칸의 다듬기 문맥(원문): 대체 텍스트 → 카드 설명 → 같은 무리(같은 말풍선의 이어지는 칸·같은
   *  문단의 줄) 다른 칸 인식 원문. 같은 그림의 다른 말풍선·다른 칸 글자는 넣지 않는다(모델이 끌어와 이어 붙인다). */
  function imageRefineContext(candidate) {
    try {
      const img = candidate.img;
      const parts = [];
      // 제목은 로컬 다듬기의 참고 데이터다. 그림의 잘못 인식된 고유명사를 판단할 단서를 준다.
      const pageTitle = String(document.title || "").trim().slice(0, REFINE_CONTEXT_PART);
      const own = candidate.items && candidate.items[candidate.index];
      if (pageTitle && own && own.w > 0.2 && own.h > 0.06) parts.push(pageTitle);
      const alt = img ? `${img.alt || ""} ${img.getAttribute("aria-label") || ""}`.trim() : "";
      if (alt) parts.push(alt.slice(0, REFINE_CONTEXT_PART));
      const card = img && img.isConnected ? imageCardText(img) : "";
      if (card) parts.push(card.slice(0, REFINE_CONTEXT_PART));
      const items = candidate.items || [];
      const others = (candidate.group || []).filter((index) => index !== candidate.index && items[index] &&
        typeof items[index].o === "string").map((index) => items[index].o.trim()).filter(Boolean).join(" ");
      if (others) parts.push(others.slice(0, REFINE_CONTEXT_PART));
      return parts.join(" | ").slice(0, REFINE_CONTEXT_CHARS);
    } catch {
      return "";
    }
  }

  function withoutImageNames(img, items) {
    if (!Array.isArray(items) || !items.length) return items;
    const alt = `${img.alt || ""} ${img.getAttribute("aria-label") || ""}`;
    const card = imageCardText(img);
    const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    return items.filter((item) => {
      const word = typeof item.o === "string" ? item.o.trim() : "";
      if (!/^[A-Za-z][A-Za-z0-9.+\-]{1,23}$/.test(word)) return true;
      const w = escape(word);
      if (new RegExp(`(^|[^\\p{L}\\p{N}])${w}($|[^\\p{L}\\p{N}])`, "u").test(alt)) return false;
      return !new RegExp(`(^|\\s)\\S*\\d\\S*\\s+${w}($|[^\\p{L}\\p{N}])`, "u").test(card);
    });
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
    // 조각 묶음은 모든 조각이 그대로여야 한다(조각 하나만 바뀌거나 옮겨져도 찍힌 그림과 맞지 않는다).
    const members = candidate.members || [candidate.img];
    const rects = candidate.rects || [candidate.rect];
    if (candidate.key !== membersKey(members)) return false;
    return members.every((img, index) => {
      if (!img.isConnected || !img.complete) return false;
      // 백그라운드 캡처 빈도 제한으로 기다리는 사이 보이지 않게 된(투명해지거나 숨겨진) 그림은 캡처에 찍히지 않는다.
      if (!isImageVisible(img)) return false;
      const now = img.getBoundingClientRect();
      const then = rects[index];
      return Math.abs(now.left - then.left) <= 1 && Math.abs(now.top - then.top) <= 1 &&
        Math.abs(now.width - then.width) <= 1 && Math.abs(now.height - then.height) <= 1;
    });
  }

  /** 번역 서비스를 바꾼 뒤 같은 그림(reusableRecord)의 인식 원문만 새 서비스로 번역해, 위치·쓰기 방향·글꼴 판정·원문 가림
   *  조각은 그대로 두고 번역문(t)만 바꿔 다시 그린다(재캡처·재인식·배경 분석 없음). 보내는 원문은 지난번 실제로 그린 항목의
   *  인식 원문뿐이며(이전 번역문은 보내지 않는다), 일반 글자와 같은 1회성 전송 경로(translatePageExternal: 동의·엔진·토큰·
   *  문서 확인과 시간 한도)를 쓴다. 기다리는 사이 이동·스크롤·서비스 변경이 있었으면 그리지 않고 false를 돌려준다. */
  async function translateHeldImages(reuse, pass) {
    const { pageGen, scrollGen, sx, sy, override, action, inventory, imageTiming, shared } = pass;
    const current = () => stillCurrent(pageGen) && state.scrollGen === scrollGen && scrollX === sx && scrollY === sy &&
      state.pageEngineOverride === override;
    const translations = new Map(); // 인식 원문 → 번역문|null(실패)
    const queued = new Set();
    // 일반 글자 요청에 합쳐 이미 받은 결과(실패 포함)를 먼저 쓴다. 같은 패스에서 같은 원문을 다시 보내지 않는다(재시도 없음).
    const merged = shared && shared.override === override ? shared.held : null;
    let mergedCount = 0;
    for (const { record } of reuse) {
      for (const item of record.items) {
        if (translations.has(item.o) || queued.has(item.o)) continue;
        if (merged && merged.has(item.o)) {
          translations.set(item.o, merged.get(item.o));
          mergedCount += 1;
          continue;
        }
        const cached = cacheGet(item.o);
        if (cached !== undefined) translations.set(item.o, cached);
        else queued.add(item.o);
      }
    }
    const texts = [...queued];
    // images: 재사용한 그림 수(캡처·인식하지 않음), merged: 일반 글자 요청에 합쳐 받은 원문 수, texts: 여기서 따로 보낸 원문 수,
    // roundtrip: 따로 보낸 요청의 왕복 시간(합친 요청의 시간은 timing.text에 있다).
    const reuseTiming = { images: reuse.length, merged: mergedCount, texts: texts.length, roundtrip: 0 };
    imageTiming.reuse = reuseTiming;
    try {
      if (texts.length) {
        markStage(action, "external");
        // 외부로 보낸 양은 이 요청까지 합친 실제 값으로 센다.
        const chars = texts.reduce((sum, text) => sum + text.length, 0);
        const sendInfo = inventory && state.inventory === inventory ? inventory.send : null;
        updateInventory(inventory, {
          phase: "external",
          send: sendInfo ? { ...sendInfo, texts: sendInfo.texts + texts.length, chars: sendInfo.chars + chars }
            : { texts: texts.length, chars, sentTexts: 0, sentChars: 0, batch: 0, batchTexts: 0, batchChars: 0 }
        });
      }
      let start = 0;
      while (start < texts.length) {
        const { batch, chars, next } = nextBatch(texts, start, externalBatchTexts(override.engine), EXTERNAL_BATCH_CHARS);
        start = next;
        if (!current()) return false;
        const sendInfo = inventory && state.inventory === inventory ? inventory.send : null;
        if (sendInfo) Object.assign(sendInfo, { batch: sendInfo.batch + 1, batchTexts: batch.length, batchChars: chars });
        const sentAt = performance.now();
        const response = await send({ cmd: "translatePageExternal", engine: override.engine, target: override.target, texts: batch,
                                      token: override.token, ...(action ? { action: action.id } : {}) });
        reuseTiming.roundtrip += Math.round(performance.now() - sentAt);
        if (sendInfo) Object.assign(sendInfo, { sentTexts: sendInfo.sentTexts + batch.length, sentChars: sendInfo.sentChars + chars });
        if (!current()) return false;
        if (response.warning) state.warning = response.warning;
        // 돌려받은 번역은 보낸 순서 그대로 그 원문에만 붙인다. 실패(null)·빈 값은 캐시에 남기지 않는다.
        response.texts.forEach((value, index) => {
          const ok = imageTranslation(value);
          if (ok !== null) cachePut(batch[index], ok);
          translations.set(batch[index], ok);
        });
      }
    } catch (error) {
      if (error.code === "cancelled" || error.code === "stale" || error.code === "contextinvalid") throw error;
      // 새 서비스 번역을 받지 못한 그림은 원문으로 되돌리지 않는다. 남겨 둔(held) 이전 성공 덮개는 그대로 두고 runPass가 실패로
      // 끝내며 유효한 것만 남긴다(지금 번역으로 세지 않고, 완료로 표시하지 않는다).
      error.imageReuse = true;
      throw error;
    }
    if (!current()) return false;
    markStage(action, "render");
    const renderAt = performance.now();
    for (const { candidate, record } of reuse) {
      if (pageGen !== state.pageGen || scrollGen !== state.scrollGen || state.pageEngineOverride !== override) return false;
      // 기다리는 사이 그림·자리·기록이 바뀌었으면 그리지 않는다(남은 덮개는 패스 끝에서 지우고 다음 패스가 다시 인식한다).
      if (imageRecords.get(candidate.img) !== record || reusableRecord(candidate) !== record || !candidateUnchanged(candidate)) continue;
      const geometry = recordGeometry(candidate.img, record);
      if (!geometry) continue;
      const { rect, rects } = geometry;
      // 번역문(t)만 바꾸고 위치·글자 상자·쓰기 방향·글꼴 판정·원문 가림 정보는 그대로 둔다. 이전 실패 표시는 새 번역으로 다시 판정한다.
      const items = markUnresolved(record.items.map(({ unresolved, ...item }) => ({ ...item, t: translations.get(item.o) || "" })),
        override.target);
      await renderImage({ img: candidate.img, members: record.members, rects, rect, key: candidate.key,
                          clip: { x: rect.left + record.offX, y: rect.top + record.offY, w: record.w, h: record.h } },
        items, record.langs, null, record.patches);
    }
    imageTiming.render = Math.round(performance.now() - renderAt);
    return true;
  }

  async function imagePass(pageGen, shared = null) {
    repositionOverlays();
    if (!state.images) dropHeldImages(false);
    if (!state.images || document.visibilityState !== "visible") return;
    const action = state.passAction && state.passAction.gen === pageGen ? state.passAction : null;
    markStage(action, "capture");
    // 고르기 전에 화면 전환이 끝나기를 기다린다(끝난 뒤 자리에서 골라야 캡처와 맞는다).
    await imageAnimationsDone();
    if (!stillCurrent(pageGen) || document.visibilityState !== "visible") return;
    repositionOverlays();
    let candidates = imageCandidates();
    const inventory = inventoryOf(pageGen);
    // 이미지 수는 화면에 보이는 그림 전체(이미 그려 둔 그림 포함)로 센다. 새로 인식할 그림이 없으면(캐시만으로 끝난
    // 패스) 이미 아는 문단 수를 그대로 두고, 있으면 그 수가 끝날 때까지 null(확인 중)로 둔다.
    const known = imageInventory();
    updateInventory(inventory, { images: known.images, imageSentences: known.imageSentences });
    if (!candidates.length) {
      dropHeldImages(true);
      return;
    }
    const scrollGen = state.scrollGen;
    const sx = scrollX;
    const sy = scrollY;
    const viewport = { w: innerWidth, h: innerHeight };
    const override = state.pageEngineOverride;
    const target = override ? override.target : state.target;
    const engine = override ? override.engine : state.engine;
    // 번역 서비스만 바꾼 같은 그림은 원문 인식·복원 조각을 재사용한다(캡처·인식 대상에서 뺀다).
    const reuse = [];
    if (override) {
      candidates = candidates.filter((candidate) => {
        const record = reusableRecord(candidate);
        if (record) reuse.push({ candidate, record });
        return !record;
      });
    }

    ocrInFlight = true;
    // 단계별 걸린 시간(ms, 숫자만). capture: 캡처 요청, ocrRoundtrip: 인식·번역 요청 왕복, native: Mac 쪽 단계별, render: 그리기.
    const imageTiming = { capture: null, ocrRoundtrip: null, native: null, render: null };
    state.timing.image = imageTiming;
    // 새로 인식할 그림이 있다: 이 패스의 동작을 보여 줄 동작으로 정한다(캐시만 남은 자동 패스는 이전 경과를 덮지 않는다).
    commitAction(action);
    if (action) action.timing.image = imageTiming;
    // 예외(실패·취소)로 끝나면 남겨 둔 이전 성공 덮개를 여기서 지우지 않는다(runPass·시간 한도 처리가 유효한 것만 남긴다).
    let threw = false;
    try {
      if (reuse.length) {
        if (!(await translateHeldImages(reuse, { pageGen, scrollGen, sx, sy, override, action, inventory, imageTiming, shared }))) return;
        if (!candidates.length) {
          const reused = imageInventory();
          updateInventory(inventory, { images: reused.images, imageSentences: reused.imageSentences });
          return;
        }
        markStage(action, "capture");
      }
      // complete는 데이터를 다 받았다는 뜻일 뿐 새 그림이 화면에 그려졌다는 뜻이 아니다(디코딩은 따로 늦게 끝날 수 있고,
      // 그동안 화면에는 이전 그림이 남을 수 있다). 디코딩이 끝난 뒤 프레임을 넘겨야 캡처에 새 그림이 찍힌다.
      // 디코딩이 실패한(깨졌거나 취소된) 그림은 화면에 제대로 그려지지 않으므로 애초에 캡처·OCR 대상에서 뺀다.
      const decoded = await Promise.all(candidates.map((c) =>
        Promise.all(c.members.map((m) => m.decode())).then(() => true, () => false)));
      candidates = candidates.filter((c, index) => decoded[index]);
      if (!candidates.length) return;
      // 자기 덮개를 OCR하지 않도록 캡처 동안만 숨기고, 같은 동안만 밝기 보정 견본을 가장자리에 그린다.
      captureHidden = true;
      applyLayerVisibility();
      const spot = calibrationSpot(candidates);
      const swatch = spot ? showCalibration(spot) : null;
      let capture;
      try {
        await nextFrames(2);
        // 기다리는 사이 그림·자리가 바뀐 후보는 캡처에 다른 그림이 찍히므로 뺀다.
        candidates = captureReadyCandidates(candidates);
        if (!candidates.length || !stillCurrent(pageGen) || scrollGen !== state.scrollGen) return;
        const calibration = swatch && calibrationPlaced(swatch, spot) ? { x: spot.x, y: spot.y, w: spot.w, h: spot.h } : null;
        const captureAt = performance.now();
        capture = await send({ cmd: "capture", ...(calibration ? { calibration } : {}) });
        imageTiming.capture = Math.round(performance.now() - captureAt);
      } finally {
        removeCalibration();
        captureHidden = false;
        applyLayerVisibility();
      }
      if (!stillCurrent(pageGen) || scrollGen !== state.scrollGen || scrollX !== sx || scrollY !== sy) return;
      // 백그라운드는 캡처 빈도 제한 때문에 찍기 전에 기다릴 수 있다. 그사이 바뀐 후보는 찍힌 그림과 맞지 않으므로 뺀다.
      candidates = captureReadyCandidates(candidates);
      if (!candidates.length) return;
      const regions = candidates.map((c, index) => ({ k: `i${index}`, x: c.clip.x, y: c.clip.y, w: c.clip.w, h: c.clip.h }));
      updateInventory(inventory, { phase: "ocr" });
      markStage(action, "ocr");
      const ocrSentAt = performance.now();
      const response = await send({ cmd: override ? "ocrPageExternal" : "ocr", captureId: capture.captureId, target, engine, viewport, regions,
                                    pageTitle: String(document.title || "").slice(0, 300),
                                    ...(shared?.deferred && !shared.deferred.done ? { texts: shared.deferred.texts } : {}),
                                    ...(override ? { token: override.token } : {}), ...(action ? { action: action.id } : {}) });
      imageTiming.ocrRoundtrip = Math.round(performance.now() - ocrSentAt);
      imageTiming.native = response.timing || null;
      imageTiming.externalRequest = response.externalRequest || null;
      // 결과가 오는 사이 스크롤·이동·언어·엔진 변경이 있었으면 위치가 맞지 않으므로 버린다.
      if (!stillCurrent(pageGen) || scrollGen !== state.scrollGen || state.pageEngineOverride !== override ||
          target !== (override ? override.target : state.target) || engine !== (override ? override.engine : state.engine) ||
          scrollX !== sx || scrollY !== sy) return;
      if (shared?.deferred && !shared.deferred.done) shared.deferred.consume(response);
      if (response.missing.length) state.warning = `언어 팩 필요: ${response.missing.join(", ")}`;
      if (response.warning) state.warning = response.warning;
      if (typeof response.aiRefine === "boolean") state.aiRefine = response.aiRefine;
      const imageRefineCandidates = [];
      markStage(action, "render");
      const renderAt = performance.now();
      for (const image of response.images) {
        // 그리는 사이 시간 한도 초과·중지·이동으로 세대가 바뀌었으면 남은 그림은 그리지 않는다(늦은 결과 거부).
        if (pageGen !== state.pageGen || scrollGen !== state.scrollGen) break;
        const index = Number(String(image.k).slice(1));
        const candidate = candidates[index];
        if (!candidate || `i${index}` !== image.k) continue;
        // OCR을 기다리는 사이 이 이미지가 다른 그림으로 바뀌었거나(src·currentSrc) 새 그림을 불러오는 중이거나(!complete)
        // 자리·크기가 달라졌으면(같은 엘리먼트를 재사용하거나 옮기는 리더) 방금 받은 글자는 예전 그림 것이므로 버린다.
        if (!candidateUnchanged(candidate)) continue;
        await renderImage(candidate, withoutImageNames(candidate.img, image.items), image.langs,
          isExternal() ? null : imageRefineCandidates);
        // 디버그용(제품 UI 아님): 이 캡처의 견본 측정 상태와 검정/회색/흰색 대표값
        const drawn = imageRecords.get(candidate.img);
        const cal = response.calibration;
        if (drawn && cal) drawn.box.dataset.cal = Number.isInteger(cal.w) ? `${cal.s} ${cal.b}/${cal.g}/${cal.w}` : cal.s;
      }
      imageTiming.render = Math.round(performance.now() - renderAt);
      // 이번 패스에서 그린 그림과 이전부터 그대로인 그림을 합쳐 다시 센다(번역 성공 여부와 무관, 인식한 그대로).
      const finalInventory = imageInventory();
      updateInventory(inventory, { images: finalInventory.images, imageSentences: finalInventory.imageSentences });
      if (!isExternal() && state.aiRefine && imageRefineCandidates.length) {
        // 화면 순서의 앞 여덟 항목 대신 큰 제목과 문장부터 다듬는다. 호출 수·글자 상한은 그대로다.
        imageRefineCandidates.sort((a, b) => {
          const score = (c) => {
            const source = c.original.trim().replace(/[\s〜～」』）)]+$/u, "");
            // 짧은 설명문도 이름·제목보다 먼저 다듬어 동음 한자 오역이 그대로 남지 않게 한다.
            const sentence = /[一-龯]/u.test(source) && /(?:[るたく]|[。！？])$/u.test(source);
            return (sentence ? 20000 : 0) + (c.sourceSize >= 40 ? 10000 : 0) + c.original.length;
          };
          return score(b) - score(a);
        });
        let refineChars = 0;
        const selected = imageRefineCandidates.filter((c) => {
          // 네이티브에서도 제외하는 순수 가타카나 이름으로 여덟 문장 자리를 소모하지 않는다.
          if (/^[ァ-ヺー]{3,24}$/u.test(c.original.trim())) return false;
          const size = c.original.length + c.draft.length;
          if (refineChars + size > REFINE_TOTAL_CHARS) return false;
          refineChars += size;
          return true;
        }).slice(0, MAX_REFINE_ITEMS);
        return { candidates: selected, scrollGen };
      }
    } catch (error) {
      threw = true;
      throw error;
    } finally {
      ocrInFlight = false;
      // 이번 패스를 끝까지 마쳤는데 새 서비스 번역으로 바꾸지 못한, 화면에 걸친 남은 덮개는 지운다(이전 서비스 번역을 남기지 않는다).
      if (!threw && pageGen === state.pageGen && scrollGen === state.scrollGen) dropHeldImages(true);
    }
  }

  // MARK: 번역 실행

  /** 주소가 바뀌었으면(해시·pushState 포함) 이전 결과를 모두 무효화하고 true를 돌려준다. */
  function checkNavigation() {
    if (location.href === state.url) return false;
    state.url = location.href;
    state.pageGen += 1;
    // 이전 주소의 경과·단계 기록은 새 주소에 보이지 않게 한다(진행 중이던 패스는 세대가 바뀌어 중단으로 끝난다).
    state.action = null;
    // 1회성 Google·DeepL 덮어쓰기는 그 요청을 보낸 문서(주소)에만 유효하다 — 이동하면 바로 끈다.
    if (state.pageEngineOverride) {
      endPageOverride();
      revertForeignRecords();
    }
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
    if (!manual && !isAutoLike()) return;
    // 시간 한도를 넘겨 중단한 이 문서는 사용자가 다시 누를 때까지 자동으로 다시 하지 않는다(재시도·다른 엔진 대체 없음).
    if (!manual && state.holdUrl === location.href) return;
    if (document.visibilityState !== "visible") return;
    checkNavigation();
    if (manual) state.holdUrl = null;
    state.running = true;
    // 번역을 보내기 전에 지금 화면에 보이는 그림 수를 먼저 센다(이미 그려 둔 그림도 포함, 작업 대상 여부와 무관).
    let imageInv = { images: 0, imageSentences: 0 };
    if (state.images) {
      try { imageInv = imageInventory(); } catch { imageInv = { images: 0, imageSentences: 0 }; }
    }
    state.inventory = { gen: state.pageGen, phase: "search", textMessages: null, textSentences: null,
                        images: imageInv.images, imageSentences: imageInv.imageSentences, send: null };
    const action = adoptAction(manual);
    reportProgress();
    state.error = "";
    state.warning = ""; // 이전 시도의 언어팩·이전 번역 유지 경고를 새 결과에 붙이지 않는다.
    const pageGen = state.pageGen;
    let failed = false;
    let cancelled = false;
    // 같은 패스의 일반 글자와 그림 재사용이 나누는 상태: 재사용할 그림 원문을 일반 글자 요청에 합쳐 받은 결과(1회성 번역에서만).
    const shared = { override: state.pageEngineOverride, held: new Map() };
    try {
      setStatus("번역 중");
      const textRefine = await translateTextPass(pageGen, shared);
      let imageRefine = null;
      // 이미지 인식·복원·배치는 같은 경로를 쓰고, Google·DeepL 옵션에서는 인식한 글자 번역만 그 서비스에 맡긴다.
      if (pageGen === state.pageGen) {
        if (state.images) setStatus("이미지 글자 확인 중");
        try {
          imageRefine = await imagePass(pageGen, shared);
        } catch (error) {
          // 재사용한 원문의 새 서비스 번역이 실패하면 일반 글자 번역 실패처럼 이 패스를 오류로 끝낸다(완료로 두지 않는다).
          if (error.imageReuse) throw error;
          if (error.code !== "cancelled" && error.code !== "stale" && error.code !== "tab_hidden") {
            // 1회성 번역의 그림 인식·번역 실패도 완료로 두지 않는다(남겨 둔 이전 덮개는 실패 처리에서 유효한 것만 남긴다).
            if (shared.override) {
              // 이미지 오류여도 정상 일반 글자는 번역한다. 취소·세대 변경 뒤에는 전송하지 않는다.
              if (shared.deferred && !shared.deferred.done && stillCurrent(pageGen) && state.pageEngineOverride === shared.override) {
                await shared.deferred.flush();
              }
              throw error;
            }
            state.warning = `이미지: ${error.message}`;
          }
        }
      }
      // 그림을 읽을 수 없거나 후보가 사라졌으면 보류한 일반 글자는 기존 경로로 번역한다.
      if (shared.deferred && !shared.deferred.done && pageGen === state.pageGen) await shared.deferred.flush();
      // 실제로 이미지 인식·번역이 끝난 후 다듬기를 시작한다. 앞선 일반 글자 AI가 OCR 모델과 자원을 다투지 않는다.
      if ((textRefine || imageRefine) && pageGen === state.pageGen && !isExternal() && state.aiRefine) {
        refinePageCandidates(imageRefine, textRefine, pageGen).catch(() => {});
      }
      // 시간 한도가 있는 외부 번역은 배경에 끝을 알려 한도 안에 끝났는지 확인받은 뒤에만 '완료'로 둔다(배경이 판정 주체).
      if (pageGen === state.pageGen && action.deadline && !action.provisional && action.outcome === null) {
        const verdict = await send({ cmd: "externalActionEnd", engine: action.engine, token: action.token, action: action.id })
          .catch(() => null);
        const limit = ACTION_DEADLINE_MS[action.engine];
        if (verdict && verdict.timedOut === true) {
          applyDeadline(action.token, action.id, typeof verdict.stage === "string" ? verdict.stage : null, verdict.at);
        } else if (verdict && verdict.revoked === true) {
          throw Object.assign(new Error(""), { code: "cancelled" }); // 그사이 허용이 끝났다(중지·이동 등)
        } else if (verdict && verdict.verified === false && Date.now() - action.startedAt > limit) {
          // 배경에 한도 기록이 없어(배경 재시작 등) 판정받지 못했는데 이 쪽 시계로도 한도를 넘겼으면 완료로 두지 않는다.
          send({ cmd: "endExternalPage", token: action.token }).catch(() => {});
          applyDeadline(action.token, action.id, null, null);
        } else if (!verdict && pageGen === state.pageGen) {
          throw Object.assign(new Error("DeepL 처리 시간을 확인하지 못해 결과를 확정하지 않았습니다."), { code: "deadline_unknown" });
        }
      }
      if (pageGen === state.pageGen) {
        // 한도 안에 끝난 것으로 확정됐다: 되돌릴 일이 없으므로 이전 성공 덮개 사본을 놓는다.
        dropPriors();
        setStatus("완료");
      }
    } catch (error) {
      // 취소(배경의 시간 한도 취소 포함)로 끝난 패스는 '완료'로 두지 않는다.
      if (error.code === "cancelled" || error.code === "stale") cancelled = true;
      else {
        failed = true;
        // 실패한 패스는 그림을 원문으로 되돌리지 않는다: 남겨 둔 이전 성공 덮개 중 같은 그림·같은 자리에 유효한 것만 남기고
        // (지금 번역으로 세지 않음) 고정 문구로 알린다. 다른 엔진으로 바꾸거나 다시 시도하지 않는다.
        const kept = pageGen === state.pageGen ? retainHeldOverlays(false) : 0;
        if (kept) state.warning = HELD_KEPT_WARNING;
        state.error = error.message || "번역하지 못했습니다.";
        setStatus("오류");
      }
    } finally {
      state.running = false;
      updateInventory(inventoryOf(pageGen), { phase: "done" });
      // 동작 끝: 세대가 바뀌었으면 중단, 오류면 오류, 다듬기가 남았으면 다듬기 단계로 넘겨 마지막 다듬기가 끝날 때 멈춘다.
      if (state.passAction === action) state.passAction = null;
      if (action.outcome === null && !action.provisional) {
        if (pageGen !== state.pageGen || cancelled) finishAction(action, "cancelled");
        else if (failed) finishAction(action, "error");
        else if ((refinePending.get(pageGen) || 0) > 0) {
          markStage(action, "refine");
          action.waitRefine = true;
        } else finishAction(action, "done");
      }
      reportProgress();
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
        removeFontSpan(node);
        continue;
      }
      if (record.translated === null) continue;
      const from = view === "translated" ? record.original : record.translated;
      const to = view === "translated" ? record.translated : record.original;
      if (node.nodeValue === from) node.nodeValue = to;
      if (view === "translated") applyNodeFont(node, state.fontStyle);
      else removeFontSpan(node);
    }
    applyLayerVisibility();
    setStatus(view === "translated" ? "번역 표시" : "원문 표시");
    reportProgress();
  }

  // MARK: 변경 감시(자동 번역일 때만) — 자기 변경은 걸러 무한 반복을 막는다.

  // img/picture-source의 src·srcset이 바뀌면 그 이미지는 이제 다른 그림이므로(같은 엘리먼트를 재사용하는
  // 리더 등) 남은 덮개는 틀린 그림 위에 뜬 것이다. 지우고 진행 중 캡처·OCR은 scrollGen을 올려 무효화한다.
  function invalidateImage(img) {
    // 조각 묶음 덮개는 맨 위 조각에 기록되므로 바뀐 그림이 어느 조각이든 그 묶음 덮개를 지운다.
    for (const [anchor, record] of imageRecords) {
      if (anchor !== img && !record.members.includes(img)) continue;
      record.box.remove();
      imageRecords.delete(anchor);
    }
    // 그리던 중인 그림이면 이전 성공 덮개도 되살리지 않는다(그림이 바뀌었으므로).
    overlayEpoch += 1;
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
          if (attr !== "class" && attr !== "style") invalidateImage(target);
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
          for (const [img, record] of imageRecords) {
            if (record.members.some((m) => target.contains(m))) { relevant = true; }
          }
          if (!relevant && target.querySelector("img")) relevant = true;
          // 그림을 덮던 막(또는 그 조상)의 class/style 변화는 막이 걷혔을 수 있으므로 다시 본다.
          if (!relevant && touchesImageCover(target)) relevant = true;
          if (relevant) changed = true;
        }
      } else if (mutation.type === "characterData") {
        const record = records.get(mutation.target);
        if (record && (mutation.target.nodeValue === record.translated || mutation.target.nodeValue === record.original)) continue;
        changed = true;
      } else {
        if (mutation.removedNodes.length) removed = true;
        for (const node of mutation.removedNodes) {
          if (touchesImageCover(node)) changed = true;
        }
        for (const node of mutation.addedNodes) {
          // 견본 호스트는 캡처 직후 지워져 콜백 때 참조가 남지 않으므로 태그 이름으로 거른다(전체화면 요소 아래에 붙는 경우).
          if (node !== layerHost && node.nodeName !== "SMT-TRANSLATOR-CALIBRATION") changed = true;
        }
      }
    }
    // 문서에서 빠진 이미지의 덮개는 다음 통과를 기다리지 않고 바로 지운다.
    if (removed) {
      for (const [img, record] of imageRecords) {
        if (record.members.every((m) => m.isConnected)) continue;
        record.box.remove();
        imageRecords.delete(img);
      }
    }
    if (changed) onPageChanged();
  });
  let observing = false;

  function onPageChanged() {
    if (isAutoLike()) schedule();
  }

  // 로딩 중이라 이번 통과에서 건너뛴 이미지(imageCandidates의 !img.complete)는 로드가 끝나야 OCR할 수 있으므로,
  // 캡처링으로 하위 img의 load를 받아 그때 한 번 더 통과를 건다(자동 번역 중일 때만).
  function onImageLoad(event) {
    if (event.target instanceof HTMLImageElement && isAutoLike()) schedule();
  }

  // 그림을 덮던 막이 class 변화 뒤 서서히 사라지는(전환·애니메이션) 경우, 변화 순간의 통과는 아직 덮인 상태를 보므로
  // 그 막의 전환이 끝났을 때 한 번 더 통과를 건다(고정 대기 없이 페이지 자신의 끝 신호만 쓴다).
  function onCoverSettled(event) {
    if (!isAutoLike()) return;
    if (imageCovers.size && touchesImageCover(event.target)) schedule();
    // 투명하게 시작한 일반 본문은 화면에 나타나는 전환이 끝난 뒤 다시 수집한다.
    else if (event.propertyName === "opacity" && event.target instanceof Element &&
             !event.target.closest(SKIP_SELECTOR) && Number(getComputedStyle(event.target).opacity) > 0.01 &&
             LETTER.test(event.target.textContent || "")) schedule();
  }

  function setObserving(on) {
    if (on && !observing && document.body) {
      observer.observe(document.body, {
        childList: true, subtree: true, characterData: true,
        attributes: true, attributeFilter: ["src", "srcset", "class", "style"]
      });
      document.addEventListener("load", onImageLoad, true);
      document.addEventListener("transitionend", onCoverSettled, true);
      document.addEventListener("animationend", onCoverSettled, true);
      observing = true;
    } else if (!on && observing) {
      observer.disconnect();
      document.removeEventListener("load", onImageLoad, true);
      document.removeEventListener("transitionend", onCoverSettled, true);
      document.removeEventListener("animationend", onCoverSettled, true);
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
        if (record.members.some((m) => scroller.contains(m))) record.box.style.display = "none";
      }
    }
    if (isAutoLike()) schedule();
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
    if (isAutoLike()) schedule();
  }

  addEventListener("scroll", onScroll, { passive: true, capture: true });
  addEventListener("resize", onScroll, { passive: true });
  document.addEventListener("fullscreenchange", onFullscreenChange);
  document.addEventListener("webkitfullscreenchange", onFullscreenChange);
  function onHistoryChange() {
    checkNavigation();
    if (isAutoLike()) schedule();
  }
  addEventListener("popstate", onHistoryChange);
  addEventListener("hashchange", onHistoryChange);
  addEventListener("pagehide", () => send({ cmd: "cancel" }).catch(() => {}));
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") {
      if (ocrInFlight) send({ cmd: "cancel", kind: "ocr" }).catch(() => {});
    } else if (isAutoLike()) {
      schedule();
    }
  });

  // MARK: 확장 메시지

  // 텍스트 조각(레코드)과 OCR 문단(이미지 레코드)에 남아 있는 판별 언어만 센다. 글자 없음(null)·구버전 응답(생략)은
  // 집계하지 않아(거짓으로 채우지 않음) langCounts가 비면 null을 돌려준다.
  // 번역한 원문 글자 수: 공백을 뺀 유니코드 코드포인트 수(서로게이트 쌍·한자·가나·한글 모두 한 글자).
  const letterCount = (text) => (typeof text === "string" ? Array.from(text.replace(/\s+/gu, "")).length : 0);

  /** 지금 이 문서에 번역문으로 보이고 있는 원문 글자 수. 일반 글자는 연결된 노드 중 현재 번역 설정(profile)으로 번역돼
   *  번역문이 실제로 걸려 있는 조각만, 이미지는 화면에 붙어 있는 덮개의 번역 성공 항목(번역 확인 필요 표시 제외)만 센다.
   *  묶음 이미지(조각 여러 장)는 덮개 하나로 기록되므로 한 번만 센다. 원문 보기 중에는 번역문이 보이지 않으므로 0이다.
   *  언어 판별 개수는 번역한 글자가 아니므로 섞지 않는다. */
  function translatedLetters() {
    let text = 0, image = 0, imageItems = 0;
    if (state.view !== "translated") return { text, image, imageItems };
    const current = profile();
    for (const [node, record] of records) {
      if (record.translated === null || record.target !== current || !node.isConnected || node.nodeValue !== record.translated) continue;
      text += letterCount(record.original);
    }
    const seen = new Set();
    for (const [img, record] of imageRecords) {
      // 번역 서비스를 바꾸는 동안 남겨 둔(held) 덮개는 이전 서비스 번역이라 지금 번역으로 세지 않는다.
      if (seen.has(record) || record.held || !img.isConnected || !record.box.isConnected || !Array.isArray(record.items)) continue;
      seen.add(record);
      for (const item of record.items) {
        if (!item || item.unresolved || typeof item.t !== "string" || !item.t.trim()) continue;
        const n = letterCount(item.o);
        if (n <= 0) continue;
        image += n;
        imageItems += 1;
      }
    }
    return { text, image, imageItems };
  }

  function snapshot() {
    let translated = 0;
    const langCounts = {};
    let hasLangData = false;
    const letters = translatedLetters();
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
      // 번역해 보이고 있는 원문 글자 수(공백 제외): 전체·일반 글자·이미지 속 글자, 번역된 이미지 글자 묶음 수.
      letters: { total: letters.text + letters.image, text: letters.text, image: letters.image, imageItems: letters.imageItems },
      langCounts: hasLangData ? langCounts : null,
      // 실제로 번역·OCR·다듬기 패스가 진행 중인지(단순 자동 감시 대기는 포함 안 함). 팝업 스피너가 이 값만 본다.
      running: isBusy(),
      // 1회성 Google·DeepL 덮어쓰기가 지금 이 문서에서 진행 중인지(팝업이 버튼 상태·중지 버튼을 보이는 데만 쓴다).
      externalPage: state.pageEngineOverride ? { engine: state.pageEngineOverride.engine, target: state.pageEngineOverride.target } : null,
      timing: state.timing,
      inventory: inventorySnapshot(),
      action: actionSnapshot()
    };
  }

  /** 지금 보여 줄 번역 동작(지금 세대 것, 또는 시간 초과로 멈춘 것)의 시각·단계·결과(숫자와 단계 이름만). */
  function actionSnapshot() {
    const action = state.action;
    if (!action || (action.gen !== state.pageGen && action.outcome !== "timeout")) return null;
    const open = action.stages.length && action.stages[action.stages.length - 1].b === null
      ? action.stages[action.stages.length - 1].s : null;
    return {
      id: action.id, startedAt: action.startedAt, source: action.source, engine: action.engine, deadline: action.deadline,
      outcome: action.outcome, endedAt: action.endedAt, stage: open, stopStage: action.stopStage ? { ...action.stopStage } : null,
      stages: action.stages.map((stage) => ({ ...stage })), inventory: action.inventory, timing: action.timing
    };
  }

  /** 지금 세대 패스의 기본 목록(개수만)과 실제 단계. 패스가 끝난 뒤 다듬기가 남아 있으면 refine 단계다. */
  function inventorySnapshot() {
    const inventory = inventoryOf(state.pageGen);
    const refineItems = refineItemsPending.get(state.pageGen) || 0;
    const refining = (refinePending.get(state.pageGen) || 0) > 0;
    if (!inventory && !refining) return null;
    const base = inventory || { phase: "done", textMessages: null, textSentences: null, images: null, imageSentences: null, send: null };
    return {
      phase: state.running ? base.phase : (refining ? "refine" : "done"),
      engine: state.pageEngineOverride ? state.pageEngineOverride.engine : state.engine,
      textMessages: base.textMessages, textSentences: base.textSentences, images: base.images, imageSentences: base.imageSentences,
      send: base.send ? { ...base.send } : null,
      refineItems
    };
  }

  /** 진행 상태(실행 중 여부·보기)를 배경에 알려 툴바 아이콘·배지를 갱신한다(팝업이 닫혀 있어도 반영됨).
   *  응답을 기다리지 않고, 실패(컨텍스트 무효화 등)는 조용히 무시한다. */
  function reportProgress() {
    if (contextDead) return;
    try {
      const result = api.runtime.sendMessage({ cmd: "progress", running: isBusy(), view: state.view });
      if (result && typeof result.catch === "function") result.catch(() => {});
    } catch { /* 확장 컨텍스트 무효화 등 — 조용히 무시 */ }
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
          rerenderTextFonts(); // 재번역 없이 이미 보이는 번역 텍스트 노드만 새 글꼴로 다시 입힌다
        }
        if (targetChanged || engineChanged) {
          if (targetChanged) state.target = message.target;
          if (engineChanged) state.engine = message.engine;
          // 전역 설정이 바뀌면 1회성 Google·DeepL 덮어쓰기도 끈다(다른 언어/엔진으로 섞여 보이지 않게).
          endPageOverride();
          state.pageGen += 1;
          revertForeignRecords();
          state.warning = "";
          clearImageOverlays();
          send({ cmd: "cancel" }).catch(() => {});
        }
        // 수동 번역 뒤에도 감시는 켜 둔다: 페이지가 바뀌면 이전 결과를 지우는 데만 쓰고, 새 번역은 자동일 때만 한다.
        // 끄는 것은 원문 보기(toggleOriginal)뿐이다.
        if (state.auto || message.translateNow === true) setObserving(true);
        if (message.translateNow === true) {
          // 경과는 팝업이 보낸 클릭 시각부터 잰다. 팝업을 열며 실행된 경우(open)는 이미 번역 중이면 지금 동작을 그대로 두고,
          // 아니면 실제로 할 일이 생길 때만 새 동작으로 보인다(이미 번역된 페이지에서 팝업을 다시 열어도 경과가 바뀌지 않는다).
          const trigger = message.trigger === "button" ? "click" : "open";
          if (trigger === "click" || !state.running) state.pendingAction = newAction(clickTime(message.clickedAt), trigger);
          // 일반 번역은 1회성 Google·DeepL 번역를 끝내고, 그 결과(다른 엔진)를 화면에 남기지 않는다.
          if (state.pageEngineOverride) {
            endPageOverride();
            state.pageGen += 1;
            clearImageOverlays();
          }
          revertForeignRecords();
          setView("translated");
          clearTimeout(state.timer);
          state.timer = 0;
          runPass(true);
        } else if (state.auto && state.holdUrl !== location.href) {
          setView("translated");
          schedule();
        }
        sendResponse(snapshot());
        return false;
      }
      case "toggleOriginal":
        // 원문 보기는 항상 원문으로 되돌리고 이 페이지의 자동 번역을 끈다(다시 켜려면 번역 버튼).
        // 세대를 올려 이미 보낸 요청의 늦은 응답이 돌아와도 다시 칠하지 않게 한다.
        // 진행 중인 패스 뒤에 이어 하기로 한 재실행(수동 포함)도 취소한다. 1회성 Google·DeepL 번역도 함께 끈다.
        if (Number.isFinite(message.epoch)) state.stopEpoch = Math.max(state.stopEpoch, message.epoch);
        state.auto = false;
        endPageOverride();
        revertForeignRecords();
        state.rerun = false;
        state.rerunManual = false;
        state.pendingAction = null;
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
      case "startExternalPage": {
        // 팝업의 명시적 1회성 Google·DeepL 번역 버튼. 이 탭의 지금 문서(주소)에만, 이 흐름이 남아 있는 동안만 적용된다.
        // 저장된 전역 engine·전역 자동 번역은 건드리지 않는다. 이미지 자체는 Mac에서 인식·복원한다.
        if (!Number.isFinite(message.epoch) || message.epoch < state.stopEpoch ||
            !Object.hasOwn(EXTERNAL_PAGE_MAX_CHARS, message.engine) || typeof message.target !== "string" ||
            typeof message.token !== "string") {
          sendResponse(snapshot());
          return false;
        }
        // token: 배경이 이 문서와 이 엔진에만 건넨 허용 표시. 요청마다 엔진과 함께 보내며, 끝날 때 배경에 알려 지우게 한다.
        // 다른 엔진으로 다시 시작하면 덮어쓰기 객체가 바뀌어, 이전 엔진의 늦은 응답은 아래 패스들이 버린다.
        state.pageEngineOverride = { engine: message.engine, target: message.target, token: message.token };
        // 경과·시간 한도는 팝업의 클릭 시각부터 잰다. 동작 id는 배경이 이 클릭에 붙인 값(배경의 한도 기록과 같은 id)이다.
        state.pendingAction = newAction(clickTime(message.clickedAt), "click", message.action);
        state.pageGen += 1; // 다른 캐시 키(profile())로 바로 다시 모으도록 이전 수집과 분리한다.
        // 다 그린 이미지 덮개는 지우지 않고 남겨, 같은 그림이면 원문 인식·복원 조각을 재사용해 글자만 새 서비스로 번역한다
        // (재캡처·재인식·배경 분석 생략). 새 번역이 올 때까지 원문 글자를 가린다. 그리는 중이던 덮개는 지운다.
        holdImageOverlays();
        // 이전 엔진(Mac 기본 번역)으로 바꿔 둔 글자는 원문으로 돌려, 화면에 두 엔진 결과가 섞이지 않게 한다.
        revertForeignRecords();
        send({ cmd: "cancel" }).catch(() => {});
        state.warning = "";
        setObserving(true);
        setView("translated");
        clearTimeout(state.timer);
        state.timer = 0;
        runPass(true);
        sendResponse(snapshot());
        return false;
      }
      case "stopExternalPage":
        // 사용자가 팝업에서 직접 중지하거나, 배경이 탭 종료 전에 정리할 때. 전역 자동 번역 상태는 그대로 두고,
        // 화면은 기다리지 않고 바로 되돌린다: 전역 자동 번역이 켜져 있으면 그 결과로 바로 다시 번역하고,
        // 꺼져 있으면 즉시 원문으로 되돌린다('중지'를 눌렀는데 Google 번역 글자가 그대로 남아 있지 않게 한다).
        if (state.pageEngineOverride) {
          endPageOverride();
          state.pageGen += 1;
          clearImageOverlays();
          // Google로 바꿔 둔 글자는 바로 원문으로 돌린다(자동 번역이면 이어서 Mac 기본 번역으로 다시 바뀐다).
          revertForeignRecords();
          state.warning = "";
          send({ cmd: "cancel" }).catch(() => {});
          clearTimeout(state.timer);
          state.timer = 0;
          if (state.auto) {
            setObserving(true);
            setView("translated");
            runPass(true);
          } else {
            setObserving(false);
            setView("original");
          }
        }
        sendResponse(snapshot());
        return false;
      case "externalDeadline":
        // 배경이 이 동작의 외부 번역 시간 한도 초과를 판정하고 허용을 거둔 뒤 보낸다(배경의 취소와 별도로 화면을 바로 멈춘다).
        if (typeof message.token === "string" && typeof message.action === "string") {
          const at = Number.isFinite(message.at) && message.at >= 0 && message.at <= 3600000 ? message.at : null;
          applyDeadline(message.token, message.action, typeof message.stage === "string" ? message.stage : null, at);
        }
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
