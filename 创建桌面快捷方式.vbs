' Creates a desktop shortcut with a custom icon for this widget.
' Keep this file in the same folder as the launcher and app.ico.
Option Explicit

Dim sh, fso, base, target, ico, name, lnk, sc

Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

base   = fso.GetParentFolderName(WScript.ScriptFullName)
' Launcher file name (built from code points so this script stays pure ASCII)
target = base & "\" & ChrW(21551) & ChrW(21160) & ChrW(24748) & ChrW(28014) & ChrW(32929) & ChrW(20215) & ".vbs"
ico    = base & "\app.ico"

If Not fso.FileExists(target) Then
    MsgBox "Launcher not found:" & vbCrLf & vbCrLf & target & vbCrLf & vbCrLf & _
           "Keep all files of this package in the same folder.", 16, "Floating Quote"
    WScript.Quit 1
End If

' Shortcut name: the same Chinese name as the folder concept "floating stock quote"
name = ChrW(24748) & ChrW(28014) & ChrW(32929) & ChrW(20215)
lnk  = sh.SpecialFolders("Desktop") & "\" & name & ".lnk"

Set sc = sh.CreateShortcut(lnk)
sc.TargetPath       = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\wscript.exe"
sc.Arguments        = """" & target & """"
sc.WorkingDirectory = base
sc.Description      = "Floating stock quote widget"
sc.WindowStyle      = 1
If fso.FileExists(ico) Then sc.IconLocation = ico & ",0"
sc.Save

MsgBox "Desktop shortcut created:" & vbCrLf & vbCrLf & lnk, 64, "Floating Quote"
