[CmdletBinding()]
param(
  [ValidateSet('all', 'android', 'windows')]
  [string]$Target = 'all',
  [switch]$AllowDebugSigning
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'generate_sdk.ps1')
$pubspec = Get-Content -LiteralPath (Join-Path $repoRoot 'pubspec.yaml') -Encoding UTF8
$versionLine = $pubspec | Where-Object { $_ -match '^version:\s*(\S+)\s*$' } | Select-Object -First 1
if (-not $versionLine -or $versionLine -notmatch '^version:\s*([^+\s]+)\+(\d+)\s*$') {
  throw 'pubspec.yaml version must use MAJOR.MINOR.PATCH+BUILD.'
}

$versionName = $matches[1]
$buildNumber = $matches[2]
$artifactPrefix = "Playmesh-$versionName-build$buildNumber"
$releaseDir = Join-Path $repoRoot "release\$versionName"
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

$buildAndroid = $Target -in @('all', 'android')
$buildWindows = $Target -in @('all', 'windows')
$artifacts = [System.Collections.Generic.List[string]]::new()

if ($buildAndroid) {
  $keyProperties = Join-Path $repoRoot 'android\key.properties'
  if ((-not (Test-Path -LiteralPath $keyProperties)) -and (-not $AllowDebugSigning)) {
    throw 'Missing android/key.properties. Use a production key or explicitly pass -AllowDebugSigning for an internal build.'
  }

  $flutter = (Get-Command flutter.bat -ErrorAction Stop).Source
  & $flutter build apk --release --no-pub
  if ($LASTEXITCODE -ne 0) {
    throw "Android release build failed: $LASTEXITCODE"
  }

  $apkSource = Join-Path $repoRoot 'build\app\outputs\flutter-apk\app-release.apk'
  $apkArtifact = Join-Path $releaseDir "$artifactPrefix-android-universal.apk"
  Copy-Item -LiteralPath $apkSource -Destination $apkArtifact -Force
  $artifacts.Add($apkArtifact)

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
  & (Join-Path $PSScriptRoot 'build_windows_release_ninja.ps1')
  if ($LASTEXITCODE -ne 0) {
    throw "Windows release build failed: $LASTEXITCODE"
  }

  $windowsBundle = Join-Path $repoRoot 'build\windows\x64-ninja\runner\Release'
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
        'flutter_windows.dll',
        'WebView2Loader.dll',
        'data/app.so',
        'data/icudtl.dat')) {
      if ($entryNames -notcontains $requiredEntry) {
        throw "Windows ZIP is missing a runtime entry: $requiredEntry"
      }
    }
  } finally {
    $archive.Dispose()
  }
  $artifacts.Add($windowsArtifact)
}

Write-Output 'Release artifacts:'
foreach ($artifact in $artifacts) {
  $hash = Get-FileHash -LiteralPath $artifact -Algorithm SHA256
  Write-Output "$($hash.Hash)  $artifact"
}
