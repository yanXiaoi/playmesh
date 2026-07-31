[CmdletBinding()]
param(
  [ValidateSet('all', 'android', 'windows')]
  [string]$Target = 'all',
  [string]$Repository = 'yanxao/playmesh',
  [string]$CommitSha,
  [string]$GitHubRemote = 'origin',
  [switch]$Prerelease,
  [ValidateRange(0, 1800)]
  [int]$MirrorTimeoutSeconds = 300,
  [ValidateRange(1, 60)]
  [int]$MirrorPollSeconds = 5,
  [ValidateRange(30, 3600)]
  [int]$HttpTimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$pubspecPath = Join-Path $repoRoot 'pubspec.yaml'
$apiRoot = 'https://gitee.com/api/v5'
$accessToken = $env:GITEE_ACCESS_TOKEN
$localTokenPath =
  Join-Path $repoRoot 'release\tools\gitee-token.txt'
if ([string]::IsNullOrWhiteSpace($accessToken) -and
    (Test-Path -LiteralPath $localTokenPath -PathType Leaf)) {
  $accessToken =
    (Get-Content -LiteralPath $localTokenPath -Raw -Encoding UTF8).Trim()
}

function ConvertTo-FormContent {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Fields
  )

  $values =
    [System.Collections.Generic.Dictionary[string, string]]::new()
  foreach ($field in $Fields.GetEnumerator()) {
    $values.Add([string]$field.Key, [string]$field.Value)
  }
  return [System.Net.Http.FormUrlEncodedContent]::new($values)
}

function Invoke-GiteeApi {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('GET', 'POST', 'PATCH')]
    [string]$Method,
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [hashtable]$Fields,
    [int[]]$AllowedStatusCodes = @(),
    [string]$DisplayPath = $Path
  )

  $request = [System.Net.Http.HttpRequestMessage]::new(
    [System.Net.Http.HttpMethod]::new($Method),
    "$apiRoot$Path"
  )
  $response = $null
  try {
    $request.Headers.Authorization =
      [System.Net.Http.Headers.AuthenticationHeaderValue]::new(
        'Bearer',
        $accessToken
      )
    $request.Headers.Accept.ParseAdd('application/json')
    if ($Fields) {
      $request.Content = ConvertTo-FormContent -Fields $Fields
    }

    $response = $script:httpClient.SendAsync($request).GetAwaiter().GetResult()
    $statusCode = [int]$response.StatusCode
    $responseBody =
      $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
      if ($AllowedStatusCodes -contains $statusCode) {
        return $null
      }
      $detail = $responseBody.Trim()
      if (-not [string]::IsNullOrEmpty($accessToken)) {
        $detail = $detail.Replace($accessToken, '<redacted>')
      }
      if ($detail.Length -gt 1000) {
        $detail = $detail.Substring(0, 1000)
      }
      throw "Gitee API $Method $DisplayPath failed with HTTP " +
        "$statusCode. $detail"
    }
    if ([string]::IsNullOrWhiteSpace($responseBody)) {
      return $null
    }
    return ($responseBody | ConvertFrom-Json)
  } finally {
    if ($response) {
      $response.Dispose()
    }
    $request.Dispose()
  }
}

function Send-GiteeAttachment {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$FilePath
  )

  $fileName = [IO.Path]::GetFileName($FilePath)
  $fileStream = [IO.File]::OpenRead($FilePath)
  $fileContent = [System.Net.Http.StreamContent]::new($fileStream)
  $multipart = [System.Net.Http.MultipartFormDataContent]::new()
  $request = $null
  $response = $null
  try {
    $fileContent.Headers.ContentType =
      [System.Net.Http.Headers.MediaTypeHeaderValue]::new(
        'application/octet-stream'
      )
    $multipart.Add($fileContent, 'file', $fileName)
    $request = [System.Net.Http.HttpRequestMessage]::new(
      [System.Net.Http.HttpMethod]::Post,
      "$apiRoot$Path"
    )
    $request.Headers.Authorization =
      [System.Net.Http.Headers.AuthenticationHeaderValue]::new(
        'Bearer',
        $accessToken
      )
    $request.Headers.Accept.ParseAdd('application/json')
    $request.Content = $multipart

    $response = $script:httpClient.SendAsync($request).GetAwaiter().GetResult()
    $responseBody =
      $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
      $statusCode = [int]$response.StatusCode
      $detail = $responseBody.Trim()
      if (-not [string]::IsNullOrEmpty($accessToken)) {
        $detail = $detail.Replace($accessToken, '<redacted>')
      }
      if ($detail.Length -gt 1000) {
        $detail = $detail.Substring(0, 1000)
      }
      throw "Uploading '$fileName' to Gitee failed with HTTP " +
        "$statusCode. $detail"
    }
    if ([string]::IsNullOrWhiteSpace($responseBody)) {
      return $null
    }
    return ($responseBody | ConvertFrom-Json)
  } finally {
    if ($response) {
      $response.Dispose()
    }
    if ($request) {
      $request.Dispose()
    } else {
      $multipart.Dispose()
    }
  }
}

function Get-GiteeAttachmentName {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Attachment
  )

  foreach ($propertyName in @('name', 'file_name', 'filename')) {
    $property = $Attachment.PSObject.Properties[$propertyName]
    if ($property -and -not [string]::IsNullOrWhiteSpace($property.Value)) {
      return [string]$property.Value
    }
  }
  $downloadProperty =
    $Attachment.PSObject.Properties['browser_download_url']
  if ($downloadProperty -and $downloadProperty.Value) {
    $downloadUri = [Uri][string]$downloadProperty.Value
    return [Uri]::UnescapeDataString(
      [IO.Path]::GetFileName($downloadUri.AbsolutePath)
    )
  }
  return $null
}

if ([string]::IsNullOrWhiteSpace($accessToken)) {
  throw 'Gitee credentials were not found. Create a personal access token ' +
    'with the project scope, then set GITEE_ACCESS_TOKEN or save it to ' +
    "$localTokenPath."
}
if ($Repository -notmatch
    '^(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+)$') {
  throw "Gitee repository must use owner/repo format: $Repository"
}
$owner = $matches['owner']
$repo = $matches['repo']

if (-not (Test-Path -LiteralPath $pubspecPath -PathType Leaf)) {
  throw "pubspec.yaml was not found: $pubspecPath"
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
$releaseNotesPath = Join-Path $repoRoot "docs\version\$versionName.md"
$releaseNotesUrl =
  "https://gitee.com/$Repository/blob/$tagName/docs/version/$versionName.md"
$releaseNotesBody =
  "[docs/version/$versionName.md]($releaseNotesUrl)"

if (-not (Test-Path -LiteralPath $releaseNotesPath -PathType Leaf)) {
  throw "Release notes were not found: $releaseNotesPath"
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
$artifacts.Add(
  (Join-Path $releaseDir "$artifactPrefix-SHA256SUMS.txt")
)
foreach ($artifact in $artifacts) {
  if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
    throw "Release artifact was not found: $artifact"
  }
}

$gitCommand = Get-Command git -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($CommitSha)) {
  if (-not $gitCommand) {
    throw 'Git was not found in PATH and -CommitSha was not supplied.'
  }
  Push-Location $repoRoot
  try {
    $tagRefs = @(
      & $gitCommand.Source `
        'ls-remote' `
        '--exit-code' `
        $GitHubRemote `
        "refs/tags/$tagName" `
        "refs/tags/${tagName}^{}"
    )
    if ($LASTEXITCODE -ne 0) {
      throw "GitHub tag $tagName was not found on remote " +
        "'$GitHubRemote'. Supply -CommitSha explicitly if needed."
    }
    $escapedTagName = [Regex]::Escape($tagName)
    $selectedTagRef = $tagRefs |
      Where-Object {
        $_ -match "\srefs/tags/$escapedTagName\^\{\}$"
      } |
      Select-Object -First 1
    if (-not $selectedTagRef) {
      $selectedTagRef = $tagRefs |
        Where-Object {
          $_ -match "\srefs/tags/$escapedTagName$"
        } |
        Select-Object -First 1
    }
    if (-not $selectedTagRef -or
        $selectedTagRef -notmatch '^(?<sha>[0-9a-fA-F]{40})\s') {
      throw "Unable to resolve GitHub tag $tagName on remote " +
        "'$GitHubRemote'."
    }
    $CommitSha = $matches['sha']
  } finally {
    Pop-Location
  }
}
if ($CommitSha -notmatch '^[0-9a-fA-F]{40}$') {
  throw "Commit SHA must contain 40 hexadecimal characters: $CommitSha"
}
$CommitSha = $CommitSha.ToLowerInvariant()

Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol =
  [Net.ServicePointManager]::SecurityProtocol -bor
  [Net.SecurityProtocolType]::Tls12
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AutomaticDecompression =
  [Net.DecompressionMethods]::GZip -bor
  [Net.DecompressionMethods]::Deflate
$script:httpClient = [System.Net.Http.HttpClient]::new($handler)
$script:httpClient.Timeout = [TimeSpan]::FromSeconds($HttpTimeoutSeconds)
$script:httpClient.DefaultRequestHeaders.UserAgent.ParseAdd(
  'Playmesh-Release-Script/1.0'
)

try {
  $escapedCommit = [Uri]::EscapeDataString($CommitSha)
  $commitPath = "/repos/$owner/$repo/commits/$escapedCommit"
  $mirroredCommit = Invoke-GiteeApi `
    -Method GET `
    -Path $commitPath `
    -AllowedStatusCodes @(404)

  if (-not $mirroredCommit) {
    Write-Output "Requesting Gitee mirror update for $Repository..."
    $mirrorPath = "/repos/$owner/$repo/remote_mirror/pull"
    Invoke-GiteeApi `
      -Method POST `
      -Path $mirrorPath `
      -Fields @{ access_token = $accessToken } `
      -AllowedStatusCodes @(409) `
      -DisplayPath $mirrorPath |
        Out-Null

    $deadline = [DateTime]::UtcNow.AddSeconds($MirrorTimeoutSeconds)
    do {
      $mirroredCommit = Invoke-GiteeApi `
        -Method GET `
        -Path $commitPath `
        -AllowedStatusCodes @(404)
      if ($mirroredCommit) {
        break
      }
      if ([DateTime]::UtcNow -ge $deadline) {
        throw "Gitee mirror did not expose commit $CommitSha within " +
          "$MirrorTimeoutSeconds seconds. Rerun this script after the " +
          'repository synchronization finishes.'
      }
      Start-Sleep -Seconds $MirrorPollSeconds
    } while ($true)
  }

  $escapedTag = [Uri]::EscapeDataString($tagName)
  $giteeTagCommit = Invoke-GiteeApi `
    -Method GET `
    -Path "/repos/$owner/$repo/commits/$escapedTag" `
    -AllowedStatusCodes @(404)
  if ($giteeTagCommit -and
      ([string]$giteeTagCommit.sha).ToLowerInvariant() -ne $CommitSha) {
    throw "Gitee tag $tagName points to $($giteeTagCommit.sha), but " +
      "GitHub points to $CommitSha. Wait for mirror synchronization " +
      'instead of publishing mismatched releases.'
  }

  $release = Invoke-GiteeApi `
    -Method GET `
    -Path "/repos/$owner/$repo/releases/tags/$escapedTag" `
    -AllowedStatusCodes @(404)

  $releaseFields = @{
    tag_name = $tagName
    name = $releaseTitle
    body = $releaseNotesBody
    prerelease = $Prerelease.IsPresent.ToString().ToLowerInvariant()
  }
  if ($release) {
    Write-Output "Updating existing Gitee Release $tagName..."
    $release = Invoke-GiteeApi `
      -Method PATCH `
      -Path "/repos/$owner/$repo/releases/$($release.id)" `
      -Fields $releaseFields
  } else {
    Write-Output "Creating Gitee Release $tagName from $CommitSha..."
    $releaseFields.target_commitish = $CommitSha
    $release = Invoke-GiteeApi `
      -Method POST `
      -Path "/repos/$owner/$repo/releases" `
      -Fields $releaseFields
  }

  if (-not $release -or -not $release.id) {
    throw "Gitee did not return a release ID for $tagName."
  }
  $releaseId = [string]$release.id
  $attachments = @(
    Invoke-GiteeApi `
      -Method GET `
      -Path "/repos/$owner/$repo/releases/$releaseId/attach_files"
  )
  $existingNames =
    [System.Collections.Generic.HashSet[string]]::new(
      [StringComparer]::OrdinalIgnoreCase
    )
  foreach ($attachment in $attachments) {
    $attachmentName = Get-GiteeAttachmentName -Attachment $attachment
    if ($attachmentName) {
      [void]$existingNames.Add($attachmentName)
    }
  }

  foreach ($artifact in $artifacts) {
    $fileName = [IO.Path]::GetFileName($artifact)
    if ($existingNames.Contains($fileName)) {
      Write-Output "Gitee attachment already exists; skipping: $fileName"
      continue
    }
    Write-Output "Uploading Gitee attachment: $fileName"
    Send-GiteeAttachment `
      -Path "/repos/$owner/$repo/releases/$releaseId/attach_files" `
      -FilePath $artifact |
      Out-Null
  }

  Write-Output (
    'Published Gitee Release: ' +
    "https://gitee.com/$Repository/releases/tag/$tagName"
  )
} finally {
  $script:httpClient.Dispose()
  $handler.Dispose()
}
