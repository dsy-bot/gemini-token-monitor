# ⚡ Antigravity Token Monitor v4.3

[🌐 Read in English (README_EN.md)](README_EN.md)

> **Antigravity (Gemini) 토큰 쿼터 실시간 모니터링, Upstash Redis 클라우드 동기화 & 실근무 스케줄 기반 현실적 쿼터 예측 시스템**  
> 외부 런타임(Python/Node.js 등) 설치가 전혀 필요 없는 **초경량 무설치 단일 실행 파일(.exe)** 로 동작하며, 백그라운드 유휴 메모리를 **1.48 MB** 로 유지합니다.

---

## 🌟 주요 핵심 기능

1. **🎯 5시간 공인 실시간 쿼터 직결**:
   - ntigravity-usage quota --json 및 로컬 언어 서버(language_server.exe) IPC 직결을 통해 5시간 쿼터 잔여 %와 공식 리셋 시각을 100% 무결점으로 수신.
2. **🏢 요일별 출퇴근 스케줄 기반 현실적 쿼터 예측 (v4.1 신규)**:
   - 퇴근 후, 수면 시간, 주말 등 에이전트를 쓰지 않는 비활동 시간을 자동 예외 처리.
   - 리셋 시점까지의 **순수 실근무시간(Active Working Hours)** 만을 정밀 적분 계산하여 불필요한 주황/빨강불 오경보(False Alarm)를 100% 방지.
3. **☁️ Upstash Redis 클라우드 동기화 (직장 ↔ 집 PC)**:
   - 평생 무료(Free forever) Upstash Redis REST API를 연동하여 직장 PC와 집 PC 간 주간 소모량과 배율을 실시간 양방향 자동 동기화.
4. **🎯 주간/일간 쿼터 배율 자동 조절 & 수동 직접 수정**:
   - 동일 5시간 세션 내 소모량을 기반으로 실제 주간 배율($\text{Multiplier} = \frac{\Delta 5h\%}{\Delta Wk\%}$)을 전자동으로 계산 및 학습.
   - 보정 다이얼로그에서 배율 수치를 직접 원하는 값(예: 30.9배)으로 수정 및 즉시 적용 가능.
5. **🌱 새 주간 사이클 리셋 & 첫 토큰 소비 시점 자동 추적**:
   - 주간 리셋 시각 경과 시 100% 자동 리셋 및 이후 첫 토큰 소모 발생 순간(FirstActiveTime)을 실시간 감지하여 대시보드와 로그에 기록.
6. **⏰ 주간 리셋 시간 간편 맞춤 계산기**:
   - 웹 화면에 표시된 남은 시간(예: 2일 5시간 30분)을 입력하면 초기화 요일과 시각을 자동 역산하여 config.json에 저장.
7. **🚦 3단계 상태 판별 & 트레이 동적 배지 렌더링**:
   - 🔴 **위험 (Danger)**: 리셋 시점 잔여량 $\le 15\%$
   - 🟠 **경고 (Warning)**: 5h 속도 $\ge 20\%/\text{h}$ 또는 리셋 시점 잔여량 $\le 25\%$
   - 🟢 **정상 (Normal)**: 안정 범위
   - 트레이 아이콘에 실시간 잔여 % 숫자가 동적으로 실시간 드로잉.
8. **🚀 메모리 1.48MB 극대화 압축**:
   - Windows 네이티브 EmptyWorkingSet, 2세대 GC 자동 트림, HTTP 소켓 즉시 반환 적용으로 유휴 메모리 **1.48 MB** 유지 (누수 0%).
9. **📂 카테고리별/일자별 롤링 분리 로깅**:
   - /logs/usage/: 실시간 5h/주간 잔여량 기록
   - /logs/speed/: 5시간 소모 속도, 실근무 잔여시간, 리셋 카운트다운, 고갈 예측치 기록
   - /logs/system/: 시스템 상태 변경, 클라우드 동기화, 배율 자동보정 이력 기록

---

## 🚀 Git을 이용한 30초 멀티 PC 세팅 & 업데이트

새로운 PC(직장, 노트북 등)에서 사용하거나 최신 버전으로 업데이트할 때 Git을 이용하면 매우 간편합니다.

### 1. 새 PC에서 처음 설치할 때 (30초)
터미널(PowerShell 또는 CMD)에서 아래 명령어를 실행합니다:
`ash
git clone https://github.com/dsy-bot/gemini-token-monitor.git
`
1. 복제된 gemini-token-monitor 폴더로 이동합니다.
2. config.json 파일을 생성하고 본인의 **Upstash 동기화 정보 및 출퇴근 시간**을 입력합니다 (아래 가이드 참조).
3. AntigravityTokenMonitor.exe 를 실행합니다.
4. 부팅 시 자동 시작을 원하시면 Install-Startup.bat 을 더블클릭합니다.

### 2. 최신 버전으로 업데이트할 때 (5초)
프로그램 폴더에서 터미널을 열고 아래 명령어를 입력하면 즉시 최신 버전으로 업데이트됩니다:
`ash
git pull
`

---

## 🌐 Upstash 클라우드 동기화 1분 가이드 (직장 ↔ 집 PC 연동)

집 PC와 직장 PC에서 동일한 주간 쿼터 상태를 공유하려면 **Upstash (평생 무료)** 를 설정할 수 있습니다.

### 1단계: Upstash 가입 및 무료 DB 생성
1. [console.upstash.com](https://console.upstash.com) 에 접속하여 **Google 계정으로 로그인**합니다. (신용카드 등록 불필요, 평생 무료)
2. **Redis** 탭에서 **+ Create Database** 버튼을 클릭합니다.
3. 설정 입력:
   - **Name**: gemini-token (원하는 이름 입력)
   - **Region**: p-northeast-1 (Tokyo) 등 가까운 지역 선택
   - **Eviction**: 체크 (Enable)
4. 맨 아래 **Create** 버튼을 클릭하여 데이터베이스 생성을 완료합니다.

### 2단계: REST API 정보 복사
1. 생성된 데이터베이스 상세 페이지의 **REST API** 섹션으로 이동합니다.
2. 아래 2가지 값을 복사합니다:
   - **UPSTASH_REDIS_REST_URL**: https://xxxx-xxxxx.upstash.io
   - **UPSTASH_REDIS_REST_TOKEN**: A... 로 시작하는 긴 비밀 토큰 문자열

### 3단계: config.json에 입력
프로그램 폴더의 config.json에 복사한 정보를 입력합니다:
`json
{
  // 요일 복사용: Monday | Tuesday | Wednesday | Thursday | Friday | Saturday | Sunday
  "interval_minutes": 10,
  "weekly_reset_day": "Monday",
  "weekly_reset_time": "00:00",
  "weekly_multiplier": 30.9,
  "sync_enabled": true,
  "sync_url": "https://xxxx-xxxxx.upstash.io",
  "sync_api_key": "복사한_UPSTASH_REST_TOKEN_입력",

  // 요일별 출퇴근(활동) 시간대 (쉬는 날은 "off")
  "work_schedule": {
    "Monday": "09:00-18:00",
    "Tuesday": "09:00-18:00",
    "Wednesday": "09:00-18:00",
    "Thursday": "09:00-18:00",
    "Friday": "09:00-18:00",
    "Saturday": "off",
    "Sunday": "off"
  }
}
`

> **💡 직장 ↔ 집 PC 사용 팁**:  
> 직장 PC와 집 PC 양쪽의 config.json에 **동일한 sync_url과 sync_api_key** 를 넣어두면, 직장에서 퇴근 시 자동 Push되고 집에서 실행 시 자동 Pull되어 완벽하게 동기화됩니다!

---

## ⚙️ 설정 파일 (config.json) 가이드

config.json은 프로그램 실행 시 자동 생성되며, // 주석을 지원합니다.

| 설정 항목 | 기본값 | 설명 |
| :--- | :--- | :--- |
| interval_minutes | 10 | 백그라운드 실시간 쿼터 자동 조회 주기 (분 단위) |
| weekly_reset_day | "Monday" | 주간 초기화 요일 (Monday ~ Sunday) |
| weekly_reset_time| "00:00" | 24시간 형식 주간 초기화 시각 (HH:mm) |
| weekly_multiplier| 30.9 | 5시간 쿼터 대비 주간 쿼터 배율 ($\Delta 5h / \Delta Wk$) |
| sync_enabled | alse | 클라우드 동기화 활성화 여부 (	rue / alse) |
| sync_url | "" | Upstash Redis REST Endpoint URL |
| sync_api_key | "" | Upstash Redis REST Token |
| work_schedule | 월~금 09:00-18:00 | 요일별 출퇴근 시간대 ("HH:mm-HH:mm" 또는 "off") |

---

## 🔨 실행 및 빌드 방법

### 1. 프로그램 실행
- AntigravityTokenMonitor.exe 를 더블클릭하여 실행합니다.
- **트레이 아이콘 더블클릭**: 📊 실시간 현황 대시보드 열기
- **트레이 아이콘 우클릭**: 지금 갱신, 주간 보정, 로그 폴더 열기, 설정 파일 열기, 종료

### 2. 빌드 (컴파일)
- uild.bat 을 실행하면 Windows 기본 내장 C# 컴파일러(csc.exe)를 통해 1초 만에 최적화된 .exe가 생성됩니다. (외부 도구 설치 불필요)

### 3. 윈도우 부팅 시 자동 시작 등록
- **등록**: Install-Startup.bat 실행 (시작프로그램 바로가기 자동 생성)
- **해제**: Uninstall-Startup.bat 실행
