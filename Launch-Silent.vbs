Set WshShell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
psScript = scriptDir & "\GeminiTokenMonitor.ps1"
WshShell.Run "powershell.exe -STA -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File """ & psScript & """", 0, False
