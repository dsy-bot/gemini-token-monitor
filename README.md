# ⚡ Gemini Token Monitor (제미나이 토큰 사용량 및 위험도 모니터링)

> **Windows 10/11 전용 초경량 Gemini API 실트래픽 토큰 모니터링 툴**  
> 별도의 외부 런타임(Python, Node.js 등) 설치 없이 **Windows 기본 PowerShell 5.1 + .NET**으로 구동되며, 컴퓨터 부팅 시 백그라운드로 스텔스 자동 구동됩니다.

---

## 🌟 주요 특징 (Key Features)

1. **로컬 Gemini 실트래픽 로그 스캔 엔진 (Local Log Traffic Scanner)**:
   - 개발 도구, 코딩 에이전트(Antigravity), Gemini CLI 등이 로컬(`C:\Users\ms000\.gemini\...`)에 남긴 세션 기록을 실시간 추적하여 **진짜 실사용 토큰 수량**과 **진짜 분당/시간당 소모 속도(TPM/TPH)**를 100% 정확하게 연동합니다.
   - **인터넷 API를 추가로 호출하지 않으므로 API 토큰 소모량이 0개이며, CPU/RAM 리소스 사용량이 극소량(~15MB)**입니다.

2. **스마트 업무시간(월~금 09:00 ~ 18:00) 연동 위험도 3단계 동적 트레이 아이콘**:
   - 🔴 **빨간색 위험 (RED)**: 현재 소비 속도 유지 시 **오늘 18시 업무 종료 전 토큰 100% 전량 소진**이 예상되는 경우
   - 🟡 **노란색 경고 (YELLOW)**: 현재 소비 속도 고려 시 **잔여 토큰이 20% 이하**로 떨어질 우려가 있는 경우
   - 🟢 **기본 배터리/배지 아이콘 (GREEN)**: 업무시간 내 소진 위험 없이 여유로운 상태

3. **크고 또렷한 수치(%) 오버레이 직사각형 트레이 배지**:
   - 작업 표시줄 트레이 아이콘에 잔여 토큰 퍼센트(`85`, `98` 등) 수치가 **대형 굵은 폰트(Segoe UI 10pt Bold)**로 잘림 없이 직관적으로 표시됩니다.

4. **깔끔한 단일행 한글 UI 현황 대시보드 (View Status)**:
   - 어색한 줄바꿈 없는 단일행 레이아웃과 수직 스크롤바(`Vertical ScrollBar`) 및 마우스 휠 스크롤 지원

5. **독립된 모듈화 구조 (`modules/GeminiApiPing.ps1`)**:
   - 추후 원격 REST API 핑 및 토큰 직접 측정이 필요할 때 재사용할 수 있는 독립 모듈이 별도 분리되어 있습니다.

---

## 🛠️ 프로젝트 파일 구조 (Project Architecture)

```
gemini-token-monitor/
├── README.md                # 📖 모니터링 프로그램 가이드 문서
├── GeminiTokenMonitor.ps1   # 메인 모니터링 엔진 (로컬 로그 스캔 & 트레이 GUI)
├── Launch-Silent.vbs        # 콘솔 창 없는 스텔스 백그라운드 런처
├── Install-Startup.bat      # 1클릭 시작 프로그램 자동 등록 배치 파일
├── Uninstall-Startup.bat    # 1클릭 시작 프로그램 등록 해제 배치 파일
├── Run-Test.bat             # 디버그 테스트 실행 배치 파일
├── config.json              # API Key 및 토큰 쿼터 한도 설정 파일
├── modules/
│   └── GeminiApiPing.ps1    # 🧩 추후 재사용 가능한 독립 Gemini REST API 핑 모듈
└── unused_archive/          # 📦 구 버전 보관용 레거시 스크립트 폴더
    ├── README.md
    ├── Install-AutoStart.ps1
    ├── Uninstall-AutoStart.ps1
    └── Fix-Encoding.vbs
```

---

## 🚀 사용법 (Getting Started)

### 1. 부팅 시 자동 실행 등록 (1클릭)
1. [`Install-Startup.bat`](file:///C:/Users/ms000/.gemini/antigravity/scratch/gemini-token-monitor/Install-Startup.bat) 파일을 더블클릭합니다.
2. Windows 시작 프로그램 폴더(`shell:startup`)에 스텔스 런처가 자동 등록됩니다.

### 2. 시작 프로그램 해제
1. [`Uninstall-Startup.bat`](file:///C:/Users/ms000/.gemini/antigravity/scratch/gemini-token-monitor/Uninstall-Startup.bat) 파일을 더블클릭하면 즉시 등록 해제됩니다.

---

## ⚙️ 설정 (`config.json`)

```json
{
  "apiKey": "YOUR_GEMINI_API_KEY",
  "dailyQuotaRPD": 1500,
  "dailyQuotaTokens": 1000000,
  "checkIntervalMinutes": 10,
  "workHours": {
    "startHour": 9,
    "endHour": 18,
    "lunchStartHour": 12,
    "lunchEndHour": 13,
    "workDays": [1, 2, 3, 4, 5]
  }
}
```

---

## 📜 License
MIT License - 자유롭게 수정 및 공유하실 수 있습니다.
