# ⚡ Antigravity Token Monitor v3.1

> **ntigravity-usage quota --json 및 로컬 언어 서버 직결 실시간 쿼터 모니터링, 클라우드 Key-Value 동기화 & 주간 배율 자동보정 시스템**
> 무설치 단일 실행 파일(.exe) 형태로 백그라운드 메모리 점유율을 극도로 최소화(< 3MB)하여 동작합니다.

---

## ✨ v3.1 핵심 기능

1. **🎯 5시간 공인 실시간 쿼터 직결**:
   - ntigravity-usage quota --json 및 로컬 언어 서버 IPC 연동을 통해 5시간 쿼터 잔여 %와 공식 리셋 시각을 100% 실시간 무결점으로 수신.
2. **☁️ 초경량 Key-Value 클라우드 동기화 (직장 ↔ 집 PC)**:
   - 무료 Key-Value 스토리지(jsonbin.io, kvdb.io, npoint.io 또는 커스텀 API)와 원시 HttpWebRequest로 통신.
   - 앱 시작 시 최신 주간 상태 자동 Pull, 10분 체크 및 보정 시 자동 Push.
3. **🎯 주간/일간 쿼터 배율 자동 조절 & 수동 직접 수정 (Multiplier 튜닝)**:
   - 동일 5시간 세션 내 소모량 기반 배율($\text{Multiplier} = \frac{\Delta 5h\%}{\Delta Wk\%}$) 자동 학습 지원.
   - 설정 다이얼로그에서 배율 수치를 직접 원하는 값(예: 30.9배)으로 수정 및 즉시 적용 가능.
4. **🌱 새 주간 사이클 리셋 & 첫 토큰 소비 시점 자동 추적**:
   - 주간 리셋 시각 경과 시 100% 자동 리셋 및 이후 첫 토큰 소모 발생 순간(FirstActiveTime)을 자동 감지하여 시스템 로그 및 대시보드에 기록.
5. **⏰ 주간 리셋 시간 간편 맞춤 계산기**:
   - 웹 UI의 남은 시간(예: 2일 5시간 30분)을 입력하면 초기화 요일과 시각을 자동 역산하여 config.json에 저장.
6. **🚀 메모리 3MB 극대화 압축**:
   - Windows 네이티브 EmptyWorkingSet 및 2세대 GC 자동 트림 적용으로 유휴 메모리 점유율 **2.99 MB** 달성.
7. **📂 카테고리별/일자별 롤링 분리 로깅**:
   - /logs/usage/, /logs/speed/, /logs/system/ (UTF-8 인코딩).

---

## 🚀 실행 및 빌드 방법

1. **실행**:
   - AntigravityTokenMonitor.exe를 더블클릭하여 실행합니다.
2. **빌드 (컴파일)**:
   - uild.bat을 실행하면 Windows 내장 C# 컴파일러를 통해 즉시 단일 .exe가 생성됩니다. (외부 런타임/도구 설치 불필요)
3. **시작프로그램 등록**:
   - Install-Startup.bat 실행 시 윈도우 부팅 시 자동 실행 등록.
   - Uninstall-Startup.bat 실행 시 등록 해제.
