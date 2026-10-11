"use strict";
// Barobogi 웹 번역 — 백그라운드(Chrome·Whale 서비스 워커 / Safari 이벤트 페이지 공용).
// - 페이지 글자·보이는 탭 캡처는 이 Mac의 Barobogi 엔진(Chrome·Whale: 네이티브 메시징 도우미, Safari: 확장 앱)으로만 보낸다.
//   기본 번역 엔진은 Mac 기본 번역(기기 내)이다. Chrome·Whale에서 사용자가 웹 번역 엔진(DeepL·Google·Papago)을 따로 고르고
//   그 엔진에 동의한 경우에만 Barobogi가 글자(이미지는 Mac에서 인식한 글자)를 그 서비스의 공식 웹페이지로 보낸다. Safari는 Mac 기본만.
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
                 refineItems: 16, refineItemChars: 700, refineChars: 4000, refineContextChars: 300, refineContextTotal: 1200 };
// 웹 번역 엔진은 Barobogi가 항목마다 차례로 공식 페이지에 넣으므로 요청을 작게 하고 오래 기다린다(페이지 확인을 사용자가 할 시간 포함).
// DeepL은 네이티브가 입력 한도(1400 UTF-16, 식별자 포함) 안에서 여러 항목을 묶어 보내므로 항목 수만 120까지 받는다
// (내용 스크립트 MAX_EXTERNAL_UNITS·네이티브 BrowserRequest.maxDeepLTexts와 같음). 전체 글자 상한은 같다.
const EXTERNAL_LIMITS = { texts: 12, deeplTexts: 120, chars: 15000 };
const TIMEOUT = { hello: 15000, text: 60000, ocr: 90000, external: 600000, refine: 20000 };
const LOCAL_ENGINE = "apple";
// 외부 번역 서비스는 당분간 숨긴다. 저장된 동의는 삭제하지 않는다.
const EXTERNAL_ENGINES = [];
const CAPTURE_MIN_INTERVAL = 700; // Chrome captureVisibleTab 호출 빈도 제한(초당 2회) 아래로 유지
const CAPTURE_TTL = 15000;
const CAPTURE_CALL_TIMEOUT = 10000; // 캡처 호출 하나를 기다리는 최대 시간(줄이 멈추지 않게)
const FONT_STYLES = ["auto", "gothic", "myeongjo", "gungseo", "hand"];
const ICON_SIZES = [16, 32];
// 빨강(원문 보기)·파랑(번역, 번들 원본 그대로)은 같은 그림을 색만 바꾼 것이다(새 디자인이 아니라 기존
// 아이콘의 색조만 회전). hue는 0~1 비율.
const RED_HUE = 0;
// 처리 중 회전 원형 화살표 오버레이의 프레임 수·간격(ms). 적은 프레임으로 가볍게 회전하는 느낌만 준다.
const SPINNER_FRAMES = 8;
const SPINNER_INTERVAL_MS = 150;
const DEFAULTS = { consent: false, target: "ko", images: true, automaticEnabled: false, engine: LOCAL_ENGINE, engineConsents: [],
                   fontStyle: "auto" };

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
    ? stored.engineConsents.filter((engine) => ["deepl", "google", "papago"].includes(engine))
    : [];
  // 웹 번역 엔진은 이 브라우저에서 지원하고 그 엔진에 동의했을 때만 쓴다. 아니면 Mac 기본 번역.
  const engine = EXTERNAL_ENGINES.includes(stored.engine) && engineConsents.includes(stored.engine) ? stored.engine : LOCAL_ENGINE;
  return {
    consent: stored.consent === true,
    target: TARGETS.includes(stored.target) ? stored.target : "ko",
    images: stored.images !== false,
    automaticEnabled: stored.automaticEnabled === true,
    engine,
    engineConsents,
    fontStyle: FONT_STYLES.includes(stored.fontStyle) ? stored.fontStyle : "auto"
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
    return "Barobogi 확장 앱에 연결하지 못했습니다. Barobogi를 응용 프로그램 폴더에 설치해 한 번 실행하고 Safari 설정에서 확장을 켜 주세요.";
  }
  if (/not found/i.test(text)) {
    return "Barobogi 연결이 등록되지 않았습니다. Barobogi 메뉴 막대 › 브라우저 번역…에서 이 브라우저의 '설치 시작'을 누르세요.";
  }
  if (/forbidden/i.test(text)) {
    return "이 확장은 Barobogi 연결 허용 목록에 없습니다. Barobogi의 '브라우저 번역…'에서 '설치 시작'을 다시 누른 뒤 확장 폴더를 다시 로드하세요.";
  }
  return "Barobogi 엔진과 연결이 끊겼습니다. Barobogi가 응용 프로그램 폴더에 있는지 확인하고 다시 시도하세요.";
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
    // 중간 진행 프레임: 기다리는 요청은 그대로 두고(결과로 끝내지 않음) 그 요청의 진행 기록만 바꾼다. 이미 끝났거나
    // 취소된(대기 목록에 없는) id의 늦은 진행은 버린다.
    if (message.type === "progress") {
      const entry = id ? this.pending.get(id) : null;
      if (entry && typeof entry.onProgress === "function") entry.onProgress(message);
      return;
    }
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

  request(message, { timeout, tabId = null, kind = "other", onProgress = null }) {
    const id = message.id;
    return new Promise((settleResolve, settleReject) => {
      // 끝나는 모든 경로(응답·오류·취소·시간 초과·연결 끊김)에서 이 요청의 진행 기록을 지운다.
      const resolve = (value) => { dropNativeProgress(tabId, id); settleResolve(value); };
      const reject = (error) => { dropNativeProgress(tabId, id); settleReject(error); };
      const timer = setTimeout(() => {
        if (!this.pending.has(id)) return;
        this.cancel(id);
        reject(codedError("timeout", "Barobogi 응답 시간이 지났습니다. 다시 시도하세요."));
      }, timeout);
      this.pending.set(id, { resolve, reject, timer, tabId, kind, onProgress });
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
      // 구버전 Barobogi나 Safari 확장 앱은 웹 번역 엔진을 알리지 않는다.
      externalEngines: Array.isArray(response.externalEngines)
        ? response.externalEngines.filter((engine) => EXTERNAL_ENGINES.includes(engine))
        : [],
      aiRefine: response.aiRefine === true
    };
  },

  /** 팝업 "언어팩" 버튼: Barobogi가 실제 다운로드 화면을 열게 한다. Safari처럼 이 확장이 직접 그 화면을 열 수 없을 때는
   *  응답에 안내 문구(message)가 실려 온다(창을 바로 열었을 때는 없음). */
  async openLanguagePack() {
    const response = await this.request({ v: 1, type: "openLanguagePack", id: this.nextId("lp") }, { timeout: TIMEOUT.hello });
    return typeof response.message === "string" ? response.message : null;
  }
};

// MARK: - 툴바 아이콘·배지(원문 보기=빨강, 번역 보기=기존 파랑, 처리 중=회전 원형 화살표 오버레이) + 팝업 진행 스피너용 탭 상태
//
// 처리 중(running)이 최우선이다: 기존 아이콘 위에 작은 회전 원형 화살표를 오버레이해 setInterval로 몇 프레임만
// 반복 setIcon 한다(끝나면·취소·오류여도 content.js의 finally가 항상 running:false를 보내 바로 멈춘다).
// 처리 중이 아닐 때는 원문 보기=빨강 오버레이, 번역 보기=기존 파랑(그대로)로 한 번만 바뀐다.
// 빨강 변형은 번들 아이콘 자체의 색조(hue)만 돌려 만든다(채도·명도는 그대로 둬 음영·외곽선을 보존) —
// 새 그림을 생성하지 않고 지금 아이콘을 그대로 알아볼 수 있게 한다.

function rgbToHsl(r, g, b) {
  r /= 255; g /= 255; b /= 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  const l = (max + min) / 2;
  if (max === min) return [0, 0, l];
  const d = max - min;
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  let h;
  if (max === r) h = ((g - b) / d + (g < b ? 6 : 0)) / 6;
  else if (max === g) h = ((b - r) / d + 2) / 6;
  else h = ((r - g) / d + 4) / 6;
  return [h, s, l];
}

function hslToRgb(h, s, l) {
  if (s === 0) { const v = Math.round(l * 255); return [v, v, v]; }
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p = 2 * l - q;
  const hue = (t) => {
    let tt = t;
    if (tt < 0) tt += 1;
    if (tt > 1) tt -= 1;
    if (tt < 1 / 6) return p + (q - p) * 6 * tt;
    if (tt < 1 / 2) return q;
    if (tt < 2 / 3) return p + (q - p) * (2 / 3 - tt) * 6;
    return p;
  };
  return [Math.round(hue(h + 1 / 3) * 255), Math.round(hue(h) * 255), Math.round(hue(h - 1 / 3) * 255)];
}

/** imageData를 제자리에서 지정한 색조(hue)로 돌린다. 채도·명도·투명도는 그대로 둔다(모양·세부는 그대로). */
function tintToHue(imageData, hue) {
  const data = imageData.data;
  for (let i = 0; i < data.length; i += 4) {
    if (data[i + 3] === 0) continue;
    const [, s, l] = rgbToHsl(data[i], data[i + 1], data[i + 2]);
    const [r, g, b] = hslToRgb(hue, s, l);
    data[i] = r; data[i + 1] = g; data[i + 2] = b;
  }
  return imageData;
}

/** 기존 아이콘(base) 중앙에 얇은 회전 원형 화살표(처리 중 표시)를 겹쳐 한 프레임을 만든다.
 *  angle은 라디안(화살표 진행 방향). 배경 원판 없이 얇은 흰 선 + 어두운 외곽선만으로 가독성을 준다. */
function drawSpinnerFrame(base, size, angle) {
  const canvas = new OffscreenCanvas(size, size);
  const ctx = canvas.getContext("2d");
  ctx.putImageData(base, 0, 0);
  const cx = size / 2;
  const cy = size / 2;
  const r = size * 0.335;
  const lineWidth = Math.max(1, size * 0.09);
  const arcRadius = r - lineWidth / 2;
  const tipAngle = Math.PI * 1.5;
  const tipX = arcRadius * Math.cos(tipAngle);
  const tipY = arcRadius * Math.sin(tipAngle);
  const headLen = size * 0.1;

  ctx.save();
  ctx.translate(cx, cy);
  ctx.rotate(angle);

  ctx.strokeStyle = "rgba(0,0,0,0.55)";
  ctx.lineWidth = lineWidth + Math.max(1, size * 0.045);
  ctx.lineCap = "round";
  ctx.beginPath();
  ctx.arc(0, 0, arcRadius, 0, tipAngle);
  ctx.stroke();

  ctx.strokeStyle = "#FFFFFF";
  ctx.lineWidth = lineWidth;
  ctx.beginPath();
  ctx.arc(0, 0, arcRadius, 0, tipAngle);
  ctx.stroke();

  // 화살촉: 호의 끝(각도 1.5π)에서 접선 방향을 가리키는 작은 삼각형.
  ctx.beginPath();
  ctx.moveTo(tipX, tipY);
  ctx.lineTo(tipX - headLen, tipY - headLen * 0.4);
  ctx.lineTo(tipX - headLen * 0.2, tipY + headLen);
  ctx.closePath();
  ctx.strokeStyle = "rgba(0,0,0,0.55)";
  ctx.lineWidth = Math.max(1, size * 0.045);
  ctx.stroke();
  ctx.fillStyle = "#FFFFFF";
  ctx.fill();
  ctx.restore();
  return ctx.getImageData(0, 0, size, size);
}

async function loadIconImageData(path, size) {
  const response = await fetch(api.runtime.getURL(path));
  const bitmap = await createImageBitmap(await response.blob());
  const canvas = new OffscreenCanvas(size, size);
  const ctx = canvas.getContext("2d");
  ctx.drawImage(bitmap, 0, 0, size, size);
  return ctx.getImageData(0, 0, size, size);
}

/** 16/32 두 크기의 파랑(원본)·빨강(색조 회전)·처리 중 회전 프레임 ImageData를 한 번만 만들어 둔다. OffscreenCanvas·
 *  createImageBitmap·action.setIcon 중 하나라도 없으면(구버전 Safari 등) null — 그 경우 토글 아이콘 색은
 *  바뀌지 않고 팝업 스피너·상태만으로 안내한다(기능이 조용히 깨지지 않는다). */
const iconReady = (async () => {
  try {
    if (typeof OffscreenCanvas !== "function" || typeof createImageBitmap !== "function" ||
        typeof api.action?.setIcon !== "function") return null;
    const blue = {};
    const red = {};
    const spinner = {};
    for (const size of ICON_SIZES) {
      const base = await loadIconImageData(`icons/icon${size}.png`, size);
      blue[size] = base;
      red[size] = tintToHue(new ImageData(new Uint8ClampedArray(base.data), base.width, base.height), RED_HUE);
      spinner[size] = Array.from({ length: SPINNER_FRAMES }, (_, i) =>
        drawSpinnerFrame(base, size, (i / SPINNER_FRAMES) * Math.PI * 2));
    }
    return { blue, red, spinner };
  } catch {
    return null;
  }
})();

/** Chrome·Whale의 action.* 콜백 API는 탭이 막 닫혀 대상이 없을 때 lastError를 그 콜백 안에서 동기적으로
 *  읽어야 "Unchecked runtime.lastError" 경고가 없다(await로 받은 뒤 읽으면 엔진이 이미 경고를 찍은 뒤다).
 *  Safari의 browser.* action은 순수 promise라 이 패턴이 필요 없고 그대로 호출한다. 성공하면 true. */
function callActionApi(method, options) {
  if (IS_SAFARI) return Promise.resolve(method(options)).then(() => true, () => false);
  return new Promise((resolve) => {
    method(options, () => {
      const failed = Boolean(api.runtime.lastError); // 탭이 닫혔을 수 있음: 그 자리에서 읽어 소비한다.
      resolve(!failed);
    });
  });
}

const tabProgress = new Map(); // tabId → { view: "translated"|"original", running: boolean, timer: number|0, frame: number }

function stopSpinner(info) {
  if (info.timer) {
    clearInterval(info.timer);
    info.timer = 0;
    info.frame = 0;
  }
}

/** 탭 하나의 툴바 아이콘·배지·툴팁을 실제 상태에 맞춘다. 탭이 이미 닫혀 사라졌으면 조용히 무시한다.
 *  처리 중(running)이 최우선: 회전 원형 화살표 오버레이를 setInterval로 몇 프레임만 반복 그린다.
 *  처리 중이 끝나면(완료·취소·오류 모두 content.js가 running:false로 알려줌) 타이머를 바로 멈추고
 *  원문 보기=빨강, 번역 보기=기존 파랑으로 한 번만 되돌린다. */
async function updateTabIcon(tabId) {
  const info = tabProgress.get(tabId) || { view: "original", running: false, timer: 0, frame: 0 };
  tabProgress.set(tabId, info);
  const icons = await iconReady;
  if (tabProgress.get(tabId) !== info) return;
  if (!info.running) {
    stopSpinner(info);
    if (icons) {
      const variant = info.view === "original" ? icons.red : icons.blue;
      await callActionApi(api.action.setIcon.bind(api.action), { tabId, imageData: variant });
    }
  } else if (icons && !info.timer) {
    const paintFrame = async () => {
      if (tabProgress.get(tabId) !== info || !info.running) {
        stopSpinner(info);
        return;
      }
      const frames = icons.spinner;
      const data = {};
      for (const size of ICON_SIZES) data[size] = frames[size][info.frame % SPINNER_FRAMES];
      const ok = await callActionApi(api.action.setIcon.bind(api.action), { tabId, imageData: data });
      if (!ok) {
        stopSpinner(info); // 탭이 닫혔을 수 있음
        return;
      }
      info.frame = (info.frame + 1) % SPINNER_FRAMES;
    };
    // 첫 프레임을 기다리기 전에 핸들을 저장해 중복 생성·종료 직후 재시작을 막는다.
    info.timer = setInterval(paintFrame, SPINNER_INTERVAL_MS);
    await paintFrame();
  }
  if (typeof api.action?.setBadgeText === "function") {
    await callActionApi(api.action.setBadgeText.bind(api.action), { tabId, text: "" });
  }
  if (typeof api.action?.setTitle === "function") {
    const title = info.running ? "Barobogi 웹 번역 — 번역 중…" : "Barobogi 웹 번역";
    await callActionApi(api.action.setTitle.bind(api.action), { tabId, title });
  }
}

/** 내용 스크립트가 보낸 진행 상태(실행 중 여부·원문/번역 보기)를 반영한다. 보낸 탭 것만 보고, 숫자가
 *  아닌 탭 ID는 무시한다(가짜 tabId 방어). 팝업이 닫혀 있어도 이 경로로 툴바가 갱신된다. */
function handleProgress(message, sender) {
  const tabId = sender.tab?.id;
  if (!Number.isInteger(tabId)) return;
  // 타이머 콜백과 맵이 같은 상태 객체를 유지해야 종료 때 모든 타이머를 멈출 수 있다.
  const info = tabProgress.get(tabId) || { timer: 0, frame: 0 };
  info.view = message.view === "original" ? "original" : "translated";
  info.running = message.running === true;
  if (!info.running) stopSpinner(info);
  tabProgress.set(tabId, info);
  updateTabIcon(tabId).catch(() => {});
}

// MARK: - 보이는 탭 캡처(메모리에만 잠깐 보관, 탭당 최신 1장)

const captures = new Map(); // tabId → { id, dataUrl, url, time, calibration }
// 팝업의 명시적 1회성 번역 버튼(Google·DeepL)으로만 허용하는 엔진. 저장된 전역 engine 설정과는 무관하다.
const PAGE_ENGINES = ["google", "deepl"];
// 팝업에서 직접 'Google'·'DeepL'을 누른 탭 → { engine, url, token, documentId }. 토큰은 그 순간 그 탭의 문서에 붙은 내용
// 스크립트에만 건네며(메모리에만 둠), 첫 요청에서 그 문서의 documentId를 묶는다. 같은 주소라도 다른 문서(새로고침·뒤로 가기로
// 다시 만든 문서)는 토큰이 없어 보낼 수 없다. 토큰은 고른 엔진에 묶여 다른 엔진 요청에는 쓸 수 없다(Google 토큰으로
// DeepL에 보내거나 그 반대가 되지 않는다). 탭당 하나만 두므로 다른 엔진을 고르면 이전 토큰은 바로 무효다.
// 일반 번역·원문 보기·중지·언어 변경·이동·탭 닫기·동의 철회 때 지운다.
const externalPages = new Map();

/** 이 요청이 그 엔진의 1회성 번역을 허용받은 바로 그 문서(같은 엔진·토큰·주소·documentId, 최상위 프레임)에서 왔는지. */
function externalAllowedFor(message, sender, tab, engine) {
  const entry = externalPages.get(tab.id);
  if (!entry || !PAGE_ENGINES.includes(engine) || entry.engine !== engine) return false;
  if (typeof message.token !== "string" || message.token !== entry.token) return false;
  if (Number.isInteger(sender.frameId) && sender.frameId !== 0) return false;
  if (entry.url !== sender.url || entry.url !== tab.url) return false;
  if (typeof sender.documentId === "string") {
    if (entry.documentId === null) entry.documentId = sender.documentId;
    else if (entry.documentId !== sender.documentId) return false;
  }
  return true;
}

/** 응답을 기다리는 사이 그 허용이 끝났거나(중지·이동·다른 엔진 선택) 바뀌었으면 결과를 돌려주지 않는다. */
function externalStillAllowed(tabId, engine, token) {
  const entry = externalPages.get(tabId);
  return !!entry && entry.engine === engine && entry.token === token;
}

/** 내용 스크립트의 1회성 요청에서 엔진을 고른다. 옛 이름(…Google)은 Google로만, 새 이름(…External)은 Google·DeepL 중
 *  하나로만 받는다. 그 밖의 값은 null(거부). */
function pageEngineOf(message) {
  if (message.cmd === "translatePageGoogle" || message.cmd === "ocrPageGoogle") return "google";
  return PAGE_ENGINES.includes(message.engine) ? message.engine : null;
}
let lastCaptureAt = 0;
// 캡처는 모든 탭을 통틀어 한 줄로 세운다(Chrome의 초당 호출 한도는 확장 전체 기준). 앞 요청이 실패해도 다음 요청은 이어간다.
let captureQueue = Promise.resolve();
// 탭마다 캡처 취소 세대: 중지·이동·탭 닫기·시간 초과 때 올려, 줄에서 기다리던 요청이 새로 캡처하지 않게 한다.
const captureTickets = new Map();

function dropCapture(tabId) {
  captures.delete(tabId);
  captureTickets.set(tabId, (captureTickets.get(tabId) || 0) + 1);
}

/** 브라우저 캡처 API의 오류를 고정 코드로만 나눈다(원래 오류 문장은 사용자에게 내보내지 않는다). */
function captureErrorCode(error) {
  const text = String((error && error.message) || error || "");
  if (/MAX_CAPTURE_VISIBLE_TAB_CALLS_PER_SECOND|quota/i.test(text)) return "capture_rate_limited";
  if (/<all_urls>|activeTab|permission|Cannot access contents/i.test(text)) return "capture_denied";
  if (/No (tab|window) with id/i.test(text)) return "stale";
  return "capture_failed";
}

const CAPTURE_MESSAGES = {
  capture_denied: "이미지 글자 번역에는 화면 캡처 권한이 필요합니다. 툴바의 Barobogi 아이콘에서 '번역'을 누르세요.",
  capture_rate_limited: "화면 캡처 요청이 잠시 몰려 이번에는 이미지를 확인하지 못했습니다. 잠시 뒤 다시 번역을 누르세요.",
  capture_failed: "화면을 캡처하지 못해 이미지 글자를 번역하지 못했습니다. 다시 번역을 눌러 주세요.",
  stale: ""
};

/** 캡처 직전 내용 스크립트가 화면 가장자리에 그린 밝기 보정 견본(검정 0·회색 128·흰색 255 세 칸)의 뷰포트 CSS 좌표.
 *  형식·크기가 맞을 때만 그 캡처에 묶고, 틀리면 없는 것으로 본다(네이티브가 밝기를 짐작으로 고치지 않음). */
function validCalibration(c) {
  if (!c || typeof c !== "object") return null;
  if (!["x", "y", "w", "h"].every((key) => Number.isFinite(c[key]))) return null;
  if (c.x < 0 || c.y < 0 || c.w < 48 || c.w > 96 || c.h < 16 || c.h > 32) return null;
  return { x: c.x, y: c.y, w: c.w, h: c.h };
}

/** 이 탭이 지금 그 창의 보이는 탭이고 같은 주소인지. 아니면 stale(탭 없음·이동) 또는 tab_hidden(다른 탭이 보임)으로 끝낸다. */
async function assertCaptureTab(tab) {
  let now;
  try {
    now = await api.tabs.get(tab.id);
  } catch {
    throw codedError("stale", "");
  }
  if (!now || now.windowId !== tab.windowId || now.url !== tab.url) throw codedError("stale", "");
  if (!now.active) throw codedError("tab_hidden", "보이는 탭이 아니어서 이미지를 캡처하지 않았습니다.");
}

/** 캡처 요청을 한 줄로 세운다. 호출 시작 사이 간격(CAPTURE_MIN_INTERVAL)은 줄 안에서만 재므로 두 요청이 같은 순간에 깨어
 *  함께 호출하지 않는다. 앞 요청의 실패는 줄을 멈추지 않는다. epoch: 요청을 받은 때의 전역 세대. */
function captureVisible(tab, calibration, epoch) {
  const ticket = captureTickets.get(tab.id) || 0;
  const run = captureQueue.then(() => captureNow(tab, calibration, epoch, ticket));
  captureQueue = run.catch(() => {});
  return run;
}

async function captureNow(tab, calibration, epoch, ticket) {
  // 권한 범위가 <all_urls>여도 캡처 대상은 http/https 페이지로만 제한한다.
  if (!originOf(tab.url)) throw codedError("restricted_page", "이 페이지는 캡처하지 않습니다.");
  const cancelled = () => epoch !== control.epoch || (captureTickets.get(tab.id) || 0) !== ticket;
  if (cancelled()) throw codedError("cancelled", "");
  const wait = lastCaptureAt + CAPTURE_MIN_INTERVAL - Date.now();
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
  // 기다리는 사이 취소·이동·탭 전환이 있었으면 새로 캡처하지 않는다(찍기 직전에 다시 확인).
  if (cancelled()) throw codedError("cancelled", "");
  await assertCaptureTab(tab);
  if (cancelled()) throw codedError("cancelled", "");
  lastCaptureAt = Date.now();
  let dataUrl;
  try {
    // 장식 글자의 인식·가림 경계와 바탕색을 보존한다. 지연은 중복 분석 제거와 번역 병렬 처리로 줄인다.
    // 브라우저가 응답하지 않아도 줄이 영영 멈추지 않게 시간 제한을 둔다(넘기면 일반 캡처 실패).
    let timer = 0;
    dataUrl = await Promise.race([
      api.tabs.captureVisibleTab(tab.windowId, { format: "png" }),
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("capture timeout")), CAPTURE_CALL_TIMEOUT); })
    ]).finally(() => clearTimeout(timer));
  } catch (error) {
    // 캡처 도중 탭이 바뀌어 다른 탭 접근이 거절된 경우를 권한 부족으로 오진하지 않는다.
    if (cancelled()) throw codedError("cancelled", "");
    await assertCaptureTab(tab).catch(() => { throw codedError("stale", ""); });
    if (cancelled()) throw codedError("cancelled", "");
    // 실제 권한 오류만 권한 안내를 보인다. 호출 빈도 한도·그 밖의 실패는 따로 알리고, 자동으로 다시 찍지 않는다.
    const code = captureErrorCode(error);
    throw codedError(code, CAPTURE_MESSAGES[code]);
  }
  // 캡처하는 사이 탭이 바뀌었거나 다른 페이지로 이동했으면 버린다.
  await assertCaptureTab(tab).catch(() => { throw codedError("stale", ""); });
  if (cancelled()) throw codedError("cancelled", "");
  if (typeof dataUrl !== "string" || !/^data:image\/(png|jpeg);base64,/.test(dataUrl)) throw codedError("capture_failed", "캡처에 실패했습니다.");
  if (dataUrl.length > 15 * 1024 * 1024) throw codedError("image_too_large", "캡처 이미지가 너무 큽니다. 창을 줄여 주세요.");
  const id = native.nextId("cap");
  captures.set(tab.id, { id, dataUrl, url: tab.url, time: Date.now(), calibration });
  return id;
}

/** 한 번만 꺼낼 수 있다. 캡처와 같은 자리에 묶인 견본 좌표도 함께 돌려준다. */
function takeCapture(tabId, id) {
  const entry = captures.get(tabId);
  captures.delete(tabId);
  if (!entry || entry.id !== id || Date.now() - entry.time > CAPTURE_TTL) return null;
  return { dataUrl: entry.dataUrl, calibration: entry.calibration || null };
}

const CALIBRATION_STATUS = ["applied", "normal", "rejected", "none"];
const TIMING_KEYS = ["decode", "calibrate", "ocr", "analyze", "translate", "encode"];

/** 네이티브의 단계별 걸린 시간(ms): 알려진 이름과 0~10분 정수만 통과시킨다(원문·이미지는 담기지 않음). */
function sanitizeTiming(t) {
  if (!t || typeof t !== "object") return null;
  const result = {};
  for (const key of TIMING_KEYS) {
    if (Number.isInteger(t[key]) && t[key] >= 0 && t[key] <= 600000) result[key] = t[key];
  }
  return Object.keys(result).length ? result : null;
}

/** 네이티브의 견본 측정 진단 값: 알려진 상태와 0~255 정수 세 값만 통과시킨다. */
function sanitizeCalibration(c) {
  if (!c || !CALIBRATION_STATUS.includes(c.s)) return null;
  const levels = ["b", "g", "w"].every((key) => Number.isInteger(c[key]) && c[key] >= 0 && c[key] <= 255);
  return levels ? { s: c.s, b: c.b, g: c.g, w: c.w } : { s: c.s };
}

// MARK: - 네이티브 중간 진행(요청 id에 묶임, 메모리에만, 단계 이름과 개수만)

// tabId → Map(요청 id → { kind, engine, token, phase, step, counts, at }). 요청이 끝나거나(응답·오류·취소·시간 초과)
// 탭이 이동·닫히면 지운다. 1회성 Google·DeepL 요청은 보낼 때의 엔진·토큰을 함께 두고, 팝업에 보여줄 때 그 허용이
// 그대로인지 다시 확인한다(다른 엔진·문서로 바뀐 뒤의 늦은 진행은 보이지 않는다).
const nativeProgress = new Map();
const PROGRESS_PHASES = ["recognized", "translating", "external"];
const PROGRESS_STEPS = ["opening", "input", "waiting", "challenge"];
const PROGRESS_COUNTS = ["images", "recognizedImages", "sentences", "letters", "batch", "batches", "batchItems", "batchChars",
                         "totalItems", "totalChars", "doneItems"];

function dropNativeProgress(tabId, id) {
  const entries = nativeProgress.get(tabId);
  if (!entries) return;
  entries.delete(id);
  if (!entries.size) nativeProgress.delete(tabId);
}

// MARK: - 번역 동작의 네이티브 단계 시각(동작 id에 묶임, 메모리에만, 단계 이름과 시각만)
//
// 내용 스크립트가 요청마다 지금 동작 id(action)를 함께 보낸다. 요청을 보낸 때·진행 프레임으로 단계가 바뀐 때·끝난 때의 시각만
// 남겨, 요청이 끝나 진행 기록(nativeProgress)이 지워진 뒤에도 그 동작이 끝날 때까지 팝업이 단계별 구간을 보여줄 수 있게 한다.
// 같은 탭에서 다른 동작 id가 오면 이전 기록은 버린다. 이동·탭 닫기 때 지운다. 원문·주소·이미지는 담지 않는다.
const ACTION_ID = /^[A-Za-z0-9-]{1,40}$/;
const TIMELINE_MAX_MARKS = 256;
const timelines = new Map(); // tabId → { action, seq, marks: [{ r: 요청 번호, k: "text"|"ocr", p: 단계, t: Date.now() }] }

function timelineFor(tabId, action) {
  if (!Number.isInteger(tabId) || typeof action !== "string" || !ACTION_ID.test(action)) return null;
  let line = timelines.get(tabId);
  if (!line || line.action !== action) {
    line = { action, seq: 0, marks: [] };
    timelines.set(tabId, line);
  }
  return line;
}

/** 요청 r의 단계 p 시작 시각을 남긴다(같은 요청의 같은 단계가 이어지면 다시 남기지 않는다). */
function addMark(line, r, k, p) {
  if (!line || line.marks.length >= TIMELINE_MAX_MARKS) return;
  for (let i = line.marks.length - 1; i >= 0; i -= 1) {
    if (line.marks[i].r !== r) continue;
    if (line.marks[i].p === p) return;
    break;
  }
  line.marks.push({ r, k, p, t: Date.now() });
}

function timelineSnapshot(tabId) {
  const line = timelines.get(tabId);
  return line ? { action: line.action, marks: line.marks.map((mark) => ({ ...mark })) } : null;
}

/** 이 동작에서 아직 끝나지 않은 요청의 마지막 단계("sent"·"recognized"·"translating"·"external:waiting" 등). 없으면 null. */
function openNativeStage(tabId, action) {
  const line = timelines.get(tabId);
  if (!line || line.action !== action) return null;
  const last = new Map();
  for (const mark of line.marks) last.set(mark.r, mark);
  let open = null;
  for (const mark of last.values()) {
    if (mark.p === "end" || mark.p === "fail") continue;
    if (!open || mark.t >= open.t) open = mark;
  }
  return open ? `${open.k}/${open.p}` : null;
}

/** 요청 하나를 동작 기록에 묶어 보낸다(보낸 때·끝난 때를 남긴다). 진행 프레임 단계는 progressRecorder가 남긴다. */
async function trackedRequest(line, kind, run) {
  const r = line ? (line.seq += 1) : 0;
  addMark(line, r, kind, "sent");
  try {
    const response = await run(r);
    addMark(line, r, kind, "end");
    return response;
  } catch (error) {
    addMark(line, r, kind, "fail");
    throw error;
  }
}

// MARK: - 외부 번역 전체 시간 한도(현재 모든 엔진 비활성: DeepL도 Google과 동일)
//
// 배경이 판정 주체다. 한도는 클릭(자동 실행은 실제 시작) 시각부터 재며 검색·이미지 인식·복원·페이지 준비·입력·결과 읽기·그리기를
// 모두 포함한다. 사용자가 공식 페이지에서 직접 풀어야 하는 보안 확인(네이티브 진행 단계 challenge) 동안만 따로 세고 한도에서 뺀다
// (그 사이 사용자가 직접 끝내면 이어서 진행하는 기존 동작을 그대로 둔다). 한도를 넘으면 그 1회성 허용(토큰)을 거둬 늦은 요청·결과를
// 거부하고, 그 탭의 남은 네이티브 요청을 기존 취소 경로(네이티브 취소 포함)로 멈춘 뒤 내용 스크립트에 알린다. 다른 엔진으로
// 바꾸거나 다시 시도하지 않는다. 현재는 어떤 엔진에도 이 별도 한도를 두지 않는다.
const ACTION_DEADLINE_MS = {};
const deadlines = new Map(); // tabId → { action, token, engine, startedAt, limit, securityMs, securitySince, timer, state, stage, at }

function deadlineElapsed(entry, now) {
  return now - entry.startedAt - entry.securityMs - (entry.securitySince !== null ? now - entry.securitySince : 0);
}

function armDeadline(tabId, entry) {
  clearTimeout(entry.timer);
  entry.timer = 0;
  if (entry.state !== "running" || entry.securitySince !== null) return;
  entry.timer = setTimeout(() => deadlineFired(tabId, entry), Math.max(0, entry.limit - deadlineElapsed(entry, Date.now())));
}

/** 클릭(또는 자동 실행 시작) 시각의 한도를 시작한다. 같은 동작이면 그대로 두고, 다른 동작이면 이전 기록을 바꾼다. */
function startDeadline(tabId, engine, token, action, startedAt) {
  const limit = ACTION_DEADLINE_MS[engine];
  if (!limit || !Number.isInteger(tabId) || typeof action !== "string" || !ACTION_ID.test(action)) return;
  const existing = deadlines.get(tabId);
  if (existing && existing.action === action && existing.token === token) return;
  if (existing) clearTimeout(existing.timer);
  const now = Date.now();
  const start = Number.isFinite(startedAt) && startedAt <= now && startedAt >= now - 60000 ? startedAt : now;
  const entry = { action, token, engine, startedAt: start, limit, securityMs: 0, securitySince: null, timer: 0,
                  state: "running", stage: null, at: null };
  deadlines.set(tabId, entry);
  armDeadline(tabId, entry);
}

/** 1회성 허용이 끝났을 때(중지·일반 번역·이동·설정 변경) 진행 중인 한도를 멈춘다. 초과로 끝난 기록은 팝업이 보도록 남긴다. */
function dropDeadline(tabId) {
  const entry = deadlines.get(tabId);
  if (!entry) return;
  clearTimeout(entry.timer);
  entry.timer = 0;
  if (entry.state === "running") deadlines.delete(tabId);
}

function clearDeadlines() {
  for (const tabId of [...deadlines.keys()]) dropDeadline(tabId);
}

/** 네이티브 진행에서 보안 확인(challenge) 단계에 들어가고 나온 때를 잰다. 그 동안은 한도 시계를 멈춘다. */
function noteSecurity(tabId, token, challenge) {
  const entry = deadlines.get(tabId);
  if (!entry || entry.state !== "running" || token === null || entry.token !== token) return;
  const now = Date.now();
  if (challenge && entry.securitySince === null) {
    entry.securitySince = now;
    armDeadline(tabId, entry);
  } else if (!challenge && entry.securitySince !== null) {
    entry.securityMs += now - entry.securitySince;
    entry.securitySince = null;
    armDeadline(tabId, entry);
  }
}

function deadlineFired(tabId, entry) {
  entry.timer = 0;
  if (deadlines.get(tabId) !== entry || entry.state !== "running" || entry.securitySince !== null) return;
  if (deadlineElapsed(entry, Date.now()) < entry.limit) {
    armDeadline(tabId, entry);
    return;
  }
  entry.state = "timeout";
  entry.at = Date.now() - entry.startedAt;
  entry.stage = openNativeStage(tabId, entry.action);
  // 허용을 먼저 거둬 이 뒤에 오는 요청·결과는 모두 거부되게 하고, 남은 요청은 네이티브까지 취소한다.
  if (externalPages.get(tabId)?.token === entry.token) externalPages.delete(tabId);
  dropCapture(tabId);
  native.cancelTab(tabId);
  sendToTab(tabId, { cmd: "externalDeadline", token: entry.token, action: entry.action, stage: entry.stage, at: entry.at })
    .catch(() => {});
}

/** 팝업용: 지금 탭의 한도 기록(보안 확인 시간 포함, 숫자만). */
function deadlineSnapshot(tabId) {
  const entry = deadlines.get(tabId);
  if (!entry) return null;
  const now = Date.now();
  return { action: entry.action, engine: entry.engine, limit: entry.limit, state: entry.state, stage: entry.stage, at: entry.at,
           securityMs: entry.securityMs + (entry.securitySince !== null ? now - entry.securitySince : 0),
           security: entry.securitySince !== null };
}

/** 이 탭 요청의 진행 프레임을 알려진 단계·개수(0~1천만 정수)만 남겨 기록하는 함수를 만든다. line·r이 있으면 그 동작 기록에
 *  단계가 바뀐 시각도 남긴다. 1회성 외부 요청이면 보안 확인 단계 출입을 한도 시계에 알린다. */
function progressRecorder(tabId, id, kind, engine, token = null, line = null, r = 0) {
  if (IS_SAFARI || !Number.isInteger(tabId)) return null;
  return (message) => {
    if (!PROGRESS_PHASES.includes(message.phase)) return;
    const step = PROGRESS_STEPS.includes(message.step) ? message.step : null;
    addMark(line, r, kind, message.phase === "external" && step ? `external:${step}` : message.phase);
    noteSecurity(tabId, token, message.phase === "external" && step === "challenge");
    const counts = {};
    const raw = message.counts && typeof message.counts === "object" ? message.counts : {};
    for (const key of PROGRESS_COUNTS) {
      if (Number.isInteger(raw[key]) && raw[key] >= 0 && raw[key] <= 10000000) counts[key] = raw[key];
    }
    if (!nativeProgress.has(tabId)) nativeProgress.set(tabId, new Map());
    nativeProgress.get(tabId).set(id, {
      kind, engine, token, phase: message.phase, step: PROGRESS_STEPS.includes(message.step) ? message.step : null, counts,
      at: Date.now()
    });
  };
}

/** 팝업용: 이 탭에서 아직 기다리는 요청의 최신 진행만(1회성 요청은 허용이 그대로일 때만) 돌려준다. */
function nativeProgressFor(tabId) {
  const entries = nativeProgress.get(tabId);
  if (!entries) return [];
  const list = [];
  for (const [id, entry] of entries) {
    if (!native.pending.has(id)) { entries.delete(id); continue; }
    if (entry.token !== null && !externalStillAllowed(tabId, entry.engine, entry.token)) continue;
    list.push({ kind: entry.kind, engine: entry.engine, phase: entry.phase, step: entry.step, counts: entry.counts, at: entry.at });
  }
  return list;
}

// MARK: - 내용 스크립트 요청 처리

function validTexts(texts, engine) {
  const external = engine !== LOCAL_ENGINE;
  const maxTexts = engine === "deepl" ? EXTERNAL_LIMITS.deeplTexts : (external ? EXTERNAL_LIMITS.texts : LIMITS.texts);
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

/** Apple Intelligence 다듬기 후속 요청 항목: 키 형식·개수·길이만 확인한다(내용은 이미 화면에 그려진 값).
 *  c(선택)는 같은 페이지의 주변 원문(문맥)으로, 개수·길이만 확인하고 다듬기 참고용으로만 넘긴다. */
function validRefineItems(items) {
  if (!Array.isArray(items) || items.length === 0 || items.length > LIMITS.refineItems) return false;
  let total = 0;
  let contextTotal = 0;
  for (const item of items) {
    if (!item || typeof item.k !== "string" || !/^[A-Za-z0-9_-]{1,32}$/.test(item.k)) return false;
    if (typeof item.o !== "string" || typeof item.d !== "string") return false;
    if (item.o.length > LIMITS.refineItemChars || item.d.length > LIMITS.refineItemChars) return false;
    if (item.c !== undefined && (typeof item.c !== "string" || item.c.length > LIMITS.refineContextChars)) return false;
    total += item.o.length + item.d.length;
    contextTotal += typeof item.c === "string" ? item.c.length : 0;
  }
  return total <= LIMITS.refineChars && contextTotal <= LIMITS.refineContextTotal;
}

/** 검증한 다듬기 항목을 알려진 필드(k·o·d·c)만 남겨 네이티브로 넘긴다. */
function refineItemsForNative(items) {
  return items.map((item) => ({ k: item.k, o: item.o, d: item.d, ...(typeof item.c === "string" && item.c ? { c: item.c } : {}) }));
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
 *  (마스킹 생략으로 이어짐) 문단 전체를 가리는 등의 값을 지어내지 않는다.
 *  gl(선택)은 g와 같은 길이의 "0"/"1" 문자열(본문 글자 여부)로, 길이가 맞을 때만 남긴 상자와 같은 순서로 함께 거른다. */
function sanitizeGlyphs(g, remainingBudget, gl) {
  if (!Array.isArray(g) || remainingBudget <= 0) return { boxes: [], letters: "" };
  const flags = typeof gl === "string" && gl.length === g.length && /^[01]*$/.test(gl) ? gl : null;
  const result = [];
  let letters = "";
  for (let index = 0; index < g.length; index += 1) {
    const entry = g[index];
    if (result.length >= LIMITS.glyphsPerItem || result.length >= remainingBudget) break;
    if (!Array.isArray(entry) || entry.length !== 4 || !entry.every((n) => Number.isFinite(n))) continue;
    const x = clampGlyphCoord(entry[0]);
    const y = clampGlyphCoord(entry[1]);
    const w = clampGlyphCoord(entry[2]);
    const h = clampGlyphCoord(entry[3]);
    if (x === null || y === null || w === null || h === null || w <= 0 || h <= 0) continue;
    result.push([x, y, w, h]);
    if (flags) letters += flags[index];
  }
  return { boxes: result, letters };
}

function sanitizeImages(images) {
  if (!Array.isArray(images)) return [];
  const hex = /^#[0-9A-Fa-f]{6}$/;
  let glyphBudget = LIMITS.glyphsTotal;
  // 네이티브는 조각을 뺀 응답 크기를 잰 뒤 1MB 프레임 상한까지 남은 만큼만 싣는다. 여기서는 그 상한만 다시 확인한다.
  let restorationBudget = 960000;
  return images.slice(0, LIMITS.regions).map((image) => ({
    k: typeof image?.k === "string" ? image.k : "",
    items: (Array.isArray(image?.items) ? image.items : []).filter((item) =>
      item && typeof item.t === "string" &&
      ["x", "y", "w", "h"].every((key) => Number.isFinite(item[key]) && item[key] >= -0.5 && item[key] <= 1.5)
    ).map((item) => {
      const { boxes: g, letters: gl } = sanitizeGlyphs(item.g, glyphBudget, item.gl);
      glyphBudget -= g.length;
      // cv: g 밖에서 함께 지운 상자(후리가나 등). 복원 조각을 못 쓸 때 g와 함께 불투명하게 가리는 데만 쓴다.
      const { boxes: cv } = sanitizeGlyphs(item.cv, glyphBudget);
      glyphBudget -= cv.length;
      const patch = item.m;
      let m;
      if (patch && typeof patch.d === "string" && patch.d.length <= restorationBudget &&
          /^data:image\/png;base64,iVBORw0KGgo[A-Za-z0-9+/]*={0,2}$/.test(patch.d) &&
          ["x", "y", "w", "h"].every((key) => Number.isFinite(patch[key]) && patch[key] >= -0.5 && patch[key] <= 1.5) &&
          patch.w > 0 && patch.h > 0) {
        m = { x: patch.x, y: patch.y, w: patch.w, h: patch.h, d: patch.d };
        restorationBudget -= patch.d.length;
      }
      return {
        // 상한을 넘는 번역문은 잘라 쓰지도, 항목을 빼서(가림 없이) 원문 글자를 다시 드러내지도 않는다. 빈 번역(내용 스크립트의
        // "번역 확인 필요" 표시)으로 둔다.
        x: item.x, y: item.y, w: item.w, h: item.h, t: item.t.length <= LIMITS.textLength ? item.t : "",
        bg: hex.test(item.bg) ? item.bg : "#FFFFFF",
        fg: hex.test(item.fg) ? item.fg : "#000000",
        ...(FONT_STYLES.includes(item.fs) && item.fs !== "auto" ? { fs: item.fs } : {}),
        ...(item.fw === 700 ? { fw: 700 } : {}),
        ...(hex.test(item.oc) ? { oc: item.oc } : {}),
        ...(m ? { m } : {}),
        // 다듬기 후속 요청에만 쓰는 인식 원문(짧게 자름). 저장하지 않고 이번 패스에서만 메모리에서 쓴다.
        ...(typeof item.o === "string" ? { o: item.o.slice(0, 700) } : {}),
        ...(g.length ? { g } : {}),
        ...(g.length && gl.length === g.length ? { gl } : {}),
        ...(cv.length ? { cv } : {}),
        ...(Number.isInteger(item.uc) && item.uc > 0 && item.uc < 100000 ? { uc: item.uc } : {})
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
      if (!settings.consent) throw codedError("consent_required", "툴바의 Barobogi 아이콘에서 먼저 동의해 주세요.");
      const engine = requestEngine(message, settings);
      if (!TARGETS.includes(message.target) || !validTexts(message.texts, engine)) throw codedError("bad_request", "잘못된 번역 요청입니다.");
      const id = native.nextId("t");
      const line = timelineFor(tab.id, message.action);
      const response = await trackedRequest(line, "text", (r) => {
        const onProgress = progressRecorder(tab.id, id, "text", engine, null, line, r);
        return native.request(
          { v: 1, type: "translate", id, target: message.target, texts: message.texts, engine, ...(onProgress ? { progress: true } : {}) },
          { timeout: engineTimeout(engine, TIMEOUT.text), tabId: tab.id, kind: "text", onProgress });
      });
      if (epoch !== control.epoch) throw codedError("cancelled", "");
      const texts = Array.isArray(response.texts) && response.texts.length === message.texts.length
        ? response.texts.map((t) => (typeof t === "string" ? t : null))
        : null;
      if (!texts) throw codedError("bad_response", "Barobogi 응답 형식이 올바르지 않습니다.");
      return { ok: true, texts, missing: Array.isArray(response.missing) ? response.missing.filter((m) => typeof m === "string") : [],
               langs: sanitizeLangs(response.langs, texts.length), warning: sanitizeWarning(response.warning),
               aiRefine: response.aiRefine === true, timing: sanitizeTiming(response.timing) };
    }
    // 명시적 버튼(팝업의 'Google'·'DeepL')으로만 오는 1회성 요청. 저장된 engine 설정(EXTERNAL_ENGINES로 가려 있음)과
    // 무관하게 이 탭의 지금 페이지 글자만 고른 서비스의 공식 번역 페이지로 보낸다. 엔진별 전송 동의는 앱(Barobogi)이 확인한다.
    // translatePageGoogle은 이전 내용 스크립트용 옛 이름(Google 전용)이다.
    case "translatePageExternal":
    case "translatePageGoogle": {
      if (!settings.consent) throw codedError("consent_required", "툴바의 Barobogi 아이콘에서 먼저 동의해 주세요.");
      const engine = pageEngineOf(message);
      if (!engine || !externalAllowedFor(message, sender, tab, engine)) throw codedError("cancelled", "");
      if (!TARGETS.includes(message.target) || !validTexts(message.texts, engine)) {
        throw codedError("bad_request", "잘못된 번역 요청입니다.");
      }
      const id = native.nextId("tg");
      const line = timelineFor(tab.id, message.action);
      const response = await trackedRequest(line, "text", (r) => {
        const onProgress = progressRecorder(tab.id, id, "text", engine, message.token, line, r);
        return native.request(
          { v: 1, type: "translate", id, target: message.target, texts: message.texts, engine, ...(onProgress ? { progress: true } : {}) },
          { timeout: TIMEOUT.external, tabId: tab.id, kind: "text", onProgress });
      }).finally(() => noteSecurity(tab.id, message.token, false));
      // 시간 한도를 넘긴 뒤(허용을 거둔 뒤) 도착한 결과는 돌려주지 않는다.
      if (epoch !== control.epoch || !externalStillAllowed(tab.id, engine, message.token)) throw codedError("cancelled", "");
      const texts = Array.isArray(response.texts) && response.texts.length === message.texts.length
        ? response.texts.map((t) => (typeof t === "string" ? t : null))
        : null;
      if (!texts) throw codedError("bad_response", "Barobogi 응답 형식이 올바르지 않습니다.");
      return { ok: true, texts, missing: Array.isArray(response.missing) ? response.missing.filter((m) => typeof m === "string") : [],
               langs: sanitizeLangs(response.langs, texts.length), warning: sanitizeWarning(response.warning) };
    }
    case "capture": {
      if (!settings.consent) throw codedError("consent_required", "툴바의 Barobogi 아이콘에서 먼저 동의해 주세요.");
      const captureId = await captureVisible(tab, validCalibration(message.calibration), epoch);
      if (epoch !== control.epoch) {
        captures.delete(tab.id);
        throw codedError("cancelled", "");
      }
      return { ok: true, captureId };
    }
    case "ocr":
    case "ocrPageExternal":
    case "ocrPageGoogle": {
      if (!settings.consent) throw codedError("consent_required", "툴바의 Barobogi 아이콘에서 먼저 동의해 주세요.");
      const viewport = message.viewport;
      const page = message.cmd !== "ocr";
      const engine = page ? pageEngineOf(message) : requestEngine(message, settings);
      if (page && (!engine || !externalAllowedFor(message, sender, tab, engine))) throw codedError("cancelled", "");
      if (!TARGETS.includes(message.target) || !validRegions(message.regions) ||
          !viewport || !Number.isFinite(viewport.w) || !Number.isFinite(viewport.h)) {
        throw codedError("bad_request", "잘못된 이미지 요청입니다.");
      }
      const companionTexts = page && message.texts !== undefined ? message.texts : [];
      if (!Array.isArray(companionTexts) || (companionTexts.length && !validTexts(companionTexts, engine))) {
        throw codedError("bad_request", "잘못된 동반 글자 요청입니다.");
      }
      const capture = takeCapture(tab.id, message.captureId);
      if (!capture) throw codedError("stale", "");
      // 견본은 캡처 때의 자리 그대로 이 캡처와 함께만 보낸다. 지금 화면 크기 밖이면 보내지 않는다.
      const calibration = capture.calibration && capture.calibration.x + capture.calibration.w <= viewport.w &&
        capture.calibration.y + capture.calibration.h <= viewport.h ? capture.calibration : null;
      const id = native.nextId("o");
      const line = timelineFor(tab.id, message.action);
      let externalRequest = null;
      const response = await trackedRequest(line, "ocr", (r) => {
        const recordProgress = progressRecorder(tab.id, id, "ocr", engine, page ? message.token : null, line, r);
        const onProgress = (update) => {
          recordProgress?.(update);
          const c = update.counts;
          if (page && Number.isInteger(c?.totalItems) && c.totalItems >= 0 && c.totalItems <= 10000000 &&
              Number.isInteger(c?.totalChars) && c.totalChars >= 0 && c.totalChars <= 10000000) {
            externalRequest = { texts: c.totalItems, chars: c.totalChars };
          }
        };
        return native.request(
          { v: 1, type: "ocr", id, target: message.target, image: capture.dataUrl,
            viewport: { w: viewport.w, h: viewport.h }, regions: message.regions, ...(calibration ? { calibration } : {}), engine,
            ...(companionTexts.length ? { texts: companionTexts } : {}),
            ...(typeof message.pageTitle === "string" ? { pageTitle: message.pageTitle.slice(0, 300) } : {}),
            ...(onProgress ? { progress: true } : {}) },
          { timeout: engineTimeout(engine, TIMEOUT.ocr), tabId: tab.id, kind: "ocr", onProgress });
      }).finally(() => { if (page) noteSecurity(tab.id, message.token, false); });
      if (epoch !== control.epoch || (page && !externalStillAllowed(tab.id, engine, message.token))) throw codedError("cancelled", "");
      const companionResults = Array.isArray(response.texts) && response.texts.length === companionTexts.length
        ? response.texts.map((t) => typeof t === "string" ? t : null) : null;
      if (companionTexts.length && !companionResults) throw codedError("bad_response", "동반 번역 응답 형식이 올바르지 않습니다.");
      return { ok: true, texts: companionResults || [], externalRequest, images: sanitizeImages(response.images),
               missing: Array.isArray(response.missing) ? response.missing.filter((m) => typeof m === "string") : [],
               warning: sanitizeWarning(response.warning), aiRefine: response.aiRefine === true,
               calibration: sanitizeCalibration(response.calibration), timing: sanitizeTiming(response.timing) };
    }
    case "refine": {
      if (!settings.consent) throw codedError("consent_required", "툴바의 Barobogi 아이콘에서 먼저 동의해 주세요.");
      const engine = requestEngine(message, settings);
      if (engine !== LOCAL_ENGINE) throw codedError("bad_request", "다듬기는 Mac 기본 번역에서만 지원합니다.");
      if (!TARGETS.includes(message.target) || !validRefineItems(message.items)) {
        throw codedError("bad_request", "잘못된 다듬기 요청입니다.");
      }
      const response = await native.request(
        { v: 1, type: "refine", id: native.nextId("r"), target: message.target, items: refineItemsForNative(message.items), engine },
        { timeout: TIMEOUT.refine, tabId: tab.id, kind: "refine" });
      if (epoch !== control.epoch) throw codedError("cancelled", "");
      const items = Array.isArray(response.items)
        ? response.items.filter((it) => it && typeof it.k === "string" && typeof it.t === "string" && it.t.length <= LIMITS.textLength)
        : [];
      return { ok: true, items };
    }
    case "endExternalPage": {
      // 내용 스크립트가 1회성 Google·DeepL 번역을 스스로 끝냈다(이동·중지·설정 변경). 그 문서의 토큰일 때만 지운다.
      // 다른 엔진으로 새로 시작한 뒤 늦게 온 옛 토큰의 끝내기는 새 요청을 취소하지 않는다.
      const entry = externalPages.get(tab.id);
      if (entry && entry.token === message.token) {
        externalPages.delete(tab.id);
        if (deadlines.get(tab.id)?.token === message.token) dropDeadline(tab.id);
        native.cancelTab(tab.id);
      }
      return { ok: true };
    }
    case "externalActionStart": {
      // 1회성 외부 번역의 새 동작(클릭 동작은 팝업 요청 때 이미 시작됨, 자동 실행은 실제 일을 보낼 때). 같은 문서·토큰일 때만.
      const engine = pageEngineOf(message);
      if (!engine || !externalAllowedFor(message, sender, tab, engine)) throw codedError("cancelled", "");
      startDeadline(tab.id, engine, message.token, message.action, message.startedAt);
      return { ok: true };
    }
    case "externalActionEnd": {
      // 동작이 결과를 다 그렸다. 한도 안이면 끝으로 기록하고, 이미 넘겼으면(또는 지금 넘겼으면) 초과로 판정해 돌려준다.
      const entry = deadlines.get(tab.id);
      if (!entry || entry.action !== message.action || entry.token !== message.token) {
        // 한도 기록이 없으면(배경이 다시 시작됨 등) 판정할 수 없다. 허용이 남아 있을 때만 끝으로 받는다.
        const engine = pageEngineOf(message);
        const allowed = !!engine && externalStillAllowed(tab.id, engine, message.token);
        return allowed ? { ok: true, timedOut: false, verified: false } : { ok: true, timedOut: false, revoked: true };
      }
      if (entry.state === "running" && entry.securitySince === null && deadlineElapsed(entry, Date.now()) >= entry.limit) {
        deadlineFired(tab.id, entry);
      }
      if (entry.state === "timeout") return { ok: true, timedOut: true, stage: entry.stage, at: entry.at };
      clearTimeout(entry.timer);
      entry.timer = 0;
      entry.state = "ended";
      entry.at = Date.now() - entry.startedAt;
      return { ok: true, timedOut: false, verified: true, securityMs: entry.securityMs };
    }
    case "cancel": {
      dropCapture(tab.id);
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
    images: true, // 이미지 속 글자 번역은 항상 켜져 있다(옵션 아님, 옛 저장값이 꺼짐이어도 무시한다).
    fontStyle: settings.fontStyle,
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
  externalPages.clear();
  clearDeadlines();
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
      // 동의 전에는 Barobogi를 실행하거나 연결하지 않는다.
      let engine = { ok: false, message: "동의하면 Barobogi에 연결합니다." };
      if (settings.consent) {
        try {
          engine = { ok: true, ...(await native.hello()) };
        } catch (error) {
          engine = { ok: false, message: error.message };
        }
      }
      const page = tabId !== null && origin ? await sendToTab(tabId, { cmd: "state" }) : null;
      return { ok: true, settings, origin, engine, page, grant, safari: IS_SAFARI, externalEngines: EXTERNAL_ENGINES,
               native: tabId !== null ? nativeProgressFor(tabId) : [],
               timeline: tabId !== null ? timelineSnapshot(tabId) : null, deadline: tabId !== null ? deadlineSnapshot(tabId) : null };
    }
    case "pageProgress": {
      // 진행 중 팝업 갱신: Barobogi 연결 확인(hello) 없이 이 탭의 내용 스크립트 상태와 기다리는 요청의 진행만 다시 읽는다.
      const page = tabId !== null && origin ? await sendToTab(tabId, { cmd: "state" }) : null;
      return { ok: true, page, native: tabId !== null ? nativeProgressFor(tabId) : [],
               timeline: tabId !== null ? timelineSnapshot(tabId) : null, deadline: tabId !== null ? deadlineSnapshot(tabId) : null };
    }
    case "consent": {
      await api.storage.local.set({ consent: true });
      return { ok: true };
    }
    case "openLanguagePack": {
      if (!settings.consent) throw codedError("consent_required", "먼저 동의해 주세요.");
      const message = await native.openLanguagePack();
      return { ok: true, message };
    }
    case "setTarget": {
      if (!TARGETS.includes(message.target)) throw codedError("bad_request", "지원하지 않는 언어입니다.");
      await api.storage.local.set({ target: message.target });
      // 번역 언어가 바뀌면 이 탭의 1회성 Google·DeepL 번역도 끝난다(내용 스크립트도 설정 변경으로 스스로 끈다).
      if (tabId !== null) { externalPages.delete(tabId); dropDeadline(tabId); }
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
      // 엔진이 바뀌면 진행 중인 요청은 이전 엔진의 것이므로 모두 취소한다. 이 탭의 1회성 Google·DeepL 번역도 끝난다.
      if (tabId !== null) { externalPages.delete(tabId); dropDeadline(tabId); }
      native.cancelAllTabs();
      return { ok: true, page: await reconfigure(tabId, origin) };
    }
    case "revokeEngine": {
      // 지금 고른 웹 번역 엔진의 동의를 철회하고 Mac 기본 번역으로 돌아간다.
      const consents = settings.engineConsents.filter((engine) => engine !== message.engine);
      await api.storage.local.set({ engine: LOCAL_ENGINE, engineConsents: consents });
      // 전송 동의를 거둘 때는 모든 탭의 진행 중인 1회성 Google·DeepL 번역 허용도 함께 끝낸다.
      externalPages.clear();
      clearDeadlines();
      native.cancelAllTabs();
      return { ok: true, page: await reconfigure(tabId, origin) };
    }
    case "setFontStyle": {
      if (!FONT_STYLES.includes(message.fontStyle)) throw codedError("bad_request", "지원하지 않는 글꼴입니다.");
      await api.storage.local.set({ fontStyle: message.fontStyle });
      return { ok: true, page: await reconfigure(tabId, origin) };
    }
    case "translateNow": {
      // 팝업이 보낸 automatic은 '켜 달라'는 뜻일 뿐이다. 켜짐(true)은 배경이 전체 권한을 직접 확인했을 때만 저장한다.
      if (!settings.consent) throw codedError("consent_required", "먼저 동의해 주세요.");
      if (tabId === null) throw codedError("bad_request", "탭을 찾을 수 없습니다.");
      // 일반 번역을 누르면 이 탭의 1회성 Google·DeepL 번역 허용은 끝난다(내용 스크립트도 translateNow에서 스스로 끈다).
      externalPages.delete(tabId);
      dropDeadline(tabId);
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
        // tabOnly(팝업 열 때 한 번 토글)는 이 탭 하나만 수동으로 번역하려는 뜻이라, 전역 자동 번역이 이미
        // 켜져 있어도(다른 탭들은 계속 자동) 그걸 끄지 않는다. 버튼으로 직접 누른 보통 번역 요청만 기존대로
        // 전역 자동 번역이 켜져 있으면 끈다(거절 뒤 이 페이지만 한 번 번역하는 의도된 동작).
        if (message.tabOnly === true) return "manual";
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
      // 경과는 팝업이 잰 클릭 시각부터(내용 스크립트가 범위를 다시 확인한다). trigger: button(버튼) | open(팝업을 열며 실행)
      const page = await sendIfCurrent(tabId, epoch, configureMessage(next, epoch, {
        translateNow: true, trigger: message.trigger === "button" ? "button" : "open",
        ...(Number.isFinite(message.clickedAt) ? { clickedAt: message.clickedAt } : {}) }));
      if (automatic && epoch === control.epoch) configureAllTabs(epoch, tabId).catch(() => {});
      return { ok: true, page, automatic };
    }
    case "toggleOriginal": {
      // 원문 보기는 전역 자동 번역을 끄고, 열려 있는 모든 탭에서 진행 중인 요청을 취소하며 각 탭을 원문으로 되돌린다.
      // 현재 탭이 번역된 적이 없거나 보호된 페이지여도 전역 끄기 자체는 항상 성공한다.
      const { pages } = await globalStop();
      return { ok: true, page: tabId !== null ? pages.get(tabId) ?? null : null };
    }
    case "translatePageOnce":
    case "translatePageGoogleOnce": {
      // 팝업의 명시적 1회성 번역 버튼(Google·DeepL). 전역 자동 번역·저장된 engine 설정은 건드리지 않고, 이 탭의 지금
      // 문서(주소)만 내용 스크립트에게 고른 엔진으로 번역해 달라고 한 번 요청한다. 이동·새로고침·원문 보기로
      // 내용 스크립트의 세대(pageGen)가 바뀌면 그 쪽에서 스스로 멈춘다. translatePageGoogleOnce는 옛 이름(Google 전용)이다.
      const engine = message.cmd === "translatePageGoogleOnce" ? "google" : message.engine;
      if (!PAGE_ENGINES.includes(engine)) throw codedError("bad_request", "지원하지 않는 번역 엔진입니다.");
      if (IS_SAFARI) throw codedError("bad_request", "Safari에서는 지원하지 않습니다.");
      if (!settings.consent) throw codedError("consent_required", "먼저 동의해 주세요.");
      if (tabId === null || !origin) throw codedError("restricted_page", "이 페이지는 번역할 수 없습니다.");
      await injectContent(tabId, origin);
      const currentTab = await api.tabs.get(tabId);
      // 이 탭의 이전 1회성 허용(다른 엔진 포함)은 새 토큰으로 바뀌며 끝난다. 이전 엔진으로 보낸 요청도 취소한다.
      if (externalPages.has(tabId)) native.cancelTab(tabId);
      const token = crypto.randomUUID();
      externalPages.set(tabId, { engine, url: currentTab.url, token, documentId: null });
      // 이 클릭의 동작 id와 클릭 시각. DeepL은 지금 바로 전체 시간 한도를 시작한다(주입·이전 패스 정리 시간도 포함).
      const now = Date.now();
      const clickedAt = Number.isFinite(message.clickedAt) && message.clickedAt <= now && message.clickedAt >= now - 60000
        ? message.clickedAt : now;
      const action = `c${now.toString(36)}-${crypto.randomUUID().slice(0, 8)}`;
      dropDeadline(tabId);
      startDeadline(tabId, engine, token, action, clickedAt);
      const epoch = control.epoch;
      const page = await sendIfCurrent(tabId, epoch, { cmd: "startExternalPage", epoch, engine, target: settings.target, token,
                                                      action, clickedAt });
      if (!page) {
        if (externalPages.get(tabId)?.token === token) externalPages.delete(tabId);
        if (deadlines.get(tabId)?.token === token) dropDeadline(tabId);
        throw codedError("bad_response", "Barobogi 확장과 통신하지 못했습니다.");
      }
      return { ok: true, page };
    }
    case "stopPageOnce":
    case "stopPageGoogleOnce": {
      if (tabId === null) throw codedError("bad_request", "탭을 찾을 수 없습니다.");
      externalPages.delete(tabId);
      dropDeadline(tabId);
      native.cancelTab(tabId);
      const page = await sendToTab(tabId, { cmd: "stopExternalPage" });
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
    if (message.cmd === "progress") {
      handleProgress(message, sender);
      return false; // 응답 없음(배경 전용 신호)
    }
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
  // 주소가 바뀌면(기록 API 이동 포함) 그 탭의 1회성 Google·DeepL 번역 허용은 끝난다.
  if (typeof info.url === "string") { externalPages.delete(tabId); dropDeadline(tabId); }
  if (info.status === "loading") {
    externalPages.delete(tabId);
    dropCapture(tabId);
    native.cancelTab(tabId);
    nativeProgress.delete(tabId);
    // 새 문서에는 이전 문서의 경과·단계·시간 한도 기록을 남기지 않는다.
    timelines.delete(tabId);
    clearTimeout(deadlines.get(tabId)?.timer);
    deadlines.delete(tabId);
    // 새로 불러오는 페이지는 아직 번역한 적이 없으므로 이전 페이지의 아이콘·회전 오버레이가
    // 그대로 남지 않게 기본 상태로 되돌린다(내용 스크립트가 다시 붙을 때까지 기다리지 않음).
    const previous = tabProgress.get(tabId);
    if (previous) stopSpinner(previous);
    tabProgress.delete(tabId);
    updateTabIcon(tabId).catch(() => {});
  }
  if (info.status !== "complete" || !tab?.url || !originOf(tab.url)) return;
  applyAutoToTab(tabId, control.epoch).catch(() => {});
});

api.tabs.onRemoved.addListener((tabId) => {
  externalPages.delete(tabId);
  captures.delete(tabId);
  captureTickets.delete(tabId);
  native.cancelTab(tabId);
  nativeProgress.delete(tabId);
  timelines.delete(tabId);
  clearTimeout(deadlines.get(tabId)?.timer);
  deadlines.delete(tabId);
  const previous = tabProgress.get(tabId);
  if (previous) stopSpinner(previous);
  tabProgress.delete(tabId);
  // 자동 번역 중이던 번역 창(탭)이 모두 닫히면 자동 번역도 함께 끈다(다음에 새로 여는 탭에서는 다시 켜지지 않음).
  // 남은 탭이 없는지는 다음 실행 루프에서 확인한다(onRemoved 시점에는 닫히는 탭이 아직 목록에 남아 있을 수 있음).
  if (!control.armed) return;
  setTimeout(() => {
    if (!control.armed) return;
    api.tabs.query({}).then((tabs) => {
      if (control.armed && tabs.length === 0) globalStop().catch(() => {});
    }).catch(() => {});
  }, 0);
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

// 새 탭의 기본 툴바 아이콘(아직 특정 탭에 맞춰지기 전)을 빨강(원문 보기)으로 둔다 — 그래야 막 연 탭이
// 내용 스크립트가 붙기 전까지 잠깐이라도 기존 파랑으로 보이지 않는다. tabId 없이 설정하면 전역 기본값이 된다.
iconReady.then((icons) => {
  if (icons && typeof api.action?.setIcon === "function") {
    api.action.setIcon({ imageData: icons.red }).catch(() => {});
  }
}).catch(() => {});

// 워커가 막 시작했을 때(설치·업데이트·재시작 포함) 이미 열려 있는 탭들의 실제 상태(번역 보기·처리 중 여부)를
// 내용 스크립트에 물어 tabProgress를 채운다. 응답이 없으면(아직 안 붙음·보호된 페이지 등) 기본값(원문·빨강)을
// 그대로 둔다 — invent하지 않고 content.js의 state 응답에 있는 view·running 필드만 그대로 쓴다.
(async () => {
  let tabs = [];
  try { tabs = await api.tabs.query({}); } catch { tabs = []; }
  await Promise.all(tabs.filter((tab) => Number.isInteger(tab.id)).map(async (tab) => {
    const page = await sendToTab(tab.id, { cmd: "state" });
    // 조회 중 새 진행 메시지나 페이지 이동이 들어왔으면 그 최신 상태를 보존한다.
    if (page && !tabProgress.has(tab.id)) tabProgress.set(tab.id, { view: page.view === "original" ? "original" : "translated",
                                         running: page.running === true, timer: 0, frame: 0 });
    updateTabIcon(tab.id).catch(() => {});
  }));
})().catch(() => {});
