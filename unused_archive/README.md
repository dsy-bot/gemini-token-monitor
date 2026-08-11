# 📦 Unused / Deprecated Scripts Archive (미사용 보관 폴더)

이 폴더는 과거 버전 개발 과정에서 사용되었으나 현재는 자체 포함 배치 파일(`Install-Startup.bat`, `Launch-Silent.vbs` 등)로 대체되어 더 이상 주 실행 경로에서 직접 사용되지 않는 **유산(Legacy/Deprecated) 스크립트 보관 폴더**입니다.

---

## 📂 보관된 파일 목록 및 설명

* `Install-AutoStart.ps1`: 과거 단독 PowerShell 전용 시작프로그램 등록 스크립트 (현재는 `Install-Startup.bat`로 대체)
* `Uninstall-AutoStart.ps1`: 과거 단독 PowerShell 전용 시작프로그램 등록 해제 스크립트 (현재는 `Uninstall-Startup.bat`로 대체)
* `Fix-Encoding.vbs`: 과거 인코딩 수동 강제 변환 VBScript 모듈 (현재는 `Launch-Silent.vbs` 및 `GeminiTokenMonitor.ps1` 내부로 자체 내장)
