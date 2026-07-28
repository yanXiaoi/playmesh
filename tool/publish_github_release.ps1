[CmdletBinding()]
param(
  [ValidateSet('all', 'android', 'windows')]
  [string]$Target = 'all',
  [switch]$SkipBuild,
  [switch]$SkipPush,
  [switch]$AllowDebugSigning,
  [switch]$Draft,
  [switch]$Prerelease,
  [string]$AndroidFlutter,
  [string]$Remote = 'origin',
  [string]$Branch = 'master'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$pubspecPath = Join-Path $repoRoot 'pubspec.yaml'
$buildScript = Join-Path $PSScriptRoot 'build_release.ps1'

function Invoke-CheckedCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Command,
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  & $Command @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$Command failed with exit code $LASTEXITCODE."
  }
}

function Read-CommandText {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Command,
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $result = & $Command @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$Command failed with exit code $LASTEXITCODE."
  }
  return (($result | Out-String).Trim())
}

if (-not (Test-Path -LiteralPath $pubspecPath -PathType Leaf)) {
  throw "pubspec.yaml was not found: $pubspecPath"
}
if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
  throw "Release build script was not found: $buildScript"
}

$gitCommand = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitCommand) {
  throw 'Git was not found in PATH.'
}
$ghCommand = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghCommand) {
  throw 'GitHub CLI was not found. Install it with: winget install --id GitHub.cli'
}

$pubspec = Get-Content -LiteralPath $pubspecPath -Encoding UTF8
$versionLine = $pubspec |
  Where-Object { $_ -match '^version:\s*(\S+)\s*$' } |
  Select-Object -First 1
if (-not $versionLine -or
    $versionLine -notmatch '^version:\s*([^+\s]+)\+(\d+)\s*$') {
  throw 'pubspec.yaml version must use MAJOR.MINOR.PATCH+BUILD.'
}

$versionName = $matches[1]
$buildNumber = $matches[2]
$tagName = "v$versionName-build$buildNumber"
$releaseTitle = "Playmesh $versionName (build $buildNumber)"
$artifactPrefix = "Playmesh-$versionName-build$buildNumber"
$releaseDir = Join-Path $repoRoot "release\$versionName"
$buildAndroid = $Target -in @('all', 'android')

if ($buildAndroid -and $AllowDebugSigning -and
    (-not $Draft) -and (-not $Prerelease)) {
  throw 'Debug-signed Android artifacts can only be published with -Draft or -Prerelease.'
}

Push-Location $repoRoot
try {
  $insideWorkTree = Read-CommandText `
    -Command $gitCommand.Source `
    -Arguments @('rev-parse', '--is-inside-work-tree')
  if ($insideWorkTree -ne 'true') {
    throw "$repoRoot is not a Git work tree."
  }

  $currentBranch = Read-CommandText `
    -Command $gitCommand.Source `
    -Arguments @('branch', '--show-current')
  if (-not $currentBranch) {
    throw 'Git is currently in detached HEAD state.'
  }
  if ($currentBranch -ne $Branch) {
    throw "Current branch is '$currentBranch'; expected '$Branch'."
  }

  $remoteUrl = Read-CommandText `
    -Command $gitCommand.Source `
    -Arguments @('remote', 'get-url', $Remote)
  if ($remoteUrl -notmatch
      'github\.com[/:](?<repository>[^/]+/[^/]+?)(?:\.git)?/?$') {
    throw "Remote '$Remote' is not a GitHub repository: $remoteUrl"
  }
  $repository = $matches['repository']

  $gitStatus = Read-CommandText `
    -Command $gitCommand.Source `
    -Arguments @('status', '--porcelain', '--untracked-files=normal')
  if ($gitStatus) {
    throw 'Working tree is not clean. Commit or stash all changes before publishing.'
  }

  Invoke-CheckedCommand `
    -Command $ghCommand.Source `
    -Arguments @('auth', 'status', '--hostname', 'github.com')

  if (-not $SkipBuild) {
    $buildParameters = @{
      Target = $Target
    }
    if ($AllowDebugSigning) {
      $buildParameters.AllowDebugSigning = $true
    }
    if ($AndroidFlutter) {
      $buildParameters.AndroidFlutter = $AndroidFlutter
    }
    & $buildScript @buildParameters
    if (-not $?) {
      throw 'Release build failed.'
    }

    # 生成器改变受版本控制文件时，必须先提交再发布，确保 Release 可追溯到同一提交。
    $postBuildStatus = Read-CommandText `
      -Command $gitCommand.Source `
      -Arguments @('status', '--porcelain', '--untracked-files=normal')
    if ($postBuildStatus) {
      throw 'The build changed tracked or untracked source files. Review and commit them, then rerun with -SkipBuild.'
    }
  }

  $artifacts = [System.Collections.Generic.List[string]]::new()
  if ($Target -in @('all', 'android')) {
    $artifacts.Add(
      (Join-Path $releaseDir "$artifactPrefix-android-universal.apk")
    )
  }
  if ($Target -in @('all', 'windows')) {
    $artifacts.Add(
      (Join-Path $releaseDir "$artifactPrefix-windows-x64-portable.zip")
    )
  }
  foreach ($artifact in $artifacts) {
    if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
      throw "Release artifact was not found: $artifact"
    }
  }

  $checksumPath = Join-Path $releaseDir "$artifactPrefix-SHA256SUMS.txt"
  $checksumLines = foreach ($artifact in $artifacts) {
    $hash = Get-FileHash -LiteralPath $artifact -Algorithm SHA256
    "$($hash.Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($artifact))"
  }
  [IO.File]::WriteAllLines(
    $checksumPath,
    $checksumLines,
    [Text.UTF8Encoding]::new($false)
  )
  $artifacts.Add($checksumPath)

  if (-not $SkipPush) {
    Invoke-CheckedCommand `
      -Command $gitCommand.Source `
      -Arguments @('push', '--set-upstream', $Remote, $Branch)
  }

  $commitSha = Read-CommandText `
    -Command $gitCommand.Source `
    -Arguments @('rev-parse', 'HEAD')

  $releaseArguments = @(
    'release',
    'create',
    $tagName
  )
  $releaseArguments += $artifacts.ToArray()
  $releaseArguments += @(
    '--target',
    $commitSha,
    '--repo',
    $repository,
    '--title',
    $releaseTitle,
    '--generate-notes',
    '--fail-on-no-commits'
  )
  if ($Draft) {
    $releaseArguments += '--draft'
  }
  if ($Prerelease) {
    $releaseArguments += '--prerelease'
  }

  Write-Output "Publishing GitHub Release $tagName from $commitSha..."
  Invoke-CheckedCommand `
    -Command $ghCommand.Source `
    -Arguments $releaseArguments

  Write-Output 'Published artifacts:'
  foreach ($artifact in $artifacts) {
    Write-Output "  $artifact"
  }
} finally {
  Pop-Location
}
