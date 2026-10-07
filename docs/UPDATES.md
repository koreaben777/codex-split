# 공식 앱 업데이트 대응

자동 대응은 서명 검사 생략이나 버전·해시 제한 해제가 아닙니다. 공식 앱과 번들 CLI는 언제나 정확한 고정값과 identifier별 strict 서명을 통과해야 실행되며, 새 버전은 **검토 edge 하나**로만 이어집니다. 이전 성공·일상 허용은 새 런처나 새 버전으로 이어지지 않습니다.

## 흐름

| 단계 | 처리 | 사용자 확인 |
|---|---|---|
| 감지 | 런처 실행 시 고정값 불일치면 업무 앱을 열지 않고 업데이트 요약을 보여 줌. `codex-split update-check work` | 없음 |
| 후보 검증 | `update-work.py`: 서명 확인된 변경만 격리 복사본에 고정값 이력·검토 ID를 추가하고 전체 검사·빌드, 앱 재검사 | 자동 대응 동의 또는 직접 실행 |
| 호환성 확인 | 업무 저장소 분리 표식 정적 점검 + 검토 기록(`REVIEW.json`) | 자동 대응 동의 또는 수동 검토 |
| 배치 | `install-work-update-approved.py`: 런처 미실행, 미해결 방문·거부 보고 없음, 기록 불변, 후보 고정값과 공식 앱 일치(strict)를 확인한 뒤 백업·배타 이동·영수증으로 교체 | 자동 대응 동의 또는 설치 실행 |
| 버전 전환 | 새 런처 실행 → 영수증·binding·edge·공식 앱 재검사 → 동의하면 이전 구간을 불변 보존본으로 남기고 성공 0회·허용 없음의 새 구간 시작 | GUI 동의 |
| 수용·일상 | 수용 시험 두 번 뒤 별도 일상 허용 | 필요 |
| 실패 복구 | 새 구간 전환 전: `--restore-backup`으로 이전 런처 복원(수동). 전환 후: 이전 런처는 새 기록을 읽지 못해 실행을 막음 | 필요 |

자동 롤백은 없습니다. 공식 앱 버전을 되돌리거나 수정·재서명하지 않습니다.

## 자동 대응 (기본 경로)

1. 공식 앱에서 업데이트를 설치합니다.
2. 업무 런처를 열면 서명·identifier가 확인된 새 버전을 감지하고 **자동 대응 시작** 동의를 한 번 받습니다. 서명을 확인하지 못하면 제안하지 않습니다.
3. 런처는 `update-work.py --auto`를 분리 실행하고 닫힙니다. 스크립트가 공식 앱 재검사, 업무 저장소 분리 표식(`CODEX_ELECTRON_USER_DATA_PATH`, `CODEX_HOME`, `CODEX_SQLITE_HOME`, `user-data-dir`) 정적 점검, 격리 후보 빌드와 `scripts/check.sh`, 앱 재검사를 하고, 런처가 닫혀 있을 때(최대 10분 대기) 백업·영수증과 함께 교체합니다. 시작·완료·중단은 macOS 알림으로 알립니다.
4. 런처를 다시 열면 새 수용 구간 시작 동의, 수용 시험 두 번, 일상 허용 동의를 차례로 받습니다.

자동 모드의 `REVIEW.json`은 `mode: automatic`이며 항목마다 `automatic`과 실제로 확인한 내용만 적습니다. 공식 변경 내역은 사람이 검토하지 않았다고 명시하고, 저장·인증 분리는 정적 표식과 새 수용 시험으로 확인합니다. 같은 공식 버전에서 런처만 바꾸는 경우에는 자동 모드를 쓸 수 없습니다. 분리 표식이 하나라도 없으면 빌드 전에 `blocked-incompatible`로 멈춥니다.

## 수동 경로

```sh
sh scripts/build.sh
.build/codex-split update-check work --json
python3 scripts/update-work.py              # 후보: .build/work-updates/<id>/candidate
python3 scripts/install-work-update-approved.py --manifest ~/Applications/CodexSplit-work.app        # 설치본
python3 scripts/install-work-update-approved.py --manifest <후보>/.build/CodexSplit-work-standalone.app  # 후보
python3 scripts/install-work-update-approved.py --preflight --candidate-root <후보> \
  --review <REVIEW.json> --from-manifest-sha256 <설치본> --to-manifest-sha256 <후보>
python3 scripts/install-work-update-approved.py --install ...      # 같은 인자
```

`REVIEW.json` 형식:

```json
{"schemaVersion": 1, "mode": "reviewed", "reviewID": "<후보 ID, 런처만 교체하면 null>",
 "candidateManifestSHA256": "<후보 bundle manifest>",
 "items": {"baseline": {"result": "accepted", "evidence": "..."}, "release-evidence": {...},
           "identity": {...}, "storage-auth-ipc": {...}, "preservation-recovery": {...}, "trial-consent": {...}}}
```

원본은 교체 workspace에 `REVIEW.json`으로, binding은 `UPDATE.json`으로 보존됩니다.

## 고정값 이력과 검토 edge

`Sources/AppTrial.swift`의 `WorkAppPins` 관리 블록만 후보에서 바뀝니다.

- `current`: 실행 가능한 유일한 대상. 앱/CLI 버전·build·SHA-256과 `app.asar` SHA-256.
- `history`: 이전 승인 대상. 보존된 설정·실행 기록을 **읽는 데만** 쓰고, 실행·저장소 연결·공식 앱 검사에는 쓸 수 없습니다.
- `updateReviewID`: `history.first → current` edge 하나. 런처는 이 edge와 맞는 이전 구간에서만 버전 전환을 제안합니다.

연속 업데이트: `update-work.py`는 설치된 런처를 만든 후보가 있으면 그 후보 소스에서 다음 후보를 만들어 이력을 잇습니다. 배치는 (1) 교체할 런처가 현재 구간의 런처와 같고 (2) 후보 edge의 시작 버전이 현재 구간 버전과 같을 때만 진행합니다.

업무 설정만 마치고 런처를 아직 한 번도 열지 않은 상태에서 업데이트가 와도 같은 경로로 이어집니다. 이때는 완료된 설정의 버전이 edge 시작점이 되고, 교체 영수증의 이전 런처가 전환 기록에 남습니다.

처음 설정 전에는 `update-work.py --pin-installed`로 설치된 공식 앱 버전을 checkout에 고정합니다. 업무 프로필이 생긴 뒤에는 이 명령을 거부하고 업데이트 경로만 씁니다.

## 실행 중 업데이트

- 업무 창이 열려 있는 동안 공식 앱이 디스크에서 바뀌어도 커널 세대로 종료를 계속 관측합니다. 런처를 다시 누르면 기존 창만 활성화하고 바뀐 사실을 알립니다.
- 종료 뒤 다음 실행은 고정값 불일치로 막고 자동 대응을 제안합니다.
- 검사 도중 파일이 바뀌면 `unverified`, 배치 도중 공식 앱·기록이 바뀌면 교체를 중단하고 이전 런처를 유지합니다.

## 부분 실패

| 중단 지점 | 상태 | 복원 |
|---|---|---|
| staging까지 | 설치본 그대로, workspace에 `staged` 기록 | 조치 불필요 |
| 이전 런처 이동 후(`oldMoved`) | 설치 경로 비어 있음, `previous.app` 보존 | `previous.app`을 설치 경로로 이동(수동) |
| 게시 후 검증 전(`published`) | 새 런처 설치, 백업 보존 | 원인 확인 후 수동 복원 또는 재검증 |
| binding 기록 실패 | 영수증 `verified`, `UPDATE.json` 없음 → 런처는 전환을 제안하지 않음 | `--bind-update` 또는 `--restore-backup` |
| 복원 중 중단 | `RESTORE.json` `restoring` | `previous.app`을 설치 경로로 이동(수동). 복원 기록이 있는 영수증은 증거로 쓰지 않음 |
| 전환 후 | 새 구간 기록, 이전 구간은 불변 보존본 | 이전 런처 복원은 실행을 막을 뿐이므로 상태 확인 후 별도 판단 |

## 검증

- `Tests/work_update_transition.sh`: 런처만 교체/버전 업데이트 전환, 보존본 바이트 유지, 이전 성공·허용 비승계, 미해결 실행·거부 보고·root 교체·동의 만료·검사 실패 차단, 보존본 변조·알 수 없는 필드 거부, 영수증 탐색.
- `Tests/work_update_candidate_stage.py`: 실제 소스를 복사해 고정값을 바꾸고 컴파일. 후보가 이전 버전 기록을 읽되 실행·저장소 연결·공식 앱 검사에는 쓰지 못함.
- `Tests/work_update_install.py`, `Tests/launcher_replacement_test.py`: 설치·교체·binding·검토 누락·미해결 실행·런처 실행 중·배치 중 변경·후보 위치 위조·아이콘 유지·복원.
- `Tests/work_update_automation.py`, `Tests/work_update.sh`, 전체 `scripts/check.sh`.

실제 공식 앱 업데이트와 수용 시험은 자동 시험과 별개입니다.
