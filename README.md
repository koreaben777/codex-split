# CodexSplit

**CodexSplit** runs the official ChatGPT (Codex) desktop app for macOS with a separate *work* profile, next to your everyday personal profile. It does not modify, re-sign or bundle the official app. It launches the installed `/Applications/ChatGPT.app` with its own `CODEX_HOME` and Electron user-data directory, and only when the app's exact version, hashes and OpenAI code signature match what you approved. It follows that exact process until it exits. When the official app updates, CodexSplit builds and tests a new launcher for the new version and asks you to accept it again before daily use.

> Not affiliated with or endorsed by OpenAI. Experimental: profile separation relies in part on app behavior that is not a public contract (see *Limits*).

---

macOS에서 공식 ChatGPT(Codex) 데스크톱 앱을 기존 개인 프로필과 분리된 **업무 프로필**로 실행하는 도구입니다. 공식 앱을 수정·재서명·복제하지 않고, 설치된 원본을 별도 저장소 경로로 실행합니다.

## 동작 원리

- **분리 실행**: `~/Library/Application Support/CodexSplit/profiles/work` 아래의 `codex`, `desktop` 디렉터리를 `CODEX_HOME`, `CODEX_SQLITE_HOME`, `CODEX_ELECTRON_USER_DATA_PATH`, `--user-data-dir`로 전달해 새 인스턴스를 엽니다.
- **정확한 대상만 실행**: 앱·번들 CLI의 버전·build·SHA-256, `app.asar` SHA-256이 고정값(`WorkAppPins.current`)과 같고, OpenAI 서명(Team `2DC432GLL2`, identifier별 strict 검증)을 통과해야 실행합니다. 검사 생략·강제 옵션은 없습니다.
- **귀속과 종료 관측**: 실행 완료 객체와 커널 프로세스 세대(pid + 시작 시각)를 기록하고, 사용자가 그 창에서 직접 종료(Cmd-Q)할 때까지 관측합니다. 같은 런처를 다시 누르면 새 창을 열지 않고 기존 업무 창만 앞으로 가져옵니다. 결과가 불분명하면 예약을 보존하고 자동 재실행하지 않습니다.
- **수용 후 일상 사용**: 새 런처·버전마다 수용 시험 두 번(업무 계정 확인, 개인 앱 무변화, 프로젝트 목록 유지 또는 해당 없음, 정상 종료)을 거친 뒤에야 별도 동의로 일상 사용을 허용합니다.
- **업데이트 대응**: 공식 앱이 업데이트되면 실행을 막고, 동의 한 번으로 새 버전용 런처 후보를 격리 빌드·전체 검사·백업 교체합니다. 이전 기록은 바이트 그대로 보존하고, 새 버전은 성공 0회부터 다시 수용합니다. 자세한 내용은 [docs/UPDATES.md](docs/UPDATES.md)를 보세요.

## 요구 사항

- macOS, `/Applications/ChatGPT.app` (공식 배포본)
- Xcode Command Line Tools (`swiftc`, `clang`, `codesign`), `python3`
- 외부 패키지는 사용하지 않습니다.

## 시작하기

이 저장소를 clone한 디렉터리에서:

```sh
sh scripts/check.sh
```

1. **설치된 공식 앱 버전 고정** — 저장소의 고정값과 설치된 버전이 다르면, 처음 설정 전에만 다음을 실행한 뒤 검사를 다시 돌립니다. 서명과 업무 저장소 분리 표식이 확인된 경우에만 고정합니다.
   ```sh
   python3 scripts/update-work.py --pin-installed
   sh scripts/check.sh
   ```
   이 명령은 추적 파일 `Sources/AppTrial.swift`의 고정값 블록을 고칩니다. 이후 `git pull` 전에 로컬 커밋하거나 충돌을 직접 정리하세요.
2. **업무 프로필 설정** — Terminal에서 실행합니다. 새 업무 창에서 직접 로그인하고, 업무 계정·개인 앱 상태를 확인한 뒤 종료, 그리고 재실행 한 번으로 로그인 유지를 확인합니다. 단계마다 정확한 입력(`LOGIN work`, `REOPEN work`, `QUIT`)을 요구합니다.
   ```sh
   .build/codex-split-work-setup --setup work
   ```
3. **런처 설치** — 이 checkout에서 빌드한 런처를 `~/Applications/CodexSplit-work.app`에 처음 설치합니다(이미 있으면 거부).
   ```sh
   python3 scripts/install-work-update-approved.py --install-new
   ```
4. **수용과 일상 사용** — `CodexSplit-work.app`을 열어 수용 시험을 두 번 진행합니다. 메뉴 막대의 `업무` 메뉴에서 계정·개인 앱·프로젝트 확인과 정상 종료 준비를 선택하고, 해당 업무 창에서 Cmd-Q 합니다. 두 번 성공하면 런처가 일상 사용 허용을 묻습니다.

런처 아이콘은 선택 사항입니다. `Assets/WorkIcon/CodexSplit-work.icns`를 두면 빌드에 포함되고, 업데이트 교체 시에도 같은 아이콘을 유지해야 합니다(저장소에는 포함하지 않습니다).

## 업데이트

공식 앱을 업데이트한 뒤 런처를 열면 실행 대신 **자동 대응 시작**을 제안합니다. 동의하면 `scripts/update-work.py --auto`가 백그라운드에서 서명·고정값 재확인, 저장소 분리 표식 점검, 격리 후보 빌드와 전체 검사, 런처가 닫힌 뒤의 백업 교체를 처리하고 알림을 보냅니다. 교체 뒤 런처를 다시 열어 새 수용 구간을 시작합니다. 사람의 변경 내역 검토를 거치는 수동 경로와 실패 시 복원 방법은 [docs/UPDATES.md](docs/UPDATES.md)에 있습니다.

## 기록 위치

| 경로 | 내용 |
|---|---|
| `~/Library/Application Support/CodexSplit/profiles/work/{codex,desktop,cwd}` | 업무 프로필 저장소(공식 앱이 사용) |
| `…/profiles/work/control/state.json` | 설정·방문 기록(계정 식별자·토큰·대화 내용 없음) |
| `…/profiles/work/control/work-daily.json`, `work-daily-history-*.json` | 런처 실행 기록과 이전 구간의 불변 보존본 |
| `~/Applications/.CodexSplit-work-replacement-*` | 교체 영수증과 이전 런처 백업 |
| `<checkout>/.build/work-updates/<id>` | 업데이트 후보와 검사 기록 |

실행 중 경로는 `$HOME`이 아니라 계정 정보(`getpwuid`)에서 계산하므로 환경 변수로 다른 위치를 가리킬 수 없습니다. 업데이트 후보를 만들 소스 위치는 빌드할 때 런처 번들의 `Contents/Resources/source-root`에 기록됩니다(`CODEXSPLIT_SOURCE_ROOT`로 지정 가능, 기본은 checkout). 런처는 실행 시 자기 번들 서명을 검증하므로 설치 뒤 이 값을 바꾸면 실행하지 않습니다.

수용 시험에서 다른 계정·개인 앱 변화·확인 불가를 보고하면 그 기록은 보존되고 이후 실행과 업데이트가 멈춥니다. 원인을 확인한 뒤 다시 시작하려면 업무 프로필 폴더 전체를 다른 위치로 옮겨 보존하고 2단계(업무 프로필 설정)부터 진행하세요. CodexSplit은 기록이나 로그인 데이터를 자동으로 지우지 않습니다.

## 제한

- 공식 문서에 공개된 것은 CLI의 `CODEX_HOME`입니다. 데스크톱 앱의 사용자 데이터 경로 분리는 공개 계약이 아니므로 버전마다 검사·수용 시험으로 확인합니다.
- OS 공유 인증 저장소나 브라우저 로그인을 쓸 수 있으므로 폴더 분리만으로 계정 격리를 보장하지 않습니다. 수용 시험은 사용자가 관찰한 결과이며 완전한 분리의 증명이 아닙니다.
- 공식 앱을 업데이트하면 새 버전 수용 전까지 업무 앱을 열지 않습니다. 공식 앱 버전을 되돌리거나 업데이트를 막지는 않습니다.
- 개발 단계의 CLI(`codex-split`)는 상태 조회·진단·업데이트 검사만 제공합니다. `cli`, `app`, `login` 등 실행 계열 명령은 차단돼 있습니다.

## 검사

`sh scripts/check.sh`는 합성 데이터와 fixture만 사용하며 공식 앱·프로필을 열지 않습니다.

## 구성

- `Sources/` — CLI·정책(`Model`, `Policy`, `Runtime`, `App*`), 공식 앱 실행·관측(`AppTrial*`, `WorkProcess`, `Native.c`), 업무 설정(`WorkSetup`), 런처 기록·업데이트 전환(`WorkDaily`, `WorkUpdate*`), GUI 런처(`WorkDailyUI`)
- `scripts/` — 빌드·검사, `update-work.py`(감지·후보·자동 대응), `install-work-update-approved.py`·`launcher_replacement.py`(설치·교체·복원)
- `Tests/` — 합성 시험

## 라이선스

Copyright 2026 koreaben777. [Apache License 2.0](LICENSE)으로 배포합니다.

ChatGPT, Codex, OpenAI는 OpenAI의 상표입니다. 이 프로젝트는 OpenAI와 관련이 없으며, 공식 앱을 포함하거나 수정하지 않고 사용자가 설치한 앱을 실행만 합니다.
