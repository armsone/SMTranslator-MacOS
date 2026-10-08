"use strict";
// SMT 웹 번역 — 백그라운드(Chrome·Whale 서비스 워커 / Safari 이벤트 페이지 공용).
// - 페이지 글자·보이는 탭 캡처는 이 Mac의 SMT 엔진(Chrome·Whale: 네이티브 메시징 도우미, Safari: 확장 앱)으로만 보낸다.
// - 저장하는 값: 동의 여부, 번역 언어, 이미지 번역 여부, 자동 번역을 켠 사이트 출처. 페이지 내용은 저장하지 않는다.
// - 요청마다 ID를 붙여 탭별로 추적하고, 탭 이동·닫기·스크롤(이미지) 때 그 탭의 요청만 취소한다.

const api = globalThis.browser ?? globalThis.chrome;
const IS_SAFARI = api.runtime.getURL("").startsWith("safari-web-extension:");
const HOST_NAME = "com.local.screentranslator.browser";
const SAFARI_APP_ID = "com.local.screentranslator";
const TARGETS = ["ko", "en", "ja", "zh-Hans"];
const LIMITS = { texts: 150, textLength: 5000, chars: 40000, regions: 16, sites: 500 };
const TIMEOUT = { hello: 15000, text: 60000, ocr: 90000 };
const CAPTURE_MIN_INTERVAL = 700; // Chrome captureVisibleTab 호출 빈도 제한(초당 2회) 아래로 유지
const CAPTURE_TTL = 15000;
const DEFAULTS = { consent: false, target: "ko", images: true, sites: [] };

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
  return {
    consent: stored.consent === true,
    target: TARGETS.includes(stored.target) ? stored.target : "ko",
    images: stored.images !== false,
    sites: Array.isArray(stored.sites) ? stored.sites.filter((s) => typeof s === "string").slice(0, LIMITS.sites) : []
  };
}

// MARK: - 네이티브 연결

function describeNativeFailure(raw) {
  const text = String(raw || "");
  if (IS_SAFARI) {
    return "SMT 확장 앱에 연결하지 못했습니다. SMT를 응용 프로그램 폴더에 설치해 한 번 실행하고 Safari 설정에서 확장을 켜 주세요.";
  }
  if (/not found/i.test(text)) {
    return "SMT 연결이 등록되지 않았습니다. SMT 메뉴 막대 › 브라우저 번역…에서 이 브라우저의 '준비'를 누르세요.";
  }
  if (/forbidden/i.test(text)) {
    return "이 확장은 SMT 연결 허용 목록에 없습니다. SMT의 '브라우저 번역…'에서 다시 준비한 뒤 확장 폴더를 다시 로드하세요.";
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

  async hello() {
    const response = await this.request({ v: 1, type: "hello", id: this.nextId("h") }, { timeout: TIMEOUT.hello });
    return {
      enabled: response.enabled === true,
      engineTitle: typeof response.engineTitle === "string" ? response.engineTitle : "Mac 기본 번역",
      version: typeof response.version === "string" ? response.version : ""
    };
  }
};

// MARK: - 보이는 탭 캡처(메모리에만 잠깐 보관, 탭당 최신 1장)

const captures = new Map(); // tabId → { id, dataUrl, url, time }
let lastCaptureAt = 0;

async function captureVisible(tab) {
  const [active] = await api.tabs.query({ active: true, windowId: tab.windowId });
  if (!active || active.id !== tab.id) throw codedError("tab_hidden", "보이는 탭이 아니어서 이미지를 캡처하지 않았습니다.");
  const wait = lastCaptureAt + CAPTURE_MIN_INTERVAL - Date.now();
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
  lastCaptureAt = Date.now();
  let dataUrl;
  try {
    dataUrl = await api.tabs.captureVisibleTab(tab.windowId, { format: "jpeg", quality: 82 });
  } catch (error) {
    throw codedError("capture_denied", "이미지 글자 번역에는 화면 캡처 권한이 필요합니다. 툴바의 SMT 아이콘에서 '이 페이지 번역'을 누르세요.");
  }
  // 캡처하는 사이 탭이 바뀌었거나 다른 페이지로 이동했으면 버린다.
  const after = await api.tabs.get(tab.id);
  if (!after.active || after.windowId !== tab.windowId || (tab.url && after.url && after.url !== tab.url)) {
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

function validTexts(texts) {
  if (!Array.isArray(texts) || texts.length === 0 || texts.length > LIMITS.texts) return false;
  let total = 0;
  for (const text of texts) {
    if (typeof text !== "string" || text.length > LIMITS.textLength) return false;
    total += text.length;
  }
  return total <= LIMITS.chars;
}

function validRegions(regions) {
  return Array.isArray(regions) && regions.length > 0 && regions.length <= LIMITS.regions && regions.every((r) =>
    r && typeof r.k === "string" && /^[A-Za-z0-9_-]{1,32}$/.test(r.k) &&
    ["x", "y", "w", "h"].every((key) => Number.isFinite(r[key])) && r.w >= 1 && r.h >= 1);
}

function sanitizeImages(images) {
  if (!Array.isArray(images)) return [];
  const hex = /^#[0-9A-Fa-f]{6}$/;
  return images.slice(0, LIMITS.regions).map((image) => ({
    k: typeof image?.k === "string" ? image.k : "",
    items: (Array.isArray(image?.items) ? image.items : []).filter((item) =>
      item && typeof item.t === "string" && item.t.length <= LIMITS.textLength &&
      ["x", "y", "w", "h"].every((key) => Number.isFinite(item[key]) && item[key] >= -0.5 && item[key] <= 1.5)
    ).map((item) => ({
      x: item.x, y: item.y, w: item.w, h: item.h, t: item.t,
      bg: hex.test(item.bg) ? item.bg : "#FFFFFF",
      fg: hex.test(item.fg) ? item.fg : "#000000"
    }))
  }));
}

async function handleContent(message, sender) {
  const tab = sender.tab;
  const settings = await loadSettings();
  switch (message.cmd) {
    case "translate": {
      if (!settings.consent) throw codedError("consent_required", "툴바의 SMT 아이콘에서 먼저 동의해 주세요.");
      if (!TARGETS.includes(message.target) || !validTexts(message.texts)) throw codedError("bad_request", "잘못된 번역 요청입니다.");
      const response = await native.request(
        { v: 1, type: "translate", id: native.nextId("t"), target: message.target, texts: message.texts },
        { timeout: TIMEOUT.text, tabId: tab.id, kind: "text" });
      const texts = Array.isArray(response.texts) && response.texts.length === message.texts.length
        ? response.texts.map((t) => (typeof t === "string" ? t : null))
        : null;
      if (!texts) throw codedError("bad_response", "SMT 응답 형식이 올바르지 않습니다.");
      return { ok: true, texts, missing: Array.isArray(response.missing) ? response.missing.filter((m) => typeof m === "string") : [] };
    }
    case "capture": {
      if (!settings.consent) throw codedError("consent_required", "툴바의 SMT 아이콘에서 먼저 동의해 주세요.");
      return { ok: true, captureId: await captureVisible(tab) };
    }
    case "ocr": {
      if (!settings.consent) throw codedError("consent_required", "툴바의 SMT 아이콘에서 먼저 동의해 주세요.");
      const viewport = message.viewport;
      if (!TARGETS.includes(message.target) || !validRegions(message.regions) ||
          !viewport || !Number.isFinite(viewport.w) || !Number.isFinite(viewport.h)) {
        throw codedError("bad_request", "잘못된 이미지 요청입니다.");
      }
      const image = takeCapture(tab.id, message.captureId);
      if (!image) throw codedError("stale", "");
      const response = await native.request(
        { v: 1, type: "ocr", id: native.nextId("o"), target: message.target, image,
          viewport: { w: viewport.w, h: viewport.h }, regions: message.regions },
        { timeout: TIMEOUT.ocr, tabId: tab.id, kind: "ocr" });
      return { ok: true, images: sanitizeImages(response.images),
               missing: Array.isArray(response.missing) ? response.missing.filter((m) => typeof m === "string") : [] };
    }
    case "cancel": {
      captures.delete(tab.id);
      native.cancelTab(tab.id, message.kind === "ocr" || message.kind === "text" ? message.kind : null);
      return { ok: true };
    }
    default:
      throw codedError("bad_request", "알 수 없는 요청입니다.");
  }
}

// MARK: - 팝업 요청 처리

async function injectContent(tabId) {
  try {
    await api.scripting.executeScript({ target: { tabId }, files: ["content.js"] });
  } catch {
    throw codedError("restricted_page", "이 페이지는 브라우저 정책상 확장이 접근할 수 없습니다.");
  }
}

async function sendToTab(tabId, message) {
  try {
    return await api.tabs.sendMessage(tabId, message);
  } catch {
    return null;
  }
}

async function configureTab(tabId, origin, settings, extra = {}) {
  return sendToTab(tabId, {
    cmd: "configure",
    auto: !!origin && settings.sites.includes(origin),
    target: settings.target,
    images: settings.images,
    ...extra
  });
}

async function handlePopup(message) {
  const settings = await loadSettings();
  const tabId = Number.isInteger(message.tabId) ? message.tabId : null;
  let origin = null;
  if (tabId !== null) {
    try { origin = originOf((await api.tabs.get(tabId)).url); } catch { origin = null; }
  }
  switch (message.cmd) {
    case "popupState": {
      // 동의 전에는 SMT를 실행하거나 연결하지 않는다.
      let engine = { ok: false, message: "동의하면 SMT에 연결합니다." };
      if (settings.consent) {
        try {
          engine = { ok: true, ...(await native.hello()) };
        } catch (error) {
          engine = { ok: false, message: error.message };
        }
      }
      const permitted = origin ? await api.permissions.contains({ origins: [`${origin}/*`] }).catch(() => false) : false;
      const page = tabId !== null ? await sendToTab(tabId, { cmd: "state" }) : null;
      return { ok: true, settings: { ...settings, sites: undefined }, origin,
               siteEnabled: !!origin && settings.sites.includes(origin), permitted, engine, page, safari: IS_SAFARI };
    }
    case "consent": {
      await api.storage.local.set({ consent: true });
      return { ok: true };
    }
    case "setTarget": {
      if (!TARGETS.includes(message.target)) throw codedError("bad_request", "지원하지 않는 언어입니다.");
      await api.storage.local.set({ target: message.target });
      if (tabId !== null) await configureTab(tabId, origin, { ...settings, target: message.target });
      return { ok: true };
    }
    case "setImages": {
      await api.storage.local.set({ images: message.enabled === true });
      if (tabId !== null) await configureTab(tabId, origin, { ...settings, images: message.enabled === true });
      return { ok: true };
    }
    case "setSite": {
      if (!origin || tabId === null) throw codedError("bad_request", "이 페이지에서는 자동 번역을 켤 수 없습니다.");
      let sites = settings.sites.filter((s) => s !== origin);
      if (message.enabled === true) {
        if (!settings.consent) throw codedError("consent_required", "먼저 동의해 주세요.");
        if (!(await api.permissions.contains({ origins: [`${origin}/*`] }))) {
          throw codedError("permission_required", "이 사이트 접근 권한이 없어 자동 번역을 켜지 않았습니다.");
        }
        sites = [origin, ...sites].slice(0, LIMITS.sites);
      }
      await api.storage.local.set({ sites });
      const next = { ...settings, sites };
      if (message.enabled === true) {
        await injectContent(tabId);
        await configureTab(tabId, origin, next);
      } else {
        await configureTab(tabId, origin, next);
      }
      return { ok: true };
    }
    case "translateNow": {
      if (!settings.consent) throw codedError("consent_required", "먼저 동의해 주세요.");
      if (tabId === null) throw codedError("bad_request", "탭을 찾을 수 없습니다.");
      await injectContent(tabId);
      return { ok: true, page: await configureTab(tabId, origin, settings, { translateNow: true }) };
    }
    case "toggleOriginal": {
      if (tabId === null) throw codedError("bad_request", "탭을 찾을 수 없습니다.");
      const page = await sendToTab(tabId, { cmd: "toggleOriginal" });
      if (!page) throw codedError("not_translated", "이 페이지는 아직 번역하지 않았습니다.");
      return { ok: true, page };
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

// MARK: - 탭 수명: 이동·닫기 때 그 탭의 요청만 취소, 자동 번역 사이트면 내용 스크립트를 넣는다.

api.tabs.onUpdated.addListener(async (tabId, info, tab) => {
  if (info.status === "loading") {
    captures.delete(tabId);
    native.cancelTab(tabId);
  }
  if (info.status !== "complete" || !tab?.url) return;
  const origin = originOf(tab.url);
  if (!origin) return;
  const settings = await loadSettings();
  if (!settings.consent || !settings.sites.includes(origin)) return;
  const permitted = await api.permissions.contains({ origins: [`${origin}/*`] }).catch(() => false);
  if (!permitted) return;
  try {
    await injectContent(tabId);
    await configureTab(tabId, origin, settings);
  } catch {
    // 제한된 페이지 등: 조용히 건너뛴다(팝업에서 상태를 볼 수 있다).
  }
});

api.tabs.onRemoved.addListener((tabId) => {
  captures.delete(tabId);
  native.cancelTab(tabId);
});
