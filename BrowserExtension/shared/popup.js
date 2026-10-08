"use strict";
// SMT 웹 번역 팝업: 동의, 번역 언어, 번역(전역 자동 번역 켜기), 원문 보기(전역 자동 번역 끄기), 이미지 번역, 상태.

const api = globalThis.browser ?? globalThis.chrome;
const IS_SAFARI = api.runtime.getURL("").startsWith("safari-web-extension:");
const ALL_URLS = "<all_urls>";
const $ = (id) => document.getElementById(id);
let tabId = null;
let origin = null;
let current = null;
let notice = ""; // 번역 버튼 결과 안내(새로 고침해도 다른 오류가 없으면 계속 보인다)

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
  $("images").checked = state.settings.images;
  $("translate").disabled = tabId === null;
  // 이 탭이 아직 번역되지 않았어도 전역 자동 번역이 켜져 있으면 전역으로 끌 수 있어야 한다.
  $("original").disabled = !state.page && !state.settings.automaticEnabled;
  if (state.settings.automaticEnabled) {
    $("autoStatus").textContent = "자동 번역 켜짐 · 열린 탭과 이후 여는 http/https 페이지에 적용 · 원문 보기로 전체 끄기";
  } else if (!IS_SAFARI && !state.grant) {
    $("autoStatus").textContent = "자동 번역 꺼짐 · 번역을 누르면 모든 웹사이트 접근 권한을 묻습니다";
  } else {
    $("autoStatus").textContent = "자동 번역 꺼짐 · 번역을 누르면 시작";
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
