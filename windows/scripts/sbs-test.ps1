# SPDX-License-Identifier: GPL-3.0-or-later
#
# End-to-end test of side by side mode for CI, against the same stand-in for
# Claude Desktop as switch-test.ps1 (a small WinForms claude.exe in the classic
# install location). With side by side and profile shortcuts turned on:
#   1. "Clatch --add-account Bob" must leave the running Claude alone, make a
#      profile folder %LOCALAPPDATA%\Clatch-<id>, start a second Claude with
#      --user-data-dir pointing at it, and create Bob's Desktop and Start menu
#      shortcuts;
#   2. "Clatch --launch <Bob>" must not start a third Claude (Bob's is open);
#   3. closing the first Claude and "Clatch --launch <first>" must start it
#      again on Claude's own folder.
#
#   pwsh windows/scripts/sbs-test.ps1 -Exe path\to\Clatch.exe
param([Parameter(Mandatory)] [string]$Exe)
$ErrorActionPreference = 'Stop'

$classic = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
$fake = Join-Path $classic 'claude.exe'
$data = Join-Path $env:APPDATA 'Claude'
$clatch = Join-Path $env:LOCALAPPDATA 'Clatch'
$log = Join-Path $clatch 'clatch.log'
$desktop = [Environment]::GetFolderPath('DesktopDirectory')
$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Clatch Profiles'

Get-Process claude, Clatch -ErrorAction SilentlyContinue | Stop-Process -Force
Get-ChildItem $env:LOCALAPPDATA -Directory -Filter 'Clatch-*' | Remove-Item -Recurse -Force
Remove-Item $clatch, $classic, $data, $startMenu -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem $desktop -Filter 'Claude - *.lnk' -ErrorAction SilentlyContinue | Remove-Item -Force
New-Item -ItemType Directory -Force $classic, $clatch | Out-Null
'{ "sideBySide": true, "profileShortcuts": true }' | Set-Content (Join-Path $clatch 'settings.json')

$source = @'
using System.Windows.Forms;
public static class FakeClaude {
    [System.STAThread] public static void Main() { Application.Run(new Form { Text = "Fake Claude" }); }
}
'@
$builder = Join-Path $env:TEMP 'build-fake-claude.ps1'
@"
Add-Type -TypeDefinition @'
$source
'@ -ReferencedAssemblies System.Windows.Forms -OutputAssembly '$fake' -OutputType WindowsApplication
"@ | Set-Content $builder
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder
if (-not (Test-Path $fake)) { throw 'could not build the stand-in claude.exe' }

New-Item -ItemType Directory -Force $data | Out-Null
Set-Content (Join-Path $data 'Local State') '{}'
Set-Content (Join-Path $data 'config.json') '{}'
Set-Content (Join-Path $data 'Cookies') 'alice' -NoNewline

function Wait-Until([scriptblock]$condition, $what) {
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $log) -and (Select-String -Path $log -Pattern ' ERROR ' -Quiet)) { throw 'Clatch logged an error' }
        if (& $condition) { return }
        Start-Sleep -Milliseconds 500
    }
    throw "timed out waiting for $what"
}

function Claudes {
    @(Get-CimInstance Win32_Process -Filter "Name = 'claude.exe'" | Where-Object { $_.ExecutablePath -eq $fake })
}

try {
    $first = Start-Process $fake -PassThru
    Wait-Until { $first.Refresh(); $first.MainWindowHandle -ne [IntPtr]::Zero } 'the stand-in Claude window'

    # 1. Add Bob side by side.
    Start-Process $Exe -ArgumentList '--add-account', 'Bob' | Out-Null
    Wait-Until { (Claudes).Count -ge 2 } "Bob's Claude to start"
    if ($first.HasExited) { throw 'the first Claude was closed; side by side must leave it open' }
    $bob = Claudes | Where-Object { $_.CommandLine -match '--user-data-dir' }
    if (-not $bob) { throw "Bob's Claude was started without --user-data-dir" }
    $profileFolder = @(Get-ChildItem $env:LOCALAPPDATA -Directory -Filter 'Clatch-*')
    if ($profileFolder.Count -ne 1) { throw "expected one profile folder, found $($profileFolder.Count)" }
    if ($bob.CommandLine -notlike "*$($profileFolder[0].FullName)*") { throw "Bob's Claude does not use $($profileFolder[0].FullName): $($bob.CommandLine)" }
    Wait-Until { Test-Path (Join-Path $desktop 'Claude - Bob.lnk') } "Bob's Desktop shortcut"
    if (-not (Test-Path (Join-Path $startMenu 'Claude - Bob.lnk'))) { throw "Bob's Start menu shortcut is missing" }
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut((Join-Path $desktop 'Claude - Bob.lnk'))
    if ($link.Arguments -notmatch '^--launch [0-9a-f-]{36}$') { throw "unexpected shortcut arguments: $($link.Arguments)" }
    'step 1 ok: Bob started side by side with his own folder; shortcuts created'

    # 2. Bob's shortcut while Bob's Claude is open: no third Claude.
    $state = Get-Content (Join-Path $clatch 'accounts.json') -Raw | ConvertFrom-Json
    $bobId = ($state.accounts | Where-Object { $_.name -eq 'Bob' }).id
    $aliceId = $state.activeId
    if (-not $bobId -or -not $aliceId) { throw 'accounts.json does not have both profiles' }
    Start-Process $Exe -ArgumentList '--launch', $bobId | Out-Null
    Start-Sleep 4
    if ((Claudes).Count -ne 2) { throw "expected 2 Claudes after opening Bob again, found $((Claudes).Count)" }
    'step 2 ok: opening an open profile brings it forward instead of starting another Claude'

    # 3. Close the first Claude; its shortcut starts it again on Claude's own folder.
    Stop-Process -Id $first.Id -Force
    Wait-Until { (Claudes).Count -eq 1 } 'the first Claude to end'
    Start-Process $Exe -ArgumentList '--launch', $aliceId | Out-Null
    Wait-Until { (Claudes).Count -eq 2 } 'the first profile to start again'
    $own = Claudes | Where-Object { $_.CommandLine -notmatch '--user-data-dir' }
    if (-not $own) { throw "the first profile's Claude should run on Claude's own folder (no --user-data-dir)" }
    'step 3 ok: the first profile started again on Claude''s own folder'
    'side by side test passed'
}
finally {
    Get-Process claude, Clatch -ErrorAction SilentlyContinue | Stop-Process -Force
    '---- clatch.log ----'
    if (Test-Path $log) { Get-Content $log } else { '(no log written)' }
}
