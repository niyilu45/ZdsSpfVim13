[CmdletBinding()]
param(
    [string]$TargetProfile = $env:USERPROFILE,
    [switch]$SkipIntegrityCheck,
    [switch]$SkipVimValidation,
    [switch]$SkipPathUpdate,
    [switch]$SkipCapsCtrl
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha256.ComputeHash($stream)
        return ([System.BitConverter]::ToString($bytes)).Replace("-", "")
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Get-ExistingItem {
    param([Parameter(Mandatory = $true)][string]$Path)
    return Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Find-Vim {
    param([string]$BundledInstallPath)

    $command = Get-Command vim.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($BundledInstallPath)) {
        $candidates.Add((Join-Path $BundledInstallPath "vim.exe"))
    }

    $programRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique

    foreach ($programRoot in $programRoots) {
        $vimRoot = Join-Path $programRoot "Vim"
        if (Test-Path -LiteralPath $vimRoot) {
            Get-ChildItem -LiteralPath $vimRoot -Directory -Filter "vim*" -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object { $candidates.Add((Join-Path $_.FullName "vim.exe")) }
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}

function Get-StringSha256 {
    param([Parameter(Mandatory = $true)][string]$Value)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $hash = $sha256.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash)).Replace("-", "")
    }
    finally {
        $sha256.Dispose()
    }
}

function Write-CommitJournal {
    param(
        [Parameter(Mandatory = $true)][object]$Journal,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $temporaryPath = $Path + ".tmp"
    $json = $Journal | ConvertTo-Json -Depth 8
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temporaryPath, $json, $encoding)
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Remove-PathIfPresent {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($null -ne (Get-ExistingItem -Path $Path)) {
        Remove-Item -LiteralPath $Path -Force -Recurse
    }
}

function Test-ExactAllowedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$AllowedPaths
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\")
    foreach ($allowedPath in $AllowedPaths) {
        if ($fullPath -ieq ([System.IO.Path]::GetFullPath($allowedPath).TrimEnd("\"))) {
            return $true
        }
    }
    return $false
}

function Recover-InterruptedInstall {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedTargetProfile,
        [Parameter(Mandatory = $true)][string[]]$AllowedTargets,
        [Parameter(Mandatory = $true)][bool]$IsCurrentUserProfile
    )

    if (-not (Test-Path -LiteralPath $TransactionRoot)) {
        return
    }

    $completedMarker = Join-Path $TransactionRoot "completed.marker"
    if (Test-Path -LiteralPath $completedMarker -PathType Leaf) {
        Write-Host "Cleaning up files from a previously completed installation..."
        Remove-Item -LiteralPath $TransactionRoot -Force -Recurse
        return
    }

    $commitJournalPath = Join-Path $TransactionRoot "commit.json"
    if (-not (Test-Path -LiteralPath $commitJournalPath -PathType Leaf)) {
        Write-Host "Removing an incomplete staging area from an interrupted installation..."
        Remove-Item -LiteralPath $TransactionRoot -Force -Recurse
        return
    }

    Write-Warning "An interrupted installation was detected. Restoring the previous configuration before continuing..."
    try {
        $journal = Get-Content -LiteralPath $commitJournalPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "The interrupted-install journal is unreadable. To protect existing data, nothing was changed. Journal: $commitJournalPath"
    }

    if ([System.IO.Path]::GetFullPath([string]$journal.TargetProfile).TrimEnd("\") -ine $ExpectedTargetProfile.TrimEnd("\")) {
        throw "The interrupted-install journal does not belong to this user profile. Journal: $commitJournalPath"
    }

    $backupBase = [System.IO.Path]::GetFullPath((Join-Path $ExpectedTargetProfile "spf13-vim-backups")).TrimEnd("\")
    $backupRoot = [System.IO.Path]::GetFullPath([string]$journal.BackupRoot).TrimEnd("\")
    if (-not $backupRoot.StartsWith($backupBase + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "The interrupted-install journal contains an unsafe backup path. Journal: $commitJournalPath"
    }

    $entries = @($journal.Entries)
    for ($index = $entries.Count - 1; $index -ge 0; $index--) {
        $entry = $entries[$index]
        $target = [System.IO.Path]::GetFullPath([string]$entry.Target)
        $backup = [System.IO.Path]::GetFullPath([string]$entry.Backup)

        if (-not (Test-ExactAllowedPath -Path $target -AllowedPaths $AllowedTargets)) {
            throw "The interrupted-install journal contains an unsafe target path: $target"
        }
        if (-not $backup.StartsWith($backupRoot + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "The interrupted-install journal contains an unsafe backup item path: $backup"
        }

        if ([bool]$entry.OriginalExists) {
            if ($null -ne (Get-ExistingItem -Path $backup)) {
                Remove-PathIfPresent -Path $target
                $targetParent = Split-Path -Parent $target
                New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
                Move-Item -LiteralPath $backup -Destination $target -Force
            }
        }
        else {
            Remove-PathIfPresent -Path $target
        }
    }

    if ([bool]$journal.RestoreUserPath -and $IsCurrentUserProfile) {
        [Environment]::SetEnvironmentVariable("Path", [string]$journal.OldUserPath, "User")
    }

    Remove-Item -LiteralPath $TransactionRoot -Force -Recurse
    if (Test-Path -LiteralPath $backupRoot) {
        $backupChildren = @(Get-ChildItem -LiteralPath $backupRoot -Force)
        if ($backupChildren.Count -eq 0) {
            Remove-Item -LiteralPath $backupRoot -Force
        }
    }
    Write-Host "The previous configuration was restored successfully."
    Write-Host ""
}

$packageRoot = $PSScriptRoot
$payloadArchive = Join-Path $packageRoot "payload.zip"
$configRoot = Join-Path $packageRoot "config"
$manifestPath = Join-Path $packageRoot "manifest.sha256"

if ([string]::IsNullOrWhiteSpace($TargetProfile)) {
    throw "The target user profile could not be determined."
}
$TargetProfile = [System.IO.Path]::GetFullPath($TargetProfile)

Write-Host "Package: $packageRoot"
Write-Host "Target user profile: $TargetProfile"
Write-Host ""

New-Item -ItemType Directory -Path $TargetProfile -Force | Out-Null

$isCurrentUserProfile = $TargetProfile.TrimEnd("\") -ieq $env:USERPROFILE.TrimEnd("\")
if ($isCurrentUserProfile -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $localAppData = $env:LOCALAPPDATA
}
else {
    $localAppData = Join-Path $TargetProfile "AppData\Local"
}

$runtimeTarget = Join-Path $localAppData "Programs\spf13-vim\vim81"
$capsCtrlTarget = Join-Path $localAppData "Programs\spf13-vim\tools\capsctrl.exe"
$vimExe = Find-Vim -BundledInstallPath $runtimeTarget
$installBundledVim = $null -eq $vimExe

$pluginTarget = Join-Path $TargetProfile ".vim"
$targetPaths = @(
    (Join-Path $TargetProfile "_vimrc"),
    (Join-Path $TargetProfile ".vimrc"),
    (Join-Path $TargetProfile ".vimrc.before"),
    (Join-Path $TargetProfile ".vimrc.bundles"),
    (Join-Path $TargetProfile ".vimrc.local"),
    $pluginTarget,
    $runtimeTarget,
    $capsCtrlTarget
)
$transactionRoot = Join-Path $TargetProfile ".spf13-vim-install-transaction"
$stageRoot = Join-Path $transactionRoot "stage"
$commitJournalPath = Join-Path $transactionRoot "commit.json"
$completedMarker = Join-Path $transactionRoot "completed.marker"

$mutexHash = (Get-StringSha256 -Value $TargetProfile.ToUpperInvariant()).Substring(0, 24)
$mutexName = "Local\spf13-vim-installer-$mutexHash"
$installMutex = New-Object System.Threading.Mutex($false, $mutexName)
$mutexAcquired = $false
try {
    $mutexAcquired = $installMutex.WaitOne(0)
}
catch [System.Threading.AbandonedMutexException] {
    $mutexAcquired = $true
}
if (-not $mutexAcquired) {
    $installMutex.Dispose()
    throw "Another spf13-vim installation is already running for this user profile."
}

$backupRoot = $null
$pathChanged = $false
try {
    Recover-InterruptedInstall -TransactionRoot $transactionRoot -ExpectedTargetProfile $TargetProfile -AllowedTargets $targetPaths -IsCurrentUserProfile $isCurrentUserProfile

    $requiredPaths = @(
        (Join-Path $configRoot "main.vimrc"),
        (Join-Path $configRoot ".vimrc.before"),
        (Join-Path $configRoot ".vimrc.bundles"),
        (Join-Path $configRoot ".vimrc.local"),
        $payloadArchive,
        $manifestPath
    )
    foreach ($requiredPath in $requiredPaths) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "The package is incomplete. Missing: $requiredPath"
        }
    }

    if (-not $SkipIntegrityCheck) {
        Write-Host "Checking package integrity..."
        $manifestLines = @(Get-Content -LiteralPath $manifestPath -Encoding UTF8)
        $checked = 0
        foreach ($line in $manifestLines) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            $parts = $line.Split("`t", 2)
            if ($parts.Count -ne 2 -or $parts[0].Length -ne 64) {
                throw "Invalid manifest entry: $line"
            }

            $expectedHash = $parts[0].ToUpperInvariant()
            $relativePath = $parts[1]
            $filePath = Join-Path $packageRoot $relativePath
            if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                throw "Package file is missing: $relativePath"
            }

            $actualHash = Get-Sha256 -Path $filePath
            if ($actualHash -ne $expectedHash) {
                throw "Package integrity check failed: $relativePath"
            }

            $checked++
            if (($checked % 250) -eq 0) {
                $percent = [Math]::Min(100, [int](100 * $checked / [Math]::Max(1, $manifestLines.Count)))
                Write-Progress -Activity "Checking package integrity" -Status "$checked files checked" -PercentComplete $percent
            }
        }
        Write-Progress -Activity "Checking package integrity" -Completed
        Write-Host "Integrity check passed ($checked files)."
        Write-Host ""
    }

    Write-Host "Extracting the offline payload..."
    Write-Host "If this is interrupted, run install.bat again to restart safely."
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
    Expand-Archive -LiteralPath $payloadArchive -DestinationPath $stageRoot -Force

    $payloadRoot = Join-Path $stageRoot "payload"
    $pluginSource = Join-Path $payloadRoot ".vim"
    $vimSource = Join-Path $payloadRoot "vim81"
    $capsCtrlSource = Join-Path $payloadRoot "tools\capsctrl.exe"
    $requiredPayloadPaths = @(
        $pluginSource,
        (Join-Path $vimSource "vim.exe")
    )
    if (-not $SkipCapsCtrl) {
        $requiredPayloadPaths += $capsCtrlSource
    }
    foreach ($requiredPayloadPath in $requiredPayloadPaths) {
        if (-not (Test-Path -LiteralPath $requiredPayloadPath)) {
            throw "The payload archive is incomplete. Missing after extraction: $requiredPayloadPath"
        }
    }

    Write-Host "Staging configuration and plugins..."
    Write-Host "The current Vim setup will remain untouched until staging is complete."

    $fileDeployments = @(
        [PSCustomObject]@{ Source = (Join-Path $configRoot "main.vimrc"); Stage = (Join-Path $stageRoot "_vimrc"); Target = (Join-Path $TargetProfile "_vimrc"); BackupName = "_vimrc" },
        [PSCustomObject]@{ Source = (Join-Path $configRoot "main.vimrc"); Stage = (Join-Path $stageRoot ".vimrc"); Target = (Join-Path $TargetProfile ".vimrc"); BackupName = ".vimrc" },
        [PSCustomObject]@{ Source = (Join-Path $configRoot ".vimrc.before"); Stage = (Join-Path $stageRoot ".vimrc.before"); Target = (Join-Path $TargetProfile ".vimrc.before"); BackupName = ".vimrc.before" },
        [PSCustomObject]@{ Source = (Join-Path $configRoot ".vimrc.bundles"); Stage = (Join-Path $stageRoot ".vimrc.bundles"); Target = (Join-Path $TargetProfile ".vimrc.bundles"); BackupName = ".vimrc.bundles" },
        [PSCustomObject]@{ Source = (Join-Path $configRoot ".vimrc.local"); Stage = (Join-Path $stageRoot ".vimrc.local"); Target = (Join-Path $TargetProfile ".vimrc.local"); BackupName = ".vimrc.local" }
    )
    foreach ($deployment in $fileDeployments) {
        [System.IO.File]::Copy($deployment.Source, $deployment.Stage, $true)
    }
    if ($SkipCapsCtrl) {
        $localConfigStage = Join-Path $stageRoot ".vimrc.local"
        $localConfigContents = [System.IO.File]::ReadAllText($localConfigStage)
        [System.IO.File]::WriteAllText(
            $localConfigStage,
            "let g:spf13_disable_caps_ctrl = 1`n$localConfigContents",
            (New-Object System.Text.UTF8Encoding($false))
        )
        Write-Host "Caps Lock to Ctrl mapping: disabled by option."
    }
    else {
        $capsCtrlStage = Join-Path $stageRoot "capsctrl.exe"
        [System.IO.File]::Copy($capsCtrlSource, $capsCtrlStage, $true)
        $fileDeployments += [PSCustomObject]@{
            Source = $capsCtrlSource
            Stage = $capsCtrlStage
            Target = $capsCtrlTarget
            BackupName = "capsctrl.exe"
        }
        Write-Host "Caps Lock to Ctrl mapping: enabled for Vim/gVim only."
    }

    $pluginStage = $pluginSource

    $runtimeStage = $vimSource
    if ($installBundledVim) {
        Write-Host "No existing Vim installation was found; the bundled Vim runtime will be installed."
    }

    $oldUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $pathParts = @([string]$oldUserPath -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $runtimeAlreadyInPath = $null -ne ($pathParts | Where-Object { $_.TrimEnd("\") -ieq $runtimeTarget.TrimEnd("\") } | Select-Object -First 1)
    $willChangePath = $installBundledVim -and $isCurrentUserProfile -and (-not $SkipPathUpdate) -and (-not $runtimeAlreadyInPath)

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupRoot = Join-Path $TargetProfile "spf13-vim-backups\$timestamp-$PID"
    $commitEntries = New-Object System.Collections.Generic.List[object]
    foreach ($deployment in $fileDeployments) {
        $commitEntries.Add([PSCustomObject]@{
            Stage = $deployment.Stage
            Target = $deployment.Target
            Backup = (Join-Path $backupRoot $deployment.BackupName)
            OriginalExists = ($null -ne (Get-ExistingItem -Path $deployment.Target))
        })
    }
    $commitEntries.Add([PSCustomObject]@{
        Stage = $pluginStage
        Target = $pluginTarget
        Backup = (Join-Path $backupRoot ".vim")
        OriginalExists = ($null -ne (Get-ExistingItem -Path $pluginTarget))
    })

    if ($installBundledVim) {
        $commitEntries.Add([PSCustomObject]@{
            Stage = $runtimeStage
            Target = $runtimeTarget
            Backup = (Join-Path $backupRoot "vim-runtime")
            OriginalExists = ($null -ne (Get-ExistingItem -Path $runtimeTarget))
        })
    }

    $journal = [PSCustomObject]@{
        Version = 1
        TargetProfile = $TargetProfile
        BackupRoot = $backupRoot
        RestoreUserPath = $willChangePath
        OldUserPath = [string]$oldUserPath
        Entries = $commitEntries.ToArray()
    }
    Write-CommitJournal -Journal $journal -Path $commitJournalPath

    Write-Host "Staging completed. Committing the installation..."
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    foreach ($entry in $commitEntries) {
        if ([bool]$entry.OriginalExists) {
            $backupParent = Split-Path -Parent $entry.Backup
            New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
            Move-Item -LiteralPath $entry.Target -Destination $entry.Backup -Force
            Write-Host "Backed up: $($entry.Target)"
        }

        $targetParent = Split-Path -Parent $entry.Target
        New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
        Move-Item -LiteralPath $entry.Stage -Destination $entry.Target -Force
    }

    if ($installBundledVim) {
        $vimExe = Join-Path $runtimeTarget "vim.exe"
        if ($willChangePath) {
            $newUserPath = (($pathParts + $runtimeTarget) -join ";")
            [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
            $pathChanged = $true
            $env:Path = $env:Path + ";" + $runtimeTarget
            [System.IO.File]::WriteAllText((Join-Path $backupRoot "user-path-before.txt"), [string]$oldUserPath)
            Write-Host "Added bundled Vim to the current user's PATH."
        }
    }
    else {
        Write-Host "Using existing Vim: $vimExe"
    }

    if (-not $SkipVimValidation) {
        Write-Host "Validating Vim startup..."
        $mainConfig = Join-Path $TargetProfile "_vimrc"
        $validationState = Join-Path $transactionRoot "vim-validation.state"
        $validationStateForVim = $validationState.Replace("'", "''").Replace("\", "/")
        $validationCommand = "call writefile([&encoding, &termencoding, &fileencodings, &listchars, 'ERR=' . v:errmsg, string(get(g:, 'spf13_caps_ctrl_active', 0))], '$validationStateForVim')"
        $previousErrorActionPreference = $ErrorActionPreference
        $previousHome = $env:HOME
        $previousLocalAppData = $env:LOCALAPPDATA
        try {
            # Some optional plugins write harmless diagnostics to stderr.  The
            # encoding state written by Vim is authoritative; process output is
            # retained only for diagnostics.
            $ErrorActionPreference = "Continue"
            $env:HOME = $TargetProfile
            $env:LOCALAPPDATA = $localAppData
            $validationOutput = @(& $vimExe "-Nu" $mainConfig "-n" "-N" "-es" "-i" "NONE" "-c" "set nomore" "-c" $validationCommand "-c" "qa!" 2>&1)
            $validationExitCode = $LASTEXITCODE
        }
        finally {
            if ($null -eq $previousHome) {
                Remove-Item Env:HOME -ErrorAction SilentlyContinue
            }
            else {
                $env:HOME = $previousHome
            }
            if ($null -eq $previousLocalAppData) {
                Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue
            }
            else {
                $env:LOCALAPPDATA = $previousLocalAppData
            }
            $ErrorActionPreference = $previousErrorActionPreference
        }

        $validationValues = @()
        if (Test-Path -LiteralPath $validationState -PathType Leaf) {
            $validationValues = @(Get-Content -LiteralPath $validationState -Encoding UTF8)
        }
        $validationDiagnostics = ($validationOutput | ForEach-Object { [string]$_ }) -join "`n"
        $hasForbiddenStartupDiagnostic = $validationDiagnostics -match "(?i)not a git repository|(^|\W)uname(\W|$)"
        $expectedCapsCtrlState = if ($SkipCapsCtrl) { "0" } else { "1" }
        $encodingIsValid = $validationValues.Count -ge 6 -and
            $validationValues[0] -eq "utf-8" -and
            $validationValues[1] -eq "" -and
            @($validationValues[2].Split(",")) -contains "gb18030" -and
            $validationValues[3] -eq "tab:>-,trail:.,extends:>,precedes:<,nbsp:+" -and
            $validationValues[4] -eq "ERR=" -and
            $validationValues[5] -eq $expectedCapsCtrlState -and
            -not $hasForbiddenStartupDiagnostic

        if ($encodingIsValid) {
            Write-Host "Vim startup validation passed."
        }
        else {
            $validationLog = Join-Path $backupRoot "vim-validation.log"
            if ($validationOutput.Count -gt 0) {
                [System.IO.File]::WriteAllLines($validationLog, [string[]]$validationOutput)
            }
            throw "Vim startup or encoding validation failed (exit code $validationExitCode). Details: $validationLog"
        }
    }

    $backupHasContent = (@($commitEntries | Where-Object { [bool]$_.OriginalExists }).Count -gt 0) -or $pathChanged
    if (-not $backupHasContent) {
        Remove-Item -LiteralPath $backupRoot -Force -Recurse
        $backupRoot = $null
    }

    [System.IO.File]::WriteAllText($completedMarker, "completed")
    try {
        Remove-Item -LiteralPath $transactionRoot -Force -Recurse
    }
    catch {
        Write-Warning "Installation completed, but temporary files could not be removed. They will be cleaned automatically next time."
    }

    Write-Host ""
    Write-Host "spf13-vim deployment completed."
    Write-Host "Vim executable: $vimExe"
    if ($null -ne $backupRoot) {
        Write-Host "Previous files backup: $backupRoot"
    }
    if ($pathChanged) {
        Write-Host "Open a new Command Prompt or PowerShell window before using the 'vim' command."
    }
    $installMutex.ReleaseMutex()
    $mutexAcquired = $false
    $installMutex.Dispose()
    exit 0
}
catch {
    $failure = $_
    Write-Host ""
    Write-Warning "Installation failed. Rolling back changes..."

    try {
        Recover-InterruptedInstall -TransactionRoot $transactionRoot -ExpectedTargetProfile $TargetProfile -AllowedTargets $targetPaths -IsCurrentUserProfile $isCurrentUserProfile
    }
    catch {
        Write-Warning "Automatic rollback could not finish: $($_.Exception.Message)"
        Write-Warning "Keep this recovery directory and run install.bat again: $transactionRoot"
    }

    if ($mutexAcquired) {
        $installMutex.ReleaseMutex()
        $mutexAcquired = $false
    }
    $installMutex.Dispose()
    Write-Host ("ERROR: " + $failure.Exception.Message) -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace([string]$failure.ScriptStackTrace)) {
        Write-Host ([string]$failure.ScriptStackTrace) -ForegroundColor DarkGray
    }
    exit 1
}
