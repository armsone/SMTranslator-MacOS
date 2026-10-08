"use strict";
// SMT 웹 번역 — 백그라운드(Chrome·Whale 서비스 워커 / Safari 이벤트 페이지 공용).
// - 페이지 글자·보이는 탭 캡처는 이 Mac의 SMT 엔진(Chrome·Whale: 네이티브 메시징 도우미, Safari: 확장 앱)으로만 보낸다.
//   기본 번역 엔진은 Mac 기본 번역(기기 내)이다. Chrome·Whale에서 사용자가 웹 번역 엔진(DeepL·Google·Papago)을 따로 고르고
//   그 엔진에 동의한 경우에만 SMT가 글자(이미지는 Mac에서 인식한 글자)를 그 서비스의 공식 웹페이지로 보낸다. Safari는 Mac 기본만.
// - 저장하는 값: 동의 여부, 번역 언어, 번역 엔진과 엔진별 동의, 이미지 번역 여부, 전역 자동 번역 켜짐 여부. 페이지 내용은 저장하지 않는다.
// - 요청마다 ID를 붙여 탭별로 추적하고, 탭 이동·닫기·스크롤(이미지) 때 그 탭의 요청만 취소한다.
// - 전역 자동 번역(automaticEnabled)은 번역 버튼을 누를 때만 켜진다(이전 sites 목록은 더는 옵트인 신호로 쓰지 않는다).
//   Chrome·Whale은 팝업이 그 클릭 안에서 선택 권한 <all_urls>(captureVisibleTab 문서상 activeTab 대신 필요한 권한)를
//   요청하고, 배경이 실제 허용 여부를 다시 확인한 뒤에만 true를 저장한다. 거절·미허용이면 false를 저장하고 전역으로 멈춘다.
//   권한 범위와 달리 실제 주입·번역·캡처는 http/https 페이지(originOf)에만 한다.
// - 전역 켜기/끄기는 세대(control.epoch)로 직렬화한다. 끄기(원문 보기·권한 철회·동의/자동 해제)는 요청 즉시 세대를 올리고,
//   모든 비동기 흐름은 탭에 보내기 직전 자기 세대가 그대로인지와 최신 동의·자동·권한을 다시 확인한다.

const api = globalThis.browser ?? globalThis.chrome;
const IS_SAFARI = api.runtime.getURL("").startsWith("safari-web-extension:");
const HOST_NAME = "com.local.screentranslator.browser";
const SAFARI_APP_ID = "com.local.screentranslator";
const TARGETS = ["ko", "en", "ja", "zh-Hans", "zh-Hant"];
const ALL_URLS = "<all_urls>";
const TAB_MESSAGE_TIMEOUT = 5000;
const LIMITS = { texts: 150, textLength: 5000, chars: 40000, regions: 16, glyphsPerItem: 128, glyphsTotal: 8192,
                 refineItems: 8, refineItemChars: 700, refineChars: 4000 };
// 웹 번역 엔진은 SMT가 항목마다 차례로 공식 페이지에 넣으므로 요청을 작게 하고 오래 기다린다(페이지 확인을 사용자가 할 시간 포함).
const EXTERNAL_LIMITS = { texts: 12, chars: 15000 };
const TIMEOUT = { hello: 15000, text: 60000, ocr: 90000, external: 600000, refine: 20000 };
const LOCAL_ENGINE = "apple";
const EXTERNAL_ENGINES = IS_SAFARI ? [] : ["deepl", "google", "papago"];
const CAPTURE_MIN_INTERVAL = 700; // Chrome captureVisibleTab 호출 빈도 제한(초당 2회) 아래로 유지
const CAPTURE_TTL = 15000;
const DEFAULTS = { consent: false, target: "ko", images: true, automaticEnabled: false, engine: LOCAL_ENGINE, engineConsents: [] };

function codedError(code, message) {
  const error = new Error(message || code);
  error.code = code;
  return error;
}

function originOf(url) {
  try {
    const parsed = new URL(url);
    return parsed.protocol === "http:" || parsed.protocol === "https:" ? parsed.origin : null;
  } catch {
    return null;
  }
}

async function loadSettings() {
  const stored = await api.storage.local.get(DEFAULTS);
  const engineConsents = Array.isArray(stored.engineConsents)
    ? stored.engineConsents.filter((engine) => EXTERNAL_ENGINES.includes(engine))
    : [];
  // 웹 번역 엔진은 이 브라우저에서 지원하고 그 엔진에 동의했을 때만 쓴다. 아니면 Mac 기본 번역.
  const engine = EXTERNAL_ENGINES.includes(stored.engine) && engineConsents.includes(stored.engine) ? stored.engine : LOCAL_ENGINE;
  return {
    consent: stored.consent === true,
    target: TARGETS.includes(stored.target) ? stored.target : "ko",
    images: stored.images !== false,
    automaticEnabled: stored.automaticEnabled === true,
    engine,
    engineConsents
  };
}

// MARK: - 권한·전역 상태 세대

/** 전역 자동 번역에 필요한 권한이 실제로 있는지. Chrome·Whale은 선택 권한 <all_urls> 전체 허용이어야 한다.
 * Safari는 사이트별 허용을 Safari 설정이 관리하므로 탭마다 originPermitted로 확인한다. */
function hasGlobalGrant() {
  if (IS_SAFARI) return Promise.resolve(true);
  return Promise.resolve()
    .then(() => api.permissions.contains({ origins: [ALL_URLS] }))
    .then((granted) => granted === true, () => false);
}

function originPermitted(origin) {
  return Promise.resolve()
    .then(() => api.permissions.contains({ origins: [`${origin}/*`] }))
    .then((granted) => granted === true, () => false);
}

const control = {
  // 끄기마다 올라가는 세대. 서비스 워커가 다시 떠도 이전 값보다 커지도록 시각을 바탕으로 한다(내용 스크립트가 비교).
  epoch: Date.now(),
  // 이 워커가 전역 자동 번역이 켜져 있다고 믿는지(저장소 변경 이벤트로 자기 끄기를 다시 처리하지 않기 위함).
  // 깨어난 직후에는 알 수 없으므로 켜짐으로 보고 reconcile이 바로잡는다.
  armed: true,
  chain: Promise.resolve()
};

/** 전역 상태 전환(켜기 확정·끄기·시작 시 확인)을 하나씩 순서대로 실행한다. 이 안에서 globalStop을 부르면 안 된다. */
function serially(task) {
  const run = control.chain.then(task);
  control.chain = run.catch(() => {});
  return run;
}

function nextEpoch() {
  control.epoch = Math.max(Date.now(), control.epoch + 1);
  return control.epoch;
}

/** 지금도 자동 번역을 이어 가도 되면 최신 설정을, 아니면 null. 세대가 바뀌었거나(끄기) 동의·자동·권한이 없으면 null.
 * 저장값은 켜짐인데 전체 권한이 없으면 전역으로 끈다. */
async function autoStillAllowed(epoch, origin = null) {
  if (epoch !== control.epoch) return null;
  const settings = await loadSettings();
  if (!settings.consent || !settings.automaticEnabled) return null;
  if (!(await hasGlobalGrant())) {
    if (control.armed && epoch === control.epoch) globalStop().catch(() => {});
    return null;
  }
  if (origin && !(await originPermitted(origin))) return null;
  return epoch === control.epoch ? settings : null;
}

// MARK: - 네이티브 연결

function describeNativeFailure(raw) {
  const text = String(raw || "");
  if (IS_SAFARI) {
    return "SMT 확장 앱에 연결하지 못했습니다. SMT를 응용 프로그램 폴더에 설치해 한 번 실행하고 Safari 설정에서 확장을 켜 주세요.";
  }
  if (/not found/i.test(text)) {
    return "SMT 연결이 등록되지 않았습니다. SMT 메뉴 막대 › 브라우저 번역…에서 이 브라우저의 '설치 시작'을 누르세요.";
  }
  if (/forbidden/i.test(text)) {
    return "이 확장은 SMT 연결 허용 목록에 없습니다. SMT의 '브라우저 번역…'에서 '설치 시작'을 다시 누른 뒤 확장 폴더를 다시 로드하세요.";
  }
  return "SMT 엔진과 연결이 끊겼습니다. SMT가 응용 프로그램 폴더에 있는지 확인하고 다시 시도하세요.";
}

const native = {
  port: null,
  pending: new Map(), // id → { resolve, reject, timer, tabId, kind }
  seq: 0,
  lastFatal: null,
  status: { state: "unknown", message: "" },

  nextId(prefix) {
    this.seq = (this.seq + 1) % 1000000000;
    return `${prefix}-${Date.now().toString(36)}-${this.seq}`;
  },

  setStatus(state, message) {
    this.status = { state, message: message || "" };
  },

  ensurePort() {
    if (this.port) return this.port;
    const port = api.runtime.connectNative(HOST_NAME);
    this.lastFatal = null;
    port.onMessage.addListener((message) => this.receive(message));
    port.onDisconnect.addListener(() => {
      const reason = api.runtime.lastError?.message;
      if (this.port === port) this.port = null;
      const message = this.lastFatal?.message || describeNativeFailure(reason);
      const code = this.lastFatal?.code || "native_unavailable";
      this.setStatus("error", message);
      for (const [id, entry] of this.pending) {
        clearTimeout(entry.timer);
        this.pending.delete(id);
        entry.reject(codedError(code, message));
      }
    });
    this.port = port;
    return port;
  },

  receive(message) {
    if (!message || typeof message !== "object") return;
    const id = typeof message.id === "string" ? message.id : null;
    if (id && this.pending.has(id)) {
      const entry = this.pending.get(id);
      this.pending.delete(id);
      clearTimeout(entry.timer);
      if (message.ok === true) {
        this.setStatus("ready", "");
        entry.resolve(message);
      } else {
        entry.reject(codedError(String(message.code || "error"), String(message.message || "")));
      }
      return;
    }
    // ID 없는 오류(도우미가 연결 전에 보낸 안내)는 연결 끊김 때 그대로 보여준다.
    if (message.type === "error" && !id) {
      this.lastFatal = { code: String(message.code || "error"), message: String(message.message || "") };
      this.setStatus("error", this.lastFatal.message);
    }
  },

  request(message, { timeout, tabId = null, kind = "other" }) {
    const id = message.id;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (!this.pending.has(id)) return;
        this.cancel(id);
        reject(codedError("timeout", "SMT 응답 시간이 지났습니다. 다시 시도하세요."));
      }, timeout);
      this.pending.set(id, { resolve, reject, timer, tabId, kind });
      const failSend = (error) => {
        if (!this.pending.has(id)) return;
        clearTimeout(timer);
        this.pending.delete(id);
        const text = describeNativeFailure(error?.message);
        this.setStatus("error", text);
        reject(codedError("native_unavailable", text));
      };
      if (IS_SAFARI) {
        Promise.resolve(api.runtime.sendNativeMessage(SAFARI_APP_ID, message)).then(
          (response) => this.receive(response && typeof response === "object" ? response : { id, ok: false, code: "no_response", message: describeNativeFailure() }),
          failSend
        );
      } else {
        try {
          this.ensurePort().postMessage(message);
        } catch (error) {
          failSend(error);
        }
      }
    });
  },

  /** 대기 중인 요청을 취소한다. 엔진에도 취소를 보내 남은 작업을 멈춘다(같은 연결의 그 ID만). */
  cancel(id) {
    const entry = this.pending.get(id);
    if (entry) {
      clearTimeout(entry.timer);
      this.pending.delete(id);
      entry.reject(codedError("cancelled", ""));
    }
    const message = { v: 1, type: "cancel", id };
    if (IS_SAFARI) {
      Promise.resolve(api.runtime.sendNativeMessage(SAFARI_APP_ID, message)).catch(() => {});
    } else if (this.port) {
      try { this.port.postMessage(message); } catch { /* 연결이 이미 끊김 */ }
    }
  },

  cancelTab(tabId, kind = null) {
    for (const [id, entry] of this.pending) {
      if (entry.tabId === tabId && (!kind || entry.kind === kind)) this.cancel(id);
    }
  },

  /** 모든 탭의 대기 중인 요청을 취소한다(팝업의 연결 확인 요청은 남긴다). */
  cancelAllTabs() {
    for (const [id, entry] of this.pending) {
      if (entry.tabId !== null) this.cancel(id);
    }
  },

  async hello() {
    const response = await this.request({ v: 1, type: "hello", id: this.nextId("h") }, { timeout: TIMEOUT.hello });
    return {
      enabled: response.enabled === true,
      engineTitle: typeof response.engineTitle === "string" ? response.engineTitle : "Mac 기본 번역",
      version: typeof response.version === "string" ? response.version : "",
      // 구버전 SMT나 Safari 확장 앱은 웹 번역 엔진을 알리지 않는다.
      externalEngines: Array.isArray(response.externalEngines)
        ? response.externalEngines.filter((engine) => EXTERNAL_ENGINES.includes(engine))
        : [],
      aiRefine: response.aiRefine === true
    };
  }
};

// MARK: - 보이는 탭 캡처(메모리에만 잠깐 보관, 탭당 최신 1장)

const captures = new Map(); // tabId → { id, dataUrl, url, time }
let lastCaptureAt = 0;

async function captureVisible(tab) {
  // 권한 범위가 <all_urls>여도 캡처 대상은 http/https 페이지로만 제한한다.
  if (!originOf(tab.url)) throw codedError("restricted_page", "이 페이지는 캡처하지 않습니다.");
  const [active] = await api.tabs.query({ active: true, windowId: tab.windowId });
  if (!active || active.id !== tab.id) throw codedError("tab_hidden", "보이는 탭이 아니어서 이미지를 캡처하지 않았습니다.");
  const wait = lastCaptureAt + CAPTURE_MIN_INTERVAL - Date.now();
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
  lastCaptureAt = Date.now();
  let dataUrl;
  try {
    dataUrl = await api.tabs.captureVisibleTab(tab.windowId, { format: "jpeg", quality: 82 });
  } catch (error) {
    throw codedError("capture_denied", "이미지 글자 번역에는 화면 캡처 권한이 필요합니다. 툴바의 SMT 아이콘에서 '번역'을 누르세요.");
  }
  // 캡처하는 사이 탭이 바뀌었거나 다른 페이지로 이동했으면 버린다.
  const after = await api.tabs.get(tab.id);
  if (!after.active || after.windowId !== tab.windowId || after.url !== tab.url) {
    throw codedError("stale", "");
  }
  if (typeof dataUrl !== "string" || !dataUrl.startsWith("data:image/jpeg;base64,")) throw codedError("capture_failed", "캡처에 실패했습니다.");
  if (dataUrl.length > 15 * 1024 * 1024) throw codedError("image_too_large", "캡처 이미지가 너무 큽니다. 창을 줄여 주세요.");
  const id = native.nextId("cap");
  captures.set(tab.id, { id, dataUrl, url: tab.url, time: Date.now() });
  return id;
}

function takeCapture(tabId, id) {
  const entry = captures.get(tabId);
  captures.delete(tabId);
  if (!entry || entry.id !== id || Date.now() - entry.time > CAPTURE_TTL) return null;
  return entry.dataUrl;
}

// MARK: - 내용 스크립트 요청 처리

function validTexts(texts, engine) {
  const external = engine !== LOCAL_ENGINE;
  const maxTexts = external ? EXTERNAL_LIMITS.texts : LIMITS.texts;
  if (!Array.isArray(texts) || texts.length === 0 || texts.length > maxTexts) return false;
  let total = 0;
  for (const text of texts) {
    if (typeof text !== "string" || text.length > LIMITS.textLength) return false;
    total += text.length;
  }
  return total <= (external ? EXTERNAL_LIMITS.chars : LIMITS.chars);
}

/** 내용 스크립트가 쓴 엔진이 지금 설정과 같을 때만 보낸다(엔진을 바꾼 직후 늦게 온 요청은 버린다). */
function requestEngine(message, settings) {
  const engine = typeof message.engine === "string" ? message.engine : LOCAL_ENGINE;
  if (engine !== settings.engine) throw codedError("cancelled", "");
  return engine;
}

function engineTimeout(engine, local) {
  return engine === LOCAL_ENGINE ? local : TIMEOUT.external;
}

function sanitizeWarning(warning) {
  return typeof warning === "string" ? warning.slice(0, 300) : "";
}

/** Apple Intelligence 다듬기 후속 요청 항목: 키 형식·개수·길이만 확인한다(내용은 이미 화면에 그려진 값). */
function validRefineItems(items) {
  if (!Array.isArray(items) || items.length === 0 || items.length > LIMITS.refineItems) return false;
  let total = 0;
  for (const item of items) {
    if (!item || typeof item.k !== "string" || !/^[A-Za-z0-9_-]{1,32}$/.test(item.k)) return false;
    if (typeof item.o !== "string" || typeof item.d !== "string") return false;
    if (item.o.length > LIMITS.refineItemChars || item.d.length > LIMITS.refineItemChars) return false;
    total += item.o.length + item.d.length;
  }
  return total <= LIMITS.refineChars;
}

function validRegions(regions) {
  return Array.isArray(regions) && regions.length > 0 && regions.length <= LIMITS.regions && regions.every((r) =>
    r && typeof r.k === "string" && /^[A-Za-z0-9_-]{1,32}$/.test(r.k) &&
    ["x", "y", "w", "h"].every((key) => Number.isFinite(r[key])) && r.w >= 1 && r.h >= 1);
}

const LANG_CODE = /^[A-Za-z]{2,8}(-[A-Za-z0-9]{2,8}){0,2}$/;

/** 번역 응답의 조각별 인식 언어: 언어 코드 문자열, "unknown"(판별 못함), null(글자 없음·구버전)만 통과시킨다. */
function sanitizeLangs(langs, expectedLength) {
  if (!Array.isArray(langs) || langs.length !== expectedLength) return null;
  return langs.map((lang) => {
    if (lang === null) return null;
    if (lang === "unknown") return "unknown";
    return typeof lang === "string" && LANG_CODE.test(lang) ? lang : null;
  });
}

/** OCR 이미지별 인식 언어 개수: {언어코드|"unknown": 양의 정수} 형태만 통과시킨다. */
function sanitizeLangCounts(langs) {
  const result = {};
  if (!langs || typeof langs !== "object") return result;
  for (const [key, value] of Object.entries(langs)) {
    if (key !== "unknown" && !LANG_CODE.test(key)) continue;
    const n = Number(value);
    if (Number.isInteger(n) && n > 0 && n <= LIMITS.texts) result[key] = n;
  }
  return result;
}

// 정규화 좌표(0~1)의 반올림 오차만 허용하고 그 밖의 값은 잘라낸다(이미지 밖까지 칠하는 것을 막는다).
const GLYPH_COORD_TOLERANCE = 0.01;

function clampGlyphCoord(n) {
  if (n < 0) return n >= -GLYPH_COORD_TOLERANCE ? 0 : null;
  if (n > 1) return n <= 1 + GLYPH_COORD_TOLERANCE ? 1 : null;
  return n;
}

/** 네이티브가 보낸 글자 상자(g)들: [x,y,w,h] 정규화 좌표 4개, w/h는 양수인 항목만 통과시키고
 *  이미지당·응답 전체 개수 상한을 넘으면 자른다. 형식이 틀리거나 비어 있으면 빈 배열을 돌려주고
 *  (마스킹 생략으로 이어짐) 문단 전체를 가리는 등의 값을 지어내지 않는다. */
function sanitizeGlyphs(g, remainingBudget) {
  if (!Array.isArray(g) || remainingBudget <= 0) return [];
  const result = [];
  for (const entry of g) {
    if (result.length >= LIMITS.glyphsPerItem || result.length >= remainingBudget) break;
    if (!Array.isArray(entry) || entry.length !== 4 || !entry.every((n) => Number.isFinite(n))) continue;
    const x = clampGlyphCoord(entry[0]);
    const y = clampGlyphCoord(entry[1]);
    const w = clampGlyphCoord(entry[2]);
    const h = clampGlyphCoord(entry[3]);
    if (x === null || y === null || w === null || h === null || w <= 0 || h <= 0) continue;
    result.push([x, y, w, h]);
  }
  return result;
}

function sanitizeImages(images) {
  if (!Array.isArray(images)) return [];
  const hex = /^#[0-9A-Fa-f]{6}$/;
  let glyphBudget = LIMITS.glyphsTotal;
  return images.slice(0, LIMITS.regions).map((image) => ({
    k: typeof image?.k === "string" ? image.k : "",
    items: (Array.isArray(image?.items) ? image.items : []).filter((item) =>
      item && typeof item.t === "string" && item.t.length <= LIMITS.textLength &&
      ["x", "y", "w", "h"].every((key) => Number.isFinite(item[key]) && item[key] >= -0.5 && item[key] <= 1.5)
    ).map((item) => {
      const g = sanitizeGlyphs(item.g, glyphBudget);
      glyphBudget -= g.length;
      return {
        x: item.x, y: item.y, w: item.w, h: item.h, t: item.t,
        bg: hex.test(item.bg) ? item.bg : "#FFFFFF",
        fg: hex.test(item.fg) ? item.fg : "#000000",
        // 다듬기 후속 요청에만 쓰는 인식 원문(짧게 자름). 저장하지 않고 이번 패스에서만 메모리에서 쓴다.
        ...(typeof item.o === "string" ? { o: item.o.slice(0, 700) } : {}),
        ...(g.length ? { g } : {})
      };
    }),
    langs: sanitizeLangCounts(image?.langs)
  }));
}

async function handleContent(message, sender) {
  const tab = sender.tab;
  if (message.cmd !== "cancel" && !originOf(sender.url || tab.url)) {
    throw codedError("restricted_page", "이 페이지는 번역하지 않습니다.");
  }
  // 요청을 받은 시점의 세대. 처리하는 사이 전역 끄기가 있었으면 결과를 돌려주지 않는다(내용 스크립트도 세대로 한 번 더 거른다).
  const epoch = control.epoch;
  const settings = await loadSettings();
  // 전체 권한이 이벤트 없이 줄어든 경우(예: 사이트 접근을 일부 사이트로 변경)에도 자동 번역 중인 페이지의 다음 요청에서 전역으로 멈춘다.
  if (message.cmd !== "cancel" && settings.automaticEnabled && control.armed && !(await hasGlobalGrant())) {
    await globalStop();
    throw codedError("cancelled", "");
  }
  switch (message.cmd) {
    case "translate": {
      if (!settings.consent) throw codedError("consent_required", "툴바의 SMT 아이콘에서 먼저 동의해 주세요.");
      const engine = requestEngine(message, settings);
      if (!TARGETS.includes(message.target) || !validTexts(message.texts, engine)) throw codedError("bad_request", "잘못된 번역 요청입니다.");
      const response = await native.request(
        { v: 1, type: "translate", id: native.nextId("t"), target: message.target, texts: message.texts, engine },
        { timeout: engineTimeout(engine, TIMEOUT.text), tabId: tab.id, kind: "text" });
      if (epoch !== control.epoch) throw codedError("cancelled", "");
      const texts = Array.isArray(response.texts) && response.texts.length === message.texts.length
        ? response.texts.map((t) => (typeof t === "string" ? t : null))
        : null;
      if (!texts) throw codedError("bad_response", "SMT 응답 형식이 올바르지 않습니다.");
      return { ok: true, texts, missing: Array.isArray(response.missing) ? response.missing.filter((m) => typeof m === "string") : [],
               langs: sanitizeLangs(response.langs, texts.length), warning: sanitizeWarning(response.warning),
               aiRefine: response.aiRefine === true };
    }
    case "capture": {
      if (!settings.consent) throw codedError("consent_required", "툴바의 SMT 아이콘에서 먼저 동의해 주세요.");
      const captureId = await captureVisible(tab);
      if (epoch !== control.epoch) {
        captures.delete(tab.id);
        throw codedError("cancelled", "");
      }
      return { ok: true, captureId };
    }
    case "ocr": {
      if (!settings.consent) throw codedError("consent_required", "툴바의 SMT 아이콘에서 먼저 동의해 주세요.");
      const viewport = message.viewport;
      const engine = requestEngine(message, settings);
      if (!TARGETS.includes(message.target) || !validRegions(message.regions) ||
          !viewport || !Number.isFinite(viewport.w) || !Number.isFinite(viewport.h)) {
        throw codedError("bad_request", "잘못된 이미지 요청입니다.");
      }
      const image = takeCapture(tab.id, message.captureId);
      if (!image) throw codedError("stale", "");
      const response = await native.request(
        { v: 1, type: "ocr", id: native.nextId("o"), target: message.target, image,
          viewport: { w: viewport.w, h: viewport.h }, regions: message.regions, engine },
        { timeout: engineTimeout(engine, TIMEOUT.ocr), tabId: tab.id, kind: "ocr" });
      if (epoch !== control.epoch) throw codedError("cancelled", "");
      return { ok: true, images: sanitizeImages(response.images),
               missing: Array.isArray(response.missing) ? response.missing.filter((m) => typeof m === "string") : [],
               warning: sanitizeWarning(response.warning), aiRefine: response.aiRefine === true };
    }
    case "refine": {
      if (!settings.consent) throw codedError("consent_required", "툴바의 SMT 아이콘에서 먼저 동의해 주세요.");
      const engine = requestEngine(message, settings);
      if (engine !== LOCAL_ENGINE) throw codedError("bad_request", "다듬기는 Mac 기본 번역에서만 지원합니다.");
      if (!TARGETS.includes(message.target) || !validRefineItems(message.items)) {
        throw codedError("bad_request", "잘못된 다듬기 요청입니다.");
      }
      const response = await native.request(
        { v: 1, type: "refine", id: native.nextId("r"), target: message.target, items: message.items, engine },
        { timeout: TIMEOUT.refine, tabId: tab.id, kind: "refine" });
      if (epoch !== control.epoch) throw codedError("cancelled", "");
      const items = Array.isArray(response.items)
        ? response.items.filter((it) => it && typeof it.k === "string" && typeof it.t === "string" && it.t.length <= LIMITS.textLength)
        : [];
      return { ok: true, items };
    }
    case "cancel": {
      captures.delete(tab.id);
      native.cancelTab(tab.id, message.kind === "ocr" || message.kind === "text" || message.kind === "refine" ? message.kind : null);
      return { ok: true };
    }
    default:
      throw codedError("bad_request", "알 수 없는 요청입니다.");
  }
}

// MARK: - 팝업 요청 처리

/** 지금 탭의 http/https 출처가 기대한 출처와 같을 때만 내용 스크립트를 넣는다(파일·브라우저 내부 페이지 제외). */
async function injectContent(tabId, origin) {
  let current = null;
  try { current = originOf((await api.tabs.get(tabId)).url); } catch { current = null; }
  if (!current || current !== origin) {
    throw codedError("restricted_page", "이 페이지는 브라우저 정책상 확장이 접근할 수 없습니다.");
  }
  try {
    await api.scripting.executeScript({ target: { tabId }, files: ["content.js"] });
  } catch {
    throw codedError("restricted_page", "이 페이지는 브라우저 정책상 확장이 접근할 수 없습니다.");
  }
}

/** 탭에 메시지를 보낸다. 내용 스크립트가 없거나 응답이 없으면(멈춘 페이지 포함) null. */
async function sendToTab(tabId, message) {
  let timer = 0;
  try {
    return await Promise.race([
      Promise.resolve(api.tabs.sendMessage(tabId, message)),
      new Promise((resolve) => { timer = setTimeout(() => resolve(null), TAB_MESSAGE_TIMEOUT); })
    ]);
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/** 세대가 그대로일 때만 보낸다. 확인과 보내기 사이에 await가 없어서, 그 뒤에 들어온 끄기는 이 메시지보다 늦게 도착한다. */
function sendIfCurrent(tabId, epoch, message) {
  if (epoch !== control.epoch) return Promise.resolve(null);
  return sendToTab(tabId, message);
}

function configureMessage(settings, epoch, extra = {}) {
  return {
    cmd: "configure",
    epoch,
    auto: settings.automaticEnabled === true,
    target: settings.target,
    engine: settings.engine,
    images: settings.images,
    ...extra
  };
}

async function queryAllTabs() {
  try {
    return (await api.tabs.query({})).filter((tab) => Number.isInteger(tab.id));
  } catch {
    return [];
  }
}

/** 전역 자동 번역이 켜진 상태에서 이 탭에 자동 번역을 적용한다(필요하면 주입). 주입 전후로 세대·동의·자동·권한을 다시 확인한다. */
async function applyAutoToTab(tabId, epoch) {
  let origin = null;
  try { origin = originOf((await api.tabs.get(tabId)).url); } catch { return null; }
  if (!origin || !(await autoStillAllowed(epoch, origin))) return null;
  const present = await sendToTab(tabId, { cmd: "state" });
  if (!present) {
    try {
      await injectContent(tabId, origin);
    } catch {
      return null; // 제한된 페이지 등: 조용히 건너뛴다(팝업에서 상태를 볼 수 있다).
    }
  }
  // 주입을 기다리는 사이 원문 보기·권한 철회·설정 변경이 있었을 수 있으므로 보내기 직전에 다시 확인한다.
  const settings = await autoStillAllowed(epoch, origin);
  if (!settings) return null;
  return sendIfCurrent(tabId, epoch, configureMessage(settings, epoch));
}

/** 이미 열려 있는 http/https 탭(exceptTabId 제외)에도 전역 자동 번역·언어·이미지 설정을 반영한다. */
async function configureAllTabs(epoch, exceptTabId = null) {
  const tabs = await queryAllTabs();
  await Promise.all(tabs.filter((tab) => tab.id !== exceptTabId).map((tab) => applyAutoToTab(tab.id, epoch)));
}

/** 전역 자동 번역을 끈다. 요청 즉시 세대를 올려 진행 중인 모든 켜기·설정·주입 흐름이 더는 보내지 않게 하고,
 * false를 저장한 뒤 열려 있는 모든 탭의 요청·캡처를 취소하고 원문 보기를 보내 그 응답까지 기다린다.
 * 내용 스크립트가 없는 탭(보호된 페이지 포함)은 조용히 건너뛴다. 반환: { epoch, pages: Map(tabId → 상태) } */
function globalStop() {
  const epoch = nextEpoch();
  control.armed = false;
  native.cancelAllTabs();
  captures.clear();
  return serially(async () => {
    await api.storage.local.set({ automaticEnabled: false }).catch(() => {});
    const tabs = await queryAllTabs();
    const pages = new Map();
    await Promise.all(tabs.map(async (tab) => {
      captures.delete(tab.id);
      native.cancelTab(tab.id);
      pages.set(tab.id, await sendToTab(tab.id, { cmd: "toggleOriginal", epoch }));
    }));
    captures.clear();
    return { epoch, pages };
  });
}

/** 저장된 상태와 실제 권한을 맞춘다(워커 시작·브라우저 시작·설치/업데이트·팝업 열기). 켜짐인데 동의나 전체 권한이
 * 없으면 false를 저장하고 전역으로 끈다. 반환: 지금 전역 자동 번역을 이어 가도 되는지. */
async function reconcile() {
  const epoch = control.epoch;
  const verdict = await serially(async () => {
    const settings = await loadSettings();
    if (!settings.automaticEnabled) {
      control.armed = false;
      return "off";
    }
    const ok = settings.consent && (await hasGlobalGrant());
    if (epoch !== control.epoch) return "off"; // 그사이 끄기가 있었다
    if (ok) {
      control.armed = true;
      return "on";
    }
    return "stop";
  });
  if (verdict === "stop") await globalStop();
  return verdict === "on";
}

/** 언어·이미지 설정을 바꾼 뒤: 현재 탭과(전역이 실제로 유효하면) 다른 탭에 반영한다. 저장된 켜짐 값만으로 자동을 켜지 않는다. */
async function reconfigure(tabId, origin) {
  const epoch = control.epoch;
  const latest = await loadSettings();
  const global = latest.automaticEnabled ? await autoStillAllowed(epoch) : null;
  let page = null;
  if (tabId !== null && origin) {
    const tabAuto = global !== null && (await originPermitted(origin));
    page = await sendIfCurrent(tabId, epoch, configureMessage({ ...latest, automaticEnabled: tabAuto }, epoch));
  }
  if (global && epoch === control.epoch) configureAllTabs(epoch, tabId).catch(() => {});
  return page;
}

async function handlePopup(message) {
  let settings = await loadSettings();
  const tabId = Number.isInteger(message.tabId) ? message.tabId : null;
  let origin = null;
  if (tabId !== null) {
    try { origin = originOf((await api.tabs.get(tabId)).url); } catch { origin = null; }
  }
  switch (message.cmd) {
    case "popupState": {
      // 저장값과 실제 권한이 어긋나 있으면(예: 브라우저 설정에서 권한 철회) 여기서 바로 끈다.
      await reconcile();
      settings = await loadSettings();
      const grant = await hasGlobalGrant();
      // 동의 전에는 SMT를 실행하거나 연결하지 않는다.
      let engine = { ok: false, message: "동의하면 SMT에 연결합니다." };
      if (settings.consent) {
        try {
          engine = { ok: true, ...(await native.hello()) };
        } catch (error) {
          engine = { ok: false, message: error.message };
        }
      }
      const page = tabId !== null && origin ? await sendToTab(tabId, { cmd: "state" }) : null;
      return { ok: true, settings, origin, engine, page, grant, safari: IS_SAFARI, externalEngines: EXTERNAL_ENGINES };
    }
    case "consent": {
      await api.storage.local.set({ consent: true });
      return { ok: true };
    }
    case "setTarget": {
      if (!TARGETS.includes(message.target)) throw codedError("bad_request", "지원하지 않는 언어입니다.");
      await api.storage.local.set({ target: message.target });
      return { ok: true, page: await reconfigure(tabId, origin) };
    }
    case "setEngine": {
      // 웹 번역 엔진은 팝업에서 사용자가 그 엔진의 전송 안내를 보고 동의(consent: true)했거나 이미 동의한 경우에만 고른다.
      const engine = message.engine;
      if (engine !== LOCAL_ENGINE && !EXTERNAL_ENGINES.includes(engine)) {
        throw codedError("bad_request", IS_SAFARI ? "Safari에서는 Mac 기본 번역만 쓸 수 있습니다." : "지원하지 않는 번역 엔진입니다.");
      }
      const consents = settings.engineConsents.slice();
      if (engine !== LOCAL_ENGINE && !consents.includes(engine)) {
        if (message.consent !== true) throw codedError("consent_required", "이 번역 엔진의 전송 안내에 먼저 동의해 주세요.");
        consents.push(engine);
      }
      await api.storage.local.set({ engine, engineConsents: consents });
      // 엔진이 바뀌면 진행 중인 요청은 이전 엔진의 것이므로 모두 취소한다.
      native.cancelAllTabs();
      return { ok: true, page: await reconfigure(tabId, origin) };
    }
    case "revokeEngine": {
      // 지금 고른 웹 번역 엔진의 동의를 철회하고 Mac 기본 번역으로 돌아간다.
      const consents = settings.engineConsents.filter((engine) => engine !== message.engine);
      await api.storage.local.set({ engine: LOCAL_ENGINE, engineConsents: consents });
      native.cancelAllTabs();
      return { ok: true, page: await reconfigure(tabId, origin) };
    }
    case "setImages": {
      await api.storage.local.set({ images: message.enabled === true });
      return { ok: true, page: await reconfigure(tabId, origin) };
    }
    case "translateNow": {
      // 팝업이 보낸 automatic은 '켜 달라'는 뜻일 뿐이다. 켜짐(true)은 배경이 전체 권한을 직접 확인했을 때만 저장한다.
      if (!settings.consent) throw codedError("consent_required", "먼저 동의해 주세요.");
      if (tabId === null) throw codedError("bad_request", "탭을 찾을 수 없습니다.");
      let epoch = control.epoch;
      const wantAuto = message.automatic === true;
      const outcome = await serially(async () => {
        if (epoch !== control.epoch) return "superseded";
        const granted = wantAuto && (await hasGlobalGrant());
        if (epoch !== control.epoch) return "superseded";
        if (granted) {
          control.armed = true;
          await api.storage.local.set({ automaticEnabled: true });
          return "auto";
        }
        return (await loadSettings()).automaticEnabled ? "stop" : "manual";
      });
      if (outcome === "superseded") return { ok: true, page: null, automatic: false, superseded: true };
      const automatic = outcome === "auto";
      // 거절·미허용인데 이전 켜짐이 남아 있으면 false를 저장하고 전역으로 멈춘 뒤, 이 페이지만 한 번 번역한다.
      if (outcome === "stop") epoch = (await globalStop()).epoch;
      if (!origin) {
        // 보호된 페이지에서 눌러도 전역 자동 번역 켜기는 유지하고 다른 http/https 탭에만 반영한다.
        if (automatic && epoch === control.epoch) configureAllTabs(epoch, tabId).catch(() => {});
        return { ok: true, page: null, automatic, restricted: true };
      }
      try {
        await injectContent(tabId, origin);
      } catch (error) {
        if (automatic && epoch === control.epoch) configureAllTabs(epoch, tabId).catch(() => {});
        return { ok: true, page: null, automatic, restricted: true, message: error.message };
      }
      // 주입을 기다리는 사이 '원문 보기'·철회가 있었으면 세대가 바뀌므로 아무것도 시작하지 않는다.
      const latest = await loadSettings();
      // 이 탭의 자동 번역은 이 사이트 권한까지 있을 때만(Safari 사이트별 허용). 없으면 이 페이지는 수동 한 번만.
      const tabAuto = automatic && latest.automaticEnabled && (await originPermitted(origin));
      if (epoch !== control.epoch || !latest.consent) return { ok: true, page: null, automatic: false, superseded: true };
      const next = { ...latest, automaticEnabled: tabAuto };
      const page = await sendIfCurrent(tabId, epoch, configureMessage(next, epoch, { translateNow: true }));
      if (automatic && epoch === control.epoch) configureAllTabs(epoch, tabId).catch(() => {});
      return { ok: true, page, automatic };
    }
    case "toggleOriginal": {
      // 원문 보기는 전역 자동 번역을 끄고, 열려 있는 모든 탭에서 진행 중인 요청을 취소하며 각 탭을 원문으로 되돌린다.
      // 현재 탭이 번역된 적이 없거나 보호된 페이지여도 전역 끄기 자체는 항상 성공한다.
      const { pages } = await globalStop();
      return { ok: true, page: tabId !== null ? pages.get(tabId) ?? null : null };
    }
    default:
      throw codedError("bad_request", "알 수 없는 요청입니다.");
  }
}

api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || typeof message !== "object" || typeof message.cmd !== "string") return false;
  if (sender.id !== api.runtime.id) return false;
  const reply = (promise) => {
    promise.then(sendResponse, (error) => sendResponse({ ok: false, code: error.code || "error", message: error.message || "" }));
    return true;
  };
  if (sender.tab) {
    // 내용 스크립트는 최상위 프레임에만 넣는다.
    if (typeof sender.frameId === "number" && sender.frameId !== 0) return false;
    return reply(handleContent(message, sender));
  }
  const extensionBase = api.runtime.getURL("");
  if (typeof sender.url === "string" && sender.url.startsWith(extensionBase)) {
    return reply(handlePopup(message));
  }
  return false;
});

// MARK: - 탭 수명: 이동·닫기 때 그 탭의 요청만 취소, 전역 자동 번역이 유효하면 내용 스크립트를 넣는다.

api.tabs.onUpdated.addListener((tabId, info, tab) => {
  if (info.status === "loading") {
    captures.delete(tabId);
    native.cancelTab(tabId);
  }
  if (info.status !== "complete" || !tab?.url || !originOf(tab.url)) return;
  applyAutoToTab(tabId, control.epoch).catch(() => {});
});

api.tabs.onRemoved.addListener((tabId) => {
  captures.delete(tabId);
  native.cancelTab(tabId);
});

// 탭을 바꿔 들어갈 때, 전역 자동 번역이 유효한데 아직 주입·설정되지 않았으면(예: 켜기 전부터 열려 있던 탭) 이어받는다.
api.tabs.onActivated.addListener(({ tabId }) => {
  applyAutoToTab(tabId, control.epoch).catch(() => {});
});

// 권한 철회(어느 호스트든)는 전역 자동 번역을 끄고 모든 탭을 원문으로 되돌린다. 다시 켜려면 번역 버튼을 누른다.
if (api.permissions?.onRemoved) {
  api.permissions.onRemoved.addListener((removed) => {
    if ((removed?.origins || []).length) globalStop().catch(() => {});
  });
}

// 동의 해제나 (이 워커 밖에서의) 자동 번역 해제도 모든 탭을 멈춘다. 자기 끄기는 armed가 이미 false라 다시 처리하지 않는다.
api.storage.onChanged.addListener((changes, area) => {
  if (area !== "local") return;
  const consentOff = changes.consent && changes.consent.oldValue === true && changes.consent.newValue !== true;
  const autoOff = changes.automaticEnabled && changes.automaticEnabled.newValue !== true;
  if (consentOff || (autoOff && control.armed)) globalStop().catch(() => {});
});

// 브라우저 시작(복원된 탭 포함): 저장 상태와 실제 권한을 맞춘 뒤 유효할 때만 각 창의 보이는 탭에 적용한다.
// 나머지 탭은 활성화·로드 완료 이벤트 때 처리한다(탭별 반복 확인 없음).
api.runtime.onStartup?.addListener(async () => {
  if (!(await reconcile())) return;
  const epoch = control.epoch;
  let active = [];
  try { active = await api.tabs.query({ active: true }); } catch { active = []; }
  await Promise.all(active.filter((tab) => Number.isInteger(tab.id)).map((tab) => applyAutoToTab(tab.id, epoch)));
});

// 워커가 깨어날 때마다(설치·업데이트 포함) 저장 상태를 실제 권한에 맞춘다. 이전 버전의 http/https 권한만 있던 켜짐은 여기서 꺼진다.
reconcile().catch(() => {});
