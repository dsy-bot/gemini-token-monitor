# ⚡ Antigravity Token Monitor v3.0

> **ntigravity-usage quota --json 및 로컬 언어 서버 직결 실시간 쿼터 모니터링 & 주간 배율 자동보정 시스템**
> 무설치 단일 실행 파일(.exe) 형태로 백그라운드 메모리 점유율을 극도로 최소화(< 8MB)하여 동작합니다.

---

## ✨ 핵심 기능

1. **🎯 5시간 실시간 공인 쿼터 직결**:
   - ntigravity-usage quota --json 및 로컬 언어 서버 IPC 연동을 통해 5시간 쿼터 잔여 %와 공식 리셋 시각을 100% 실시간 무결점으로 수신.
2. **📈 5시간 소모 속도 및 초기화 시점 예측 계산**:
   - 최근 5시간 사용량 스트리밍 분석을 통한 '시간당 토큰 소모율(%/h)' 계산.
   - 5시간 공식 리셋 시점 및 주간 초기화 시점 잔여 토큰량 실시간 예측.
3. **🎯 주간/일간 쿼터 배율 자동 조절 (Weekly Multiplier Auto-Calibration)**:
   - 사용자가 공식 웹에서 확인한 주간 %를 입력하면, 동일한 5시간 롤링 윈도우(esetTime) 내의 5h 소모율과 주간 소모율을 비교하여 실제 주간/일간 배율($\text{Multiplier} = \frac{\Delta 5h\%}{\Delta Wk\%}$)을 전자동으로 정밀 산출 및 학습.
4. **🚦 3단계 상태 판별 & 트레이 동적 배지 렌더링**:
   - 🔴 **위험 (빨강 / Danger)**: 리셋 시점 잔여량 $\le 15\%$
   - 🟠 **경고 (주황 / Warning)**: 5h 속도 $\ge 20\%/\text{h}$ 또는 리셋 시점 잔여량 $\le 25\%$
   - 🟢 **정상 (초록 / Normal)**: 안정 상태
   - 트레이 아이콘에 실시간 5시간 잔여 % 숫자가 동적 드로잉됩니다.
5. **📂 카테고리별/일자별 롤링 분리 로깅**:
   - /logs/usage/{YYYYMMDD}_usage.log: 실시간 5h/주간 토큰 잔여량 기록
   - /logs/speed/{YYYYMMDD}_speed.log: 5시간 속도, 리셋 카운트다운, 고갈 예측치 기록
   - /logs/system/{YYYYMMDD}_system.log: 프로그램 오류, 상태 변경, 배율 자동보정 이력 기록

---

## 🚀 실행 및 빌드 방법

1. **실행**:
   - AntigravityTokenMonitor.exe를 더블클릭하여 실행합니다.
2. **빌드 (컴파일)**:
   - uild.bat을 실행하면 Windows 내장 C# 컴파일러를 통해 즉시 단일 .exe가 생성됩니다. (외부 런타임/도구 설치 불필요)
3. **시작프로그램 등록**:
   - Install-Startup.bat 실행 시 윈도우 부팅 시 자동 실행 등록.
   - Uninstall-Startup.bat 실행 시 등록 해제.
