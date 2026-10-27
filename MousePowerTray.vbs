' Mouse Battery Tray - silent launcher
' Double-click this file. It starts the tray app with no console window.
Option Explicit
Dim sh, fso, appDir, ps1, psExe, cmd

Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

appDir = fso.GetParentFolderName(WScript.ScriptFullName)

' support both layouts: <root>\src\MousePowerTray.ps1 and <root>\MousePowerTray.ps1
ps1 = fso.BuildPath(appDir, "src\MousePowerTray.ps1")
If Not fso.FileExists(ps1) Then
    ps1 = fso.BuildPath(appDir, "MousePowerTray.ps1")
End If

If Not fso.FileExists(ps1) Then
    MsgBox "Cannot find MousePowerTray.ps1 next to this launcher." & vbCrLf & vbCrLf & _
           "Please keep the whole folder together.", 16, "Mouse Battery Tray"
    WScript.Quit 1
End If

psExe = sh.ExpandEnvironmentStrings("%SystemRoot%") & _
        "\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = """" & psExe & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass " & _
      "-WindowStyle Hidden -File """ & ps1 & """"

sh.CurrentDirectory = appDir
sh.Run cmd, 0, False
