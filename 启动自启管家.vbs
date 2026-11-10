' AutoStart Manager launcher - starts the tool without showing a console window
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
appDir = fso.GetParentFolderName(WScript.ScriptFullName)
script = appDir & "\AutoStartManager.ps1"
If Not fso.FileExists(script) Then
    MsgBox "AutoStartManager.ps1 not found next to this launcher.", 16, "AutoStart Manager"
    WScript.Quit 1
End If
sh.CurrentDirectory = appDir
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """", 0, False
