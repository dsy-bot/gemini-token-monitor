# ⚡ Gemini Token Monitor (제미나이 토큰 사용량 모니터링 프로그램)

> **Windows 10/11 전용 초경량 Gemini API 토큰 잔여량 및 위험도 실시간 모니터링 툴**  
> 별도의 외부 런타임(Python, Node.js 등) 설치 없이 **Windows 기본 PowerShell 5.1 + .NET**으로만 작동하는 **무설치(Zero-Dependency) 백그라운드 트레이 앱**입니다.

---

## 🌟 주요 특징 (Key Features)

1. **무설치(Zero-Dependency) 및 초경량 실행**:
   - Python/Node.js 등 별도 프로그램 설치 불필요
   - 메모리 사용량 **약 15~30MB** 수준으로 부팅 시 백그라운드 스텔스 구동
2. **10분 주기 Gemini API 헬스체크 및 쿼터 잔여량 계산**:
   - 10분 간격으로 Gemini API 통신 핑 및 토큰 소모 속도(Burn Rate) 측정
3. **스마트 업무시간(월~금 09:00 ~ 18:00) 연동 위험도 3단계 동적 아이콘**:
   - 🔴 **빨간색 위험 (Red Risk)**: 현재 소비 속도 유지 시 **금일 업무시간(18시) 종료 전 토큰이 100% 소진**될 위험이 있는 경우
   - 🟡 **노란색 경고 (Yellow Warning)**: 소비 속도 고려 시 **잔여 토큰이 20% 이하**로 떨어질 것으로 예상되는 경우
   - 🟢 **기본 배터리 아이콘 (Normal)**: 업무시간 내 소진 위험 없이 여유로운 상태
4. **경량 텍스트 현황 정보 창**:
   - 트레이 아이콘 클릭/더블클릭 시 남은 토큰, 분당/시간당 소모 속도, 일일 쿼터 리셋 회복 시간 등 직관적 텍스트 제공
5. **시작 프로그램 자동 등록 지원**:
   - 컴퓨터 부팅 시 검은색 명령창(CMD) 없이 스텔스 자동 구동

---

## 📐 스마트 업무시간 위험도 수치 계산 로직

* **업무시간 정의**: 월~금요일 `09:00 ~ 18:00` (12:00~13:00 점심시간 1시간 제외 = 하루 실 업무시간 8시간 = `480분`)
* **남은 실 업무시간 ($T_{rem\_work}$)**: 현재 시각부터 당일 18:00까지의 남은 실 업무시간(분)
* **토큰 완진 소진까지 남은 시간 ($T_{deplete}$)**: $\text{남은 토큰량} \div \text{분당 소모속도}(R_{TPM})$

$$
\begin{cases} 
\text{🔴 빨간색 위험 (Red Risk)} & : T_{deplete} \le T_{rem\_work} \quad \text{(업무시간 마감 전 100% 소진)} \\
\text{🟡 노란색 경고 (Yellow Warning)} & : P_{projected} \le 20\% \quad \text{(업무 마감 시 잔여 쿼터 20% 이하)} \\
\text{🟢 기본 배터리 (Normal)} & : P_{projected} > 20\% \quad \text{(소진 위험 없음)}
\end{cases}
$$

---

## 🚀 사용법 (Getting Started)

### 1. 다운로드 및 파일 구조
원하는 폴더에 스크립트 파일들을 배치합니다.
```
gemini-token-monitor/
├── README.md                # 📖 사용 가이드 문서
├── GeminiTokenMonitor.ps1   # 메인 모니터링 스크립트 (PowerShell + .NET)
├── Launch-Silent.vbs        # 콘솔 창 없는 스텔스 런처
├── Install-AutoStart.ps1    # 시작 프로그램 자동 등록 스크립트
├── Uninstall-AutoStart.ps1  # 시작 프로그램 등록 해제 스크립트
└── config.json              # API Key 및 설정 파일
```

### 2. 시작 프로그램 등록 (부팅 시 자동 실행)
1. `Install-AutoStart.ps1` 파일을 우클릭하여 **[PowerShell로 실행]**을 선택합니다.
2. Windows 시작 프로그램 폴더(`shell:startup`)에 자동으로 스텔스 런처가 등록됩니다.
3. 이제 컴퓨터를 켜면 자동으로 시계 옆 트레이 아이콘으로 구동됩니다.

### 3. API 키 설정 (최초 1회)
1. 프로그램을 처음 실행하면 **API 키 설정 창**이 나타납니다.
2. [Google AI Studio](https://aistudio.google.com/)에서 발급받은 Gemini API Key를 입력하고 **[저장 및 확인]**을 클릭합니다.
3. 설정은 `config.json` 파일에 안전하게 자동 저장됩니다.

---

## 🖥️ 트레이 아이콘 조작 가이드

- **마우스 더블클릭 또는 우클릭 > [📊 현 토큰 상태 보기]**:
  - 현재 Gemini API 연결 상태, 남은 일일/주간 토큰 쿼터, 분당/시간당 소모 속도, 리셋 회복 시간 텍스트 카드를 표시합니다.
- **마우스 우클릭 > [🔄 지금 즉시 갱신]**:
  - 10분 주기를 기다리지 않고 즉시 헬스체크 및 쿼터를 재계산합니다.
- **마우스 우클릭 > [⚙️ API 키 설정]**:
  - API Key를 변경하거나 수정합니다.
- **마우스 우클릭 > [❌ 종료]**:
  - 백그라운드 모니터링 프로그램을 종료합니다.

---

## ⚙️ 설정 파일 (`config.json`)

```json
{
  "apiKey": "YOUR_GEMINI_API_KEY",
  "quotaTier": "Free",
  "dailyQuotaRPD": 1500,
  "minuteQuotaTPM": 1000000,
  "checkIntervalMinutes": 10,
  "workHours": {
    "enabled": true,
    "startHour": 9,
    "endHour": 18,
    "lunchStartHour": 12,
    "lunchEndHour": 13,
    "workDays": [1, 2, 3, 4, 5]
  }
}
```

---

## 🔧 시작 프로그램 해제 및 제거

프로그램 자동 시작을 해제하고 싶을 때는 `Uninstall-AutoStart.ps1`을 우클릭하여 **[PowerShell로 실행]**하면 됩니다.

---

## 📜 License
MIT License - 자유롭게 수정 및 공유하실 수 있습니다.
