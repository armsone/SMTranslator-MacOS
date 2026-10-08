"use strict";
// SMT 웹 번역 팝업: 동의, 번역 언어, 번역 엔진(웹 번역은 엔진별 전송 동의 후), 번역(전역 자동 번역 켜기),
// 원문 보기(전역 자동 번역 끄기), 이미지 번역, 상태. 엔진을 고르는 것만으로는 아무것도 보내지 않는다.

const api = globalThis.browser ?? globalThis.chrome;
const IS_SAFARI = api.runtime.getURL("").startsWith("safari-web-extension:");
const ALL_URLS = "<all_urls>";
const $ = (id) => document.getElementById(id);
let tabId = null;
let origin = null;
let current = null;
let notice = ""; // 번역 버튼 결과 안내(새로 고침해도 다른 오류가 없으면 계속 보인다)
let pendingEngine = null; // 동의를 기다리는 웹 번역 엔진
const ENGINE_NAMES = { apple: "Mac 기본 번역", deepl: "DeepL", google: "Google 번역", papago: "Papago" };

// 0.5.0 이전 배경 작업자는 settings.engine 자체가 없다(필드가 문자열이 아님). 그 경우 새 번역 엔진
// 기능(engineConsents 등)을 쓸 수 없으니, 그 사실을 솔직히 알리고 외부 전송을 임의로 주장하지 않는다.
function isLegacyBackground(state) {
  return typeof state?.settings?.engine !== "string";
}

// 알려진 엔진 키만 유효하게 취급한다(Object.hasOwn으로 프로토타입 체인 값을 배제해
// "__proto__" 같은 값이 유효한 엔진으로 오판되지 않도록 한다).
function isKnownEngine(engine) {
  return typeof engine === "string" && Object.hasOwn(ENGINE_NAMES, engine);
}

// 알 수 없거나 비어 있는 엔진 값은 절대 그대로 화면에 보여주지 않고(undefined 노출 방지),
// 실제로 외부로 보냈다고 거짓 주장하지 않도록 안전하게 Mac 기본 번역으로만 표시한다.
function safeEngineName(engine) {
  return isKnownEngine(engine) ? ENGINE_NAMES[engine] : ENGINE_NAMES.apple;
}

function engineConsentText(engine) {
  const name = ENGINE_NAMES[engine] || engine;
  return `${name}을(를) 고르면, 번역할 때 이 페이지에서 찾은 글자(이미지 속 글자는 이 Mac에서 인식한 텍스트만)를 SMT 앱이 ` +
    `${name} 공식 웹페이지에 한 조각씩 입력해 번역합니다. 화면 캡처 이미지·페이지 HTML·페이지 주소는 보내지 않습니다. ` +
    `보낸 내용에는 ${name}의 정책이 적용되며 서비스 쪽에 기록될 수 있습니다. 자동 번역이 켜져 있으면 이후 여는 페이지의 글자도 보냅니다. ` +
    `SMT 앱(설정 › 웹 번역 전송 동의)에서도 ${name} 동의가 필요합니다. 고르는 것만으로는 보내지 않습니다.`;
}

function showError(message) {
  $("error").textContent = message || "";
  $("error").hidden = !message;
}

async function call(message) {
  const response = await api.runtime.sendMessage({ ...message, tabId });
  if (!response || response.ok !== true) throw new Error(response?.message || "요청을 처리하지 못했습니다.");
  return response;
}

function render(state) {
  current = state;
  const engine = $("engine");
  if (!state.settings.consent) {
    engine.textContent = "동의 필요";
    engine.className = "pill";
  } else if (state.engine.ok && state.engine.enabled) {
    engine.textContent = "SMT 연결됨";
    engine.className = "pill ok";
  } else {
    engine.textContent = "연결 안 됨";
    engine.className = "pill bad";
  }
  $("consent").hidden = state.settings.consent;
  $("main").hidden = !state.settings.consent;
  $("target").value = state.settings.target;
  const legacy = isLegacyBackground(state);
  // 알려진 엔진 값이 아니거나(미판별) 레거시 배경이면 Mac 기본 번역으로만 표시한다. 저장된 설정은 바꾸지 않는다.
  const displayEngine = !legacy && isKnownEngine(state.settings.engine) ? state.settings.engine : "apple";
  // 웹 번역 엔진은 Chrome·Whale에서, 그 엔진을 지원하는 SMT와 연결됐을 때만 고를 수 있다.
  const available = state.engine.ok && Array.isArray(state.engine.externalEngines) ? state.engine.externalEngines : [];
  for (const option of $("engineSelect").options) {
    if (option.value === "apple") continue;
    // 레거시 배경 작업자는 engineConsents/setEngine을 모르므로 새로고침 전까지 외부 엔진을 고를 수 없게 막는다.
    option.disabled = legacy || state.safari || !available.includes(option.value);
  }
  if (!pendingEngine) $("engineSelect").value = displayEngine;
  $("engineConsent").hidden = !pendingEngine;
  if (legacy) {
    $("engineNote").textContent = "확장 관리에서 새로고침해 주세요.";
  } else if (state.safari) {
    $("engineNote").textContent = "Safari · Mac 기본 번역";
  } else if (displayEngine !== "apple") {
    $("engineNote").textContent = `${safeEngineName(displayEngine)} 외부 전송 · `;
  } else {
    $("engineNote").textContent = "";
  }
  $("engineNote").hidden = !$("engineNote").textContent;
  if (!legacy && !state.safari && displayEngine !== "apple") {
    const revoke = document.createElement("button");
    revoke.className = "linkButton";
    revoke.textContent = "동의 철회";
    revoke.addEventListener("click", async () => {
      await call({ cmd: "revokeEngine", engine: displayEngine }).catch((e) => showError(e.message));
      refresh();
    });
    $("engineNote").appendChild(revoke);
  }
  $("images").checked = state.settings.images;
  $("translate").disabled = tabId === null;
  // 이 탭이 아직 번역되지 않았어도 전역 자동 번역이 켜져 있으면 전역으로 끌 수 있어야 한다.
  $("original").disabled = !state.page && !state.settings.automaticEnabled;
  if (state.settings.automaticEnabled) {
    $("autoStatus").textContent = "자동 번역 켜짐";
  } else if (!IS_SAFARI && !state.grant) {
    $("autoStatus").textContent = "자동 번역 꺼짐 · 접근 허용 필요";
  } else {
    $("autoStatus").textContent = "자동 번역 꺼짐";
  }

  let status = "";
  if (state.settings.consent && state.engine.ok && !state.engine.enabled) {
    showError("SMT 메뉴 막대 › 브라우저 번역…에서 '브라우저 확장 연결 허용'을 켜 주세요.");
  } else if (state.settings.consent && !state.engine.ok) {
    showError(state.engine.message);
  } else if (state.page?.error) {
    showError(state.page.error);
  } else {
    showError(notice);
  }
  if (state.page) {
    status = `${state.page.status} · 글자 ${state.page.translated}개` + (state.page.imageCount ? ` · 이미지 ${state.page.imageCount}개` : "");
    if (state.page.warning) status += ` · ${state.page.warning}`;
  } else if (!origin) {
    status = "이 페이지는 번역할 수 없습니다.";
  }
  $("status").textContent = status;
  renderLangCounts(state.page ? state.page.langCounts : null);
}

// 언어 코드를 한글 locale 이름으로 안전하게 표시(중국어 간체/번체 등 포함). 지원 안 되는 환경이면 코드 그대로.
function langLabel(code) {
  if (code === "unknown") return "미판별";
  try {
    const name = new Intl.DisplayNames(["ko"], { type: "language" }).of(code);
    return typeof name === "string" && name ? name : code;
  } catch {
    return code;
  }
}

// 원문 언어별 인식 개수(텍스트 조각·OCR 문단 기준)를 상태 아래에 한 줄로 보여준다. 집계가 없으면 숨긴다.
function renderLangCounts(langCounts) {
  const el = $("langStats");
  const entries = langCounts && typeof langCounts === "object"
    ? Object.entries(langCounts).filter(([, n]) => Number.isFinite(n) && n > 0)
    : [];
  if (!entries.length) {
    el.hidden = true;
    el.textContent = "";
    return;
  }
  entries.sort((a, b) => {
    if (a[0] === "unknown") return 1;
    if (b[0] === "unknown") return -1;
    if (b[1] !== a[1]) return b[1] - a[1];
    return a[0].localeCompare(b[0]);
  });
  el.textContent = `인식: ${entries.map(([code, n]) => `${langLabel(code)} ${n}문장`).join(" · ")}`;
  el.hidden = false;
}

async function refresh() {
  try {
    render(await call({ cmd: "popupState" }));
  } catch (error) {
    showError(error.message);
  }
}

$("agree").addEventListener("click", async () => {
  await call({ cmd: "consent" }).catch((e) => showError(e.message));
  refresh();
});

$("target").addEventListener("change", async (event) => {
  await call({ cmd: "setTarget", target: event.target.value }).catch((e) => showError(e.message));
  refresh();
});

$("engineSelect").addEventListener("change", async (event) => {
  const engine = event.target.value;
  showError("");
  if (isLegacyBackground(current)) {
    // 레거시 배경 작업자는 setEngine/engineConsents를 모른다. 불필요한 명령을 보내지 않고 되돌린다.
    event.target.value = "apple";
    return;
  }
  if (engine !== "apple" && !(current?.settings.engineConsents || []).includes(engine)) {
    // 전송 안내를 보여 주고 동의를 받을 때까지 이전 엔진을 유지한다.
    pendingEngine = engine;
    $("engineConsentText").textContent = engineConsentText(engine);
    $("engineConsent").hidden = false;
    return;
  }
  pendingEngine = null;
  await call({ cmd: "setEngine", engine }).catch((e) => showError(e.message));
  refresh();
});

$("engineAgree").addEventListener("click", async () => {
  const engine = pendingEngine;
  pendingEngine = null;
  if (engine) await call({ cmd: "setEngine", engine, consent: true }).catch((e) => showError(e.message));
  refresh();
});

$("engineCancel").addEventListener("click", () => {
  pendingEngine = null;
  $("engineConsent").hidden = true;
  if (current) {
    const displayEngine = !isLegacyBackground(current) && isKnownEngine(current.settings.engine) ? current.settings.engine : "apple";
    $("engineSelect").value = displayEngine;
  }
});

$("images").addEventListener("change", async (event) => {
  await call({ cmd: "setImages", enabled: event.target.checked }).catch((e) => showError(e.message));
  refresh();
});

$("translate").addEventListener("click", async () => {
  // 권한 요청은 클릭 처리의 첫 동작(어떤 await보다 먼저)이어야 브라우저 확인 창이 뜬다(몰래 켜지 않는다).
  // 이미 허용했으면 다시 묻지 않고 true. Safari는 사이트별 허용을 Safari 설정이 관리한다.
  let permission;
  try {
    permission = IS_SAFARI ? Promise.resolve(true) : Promise.resolve(api.permissions.request({ origins: [ALL_URLS] }));
  } catch {
    permission = Promise.resolve(false);
  }
  $("translate").disabled = true;
  notice = "";
  showError("");
  try {
    const granted = (await permission.catch(() => false)) === true;
    // 실제로 켜졌는지는 배경이 권한을 다시 확인해 정한다(팝업 결과만 믿지 않음).
    const response = await call({ cmd: "translateNow", automatic: granted });
    if (response.superseded) {
      notice = "원문 보기가 먼저 처리되어 번역을 시작하지 않았습니다.";
    } else if (!response.automatic) {
      notice = response.restricted
        ? "모든 웹사이트 접근이 허용되지 않아 자동 번역은 꺼져 있고, 이 페이지는 브라우저 정책상 번역할 수 없습니다."
        : "모든 웹사이트 접근이 허용되지 않아 자동 번역은 꺼져 있습니다. 이 페이지만 한 번 번역합니다.";
    } else if (response.restricted) {
      notice = "자동 번역을 켰습니다. 이 페이지는 브라우저 정책상 번역할 수 없어 다른 일반 웹페이지부터 적용됩니다.";
    }
    showError(notice);
    if (!response.superseded && !response.restricted) $("status").textContent = "번역 중…";
    setTimeout(refresh, 1200);
  } catch (error) {
    showError(error.message);
  } finally {
    $("translate").disabled = false;
  }
});

$("original").addEventListener("click", async () => {
  notice = "";
  try {
    await call({ cmd: "toggleOriginal" });
    refresh();
  } catch (error) {
    showError(error.message);
  }
});

(async () => {
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  tabId = Number.isInteger(tab?.id) ? tab.id : null;
  try {
    const url = new URL(tab?.url || "");
    origin = url.protocol === "http:" || url.protocol === "https:" ? url.origin : null;
  } catch {
    origin = null;
  }
  refresh();
})();
