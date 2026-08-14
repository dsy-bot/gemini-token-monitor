# ⚡ Gemini API 토큰 모니터링 프로그램 (Gemini Token Monitor)

> **로컬 세션 로그 실시간 스캔 & 실측 5:1 소모 비율 100% 정밀 동기화 롤링 쿼터 모니터링 시스템**
> Windows 트레이 아이콘을 통해 Google Gemini 토큰 소모량, 5시간 및 주간 롤링 쿼터 잔여율, 전일 대비 소모속도를 한눈에 확인할 수 있는 초경량 모니터링 프로그램입니다.

---

## ✨ 핵심 기능 및 메커니즘

1. **📜 1~3일 세부 토큰 소모 로그 연동 (`token_history.json`)**:
   - 스캔된 모든 대화 세션의 타임스탬프와 토큰 수치를 3일간(72시간) 자동으로 적재 관리합니다. 72시간이 지난 옛 기록은 자동으로 정돈 삭제됩니다.

2. **⏰ 초기화 시점 수동 지정 & 이전 토큰 자동 차감 무시**:
   - **`config.json`** 또는 UI 설정 창에서 5시간/주간 초기화까지 **남은 시간**을 수동으로 입력할 수 있습니다.
   - `override5HourRemainingMinutes`: 5시간 초기화까지 남은 **분(minute)** 입력 (예: `90` 입력 시 1시간 30분 후 초기화 시점 자동 계산).
   - `overrideWeeklyRemainingHours`: 주간 초기화까지 남은 **시간(hour)** 입력 (예: `48` 입력 시 48시간 후 주간 리셋 시점 계산).
   - 초기화 시점이 설정되면 로그 데이터를 기반으로 **해당 초기화 시점 이전 토큰은 롤링 합산에서 자동 차감 무시**되어 수치가 정확하게 보정됩니다.

3. **🔒 0% 네트워크 오프라인 전용 스캔**:
   - 외부 REST API 호출 없이 사용자 PC 로컬 세션 로그(`~/.gemini`, `%APPDATA%/gemini` 등)만 실시간으로 안전하게 스캔합니다. (메모리 ~12MB)

4. **📐 실측 소모% 변화량 역산 5:1 쿼터 비율 엔진**:
   - Google Gemini 공식 화면 실측 데이터(5시간 5% 감소 당 주간 1% 감소)를 수학적으로 역산 반영하였습니다.
   - **5시간 롤링 쿼터 풀**: `1,000,000 Tokens` (5시간 단기 폭주 제어용 한도)
   - **1주일 롤링 쿼터 풀**: `5,000,000 Tokens` (7일 전체 쿼터 예산 한도)

5. **🧩 세션 누적 토큰 중복 합산 방지 (Deduplication Engine)**:
   - 대화 세션 로그 파일(`transcript.jsonl`) 내부의 단계별 누적 토큰 중 **최신 최댓값(`MaxTokenInFile`) 단 하나만 추출**하여 첫 질문 시 토큰 뻥튀기 현상을 원천 차단했습니다.

---

## 📁 프로젝트 구조

```text
gemini-token-monitor/
├── GeminiTokenMonitor.ps1   # 메인 모니터링 및 WinForms 트레이 GUI 스크립트
├── config.json              # 모니터링 쿼터, 수동 초기화 시점 및 주간 리셋 요일 설정
├── token_history.json       # 1~3일(72시간) 세부 토큰 소모 타임스탬프 로그
├── daily_usage.json         # 일자별 누적 토큰 및 소모속도 히스토리
├── Launch-Silent.vbs        # 검은 콘솔 창 없이 백그라운드 무소음 실행 스크립트
├── Run-Test.bat             # 즉시 테스트 실행 배치 파일
├── Install-Startup.bat      # Windows 윈도우 시작 프로그램 등록 스크립트
└── modules/
    └── GeminiApiPing.ps1    # REST API 핑 헬스체크 모듈 (선택적 활성화)
```

---

## ⚙️ 설정 가이드 (`config.json`)

```json
{
  "dailyQuotaTokens": 1000000,
  "rolling5HourQuotaTokens": 1000000,
  "weeklyQuotaTokens": 5000000,
  "override5HourRemainingMinutes": null,
  "overrideWeeklyRemainingHours": null,
  "weeklyResetDay": 1,
  "weeklyResetHour": 9,
  "checkIntervalMinutes": 10
}
```

- `override5HourRemainingMinutes`: 5시간 초기화 남은시간(분 단위, 예: `90` 설정 시 1시간 30분 후 초기화, `null`이면 자동 스캔)
- `overrideWeeklyRemainingHours`: 주간 초기화 남은시간(시간 단위, 예: `48` 설정 시 48시간 후 리셋, `null`이면 자동 스캔)
- `weeklyResetDay`: 주간 쿼터 리셋 요일 지정 (`1`=월, `2`=화, `3`=수, `4`=목, `5`=금, `6`=토, `0`=일)
- `weeklyResetHour`: 주간 쿼터 리셋 시각 지정 (`0`~`23`시, 기본값 `9` = 오전 9시)

---

## 🚀 실행 및 사용 방법

1. **무소음 백그라운드 실행**:
   - `Launch-Silent.vbs` 파일을 더블클릭합니다.
2. **트레이 아이콘 사용**:
   - 트레이 아이콘 우클릭 $\rightarrow$ **[초기화 시점 및 설정]**에서 남은 시간(분/시간)을 직접 입력하고 저장하면 로그를 기반으로 수치가 즉시 보정됩니다.
