#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SourcePath,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'

function Read-ColorBackup([string]$Root) {
    $WhatIfPreference = $false
    $manifest = Get-Content -LiteralPath (Join-Path $Root 'manifests\color-sha256.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.version -ne 1 -or @($manifest.files).Count -eq 0) {
        throw 'Invalid or empty backup manifest.'
    }
    $names = @{}
    foreach ($entry in $manifest.files) {
        if ($entry.name -notmatch '^[^\\/:*?"<>|]+\.(dv|icm|icc|txt|camp|cdmp|gmmp)$' -or
            @($entry.sha256).Count -notin @(1, 2) -or
            @($entry.sha256 | Where-Object { $_ -notmatch '^[0-9a-fA-F]{64}$' }).Count -or
            $names.ContainsKey($entry.name)) {
            throw "Invalid or duplicate manifest entry: $($entry.name)"
        }
        $names[$entry.name] = $true
        $file = Join-Path (Join-Path $Root 'color') $entry.name
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -notin @($entry.sha256)) {
            throw "Backup SHA-256 mismatch: $($entry.name). Nothing has been restored."
        }
    }
    $items = @(Get-ChildItem -LiteralPath (Join-Path $Root 'color') -Force)
    if ($items.Count -ne $names.Count -or @($items | Where-Object PSIsContainer).Count) {
        throw 'The color directory does not match the manifest.'
    }
    $manifest.files
}

function Restore-ColorFiles([string]$Root, [string]$Destination, [array]$Entries, [string]$BackupBase) {
    $pending = @($Entries | Where-Object {
        $target = Join-Path $Destination $_.name
        !(Test-Path -LiteralPath $target -PathType Leaf) -or
            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -notin @($_.sha256)
    })
    if (!$pending.Count) {
        Write-Host 'All backup files already match. No changes needed.'
        return
    }

    $backup = Join-Path $BackupBase ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    $originals = @()
    $created = @()
    # Back up every affected original before writing any destination file.
    foreach ($entry in $pending) {
        $target = Join-Path $Destination $entry.name
        if (Test-Path -LiteralPath $target) {
            $originalHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
            Copy-Item -LiteralPath $target -Destination (Join-Path $backup $entry.name)
            if ((Get-FileHash -LiteralPath (Join-Path $backup $entry.name) -Algorithm SHA256).Hash -ne $originalHash) {
                throw "Could not verify original backup: $($entry.name)"
            }
            $originals += $entry.name
        } else {
            $created += $entry.name
        }
    }
    # New files are recorded separately so a manual undo can remove only these files.
    ConvertTo-Json -InputObject @{originals = @($originals); created = @($created)} |
        Set-Content -LiteralPath (Join-Path $backup 'restore-log.json') -Encoding UTF8
    Write-Host "Original files backed up to: $backup"

    try {
        foreach ($entry in $pending) {
            $target = Join-Path $Destination $entry.name
            Copy-Item -LiteralPath (Join-Path (Join-Path $Root 'color') $entry.name) -Destination $target -Force
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -notin @($entry.sha256)) {
                throw "Restored file SHA-256 mismatch: $($entry.name)"
            }
        }
    } catch {
        $failure = $_
        foreach ($name in $originals) {
            try {
                Copy-Item -LiteralPath (Join-Path $backup $name) -Destination (Join-Path $Destination $name) -Force
                if ((Get-FileHash -LiteralPath (Join-Path $Destination $name)).Hash -ne
                    (Get-FileHash -LiteralPath (Join-Path $backup $name)).Hash) { throw 'SHA-256 mismatch' }
            } catch { Write-Warning "Rollback failed for $name : $_. Original remains in $backup" }
        }
        foreach ($name in $created) {
            try {
                if (Test-Path -LiteralPath (Join-Path $Destination $name)) {
                    Remove-Item -LiteralPath (Join-Path $Destination $name) -Force
                }
            } catch { Write-Warning "Could not remove new file $name : $_" }
        }
        throw "Restore failed; rollback attempted. Backup: $backup. Cause: $failure"
    }
    Write-Host "Restored and verified $($pending.Count) files. Other destination files were kept."
    Write-Host 'Check the display profile association in colorcpl.exe, then restart affected apps.'
}

# Dot-sourcing exposes the two file functions for tests without touching Windows.
if ($MyInvocation.InvocationName -eq '.') { return }

$downloadDirectory = $null
try {
    # Windows PowerShell 5.1's Get-FileHash inherits WhatIf internally; reads must still run.
    $preview = [bool]$WhatIfPreference
    $WhatIfPreference = $false
    if (!$SourcePath) {
        $localRoot = Split-Path -Parent $PSScriptRoot
        if ((Test-Path -LiteralPath (Join-Path $localRoot 'manifests\color-sha256.json')) -and
            (Test-Path -LiteralPath (Join-Path $localRoot 'color') -PathType Container)) {
            $SourcePath = $localRoot
        } else {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
            $downloadDirectory = Join-Path $tempRoot ('thinkbook-icc-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $downloadDirectory | Out-Null
            $zip = Join-Path $downloadDirectory 'backup.zip'
            Write-Host 'Downloading Leovikii/thinkbook-icc (main) from GitHub...'
            Invoke-WebRequest -UseBasicParsing -Uri 'https://codeload.github.com/Leovikii/thinkbook-icc/zip/refs/heads/main' -OutFile $zip
            Expand-Archive -LiteralPath $zip -DestinationPath $downloadDirectory
            $SourcePath = Join-Path $downloadDirectory 'thinkbook-icc-main'
        }
    }
    $SourcePath = (Resolve-Path -LiteralPath $SourcePath).ProviderPath
    $entries = @(Read-ColorBackup $SourcePath)
    Write-Host "Backup verified: $($entries.Count) files."
    $destination = Join-Path $env:windir 'System32\spool\drivers\color'
    if ($CheckOnly) {
        $results = foreach ($entry in $entries) {
            $target = Join-Path $destination $entry.name
            $state = if (!(Test-Path -LiteralPath $target -PathType Leaf)) { 'Missing' }
                elseif ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -in @($entry.sha256)) { 'Match' }
                else { 'Different' }
            [pscustomobject]@{Name = $entry.name; Status = $state}
        }
        $results | Group-Object Status | Select-Object Name, Count | Format-Table -AutoSize
        $results | Where-Object Status -ne 'Match' | Format-Table -AutoSize
        Write-Host 'Check only. No Windows files or settings changed.'
        return
    }

    $model = (Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS').SystemProductName
    if ($model -notlike '21VR*' -or !(Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY\LEN8AD7')) {
        throw 'This backup is for Lenovo 21VR with a LEN8AD7 panel. Hardware check failed.'
    }
    $WhatIfPreference = $preview
    if (!$PSCmdlet.ShouldProcess($destination, "Restore $($entries.Count) verified backup files")) { return }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $admin = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (!$admin) {
        $executable = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
        $powershell = Join-Path $PSHOME $executable
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -SourcePath "{1}"' -f $PSCommandPath, $SourcePath
        $process = Start-Process -FilePath $powershell -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "Elevated restore failed (exit $($process.ExitCode))." }
        return
    }
    if (![Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
        throw 'Run this script in 64-bit PowerShell to access the correct Windows color directory.'
    }
    Restore-ColorFiles $SourcePath $destination $entries (Join-Path $env:ProgramData 'Thinkbook-ICC\Backups')
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
} finally {
    # Delete only the unique direct child created under the resolved temp directory.
    if ($downloadDirectory -and
        [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($downloadDirectory)) -eq $tempRoot -and
        [IO.Path]::GetFileName($downloadDirectory) -match '^thinkbook-icc-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $downloadDirectory -Recurse -Force -WhatIf:$false -ErrorAction SilentlyContinue
    }
}
