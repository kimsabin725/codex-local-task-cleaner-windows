# Codex Local Task Cleaner for Windows

ChatGPT 데스크톱 앱의 로컬 Codex 작업을 정리하는 **비공식 Windows 전용 도구**입니다.
Codex 앱이나 Codex CLI, Python, Node.js를 별도로 설치하지 않습니다.

## 중요

- 실행 전에 ChatGPT 데스크톱 앱을 트레이 아이콘까지 완전히 종료하세요.
- 내부 저장 구조를 직접 정리하는 비공식 도구이므로 먼저 미리보기와 백업을 사용합니다.
- 지원하는 DB 구조가 아니면 아무것도 수정하지 않고 중단합니다.
- 정리 전 DB, 전역 상태, 세션 인덱스와 대상 세션 파일을 백업합니다.
- 검증 실패 시 백업을 자동 복원합니다.
- 본체가 이미 삭제됐지만 앱의 최근 목록에 남은 `목록잔상`도 표시하고 정리합니다.
- 작업 폴더 삭제는 별도 선택이며 Windows 휴지통으로만 보냅니다.
- 백업은 자동 삭제되지 않습니다.

## 가장 쉬운 실행법

1. ChatGPT 앱을 완전히 종료합니다.
2. `CodexTaskCleaner.cmd`를 더블클릭합니다.
3. 기본 목록에는 사용자가 만든 일반 대화만 표시됩니다.
4. 목록에서 삭제할 작업 번호를 입력합니다. 여러 개는 `1,2`처럼 입력합니다.
5. 제목, 전체 ID와 폴더가 표시되는 최종 확인 화면을 검토합니다.
6. 자동화·하위 작업까지 보려면 목록 화면에서 `A`를 입력합니다.
7. 미리보기를 확인합니다.
8. 실제 삭제하려면 정확히 `DELETE`를 입력합니다.

목록 앞의 번호는 실행할 때마다 새로 붙는 임시 번호입니다. 기존 작업 제목이나 과거에
사용한 `1번~5번` 같은 이름과는 관계없습니다.

## 명령줄 사용

목록만 확인:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexTaskCleaner.ps1 -List
```

자동화와 내부 하위 작업을 포함한 전체 목록:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexTaskCleaner.ps1 -List -ShowAll
```

ID를 지정해 미리보기:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexTaskCleaner.ps1 -Id "작업-ID"
```

ID를 지정해 실행하고 작업 폴더도 휴지통으로 이동:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexTaskCleaner.ps1 -Id "작업-ID" -Execute -RemoveWorkspaces
```

## 정리 대상

- `state_5.sqlite`의 작업 및 하위 작업 관계
- 로그, 목표, 메모리 DB의 해당 작업 참조
- `sqlite\codex-dev.db`의 로컬 작업 카탈로그와 타임라인 참조
- `session_index.jsonl`
- 전역 UI 상태 JSON과 백업·임시 상태 파일
- 해당 작업의 rollout 세션 파일
- 해당 작업 ID의 writer lock 및 visualization 폴더

첨부 파일처럼 작업 소유 관계를 안전하게 확정할 수 없는 공용 저장물은 삭제하지 않습니다.

## 복구

백업 기본 위치:

```text
%LOCALAPPDATA%\CodexTaskCleaner\Backups
```

각 백업에는 `manifest.json`, 전체 핵심 메타데이터 사본과 대상 세션 파일이 포함됩니다.
자동 복구에 실패한 예외 상황에서는 백업 폴더를 보존하고 배포자에게 문의하세요.

## 호환성

- Windows 10/11
- Windows PowerShell 5.1 이상
- 현재 ChatGPT/Codex 로컬 저장 구조의 `state_5.sqlite` 계열
- `codex-dev.db`가 있는 최신 목록 구조와, 해당 DB가 없는 이전 구조

## 목록 분류

- `일반대화`: 사용자가 ChatGPT 데스크톱 앱에서 시작한 로컬 Codex 대화
- `목록잔상`: 실제 세션은 없지만 최근/고정 목록 카탈로그에 남아 있는 항목
- `자동화`: 예약 실행, Outlook 연동 등 비대화형 실행 기록
- `하위작업`: guardian 같은 내부 보조 작업

안전을 위해 `자동화`와 `하위작업`은 기본 목록에서 숨깁니다.

macOS판은 이 Windows판 검증이 끝난 뒤 동일한 핵심 로직을 사용하고 경로, 앱 감지,
휴지통 처리만 macOS 방식으로 교체할 예정입니다.

## 공식 방식과의 차이

OpenAI가 문서화한 공식 삭제 인터페이스는 Codex App Server의 `thread/delete`입니다.
이 도구는 별도 CLI 설치를 피하기 위해 로컬 메타데이터를 직접 정리하므로 비공식입니다.

- https://learn.chatgpt.com/docs/app-server

## 라이선스

MIT. `LICENSE`를 확인하세요.
