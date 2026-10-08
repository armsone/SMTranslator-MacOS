"use strict";
// SMT 웹 번역 팝업: 동의, 번역 언어, 이 페이지 번역, 원문/번역 전환, 사이트 자동 번역, 이미지 번역, 상태.

const api = globalThis.browser ?? globalThis.chrome;
const $ = (id) => document.getElementById(id);
let tabId = null;
let origin = null;
let current = null;

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
  $("auto").checked = state.siteEnabled && state.permitted;
  $("auto").disabled = !origin;
  $("translate").disabled = tabId === null;
  $("original").textContent = state.page?.view === "original" ? "번역 보기" : "원문 보기";
  $("original").disabled = !state.page;
  if (state.siteEnabled && !state.permitted) $("autoLabel").textContent = "이 사이트 자동 번역 (사이트 접근 권한 필요)";

  let status = "";
  if (state.settings.consent && state.engine.ok && !state.engine.enabled) {
    showError("SMT 메뉴 막대 › 브라우저 번역…에서 '브라우저 확장 연결 허용'을 켜 주세요.");
  } else if (state.settings.consent && !state.engine.ok) {
    showError(state.engine.message);
  } else if (state.page?.error) {
    showError(state.page.error);
  } else {
    showError("");
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

$("auto").addEventListener("change", (event) => {
  const enabled = event.target.checked;
  if (!origin) return;
  // 권한 요청은 클릭 처리 안에서 바로 불러야 브라우저 확인 창이 뜬다.
  const permission = enabled
    ? Promise.resolve(api.permissions.request({ origins: [`${origin}/*`] }))
    : Promise.resolve(true);
  permission.then(async (granted) => {
    if (!granted) {
      event.target.checked = false;
      showError("사이트 접근을 허용하지 않아 자동 번역을 켜지 않았습니다.");
      return;
    }
    await call({ cmd: "setSite", enabled }).catch((e) => showError(e.message));
    refresh();
  }, (error) => {
    event.target.checked = false;
    showError(error?.message || "권한을 요청하지 못했습니다.");
  });
});

$("translate").addEventListener("click", async () => {
  $("translate").disabled = true;
  try {
    await call({ cmd: "translateNow" });
    $("status").textContent = "번역 중…";
    setTimeout(refresh, 1200);
  } catch (error) {
    showError(error.message);
  } finally {
    $("translate").disabled = false;
  }
});

$("original").addEventListener("click", async () => {
  try {
    const response = await call({ cmd: "toggleOriginal" });
    render({ ...current, page: response.page });
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
