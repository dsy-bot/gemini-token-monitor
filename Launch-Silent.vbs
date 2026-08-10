Set WshShell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)

' PowerShell 5.1 한글 인코딩 호환성을 위한 UTF-8 BOM 자동 변환
Set stream = CreateObject("ADODB.Stream")
stream.Type = 2
stream.Charset = "utf-8"
stream.Open
stream.LoadFromFile scriptDir & "\GeminiTokenMonitor.ps1"
text = stream.ReadText
stream.Close

stream.Open
stream.WriteText text
stream.SaveToFile scriptDir & "\GeminiTokenMonitor.ps1", 2
stream.Close

psScript = scriptDir & "\GeminiTokenMonitor.ps1"
WshShell.Run "powershell.exe -STA -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File """ & psScript & """", 0, False
