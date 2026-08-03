param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('preflight', 'verify')]
  [string]$Action,

  [Parameter(Mandatory = $true)]
  [string]$Snapshot,

  [string]$Artifact,

  [ValidateSet('windows', 'android')]
  [string]$Kind = 'windows'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$promptsRelativeRoot = 'assets/playmesh-library/public/developer/prompts'
$promptsRoot = Join-Path $repoRoot ($promptsRelativeRoot -replace '/', '\')
$manifestPath = Join-Path $promptsRoot 'manifest.json'
$localizationRelativeRoot = 'assets/playmesh-localization'
$localizationRoot = Join-Path $repoRoot (
  $localizationRelativeRoot -replace '/', '\'
)
$localizationManifestPath = Join-Path $localizationRoot 'manifest.json'
$utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)

function Get-StrictUtf8Text {
  param([Parameter(Mandatory = $true)][string]$Path)

  $bytes = [IO.File]::ReadAllBytes($Path)
  return $utf8Strict.GetString($bytes)
}

function Get-LocalizationFiles {
  if (-not (Test-Path -LiteralPath $localizationManifestPath -PathType Leaf)) {
    throw "Localization manifest is missing: $localizationManifestPath"
  }
  $manifestText = Get-StrictUtf8Text -Path $localizationManifestPath
  $manifest = $manifestText | ConvertFrom-Json
  if ($manifest.manifestVersion -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
    throw 'Localization manifestVersion must use strict MAJOR.MINOR.PATCH.'
  }
  if ($null -eq $manifest.ui -or
      $manifest.ui.allowLocaleSwitch -isnot [bool] -or
      $manifest.ui.allowThemeSwitch -isnot [bool] -or
      $manifest.ui.defaultThemeMode -notin @('system', 'light', 'dark')) {
    throw 'Localization manifest ui configuration is invalid.'
  }
  if ($null -eq $manifest.locales -or @($manifest.locales).Count -eq 0) {
    throw 'Localization manifest must contain locales.'
  }

  $localeIds = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
  )
  $enabledLocaleIds = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
  )
  $bundlePaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
  )
  $localeById = @{}
  $messagesByLocaleAndKind = @{}
  $relativeFiles = [Collections.Generic.List[string]]::new()
  $relativeFiles.Add("$localizationRelativeRoot/manifest.json")

  foreach ($locale in @($manifest.locales)) {
    $id = [string]$locale.id
    if ($id -notmatch '^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,2}$' -or
        -not $localeIds.Add($id)) {
      throw "Invalid or duplicate localization locale id: $id"
    }
    if ([string]::IsNullOrWhiteSpace([string]$locale.label) -or
        $locale.enabled -isnot [bool]) {
      throw "Localization locale '$id' has invalid label or enabled state."
    }
    if ($locale.enabled) {
      $null = $enabledLocaleIds.Add($id)
    }
    if ($null -ne $locale.fallback -and
        [string]::IsNullOrWhiteSpace([string]$locale.fallback)) {
      throw "Localization locale '$id' has an invalid fallback."
    }
    $localeById[$id] = $locale

    foreach ($kind in @('app', 'goServer')) {
      $relative = [string]$locale.bundles.$kind
      $escapedId = [Regex]::Escape($id)
      if ($relative -notmatch "^locales/$escapedId/[^/\\]+\.json$" -or
          $relative.Contains('..') -or
          -not $bundlePaths.Add($relative)) {
        throw "Unsafe or duplicate localization bundle path: $relative"
      }
      $assetRelative = "$localizationRelativeRoot/$relative"
      $assetPath = Join-Path $repoRoot ($assetRelative -replace '/', '\')
      if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        throw "Localization bundle is missing: $assetRelative"
      }
      $bundleText = Get-StrictUtf8Text -Path $assetPath
      $bundle = $bundleText | ConvertFrom-Json
      $bundleMessages = @{}
      foreach ($property in @($bundle.PSObject.Properties)) {
        if ($property.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$' -or
            $property.Value -isnot [string]) {
          throw "Localization bundle contains a non-string message: $assetRelative"
        }
        if ($property.Value -match '<\s*/?\s*(script|iframe|object|embed|style|link)\b') {
          throw "Localization bundle contains executable HTML: $assetRelative#$($property.Name)"
        }
        $bundleMessages[$property.Name] = [string]$property.Value
      }
      if ($bundleMessages.Count -eq 0) {
        throw "Localization bundle is empty: $assetRelative"
      }
      $messagesByLocaleAndKind["$id|$kind"] = $bundleMessages
      $relativeFiles.Add($assetRelative)
    }
  }

  $defaultLocale = [string]$manifest.defaultLocale
  if (-not $enabledLocaleIds.Contains($defaultLocale)) {
    throw 'Localization defaultLocale must reference an enabled locale.'
  }
  foreach ($id in $localeIds) {
    $fallback = $localeById[$id].fallback
    if ($null -ne $fallback -and -not $localeIds.Contains([string]$fallback)) {
      throw "Localization locale '$id' references an unknown fallback."
    }
    $visited = [Collections.Generic.HashSet[string]]::new(
      [StringComparer]::Ordinal
    )
    $current = $id
    while ($null -ne $current) {
      if (-not $visited.Add([string]$current)) {
        throw "Localization fallback cycle contains '$current'."
      }
      $next = $localeById[[string]$current].fallback
      $current = if ($null -eq $next) { $null } else { [string]$next }
    }
  }

  foreach ($kind in @('app', 'goServer')) {
    $allKeys = [Collections.Generic.HashSet[string]]::new(
      [StringComparer]::Ordinal
    )
    foreach ($id in $localeIds) {
      foreach ($key in $messagesByLocaleAndKind["$id|$kind"].Keys) {
        $null = $allKeys.Add([string]$key)
      }
    }
    foreach ($id in $enabledLocaleIds) {
      $available = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
      )
      $current = $id
      while ($null -ne $current) {
        foreach ($key in $messagesByLocaleAndKind["$current|$kind"].Keys) {
          $null = $available.Add([string]$key)
        }
        $next = $localeById[[string]$current].fallback
        $current = if ($null -eq $next) { $null } else { [string]$next }
      }
      foreach ($key in $allKeys) {
        if (-not $available.Contains($key)) {
          throw "Localization locale '$id' is missing '$kind' key '$key'."
        }
      }
    }
  }

  $expectedJson = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
  )
  foreach ($relative in $relativeFiles) {
    $null = $expectedJson.Add($relative)
  }
  foreach ($file in Get-ChildItem -LiteralPath $localizationRoot -Recurse -File -Filter '*.json') {
    $relative = $file.FullName.Substring($repoRoot.Length + 1) -replace '\\', '/'
    if (-not $expectedJson.Contains($relative)) {
      throw "Orphan localization dictionary: $relative"
    }
  }
  if (@(Get-ChildItem -LiteralPath $localizationRoot -Recurse -File -Filter '*.json').Count -ne
      $expectedJson.Count) {
    throw 'Localization manifest references a missing dictionary.'
  }
  return @($relativeFiles)
}

function Get-SourceSnapshot {
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "AI prompt manifest is missing: $manifestPath"
  }
  $manifestText = Get-StrictUtf8Text -Path $manifestPath
  $manifest = $manifestText | ConvertFrom-Json
  if ($manifest.manifestVersion -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
    throw 'AI prompt manifestVersion must use strict MAJOR.MINOR.PATCH.'
  }
  if ($null -eq $manifest.templates -or @($manifest.templates).Count -eq 0) {
    throw 'AI prompt manifest must contain templates.'
  }

  $localizationFiles = @(Get-LocalizationFiles)
  $localizationManifest = (
    Get-StrictUtf8Text -Path $localizationManifestPath
  ) | ConvertFrom-Json
  $enabledLocaleIds = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
  )
  foreach ($locale in @($localizationManifest.locales)) {
    if ($locale.enabled) {
      $null = $enabledLocaleIds.Add([string]$locale.id)
    }
  }

  $ids = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
  )
  $files = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
  )
  foreach ($template in @($manifest.templates)) {
    $id = [string]$template.id
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') {
      throw "Invalid AI prompt template id: $id"
    }
    if (-not $ids.Add($id)) {
      throw "Duplicate AI prompt template id: $id"
    }
    if ([string]::IsNullOrWhiteSpace([string]$template.category)) {
      throw "AI prompt template '$id' is missing category."
    }
    if ($null -eq $template.files) {
      throw "AI prompt template '$id' is missing locale files."
    }

    $mappedLocaleIds = [Collections.Generic.HashSet[string]]::new(
      [StringComparer]::Ordinal
    )
    foreach ($mapping in @($template.files.PSObject.Properties)) {
      $localeId = [string]$mapping.Name
      $file = [string]$mapping.Value
      $escapedLocaleId = [Regex]::Escape($localeId)
      if (-not $enabledLocaleIds.Contains($localeId)) {
        throw "AI prompt template '$id' maps an unknown or disabled locale: $localeId"
      }
      if ($file -notmatch "^$escapedLocaleId/[^/\\]+\.txt$" -or
          $file.Contains('..')) {
        throw "Invalid AI prompt template file for '$id' locale '$localeId': $file"
      }
      if (-not $mappedLocaleIds.Add($localeId)) {
        throw "AI prompt template '$id' maps locale '$localeId' more than once."
      }
      if (-not $files.Add($file)) {
        throw "Duplicate AI prompt template file: $file"
      }
    }
    foreach ($localeId in $enabledLocaleIds) {
      if (-not $mappedLocaleIds.Contains($localeId)) {
        throw "AI prompt template '$id' is missing enabled locale '$localeId'."
      }
    }
  }
  foreach ($required in @('common', 'agent-common')) {
    if (-not $ids.Contains($required)) {
      throw "AI prompt manifest is missing reserved template: $required"
    }
  }

  $actualTextFiles = Get-ChildItem -LiteralPath $promptsRoot -Recurse -File -Filter '*.txt'
  foreach ($file in $actualTextFiles) {
    $relative = $file.FullName.Substring($promptsRoot.Length + 1) -replace '\\', '/'
    if (-not $files.Contains($relative)) {
      throw "Orphan AI prompt template: $relative"
    }
  }
  if (@($actualTextFiles).Count -ne $files.Count) {
    throw 'AI prompt manifest references a missing template file.'
  }

  $relativeFiles = [Collections.Generic.List[string]]::new()
  $relativeFiles.Add("$promptsRelativeRoot/manifest.json")
  foreach ($file in ($files | Sort-Object)) {
    $relativeFiles.Add("$promptsRelativeRoot/$file")
  }
  foreach ($relative in $localizationFiles) {
    $relativeFiles.Add($relative)
  }
  $relativeFiles = @($relativeFiles | Sort-Object -Unique)
  $entries = [Collections.Generic.List[object]]::new()
  foreach ($relative in $relativeFiles) {
    $sourcePath = Join-Path $repoRoot ($relative -replace '/', '\')
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
      throw "Release asset is missing: $relative"
    }
    $bytes = [IO.File]::ReadAllBytes($sourcePath)
    if ($relative.EndsWith('.txt')) {
      if ($bytes.Length -eq 0 -or $bytes.Length -gt 512KB) {
        throw "AI prompt template must be between 1 B and 512 KiB: $relative"
      }
      $text = $utf8Strict.GetString($bytes)
      if ([string]::IsNullOrWhiteSpace($text)) {
        throw "AI prompt template is empty: $relative"
      }
    } else {
      $null = $utf8Strict.GetString($bytes)
    }
    $hash = Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256
    $entries.Add([ordered]@{
      path = $relative
      bytes = $bytes.Length
      sha256 = $hash.Hash.ToLowerInvariant()
    })
  }
  return [ordered]@{
    schemaVersion = '1.0.0'
    generatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    files = $entries
  }
}

function Get-StreamSha256 {
  param([Parameter(Mandatory = $true)][IO.Stream]$Stream)

  $algorithm = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($algorithm.ComputeHash($Stream)) -replace '-', '').ToLowerInvariant()
  } finally {
    $algorithm.Dispose()
  }
}

function Get-PackagedEntry {
  param(
    [Parameter(Mandatory = $true)]$Archive,
    [Parameter(Mandatory = $true)][string]$Relative
  )

  $prefixes = switch ($Kind) {
    'android' { @('assets/flutter_assets/') }
    default { @('data/flutter_assets/', '') }
  }
  foreach ($prefix in $prefixes) {
    $candidate = "$prefix$Relative"
    $entry = $Archive.Entries |
      Where-Object { ($_.FullName -replace '\\', '/') -ceq $candidate } |
      Select-Object -First 1
    if ($null -ne $entry) {
      return $entry
    }
  }
  return $null
}

if ($Action -eq 'preflight') {
  $source = Get-SourceSnapshot
  $snapshotPath = [IO.Path]::GetFullPath($Snapshot)
  $snapshotDirectory = Split-Path -Parent $snapshotPath
  New-Item -ItemType Directory -Force -Path $snapshotDirectory | Out-Null
  $json = $source | ConvertTo-Json -Depth 8
  [IO.File]::WriteAllText($snapshotPath, "$json`n", [Text.UTF8Encoding]::new($false))
  foreach ($file in $source.files) {
    Write-Host "release asset source $($file.path) bytes=$($file.bytes) sha256=$($file.sha256)"
  }
  return
}

if ([string]::IsNullOrWhiteSpace($Artifact)) {
  throw 'verify requires -Artifact.'
}
$snapshotPath = [IO.Path]::GetFullPath($Snapshot)
if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
  throw "Release asset snapshot is missing: $snapshotPath"
}
$expected = (Get-StrictUtf8Text -Path $snapshotPath) | ConvertFrom-Json
$current = Get-SourceSnapshot
if (@($expected.files).Count -ne @($current.files).Count) {
  throw 'Release assets changed after preflight.'
}
for ($index = 0; $index -lt @($expected.files).Count; $index++) {
  $before = @($expected.files)[$index]
  $after = @($current.files)[$index]
  if ($before.path -cne $after.path -or
      $before.sha256 -cne $after.sha256 -or
      [int64]$before.bytes -ne [int64]$after.bytes) {
    throw "Release asset changed during build: $($before.path)"
  }
}

$artifactPath = [IO.Path]::GetFullPath($Artifact)
if (Test-Path -LiteralPath $artifactPath -PathType Container) {
  foreach ($file in @($expected.files)) {
    $candidate = Join-Path $artifactPath (
      "data\flutter_assets\$($file.path -replace '/', '\')"
    )
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      throw "Packaged release asset is missing: $($file.path)"
    }
    $hash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne $file.sha256 -or
        (Get-Item -LiteralPath $candidate).Length -ne [int64]$file.bytes) {
      throw "Packaged release asset differs from source: $($file.path)"
    }
  }
} else {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [IO.Compression.ZipFile]::OpenRead($artifactPath)
  try {
    foreach ($file in @($expected.files)) {
      $entry = Get-PackagedEntry -Archive $archive -Relative $file.path
      if ($null -eq $entry) {
        throw "Packaged release asset is missing: $($file.path)"
      }
      $stream = $entry.Open()
      try {
        $hash = Get-StreamSha256 -Stream $stream
      } finally {
        $stream.Dispose()
      }
      if ($hash -cne $file.sha256 -or $entry.Length -ne [int64]$file.bytes) {
        throw "Packaged release asset differs from source: $($file.path)"
      }
    }
  } finally {
    $archive.Dispose()
  }
}
Write-Host "Verified $(@($expected.files).Count) release assets in $artifactPath"
