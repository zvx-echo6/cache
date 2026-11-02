# Download the official prebuilt libzim for Windows x86_64 into the build directory, verify its md5, unpack it.
# Never writes into the repository. Usage: fetch-libzim.ps1 -BuildDir E:\cs-build
# Versions, URLs and md5s are recorded in LIBZIM.md; keep the two in step.
param([Parameter(Mandatory = $true)][string]$BuildDir)
$ErrorActionPreference = 'Stop'
$ver = '9.8.2-1'
$name = "libzim_win-x86_64-$ver.zip"
$url = "https://download.openzim.org/release/libzim/$name"
$md5 = '6fec1bb98a7a628a2c38270414c521c1'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
$root = [System.IO.Path]::GetFullPath($BuildDir)
if ($root.StartsWith($repo, [System.StringComparison]::OrdinalIgnoreCase)) { throw "BuildDir must be outside the repository ($repo)" }
$base = Join-Path $root 'libzim'
New-Item -ItemType Directory -Force -Path $base | Out-Null
$zip = Join-Path $base $name
$dest = Join-Path $base "win-x86_64-$ver"
function Test-Md5($p) { (Test-Path $p) -and ((Get-FileHash -Algorithm MD5 -Path $p).Hash.ToLower() -eq $md5) }
if (-not (Test-Md5 $zip)) {
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    if (-not (Test-Md5 $zip)) { Remove-Item -Force $zip; throw "md5 mismatch for $name (want $md5)" }
}
if (-not (Test-Path (Join-Path $dest 'bin\zim-9.dll'))) {
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Expand-Archive -Path $zip -DestinationPath $dest
}
foreach ($f in 'bin\zim-9.dll', 'lib\zim.lib', 'include\zim\archive.h') {
    if (-not (Test-Path (Join-Path $dest $f))) { throw "missing $f in $dest" }
}
Write-Output "md5 ok: $name"
Write-Output "LIBZIM_DIR=$dest"
