Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
targetPath = fso.BuildPath(scriptDir, "..\GeminiTokenMonitor.ps1")
If Not fso.FileExists(targetPath) Then
    targetPath = fso.BuildPath(scriptDir, "GeminiTokenMonitor.ps1")
End If

Set stream = CreateObject("ADODB.Stream")
stream.Type = 2
stream.Charset = "utf-8"
stream.Open
stream.LoadFromFile targetPath
text = stream.ReadText
stream.Close

Set stream2 = CreateObject("ADODB.Stream")
stream2.Type = 2
stream2.Charset = "utf-8"
stream2.Open
stream2.WriteText text
stream2.SaveToFile targetPath, 2
stream2.Close
WScript.Echo "UTF-8 BOM Header Applied Successfully!"
