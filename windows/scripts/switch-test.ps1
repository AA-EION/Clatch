# SPDX-License-Identifier: GPL-3.0-or-later
#
# End-to-end switch test for CI, against a stand-in for Claude Desktop:
#   * a small Windows app installed as %LOCALAPPDATA%\AnthropicClaude\claude.exe
#     (classic installer layout; it closes when Windows asks it to, like Claude);
#   * a Claude-style data folder in %APPDATA%\Claude.
# Then: "Clatch --add-account Bob" must close the stand-in politely, park the
# first account's data and reopen it; "Clatch --switch-next" must bring the
# first account back and park Bob's.
#
#   pwsh windows/scripts/switch-test.ps1 -Exe path\to\Clatch.exe
#
# -CustomDataDir: like current Microsoft Store versions of Claude, the stand-in
# is started with --user-data-dir pointing into %LOCALAPPDATA%\Claude-Data, and
# Clatch must follow it (and remember it once Claude restarts without the flag).
param([Parameter(Mandatory)] [string]$Exe, [switch]$CustomDataDir)
$ErrorActionPreference = 'Stop'

$classic = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
$fake = Join-Path $classic 'claude.exe'
$data = if ($CustomDataDir) { Join-Path $env:LOCALAPPDATA 'Claude-Data\claude_test' } else { Join-Path $env:APPDATA 'Claude' }
$clatch = Join-Path $env:LOCALAPPDATA 'Clatch'
$log = Join-Path $clatch 'clatch.log'

Get-Process claude, Clatch -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item $clatch, $classic, (Join-Path $env:APPDATA 'Claude'), (Join-Path $env:LOCALAPPDATA 'Claude-Data') -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $classic | Out-Null

# The stand-in: a WinForms window (WinForms closes on WM_QUERYENDSESSION/WM_ENDSESSION).
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

function Write-Account($name) {
    New-Item -ItemType Directory -Force $data | Out-Null
    Set-Content (Join-Path $data 'Local State') '{}'
    Set-Content (Join-Path $data 'config.json') '{}'
    Set-Content (Join-Path $data 'Cookies') $name -NoNewline
}

function Wait-Log($pattern, $count) {
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $log) {
            if (Select-String -Path $log -Pattern ' ERROR ' -Quiet) { throw 'Clatch logged an error' }
            if (@(Select-String -Path $log -Pattern $pattern).Count -ge $count) { return }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "timed out waiting for '$pattern' in the log"
}

function Stashed($name) {
    Get-ChildItem (Join-Path $clatch 'Accounts') -Recurse -Filter Cookies -ErrorAction SilentlyContinue |
        Where-Object { (Get-Content $_.FullName -Raw) -eq $name }
}

try {
    Write-Account 'alice'
    $claude = if ($CustomDataDir) { Start-Process $fake -ArgumentList "--user-data-dir=`"$data`"" -PassThru } else { Start-Process $fake -PassThru }
    Start-Sleep 3

    # 1. Add a second account: Claude must close, alice must be parked, Claude reopened.
    Start-Process $Exe -ArgumentList '--add-account', 'Bob' | Out-Null
    Wait-Log 'Switched:' 1
    Start-Sleep 2
    if (-not $claude.HasExited) { throw 'the stand-in Claude was not closed' }
    if (-not (Stashed 'alice')) { throw "alice's data was not parked in the accounts folder" }
    if (Test-Path (Join-Path $data 'Cookies')) { throw 'Claude''s data folder should be empty for the new account' }
    $reopened = Get-Process claude -ErrorAction SilentlyContinue
    if (-not $reopened) { throw 'Claude was not reopened after adding the account' }
    'step 1 ok: Claude closed, alice parked, Claude reopened'

    # 2. "Sign in" as Bob, then switch back: alice live again, Bob parked.
    Write-Account 'bob'
    Start-Process $Exe -ArgumentList '--switch-next' | Out-Null
    Wait-Log 'Switched:' 2
    Start-Sleep 2
    $live = Get-Content (Join-Path $data 'Cookies') -Raw
    if ($live -ne 'alice') { throw "expected alice's data to be live, found '$live'" }
    if (-not (Stashed 'bob')) { throw "Bob's data was not parked" }
    'step 2 ok: switched back to alice, Bob parked'
    if ($CustomDataDir -and -not (Select-String -Path $log -Pattern '--user-data-dir' -Quiet)) { throw 'Clatch did not read --user-data-dir' }
    "switch test passed (data in $data)"
}
finally {
    Get-Process claude, Clatch -ErrorAction SilentlyContinue | Stop-Process -Force
    '---- clatch.log ----'
    if (Test-Path $log) { Get-Content $log } else { '(no log written)' }
}
