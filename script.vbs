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
Dim objShares, objShare, objExec, strCommand, strOutput
Set objShares = objWMIService.ExecQuery("Select * from Win32_Share")
For Each objShare in objShares
    objFile.WriteLine "Partage: " & objShare.Name
    objFile.WriteLine "  Chemin: " & objShare.Path
    objFile.WriteLine "  Description: " & objShare.Description

    ' Get the file permissions for the shared folder using PowerShell
    strCommand = "powershell.exe -Command Get-Acl """ & objShare.Path & """ | Select-Object -ExpandProperty Access"
    Set objExec = objShell.Exec(strCommand)

    strOutput = ""
    Do While Not objExec.StdOut.AtEndOfStream
        strOutput = strOutput & objExec.StdOut.ReadLine() & vbCrLf
    Loop

    If Len(strOutput) > 0 Then
        objFile.WriteLine "  Permissions:"
        objFile.WriteLine strOutput
    End If
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
    objFile.WriteLine "Utilisateur: " & objUser.Name & " | Désactivé: " & objUser.Disabled
Next

WriteTitle "12 (bis). GROUPES LOCAUX"
Dim objGroups, objGroup
Set objGroups = objWMIService.ExecQuery("Select * from Win32_Group where LocalAccount=true")
For Each objGroup in objGroups
    objFile.WriteLine "Groupe: " & objGroup.Name
    objFile.WriteLine "Description: " & objGroup.Description
    objFile.WriteLine "SID: " & objGroup.SID
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

' ==========================================
' 14. IIS CONFIGURATION
' ==========================================
WriteTitle "14. IIS - VERSION & STATUS"
RunCommandAndLog "reg query ""HKLM\SOFTWARE\Microsoft\InetStp"" /v VersionString"
RunCommandAndLog "iisreset /status"

WriteTitle "14A. IIS - SITES WEB"
RunCommandAndLog "powershell.exe -Command ""Import-Module WebAdministration; Get-Website | Select-Object Name, ID, State, PhysicalPath, @{N='Bindings';E={($_.Bindings.Collection | ForEach-Object {$_.protocol + '://' + $_.bindingInformation}) -join ', '}} | Format-List"""

WriteTitle "14B. IIS - APPLICATION POOLS"
RunCommandAndLog "powershell.exe -Command ""Import-Module WebAdministration; Get-IISAppPool | Select-Object Name, State, ManagedRuntimeVersion, ManagedPipelineMode, @{N='Identity';E={$_.ProcessModel.IdentityType}} | Format-List"""

WriteTitle "14C. IIS - CERTIFICATS SSL"
RunCommandAndLog "powershell.exe -Command ""Get-ChildItem Cert:\LocalMachine\My | Where-Object {$_.HasPrivateKey} | Select-Object Subject, Thumbprint, NotAfter, @{N='DaysRemaining';E={($_.NotAfter - (Get-Date)).Days}} | Format-List"""

WriteTitle "14D. IIS - MODULES INSTALLES"
RunCommandAndLog "powershell.exe -Command ""Get-WebGlobalModule | Select-Object Name, Image | Format-Table -AutoSize"""

' ==========================================
' 15. CONNEXIONS RESEAU ACTIVES
' ==========================================
WriteTitle "15. CONNEXIONS ETABLIES"
RunCommandAndLog "netstat -ano | find ""ESTABLISHED"""

' ==========================================
' 16. PROCESSUS EN COURS
' ==========================================
WriteTitle "16. PROCESSUS CRITIQUES"
Dim colProcesses, objProcess
Set colProcesses = objWMIService.ExecQuery("Select Name, ProcessId, ExecutablePath from Win32_Process Where Name='w3wp.exe' OR Name='svchost.exe' OR Name='sqlservr.exe'")
For Each objProcess in colProcesses
    objFile.WriteLine "PID: " & objProcess.ProcessId & " | " & objProcess.Name & " | " & objProcess.ExecutablePath
Next

' ==========================================
' 17. TACHES PLANIFIEES
' ==========================================
WriteTitle "17. TACHES PLANIFIEES"
RunCommandAndLog "schtasks /query /fo LIST /v"

' ==========================================
' 18. MEMBRES GROUPE ADMINISTRATEURS
' ==========================================
WriteTitle "18. MEMBRES GROUPE ADMINISTRATEURS"
RunCommandAndLog "net localgroup Administrateurs"
RunCommandAndLog "net localgroup Administrators"

' ==========================================
' 19. ANTIVIRUS & DEFENDER
' ==========================================
WriteTitle "19A. WINDOWS DEFENDER STATUS"
On Error Resume Next
RunCommandAndLog "powershell.exe -Command ""Get-MpComputerStatus | Select-Object AntivirusEnabled, RealTimeProtectionEnabled, AntivirusSignatureLastUpdated | Format-List"""
On Error Goto 0

WriteTitle "19B. ANTIVIRUS INSTALLES"
On Error Resume Next
Dim avFound
avFound = False

If Not avFound Or Err.Number <> 0 Then
    Err.Clear
    objFile.WriteLine "Vérification via services antivirus courants:"
    
    Dim colAVServices, objAVService
    Set colAVServices = objWMIService.ExecQuery("Select DisplayName, State from Win32_Service Where DisplayName LIKE '%antivirus%' OR DisplayName LIKE '%defender%' OR DisplayName LIKE '%symantec%' OR DisplayName LIKE '%mcafee%' OR DisplayName LIKE '%kaspersky%' OR DisplayName LIKE '%avast%' OR DisplayName LIKE '%avg%'")
    
    If colAVServices.Count > 0 Then
        For Each objAVService in colAVServices
            objFile.WriteLine "  Service: " & objAVService.DisplayName & " - Etat: " & objAVService.State
        Next
    Else
        objFile.WriteLine "  Aucun service antivirus détecté"
    End If
End If

On Error Goto 0

' ==========================================
' 20. ECHECS CONNEXION RECENTS
' ==========================================
WriteTitle "20. ECHECS DE CONNEXION (Security Log)"
RunCommandAndLog "powershell.exe -Command ""Get-EventLog -LogName Security -InstanceId 4625 -Newest 20 | Select-Object TimeGenerated, Message | Format-List"""

' ==========================================
' 21. CONFIGURATION RESEAU
' ==========================================
WriteTitle "21. CONFIGURATION IP"
RunCommandAndLog "ipconfig /all"

' ==========================================
' 22. ESPACE DISQUE
' ==========================================
WriteTitle "22. ESPACE DISQUE"
Dim colDisks, objDisk
Set colDisks = objWMIService.ExecQuery("Select DeviceID, Size, FreeSpace from Win32_LogicalDisk Where DriveType = 3")
For Each objDisk in colDisks
    objFile.WriteLine "Disque: " & objDisk.DeviceID & " | Espace libre: " & Round(objDisk.FreeSpace/1073741824, 2) & " GB / " & Round(objDisk.Size/1073741824, 2) & " GB"
Next

objFile.Close

' ==========================================
' 23. COMPRESSION DU RAPPORT EN CAB
' ==========================================
Dim cabFile, makecabCmd
cabFile = Replace(strFileName, ".txt", ".cab")

makecabCmd = "makecab.exe """ & strFileName & """ """ & cabFile & """"
objShell.Run makecabCmd, 0, True

objFSO.DeleteFile strFileName

MsgBox "Audit terminé !" & vbCrLf & "Fichier TXT: " & strFileName & vbCrLf & "Fichier CAB: " & cabFile, vbInformation, "Succès"


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