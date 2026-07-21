[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$vsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vsWhere)) {
  throw "Missing Visual Studio Installer tool: $vsWhere"
}

$visualStudioRoot = (& $vsWhere `
  -latest `
  -products '*' `
  -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
  -property installationPath).Trim()
if (-not $visualStudioRoot) {
  throw 'Visual Studio with Desktop development with C++ was not found.'
}

$vcVars = Join-Path $visualStudioRoot 'VC\Auxiliary\Build\vcvars64.bat'
$cmake = Join-Path $visualStudioRoot 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
$ninja = Join-Path $visualStudioRoot 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'
$buildDir = Join-Path $repoRoot 'build\windows\x64-ninja'
$bundleDir = Join-Path $buildDir 'runner\Release'

foreach ($requiredTool in @($vcVars, $cmake, $ninja)) {
  if (-not (Test-Path -LiteralPath $requiredTool)) {
    throw "Missing Windows build tool: $requiredTool"
  }
}

$environmentCommand = 'call "' + $vcVars + '" >nul && set'
$environmentLines = & $env:ComSpec /d /c $environmentCommand
if ($LASTEXITCODE -ne 0) {
  throw "Failed to initialize the Visual Studio x64 environment: $LASTEXITCODE"
}

foreach ($line in $environmentLines) {
  if ($line -match '^([^=]+)=(.*)$') {
    [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
  }
}

# The desktop environment may already define CC/CXX for MSYS2. Pin the
# compiler so Ninja uses the same MSVC ABI as Flutter's Windows engine.
Remove-Item Env:CC -ErrorAction SilentlyContinue
Remove-Item Env:CXX -ErrorAction SilentlyContinue
$compiler = (Get-Command cl.exe -ErrorAction Stop).Source

if (Test-Path -LiteralPath $buildDir) {
  $resolvedBuildDir = (Resolve-Path -LiteralPath $buildDir).Path
  if (-not $resolvedBuildDir.StartsWith(
      $repoRoot + '\',
      [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean outside the workspace: $resolvedBuildDir"
  }
  Remove-Item -LiteralPath $resolvedBuildDir -Recurse -Force
}

& $cmake `
  -S (Join-Path $repoRoot 'windows') `
  -B $buildDir `
  -G Ninja `
  "-DCMAKE_BUILD_TYPE=Release" `
  "-DCMAKE_MAKE_PROGRAM=$ninja" `
  "-DCMAKE_C_COMPILER=$compiler" `
  "-DCMAKE_CXX_COMPILER=$compiler" `
  "-DCMAKE_INSTALL_PREFIX=$bundleDir" `
  "-DFLUTTER_TARGET_PLATFORM=windows-x64"
if ($LASTEXITCODE -ne 0) {
  throw "CMake configure failed: $LASTEXITCODE"
}

& $cmake --build $buildDir --target install
if ($LASTEXITCODE -ne 0) {
  throw "Windows release build failed: $LASTEXITCODE"
}

Write-Output "Windows Release bundle: $bundleDir"
