[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$node = (Get-Command node.exe -ErrorAction Stop).Source
& $node (Join-Path $PSScriptRoot 'generate_sdk.mjs')
if ($LASTEXITCODE -ne 0) {
  throw "SDK generation failed: $LASTEXITCODE"
}
