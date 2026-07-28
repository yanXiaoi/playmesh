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
$archiveTempPath = "$archivePath.new"
$publishedArchivePath = $archivePath
$checksumPath = "$publishedArchivePath.sha256"
$binaryPath = Join-Path $bundleRoot "playmesh-go-server"
$standaloneBinaryPath = Join-Path $outputRoot $artifactName

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
Assert-PathInside -ChildPath $archiveTempPath -ParentPath $outputRoot
Assert-PathInside -ChildPath $checksumPath -ParentPath $outputRoot
Assert-PathInside -ChildPath $standaloneBinaryPath -ParentPath $outputRoot

if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}
if (Test-Path -LiteralPath $archiveTempPath) {
    Remove-Item -LiteralPath $archiveTempPath -Force
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

    $buildVersion = "dev"
    $buildCommit = "unknown"
    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    if ($null -ne $gitCommand) {
        $describedVersion = & $gitCommand.Source describe --tags --always --dirty 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($describedVersion)) {
            $buildVersion = ([string]$describedVersion).Trim()
        }
        $describedCommit = & $gitCommand.Source rev-parse --short=12 HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($describedCommit)) {
            $buildCommit = ([string]$describedCommit).Trim()
        }
    }
    $builtAt = [System.DateTime]::UtcNow.ToString(
        "yyyy-MM-ddTHH:mm:ssZ",
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $linkerFlags = "-s -w" +
        " -X go-server/internal/buildinfo.Version=$buildVersion" +
        " -X go-server/internal/buildinfo.Commit=$buildCommit" +
        " -X go-server/internal/buildinfo.BuiltAt=$builtAt"

    $env:GOOS = "linux"
    $env:GOARCH = $Architecture
    $env:CGO_ENABLED = "0"

    Write-Host "Building $buildVersion for linux/$Architecture..."
    Invoke-Go -Arguments @(
        "build",
        "-buildvcs=false",
        "-trimpath",
        "-ldflags=$linkerFlags",
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

    Copy-Item -LiteralPath $binaryPath -Destination $standaloneBinaryPath -Force

    Write-Host "Creating the archive..."
    & $tarCommand.Source "-czf" $archiveTempPath "-C" $stagingRoot $artifactName
    if ($LASTEXITCODE -ne 0) {
        throw "tar failed with exit code $LASTEXITCODE"
    }
    if (Test-Path -LiteralPath $archivePath) {
        try {
            Copy-Item -LiteralPath $archiveTempPath -Destination $archivePath -Force
        }
        catch {
            $safeVersion = $buildVersion -replace "[^A-Za-z0-9._-]", "-"
            $publishedArchivePath = Join-Path(
                $outputRoot,
                "$artifactName-$safeVersion.tar.gz"
            )
            Assert-PathInside -ChildPath $publishedArchivePath -ParentPath $outputRoot
            Copy-Item -LiteralPath $archiveTempPath -Destination $publishedArchivePath -Force
            Write-Warning(
                "The default archive is in use; wrote the versioned archive instead: " +
                $publishedArchivePath
            )
        }
        Remove-Item -LiteralPath $archiveTempPath -Force
    }
    else {
        Move-Item -LiteralPath $archiveTempPath -Destination $archivePath
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
    if (Test-Path -LiteralPath $archiveTempPath) {
        Remove-Item -LiteralPath $archiveTempPath -Force
    }
}

$checksumPath = "$publishedArchivePath.sha256"
Assert-PathInside -ChildPath $checksumPath -ParentPath $outputRoot
$archiveHash = (Get-FileHash -LiteralPath $publishedArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
$binaryHash = (Get-FileHash -LiteralPath $standaloneBinaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText(
    $checksumPath,
    "$archiveHash  $([System.IO.Path]::GetFileName($publishedArchivePath))`n",
    $utf8WithoutBom
)

Write-Host ""
Write-Host "Linux server package completed:"
Write-Host "  Archive: $publishedArchivePath"
Write-Host "  Checksum: $checksumPath"
Write-Host "  Archive SHA256: $archiveHash"
Write-Host "  Binary: $standaloneBinaryPath"
Write-Host "  Binary SHA256: $binaryHash"
