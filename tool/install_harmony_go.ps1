[CmdletBinding()]
param(
  [string]$InstallRoot = 'D:\KaiFaTool\runtime\go',
  [string]$BootstrapGo = 'D:\KaiFaTool\runtime\go\go-1.26.2',
  [string]$SourceDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoUrl = 'https://gitcode.com/openharmony-sig/ohos_golang_go.git'
$releaseTag = 'go1.24.5.ohosv1r1'
$releaseCommit = '2d8b23f6923100d8c90d8add9299da2c9d032a20'
$installDirectory = Join-Path $InstallRoot 'go-1.24.5-openharmony'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $SourceDirectory) {
  $SourceDirectory = Join-Path $projectRoot 'build\toolchains\ohos-go-src'
}

function Resolve-GoExecutable {
  param([string]$Path)

  if (Test-Path -LiteralPath $Path -PathType Container) {
    return Join-Path $Path 'bin\go.exe'
  }
  return $Path
}

function Assert-OpenHarmonyGo {
  param([string]$Executable)

  if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
    return $false
  }
  $version = & $Executable version 2>&1 | Out-String
  $targets = & $Executable tool dist list 2>&1 | Out-String
  return $LASTEXITCODE -eq 0 -and
    $version -match '\bgo1\.24\.5\b' -and
    $targets -match '(?m)^openharmony/arm64\s*$'
}

$installedGo = Resolve-GoExecutable $installDirectory
if (Assert-OpenHarmonyGo $installedGo) {
  Write-Output "OpenHarmony Go is already installed: $installDirectory"
  & $installedGo version
  exit 0
}
if (Test-Path -LiteralPath $installDirectory) {
  throw "The destination exists but is not the expected OpenHarmony Go toolchain: $installDirectory"
}

$bootstrapExecutable = Resolve-GoExecutable $BootstrapGo
if (-not (Test-Path -LiteralPath $bootstrapExecutable -PathType Leaf)) {
  throw "Bootstrap Go was not found: $bootstrapExecutable"
}

if (-not (Test-Path -LiteralPath $SourceDirectory)) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SourceDirectory) | Out-Null
  & git clone --branch $releaseTag --depth 1 $repoUrl $SourceDirectory
  if ($LASTEXITCODE -ne 0) {
    throw 'Unable to clone the OpenHarmony SIG Go source.'
  }
}

$actualCommit = (& git -C $SourceDirectory rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $releaseCommit) {
  throw "OpenHarmony Go source must be pinned to $releaseTag ($releaseCommit); found $actualCommit"
}

$savedBootstrap = $env:GOROOT_BOOTSTRAP
$env:GOROOT_BOOTSTRAP = Split-Path -Parent (Split-Path -Parent $bootstrapExecutable)
Push-Location (Join-Path $SourceDirectory 'src')
try {
  & .\make.bat
  if ($LASTEXITCODE -ne 0) {
    throw 'OpenHarmony Go bootstrap build failed.'
  }
} finally {
  Pop-Location
  $env:GOROOT_BOOTSTRAP = $savedBootstrap
}

$builtGo = Resolve-GoExecutable $SourceDirectory
if (-not (Assert-OpenHarmonyGo $builtGo)) {
  throw 'The built Go toolchain does not provide openharmony/arm64.'
}

New-Item -ItemType Directory -Force -Path $installDirectory | Out-Null
Get-ChildItem -LiteralPath $SourceDirectory -Force |
  Where-Object Name -ne '.git' |
  Copy-Item -Destination $installDirectory -Recurse -Force

if (-not (Assert-OpenHarmonyGo $installedGo)) {
  throw "Installed OpenHarmony Go verification failed: $installedGo"
}
Write-Output "Installed OpenHarmony Go: $installDirectory"
& $installedGo version
