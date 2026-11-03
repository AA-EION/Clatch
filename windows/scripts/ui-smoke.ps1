# SPDX-License-Identifier: GPL-3.0-or-later
#
# UI smoke test for CI: start Clatch, open its panel and its right-click
# menu exactly as a click on the notification area icon does (by posting the
# icon's callback message to Clatch's hidden window), take screenshots and
# fail if the panel did not open.
#
#   pwsh windows/scripts/ui-smoke.ps1 -Exe path\to\Clatch.exe -Shots out\shots
param(
    [Parameter(Mandatory)] [string]$Exe,
    [string]$Shots = 'shots'
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Shots | Out-Null
$log = Join-Path $env:LOCALAPPDATA 'Clatch\clatch.log'
Remove-Item $log -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Win {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string name);
    [DllImport("user32.dll")]
    public static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
}
'@

function Shot($name) {
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bitmap.Save((Join-Path $Shots "$name.png"))
    $graphics.Dispose(); $bitmap.Dispose()
}

$p = Start-Process $Exe -PassThru
Start-Sleep 6
if ($p.HasExited) { throw "Clatch exited early (code $($p.ExitCode))" }
$hwnd = [Win]::FindWindowExW([IntPtr]::Zero, [IntPtr]::Zero, 'ClatchTrayWindow', $null)
if ($hwnd -eq [IntPtr]::Zero) { throw 'Clatch''s notification area window was not found' }

# Left click on the icon: callback message WM_APP+1, LOWORD(lParam) = NIN_SELECT,
# wParam = the click point (x | y << 16) near the bottom-right corner.
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$point = [IntPtr](($screen.Width - 120) -bor (($screen.Height - 20) -shl 16))
[Win]::PostMessageW($hwnd, 0x8001, $point, [IntPtr]0x400) | Out-Null
Start-Sleep 4
Shot 'panel'

# Second launch: asks the running Clatch to show its panel, then exits.
$second = Start-Process $Exe -PassThru
$second.WaitForExit(10000) | Out-Null
"second instance exit code: $($second.ExitCode)"

# Right click: the classic context menu.
[Win]::PostMessageW($hwnd, 0x8001, $point, [IntPtr]0x7B) | Out-Null
Start-Sleep 3
Shot 'menu'
$p.Refresh()
"resident memory with the panel open: {0:N1} MB" -f ($p.WorkingSet64 / 1MB)
Stop-Process $p -ErrorAction SilentlyContinue

"---- clatch.log ----"
Get-Content $log
if (Select-String -Path $log -Pattern '^.* ERROR ' -Quiet) { throw 'Clatch logged an error' }
if (-not (Select-String -Path $log -Pattern 'Panel shown' -Quiet)) { throw 'the panel did not open' }
'UI smoke test passed'
