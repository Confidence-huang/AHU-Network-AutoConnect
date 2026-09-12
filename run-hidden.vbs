' AHU campus network hidden launcher (v2).
' Task Scheduler briefly flashes a console window when it starts powershell.exe
' directly. WScript.Shell.Run with window style 0 starts the same engine
' without creating a visible console window.
'
' PowerShell 7 is preferred when it was installed with the MSI package.
' The Microsoft Store execution alias under %LOCALAPPDATA%\Microsoft\WindowsApps
' is deliberately not used: it is a 0-byte reparse point that can fail to
' resolve inside scheduled tasks. ahu-connect.ps1 is compatible with 5.1, so
' falling back to powershell.exe is always safe.

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

pwshPath = shell.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
If fso.FileExists(pwshPath) Then
    hostExe = Quote(pwshPath)
Else
    hostExe = "powershell.exe"
End If

scriptPath = shell.ExpandEnvironmentStrings("%APPDATA%") & "\ahu-network\ahu-connect.ps1"
command = hostExe & " -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & Quote(scriptPath)

For index = 0 To WScript.Arguments.Count - 1
    command = command & " " & Quote(WScript.Arguments(index))
Next

exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode

Function Quote(value)
    Quote = Chr(34) & Replace(CStr(value), Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
