' AHU campus network hidden launcher (v3).
' Task Scheduler briefly flashes a console window when it starts powershell.exe
' directly. WScript.Shell.Run with window style 0 starts the same engine
' without creating a visible console window.
'
' Host selection (v3, 2026-10-04): PowerShell 7 is REQUIRED here.
'   v2 only probed the MSI path %ProgramFiles%\PowerShell\7\pwsh.exe. On this
'   machine PowerShell 7 is the Microsoft Store build, so that path does not
'   exist, v2 silently fell back to powershell.exe (5.1), and every run since
'   2026-09-13 logged "PowerShell 5.1.26100.9444" (467 hits, zero PS7 hits).
'   v3 resolves the host the way the working Project22 launcher does:
'     1) where.exe pwsh.exe   -> matches Store alias and normal installs
'     2) %ProgramFiles%\PowerShell\7\pwsh.exe (MSI)  -> fallback for old layouts
'     3) powershell.exe       -> only if PowerShell 7 is truly absent
'   Verified on this machine: cscript + this logic resolves
'   C:\Users\Lenovo\AppData\Local\Microsoft\WindowsApps\pwsh.exe and the real
'   process reports edition=Core version=7.6.6.

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

Function ResolveHost()
    Dim probe, line, picked, msiPath
    picked = ""
    ' 1) Let Windows resolve pwsh.exe (covers the Store execution alias).
    On Error Resume Next
    Set probe = shell.Exec("where.exe pwsh.exe")
    If Err.Number = 0 Then
        Do While Not probe.StdOut.AtEndOfStream
            line = Trim(probe.StdOut.ReadLine())
            If Len(line) > 0 Then picked = line
        Loop
    End If
    Err.Clear
    On Error GoTo 0
    If Len(picked) > 0 Then
        ResolveHost = picked
        Exit Function
    End If
    ' 2) Classic MSI install location.
    msiPath = shell.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
    If fso.FileExists(msiPath) Then
        ResolveHost = msiPath
        Exit Function
    End If
    ' 3) Last resort: Windows PowerShell 5.1 (ahu-connect.ps1 stays 5.1-compatible).
    ResolveHost = "powershell.exe"
End Function

hostExe = ResolveHost()

scriptPath = shell.ExpandEnvironmentStrings("%APPDATA%") & "\ahu-network\ahu-connect.ps1"
command = """" & hostExe & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & Quote(scriptPath)

For index = 0 To WScript.Arguments.Count - 1
    command = command & " " & Quote(WScript.Arguments(index))
Next

exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode

Function Quote(value)
    Quote = Chr(34) & Replace(CStr(value), Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
