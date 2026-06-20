' --- CONFIGURATION ---
Dim objFSO, objFile, objShell, strFileName, strComputer
strFileName = "Audit_Serveur.txt"

Set objFSO = CreateObject("Scripting.FileSystemObject")
Set objShell = CreateObject("WScript.Shell")
Set objFile = objFSO.CreateTextFile(strFileName, True)
strComputer = "."

' Connexion WMI
Dim objWMIService
Set objWMIService = GetObject("winmgmts:\\.\root\cimv2")

WScript.Echo "L'audit a commencé. Cela peut prendre quelques minutes (analyse logiciels)..."

' ==========================================
' EN-TETE
' ==========================================
WriteTitle "Audit Ceryne & Abdoulaye"
objFile.WriteLine "Date de l'audit : " & Now
objFile.WriteLine "-----------------------------------"

' ==========================================
' 1. PORTS
' ==========================================
WriteTitle "1. PORTS OUVERTS (LISTENING)"
RunCommandAndLog "netstat -an | find ""LISTENING"""

' ==========================================
' 2. SERVICES
' ==========================================
WriteTitle "2. SERVICES (Auto & Running)"
Dim colServices, objService
Set colServices = objWMIService.ExecQuery("Select Name, DisplayName from Win32_Service Where StartMode = 'Auto' AND State = 'Running'")
For Each objService in colServices
    objFile.WriteLine objService.DisplayName & " (" & objService.Name & ")"
Next

' ==========================================
' 3 & 4. APPLICATIONS DEMARRAGE
' ==========================================
WriteTitle "3 & 4. APPLICATIONS AU DEMARRAGE"
Dim colStartup, objStartup
Set colStartup = objWMIService.ExecQuery("Select * from Win32_StartupCommand")
For Each objStartup in colStartup
    objFile.WriteLine "Nom: " & objStartup.Name & " | Cmd: " & objStartup.Command
Next

' ==========================================
' 5. POLITIQUE DE SECURITE
' ==========================================
WriteTitle "5. POLITIQUE DE SECURITE (Mots de passe)"
RunCommandAndLog "net accounts"

' ==========================================
' 6. JOURNALISATION (SYSTEME)
' ==========================================
WriteTitle "6. JOURNALISATION (Dernieres Erreurs)"
Dim colEvents, objEvent, counter
counter = 0
Set colEvents = objWMIService.ExecQuery("Select * from Win32_NTLogEvent Where Logfile = 'System' AND EventType = 1")
If colEvents.Count = 0 Then
    objFile.WriteLine "Aucune erreur trouvée."
Else
    For Each objEvent in colEvents
        objFile.WriteLine "Date: " & objEvent.TimeGenerated & " | Source: " & objEvent.SourceName
        counter = counter + 1
        If counter >= 10 Then Exit For
    Next
End If

' ==========================================
' 7. CORRECTIFS
' ==========================================
WriteTitle "7. CORRECTIFS D'URGENCE"
Dim colQuickFix, objQuickFix
Set colQuickFix = objWMIService.ExecQuery("Select * from Win32_QuickFixEngineering")
For Each objQuickFix in colQuickFix
    objFile.WriteLine objQuickFix.HotFixID & " (" & objQuickFix.InstalledOn & ")"
Next

' ==========================================
' 8. PARE-FEU
' ==========================================
WriteTitle "8. ETAT DU PARE-FEU"
RunCommandAndLog "netsh advfirewall show allprofiles state"

' ==========================================
' 9. UAC (User Account Control)
' ==========================================
WriteTitle "9. USER ACCOUNT CONTROL (UAC)"
' On utilise une fonction securisee pour lire le registre sans planter si la clé manque
objFile.WriteLine "EnableLUA: " & SafeRegRead("HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\EnableLUA")
objFile.WriteLine "ConsentPromptBehaviorAdmin: " & SafeRegRead("HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\ConsentPromptBehaviorAdmin")
objFile.WriteLine "EnableVirtualization: " & SafeRegRead("HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\EnableVirtualization")

' ==========================================
' 10. DOSSIERS PARTAGES
' ==========================================
WriteTitle "10. DOSSIERS PARTAGES & PERMISSIONS"
Dim objShares, objShare
Set objShares = objWMIService.ExecQuery("Select * from Win32_Share")
For Each objShare in objShares
    objFile.WriteLine "Partage: " & objShare.Name & " | Chemin: " & objShare.Path
    objFile.WriteLine "   Desc: " & objShare.Description
Next

' ==========================================
' 11. INFO OS
' ==========================================
WriteTitle "11. INFORMATIONS SYSTEME"
objFile.WriteLine "OS Version: " & SafeRegRead("HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProductName")
objFile.WriteLine "Build: " & SafeRegRead("HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\CurrentBuild")

Dim colCS, objCS
Set colCS = objWMIService.ExecQuery("Select Name,Domain,Manufacturer,Model from Win32_ComputerSystem")
For Each objCS in colCS
    objFile.WriteLine "Nom: " & objCS.Name
    objFile.WriteLine "Domaine: " & objCS.Domain
    objFile.WriteLine "Modele: " & objCS.Manufacturer & " " & objCS.Model
Next

' ==========================================
' 12. UTILISATEURS & GROUPES LOCAUX
' ==========================================
WriteTitle "12. UTILISATEURS LOCAUX"
Dim objUsers, objUser
Set objUsers = objWMIService.ExecQuery("Select * from Win32_UserAccount where LocalAccount=true")
For Each objUser in objUsers
    objFile.WriteLine "User: " & objUser.Name & " | Désactivé: " & objUser.Disabled
Next

WriteTitle "12 (bis). GROUPES LOCAUX"
Dim objGroups, objGroup
Set objGroups = objWMIService.ExecQuery("Select * from Win32_Group where LocalAccount=true")
For Each objGroup in objGroups
    objFile.WriteLine "Groupe: " & objGroup.Name
Next

' ==========================================
' 13. LOGICIELS INSTALLES
' ==========================================
WriteTitle "13. LOGICIELS INSTALLES (Win32_Product)"
objFile.WriteLine "Recherche en cours... (Cela peut etre long)"
Dim colSoftware, objSoftware
On Error Resume Next
Set colSoftware = objWMIService.ExecQuery("Select Name, Version from Win32_Product")
If Err.Number <> 0 Then
    objFile.WriteLine "Erreur lors de la récupération des logiciels."
Else
    For Each objSoftware in colSoftware
        objFile.WriteLine objSoftware.Name & " (" & objSoftware.Version & ")"
    Next
End If
On Error Goto 0

objFile.Close
MsgBox "Audit terminé !" & vbCrLf & "Fichier : " & strFileName, vbInformation, "Succès"


' ==========================================
' FONCTIONS UTILES
' ==========================================
Sub WriteTitle(text)
    objFile.WriteLine ""
    objFile.WriteLine "=========================================="
    objFile.WriteLine UCase(text)
    objFile.WriteLine "=========================================="
End Sub

Sub RunCommandAndLog(cmd)
    Dim oExec
    On Error Resume Next
    Set oExec = objShell.Exec("cmd /c " & cmd)
    objFile.WriteLine oExec.StdOut.ReadAll
    On Error Goto 0
End Sub

Function SafeRegRead(path)
    On Error Resume Next
    SafeRegRead = objShell.RegRead(path)
    If Err.Number <> 0 Then
        SafeRegRead = "Non trouvé"
        Err.Clear
    End If
    On Error Goto 0
End Function