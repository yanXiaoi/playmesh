[CmdletBinding()]
param(
  [string]$ReleaseAssetSnapshot,
  [switch]$SkipReleaseAssetPreflight,
  [switch]$SkipSdkGeneration,
  [switch]$ValidateToolchainOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $SkipSdkGeneration) {
  & (Join-Path $PSScriptRoot 'generate_sdk.ps1')
}
$releaseAssetVerifier = Join-Path $PSScriptRoot 'verify_release_assets.ps1'
if (-not $ReleaseAssetSnapshot) {
  $ReleaseAssetSnapshot = Join-Path $repoRoot 'build\release-assets-snapshot.json'
}
if (-not $SkipReleaseAssetPreflight) {
  & $releaseAssetVerifier `
    -Action preflight `
    -Snapshot $ReleaseAssetSnapshot
}
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

$originalPath = [Environment]::GetEnvironmentVariable('Path', 'Process')
$systemRoot = [Environment]::GetEnvironmentVariable('SystemRoot', 'Process')
if (-not $systemRoot) {
  $systemRoot = 'C:\Windows'
}
$bootstrapPath = @(
  (Join-Path $systemRoot 'System32')
  $systemRoot
  (Join-Path $systemRoot 'System32\Wbem')
  (Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0')
) -join ';'

# vcvars64.bat prepends several long Visual Studio paths. Starting it with an
# already large (or duplicated as PATH/Path) environment can exceed cmd.exe's
# 8191-character expanded-line limit. Bootstrap it with only Windows tools,
# then merge the caller's PATH back in PowerShell where that limit does not
# apply.
$environmentCommand = (
  'set "Path=" && set "PATH=' + $bootstrapPath +
  '" && call "' + $vcVars + '" >nul && set'
)
$environmentLines = & $env:ComSpec /d /c $environmentCommand
if ($LASTEXITCODE -ne 0) {
  throw "Failed to initialize the Visual Studio x64 environment: $LASTEXITCODE"
}

$visualStudioEnvironment =
  [Collections.Generic.Dictionary[string, string]]::new(
    [StringComparer]::OrdinalIgnoreCase
  )
foreach ($line in $environmentLines) {
  if ($line -match '^([^=]+)=(.*)$') {
    $visualStudioEnvironment[$matches[1]] = $matches[2]
  }
}

foreach ($entry in $visualStudioEnvironment.GetEnumerator()) {
  if ($entry.Key -ine 'Path') {
    [Environment]::SetEnvironmentVariable(
      $entry.Key,
      $entry.Value,
      'Process'
    )
  }
}

$visualStudioPath = $visualStudioEnvironment['Path']
if (-not $visualStudioPath) {
  throw 'Visual Studio environment did not define PATH.'
}
$seenPathEntries =
  [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$mergedPathEntries = [Collections.Generic.List[string]]::new()
foreach ($pathEntry in @(
    ($visualStudioPath -split ';')
    ($originalPath -split ';')
  )) {
  if ([string]::IsNullOrWhiteSpace($pathEntry)) {
    continue
  }
  $trimmedPathEntry = $pathEntry.Trim()
  if ($seenPathEntries.Add($trimmedPathEntry)) {
    $mergedPathEntries.Add($trimmedPathEntry)
  }
}
[Environment]::SetEnvironmentVariable(
  'Path',
  ($mergedPathEntries -join ';'),
  'Process'
)

# The desktop environment may already define CC/CXX for MSYS2. Pin the
# compiler so Ninja uses the same MSVC ABI as Flutter's Windows engine.
Remove-Item Env:CC -ErrorAction SilentlyContinue
Remove-Item Env:CXX -ErrorAction SilentlyContinue
$compiler = (Get-Command cl.exe -ErrorAction Stop).Source

if ($ValidateToolchainOnly) {
  Write-Output "Visual Studio x64 environment: $compiler"
  return
}

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

try {
  & $releaseAssetVerifier `
    -Action verify `
    -Snapshot $ReleaseAssetSnapshot `
    -Artifact $bundleDir `
    -Kind windows
} catch {
  if (Test-Path -LiteralPath $bundleDir -PathType Container) {
    $resolvedBundle = (Resolve-Path -LiteralPath $bundleDir).Path
    $resolvedBuild = (Resolve-Path -LiteralPath $buildDir).Path
    if ($resolvedBundle.StartsWith(
        $resolvedBuild + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $resolvedBundle -Recurse -Force
    }
  }
  throw
}

Write-Output "Windows Release bundle: $bundleDir"
