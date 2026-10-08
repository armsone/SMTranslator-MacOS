# 화면 번역기 (ScreenTranslator) v0.1.0

- **소스**: [github.com/armsone/ScreenTranslator-MacOS](https://github.com/armsone/ScreenTranslator-MacOS) (공개)
- **다운로드(DMG)**: [최신 릴리스](https://github.com/armsone/ScreenTranslator-MacOS-Updates/releases/latest)
  — Developer ID 서명 및 Apple 공증(notarization)을 거친 Apple Silicon(arm64) 전용 빌드입니다.
- **요구 사항**: macOS 15 이상, Apple Silicon(arm64) Mac. Intel(x86_64)은 지원하지 않습니다.

macOS 15 이상용 네이티브 앱입니다. 화면 위에 투명한 사각형 창 하나를 띄워 두고, 주 버튼을
누를 때마다 **한 번** 그 안을 캡처해 텍스트를 인식(Vision OCR)하고 Apple Translation으로
온디바이스 번역한 뒤, **번역문을 원문 줄이 있던 바로 그 위치에** 겹쳐 보여줍니다.
캡처 이미지·인식 텍스트·번역 결과는 메모리에서만 다루며 디스크 저장이나 외부 전송을 하지 않습니다.

## 사용법

- **하나의 통합 창**: 흰색 둥근 테두리(약 12pt, 은은한 파란 글로우)와 중립 회색 헤더(제목 스트립 + 툴바),
  그리고 투명한 캡처 영역으로 이루어집니다. 항상 위 고정은 기본으로 켜져 있습니다.
- **이동**: 헤더 맨 위 제목 스트립(전체 너비)이나 툴바의 빈 곳을 끌면 네이티브 창 이동으로 움직입니다.
  버튼·언어 선택은 그대로 동작합니다.
- **크기 조절**: 좌/우 가장자리 전체(가로), 아래 가장자리(세로), 헤더 위쪽 얇은 띠(세로), 네 모서리(대각선).
  가장자리 안쪽 약 8pt까지가 조절 영역이며 알맞은 커서가 표시됩니다. 최소 크기는 툴바가 잘리지 않도록 제한됩니다.
- **이동·크기 잠금**: 툴바의 `이동·크기 잠금` 토글을 켜면 이동과 크기 조절만 막히고 나머지 기능은 계속 동작합니다.
- **주 버튼(가장 오른쪽)**: `캡처·번역` → 모든 줄의 번역이 성공하면 `원문보기`로 바뀝니다.
  `원문보기`를 누르면 방금 캡처해 메모리에 보관한 **원본 화면 이미지**를 같은 자리에 보여주고(새로 찍지 않음)
  버튼은 다시 `캡처·번역`이 됩니다. 창에 포커스가 있을 때 Space/Return/키패드 Enter도 같은 동작입니다.
  처리 중에는 비활성화됩니다.
- **상태 표시**: `화면 캡처 중` → `텍스트 인식 중` → `번역 중 (완료줄/전체줄)` → `완료`.
  번역은 줄이 끝나는 순서대로 바로바로 원래 위치에 나타납니다(인위적 지연 없음).
- **번역 패치**: 창 뒤 화면을 흐리게 비추는 네이티브 머티리얼 + 약 70% 중립 틴트(라이트/다크 자동) 위에
  불투명 고대비 번역문을 그립니다. 패치가 없는 캡처 영역은 투명하며 클릭이 아래 앱으로 통과합니다.
- **Esc / 제목 스트립의 ⓧ**: 창을 숨기고 진행 중 작업을 취소합니다. 앱은 계속 실행됩니다.
- **전역 단축키 ⌃⌥⇧⌘T**: 창을 보여주고 앱을 활성화합니다(Carbon `RegisterEventHotKey`, 추가 권한 불필요).
  다른 앱이 이미 사용 중이면 상태 줄과 메뉴에 안내가 표시됩니다.
- **메뉴 막대 아이콘**: 창 보이기/숨기기, 캡처·번역/원문보기, 로그인 시 자동 시작, 업데이트 확인,
  자동 업데이트, 단축키 상태, 정보, 종료. Dock 아이콘 클릭으로도 창을 다시 열 수 있습니다.

### 결과가 지워지거나 유지되는 경우

- 자동/주기 캡처는 없습니다. 실행·언어 변경·영역 변경 시에도 자동으로 다시 캡처하지 않습니다.
- 창을 이동하거나 크기를 바꾸면 기존 결과는 아래 화면과 맞지 않으므로 지워지고, 진행 중 작업은 취소됩니다.
- 언어를 바꾸거나 창을 숨기면 진행 중 작업만 취소됩니다(이미 받은 줄은 남지만 `완료`로 표시하지 않음).
- 인식된 글자가 없거나 캡처/번역이 실패하면 `원문보기`로 바뀌지 않습니다. 스트리밍 중 오류가 나면
  받은 줄은 남기고 `번역 오류 (k/N줄 완료): …`를 표시하며 버튼은 `캡처·번역`(재시도)입니다.

## 권한

- **화면 기록**: 실행 시 요청하지 않습니다. `캡처·번역`을 눌렀을 때 `CGPreflightScreenCaptureAccess`로 먼저 확인하고,
  미승인이면 실행당 최대 1회만 `CGRequestScreenCaptureAccess`를 호출합니다. 거부 상태면 설정 위치를 안내합니다.
- **번역 모델**: 처음 쓰는 언어 조합이면 첫 캡처 때 시스템이 다운로드를 안내할 수 있습니다.
  같은 언어 조합에서는 세션 구성이 유지되어 캡처마다 다시 만들지 않습니다.
- 번들 ID `com.local.screentranslator`와 Developer ID(팀 T7B4EPLHPK) 서명을 유지해 권한 기록이 이어지도록 했습니다.

## 로그인 시 자동 시작

`SMAppService.mainApp`을 사용합니다(LaunchAgent 파일 없음). `/Applications`에 설치된 앱에서만 동작하며,
최초 실행 시 1회 기본 등록합니다. 이후에는 메뉴에서 사용자가 바꿀 때만 등록/해제하고, 꺼 둔 선택은
재실행해도 존중합니다. 상태가 `승인 필요`이면 시스템 설정 > 일반 > 로그인 항목에서 직접 허용해야 하며,
메뉴에 실제 상태(켜짐/승인 필요/꺼짐)가 표시됩니다.

## 자동 업데이트 (Sparkle 2.10.0)

- 표준 `SPUStandardUpdaterController` 사용. 기본값: `SUEnableAutomaticChecks=YES`, `SUAutomaticallyUpdate=YES`,
  `SUVerifyUpdateBeforeExtraction=YES`, 시스템 프로파일링 끔. 메뉴에서 자동 업데이트를 끌 수 있습니다.
- 피드: `update-config.env`의 `SPARKLE_FEED_URL`
  (`https://github.com/armsone/ScreenTranslator-MacOS-Updates/releases/latest/download/appcast.xml`).
- 빌드 시 `Resources/UpdatePublicKey.txt`(EdDSA **공개키**)를 `SUPublicEDKey`로 넣습니다. 공개키나 HTTPS 피드가 없으면
  업데이터를 시작하지 않고 메뉴에 이유를 표시합니다. 개인키는 저장소에 없으며 로그인 키체인에만 있습니다.
- 피드가 아직 게시되지 않았거나(404 등) 받을 수 없으면 `업데이트 없음`이 아니라 Sparkle 오류로 표시됩니다.
- v0.1.0 릴리스가 업데이트 저장소([ScreenTranslator-MacOS-Updates](https://github.com/armsone/ScreenTranslator-MacOS-Updates/releases/latest))에
  게시되었습니다. 다만 자동 업데이트의 실제 버전 교체 동작은 아직 사용자 확인 전이며, 검증되었다고 단정하지 않습니다.

### 업데이트 배포 절차 (TM)

1. `Info.plist`의 `CFBundleVersion`/`CFBundleShortVersionString`을 올립니다.
2. `scripts/package-update.sh` 실행 (선택: `NOTARY_PROFILE=<notarytool 프로필>`로 공증·staple).
   - 서명 키 계정은 `Resources/UpdateSigningAccount.txt`(또는 `SPARKLE_KEYCHAIN_ACCOUNT`)에서 읽으며,
     `generate_appcast --account`가 키체인에서 직접 서명합니다. 키를 내보내거나 출력하지 않습니다.
   - 기존에 등록해 둔 notarytool 프로필이 있으면 `NOTARY_PROFILE=ccmb-notary scripts/package-update.sh`로
     그대로 재사용할 수 있습니다(프로필 이름만 지정하는 것이며 별도의 비밀 값을 노출하지 않습니다).
3. `build/release/v<버전>/`의 DMG와 `appcast.xml`을 업데이트 저장소 릴리스 `v<버전>` 자산으로 올리고
   그 릴리스를 latest로 지정합니다.

## 빌드

요구 사항: Xcode 커맨드라인 도구, macOS 15 이상 SDK, 키체인의 Developer ID Application 인증서.

```bash
./build.sh            # → build/ScreenTranslator.app
```

`build.sh`가 하는 일:
1. `Vendor/Sparkle`이 없으면 `scripts/bootstrap-sparkle.sh`로 고정 URL의 Sparkle 2.10.0을 받아 SHA256 검증 후 풉니다
   (`SPARKLE_TARBALL=<로컬 tar.xz>`로 오프라인 사용 가능).
2. `Resources/AppIcon-source.png`가 바뀌었으면 `scripts/make-icon.sh`(sips + iconutil)로 `Resources/AppIcon.icns` 생성.
3. `swiftc`로 컴파일(`-F Vendor/Sparkle -framework Sparkle`, rpath `@executable_path/../Frameworks`).
4. Info.plist·아이콘 복사, Sparkle.framework를 `ditto`로 심볼릭 링크 보존 복사, 피드 URL·공개키 주입.
5. Sparkle 내부(XPC → Autoupdate → Updater.app → 프레임워크) 후 앱 순으로 Developer ID + Hardened Runtime 서명,
   `codesign --verify --deep --strict` 확인.

의존성 정보와 라이선스: `ThirdParty/DEPENDENCIES.md`, `ThirdParty/Sparkle-LICENSE`.

## 제한 사항

- 캡처 영역은 하나의 디스플레이 안에 있어야 합니다.
- 세로쓰기 텍스트는 특별히 처리하지 않습니다(위→아래 줄 순서).
- 번역문이 원문보다 훨씬 길면 최소 글꼴 크기에서 잘릴 수 있습니다.
- 진단 로그(비밀 정보 없음: 버전, 경로, 로그인 항목/단축키/업데이터 상태): `~/Library/Logs/ScreenTranslator/diagnostics.log`.

## 프로젝트 구조

```
Info.plist, build.sh, update-config.env, .gitignore
Resources/  AppIcon-source.png, AppIcon.icns, UpdatePublicKey.txt(공개키), UpdateSigningAccount.txt(계정명)
scripts/    bootstrap-sparkle.sh, make-icon.sh, package-update.sh
ThirdParty/ DEPENDENCIES.md, Sparkle-LICENSE
Sources/
  main.swift                   앱 진입점
  AppDelegate.swift            메뉴 막대 항목, 앱 메뉴, 단축키/로그인 항목/업데이터 연결, 진단 로그
  AppViewModel.swift           캡처→OCR→스트리밍 번역 상태 기계, 세대 가드, 원문보기 전환
  CaptureService.swift         ScreenCaptureKit 영역 캡처 + Vision OCR(.accurate)
  Models.swift                 언어/상태/주 버튼/OCR 줄/패치/번역 작업 모델
  OverlayView.swift            배치·히트 영역 계산, 테두리·글로우, 크기 조절 핸들, 헤더/제목 스트립
  OverlayPanelController.swift 통합 투명 패널, 클릭 통과, 이동/크기 조절, 키 입력(Space/Enter/Esc)
  TranslationPatchesView.swift 번역 패치(behindWindow 블러 + 틴트), 원본 이미지 뷰
  ToolbarView.swift            SwiftUI 툴바, .translationTask + translate(batch:) 스트리밍
  GlobalHotKey.swift           Carbon 전역 단축키 ⌃⌥⇧⌘T
  LoginItemManager.swift       SMAppService.mainApp 로그인 항목
  UpdaterManager.swift         Sparkle 업데이터
```
