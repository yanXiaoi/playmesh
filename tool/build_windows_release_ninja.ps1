[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'generate_sdk.ps1')
$pubspec = Get-Content -LiteralPath (Join-Path $repoRoot 'pubspec.yaml') -Encoding UTF8
$versionLine = $pubspec | Where-Object { $_ -match '^version:\s*(\S+)\s*$' } | Select-Object -First 1
if (-not $versionLine -or
    $versionLine -notmatch '^version:\s*((\d+)\.(\d+)\.(\d+))\+(\d+)\s*$') {
  throw 'pubspec.yaml version must use MAJOR.MINOR.PATCH+BUILD.'
}
$versionName = $matches[1]
$versionMajor = $matches[2]
$versionMinor = $matches[3]
$versionPatch = $matches[4]
$buildNumber = $matches[5]
$version = "$versionName+$buildNumber"
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

$flutterAssetsDir = Join-Path $repoRoot 'build\flutter_assets'
if (Test-Path -LiteralPath $flutterAssetsDir) {
  $resolvedFlutterAssetsDir = (Resolve-Path -LiteralPath $flutterAssetsDir).Path
  $expectedBuildRoot = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'build')).Path
  if (-not $resolvedFlutterAssetsDir.StartsWith(
      $expectedBuildRoot + '\',
      [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean Flutter assets outside build/: $resolvedFlutterAssetsDir"
  }
  Remove-Item -LiteralPath $resolvedFlutterAssetsDir -Recurse -Force
}

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
  "-DFLUTTER_TARGET_PLATFORM=windows-x64" `
  "-DPLAYMESH_FLUTTER_VERSION=$version" `
  "-DPLAYMESH_FLUTTER_VERSION_MAJOR=$versionMajor" `
  "-DPLAYMESH_FLUTTER_VERSION_MINOR=$versionMinor" `
  "-DPLAYMESH_FLUTTER_VERSION_PATCH=$versionPatch" `
  "-DPLAYMESH_FLUTTER_VERSION_BUILD=$buildNumber"
if ($LASTEXITCODE -ne 0) {
  throw "CMake configure failed: $LASTEXITCODE"
}

& $cmake --build $buildDir --target install
if ($LASTEXITCODE -ne 0) {
  throw "Windows release build failed: $LASTEXITCODE"
}

Write-Output "Windows Release bundle: $bundleDir"
