#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Restore-Color.ps1')

function Assert($Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert $rejected $Message
}

$testRoot = Join-Path $PSScriptRoot ('.restore-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    # The real repository must pass the same preflight as a downloaded backup.
    $realEntries = @(Read-ColorBackup (Split-Path -Parent $PSScriptRoot))
    Assert ($realEntries.Count -eq 386) 'Unexpected factory backup file count.'

    $source = Join-Path $testRoot 'source'
    $color = Join-Path $source 'color'
    $target = Join-Path $testRoot 'target'
    $backups = Join-Path $testRoot 'backups'
    New-Item -ItemType Directory -Path $color, $target, (Join-Path $source 'manifests') | Out-Null
    foreach ($name in @('a.icm', 'b.dv', 'c.icm')) {
        Set-Content -LiteralPath (Join-Path $color $name) -Value "factory-$name"
    }
    $entries = @(Get-ChildItem -LiteralPath $color -File | Sort-Object Name | ForEach-Object {
        @{name = $_.Name; sha256 = (Get-FileHash -LiteralPath $_.FullName).Hash}
    })
    $manifest = Join-Path $source 'manifests\color-sha256.json'
    @{version = 1; files = $entries} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifest -Encoding UTF8
    $validated = @(Read-ColorBackup $source)
    Assert ($validated.Count -eq 3) 'Fixture preflight failed.'

    # Exercise the standalone download/extraction path without network access or elevation.
    $packageRoot = Join-Path $testRoot 'package'
    New-Item -ItemType Directory -Path $packageRoot | Out-Null
    $payload = Join-Path $packageRoot 'thinkbook-icc-main'
    Copy-Item -LiteralPath $source -Destination $payload -Recurse
    $downloadState = @{zip = (Join-Path $testRoot 'package.zip'); path = $null}
    Compress-Archive -LiteralPath $payload -DestinationPath $downloadState.zip
    $standalone = Join-Path $testRoot 'Restore-Color.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Restore-Color.ps1') -Destination $standalone
    $fakeDownload = {
        param([switch]$UseBasicParsing, [string]$Uri, [string]$OutFile)
        if ($Uri -ne 'https://codeload.github.com/Leovikii/thinkbook-icc/zip/refs/heads/main') { throw 'Wrong download URL.' }
        $downloadState.path = Split-Path -Parent $OutFile
        [IO.File]::Copy($downloadState.zip, $OutFile)
    }.GetNewClosure()
    Set-Item -Path Function:\Invoke-WebRequest -Value $fakeDownload
    try { & $standalone -CheckOnly } finally { Remove-Item Function:\Invoke-WebRequest }
    Assert ($downloadState.path -and !(Test-Path -LiteralPath $downloadState.path)) 'Download temp files were not cleaned up.'

    Set-Content -LiteralPath (Join-Path $target 'a.icm') -Value 'old-a'
    Set-Content -LiteralPath (Join-Path $target 'extra.icc') -Value 'keep-hdr'
    Restore-ColorFiles $source $target $validated $backups
    foreach ($entry in $entries) {
        Assert ((Get-FileHash -LiteralPath (Join-Path $target $entry.name)).Hash -eq $entry.sha256) 'Copy/hash check failed.'
    }
    Assert ((Get-Content -LiteralPath (Join-Path $target 'extra.icc')) -eq 'keep-hdr') 'Unrelated file changed.'
    $saved = @(Get-ChildItem -LiteralPath $backups -Directory)
    Assert ($saved.Count -eq 1) 'Original backup was not created.'
    Assert ((Get-Content -LiteralPath (Join-Path $saved[0].FullName 'a.icm')) -eq 'old-a') 'Original not preserved.'
    $log = Get-Content -LiteralPath (Join-Path $saved[0].FullName 'restore-log.json') -Raw | ConvertFrom-Json
    Assert (@($log.created).Count -eq 2 -and @($log.originals).Count -eq 1) 'Undo log is wrong.'
    Restore-ColorFiles $source $target $validated $backups
    Assert (@(Get-ChildItem -LiteralPath $backups -Directory).Count -eq 1) 'Identical files should be skipped.'

    Set-Content -LiteralPath (Join-Path $color 'a.icm') -Value 'tampered'
    Assert-Rejected { Read-ColorBackup $source } 'Tampered source accepted.'
    Set-Content -LiteralPath (Join-Path $color 'a.icm') -Value 'factory-a.icm'
    Set-Content -LiteralPath (Join-Path $color 'extra.dv') -Value 'unexpected'
    Assert-Rejected { Read-ColorBackup $source } 'Unlisted file accepted.'
    Remove-Item -LiteralPath (Join-Path $color 'extra.dv')
    @{version = 1; files = @(@{name = '..\escape.icm'; sha256 = ('A' * 64)})} |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifest -Encoding UTF8
    Assert-Rejected { Read-ColorBackup $source } 'Path traversal accepted.'
    @{version = 1; files = @($entries[0], $entries[0])} |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifest -Encoding UTF8
    Assert-Rejected { Read-ColorBackup $source } 'Duplicate entry accepted.'

    # Simulate a copy that writes a file and then fails, after another new file was added.
    Set-Content -LiteralPath (Join-Path $target 'a.icm') -Value 'before-a'
    Set-Content -LiteralPath (Join-Path $target 'c.icm') -Value 'before-c'
    Remove-Item -LiteralPath (Join-Path $target 'b.dv')
    $script:failSource = Join-Path $color 'c.icm'
    function Copy-Item {
        param([string]$LiteralPath, [string]$Destination, [switch]$Force)
        Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
        if ($LiteralPath -eq $script:failSource) { throw 'Simulated copy failure.' }
    }
    try {
        Assert-Rejected { Restore-ColorFiles $source $target $validated $backups } 'Copy failure was ignored.'
    } finally { Remove-Item Function:\Copy-Item }
    Assert ((Get-Content -LiteralPath (Join-Path $target 'a.icm')) -eq 'before-a') 'Rollback failed for a.icm.'
    Assert ((Get-Content -LiteralPath (Join-Path $target 'c.icm')) -eq 'before-c') 'Partial copy was not rolled back.'
    Assert (!(Test-Path -LiteralPath (Join-Path $target 'b.dv'))) 'New file was not removed on rollback.'
    Assert ((Get-Content -LiteralPath (Join-Path $target 'extra.icc')) -eq 'keep-hdr') 'Rollback changed an unrelated file.'
    Write-Host 'PASS: download/extraction, manifest, hashes, backup, idempotence, unrelated files, path validation, and failure rollback.'
} finally {
    $workspace = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($testRoot)) -eq $workspace -and
        [IO.Path]::GetFileName($testRoot) -match '^\.restore-test-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
