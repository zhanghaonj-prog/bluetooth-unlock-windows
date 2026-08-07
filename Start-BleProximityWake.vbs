Option Explicit

Dim shell, fileSystem, scriptRoot, powershellPath, scriptPath, command

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptRoot = fileSystem.GetParentFolderName(WScript.ScriptFullName)
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
scriptPath = fileSystem.BuildPath(scriptRoot, "Start-BleProximityWake.ps1")
command = Quote(powershellPath) & " -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & Quote(scriptPath)
If WScript.Arguments.Count > 0 Then
    command = command & " -ConfigPath " & Quote(WScript.Arguments(0))
End If

shell.Run command, 0, False

Function Quote(value)
    Quote = Chr(34) & value & Chr(34)
End Function
