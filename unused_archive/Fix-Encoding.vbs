Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psFile = scriptDir & "\GeminiTokenMonitor.ps1"

Set stream = CreateObject("ADODB.Stream")
stream.Type = 2
stream.Charset = "utf-8"
stream.Open
stream.LoadFromFile psFile
text = stream.ReadText
stream.Close

stream.Open
stream.WriteText text
stream.SaveToFile psFile, 2
stream.Close
