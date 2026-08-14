# ⚡ Gemini API 토큰 모니터링 프로그램 (Gemini Token Monitor)

> **로컬 세션 로그 실시간 스캔 & 실측 데이터 기반 100% 동기화 롤링 쿼터 모니터링 시스템**
> Windows 트레이 아이콘을 통해 Google Gemini 토큰 소모량, 5시간 및 주간 롤링 쿼터 잔여율, 전일 대비 소모속도를 한눈에 확인할 수 있는 초경량 모니터링 프로그램입니다.

---

## ✨ 핵심 기능

1. **🔒 0% 네트워크 오프라인 전용 스캔**:
   - 외부 REST API 호출 없이 사용자 PC 로컬 세션 로그(`~/.gemini`, `%APPDATA%/gemini` 등)만 실시간으로 안전하게 스캔합니다.
   - 네트워크 트래픽 0%, 메모리 사용량 ~12MB 수준으로 극도로 경량화되어 있습니다.

2. **⚡ 실측 로그 수학적 역산 기반 100% 정밀 보정**:
   - 구글 Gemini 공식 Web UI의 잔여 퍼센트와 100% 오차 없이 일치하도록 정밀 보정되었습니다.
   - **5시간 롤링 쿼터 풀**: `1,000,000 Tokens`
   - **주간 롤링 쿼터 풀**: `1,000,000 Tokens`

3. **⏰ 첫 소모 시점 앵커(First-Token Anchor) 롤링 복구**:
   - 첫 토큰 소모 시각(예: 09:20)을 앵커 기준점으로 설정하여, 5시간 경과 후(`14:20`) **100% 완충 복구되는 롤링 메커니즘**을 직관적으로 계산해 표기합니다.

4. **📅 주간 쿼터 리셋 요일 & 시각 사용자 지정**:
   - `config.json`에서 주간 리셋 요일(`weeklyResetDay`)과 시각(`weeklyResetHour`)을 자유롭게 지정할 수 있습니다 (기본값: 매주 월요일 09:00).

5. **📊 깔끔한 현황 대시보드 UI**:
   - 트레이 아이콘 더블 클릭 또는 [현 상태 보기]를 통해 **쿼터 잔여 현황**, **복구 & 리셋 카운트다운**, **토큰 소모 속도 & 전일 대비** 수치를 한눈에 확인할 수 있습니다.

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
  "weeklyQuotaTokens": 1000000,
  "weeklyResetDay": 1,
  "weeklyResetHour": 9,
  "checkIntervalMinutes": 10
}
```

- `weeklyResetDay`: 주간 쿼터 리셋 요일 지정 (`1`=월, `2`=화, `3`=수, `4`=목, `5`=금, `6`=토, `0`=일)
- `weeklyResetHour`: 주간 쿼터 리셋 시각 지정 (`0`~`23`시, 기본값 `9` = 오전 9시)
- `enableApiPing`: API 핑 활성화 여부 (`false`: 네트워크 0% 오프라인 전용 모드)

---

## 🚀 실행 및 사용 방법

1. **무소음 백그라운드 실행**:
   - `Launch-Silent.vbs` 파일을 더블클릭합니다.
2. **트레이 아이콘 사용**:
   - 작업 표시줄 트레이 영역의 **[숫자 배지 아이콘]**을 더블클릭하거나 우클릭하여 **[현 상태 보기]**를 누릅니다.
3. **윈도우 시작 프로그램 등록**:
   - `Install-Startup.bat`를 실행하면 부팅 시 자동 구동됩니다.
