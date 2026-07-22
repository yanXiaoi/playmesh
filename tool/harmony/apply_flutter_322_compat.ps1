[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Replace-Exact {
  param(
    [Parameter(Mandatory = $true)] [string]$RelativePath,
    [Parameter(Mandatory = $true)] [string]$OldValue,
    [Parameter(Mandatory = $true)] [string]$NewValue,
    [int]$ExpectedCount = 1
  )

  $path = Join-Path $ProjectRoot $RelativePath
  $content = [IO.File]::ReadAllText($path)
  $count = ([Regex]::Matches($content, [Regex]::Escape($OldValue))).Count
  if ($count -ne $ExpectedCount) {
    throw "Harmony Flutter compatibility replacement count for $RelativePath was $count; expected $ExpectedCount."
  }
  $content = $content.Replace($OldValue, $NewValue)
  [IO.File]::WriteAllText($path, $content, [Text.UTF8Encoding]::new($false))
}

# Flutter 3.22/Dart 3.4 equivalents for APIs and syntax used by the main
# Flutter 3.44/Dart 3.12 source tree. These edits apply only to build staging.
Replace-Exact 'lib\core\game_package\game_library_repository.dart' `
  'onError: (Object _, StackTrace _) => _clearRefresh(operation),' `
  'onError: (Object _, StackTrace stackTrace) => _clearRefresh(operation),'
Replace-Exact 'lib\features\game\game_page.dart' `
  'onPopInvokedWithResult: (didPop, _) {' `
  'onPopInvoked: (didPop) {'
Replace-Exact 'lib\features\game\standalone_html_page.dart' `
  '.withValues(alpha: ' '.withOpacity('
Replace-Exact 'lib\features\home\home_page.dart' `
  '.withValues(alpha: ' '.withOpacity(' 2
Replace-Exact 'lib\ui\playmesh_ui.dart' 'CardThemeData(' 'CardTheme('
Replace-Exact 'lib\ui\playmesh_ui.dart' 'DialogThemeData(' 'DialogTheme('
Replace-Exact 'lib\core\network\go_core_client.dart' `
  "'errorCode': ?errorCode," `
  "if (errorCode != null) 'errorCode': errorCode,"
Replace-Exact 'lib\core\network\go_core_client.dart' `
  "'statusCode': ?statusCode," `
  "if (statusCode != null) 'statusCode': statusCode,"
Replace-Exact 'lib\core\session\go_core_session_client.dart' `
  "'shareToken': ?shareToken," `
  "if (shareToken != null) 'shareToken': shareToken,"
Replace-Exact 'lib\core\session\go_core_session_client.dart' `
  "'playerId': ?playerId," `
  "if (playerId != null) 'playerId': playerId,"
Replace-Exact 'lib\core\session\go_core_session_client.dart' `
  "'targetPlayerIds': ?targetPlayerIds," `
  "if (targetPlayerIds != null) 'targetPlayerIds': targetPlayerIds,"
Replace-Exact 'lib\core\game_web\game_web_gateway_io.dart' `
  "'nickname': ?request.uri.queryParameters['playmeshNickname']," `
  "if (request.uri.queryParameters['playmeshNickname'] != null) 'nickname': request.uri.queryParameters['playmeshNickname'],"

Write-Output 'Applied Flutter 3.22 / Dart 3.4 Harmony staging compatibility transforms.'
