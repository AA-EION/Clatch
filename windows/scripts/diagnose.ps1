# SPDX-License-Identifier: GPL-3.0-or-later
#
# Clatch diagnostics for Windows: where does Claude Desktop really keep its data?
#
# Collects ONLY names, paths, sizes and dates. It never reads file contents,
# cookies, tokens or passwords. The report is written to your Desktop as
# clatch-diagnostics.txt; read it before sharing it.
#
# Run it in a normal (not administrator) PowerShell window, ideally with
# Claude Desktop open and signed in:
#
#   irm https://raw.githubusercontent.com/AA-EION/Clatch/main/windows/scripts/diagnose.ps1 | iex
#
# Works with Windows PowerShell 5.1 and PowerShell 7.

$ErrorActionPreference = 'SilentlyContinue'
$report = Join-Path ([Environment]::GetFolderPath('Desktop')) 'clatch-diagnostics.txt'
$lines = New-Object System.Collections.Generic.List[string]
function Out($text) { $lines.Add([string]$text); Write-Host $text }
function Section($title) { Out ''; Out ('==== ' + $title + ' ' + ('=' * [Math]::Max(0, 60 - $title.Length))) }

$roaming = $env:APPDATA
$local = $env:LOCALAPPDATA
$since = (Get-Date).AddMinutes(-30)

Section 'System'
Out ("Windows: " + [Environment]::OSVersion.VersionString + " | arch: " + $env:PROCESSOR_ARCHITECTURE + " | PowerShell " + $PSVersionTable.PSVersion)
Out ("Time: " + (Get-Date).ToString('u'))
Out ("APPDATA=" + $roaming)
Out ("LOCALAPPDATA=" + $local)

Section 'Claude packages (Microsoft Store / MSIX)'
$packages = @(Get-AppxPackage | Where-Object { $_.Name -like '*Claude*' -or $_.Publisher -like '*Anthropic*' -or $_.PublisherDisplayName -like '*Anthropic*' })
if ($packages.Count -eq 0) { Out 'none' }
foreach ($p in $packages) {
    Out ("Name=" + $p.Name + " | Family=" + $p.PackageFamilyName + " | Version=" + $p.Version + " | Arch=" + $p.Architecture + " | Signature=" + $p.SignatureKind)
    Out ("  Installed at: " + $p.InstallLocation)
    try {
        $manifest = [xml](Get-Content (Join-Path $p.InstallLocation 'AppxManifest.xml') -Raw)
        foreach ($app in $manifest.Package.Applications.Application) {
            Out ("  App Id=" + $app.Id + " | Executable=" + $app.Executable + " | EntryPoint=" + $app.EntryPoint)
        }
        $raw = Get-Content (Join-Path $p.InstallLocation 'AppxManifest.xml') -Raw
        foreach ($k in 'unvirtualizedResources', 'FileSystemWriteVirtualization', 'RegistryWriteVirtualization', 'runFullTrust', 'desktop6', 'virtualization') {
            if ($raw -match $k) { Out ("  manifest mentions: " + $k) }
        }
        $m = [regex]::Matches($raw, '<virtualization:ExcludedDirectory>([^<]+)</virtualization:ExcludedDirectory>')
        foreach ($x in $m) { Out ("  excluded from virtualization: " + $x.Groups[1].Value) }
    } catch { Out '  (manifest not readable)' }
}

Section 'Claude classic installer'
foreach ($f in @((Join-Path $local 'AnthropicClaude'), (Join-Path $local 'Programs\Claude'), (Join-Path $local 'Programs\claude-desktop'))) {
    if (Test-Path $f) {
        Out ("present: " + $f)
        Get-ChildItem $f | Select-Object -First 15 | ForEach-Object { Out ("  " + $_.Name + "  " + $_.LastWriteTime.ToString('u')) }
    } else { Out ("absent: " + $f) }
}

Section 'Running Claude processes (with command lines: they show --user-data-dir if set)'
$procs = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'claude|anthropic' -or $_.ExecutablePath -match 'claude|anthropic' })
if ($procs.Count -eq 0) { Out 'none running' }
foreach ($p in $procs) {
    $cmd = [string]$p.CommandLine
    # Keep the parts that matter, drop long feature-flag lists.
    $keep = @([regex]::Matches($cmd, '--(user-data-dir|type|app-path|lang|profile[-\w]*)=("[^"]*"|\S+)') | ForEach-Object { $_.Value }) -join ' '
    Out ("pid " + $p.ProcessId + " <- " + $p.ParentProcessId + " | " + $p.ExecutablePath)
    if ($keep) { Out ("  " + $keep) }
}

function Describe-Folder($path) {
    if (-not (Test-Path $path)) { Out ("absent: " + $path); return }
    $item = Get-Item $path -Force
    $attr = if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { ' (LINK -> ' + $item.Target + ')' } else { '' }
    Out ("present: " + $path + $attr + "  modified " + $item.LastWriteTime.ToString('u'))
    foreach ($marker in 'Local State', 'Cookies', 'Network\Cookies', 'config.json', 'claude_desktop_config.json', 'Local Storage', 'IndexedDB', 'Session Storage', 'Partitions') {
        $m = Join-Path $path $marker
        if (Test-Path $m) {
            $mi = Get-Item $m -Force
            $size = if ($mi.PSIsContainer) { 'folder' } else { [string]$mi.Length + ' bytes' }
            Out ("    has " + $marker + " (" + $size + ", modified " + $mi.LastWriteTime.ToString('u') + ")")
        }
    }
    $names = @(Get-ChildItem $path -Force | Select-Object -ExpandProperty Name)
    Out ("    contents: " + (($names | Select-Object -First 40) -join ', ') + $(if ($names.Count -gt 40) { ' ...' } else { '' }))
}

Section 'Candidate data folders'
$candidates = New-Object System.Collections.Generic.List[string]
foreach ($n in 'Claude', 'Claude-3p', 'Anthropic', 'Anthropic Claude', 'claude-desktop') {
    $candidates.Add((Join-Path $roaming $n)); $candidates.Add((Join-Path $local $n))
}
foreach ($pkg in @(Get-ChildItem (Join-Path $local 'Packages') -Directory | Where-Object { $_.Name -match 'claude|anthropic' })) {
    foreach ($sub in 'LocalCache\Roaming\Claude', 'LocalCache\Roaming\Claude-3p', 'LocalCache\Local\Claude', 'LocalCache\Local\AnthropicClaude', 'LocalState', 'RoamingState') {
        $candidates.Add((Join-Path $pkg.FullName $sub))
    }
}
foreach ($c in $candidates) { Describe-Folder $c }

Section 'Package folders (two levels)'
foreach ($pkg in @(Get-ChildItem (Join-Path $local 'Packages') -Directory | Where-Object { $_.Name -match 'claude|anthropic' })) {
    Out $pkg.FullName
    Get-ChildItem $pkg.FullName -Directory -Force | ForEach-Object {
        $children = @(Get-ChildItem $_.FullName -Force | Select-Object -First 15 | ForEach-Object { $_.Name }) -join ', '
        Out ("  " + $_.Name + "/ [" + $children + "]")
        foreach ($cache in 'Roaming', 'Local') {
            $cp = Join-Path $_.FullName $cache
            if (Test-Path $cp) { Out ("    " + $cache + "/ [" + ((@(Get-ChildItem $cp -Force | ForEach-Object { $_.Name })) -join ', ') + "]") }
        }
    }
}

Section 'Every "Cookies" and "Local State" file that belongs to Claude'
foreach ($root in @($roaming, $local)) {
    Get-ChildItem $root -Recurse -Force -Include 'Cookies', 'Local State' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'claude|anthropic' } |
        ForEach-Object { Out ($_.FullName + "  (" + $_.Length + " bytes, modified " + $_.LastWriteTime.ToString('u') + ")") }
}

Section 'Files Claude changed in the last 30 minutes (top 40)'
foreach ($root in @($roaming, $local)) {
    Get-ChildItem $root -Recurse -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $since -and $_.FullName -match 'claude|anthropic' -and $_.FullName -notmatch '\\Clatch\\' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 40 |
        ForEach-Object { Out ($_.LastWriteTime.ToString('u') + "  " + $_.FullName) }
}

Section 'Saved Windows credentials mentioning Claude/Anthropic (names only)'
$creds = @(cmdkey /list | Select-String -Pattern 'claude|anthropic' -Context 0, 2)
if ($creds.Count -eq 0) { Out 'none' }
foreach ($c in $creds) { Out $c.Line.Trim(); foreach ($l in $c.Context.PostContext) { if ($l.Trim()) { Out ("  " + $l.Trim()) } } }

Section 'Registry keys (names only)'
foreach ($k in 'HKCU:\Software\Anthropic', 'HKCU:\Software\Claude', 'HKCU:\Software\Classes\claude', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AnthropicClaude') {
    if (Test-Path $k) { Out ("present: " + $k + " | values: " + ((Get-Item $k).Property -join ', ')) } else { Out ("absent: " + $k) }
}

Section 'Clatch'
$clatch = Join-Path $local 'Clatch'
if (Test-Path (Join-Path $clatch 'accounts.json')) {
    $state = Get-Content (Join-Path $clatch 'accounts.json') -Raw | ConvertFrom-Json
    foreach ($a in $state.accounts) {
        $active = if ($a.id -eq $state.activeId) { ' (active)' } else { '' }
        Out ("account " + $a.name + $active + " id=" + $a.id)
        $folder = Join-Path $clatch ('Accounts\' + $a.id)
        if (Test-Path $folder) { Get-ChildItem $folder -Directory | ForEach-Object { Out ("  parked: " + $_.Name + " (modified " + $_.LastWriteTime.ToString('u') + ")") } }
    }
} else { Out 'no accounts.json' }
if (Test-Path (Join-Path $clatch 'switch-journal.json')) { Out 'switch-journal.json present (a switch did not finish)' }
$log = Join-Path $clatch 'clatch.log'
if (Test-Path $log) { Out '--- last 60 lines of clatch.log ---'; Get-Content $log -Tail 60 | ForEach-Object { Out $_ } }

$lines | Set-Content -Path $report -Encoding UTF8
Write-Host ''
Write-Host ("Report saved to " + $report + " (names, paths, sizes and dates only).") -ForegroundColor Green
