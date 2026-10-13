# 공개 저장소 검토 — 2026-10-13

이 문서는 코드·문서의 공개 적합성을 검토한 시점 기록입니다. 실행 검증이나 보안 인증을 대신하지 않습니다.

## 범위와 기준

- GitHub 공개 저장소: `koreaben777/codex-split`, 기본 브랜치 `main`.
- 확인 당시 원격 HEAD: `a71c0e840ce1046d3c9bf4a5116200d91a2f5176`.
- 작업 시작 시 로컬 HEAD: `9cddd97`. 원격보다 공식 앱 고정값 갱신 커밋 하나가 앞서 있었고, 작업 트리 변경은 없었습니다. 두 커밋의 파일 차이는 `Sources/AppTrial.swift`뿐입니다.
- 원격 현재 파일 74개: 루트 3, `Sources` 27, `Tests` 32, `docs` 2, `scripts` 10.
- 공개 `main`에서 도달 가능한 13개 커밋, 중복을 제거한 133개 blob에 대해 민감 패턴을 검사했습니다. 원격 브랜치는 `main` 하나였고 태그·GitHub Release는 없었습니다.
- 주요 실행 경로와 설치·업데이트 구현을 읽고 README 및 기존 문서의 설명을 대조했습니다. 모든 함수의 정합성을 증명하는 코드 감사는 아닙니다.

## 코드에서 확인한 구조

1. [install-work.py](../scripts/install-work.py)는 최초 설치를 여섯 단계로 연결합니다. 기존 프로필·런처가 있으면 중단하며, 실제 로그인은 [WorkSetup.swift](../Sources/WorkSetup.swift)의 대화형 경로로 수행합니다.
2. [Paths.swift](../Sources/Paths.swift)와 [AppTrialStore.swift](../Sources/AppTrialStore.swift)는 앱 경로와 서명 identifier를 고정하고, `NSWorkspace`로 새 인스턴스를 요청합니다. `ChatGPT.app`이라는 이름과 `com.openai.codex` identity가 함께 요구됩니다.
3. [WorkDaily.swift](../Sources/WorkDaily.swift)·[WorkDailyUI.swift](../Sources/WorkDailyUI.swift)는 수용 시험, 일상 사용 허용, 미관측 종료, 업데이트 구간 전환을 관리합니다. [WorkProcess.swift](../Sources/WorkProcess.swift)는 프로세스 시작 시각과 볼륨 UUID·inode를 비교합니다.
4. [update-work.py](../scripts/update-work.py)는 분리 표식 검사, 후보 복사·빌드·시험, 동의된 자동 교체를 연결합니다. 교체 후 운영 checkout의 고정값을 동기화하고 현재 HEAD 작성자로 로컬 커밋을 만들 수 있습니다.
5. [install-work-update-approved.py](../scripts/install-work-update-approved.py)와 [launcher_replacement.py](../scripts/launcher_replacement.py)는 검토·manifest·상태 확인 후 백업과 교체 영수증을 남깁니다. 부분 실패 시 자동 롤백은 없습니다.
6. [main.swift](../Sources/main.swift)의 일반 `app`·`cli`·로그인 명령은 운영용으로 연결되지 않았습니다. 개발용 shortcut과 업무용 standalone 런처는 다른 빌드 산출물입니다.

## 공개 파일과 이력 점검

| 항목 | 확인 결과 |
|---|---|
| 라이선스 | 루트에 Apache-2.0 전문이 있으며 README의 표기와 일치. 라이선스 변경 없음 |
| 배포 내용 | 현재 추적 파일은 소스·시험·문서·설정. 공식 앱·아이콘·빌드 바이너리 없음 |
| 로컬 자료 제외 | `.build`, `.test-data`, `.live-tests`, `.profiles`, `.private`, `Assets`, `.env` 및 인증 파일 패턴은 `.gitignore` 대상 |
| 과거 삭제 파일 | 확인한 공개 main 이력에는 현재 트리 밖으로 삭제된 별도 파일 경로가 없었음 |
| 자격 증명 패턴 | OpenAI/GitHub/Slack 토큰 및 PEM/OpenSSH 개인키 시작 패턴에서 발견 없음 |
| 경로·이메일 | 검색 결과를 확인했으며 `/Users/x`, `example.test`, 테스트용 GitHub noreply 주소였음 |
| 커밋 메타데이터 | 공개 main의 작성자·커미터 이메일은 모두 GitHub noreply 주소 |
| GitHub 보호 설정 | secret scanning과 push protection 활성화. 비공개 취약점 보고는 비활성화 |

이 검사는 알려진 문자열 패턴과 추적 파일을 대상으로 했습니다. 인코딩된 비밀, 미탐 패턴, 접근할 수 없는 ref, fork, PR 첨부물, Issue 내용, 외부 캐시는 검사 범위가 아닙니다. `.gitignore`는 이미 추적된 파일이나 과거 이력을 삭제하는 수단이 아닙니다.

## 이번 문서 변경

- README를 한국어 본문·영어 소개의 공개 사용자 안내로 교체했습니다. 정확한 앱 구조, 실험적 상태, 분리 한계, 설치 단계, 로컬 커밋 부작용, 데이터 위치를 명시했습니다.
- 설치 안내에서 팀 내부 표현을 제거하고 기존 프로필 이동·사용 중지·선택 아이콘 안내를 정리했습니다.
- 수동 업데이트의 불완전한 명령과 JSON 예시를 교체했습니다. 검토 대기의 종료 코드 2, 코드만 교체할 때의 GUI 빌드, manifest 해시, 부분 실패 한계를 구분했습니다.
- [기여 안내](../CONTRIBUTING.md)와 [보안 보고 안내](../SECURITY.md)를 추가했습니다.
- 실행 코드·시험·라이선스·고정값·GitHub 설정은 바꾸지 않았습니다.

## 공개 운영 전에 남은 사항

| 우선순위 | 항목 | 현재 판단 |
|---|---|---|
| 높음 | 일반 사용자 설치 호환성 | 앱 경로·실행 파일·서명·번들 구조가 고정됨. 일반 사용자 설치본과 같은지 별도 Mac에서 확인해야 하며, 조건이 다르면 문서만으로 지원할 수 없음 |
| 높음 | 비공개 보안 보고 | GitHub private vulnerability reporting 활성화 또는 별도 비공개 연락처 지정 필요. 이번 작업에서는 원격 설정을 변경하지 않음 |
| 높음 | 실제 사용자 검증 | 깨끗한 환경의 최초 설치, 로그인 유지, 개인 앱 영향, 공식 앱 업데이트, 재부팅 후 사용을 이번에 수행하지 않음 |
| 보통 | 지원 환경 | 최소 macOS·Xcode·Python 버전 및 CPU별 검증 표가 없음. README에 미확립 상태를 명시 |
| 보통 | 자동 업데이트의 소스 관리 | 로컬 변경을 빌드에 포함하고 HEAD 작성자로 고정값 커밋을 만드는 동작을 유지·고지. 공개 사용자용 동작으로 계속 유지할지는 별도 제품 결정 |
| 보통 | 재현 가능한 배포 | 현재 소스 빌드 방식. 추적된 CI workflow와 릴리스 자산 없음. 공증된 배포 바이너리·버전별 지원 정책을 제공한다고 표시하지 않음 |

## 이번 검증의 한계

문서 6개의 내부 링크·앵커 34개, Shell 예제 12개의 구문(`sh -n`), 미승인 JSON 양식 1개의 파싱·항목을 확인했고 모두 통과했습니다. `git diff --check`도 통과했습니다. Shell 예제는 실행하지 않았습니다. 실행 코드 변경이 없어 전체 `scripts/check.sh` 재실행은 생략했습니다. 문서 검토 단계에서는 실제 앱 실행·설치·로그인·서비스 재시작·재부팅 검증, 커밋·push·GitHub 설정 변경을 수행하지 않았습니다.


## 로컬 최신 커밋 추가 검토

사용자의 후속 push 요청에 따라 `9cddd97`을 별도로 검토했습니다.

- 변경 범위는 `Sources/AppTrial.swift`의 관리 고정값 블록뿐입니다. 현재 앱 대상은 `26.1007.30912` / build `20156`이며 이전 current와 history가 새 history에 순서대로 보존되어 있습니다.
- CLI 버전·build·해시는 이전 커밋과 같습니다. 해시 형식과 새 검토 ID 형식을 확인했습니다.
- 검토 시점의 설치된 공식 앱에서 앱·CLI 메타데이터와 앱 실행 파일·CLI·`app.asar`의 SHA-256을 읽어 새 고정값과 일치함을 확인했습니다.
- 앱과 번들 CLI 모두 identifier 및 Team ID 요구 조건을 포함한 `codesign --verify --strict --deep --all-architectures` 검사를 통과했습니다.
- 고정값 변경에 실행 로직 변경이나 개인 경로·자격 증명이 추가되지 않았습니다. 이 검토 범위에서 push를 막을 문제는 발견하지 못했습니다.

이는 설치 파일에 대한 읽기 전용 확인입니다. 전체 자동 시험이나 실제 계정 분리·로그인·재부팅 검증을 새로 수행했다는 뜻은 아닙니다. 후속 요청의 게시 대상은 이 고정값 커밋과 공개 문서 변경이며, GitHub 보안 설정 변경은 포함하지 않습니다.
