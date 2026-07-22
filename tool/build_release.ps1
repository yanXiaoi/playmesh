[CmdletBinding()]
param(
  [ValidateSet('all', 'harmony', 'android', 'windows')]
  [string]$Target = 'all',
  [switch]$AllowDebugSigning,
  [string]$HarmonyFlutter,
  [string]$HarmonySdk,
  [string]$HarmonyHvigor,
  [string]$HarmonyOhpm,
  [string]$HarmonyNdk,
  [string]$HarmonyGo,
  [string]$HarmonySigningProfile
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
$buildHarmony = $Target -in @('all', 'harmony')
$buildWindows = $Target -in @('all', 'windows')
$artifacts = [System.Collections.Generic.List[string]]::new()

function Resolve-HarmonyFlutter {
  param([string]$ConfiguredPath)

  $candidate = $ConfiguredPath
  if (-not $candidate) {
    $candidate = $env:PLAYMESH_HARMONY_FLUTTER
  }
  if (-not $candidate) {
    $officialRuntimeSdk = 'D:\KaiFaTool\runtime\flutter-oh-3.22.3'
    if (Test-Path -LiteralPath $officialRuntimeSdk -PathType Container) {
      $candidate = $officialRuntimeSdk
    }
  }
  if (-not $candidate) {
    $command = Get-Command flutter-ohos.bat -ErrorAction SilentlyContinue
    if ($command) {
      $candidate = $command.Source
    }
  }
  if (-not $candidate) {
    throw 'Harmony Flutter was not found. Pass -HarmonyFlutter or set PLAYMESH_HARMONY_FLUTTER to the Harmony Flutter 3.22.3 SDK directory/executable.'
  }

  if (Test-Path -LiteralPath $candidate -PathType Container) {
    $candidate = Join-Path $candidate 'bin\flutter.bat'
  }
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    throw "Harmony Flutter executable was not found: $candidate"
  }

  $flutterSdkRoot = Split-Path -Parent (Split-Path -Parent $candidate)
  $hapCommand = Join-Path $flutterSdkRoot 'packages\flutter_tools\lib\src\commands\build_hap.dart'
  if (-not (Test-Path -LiteralPath $hapCommand -PathType Leaf)) {
    throw "The configured Flutter SDK does not provide 'flutter build hap': $candidate"
  }
  return (Resolve-Path -LiteralPath $candidate).Path
}

function Remove-DirectoryWithRetry {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [int]$Attempts = 10
  )

  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    try {
      Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
      return
    } catch {
      if ($attempt -eq $Attempts) {
        throw
      }
      Start-Sleep -Milliseconds 750
    }
  }
}

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

if ($buildHarmony) {
  if ((-not $HarmonySigningProfile) -and (-not $AllowDebugSigning)) {
    throw 'Harmony production builds require -HarmonySigningProfile <build-profile.json5>. Pass -AllowDebugSigning only for internal test HAPs.'
  }

  $runtimeRoot = 'D:\KaiFaTool\runtime'
  $harmonySdkRoot = $HarmonySdk
  if (-not $harmonySdkRoot) {
    $harmonySdkRoot = $env:PLAYMESH_HARMONY_SDK
  }
  if (-not $harmonySdkRoot) {
    $harmonySdkRoot = Join-Path $runtimeRoot 'ohos-sdk-windows_linux-public'
  }
  if (-not (Test-Path -LiteralPath $harmonySdkRoot -PathType Container)) {
    throw "OpenHarmony SDK was not found: $harmonySdkRoot"
  }
  $harmonySdkRoot = (Resolve-Path -LiteralPath $harmonySdkRoot).Path

  $harmonyHvigorRoot = $HarmonyHvigor
  if (-not $harmonyHvigorRoot) {
    $harmonyHvigorRoot = $env:PLAYMESH_HVIGOR_HOME
  }
  if (-not $harmonyHvigorRoot) {
    $harmonyHvigorRoot = Join-Path $runtimeRoot 'oh-command-line-tools\hvigor'
  }
  $hvigorExecutable = Join-Path $harmonyHvigorRoot 'node_modules\@ohos\hvigor\bin\hvigor.js'
  if (-not (Test-Path -LiteralPath $hvigorExecutable -PathType Leaf)) {
    throw "Hvigor was not found: $hvigorExecutable"
  }
  $harmonyHvigorRoot = (Resolve-Path -LiteralPath $harmonyHvigorRoot).Path

  $harmonyOhpmBin = $HarmonyOhpm
  if (-not $harmonyOhpmBin) {
    $harmonyOhpmBin = $env:PLAYMESH_OHPM_BIN
  }
  if (-not $harmonyOhpmBin) {
    $harmonyOhpmBin = Join-Path $runtimeRoot 'oh-command-line-tools\ohpm\bin'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $harmonyOhpmBin 'ohpm.bat') -PathType Leaf)) {
    throw "OHPM was not found: $harmonyOhpmBin"
  }
  $harmonyOhpmBin = (Resolve-Path -LiteralPath $harmonyOhpmBin).Path

  $env:OS = 'Windows_NT'
  $env:OHOS_BASE_SDK_HOME = $harmonySdkRoot
  $env:OHOS_SDK_HOME = $harmonySdkRoot
  $env:HOS_SDK_HOME = $harmonySdkRoot
  $env:DEVECO_SDK_HOME = $harmonySdkRoot
  $env:PLAYMESH_HVIGOR_HOME = $harmonyHvigorRoot
  $env:GIT_CONFIG_COUNT = '1'
  $env:GIT_CONFIG_KEY_0 = 'core.longpaths'
  $env:GIT_CONFIG_VALUE_0 = 'true'
  $env:FLUTTER_GIT_URL = 'https://gitee.com/harmonycommando_flutter/flutter.git'
  $env:Path = "$harmonyOhpmBin;$env:Path"

  $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($nodeCommand) {
    $env:NODE_HOME = Split-Path -Parent $nodeCommand.Source
  }

  $harmonyFlutterExecutable = Resolve-HarmonyFlutter $HarmonyFlutter
  $harmonyFlutterBin = Split-Path -Parent $harmonyFlutterExecutable
  $env:Path = "$harmonyFlutterBin;$env:Path"
  & (Join-Path $PSScriptRoot 'build_go_core.ps1') `
    -Target harmony `
    -HarmonyNdk $HarmonyNdk `
    -HarmonyGo $HarmonyGo
  if ($LASTEXITCODE -ne 0) {
    throw "HarmonyOS Go Core build failed: $LASTEXITCODE"
  }
  $harmonyStage = Join-Path $repoRoot 'build\harmony-release'
  if (Test-Path -LiteralPath $harmonyStage) {
    $resolvedStage = (Resolve-Path -LiteralPath $harmonyStage).Path
    $resolvedBuild = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'build')).Path
    if (-not $resolvedStage.StartsWith($resolvedBuild + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to clean Harmony staging directory outside build/: $resolvedStage"
    }
    Remove-DirectoryWithRetry -Path $resolvedStage
  }
  New-Item -ItemType Directory -Force -Path $harmonyStage | Out-Null

  foreach ($directory in @('lib', 'assets', 'ohos')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot $directory) `
      -Destination $harmonyStage -Recurse -Force
  }
  Copy-Item -LiteralPath (Join-Path $repoRoot '.metadata') `
    -Destination (Join-Path $harmonyStage '.metadata') -Force
  Copy-Item -LiteralPath (Join-Path $repoRoot 'tool\harmony\pubspec.yaml') `
    -Destination (Join-Path $harmonyStage 'pubspec.yaml') -Force

  $harmonyPubspecPath = Join-Path $harmonyStage 'pubspec.yaml'
  $harmonyPubspec = [IO.File]::ReadAllText($harmonyPubspecPath)
  $harmonyPubspec = [Regex]::Replace(
    $harmonyPubspec,
    '(?m)^version:\s*\S+\s*$',
    "version: $versionName+$buildNumber",
    1
  )
  [IO.File]::WriteAllText(
    $harmonyPubspecPath,
    $harmonyPubspec,
    [Text.UTF8Encoding]::new($false)
  )

  $harmonyAppPath = Join-Path $harmonyStage 'ohos\AppScope\app.json5'
  $harmonyApp = [IO.File]::ReadAllText($harmonyAppPath)
  $harmonyApp = [Regex]::Replace($harmonyApp, '"versionCode"\s*:\s*\d+', "`"versionCode`": $buildNumber", 1)
  $harmonyApp = [Regex]::Replace($harmonyApp, '"versionName"\s*:\s*"[^"]+"', "`"versionName`": `"$versionName`"", 1)
  [IO.File]::WriteAllText(
    $harmonyAppPath,
    $harmonyApp,
    [Text.UTF8Encoding]::new($false)
  )

  $harmonyOverlay = Join-Path $repoRoot 'tool\harmony\overrides'
  Get-ChildItem -LiteralPath $harmonyOverlay -Recurse -File | ForEach-Object {
    $relative = $_.FullName.Substring($harmonyOverlay.Length).TrimStart('\', '/')
    $destination = Join-Path $harmonyStage $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
  }

  & (Join-Path $repoRoot 'tool\harmony\apply_flutter_322_compat.ps1') `
    -ProjectRoot $harmonyStage

  if ($HarmonySigningProfile) {
    $signingProfilePath = (Resolve-Path -LiteralPath $HarmonySigningProfile -ErrorAction Stop).Path
    Copy-Item -LiteralPath $signingProfilePath `
      -Destination (Join-Path $harmonyStage 'ohos\build-profile.json5') -Force
  }

  Push-Location $harmonyStage
  try {
    & $harmonyFlutterExecutable pub get
    if ($LASTEXITCODE -ne 0) {
      throw "Harmony dependency resolution failed: $LASTEXITCODE"
    }
    & $harmonyFlutterExecutable build hap --release --target-platform ohos-arm64 --no-pub
    if ($LASTEXITCODE -ne 0) {
      throw "Harmony release build failed: $LASTEXITCODE"
    }
  } finally {
    Pop-Location
  }

  $hapOutputDirectory = Join-Path $harmonyStage 'ohos\entry\build\default\outputs\default'
  $signedHap = Join-Path $hapOutputDirectory 'entry-default-signed.hap'
  $hapSource = $signedHap
  if (-not (Test-Path -LiteralPath $signedHap)) {
    if (-not $AllowDebugSigning) {
      throw "Harmony build did not produce the expected signed HAP: $signedHap"
    }
    $hapSource = Get-ChildItem -LiteralPath $hapOutputDirectory -Filter '*.hap' -File |
      Where-Object { $_.Name -match 'unsigned|default\.hap$' } |
      Sort-Object Name |
      Select-Object -First 1 -ExpandProperty FullName
    if (-not $hapSource) {
      throw "Harmony internal build did not produce a HAP in: $hapOutputDirectory"
    }
    Write-Warning "Using unsigned Harmony HAP for an explicitly allowed internal build: $hapSource"
  }
  $hapArtifact = Join-Path $releaseDir "$artifactPrefix-harmonyos-arm64.hap"
  Copy-Item -LiteralPath $hapSource -Destination $hapArtifact -Force

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $hapArchive = [IO.Compression.ZipFile]::OpenRead($hapArtifact)
  try {
    $hapEntries = $hapArchive.Entries.FullName -replace '\\', '/'
    foreach ($requiredEntry in @(
        'module.json',
        'resources.index',
        'libs/arm64-v8a/libapp.so',
        'libs/arm64-v8a/libplaymesh_core.so',
        'libs/arm64-v8a/libplaymesh_core_napi.so')) {
      if ($hapEntries -notcontains $requiredEntry) {
        throw "Harmony HAP is missing a runtime entry: $requiredEntry"
      }
    }
  } finally {
    $hapArchive.Dispose()
  }
  $artifacts.Add($hapArtifact)
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
