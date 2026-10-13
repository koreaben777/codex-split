# CodexSplit

**개인용 Codex 앱을 그대로 두고, 별도 업무 프로필로 Codex 창을 여는 macOS 런처입니다.**

CodexSplit is an experimental macOS launcher for a separate work profile alongside your personal Codex app. It uses your installed official app without modifying or redistributing it. The current implementation requires the exact bundle layout described below; it is not a general-purpose account switcher or a security sandbox. Documentation and the launcher UI are primarily in Korean. Not affiliated with or endorsed by OpenAI.

[설치 안내](docs/INSTALL.md) · [업데이트·복구](docs/UPDATES.md) · [기여 안내](CONTRIBUTING.md) · [보안 및 문제 보고](SECURITY.md)

## 어떤 도구인가요?

개인 계정과 업무 계정을 각각 사용하고 싶을 때, 업무용 저장 폴더를 지정하여 공식 앱의 새 인스턴스를 엽니다. 최초 설정과 확인을 마치면 `~/Applications/CodexSplit-work.app`을 클릭해 업무 창을 열 수 있습니다.

- **업무 프로필 하나**를 관리합니다. 기존 개인 자료를 새 프로필에 복사하지 않습니다.
- 공식 앱의 **서명·버전·파일 해시**가 고정한 대상과 일치해야 실행합니다.
- 사용자가 업무 계정, 개인 앱의 상태, 업무 프로젝트 목록을 확인한 뒤 일상 사용을 허용합니다.
- 런처가 관측 중인 업무 창이 있으면 다시 클릭해도 새 창을 만들지 않고 그 창을 활성화합니다.
- 공식 앱이 바뀌면 실행을 보류하고, 동의를 받아 새 런처를 빌드·검사·백업 교체하는 절차를 제공합니다.

**현재는 소스에서 직접 빌드하는 실험적 도구입니다.** 여러 계정의 자유로운 추가·전환, Windows/Linux, 일반 Codex CLI 실행은 제공하지 않습니다. 아래 조건을 만족하는 앱에서도 실제 로그인·저장소 분리는 사용자 환경에서 확인해야 합니다.

## 설치 전에 확인하세요

### 지원 대상 앱

현재 코드는 다음 경로와 서명 식별자를 고정해서 검사합니다. **앱 이름만 `ChatGPT`라고 해서 지원되는 것은 아닙니다.**

| 검사 대상 | 요구 조건 |
|---|---|
| 앱 번들 | `/Applications/ChatGPT.app` |
| 앱 실행 파일 | `Contents/MacOS/ChatGPT` |
| 앱 서명 identifier | `com.openai.codex` |
| 번들 CLI | `Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex` |
| 번들 CLI 서명 identifier | `codex` |
| 서명 Team ID | `2DC432GLL2` |
| 앱 리소스 | `Contents/Resources/app.asar` |

앱·CLI의 버전과 SHA-256, 리소스 SHA-256도 검사합니다. 처음 설치할 때 설치된 앱을 검사해 로컬 고정값을 맞출 수 있지만, 다른 경로나 번들 구조를 자동으로 지원하지는 않습니다. `/Applications/Codex.app` 등 다른 위치에 있는 앱은 현재 실행 대상이 아닙니다. 검사를 통과시키려고 앱 파일을 수정하거나 재서명하지 마세요.

### 실행 환경

- macOS와 위 조건에 맞는 공식 앱이 필요합니다. 최소 macOS·Xcode 버전 및 Intel/Apple Silicon별 호환성 표는 아직 확립하지 않았습니다.
- Xcode Command Line Tools의 `swiftc`, `clang`, `codesign`, Git, Python 3가 필요합니다. GUI 업데이트는 **`/usr/bin/python3`**를 사용합니다.
- 본인의 macOS 계정과 대화형 Terminal에서 설치합니다. `sudo`는 사용하지 않습니다.
- Swift/AppKit과 Python 표준 라이브러리로 빌드하며 별도 패키지 설치는 없습니다.
- 한국어 안내에 따라 공식 앱에서 직접 로그인하고 확인할 수 있어야 합니다.
- 소스 폴더는 공유·동기화되지 않는 영구 위치에 보관하세요. 설치 뒤에도 업데이트에 필요합니다.

### 분리의 한계

**프로필 폴더 분리는 보안 격리나 완전한 인증 분리를 보장하지 않습니다.** 공식 앱은 OS 공유 인증 저장소, 브라우저 로그인, 네트워크를 사용할 수 있습니다. 이 도구는 별도 macOS 사용자 계정이나 샌드박스를 만들지 않으며 조직의 로그인 정책을 우회하지 않습니다.

데스크톱 저장소 경로를 지정하는 앱 동작에 의존하므로, 새 앱 버전에서 동작이 달라질 수 있습니다. 서명 검사와 자동 시험은 실제 계정·저장소·IPC 분리의 증명이 아닙니다. 의도하지 않은 계정이나 개인 앱 변화가 보이면 성공으로 확인하지 말고 사용을 중단하세요.

## 시작하기

요구 사항을 준비한 뒤 소스를 계속 보관할 상위 폴더에서 실행합니다.

```sh
git clone https://github.com/koreaben777/codex-split.git
cd codex-split
sh scripts/install.sh
```

설치는 **개발 도구 확인 → 공식 앱 검사·고정 → 전체 자동 검사·빌드 → 업무 로그인 확인 → 런처 설치** 순서로 진행됩니다. 기존 업무 프로필이나 설치된 런처가 있으면 덮어쓰지 않고 멈춥니다.

1. Terminal의 안내에 따라 업무 창에서 직접 로그인합니다. 암호·인증번호는 공식 로그인 화면에서만 입력합니다.
2. 업무 계정과 개인 앱 상태를 확인하고, 안내에 따라 업무 창을 종료·재실행합니다. 설치 중 로그인 확인 방문은 두 번입니다.
3. 설치 후 `~/Applications/CodexSplit-work.app`을 열고 **별도의 수용 시험 두 번**을 진행합니다. 메뉴 막대의 **업무 확인**에서 계정·개인 앱·프로젝트를 확인하고 정상 종료 준비 후 업무 창에서 Cmd-Q 합니다.
4. 일상 사용 허용에 동의하면 이후에는 런처를 클릭해 사용합니다. 일상 사용 중에는 업무 확인 메뉴가 없으며 업무 창을 Cmd-Q로 종료하면 런처도 종료됩니다.

설치 중 `Sources/AppTrial.swift`의 버전·해시 고정값이 바뀔 수 있습니다. **소스 폴더를 이동·삭제하지 마세요.** 중단 후 재개와 수동 설치는 [설치 안내](docs/INSTALL.md)를 따르세요.

## 업데이트

공식 앱 업데이트와 CodexSplit 소스 업데이트는 별개입니다. `git pull`만으로 설치된 런처가 바뀌지는 않습니다.

공식 앱 변경이 감지되면 런처가 자동 대응을 제안합니다. 동의하면 보관한 소스에서 후보를 빌드하고 전체 검사를 수행한 뒤, 기존 런처를 백업하고 교체합니다. 완료 후 런처를 다시 열어 새 구간의 확인을 진행합니다. 이전 구간에서 일상 사용을 허용받았거나, 이전 허용을 이어받는 구간의 확인 방문을 마친 경우 확인 방문 한 번, 그 외에는 두 번의 수용 시험과 별도 허용이 필요합니다.

**자동 대응은 원본 소스의 고정값을 동기화하고 해당 파일의 로컬 Git 커밋을 만들 수 있습니다.** 현재 HEAD의 작성자 정보를 사용하며 push는 하지 않습니다. 다음 후보에 로컬 소스 변경도 포함될 수 있으므로, 운영에 쓰는 checkout에 신뢰할 수 없는 변경을 두지 마세요. 자동 대응은 공식 변경 내역에 대한 사람의 검토를 대신하지 않습니다.

수동 검토·교체, 소스 코드만 갱신하는 경우, 실패 시 복원은 [업데이트 안내](docs/UPDATES.md)를 참고하세요. 자동 롤백이나 공식 앱 버전 복원은 제공하지 않습니다.

## 저장되는 데이터

업무 프로필의 기준 경로는 `~/Library/Application Support/CodexSplit/profiles/work`입니다. 실제 홈 경로는 환경 변수 `$HOME`이 아니라 macOS 계정 정보에서 계산합니다.

| 위치 | 용도 |
|---|---|
| `profiles/work/codex` | 공식 앱에 `CODEX_HOME`, `CODEX_SQLITE_HOME`으로 전달하는 경로 |
| `profiles/work/desktop` | `CODEX_ELECTRON_USER_DATA_PATH`, `--user-data-dir`로 전달하는 경로 |
| `profiles/work/cwd` | 업무 프로필에 함께 생성되는 작업 폴더 |
| `profiles/work/control` | 설정·사용자 확인·실행·종료 기록 및 이전 구간 보존본 |
| `~/Applications/CodexSplit-work.app` | 로컬에서 빌드한 업무 런처 |
| `~/Applications/.CodexSplit-work-replacement-*` | 교체 영수증과 이전 런처 백업 |
| `<소스 폴더>/.build/work-updates` | 업데이트 후보 소스·빌드·검사 기록 |

프로필에는 공식 앱이 저장하는 **인증 정보와 대화 데이터가 포함될 수 있습니다.** `control`의 사용자 보고는 계정 식별자 대신 확인 결과를 기록하지만, 경로·프로세스 ID·시각 등의 메타데이터는 포함됩니다. 프로필, 로그, 빌드 폴더를 그대로 공개하거나 다른 사람에게 복사해서 배포하지 마세요.

실행이나 종료를 확인하지 못하면 기록을 보존하고 다음 실행을 차단합니다. 이전 프로세스가 끝났음을 확인할 수 있을 때만 사용자 동의를 받아 '종료 미관측'으로 기록하며, 수용 시험 성공으로 세지 않습니다. 오류를 없애려고 `state.json`이나 승인 기록을 직접 수정하지 마세요.

## 기존 프로필 이동과 사용 중지

기존 CodexSplit 형식의 업무 프로필을 옮기는 기능은 [기존 프로필 옮기기](docs/INSTALL.md#기존-프로필-옮기기)를 참고하세요. 임의의 개인 앱 데이터 가져오기 기능은 아닙니다.

사용을 중지하려면 업무 창에서 Cmd-Q하고 런처가 종료된 것을 확인한 뒤 Dock에서 런처를 제거하면 됩니다. 앱을 제거해도 업무 프로필은 남습니다. 데이터 삭제·재설치를 자동으로 처리하는 제거 도구는 없으며, 프로필과 교체 기록은 복구 필요성을 확인한 뒤 별도로 관리해야 합니다.

## 개발 및 기여

```sh
sh scripts/build.sh   # 진단 CLI, 업무 설정 도구, 업데이트 진행 창 빌드
sh scripts/check.sh   # 합성 시험 및 업무 런처 빌드
```

전체 검사는 실제 공식 앱에 로그인하거나 업무 프로필을 열지 않습니다. 합성 프로세스·파일 fixture를 사용하고 `.build`, `.test-data`에 산출물을 만듭니다. 통과 결과는 실제 앱의 로그인·업데이트·재부팅 검증과 구분해야 합니다.

| 코드 | 역할 |
|---|---|
| `Sources/WorkSetup.swift`, `WorkAdoption.swift` | 최초 로그인 확인, 기존 업무 프로필 이동 |
| `Sources/AppTrial.swift`, `AppTrialStore.swift` | 실행 대상 고정값, 서명·경로 검사, 공식 앱 실행 |
| `Sources/WorkDaily.swift`, `WorkDailyUI.swift` | 수용 시험·일상 사용·종료 관측·GUI |
| `Sources/WorkProcess.swift`, `Native.c` | 프로세스 세대와 폴더 동일성 검사 |
| `Sources/WorkUpdate*.swift` | 앱 변경 감지, 교체 증거와 새 구간 연결 |
| `Sources/Model.swift`, `Policy.swift`, `AppOpening.swift` 등 | 개발용 일반 프로필 정책·관측 인터페이스 |
| `scripts/` | 설치·빌드·검사·업데이트 후보 생성·교체·복원 |
| `Tests/` | Swift·C·Python·Shell 합성 시험 |

`codex-split` 일반 CLI의 `app`, `cli`, `login` 등 실행 명령은 차단되어 있습니다. 운영 경로는 업무 설정 도구와 업무 GUI 런처입니다. `.build/CodexSplit-work.app`은 개발용 shortcut이고, 설치 대상은 `.build/CodexSplit-work-standalone.app`입니다.

일반 버그·개선 제안은 [GitHub Issues](https://github.com/koreaben777/codex-split/issues)에 남겨 주세요. 재현 환경과 변경 검증 방법은 [기여 안내](CONTRIBUTING.md), 민감한 문제의 보고 방법은 [보안 안내](SECURITY.md)에 있습니다.

## 라이선스

Copyright 2026 koreaben777. [Apache License 2.0](LICENSE).

공식 앱과 그 자산은 이 저장소에 포함하지 않습니다. ChatGPT, Codex, OpenAI는 OpenAI의 상표이며, 이 프로젝트는 OpenAI와 제휴하거나 승인을 받은 제품이 아닙니다.
