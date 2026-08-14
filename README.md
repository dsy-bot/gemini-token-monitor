# ⚡ Gemini API 토큰 모니터링 프로그램 (Gemini Token Monitor)

> **로컬 세션 로그 실시간 스캔 & 실측 5:1 소모 비율 100% 정밀 동기화 롤링 쿼터 모니터링 시스템**
> Windows 트레이 아이콘을 통해 Google Gemini 토큰 소모량, 5시간 및 주간 롤링 쿼터 잔여율, 전일 대비 소모속도를 한눈에 확인할 수 있는 초경량 모니터링 프로그램입니다.

---

## ✨ 핵심 기능 및 메커니즘

1. **🔒 0% 네트워크 오프라인 전용 스캔**:
   - 외부 REST API 호출 없이 사용자 PC 로컬 세션 로그(`~/.gemini`, `%APPDATA%/gemini` 등)만 실시간으로 안전하게 스캔합니다.
   - 네트워크 트래픽 0%, 메모리 사용량 ~12MB 수준으로 극도로 경량화되어 있습니다.

2. **📐 실측 소모% 변화량 역산 5:1 쿼터 비율 엔진**:
   - Google Gemini 공식 화면 실측 데이터(5시간 5% 감소 당 주간 1% 감소)를 수학적으로 역산 보정하였습니다.
   - **5시간 롤링 쿼터 풀**: `1,000,000 Tokens` (5시간 단기 폭주 제어용 한도)
   - **1주일 롤링 쿼터 풀**: `5,000,000 Tokens` (7일 전체 쿼터 예산 한도)
   - 5시간 동안 단기 소모를 많이 하더라도 주간 쿼터는 넉넉히 유지되어 7일 내내 안정적으로 작업할 수 있습니다.

3. **⏰ 첫 소모 시점 앵커(First-Token Anchor) 롤링 복구**:
   - 당일 첫 프롬프트 소모 시각(예: 09:20 AM)을 앵커 기준점으로 지정하여, 5시간 경과 후(`14:20 PM`) 만료 토큰이 자동으로 롤링 합산에서 차감되어 **100% 완충 복구되는 남은 시간**을 직관적으로 보여줍니다.

4. **🧩 세션 누적 토큰 중복 합산 방지 (Deduplication Engine)**:
   - 대화 세션 로그 파일(`transcript.jsonl`) 내부의 단계별 누적 토큰 중 **최신 최댓값(`MaxTokenInFile`) 단 하나만 추출**하여 첫 질문 시 토큰 수치가 뻥튀기되던 현상을 원천 차단했습니다.

5. **📅 주간 쿼터 리셋 요일 & 시각 사용자 지정**:
   - `config.json`에서 주간 리셋 요일(`weeklyResetDay`)과 시각(`weeklyResetHour`)을 자유롭게 지정할 수 있습니다 (기본값: 매주 월요일 09:00).

6. **📊 전일 대비 소모속도 비교 (`daily_usage.json`)**:
   - 일자별 소모 기록을 자동 적재하여 어제 소모속도(TPM) 대비 **오늘 소모속도 증감률(%)**을 실시간으로 비교 표기합니다.

7. **⚡ 초경량 & 메모리 누수 방지**:
   - Windows GDI 아이콘 핸들 자동 해제(`DestroyIcon`) 및 가비지 컬렉션을 적용하여 메모리 12MB 상태를 일정하게 유지합니다.

---

## 📁 프로젝트 구조

```text
gemini-token-monitor/
├── GeminiTokenMonitor.ps1   # 메인 모니터링 및 WinForms 트레이 GUI 스크립트
├── config.json              # 모니터링 쿼터 및 주간 리셋 요일/시각 설정 파일
├── Launch-Silent.vbs        # 검은 콘솔 창 없이 백그라운드 무소음 실행 스크립트
├── Run-Test.bat             # 즉시 테스트 실행 배치 파일
├── Install-Startup.bat      # Windows 윈도우 시작 프로그램 등록 스크립트
├── Uninstall-Startup.bat    # Windows 윈도우 시작 프로그램 등록 해제 스크립트
├── modules/
│   └── GeminiApiPing.ps1    # REST API 핑 헬스체크 모듈 (선택적 활성화)
└── unused_archive/          # 미사용 및 레거시 스크립트 아카이브
```

---

## ⚙️ 설정 가이드 (`config.json`)

```json
{
  "enableApiPing": false,
  "dailyQuotaTokens": 1000000,
  "rolling5HourQuotaTokens": 1000000,
  "weeklyQuotaTokens": 5000000,
  "weeklyResetDay": 1,
  "weeklyResetHour": 9,
  "checkIntervalMinutes": 10
}
```

- `weeklyResetDay`: 주간 쿼터 리셋 요일 지정 (`1`=월, `2`=화, `3`=수, `4`=목, `5`=금, `6`=토, `0`=일)
- `weeklyResetHour`: 주간 쿼터 리셋 시각 지정 (`0`~`23`시, 기본값 `9` = 오전 9시)
- `rolling5HourQuotaTokens`: 5시간 단기 폭주 롤링 풀 (기본 `1,000,000` 토큰)
- `weeklyQuotaTokens`: 1주일 롤링 총 풀 (기본 `5,000,000` 토큰)
- `enableApiPing`: API 핑 활성화 여부 (`false`: 네트워크 0% 오프라인 전용 모드)

---

## 🚀 실행 및 사용 방법

1. **무소음 백그라운드 실행**:
   - `Launch-Silent.vbs` 파일을 더블클릭합니다.
2. **트레이 아이콘 사용**:
   - 작업 표시줄 트레이 영역의 **[숫자 배지 아이콘]**을 더블클릭하거나 우클릭하여 **[현 상태 보기]**를 누릅니다.
3. **윈도우 시작 프로그램 등록**:
   - `Install-Startup.bat`를 실행하면 부팅 시 자동 구동됩니다.
