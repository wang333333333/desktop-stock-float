' Floating stock quote launcher (silent start)
Option Explicit
Dim sh, fso, base, script, cmd

Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

base   = fso.GetParentFolderName(WScript.ScriptFullName)
script = base & "\stock_float.ps1"

If Not fso.FileExists(script) Then
    MsgBox "stock_float.ps1 not found in:" & vbCrLf & base, 16, "Floating Quote"
    WScript.Quit
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """"
sh.Run cmd, 0, False
