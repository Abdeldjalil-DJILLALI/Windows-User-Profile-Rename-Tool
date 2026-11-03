#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Renames users found in C:\Users (folder + ProfileList registry value, and
    the local account when there is one), driven by a CSV: OldName,NewName.

.DESCRIPTION 
    Script edting by Abdeldjalil djillali
    1. Read and validate the CSV.
    2. Inventory all profiles (Win32_UserProfile + ProfileList registry) and
       search C:\Users for folders matching each OldName.
    3. Build a plan per user:
         Local       -> folder + account + registry
         Domain      -> folder + registry (account name stays in AD)
         Folder only -> folder has no account and no registry entry
    4. DRY RUN (default, or -WhatIfMode): print the plan and stop.
    5. APPLY: back up the registry, warn and sign out ALL matched users,
       wait until their profiles are unloaded, then rename each user
       (folder -> account -> registry), verify, and roll back on failure.

.EXAMPLE
    .\Rename-UserProfiles-Final.ps1
    Dry run only.

.EXAMPLE
    .\Rename-UserProfiles-Final.ps1 -Apply -Force -WarningSeconds 60
#>

[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath = "C:\Admin\rename-users.csv",

    [string]$LogPath = (Join-Path "C:\Admin\Logs" ("ProfileRename-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))),

    [switch]$Apply,        # make real changes
    [switch]$WhatIfMode,   # force a dry run even if -Apply is given
    [switch]$SkipMissing,  # ignore CSV users that are not found
    [switch]$Force,        # do not ask for YES
    [switch]$StopOnError,  # stop at the first failed user (default: continue with the next one)
    [switch]$Pause,        # wait for Enter at the end (use it if the window closes by itself)

    [ValidateRange(0,600)][int]$WarningSeconds = 30,
    [ValidateRange(1,10)][int]$RenameRetries = 5
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$DryRun    = (-not $Apply) -or $WhatIfMode
$script:AccountCache = @{}
$Stamp     = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupDir = "C:\Admin\ProfileRenameBackup"

$BaseKey   = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
$RegKey    = "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
$UsersRoot = [IO.Path]::GetFullPath((Join-Path $env:SystemDrive "Users")).TrimEnd('\')

$ReservedNames = @('Administrator','Guest','DefaultAccount','WDAGUtilityAccount',
                   'Public','Default','Default User','All Users','system')

New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO")

    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8

    switch ($Level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

# Runs a native command without stderr becoming a terminating error (PS 5.1).
function Invoke-Native {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @())

    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out  = & $FilePath @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }

    [PSCustomObject]@{ ExitCode = $code; Output = @($out) }
}

function Invoke-WithRetry {
    param([scriptblock]$Action, [string]$What, [int]$Retries = 3)

    for ($i = 1; $i -le $Retries; $i++) {
        try { & $Action; return }
        catch {
            if ($i -eq $Retries) { throw }
            Write-Log "$What failed (attempt $i/$Retries): $($_.Exception.Message). Retrying." "WARN"
            Start-Sleep -Seconds (2 * $i)
        }
    }
}

function Get-AccountFromSid {
    param([string]$Sid)

    if ($script:AccountCache.ContainsKey($Sid)) { return $script:AccountCache[$Sid] }

    $name = $null
    try {
        $name = (New-Object Security.Principal.SecurityIdentifier $Sid).Translate(
            [Security.Principal.NTAccount]).Value
    }
    catch { }

    $script:AccountCache[$Sid] = $name
    return $name
}

# ---------------------------------------------------------------------------
# Profile inventory (Win32_UserProfile + ProfileList registry)
# ---------------------------------------------------------------------------
function Get-ProfileInventory {
    $rootPrefix = $UsersRoot + '\'

    foreach ($p in @(Get-CimInstance Win32_UserProfile)) {
        if (-not $p.SID -or -not $p.LocalPath) { continue }

        $full = [IO.Path]::GetFullPath([string]$p.LocalPath).TrimEnd('\')
        if (-not ($full + '\').StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }

        $key = Join-Path $BaseKey $p.SID
        if (-not (Test-Path -LiteralPath $key)) { continue }

        $regRaw = [string](Get-ItemProperty -LiteralPath $key).ProfileImagePath
        if (-not $regRaw) { continue }
        $regPath = [IO.Path]::GetFullPath(
            [Environment]::ExpandEnvironmentVariables($regRaw)).TrimEnd('\')

        [PSCustomObject]@{
            SID          = [string]$p.SID
            LocalPath    = $full
            RegistryPath = $regPath
            RegistryKey  = $key
            Loaded       = [bool]$p.Loaded
            Special      = [bool]$p.Special
        }
    }
}

# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------
function Get-UserSessions {
    param([Parameter(Mandatory)][string]$Username)

    $r = Invoke-Native -FilePath "$env:SystemRoot\System32\quser.exe"
    $found = @()

    # quser exits with 1 when nobody is signed in; that is not an error here.
    # The profile-loaded check later is the real safety net.
    foreach ($text in @($r.Output | Select-Object -Skip 1)) {
        # Session name is missing for disconnected sessions.
        if ($text -match '^\s*>?\s*(?<user>\S+)\s+(?:(?<session>\S+)\s+)?(?<id>\d+)\s+(?<state>\S+)') {
            if ((($Matches['user'] -split '\\')[-1]) -ieq $Username) {
                $found += [PSCustomObject]@{
                    SessionId = [int]$Matches['id']
                    State     = $Matches['state']
                }
            }
        }
    }
    return $found
}

function Get-UserProcesses {
    param([string]$Username)
    try {
        @(Get-Process -IncludeUserName -ErrorAction Stop |
            Where-Object { $_.UserName -and (($_.UserName -split '\\')[-1] -ieq $Username) })
    }
    catch { @() }
}

function Test-ProfileUnloaded {
    param([string]$Username, [string]$Sid)

    if (@(Get-UserSessions -Username $Username).Count -gt 0) { return $false }

    $cim = Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $Sid }
    if ($cim -and $cim.Loaded) { return $false }

    if (Test-Path -LiteralPath "Registry::HKEY_USERS\$Sid") { return $false }
    return $true
}

# Warn everyone once, sign all of them out, then wait until each profile is
# unloaded (forcing sign-out and killing leftover processes after 30 s).
function Stop-AllTargetSessions {
    param([Parameter(Mandatory)]$Plans, [int]$Seconds)

    $targets  = @($Plans | Where-Object { $_.SID })
    $open     = @()
    $notReady = @()

    foreach ($p in $targets) {
        foreach ($s in @(Get-UserSessions -Username $p.SessionUser)) {
            Write-Log "Open session $($s.SessionId) ($($s.State)) for $($p.SessionUser)."
            $open += [PSCustomObject]@{ User = $p.SessionUser; SessionId = $s.SessionId }
        }
    }

    if ($open.Count -eq 0) {
        Write-Log "No open sessions for the users to rename."
    }
    else {
        if ($Seconds -gt 0) {
            $text = "Profile maintenance: save your work now. You will be FORCE logged off in $Seconds seconds."

            foreach ($o in $open) {
                $m = Invoke-Native -FilePath "$env:SystemRoot\System32\msg.exe" `
                    -Arguments @("$($o.SessionId)", "/time:$Seconds", $text)
                if ($m.ExitCode -ne 0) {
                    Write-Log "Could not notify session $($o.SessionId): $($m.Output -join ' ')" "WARN"
                }
            }

            Write-Log "Waiting $Seconds seconds for users to save their work."
            Start-Sleep -Seconds $Seconds
        }

        foreach ($o in $open) {
            $still = @(Get-UserSessions -Username $o.User | Where-Object { $_.SessionId -eq $o.SessionId })
            if ($still.Count -gt 0) {
                Write-Log "Signing out $($o.User) (session $($o.SessionId))." "WARN"
                $l = Invoke-Native -FilePath "$env:SystemRoot\System32\logoff.exe" `
                    -Arguments @("$($o.SessionId)")
                if ($l.ExitCode -ne 0) {
                    Write-Log "logoff failed for session $($o.SessionId): $($l.Output -join ' '). Will escalate." "WARN"
                }
            }
        }
    }

    foreach ($p in $targets) {
        $deadline   = (Get-Date).AddMinutes(2)
        $escalateAt = (Get-Date).AddSeconds(30)
        $escalated  = $false

        while (-not (Test-ProfileUnloaded -Username $p.SessionUser -Sid $p.SID)) {
            if ((Get-Date) -gt $deadline) {
                $procs = @(Get-UserProcesses -Username $p.SessionUser |
                    Select-Object -ExpandProperty ProcessName -Unique) -join ', '
                Write-Log "Profile of $($p.OldName) is still loaded or a session remains. Processes: $procs. This user will be SKIPPED." "ERROR"
                $notReady += $p.OldName
                break
            }

            if (-not $escalated -and (Get-Date) -gt $escalateAt) {
                $escalated = $true
                Write-Log "Profile of $($p.OldName) still loaded after 30s. Forcing sign-out and stopping its processes." "WARN"

                foreach ($s in @(Get-UserSessions -Username $p.SessionUser)) {
                    Invoke-Native -FilePath "$env:SystemRoot\System32\logoff.exe" `
                        -Arguments @("$($s.SessionId)") | Out-Null
                }

                foreach ($proc in @(Get-UserProcesses -Username $p.SessionUser)) {
                    try {
                        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                        Write-Log "Stopped process $($proc.ProcessName) (PID $($proc.Id))." "WARN"
                    }
                    catch {
                        Write-Log "Could not stop $($proc.ProcessName): $($_.Exception.Message)" "WARN"
                    }
                }
            }
            Start-Sleep -Seconds 3
        }

        if ($notReady -contains $p.OldName) { continue }
        Write-Log "Profile unloaded for $($p.OldName)."
    }

    return @($notReady)
}

# ---------------------------------------------------------------------------
# Plan and rollback
# ---------------------------------------------------------------------------
# Returns $null when nothing is found for OldName; throws on any problem.
function Get-ProfilePlan {
    param(
        [Parameter(Mandatory)][string]$OldName,
        [Parameter(Mandatory)][string]$NewName,
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)]$Folders
    )

    $account = Get-LocalUser -Name $OldName -ErrorAction SilentlyContinue
    $isLocal = [bool]$account
    $prof    = $null

    # Find the registered profile: by local account SID first, then by folder name.
    if ($isLocal) {
        $prof = @($Inventory | Where-Object { $_.SID -eq $account.SID.Value }) | Select-Object -First 1
    }

    if (-not $prof) {
        $byFolder = @($Inventory | Where-Object { (Split-Path $_.LocalPath -Leaf) -ieq $OldName })
        if ($byFolder.Count -gt 1) {
            throw "More than one registered profile points to a folder named '$OldName': $(($byFolder | ForEach-Object { $_.SID }) -join ', ')"
        }
        $prof = $byFolder | Select-Object -First 1
    }

    # The folder name can differ from the account name (for example
    # S250021.DOMAIN). With no exact folder, find the profile through the
    # account name its SID resolves to.
    $exactFolder = $Folders | Where-Object { $_.Name -ieq $OldName } | Select-Object -First 1

    if (-not $prof -and -not $exactFolder) {
        $byAccount = @($Inventory | Where-Object {
            $acc = Get-AccountFromSid -Sid $_.SID
            $acc -and (($acc -split '\\')[-1] -ieq $OldName)
        })

        if ($byAccount.Count -gt 1) {
            throw "More than one profile belongs to an account named '$OldName': $(($byAccount | ForEach-Object { $_.LocalPath }) -join ', ')"
        }

        if ($byAccount.Count -eq 1) {
            $prof = $byAccount[0]
            Write-Log "Found '$OldName' through its account name: $($prof.LocalPath)" "WARN"
        }
    }

    $folder = $Folders | Where-Object { $_.Name -ieq $OldName } | Select-Object -First 1

    if (-not $prof -and -not $folder) { return $null }

    if ($isLocal -and $prof -and $prof.SID -ne $account.SID.Value) {
        throw "Folder '$OldName' is registered to a different SID ($($prof.SID)) than the local account ($($account.SID.Value))."
    }

    $sid         = $null
    $key         = $null
    $oldPath     = $null
    $sessionUser = $null
    $resolved    = $null

    if ($prof) {
        $sid     = $prof.SID
        $key     = $prof.RegistryKey
        $oldPath = $prof.LocalPath

        if ($prof.Special)               { throw "Special/system profile, refusing: $OldName" }
        if ($sid -notmatch '^S-1-5-21-') { throw "Nonstandard SID, refusing: $OldName ($sid)" }
        if ([uint64]($sid.Split('-')[-1]) -lt 1000) { throw "Built-in account, refusing: $OldName ($sid)" }

        if ($sid -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
            throw "Cannot rename the account running this script: $OldName"
        }

        if (-not $prof.LocalPath.Equals($prof.RegistryPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Profile path mismatch for $OldName. CIM='$($prof.LocalPath)'; registry='$($prof.RegistryPath)'."
        }

        $resolved    = Get-AccountFromSid -Sid $sid
        $sessionUser = if ($isLocal) { $account.Name }
                       elseif ($resolved) { ($resolved -split '\\')[-1] }
                       else { $OldName }

        # A loaded profile of a different account with the same name makes
        # the session match ambiguous. Stop instead of guessing.
        foreach ($other in @($Inventory | Where-Object { $_.SID -ne $sid -and $_.Loaded })) {
            $otherAcc = Get-AccountFromSid -Sid $other.SID
            if ($otherAcc -and (($otherAcc -split '\\')[-1] -ieq $sessionUser)) {
                throw "Another loaded profile ($otherAcc) has the same account name as '$sessionUser'. Resolve session identity manually."
            }
        }

        $leaf = Split-Path $oldPath -Leaf
        if ($leaf -ine $OldName) {
            Write-Log "Folder name '$leaf' differs from account name '$OldName'. The folder will still be renamed to '$NewName'." "WARN"
        }
    }
    else {
        if ($isLocal) {
            throw "Local account '$OldName' has no registered profile, but a folder with that name exists. Not safe to rename."
        }

        $oldPath = $folder.FullName.TrimEnd('\')
        Write-Log "'$OldName' has a folder but no account and no ProfileList entry: FOLDER-ONLY rename." "WARN"
    }

    # Account checks
    if ($isLocal) {
        if ("$($account.PrincipalSource)" -eq "MicrosoftAccount") {
            throw "$OldName is linked to a Microsoft account; renaming is not supported."
        }
        if (Get-LocalUser -Name $NewName -ErrorAction SilentlyContinue) {
            throw "Destination account already exists: $NewName"
        }
        if (Get-LocalGroup -Name $NewName -ErrorAction SilentlyContinue) {
            throw "Destination name is already used by a local group: $NewName"
        }
    }
    elseif ($sid) {
        Write-Log "'$OldName' is a DOMAIN user: only folder and registry are renamed here (SID $sid)."

        if ($resolved -and (($resolved -split '\\')[-1] -ieq $NewName)) {
            Write-Log "The domain already uses the new name '$NewName' for this SID."
        }
        else {
            Write-Log "Rename the account in Active Directory to '$NewName' too, or the user will sign in with the old name." "WARN"
        }
    }

    # Path checks
    if (([IO.Path]::GetDirectoryName($oldPath)).TrimEnd('\') -ine $UsersRoot) {
        throw "Profile is not a direct child of ${UsersRoot}: $oldPath"
    }
    if (-not (Test-Path -LiteralPath $oldPath -PathType Container)) {
        throw "Profile folder not found: $oldPath"
    }

    $newPath = Join-Path $UsersRoot $NewName
    if (Test-Path -LiteralPath $newPath) {
        throw "Destination folder already exists: $newPath"
    }

    [PSCustomObject]@{
        OldName     = $OldName
        NewName     = $NewName
        SID         = $sid
        SessionUser = $sessionUser
        OldPath     = $oldPath
        NewPath     = $newPath
        Key         = $key
        IsLocal     = $isLocal
        IsOrphan    = (-not $sid)
    }
}

function Restore-Plan {
    param([Parameter(Mandatory)]$Plan)

    $oldExists = Test-Path -LiteralPath $Plan.OldPath
    $newExists = Test-Path -LiteralPath $Plan.NewPath

    if ($oldExists -and $newExists) {
        throw "Both profile folders exist; refusing automatic folder rollback."
    }

    if ($newExists -and -not $oldExists) {
        Invoke-WithRetry -What "Folder rollback" -Retries $RenameRetries -Action {
            Rename-Item -LiteralPath $Plan.NewPath -NewName (Split-Path $Plan.OldPath -Leaf)
        }
    }

    if ($Plan.Key -and (Test-Path -LiteralPath $Plan.Key)) {
        Set-ItemProperty -LiteralPath $Plan.Key -Name ProfileImagePath -Value $Plan.OldPath -Type ExpandString
    }

    if ($Plan.IsLocal) {
        $acc = Get-LocalUser | Where-Object { $_.SID.Value -eq $Plan.SID } | Select-Object -First 1
        if ($acc -and $acc.Name -ne $Plan.OldName) {
            Rename-LocalUser -Name $acc.Name -NewName $Plan.OldName
        }
    }

    Write-Log "Best-effort recovery completed for $($Plan.OldName)." "WARN"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Invoke-Migration {
    Write-Log "========== Migration started: $(if ($DryRun) {'DRY RUN'} else {'APPLY'}) =========="
    Write-Log "Host: $env:COMPUTERNAME  Operator: $env:USERDOMAIN\$env:USERNAME"

    # 1. CSV
    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
        throw "CSV file not found: $CsvPath"
    }

    # Excel in some regions saves with ';' instead of ','.
    $delimiter = ','
    $header = Get-Content -LiteralPath $CsvPath -TotalCount 1
    if ($header -match ';' -and $header -notmatch ',') { $delimiter = ';' }

    $rows = @(Import-Csv -LiteralPath $CsvPath -Delimiter $delimiter)

    if ($rows.Count -eq 0 -or
        -not ($rows[0].PSObject.Properties.Name -contains "OldName") -or
        -not ($rows[0].PSObject.Properties.Name -contains "NewName")) {
        throw "CSV must contain OldName and NewName columns."
    }

    $oldNames = @($rows | ForEach-Object { ([string]$_.OldName).Trim() })
    $newNames = @($rows | ForEach-Object { ([string]$_.NewName).Trim() })

    foreach ($n in $oldNames) {
        if ([string]::IsNullOrWhiteSpace($n) -or $n -notmatch '^[a-zA-Z0-9_. -]+$') {
            throw "Invalid or empty OldName in CSV: '$n'"
        }
        if ($ReservedNames -contains $n) { throw "Reserved or built-in name not allowed: '$n'" }
    }

    foreach ($n in $newNames) {
        if ([string]::IsNullOrWhiteSpace($n) -or $n -notmatch '^[a-zA-Z0-9_.-]+$') {
            throw "Invalid or empty NewName in CSV: '$n'"
        }
        if ($n.Length -gt 20) { throw "NewName longer than 20 characters: '$n'" }
        if ($n.EndsWith('.')) { throw "NewName cannot end with a dot: '$n'" }
        if ($ReservedNames -contains $n) { throw "Reserved or built-in name not allowed: '$n'" }
    }

    if (@($oldNames | Sort-Object -Unique).Count -ne $rows.Count) { throw "Duplicate OldName values in CSV." }
    if (@($newNames | Sort-Object -Unique).Count -ne $rows.Count) { throw "Duplicate NewName values in CSV." }

    # 2. Inventory and search C:\Users
    $inventory = @(Get-ProfileInventory)
    $folders   = @(Get-ChildItem -LiteralPath $UsersRoot -Directory -Force)

    Write-Log "Inventory: $($inventory.Count) registered profiles, $($folders.Count) folders in $UsersRoot."

    $plans   = @()
    $missing = @()

    for ($i = 0; $i -lt $rows.Count; $i++) {
        $old = $oldNames[$i]
        $new = $newNames[$i]

        if ($old -ieq $new)           { throw "OldName and NewName are identical: $old" }
        if ($oldNames -contains $new) { throw "Destination '$new' is also a source name. Use a separate migration plan." }

        # 3. Plan
        $plan = Get-ProfilePlan -OldName $old -NewName $new -Inventory $inventory -Folders $folders

        if (-not $plan) {
            Write-Log "NOT FOUND in ${UsersRoot}: '$old'" "WARN"
            if ($missing.Count -eq 0) {
                Write-Log "Folders currently in ${UsersRoot}: $(($folders | ForEach-Object { $_.Name }) -join ', ')" "WARN"
            }
            $missing += $old
            continue
        }

        $sessionText = "no open session"
        if ($plan.SessionUser) {
            $open = @(Get-UserSessions -Username $plan.SessionUser)
            if ($open.Count -gt 0) {
                $sessionText = "SESSION OPEN (ID: $(($open | ForEach-Object { $_.SessionId }) -join ','))"
            }
        }

        Write-Log "MATCH: '$old' -> '$new' ($($plan.OldPath)) [$sessionText]"
        $plans += $plan
    }

    if ($missing.Count -gt 0) {
        if ($SkipMissing) {
            Write-Log "Skipping users not found: $($missing -join ', ')" "WARN"
        }
        else {
            throw "These CSV users were not found in ${UsersRoot}: $($missing -join ', '). Use -SkipMissing to ignore them."
        }
    }

    if ($plans.Count -eq 0) {
        throw "No user in $UsersRoot matches any OldName in the CSV."
    }

    Write-Log "Preflight passed for $($plans.Count) user(s)."

    ($plans |
        Format-Table OldName, NewName,
            @{n='Type';e={ if ($_.IsOrphan) {'Folder only'} elseif ($_.IsLocal) {'Local'} else {'Domain'} }},
            SID, OldPath, NewPath -AutoSize |
        Out-String -Width 250) -split "`r?`n" |
        Where-Object { $_.Trim() } |
        ForEach-Object { Write-Log $_ }

    # 4. Dry run stops here
    if ($DryRun) {
        Write-Log "DRY RUN ONLY - NOTHING WAS CHANGED. Run again with -Apply to rename the folders." "WARN"
        return
    }

    if (-not $Force) {
        $answer = Read-Host "Type YES to sign out and rename $($plans.Count) user(s)"
        if ($answer -cne "YES") {
            Write-Log "Cancelled by operator. No changes made." "WARN"
            return
        }
    }

    # 5. Registry backup (whole ProfileList tree)
    $backupFile = Join-Path $BackupDir "ProfileList-$Stamp.reg"
    $export = Invoke-Native -FilePath "$env:SystemRoot\System32\reg.exe" `
        -Arguments @("export", $RegKey, $backupFile, "/y")

    if ($export.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $backupFile)) {
        throw "Registry backup failed; migration cancelled. $($export.Output -join ' ')"
    }
    Write-Log "Registry backup: $backupFile"

    # 6. Warn and sign out all matched users, wait for profiles to unload
    $notReady = @(Stop-AllTargetSessions -Plans $plans -Seconds $WarningSeconds)

    # 7. Rename each user: folder -> account -> registry
    $done    = 0
    $failed  = 0
    $results = @()

    foreach ($plan in $plans) {
        if ($notReady -contains $plan.OldName) {
            $failed++
            $results += [PSCustomObject]@{ User = $plan.OldName; NewName = $plan.NewName; Result = 'SKIPPED'; Detail = 'profile still loaded, user could not be signed out' }
            continue
        }

        Write-Log "Starting $($plan.OldName) -> $($plan.NewName)"

        try {
            # Recheck everything right before changing it.
            if (($plan.IsLocal -and (Get-LocalUser -Name $plan.NewName -ErrorAction SilentlyContinue)) -or
                (Test-Path -LiteralPath $plan.NewPath)) {
                throw "Destination became occupied: $($plan.NewName)"
            }

            if ($plan.Key) {
                if (-not (Test-Path -LiteralPath $plan.Key)) { throw "ProfileList key disappeared: $($plan.Key)" }

                $freshPath = [Environment]::ExpandEnvironmentVariables(
                    [string](Get-ItemProperty -LiteralPath $plan.Key).ProfileImagePath).TrimEnd('\')
                if ($freshPath -ine $plan.OldPath) {
                    throw "ProfileImagePath changed during processing: $freshPath"
                }

                # Per-user registry backup, easy to import if needed.
                $userBackupName = ("$($plan.SID)_$Stamp" -replace '[^\w.-]', '_') + ".reg"
                $userBackup     = Join-Path $BackupDir $userBackupName
                $ex = Invoke-Native -FilePath "$env:SystemRoot\System32\reg.exe" `
                    -Arguments @("export", "$RegKey\$($plan.SID)", $userBackup, "/y")
                if ($ex.ExitCode -ne 0) { throw "Could not back up the registry key for $($plan.SID)." }
            }

            Invoke-WithRetry -What "Folder rename" -Retries $RenameRetries -Action {
                Rename-Item -LiteralPath $plan.OldPath -NewName (Split-Path $plan.NewPath -Leaf)
            }
            Write-Log "Folder renamed: $($plan.OldPath) -> $($plan.NewPath)"

            if ($plan.IsLocal) {
                Rename-LocalUser -Name $plan.OldName -NewName $plan.NewName
                Write-Log "Account renamed: $($plan.OldName) -> $($plan.NewName)"
            }

            if ($plan.Key) {
                Set-ItemProperty -LiteralPath $plan.Key -Name ProfileImagePath -Value $plan.NewPath -Type ExpandString
                Write-Log "ProfileList updated: $($plan.Key)"
            }

            # Verify
            if (-not (Test-Path -LiteralPath $plan.NewPath -PathType Container)) {
                throw "New profile directory verification failed."
            }

            if ($plan.IsLocal) {
                $acc = Get-LocalUser | Where-Object { $_.SID.Value -eq $plan.SID } | Select-Object -First 1
                if (-not $acc -or $acc.Name -ne $plan.NewName) { throw "Account name verification failed." }
            }

            if ($plan.Key) {
                $reg = ([string](Get-ItemProperty -LiteralPath $plan.Key).ProfileImagePath).TrimEnd('\')
                if (-not $reg.Equals($plan.NewPath, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "ProfileImagePath verification failed."
                }

                $cim = Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $plan.SID }
                if ($cim -and -not ([string]$cim.LocalPath).TrimEnd('\').Equals($plan.NewPath, [StringComparison]::OrdinalIgnoreCase)) {
                    Write-Log "Windows profile inventory does not show the new path yet (LocalPath='$($cim.LocalPath)'). Restart and check." "WARN"
                }
            }

            $done++
            $results += [PSCustomObject]@{ User = $plan.OldName; NewName = $plan.NewName; Result = 'SUCCESS'; Detail = '' }
            Write-Log "SUCCESS: $($plan.OldName) -> $($plan.NewName)"
        }
        catch {
            $err = $_
            Write-Log "FAILED: $($err.Exception.Message)" "ERROR"
            Write-Log "Where: $($err.InvocationInfo.PositionMessage -replace '\s+', ' ')" "ERROR"

            try { Restore-Plan -Plan $plan }
            catch {
                Write-Log "RECOVERY FAILED: $($_.Exception.Message)" "ERROR"
                Write-Log "Manual recovery required. Registry backup: $backupFile" "ERROR"
            }

            $failed++
            $results += [PSCustomObject]@{ User = $plan.OldName; NewName = $plan.NewName; Result = 'FAILED'; Detail = $err.Exception.Message }

            if ($StopOnError) {
                throw "Migration stopped after $done of $($plans.Count) users. Check log: $LogPath"
            }
        }
    }

    Write-Log "---------- Summary ----------"
    ($results | Format-Table User, NewName, Result, Detail -AutoSize | Out-String -Width 250) -split "`r?`n" |
        Where-Object { $_.Trim() } |
        ForEach-Object { Write-Log $_ }

    if ($failed -gt 0) {
        throw "$done succeeded, $failed NOT renamed. Read the ERROR lines above. Log: $LogPath"
    }

    Write-Log "All $done migration(s) completed. Restart the PC and test each account."
}

$exitCode = 0
$mutex    = New-Object System.Threading.Mutex($false, "Global\ProfileRenameScript")
$hasMutex = $false

try {
    # Prevent two instances from running at the same time.
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) { throw "Another instance of this script is already running." }

    Invoke-Migration
}
catch {
    Write-Log "STOPPED: $($_.Exception.Message)" "ERROR"
    $exitCode = 1
}
finally {
    if ($hasMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    Write-Log "========== Migration ended. Log: $LogPath =========="
}

if ($Pause) { [void](Read-Host "Press Enter to close") }

exit $exitCode
