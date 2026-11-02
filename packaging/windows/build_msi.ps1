<#
.SYNOPSIS
  Packages the Flutter Windows release folder into an MSI.

.DESCRIPTION
  Flutter has no Windows installer target, and the store-oriented MSIX is not
  what a sideloaded desktop build needs. This script wires up WiX 3:

    1. `heat` walks build\windows\x64\runner\Release and writes the component
       list, so every DLL and the whole data folder are captured.
    2. `candle` compiles that list together with Product.wxs.
    3. `light` links the .msi.

  Run it on Windows, after `flutter build windows --release` and
  `cargo build --release` inside rust\.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File packaging\windows\build_msi.ps1 `
      -Version 1.1.0
#>
param(
  [string]$ReleaseDir = "build\windows\x64\runner\Release",
  [string]$OutFile = "dist\Misaka-hrt-windows-x64.msi",
  [string]$Version = "1.1.0"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Find-WixTool([string]$name) {
  $cmd = Get-Command "$name.exe" -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $candidates = @(
    "${env:WIX}bin\$name.exe",
    "C:\Program Files (x86)\WiX Toolset v3.14\bin\$name.exe",
    "C:\Program Files (x86)\WiX Toolset v3.11\bin\$name.exe",
    "C:\Program Files\WiX Toolset v3.14\bin\$name.exe"
  )
  foreach ($path in $candidates) {
    if ($path -and (Test-Path $path)) { return $path }
  }
  throw "WiX tool '$name' was not found. Install it with: choco install wixtoolset"
}

$heat = Find-WixTool "heat"
$candle = Find-WixTool "candle"
$light = Find-WixTool "light"

$source = (Resolve-Path (Join-Path $root $ReleaseDir)).Path
if (-not (Test-Path (Join-Path $source "hrt_tracker.exe"))) {
  throw "No hrt_tracker.exe in $source - run 'flutter build windows --release' first."
}
if (-not (Test-Path (Join-Path $source "hrt_core.dll"))) {
  throw "No hrt_core.dll in $source - run 'cargo build --release' in rust\ first."
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("hrt-msi-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $work | Out-Null
$outPath = Join-Path $root $OutFile
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null

Write-Host "Harvesting $source"
& $heat dir $source -cg AppFiles -gg -g1 -srd -sreg -sfrag `
  -dr INSTALLFOLDER -var var.SourceDir -out (Join-Path $work "AppFiles.wxs")
if ($LASTEXITCODE -ne 0) { throw "heat failed" }

Write-Host "Compiling product"
& $candle -nologo -arch x64 "-dSourceDir=$source" "-dProductVersion=$Version" `
  -out (Join-Path $work "Product.wixobj") (Join-Path $root "packaging\windows\Product.wxs")
if ($LASTEXITCODE -ne 0) { throw "candle failed for Product.wxs" }

& $candle -nologo -arch x64 "-dSourceDir=$source" `
  -out (Join-Path $work "AppFiles.wixobj") (Join-Path $work "AppFiles.wxs")
if ($LASTEXITCODE -ne 0) { throw "candle failed for AppFiles.wxs" }

Write-Host "Linking $OutFile"
& $light -nologo -sval -out $outPath `
  (Join-Path $work "Product.wixobj") (Join-Path $work "AppFiles.wixobj")
if ($LASTEXITCODE -ne 0) { throw "light failed" }

Remove-Item -Recurse -Force $work
Write-Host ("Wrote {0} ({1:N1} MB)" -f $outPath, ((Get-Item $outPath).Length / 1MB))
