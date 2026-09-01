[CmdletBinding()]
param(
  [ValidateSet('all', 'android', 'windows')]
  [string]$Target = 'all',
  [switch]$AllowDebugSigning,
  [string]$AndroidFlutter
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'generate_sdk.ps1')
$releaseAssetVerifier = Join-Path $PSScriptRoot 'verify_release_assets.ps1'
$releaseAssetSnapshot = Join-Path $repoRoot 'build\release-assets-snapshot.json'
& $releaseAssetVerifier `
  -Action preflight `
  -Snapshot $releaseAssetSnapshot
$pubspec = Get-Content -LiteralPath (Join-Path $repoRoot 'pubspec.yaml') -Encoding UTF8
$versionLine = $pubspec | Where-Object { $_ -match '^version:\s*(\S+)\s*$' } | Select-Object -First 1
if (-not $versionLine -or $versionLine -notmatch '^version:\s*([^+\s]+)\+(\d+)\s*$') {
  throw 'pubspec.yaml version must use MAJOR.MINOR.PATCH+BUILD.'
}

$versionName = $matches[1]
$buildNumber = $matches[2]
$artifactPrefix = "Playmesh-$versionName-build$buildNumber"
$releaseDir = Join-Path $repoRoot "release\$versionName"
$appResourceDir = Join-Path $repoRoot 'resources\app'
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

$buildAndroid = $Target -in @('all', 'android')
$buildWindows = $Target -in @('all', 'windows')
$artifacts = [System.Collections.Generic.List[string]]::new()

function Assert-ReleaseAssets {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Artifact,
    [Parameter(Mandatory = $true)]
    [ValidateSet('windows', 'android')]
    [string]$Kind
  )

  try {
    & $releaseAssetVerifier `
      -Action verify `
      -Snapshot $releaseAssetSnapshot `
      -Artifact $Artifact `
      -Kind $Kind
  } catch {
    if (Test-Path -LiteralPath $Artifact -PathType Leaf) {
      $resolvedArtifact = (Resolve-Path -LiteralPath $Artifact).Path
      $resolvedRelease = (Resolve-Path -LiteralPath $releaseDir).Path
      if ($resolvedArtifact.StartsWith(
          $resolvedRelease + [IO.Path]::DirectorySeparatorChar,
          [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedArtifact -Force
      }
    }
    throw
  }
}

function Resolve-AndroidFlutter {
  param([string]$ConfiguredPath)

  $candidate = $ConfiguredPath
  if (-not $candidate) {
    $candidate = $env:PLAYMESH_ANDROID_FLUTTER
  }
  if (-not $candidate) {
    $officialRuntimeSdk = 'D:\KaiFaTool\runtime\flutter'
    if (Test-Path -LiteralPath $officialRuntimeSdk -PathType Container) {
      $candidate = $officialRuntimeSdk
    }
  }
  if (-not $candidate) {
    $command = Get-Command flutter.bat -ErrorAction SilentlyContinue
    if ($command) {
      $candidate = $command.Source
    }
  }
  if (-not $candidate) {
    throw 'Standard Flutter was not found. Pass -AndroidFlutter or set PLAYMESH_ANDROID_FLUTTER.'
  }

  if (Test-Path -LiteralPath $candidate -PathType Container) {
    $candidate = Join-Path $candidate 'bin\flutter.bat'
  }
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    throw "Standard Flutter executable was not found: $candidate"
  }

  return (Resolve-Path -LiteralPath $candidate).Path
}

function Resolve-FlutterInvocation {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FlutterBatch
  )

  if ($env:FLUTTER_ALREADY_LOCKED -ne 'true') {
    return [pscustomobject]@{
      Command = $FlutterBatch
      PrefixArguments = @()
    }
  }

  $flutterRoot = [IO.Path]::GetFullPath(
    (Join-Path (Split-Path -Parent $FlutterBatch) '..')
  )
  $dart = Join-Path $flutterRoot 'bin\cache\dart-sdk\bin\dart.exe'
  $packageConfig = Join-Path $flutterRoot `
    'packages\flutter_tools\.dart_tool\package_config.json'
  $snapshot = Join-Path $flutterRoot 'bin\cache\flutter_tools.snapshot'
  foreach ($required in @($dart, $packageConfig, $snapshot)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
      throw "Flutter SDK reentrant entry point is missing: $required"
    }
  }

  return [pscustomobject]@{
    Command = $dart
    PrefixArguments = @("--packages=$packageConfig", $snapshot)
  }
}

if ($buildAndroid) {
  $keyProperties = Join-Path $repoRoot 'android\key.properties'
  if ((-not (Test-Path -LiteralPath $keyProperties)) -and (-not $AllowDebugSigning)) {
    throw 'Missing android/key.properties. Use a production key or explicitly pass -AllowDebugSigning for an internal build.'
  }

  $androidFlutterExecutable = Resolve-AndroidFlutter $AndroidFlutter
  $androidFlutterInvocation = Resolve-FlutterInvocation $androidFlutterExecutable
  $androidFlutterRoot = Split-Path -Parent (Split-Path -Parent $androidFlutterExecutable)
  $androidLocalPropertiesPath = Join-Path $repoRoot 'android\local.properties'
  $androidLocalProperties = if (Test-Path -LiteralPath $androidLocalPropertiesPath) {
    [IO.File]::ReadAllText($androidLocalPropertiesPath)
  } else {
    ''
  }
  $flutterSdkProperty = 'flutter.sdk=' + ($androidFlutterRoot -replace '\\', '/')
  if ($androidLocalProperties -match '(?m)^flutter\.sdk=.*$') {
    $androidLocalProperties = [Regex]::Replace(
      $androidLocalProperties,
      '(?m)^flutter\.sdk=.*$',
      $flutterSdkProperty,
      1
    )
  } else {
    if ($androidLocalProperties.Length -gt 0 -and
        -not $androidLocalProperties.EndsWith("`n")) {
      $androidLocalProperties += [Environment]::NewLine
    }
    $androidLocalProperties += $flutterSdkProperty + [Environment]::NewLine
  }
  [IO.File]::WriteAllText(
    $androidLocalPropertiesPath,
    $androidLocalProperties,
    [Text.UTF8Encoding]::new($false)
  )

  & (Join-Path $PSScriptRoot 'build_go_core.ps1') -Target android
  if ($LASTEXITCODE -ne 0) {
    throw "Android Go Core build failed: $LASTEXITCODE"
  }

  Write-Output "Android Flutter: $androidFlutterExecutable"
  $androidFlutterArguments = @($androidFlutterInvocation.PrefixArguments) + @(
    'build', 'apk', '--release', '--no-pub'
  )
  & $androidFlutterInvocation.Command @androidFlutterArguments
  if ($LASTEXITCODE -ne 0) {
    throw "Android release build failed: $LASTEXITCODE"
  }

  $apkSource = Join-Path $repoRoot 'build\app\outputs\flutter-apk\app-release.apk'
  $apkArtifact = Join-Path $releaseDir "$artifactPrefix-android-universal.apk"
  Copy-Item -LiteralPath $apkSource -Destination $apkArtifact -Force
  Assert-ReleaseAssets -Artifact $apkArtifact -Kind android
  $artifacts.Add($apkArtifact)
  New-Item -ItemType Directory -Force -Path $appResourceDir | Out-Null
  Copy-Item -LiteralPath $apkArtifact `
    -Destination (Join-Path $appResourceDir 'playmesh.apk') `
    -Force

  $androidSdkRoot = $env:ANDROID_SDK_ROOT
  if (-not $androidSdkRoot) {
    $androidSdkRoot = $env:ANDROID_HOME
  }
  if (-not $androidSdkRoot) {
    $localProperties = Get-Content -LiteralPath (Join-Path $repoRoot 'android\local.properties') -Encoding UTF8
    $sdkLine = $localProperties | Where-Object { $_ -match '^sdk\.dir=(.+)$' } | Select-Object -First 1
    if ($sdkLine -and $sdkLine -match '^sdk\.dir=(.+)$') {
      $androidSdkRoot = $matches[1] -replace '\\\\', '\'
    }
  }
  if (-not $androidSdkRoot) {
    throw 'Android SDK was not found; APK signing cannot be verified.'
  }

  $apkSigner = Get-ChildItem (Join-Path $androidSdkRoot 'build-tools') `
    -Recurse -Filter apksigner.bat |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
  if (-not $apkSigner) {
    throw 'apksigner.bat was not found in the Android SDK.'
  }
  & $apkSigner verify --verbose $apkArtifact
  if ($LASTEXITCODE -ne 0) {
    throw "APK signature verification failed: $LASTEXITCODE"
  }
}

if ($buildWindows) {
  & (Join-Path $PSScriptRoot 'build_go_core.ps1') -Target windows
  if ($LASTEXITCODE -ne 0) {
    throw "Windows Go dependencies build failed: $LASTEXITCODE"
  }

  & (Join-Path $PSScriptRoot 'build_windows_release_ninja.ps1') `
    -ReleaseAssetSnapshot $releaseAssetSnapshot `
    -SkipReleaseAssetPreflight `
    -SkipSdkGeneration
  if ($LASTEXITCODE -ne 0) {
    throw "Windows release build failed: $LASTEXITCODE"
  }

  $windowsBundle = Join-Path $repoRoot 'build\windows\x64-ninja\runner\Release'
  $apkSignerSidecar = Join-Path $repoRoot 'build\go-core\windows\playmesh-apksign.exe'
  if (-not (Test-Path -LiteralPath $apkSignerSidecar -PathType Leaf)) {
    throw "Windows APK signer sidecar is missing: $apkSignerSidecar"
  }
  Copy-Item -LiteralPath $apkSignerSidecar `
    -Destination (Join-Path $windowsBundle 'playmesh-apksign.exe') `
    -Force
  foreach ($noticeName in @(
      'APKSIG-GO-LICENSE.txt',
      'APKSIG-GO-NOTICE.txt',
      'WINRES-LICENSE.txt',
      'NFNT-RESIZE-LICENSE.txt',
      'GOLANG-X-IMAGE-LICENSE.txt',
      'GOLANG-X-IMAGE-PATENTS.txt')) {
    $noticeSource = Join-Path $repoRoot "build\go-core\windows\$noticeName"
    if (-not (Test-Path -LiteralPath $noticeSource -PathType Leaf)) {
      throw "Windows APK signer attribution is missing: $noticeSource"
    }
    Copy-Item -LiteralPath $noticeSource `
      -Destination (Join-Path $windowsBundle $noticeName) `
      -Force
  }
  $windowsArtifact = Join-Path $releaseDir "$artifactPrefix-windows-x64-portable.zip"
  Compress-Archive -Path (Join-Path $windowsBundle '*') `
    -DestinationPath $windowsArtifact `
    -CompressionLevel Optimal `
    -Force

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [IO.Compression.ZipFile]::OpenRead($windowsArtifact)
  try {
    $entryNames = $archive.Entries.FullName -replace '\\', '/'
    foreach ($requiredEntry in @(
        'playmesh.exe',
        'playmesh-core.exe',
        'playmesh-cli.exe',
        'playmesh-apksign.exe',
        'APKSIG-GO-LICENSE.txt',
        'APKSIG-GO-NOTICE.txt',
        'WINRES-LICENSE.txt',
        'NFNT-RESIZE-LICENSE.txt',
        'GOLANG-X-IMAGE-LICENSE.txt',
        'GOLANG-X-IMAGE-PATENTS.txt',
        'LICENSE',
        'flutter_windows.dll',
        'WebView2Loader.dll',
        'data/app.so',
        'data/icudtl.dat',
        'data/flutter_assets/assets/runtime-export/playmesh-default-export.p12')) {
      if ($entryNames -notcontains $requiredEntry) {
        throw "Windows ZIP is missing a runtime entry: $requiredEntry"
      }
    }
  } finally {
    $archive.Dispose()
  }
  Assert-ReleaseAssets -Artifact $windowsArtifact -Kind windows
  $artifacts.Add($windowsArtifact)
  New-Item -ItemType Directory -Force -Path $appResourceDir | Out-Null
  Copy-Item -LiteralPath $windowsArtifact `
    -Destination (Join-Path $appResourceDir 'playmesh.zip') `
    -Force
}

Write-Output 'Release artifacts:'
foreach ($artifact in $artifacts) {
  $hash = Get-FileHash -LiteralPath $artifact -Algorithm SHA256
  Write-Output "$($hash.Hash)  $artifact"
}
