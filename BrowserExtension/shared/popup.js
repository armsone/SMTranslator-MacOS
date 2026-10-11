"use strict";
// Barobogi 웹 번역 팝업: 동의, 번역 언어, 번역(전역 자동 번역 켜기), 원문 보기(전역 자동 번역 끄기), 상태.
// 번역 방식은 Mac 기본 번역(기기 내) + Apple Intelligence 다듬기(가능할 때)이다. '구글'·'DeepL' 버튼은 지금 문서만 한 번
// 그 서비스로 번역하며(저장된 전역 엔진·자동 번역은 바꾸지 않음), 서비스별 전송 동의는 Barobogi 앱 설정에서 한다.
// 이미지 속 글자 번역은 항상 켜져 있다(옵션 아님).

const api = globalThis.browser ?? globalThis.chrome;
const IS_SAFARI = api.runtime.getURL("").startsWith("safari-web-extension:");
const ALL_URLS = "<all_urls>";
const $ = (id) => document.getElementById(id);
let tabId = null;
let origin = null;
let current = null;
let notice = ""; // 번역 버튼 결과 안내(새로 고침해도 다른 오류가 없으면 계속 보인다)
// 팝업이 열린 시각(툴바 아이콘 클릭). 팝업을 열며 실행하는 번역의 경과는 이 시각부터 잰다(이미 번역 중·번역된 문서는 그대로 둔다).
const OPENED_AT = Date.now();

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
    engine.textContent = "작동중";
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
  // 보기 선택(파랑)은 번역 보기면 항상 '번역'이다. 1회성 구글·DeepL 번역 중이어도 그 버튼이 보기 선택을 대신하지 않고,
  // 어느 서비스로 번역했는지는 그 버튼의 얇은 테두리(engineOn)와 상태 줄로만 보인다.
  $("translate").classList.toggle("active", isTranslated);
  $("original").classList.toggle("active", !isTranslated);
  if (state.settings.automaticEnabled) {
    $("autoStatus").textContent = "자동 번역 켜짐";
  } else if (!IS_SAFARI && !state.grant) {
    $("autoStatus").textContent = "자동 번역 꺼짐 · 접근 허용 필요";
  } else {
    $("autoStatus").textContent = "자동 번역 꺼짐";
  }

  if (state.settings.consent && state.engine.ok && !state.engine.enabled) {
    showError("Barobogi 메뉴 막대 › 브라우저 번역…에서 '브라우저 확장 연결 허용'을 켜 주세요.");
  } else if (state.settings.consent && !state.engine.ok) {
    showError(state.engine.message);
  } else if (state.page?.error) {
    showError(state.page.error);
  } else {
    showError(notice);
  }
  const running = state.page?.running === true;
  // 이 문서의 지금 동작과 같은 id의 배경 기록(네이티브 단계 시각·시간 한도)만 쓴다(다른 동작·이전 문서 것은 버린다).
  const action = state.page?.action || null;
  const timeline = action && state.timeline?.action === action.id ? state.timeline.marks : [];
  const deadline = action && state.deadline?.action === action.id ? state.deadline : null;
  // 기본 표시는 두 줄뿐이다: ① 지금 단계(또는 완료·중단) + 오른쪽 경과 시간 ② 이미지 수 · 전체 문장 수. 나머지는 '처리 상세'.
  let status = "";
  if (state.page) {
    status = mainStatus(state.page, state.native, action, deadline);
  } else if (!origin) {
    status = "이 페이지는 번역할 수 없습니다.";
  }
  $("statusText").textContent = status;
  shownAction = action;
  renderElapsed();
  // 실제로 번역·OCR·다듬기가 진행 중일 때만 돈다(단순 자동 감시 중에는 돌지 않음, 가짜 진행률 없음). 상태 줄과 '번역' 버튼에 함께 보인다.
  $("spinner").hidden = !running;
  $("translateSpinner").hidden = !running;
  renderLine("summary", summaryLine(state.page, state.native, action));
  renderDetails(state.page, state.native, action, deadline, timeline);
  PAGE_ENGINES.forEach(({ engine, button, spinner, title }) => renderExternalPage(state, engine, button, spinner, title));
  schedulePoll(running || action?.outcome === null);
}

const count = (n) => (Number.isFinite(n) && n > 0 ? Math.round(n) : 0).toLocaleString("ko-KR");
const seconds = (ms) => `${(Math.max(0, ms) / 1000).toFixed(1)}초`;
const ENGINE_TITLES = { google: "구글", deepl: "DeepL", papago: "Papago" };

function renderLine(id, text) {
  $(id).textContent = text;
  $(id).hidden = !text;
}

// MARK: 경과 시간(클릭 시각부터, 진행 중이면 0.1초마다 갱신, 끝나면 그 자리에서 멈춤)

let shownAction = null;
let elapsedTimer = 0;

function renderElapsed() {
  const action = shownAction;
  clearInterval(elapsedTimer);
  elapsedTimer = 0;
  if (!action || !Number.isFinite(action.startedAt)) {
    $("elapsed").textContent = "";
    return;
  }
  if (action.outcome !== null) {
    $("elapsed").textContent = Number.isFinite(action.endedAt) ? seconds(action.endedAt) : "";
    return;
  }
  const paint = () => { $("elapsed").textContent = seconds(Date.now() - action.startedAt); };
  paint();
  elapsedTimer = setInterval(paint, 100);
}

/** 이 탭에서 아직 기다리는 Barobogi 요청의 최신 진행(배경이 요청 id·엔진·허용 토큰으로 거른 것). kind: "text"|"ocr"|null(아무거나) */
function latestNative(nativeList, kind, phase = null) {
  let best = null;
  for (const entry of Array.isArray(nativeList) ? nativeList : []) {
    if (kind && entry.kind !== kind) continue;
    if (phase && entry.phase !== phase) continue;
    if (!best || entry.at > best.at) best = entry;
  }
  return best;
}

/** 지금 실제 단계. 진행 중이 아니면 다듬기 중일 때만 이름을 돌려주고, 아니면 null(결과 요약을 보인다). */
function phaseLabel(page, nativeList) {
  const inventory = page?.inventory;
  if (!inventory) return null;
  if (inventory.phase === "refine") {
    return `Apple Intelligence 문장 다듬기 중${inventory.refineItems ? ` · ${count(inventory.refineItems)}문장` : ""}`;
  }
  if (page.running !== true) return null;
  const title = ENGINE_TITLES[inventory.engine] || "외부 번역";
  const progress = latestNative(nativeList, inventory.phase === "ocr" ? "ocr" : "text");
  if (progress?.phase === "external") {
    if (progress.step === "challenge") return `${title} 보안 확인 대기 중 · 열린 창에서 직접 완료하세요`;
    if (progress.step === "waiting") return `${title} 결과 대기 중`;
    if (progress.step === "opening") return `${title} 페이지 준비 중`;
    if (progress.step === "input") return `${title} 입력 중`;
    return `${title} 전송 중`;
  }
  if (progress?.phase === "translating") return "온보드 번역 중";
  if (progress?.phase === "recognized") return "이미지 인식 완료 · 번역 준비 중";
  switch (inventory.phase) {
    case "search": return "검색 중";
    case "translating": return "온보드 번역 중";
    case "external": return `${title} 전송 중`;
    case "ocr": return "이미지 인식 중";
    default: return null;
  }
}

// 내용 스크립트의 단계(클릭부터 이어지는 구간)와 네이티브 요청 안 단계(배경이 잰 시각)의 이름.
const CONTENT_STAGES = { start: "시작 준비", search: "검색", text: "온보드 번역", capture: "이미지 확인·캡처", ocr: "이미지 요청",
                         render: "그리기", refine: "AI 다듬기" };

function contentStageLabel(stage, engine) {
  if (stage === "external") return `${ENGINE_TITLES[engine] || "외부 번역"} 일반 글자`;
  return CONTENT_STAGES[stage] || null;
}

/** 네이티브 단계 이름(k: text|ocr, p: sent|recognized|translating|external:단계). */
function nativeStageLabel(kind, phase, engine) {
  const title = ENGINE_TITLES[engine] || "외부 번역";
  const external = engine && engine !== "apple";
  switch (phase) {
    case "sent": return kind === "ocr" ? "이미지 인식(Mac)" : external ? `${title} 요청 준비` : "온보드 번역(Mac)";
    case "recognized": return "복원·번역 준비(Mac)";
    case "translating": return "온보드 번역(Mac)";
    case "external": return `${title} 전송`;
    case "external:opening": return `${title} 페이지 준비`;
    case "external:input": return `${title} 입력`;
    case "external:waiting": return `${title} 결과 대기`;
    case "external:challenge": return "보안 확인(직접)";
    default: return null;
  }
}

/** 시간 초과로 멈춘 단계: 네이티브 요청 안이면 그 단계, 아니면 내용 스크립트 단계. */
function stopStageLabel(action, deadline) {
  const nativeStage = action.stopStage?.native || deadline?.stage || null;
  if (typeof nativeStage === "string" && nativeStage.includes("/")) {
    const [kind, phase] = nativeStage.split("/");
    const label = nativeStageLabel(kind, phase, action.engine);
    if (label) return label.replace(/\(.*\)$/, "");
  }
  return contentStageLabel(action.stopStage?.content, action.engine) || "처리 중";
}

/** ① 단계 줄: 진행 중이면 지금 단계, 끝났으면 완료·중단·시간 초과. */
function mainStatus(page, nativeList, action, deadline) {
  const timedOut = action?.outcome === "timeout" || deadline?.state === "timeout";
  if (timedOut) {
    const limit = Number.isFinite(deadline?.limit) ? deadline.limit : 15000;
    return `${Math.round(limit / 1000)}초 초과 · ${stopStageLabel(action, deadline)}에서 중단`;
  }
  if (page.running === true || action?.outcome === null) {
    return phaseLabel(page, nativeList) || "번역 중";
  }
  if (action?.outcome === "done") return page.warning ? "완료 · 처리 상세 확인" : "완료";
  if (action?.outcome === "error" || action?.outcome === "cancelled") return "중단";
  return page.status || "";
}

/** 이미지 속 문장 수(인식이 끝났으면 숫자, 아직이면 null). */
function imageSentencesOf(inventory, nativeList) {
  if (Number.isInteger(inventory.imageSentences)) return inventory.imageSentences;
  const recognized = latestNative(nativeList, "ocr", "recognized") || latestNative(nativeList, "ocr");
  return Number.isInteger(recognized?.counts?.sentences) ? recognized.counts.sentences : null;
}

/** ② 요약 줄: 이미지 수 · 전체(일반+이미지 속) 문장 수. 이미지 속 문장을 아직 모르면 0으로 꾸미지 않고 '문장 확인 중'. */
function summaryLine(page, nativeList, action) {
  const inventory = page?.inventory || action?.inventory;
  if (!inventory) return "";
  const parts = [];
  const images = Number.isInteger(inventory.images) ? inventory.images : 0;
  if (images > 0) parts.push(`이미지 ${count(images)}개`);
  const imageSentences = imageSentencesOf(inventory, nativeList);
  const text = Number.isInteger(inventory.textSentences) ? inventory.textSentences : null;
  if (images > 0 && imageSentences === null) {
    if (page?.running === true) parts.push("문장 확인 중");
    else if (text !== null) parts.push(`총 ${count(text)}문장 이상 · 이미지 속 확인 못 함`);
  } else if (text !== null || imageSentences !== null) {
    parts.push(`총 ${count((text || 0) + (imageSentences || 0))}문장`);
  }
  return parts.join(" · ");
}

// MARK: 처리 상세(접힘): 일반/이미지 속 문장, 실제 보낸 양, 단계별 걸린 시간, Mac 측정, 보안 확인 대기, 인식 언어

/** 내용 스크립트 단계 구간(클릭부터 차례로 이어지는 벽시계 구간, 겹치지 않음). 진행 중인 단계는 지금까지. */
function contentStageParts(action) {
  const now = action.outcome === null ? Date.now() - action.startedAt : action.endedAt;
  const totals = new Map();
  for (const stage of Array.isArray(action.stages) ? action.stages : []) {
    const label = contentStageLabel(stage.s, action.engine);
    if (!label || !Number.isFinite(stage.a)) continue;
    const end = Number.isFinite(stage.b) ? stage.b : now;
    totals.set(label, (totals.get(label) || 0) + Math.max(0, end - stage.a));
  }
  return [...totals].filter(([, ms]) => ms >= 50).map(([label, ms]) => `${label} ${seconds(ms)}`);
}

/** 네이티브 요청 안 단계 구간: 배경이 잰 단계 시작 시각의 차이(대기 포함 벽시계). 요청끼리는 차례로 보내므로 더해도 겹치지 않는다.
 *  보안 확인(직접) 구간은 따로 돌려준다. */
function nativeStageParts(action, marks) {
  const byRequest = new Map();
  for (const mark of Array.isArray(marks) ? marks : []) {
    if (!byRequest.has(mark.r)) byRequest.set(mark.r, []);
    byRequest.get(mark.r).push(mark);
  }
  const stopAt = action.outcome === null ? Date.now() : action.startedAt + (Number.isFinite(action.endedAt) ? action.endedAt : 0);
  const totals = new Map();
  let security = 0;
  for (const list of byRequest.values()) {
    list.sort((a, b) => a.t - b.t);
    for (let i = 0; i < list.length; i += 1) {
      const mark = list[i];
      if (mark.p === "end" || mark.p === "fail") continue;
      const end = i + 1 < list.length ? list[i + 1].t : Math.max(mark.t, stopAt);
      const ms = Math.max(0, end - mark.t);
      if (mark.p === "external:challenge") security += ms;
      const label = nativeStageLabel(mark.k, mark.p, action.engine);
      if (label) totals.set(label, (totals.get(label) || 0) + ms);
    }
  }
  return { parts: [...totals].filter(([, ms]) => ms >= 50).map(([label, ms]) => `${label} ${seconds(ms)}`), security };
}

/** Mac이 끝난 요청에서 직접 잰 처리 시간(ms). 인식 뒤 분석과 번역은 동시에 돌 수 있어 더하지 않고 따로 보인다. */
function nativeMeasuredParts(timing) {
  const parts = [];
  const image = timing?.image?.native;
  if (image && typeof image === "object") {
    const names = { decode: "해석", calibrate: "밝기 보정", ocr: "글자 인식", analyze: "복원 분석", translate: "번역", encode: "포장" };
    for (const [key, label] of Object.entries(names)) {
      if (Number.isInteger(image[key]) && image[key] >= 50) parts.push(`${label} ${seconds(image[key])}`);
    }
  }
  const text = timing?.text;
  if (text && Number.isInteger(text.native) && text.native >= 50) parts.push(`일반 글자 번역 ${seconds(text.native)}`);
  return parts;
}

/** 외부 번역(구글·DeepL)으로 실제 보낸 양: 확장이 보낸 조각·글자(누적/전체)와 Barobogi가 지금 입력창에 넣는 묶음. */
function sendingLine(inventory, nativeList, running) {
  const parts = [];
  const send = inventory?.send;
  if (send && inventory.engine !== "apple" && send.texts > 0) {
    parts.push(`일반 요청 ${count(send.sentTexts)}/${count(send.texts)}조각 · ${count(send.sentChars)}/${count(send.chars)}자`);
    if (running && send.batch > 0 && send.sentTexts < send.texts) parts.push(`지금 ${count(send.batchTexts)}조각 ${count(send.batchChars)}자`);
  }
  const external = running ? latestNative(nativeList, null, "external") : null;
  if (external) {
    const c = external.counts || {};
    if (c.batch > 0 && c.batches > 0) parts.push(`입력 묶음 ${count(c.batch)}/${count(c.batches)}`);
    if (Number.isInteger(c.batchItems)) parts.push(`이번 ${count(c.batchItems)}문장 ${count(c.batchChars)}자`);
    if (external.kind === "ocr" && Number.isInteger(c.totalItems)) parts.push(`이미지 포함 요청 ${count(c.totalItems)}문장 ${count(c.totalChars)}자`);
  }
  return parts.join(" · ");
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

/** 원문 언어별 인식 개수(텍스트 조각·OCR 문단 기준) 한 줄. 집계가 없으면 빈 문자열. */
function langCountsLine(langCounts) {
  const entries = langCounts && typeof langCounts === "object"
    ? Object.entries(langCounts).filter(([, n]) => Number.isFinite(n) && n > 0)
    : [];
  if (!entries.length) return "";
  entries.sort((a, b) => {
    if (a[0] === "unknown") return 1;
    if (b[0] === "unknown") return -1;
    if (b[1] !== a[1]) return b[1] - a[1];
    return a[0].localeCompare(b[0]);
  });
  return `인식 언어: ${entries.map(([code, n]) => `${langLabel(code)} ${n}문장`).join(" · ")}`;
}

function renderDetails(page, nativeList, action, deadline, timeline) {
  const lines = [];
  const inventory = page?.inventory || action?.inventory || null;
  if (page?.warning) lines.push(page.warning);
  if (inventory) {
    const counts = [];
    if (Number.isInteger(inventory.textSentences)) {
      counts.push(`일반 ${count(inventory.textSentences)}문장${Number.isInteger(inventory.textMessages) ? `(${count(inventory.textMessages)}조각)` : ""}`);
    }
    const imageSentences = imageSentencesOf(inventory, nativeList);
    if (Number.isInteger(imageSentences)) counts.push(`이미지 속 ${count(imageSentences)}문장`);
    else if (inventory.images > 0) counts.push(page?.running === true ? "이미지 속 문장 확인 중" : "이미지 속 문장 확인 못 함");
    if (counts.length) lines.push(counts.join(" · "));
    const sending = sendingLine({ ...inventory, engine: inventory.engine || action?.engine }, nativeList, page?.running === true);
    if (sending) lines.push(sending);
  }
  if (action) {
    const stages = contentStageParts(action);
    if (stages.length) lines.push(`구간(클릭부터): ${stages.join(" · ")}`);
    const nativeStages = nativeStageParts(action, timeline);
    if (nativeStages.parts.length) lines.push(`요청 안 구간(대기 포함): ${nativeStages.parts.join(" · ")}`);
    const externalRequest = action.timing?.image?.externalRequest;
    if (externalRequest && Number.isInteger(externalRequest.texts) && Number.isInteger(externalRequest.chars)) {
      lines.push(`이미지 포함 요청 ${count(externalRequest.texts)}문장 · ${count(externalRequest.chars)}자`);
    }
    const measured = nativeMeasuredParts(action.timing);
    if (measured.length) lines.push(`Mac 처리 측정(동시 실행은 겹침): ${measured.join(" · ")}`);
    const security = Number.isFinite(deadline?.securityMs) ? deadline.securityMs : nativeStages.security;
    if (security >= 50) {
      lines.push(`보안 확인 대기 ${seconds(security)}${deadline ? ` · ${Math.round(deadline.limit / 1000)}초 한도에서 제외` : ""}`);
    }
  }
  const langs = langCountsLine(page?.langCounts);
  if (langs) lines.push(langs);
  const body = $("detailBody");
  body.replaceChildren(...lines.map((text) => {
    const p = document.createElement("p");
    p.textContent = text;
    return p;
  }));
  $("details").hidden = lines.length === 0;
}

// 진행 중일 때만 1초마다 이 탭의 상태와 진행을 다시 읽는다(Barobogi 연결 확인 없이). 끝나면 멈춘다.
let pollTimer = 0;
function schedulePoll(running) {
  clearTimeout(pollTimer);
  pollTimer = running ? setTimeout(pollProgress, 1000) : 0;
}

async function pollProgress() {
  pollTimer = 0;
  if (!current) return;
  try {
    const response = await call({ cmd: "pageProgress" });
    render({ ...current, page: response.page, native: response.native, timeline: response.timeline, deadline: response.deadline });
  } catch {
    // 팝업·탭 통신이 끊기면 더 묻지 않는다(다시 열면 새로 읽는다).
  }
}

// 현재 문서만 한 번 다른 서비스로 번역하는 버튼(전역 엔진 설정을 바꾸지 않음). 엔진마다 버튼이 따로 있다.
const PAGE_ENGINES = [
  { engine: "google", button: "googlePage", spinner: "googleSpinner", title: "구글" },
  { engine: "deepl", button: "deeplPage", spinner: "deeplSpinner", title: "DeepL" }
];

// Safari는 외부 엔진으로 가는 다리가 없어 막는다(지원하는 것처럼 꾸미지 않는다). 그 밖에는 동의·연결이 됐고 이 탭이
// 번역 가능한 페이지일 때만 누를 수 있다. 지금 이 문서에 걸린 엔진의 버튼만 진행 표시를 한다.
function renderExternalPage(state, engine, buttonId, spinnerId, title) {
  const active = state.page?.externalPage?.engine === engine;
  const button = $(buttonId);
  // 보기 선택(파랑 채움)은 '번역' 버튼만 갖는다. 이 서비스로 번역 중·번역 표시 중이면 얇은 테두리로만 알린다.
  button.classList.remove("active");
  button.classList.toggle("engineOn", active && state.page?.view === "translated");
  $(spinnerId).hidden = !(active && state.page?.running);
  button.disabled = IS_SAFARI || tabId === null || !origin || (active && state.page?.running) ||
    (state.engine.ok === true && state.engine.enabled !== true);
  if (IS_SAFARI) button.title = `Safari에서는 ${title} 옵션을 지원하지 않습니다.`;
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
async function runTranslate(gesture, clickedAt) {
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
    const response = await call({ cmd: "translateNow", automatic: granted, clickedAt, trigger: gesture ? "button" : "open" });
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
      $("statusText").textContent = "검색 중";
      $("spinner").hidden = false;
      $("translateSpinner").hidden = false;
    }
    setTimeout(refresh, 1200);
  } catch (error) {
    showError(error.message);
  } finally {
    $("translate").disabled = false;
  }
}

$("translate").addEventListener("click", async () => {
  // 경과·시간은 이 클릭 시각부터 잰다(권한 확인·중지·주입을 기다리는 시간 포함).
  const clickedAt = Date.now();
  if (current?.page?.externalPage) {
    try { await call({ cmd: "stopPageOnce" }); }
    catch (error) { showError(error.message); return; }
  }
  runTranslate(true, clickedAt);
});

// 누를 때마다 이 탭의 지금 문서만 그 엔진으로 한 번 번역한다(다른 엔진이 걸려 있었으면 배경이 그 허용을 새 것으로 바꾼다).
PAGE_ENGINES.forEach(({ engine, button, spinner }) => {
  $(button).addEventListener("click", async () => {
    const clickedAt = Date.now();
    $(button).disabled = true;
    $(spinner).hidden = false;
    notice = "";
    showError("");
    try {
      await call({ cmd: "translatePageOnce", engine, clickedAt });
    } catch (error) {
      showError(error.message);
    } finally {
      $(button).disabled = false;
      refresh();
    }
  });
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
  // 툴바 아이콘을 눌러 팝업이 열릴 때마다 '번역 보기'를 누른 것과 같은 동작을 한 번만 한다(원문으로
  // 되돌리지 않음 — '원문 보기'는 팝업에서 사용자가 직접 눌러야만 한다). 이 탭에 이전 상태가 없어도
  // (opened.page가 없는 첫 방문 페이지여도) translateNow가 필요하면 내용 스크립트를 넣어 처리한다.
  try {
    const opened = await call({ cmd: "popupState" });
    // 이 문서가 1회성 Google·DeepL 번역 중이면 팝업을 다시 연 것만으로 Mac 기본 번역으로 바꾸지 않는다.
    if (opened.settings.consent && !opened.page?.externalPage) await runTranslate(false, OPENED_AT);
  } catch {
    // 실패는 조용히 무시하고 아래 refresh()가 실제 상태를 그대로 보여준다.
  }
  refresh();
})();
