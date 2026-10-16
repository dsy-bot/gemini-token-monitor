# ⚡ Antigravity Token Monitor v5.0

[🌐 Read in English (README_EN.md)](README_EN.md)

> **Google Antigravity Language Server 공식 Quota API 직결, 최근 N시간 윈도우 속도 측정, 실측 소수점 CSV 로깅 & 실근무 스케줄 기반 현실적 쿼터 예측 시스템**  
> 외부 런타임(Python, Node.js 등) 설치가 전혀 필요 없는 **초경량 무설치 단일 실행 파일(.exe)** 로 동작하며, 백그라운드 유휴 메모리를 **2~5 MB** 로 극도로 가볍게 유지합니다.

---

## 🌟 v5.0 주요 핵심 기능

1. **🎯 공식 Language Server QuotaSummary 엔드포인트 직결 (v5.0 전면 개편)**:
   - 로컬 `language_server.exe`의 `RetrieveUserQuotaSummary` 엔드포인트를 직접 호출하여 공식 쿼터 잔여율(소수점 단위 정밀도)과 공식 리셋 시각을 100% 무결점으로 수신합니다.
   - 기존의 불완전한 배율 역산(`weekly_multiplier`), 수동 보정 창, 요일/시간 수동 입력 등의 레거시 로직이 완전히 퇴출되어 정확도가 100% 보장됩니다.

2. **🤖 Gemini 4 Argon 및 3대 모델 그룹 독립 모니터링**:
   - **Gemini Models** (Flash / Pro): 5시간 쿼터 + 1주일 쿼터
   - **Gemini 4 Argon** (단독 쿼터): 1주일 쿼터
   - **Claude and GPT models** (3P): 5시간 쿼터 + 1주일 쿼터 (필요 시 알림 끄기 지원)
   - 각 모델 그룹별로 활성화 여부(`enabled`) 및 개별 경고/위험 임계치를 자유롭게 설정 가능합니다.

3. **⏱️ 최근 N시간 윈도우(`speed_window_seconds`) 기준 소비속도 계산**:
   - 1분 단위 직전 호출 비교 시 발생하는 심한 널뛰기/노이즈를 방지하기 위해, 설정된 시간 윈도우(기본 3600초 = 1시간) 동안의 과거 데이터와 비교하여 정밀한 시간당 소모율(`%/h`)을 산출합니다.
   - 프로그램 재시작 시에도 당일 CSV 파일로부터 최근 이력을 즉시 복원하여 연속적인 속도 측정이 유지됩니다.

4. **📊 순수 실측 소수점 6자리 CSV 로깅 (`logs/usage/yyyyMMdd_usage.csv`)**:
   - 속도나 리셋시간 같은 파생값/중복 필드를 일체 배제하고, 오직 **타임스탬프와 각 버킷의 소수점 6자리(`F6`) 실측 잔여량**만 미니멀하게 저장합니다.
   - 엑셀, Pandas, 시각화 도구로 바로 불러와 분석하기에 가장 이상적인 구조입니다:
     ```csv
     timestamp,gemini_5h,gemini_weekly,argon_weekly,claude_5h,claude_weekly
     2026-10-16 10:45:01,93.533385,98.152400,85.800266,100.000000,100.000000
     2026-10-16 10:46:01,93.508640,98.145324,85.800266,100.000000,100.000000
     ```

5. **🏢 요일별 출퇴근 스케줄(`work_schedule`) 기반 현실적 쿼터 예측**:
   - 퇴근 후, 수면 시간, 주말 등 에이전트를 쓰지 않는 비활동 시간을 자동 제외합니다.
   - 리셋 시점까지의 **순수 잔여 실근무 시간**만을 계산하여, 현재 소비 속도 지속 시 리셋 시점의 예상 잔여량을 1줄로 명쾌하게 표시합니다.
     ```text
     예상 잔여: (실근무 7.2h 기준) 5시간 82.5% | [경고<20%, 위험<10%]
     ```

6. **🔄 무중단 설정 핫리로드 (Hot-Reload)**:
   - `config.json`을 수정하고 저장하면 프로그램을 재시작할 필요 없이 다음 주기 호출 시 갱신 주기(`interval_seconds`), 속도 측정 범위, 모델별 임계치, 근무 일정이 즉시 자동 반영됩니다.

7. **🚦 3단계 상태 판별 & 트레이 동적 숫자 배지**:
   - 🔴 **위험 (Danger)**: 잔여량 $\le$ 위험 임계치 또는 소모속도 $\ge$ 위험 임계치
   - 🟠 **경고 (Warning)**: 잔여량 $\le$ 경고 임계치 또는 소모속도 $\ge$ 경고 임계치
   - 🟢 **정상 (Normal)**: 안정 범위
   - 트레이 아이콘에 현재 대표 잔여 %(숫자)가 실시간으로 동적 렌더링되며 툴팁으로 전체 모델 현황 요약 제공.

8. **🚀 극대화된 경량화 (메모리 2~5 MB)**:
   - `System.Threading.Timer`, 2세대 GC 강제 수거 및 Windows 네이티브 `EmptyWorkingSet`을 적용하여 백그라운드 유휴 메모리를 **2~5 MB**로 완벽하게 억제합니다.

---

## ⚙️ 설정 파일 (`config.json`) 가이드

`config.json`은 프로그램 실행 시 자동으로 로드되며, 수정 후 저장하면 **재시작 없이 즉시 반영(Hot-Reload)** 됩니다.

```json
{
  "interval_seconds": 60,
  "speed_window_seconds": 3600,
  "work_schedule": {
    "Monday": "09:00-18:00",
    "Tuesday": "09:00-18:00",
    "Wednesday": "09:00-18:00",
    "Thursday": "09:00-18:00",
    "Friday": "09:00-18:00",
    "Saturday": "off",
    "Sunday": "off"
  },
  "model_thresholds": {
    "Gemini Models": {
      "enabled": true,
      "warning_remaining_5h": 20.0,
      "danger_remaining_5h": 10.0,
      "warning_remaining_1w": 25.0,
      "danger_remaining_1w": 10.0,
      "warning_speed_5h": 20.0,
      "danger_speed_5h": 40.0
    },
    "Gemini 4 Argon": {
      "enabled": true,
      "warning_remaining_1w": 25.0,
      "danger_remaining_1w": 10.0,
      "warning_speed_1w": 3.0,
      "danger_speed_1w": 6.0
    },
    "Claude and GPT models": {
      "enabled": false,
      "warning_remaining_5h": 15.0,
      "danger_remaining_5h": 5.0,
      "warning_remaining_1w": 20.0,
      "danger_remaining_1w": 10.0
    }
  }
}
```

| 항목 | 기본값 | 설명 |
| :--- | :--- | :--- |
| `interval_seconds` | `60` | 공식 API 쿼터 자동 갱신 주기 (초 단위, 최소 5초) |
| `speed_window_seconds` | `3600` | 소비속도(`%/h`) 계산용 과거 비교 윈도우 (초 단위, 기본 1시간) |
| `work_schedule` | 월~금 09:00-18:00 | 요일별 출퇴근(활동) 시간대 (`"HH:mm-HH:mm"` 또는 `"off"`) |
| `model_thresholds` | 모델별 설정 | 각 모델 그룹별 알림 활성화(`enabled`) 및 5시간/주간 경고·위험 임계치 |

---

## 🚀 빠른 시작 & 업데이트

### 1. 프로그램 실행
- `AntigravityTokenMonitor.exe`를 더블클릭하여 실행합니다.
- **트레이 아이콘 더블클릭**: 📊 실시간 현황 창 열기 (경량 ReadOnly TextBox)
- **트레이 아이콘 우클릭**: 지금 갱신, 로그 폴더 열기, 설정 파일 열기, 종료

### 2. 빌드 (컴파일)
- `build.bat`을 실행하면 Windows 내장 C# 컴파일러(`csc.exe`)를 통해 1초 만에 최적화된 `.exe`가 생성됩니다. (외부 개발 도구 설치 불필요)

### 3. 부팅 시 자동 시작 등록
- **등록**: `Install-Startup.bat` 더블클릭 (시작프로그램 바로가기 자동 생성)
- **해제**: `Uninstall-Startup.bat` 더블클릭

---

## 📂 로그 파일 구조

프로그램 실행 폴더의 `logs/` 디렉터리에 자동으로 저장됩니다:

- `logs/usage/yyyyMMdd_usage.csv`: 타임스탬프 및 버킷별 소수점 6자리 순수 실측치
- `logs/system/yyyyMMdd_system.log`: 프로그램 시작 및 오류 예외 기록
