# Automate the analysis of audit results using PowerShell

# Bypass execution policy for the current process (temporary change)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# Define the path to the audit results file
$path = "C:\Users\han6i\Desktop\audit_results.txt"

# Read the content of the audit results file
Get-Content $path -ReadCount 1

# Process each line of the file
ForEach ($line in Get-Content $path) {
    # Check if the line contains the word "Failed"
    If ($line -match "Failed") {
        # Output the line if it contains "Failed"
        Write-Output $line
    }
}

# Pause the script to allow the user to see the output
Read-Host -Prompt "Press Enter to continue"

# Define categories based on content in audit results
$rules = @{
    Network     = 'LISTENING|PORT|TCP|UDP|Bindings'
    Crypto      = 'TLS|SSL|cipher|certificate|Thumbprint|NotAfter'
    Auth        = 'Anonymous|Authentication|UAC|EnableLUA'
    Firewall    = 'Firewall|Pare-feu|Profile Settings|State'
    Accounts    = 'Utilisateur|Groupes|Administrators|IIS_IUSRS'
    Permissions = 'Permissions|FileSystemRights|FullControl|Everyone'
    IIS         = 'IIS|W3SVC|WAS|Application Pool|Site'
    Logging     = 'Journalisation|Log|Event|Tracing'
}

# Parse and automate
$results = @()

Get-Content $path -ReadCount 1 | ForEach-Object {
    $line = $_

    foreach ($category in $rules.Keys) {
        if ($line -match $rules[$category]) {
            $results += [PSCustomObject]@{
                Category = $category
                Content  = $line
            }
            break
        }
    }
}
# Output categorized results
$results | Format-Table -AutoSize

# Export categorized results to a CSV file
$results | Export-Csv "audit_parsed.csv" -NoTypeInformation -Encoding UTF8
Write-Output "Categorized audit results have been exported to audit_parsed.csv"

# Add severity levels based on keywords
$results = @()

Get-Content $path -ReadCount 1 | ForEach-Object {
    $line = $_
    foreach ($category in $rules.Keys) {
        if ($line -match $rules[$category]) {

            $severity = "Low"
            if ($line -match '0\.0\.0\.0|Anonymous|Expired|OFF|FullControl') {
                $severity = "High"
            }

            $results += [PSCustomObject]@{
                Category = $category
                Severity = $severity
                Content  = $line
            }
            break
        }
    }
}

# Deduplicate results
$results |
    Group-Object Category, Content |
    Sort-Object Count -Descending |
    Select-Object Count, Name

# Sanity check: Output final categorized results with severity
$results | Where-Object { $_.Content -match 'Anonymous|Expired|OFF|LISTENING' }
$results | Format-Table -AutoSize
# Export final categorized results with severity to a CSV file
$results | Export-Csv "audit_parsed_with_severity.csv" -NoTypeInformation -Encoding UTF8
Write-Output "Final categorized audit results with severity have been exported to audit_parsed_with_severity.csv"
