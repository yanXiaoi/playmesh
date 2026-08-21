[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$verifier = Join-Path $PSScriptRoot 'verify_release_assets.ps1'
$testRoot = Join-Path $repoRoot (
  'build\test-release-runtime-asset-gate-' + [guid]::NewGuid().ToString('N')
)
$snapshotPath = Join-Path $testRoot 'snapshot.json'
$defaultExportKey = Join-Path $repoRoot (
  'assets\runtime-export\playmesh-default-export.p12'
)

function New-ValidBundleSource {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$FlutterAssetsRelativeRoot,
    [Parameter(Mandatory = $true)]$Snapshot
  )

  $flutterAssetsRoot = Join-Path $Root $FlutterAssetsRelativeRoot
  New-Item -ItemType Directory -Path $flutterAssetsRoot -Force | Out-Null
  foreach ($file in @($Snapshot.files)) {
    $source = Join-Path $repoRoot ($file.path -replace '/', '\')
    $destination = Join-Path $flutterAssetsRoot ($file.path -replace '/', '\')
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force |
      Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
  }

  # This key is intentionally allowed; only compiled Runtime base packages are
  # forbidden from the main App's flutter_assets tree.
  $keyDestination = Join-Path $flutterAssetsRoot (
    'assets\runtime-export\playmesh-default-export.p12'
  )
  New-Item -ItemType Directory -Path (Split-Path -Parent $keyDestination) -Force |
    Out-Null
  Copy-Item -LiteralPath $defaultExportKey -Destination $keyDestination -Force
}

function New-TestArchive {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
  )

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  if (Test-Path -LiteralPath $Destination -PathType Leaf) {
    Remove-Item -LiteralPath $Destination -Force
  }
  [IO.Compression.ZipFile]::CreateFromDirectory(
    $Source,
    $Destination,
    [IO.Compression.CompressionLevel]::Fastest,
    $false
  )
}

function Assert-ArtifactAccepted {
  param(
    [Parameter(Mandatory = $true)][string]$Artifact,
    [Parameter(Mandatory = $true)][ValidateSet('windows', 'android')]
    [string]$Kind
  )

  & $verifier `
    -Action verify `
    -Snapshot $snapshotPath `
    -Artifact $Artifact `
    -Kind $Kind
}

function Assert-ArtifactRejected {
  param(
    [Parameter(Mandatory = $true)][string]$Artifact,
    [Parameter(Mandatory = $true)][ValidateSet('windows', 'android')]
    [string]$Kind,

    [string]$ErrorPattern = 'forbidden (?:flutter asset|Runtime-only artifact)'
  )

  try {
    Assert-ArtifactAccepted -Artifact $Artifact -Kind $Kind
  } catch {
    if ($_.Exception.Message -notmatch $ErrorPattern) {
      throw
    }
    return
  }
  throw "Runtime base package gate unexpectedly accepted: $Artifact"
}

try {
  New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
  & $verifier -Action preflight -Snapshot $snapshotPath
  $snapshot = Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8 |
    ConvertFrom-Json

  $directoryBundle = Join-Path $testRoot 'directory-bundle'
  New-ValidBundleSource `
    -Root $directoryBundle `
    -FlutterAssetsRelativeRoot 'data\flutter_assets' `
    -Snapshot $snapshot
  Assert-ArtifactAccepted -Artifact $directoryBundle -Kind windows
  $directoryForbidden = Join-Path $directoryBundle (
    'data\flutter_assets\resources\runtime\unexpected.bin'
  )
  New-Item -ItemType Directory -Path (Split-Path -Parent $directoryForbidden) -Force |
    Out-Null
  [IO.File]::WriteAllBytes($directoryForbidden, [byte[]]@(1))
  Assert-ArtifactRejected -Artifact $directoryBundle -Kind windows

  $windowsSource = Join-Path $testRoot 'windows-source'
  $windowsZip = Join-Path $testRoot 'windows.zip'
  New-ValidBundleSource `
    -Root $windowsSource `
    -FlutterAssetsRelativeRoot 'data\flutter_assets' `
    -Snapshot $snapshot
  New-TestArchive -Source $windowsSource -Destination $windowsZip
  Assert-ArtifactAccepted -Artifact $windowsZip -Kind windows
  $windowsRootForbidden = Join-Path $windowsSource 'resources\runtime\unexpected.bin'
  New-Item -ItemType Directory -Path (Split-Path -Parent $windowsRootForbidden) -Force |
    Out-Null
  [IO.File]::WriteAllBytes($windowsRootForbidden, [byte[]]@(4))
  New-TestArchive -Source $windowsSource -Destination $windowsZip
  Assert-ArtifactRejected -Artifact $windowsZip -Kind windows
  Remove-Item -LiteralPath (Join-Path $windowsSource 'resources') -Recurse -Force

  $windowsForbidden = Join-Path $windowsSource (
    'data\flutter_assets\runtime\resource\unexpected.bin'
  )
  New-Item -ItemType Directory -Path (Split-Path -Parent $windowsForbidden) -Force |
    Out-Null
  [IO.File]::WriteAllBytes($windowsForbidden, [byte[]]@(2))
  New-TestArchive -Source $windowsSource -Destination $windowsZip
  Assert-ArtifactRejected -Artifact $windowsZip -Kind windows

  $androidSource = Join-Path $testRoot 'android-source'
  $androidApk = Join-Path $testRoot 'android.apk'
  New-ValidBundleSource `
    -Root $androidSource `
    -FlutterAssetsRelativeRoot 'assets\flutter_assets' `
    -Snapshot $snapshot
  New-TestArchive -Source $androidSource -Destination $androidApk
  Assert-ArtifactAccepted -Artifact $androidApk -Kind android
  $androidKey = Join-Path $androidSource (
    'assets\flutter_assets\assets\runtime-export\playmesh-default-export.p12'
  )
  Remove-Item -LiteralPath $androidKey -Force
  New-TestArchive -Source $androidSource -Destination $androidApk
  Assert-ArtifactRejected `
    -Artifact $androidApk `
    -Kind android `
    -ErrorPattern 'default Runtime export signing key'
  Copy-Item -LiteralPath $defaultExportKey -Destination $androidKey -Force
  foreach ($forbiddenFileName in @(
      'playmesh-runtime-arm.apk',
      'playmesh-runtime-x86.apk',
      'playmesh-runtime-win.zip')) {
    $androidForbidden = Join-Path $androidSource (
      "assets\flutter_assets\assets\other\$forbiddenFileName"
    )
    New-Item -ItemType Directory -Path (Split-Path -Parent $androidForbidden) -Force |
      Out-Null
    [IO.File]::WriteAllBytes($androidForbidden, [byte[]]@(3))
    New-TestArchive -Source $androidSource -Destination $androidApk
    Assert-ArtifactRejected -Artifact $androidApk -Kind android
    Remove-Item -LiteralPath $androidForbidden -Force
  }

  Write-Host 'Release Runtime base-package exclusion gate passed.'
} finally {
  $buildRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build'))
  $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
  if (-not $resolvedTestRoot.StartsWith(
      $buildRoot + [IO.Path]::DirectorySeparatorChar,
      [StringComparison]::OrdinalIgnoreCase) -or
      -not (Split-Path -Leaf $resolvedTestRoot).StartsWith(
        'test-release-runtime-asset-gate-',
        [StringComparison]::Ordinal)) {
    throw "Refusing to clean unexpected test path: $resolvedTestRoot"
  }
  if (Test-Path -LiteralPath $resolvedTestRoot) {
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
  }
}
