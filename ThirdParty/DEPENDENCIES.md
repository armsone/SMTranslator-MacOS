# 외부 의존성

| 이름 | 버전 | 용도 | 출처 | SHA256 (tar.xz) | 라이선스 |
|---|---|---|---|---|---|
| Sparkle | 2.10.0 | 자동 업데이트 (SPUStandardUpdaterController) | https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz | c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c | MIT 등 (Sparkle-LICENSE) |

- `scripts/bootstrap-sparkle.sh`가 위 URL/SHA256을 검증한 뒤 `Vendor/Sparkle/`(git 무시)에 풉니다.
- 앱 번들에는 `Contents/Frameworks/Sparkle.framework`로 심볼릭 링크를 보존(ditto)해 포함되고,
  내부 XPC/Autoupdate/Updater.app → 프레임워크 → 앱 순서로 같은 Developer ID로 재서명됩니다.

## 내부 구성 요소(외부 의존성 아님)

| 이름 | 버전 | 용도 | 출처 |
|---|---|---|---|
| AIBI 공통 런타임·제공사 레지스트리 | 0.5.3 | 외부 AI(ChatGPT·Claude·Gemini) 웹 로그인 번역 | 같은 소유자의 AIBI 프로젝트. `MailTranslator-MacOS/Resources`의 파일과 바이트 단위로 동일한 복사본(`Resources/aibi-browser-runtime.js`, `Resources/aibi-providers.json`) |

- 호스트 한정 수정(Barobogi `Sources/AIBIMacEngine.swift`만, 런타임·레지스트리 파일은 그대로): 실행 웹 보기의 모든 페이지 스크립트(초안 확인·런타임 주입·프롬프트 입력·전송·관찰)를
  실행 세대·작업 취소·현재 웹 보기·로드 완료·공식 실행 origin(인증 경로 제외) 확인 뒤에만 실행하고, 스크립트 첫 줄에서 실제 location을 같은 허용 목록으로 다시 확인한다.
  이 수정은 정본 AIBI나 MailTranslator-MacOS에 반영된 것이 아니며, 두 저장소와 동작이 같다는 뜻이 아니다.
