Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)

Sub ConvertFile(filePath)
    If fso.FileExists(filePath) Then
        Set stream = CreateObject("ADODB.Stream")
        stream.Type = 2
        stream.Charset = "utf-8"
        stream.Open
        stream.LoadFromFile filePath
        text = stream.ReadText
        stream.Close

        Set stream2 = CreateObject("ADODB.Stream")
        stream2.Type = 2
        stream2.Charset = "utf-8"
        stream2.Open
        stream2.WriteText text
        stream2.SaveToFile filePath, 2
        stream2.Close
        WScript.Echo "UTF-8 BOM Header Applied: " & filePath
    End If
End Sub

ConvertFile fso.BuildPath(scriptDir, "..\GeminiTokenMonitor.ps1")
ConvertFile fso.BuildPath(scriptDir, "..\modules\GeminiApiPing.ps1")
