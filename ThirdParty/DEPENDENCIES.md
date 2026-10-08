# 외부 의존성

| 이름 | 버전 | 용도 | 출처 | SHA256 (tar.xz) | 라이선스 |
|---|---|---|---|---|---|
| Sparkle | 2.10.0 | 자동 업데이트 (SPUStandardUpdaterController) | https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz | c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c | MIT 등 (Sparkle-LICENSE) |

- `scripts/bootstrap-sparkle.sh`가 위 URL/SHA256을 검증한 뒤 `Vendor/Sparkle/`(git 무시)에 풉니다.
- 앱 번들에는 `Contents/Frameworks/Sparkle.framework`로 심볼릭 링크를 보존(ditto)해 포함되고,
  내부 XPC/Autoupdate/Updater.app → 프레임워크 → 앱 순서로 같은 Developer ID로 재서명됩니다.
