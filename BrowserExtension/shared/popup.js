"use strict";
// Barobogi 웹 번역 팝업: 동의, 번역 언어, 번역(전역 자동 번역 켜기), 원문 보기(전역 자동 번역 끄기), 상태.
// 번역 방식은 Mac 기본 번역(기기 내) + Apple Intelligence 다듬기(가능할 때)로 고정이며 고를 수 없다.
// 이미지 속 글자 번역은 항상 켜져 있다(옵션 아님).

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
    engine.textContent = "Barobogi 연결됨";
    engine.className = "pill ok";
  } else {
    engine.textContent = "연결 안 됨";
    engine.className = "pill bad";
  }
  $("consent").hidden = state.settings.consent;
  $("main").hidden = !state.settings.consent;
  $("target").value = state.settings.target;
  $("fontStyle").value = ["auto", "gothic", "myeongjo", "gungseo", "hand"].includes(state.settings.fontStyle) ? state.settings.fontStyle : "auto";
  $("translate").disabled = tabId === null;
  // 이 탭이 아직 번역되지 않았어도 전역 자동 번역이 켜져 있으면 전역으로 끌 수 있어야 한다.
  $("original").disabled = !state.page && !state.settings.automaticEnabled;
  const isTranslated = state.page?.view === "translated";
  $("translate").classList.toggle("active", isTranslated);
  $("original").classList.toggle("active", !isTranslated);
  if (state.settings.automaticEnabled) {
    $("autoStatus").textContent = "자동 번역 켜짐";
  } else if (!IS_SAFARI && !state.grant) {
    $("autoStatus").textContent = "자동 번역 꺼짐 · 접근 허용 필요";
  } else {
    $("autoStatus").textContent = "자동 번역 꺼짐";
  }

  let status = "";
  if (state.settings.consent && state.engine.ok && !state.engine.enabled) {
    showError("Barobogi 메뉴 막대 › 브라우저 번역…에서 '브라우저 확장 연결 허용'을 켜 주세요.");
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
  $("statusText").textContent = status;
  // 실제로 번역·OCR·다듬기가 진행 중일 때만 돈다(단순 자동 감시 중에는 돌지 않음, 가짜 진행률 없음).
  $("spinner").hidden = !(state.page && state.page.running === true);
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

$("langPack").addEventListener("click", async () => {
  // Barobogi에 실제 다운로드 화면을 열어 달라고 요청한다(언어/지역 설정이 아니다). Safari처럼 이 확장이 직접 그 화면을
  // 열 수 없을 때는 응답에 안내 문구가 실려 오므로 그걸 그대로 보여준다(엉뚱한 설정을 연 것처럼 꾸미지 않는다).
  // 연결이 안 돼 있을 때만(Barobogi 미실행 등) 가장 가까운 시스템 설정으로 대체한다.
  try {
    const response = await call({ cmd: "openLanguagePack" });
    if (response.message) showError(response.message);
  } catch (error) {
    showError(error.message);
    window.open("x-apple.systempreferences:com.apple.Localization-Settings.extension", "_blank");
  }
});

$("fontStyle").addEventListener("change", async (event) => {
  await call({ cmd: "setFontStyle", fontStyle: event.target.value }).catch((e) => showError(e.message));
  refresh();
});

// 번역 보기 동작(버튼 클릭·툴바 아이콘 클릭으로 팝업이 열릴 때 둘 다 이 함수 하나만 쓴다).
// gesture=true(버튼 클릭)일 때만 권한 요청(permissions.request)을 쓴다 — 클릭 처리의 첫 동작(어떤
// await보다 먼저)이어야 브라우저 확인 창이 뜬다. gesture=false(팝업이 열리며 자동 실행)는 사용자
// 클릭 제스처가 아니므로 권한 창을 띄우지 않고 이미 허용돼 있는지만 조용히 확인한다(permissions.contains).
// 두 경우 모두 실제로 켜졌는지는 배경이 다시 확인해 정한다(automatic은 '켜 달라'는 요청일 뿐).
async function runTranslate(gesture) {
  let permission;
  try {
    if (IS_SAFARI) {
      permission = Promise.resolve(true);
    } else if (gesture) {
      permission = Promise.resolve(api.permissions.request({ origins: [ALL_URLS] }));
    } else {
      permission = Promise.resolve(api.permissions.contains({ origins: [ALL_URLS] }));
    }
  } catch {
    permission = Promise.resolve(false);
  }
  $("translate").disabled = true;
  notice = "";
  showError("");
  try {
    const granted = (await permission.catch(() => false)) === true;
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
    if (!response.superseded && !response.restricted) {
      $("statusText").textContent = "번역 중…";
      $("spinner").hidden = false;
    }
    setTimeout(refresh, 1200);
  } catch (error) {
    showError(error.message);
  } finally {
    $("translate").disabled = false;
  }
}

$("translate").addEventListener("click", () => runTranslate(true));

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
  // 툴바 아이콘을 눌러 팝업이 열릴 때마다 '번역 보기'를 누른 것과 같은 동작을 한 번만 한다(원문으로
  // 되돌리지 않음 — '원문 보기'는 팝업에서 사용자가 직접 눌러야만 한다). 이 탭에 이전 상태가 없어도
  // (opened.page가 없는 첫 방문 페이지여도) translateNow가 필요하면 내용 스크립트를 넣어 처리한다.
  try {
    const opened = await call({ cmd: "popupState" });
    if (opened.settings.consent) await runTranslate(false);
  } catch {
    // 실패는 조용히 무시하고 아래 refresh()가 실제 상태를 그대로 보여준다.
  }
  refresh();
})();
