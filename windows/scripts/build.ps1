# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build Clatch for Windows: unit tests, x64 + ARM64 apps, one installer.
#
#   pwsh windows/scripts/build.ps1            # → windows/out/Clatch-<version>-windows-setup.exe
#   pwsh windows/scripts/build.ps1 -NoInstaller
#
# Needs the .NET 10 SDK, Visual Studio 2022+ C++ build tools (x64 and ARM64,
# for NativeAOT) and Inno Setup 6.3+ (iscc) for the installer.
param(
    [switch]$NoInstaller,
    [switch]$NoAot
)
$ErrorActionPreference = 'Stop'
$windows = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $windows
$version = (Get-Content (Join-Path $repo 'VERSION') -Raw).Trim()
$out = Join-Path $windows 'out'
Write-Host "==> Clatch $version for Windows" -ForegroundColor Green

Write-Host '==> Unit tests' -ForegroundColor Green
dotnet test (Join-Path $windows 'tests/Clatch.Core.Tests/Clatch.Core.Tests.csproj') -c Release
if ($LASTEXITCODE) { throw 'unit tests failed' }

$project = Join-Path $windows 'src/Clatch/Clatch.csproj'
foreach ($rid in 'win-x64', 'win-arm64') {
    $platform = if ($rid -eq 'win-x64') { 'x64' } else { 'ARM64' }
    $dir = Join-Path $out $rid
    Write-Host "==> Publishing $rid" -ForegroundColor Green
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    $aot = if ($NoAot) { 'false' } else { 'true' }
    dotnet publish $project -c Release -r $rid -p:Platform=$platform -p:ClatchAot=$aot -o $dir
    if ($LASTEXITCODE) { throw "publish $rid failed" }
    $exe = Join-Path $dir 'Clatch.exe'
    if (-not (Test-Path $exe)) { throw "$exe missing" }
    $size = (Get-ChildItem $dir -Recurse | Measure-Object Length -Sum).Sum / 1MB
    Write-Host ("    {0}: {1:N1} MB" -f $rid, $size)
}

if (-not $NoInstaller) {
    $iscc = (Get-Command iscc -ErrorAction SilentlyContinue)?.Source
    if (-not $iscc) { $iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" }
    if (-not (Test-Path $iscc)) { throw 'Inno Setup (iscc) not found' }
    Write-Host '==> Installer' -ForegroundColor Green
    & $iscc "/DVersion=$version" "/DX64Dir=$out\win-x64" "/DArm64Dir=$out\win-arm64" (Join-Path $windows 'installer/Clatch.iss')
    if ($LASTEXITCODE) { throw 'installer build failed' }
    $setup = Join-Path $out "Clatch-$version-windows-setup.exe"
    Get-FileHash -Algorithm SHA256 $setup | Format-List
    Write-Host "==> Built $setup" -ForegroundColor Green
}
