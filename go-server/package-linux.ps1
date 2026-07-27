[CmdletBinding()]
param(
    [ValidateSet("amd64", "arm64")]
    [string]$Architecture = "amd64",

    [string]$OutputDirectory = "dist",

    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$serverRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
if ([System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
}
else {
    $outputRoot = [System.IO.Path]::GetFullPath((Join-Path $serverRoot $OutputDirectory))
}

$artifactName = "playmesh-go-server-linux-$Architecture"
$stagingRoot = Join-Path $outputRoot ".package-$artifactName"
$bundleRoot = Join-Path $stagingRoot $artifactName
$archivePath = Join-Path $outputRoot "$artifactName.tar.gz"
$checksumPath = "$archivePath.sha256"
$binaryPath = Join-Path $bundleRoot "playmesh-go-server"

function Assert-PathInside {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChildPath,

        [Parameter(Mandatory = $true)]
        [string]$ParentPath
    )

    $parent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $child = [System.IO.Path]::GetFullPath($ChildPath)
    $prefix = $parent + [System.IO.Path]::DirectorySeparatorChar

    if (-not $child.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to operate outside the output directory: $child"
    }
}

function Invoke-Go {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    & go @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "go $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Restore-ProcessEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Values
    )

    foreach ($name in $Values.Keys) {
        if ($null -eq $Values[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
        else {
            Set-Item -LiteralPath "Env:$name" -Value $Values[$name]
        }
    }
}

$null = Get-Command go -ErrorAction Stop
$tarCommand = Get-Command tar -ErrorAction Stop

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
Assert-PathInside -ChildPath $stagingRoot -ParentPath $outputRoot
Assert-PathInside -ChildPath $archivePath -ParentPath $outputRoot
Assert-PathInside -ChildPath $checksumPath -ParentPath $outputRoot

if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}
if (Test-Path -LiteralPath $archivePath) {
    Remove-Item -LiteralPath $archivePath -Force
}
if (Test-Path -LiteralPath $checksumPath) {
    Remove-Item -LiteralPath $checksumPath -Force
}

New-Item -ItemType Directory -Path $bundleRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $bundleRoot "data\games") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $bundleRoot "data\quarantine") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $bundleRoot "data\captcha-images") -Force | Out-Null

$previousEnvironment = @{
    GOOS        = [System.Environment]::GetEnvironmentVariable("GOOS", "Process")
    GOARCH      = [System.Environment]::GetEnvironmentVariable("GOARCH", "Process")
    CGO_ENABLED = [System.Environment]::GetEnvironmentVariable("CGO_ENABLED", "Process")
}

$locationPushed = $false
try {
    Push-Location $serverRoot
    $locationPushed = $true

    if (-not $SkipTests) {
        Write-Host "Running Go tests..."
        Invoke-Go -Arguments @("test", "./...")
    }

    $env:GOOS = "linux"
    $env:GOARCH = $Architecture
    $env:CGO_ENABLED = "0"

    Write-Host "Building the linux/$Architecture executable..."
    Invoke-Go -Arguments @(
        "build",
        "-buildvcs=false",
        "-trimpath",
        "-ldflags=-s -w",
        "-o",
        $binaryPath,
        "."
    )

    foreach ($fileName in @(
        "server.json",
        ".env.example",
        "README.md",
        "THIRD_PARTY_NOTICES.md"
    )) {
        $sourcePath = Join-Path $serverRoot $fileName
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Required package file is missing: $sourcePath"
        }
        Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $bundleRoot $fileName)
    }

    $linuxReadme = @"
# Linux deployment

Target: linux/$Architecture

1. Copy the environment template: ``cp .env.example .env``
2. Configure ``.env``, especially the user/admin JWT secrets and admin credentials.
3. Make the binary executable: ``chmod +x playmesh-go-server``
4. Start it from this directory: ``./playmesh-go-server``

The server reads ``server.json`` and ``.env`` from its working directory.
The default configuration requires ClamAV and the ``clamscan`` command. See README.md.
The runtime user needs read/write permissions for the pre-created ``data/`` directory.
"@
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText(
        (Join-Path $bundleRoot "RUN-LINUX.md"),
        $linuxReadme,
        $utf8WithoutBom
    )

    $signature = New-Object byte[] 4
    $stream = [System.IO.File]::OpenRead($binaryPath)
    try {
        if ($stream.Read($signature, 0, 4) -ne 4) {
            throw "The build output is too short to contain an ELF header."
        }
    }
    finally {
        $stream.Dispose()
    }
    if (
        $signature[0] -ne 0x7F -or
        $signature[1] -ne 0x45 -or
        $signature[2] -ne 0x4C -or
        $signature[3] -ne 0x46
    ) {
        throw "The build output is not a valid Linux ELF file."
    }

    $manifestLines = Get-ChildItem -LiteralPath $bundleRoot -File -Recurse |
        Sort-Object FullName |
        ForEach-Object {
            $relativePath = $_.FullName.Substring($bundleRoot.Length + 1).Replace("\", "/")
            $fileHash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            "$fileHash  $relativePath"
        }
    [System.IO.File]::WriteAllLines(
        (Join-Path $bundleRoot "SHA256SUMS"),
        [string[]]$manifestLines,
        $utf8WithoutBom
    )

    Write-Host "Creating the archive..."
    & $tarCommand.Source "-czf" $archivePath "-C" $stagingRoot $artifactName
    if ($LASTEXITCODE -ne 0) {
        throw "tar failed with exit code $LASTEXITCODE"
    }
}
finally {
    Restore-ProcessEnvironment -Values $previousEnvironment
    if ($locationPushed) {
        Pop-Location
    }
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}

$archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText(
    $checksumPath,
    "$archiveHash  $([System.IO.Path]::GetFileName($archivePath))`n",
    $utf8WithoutBom
)

Write-Host ""
Write-Host "Linux server package completed:"
Write-Host "  Archive: $archivePath"
Write-Host "  Checksum: $checksumPath"
Write-Host "  SHA256: $archiveHash"
