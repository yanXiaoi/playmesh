param(
    [ValidateSet("android", "windows", "all")]
    [string]$Target = "all",

    [string]$ApkSigGoRoot = $env:PLAYMESH_APKSIG_GO_ROOT
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$goCoreRoot = Join-Path $projectRoot "go-core"
$expectedApkSigGoRevision = "a0389a9d7f83032504713ac6052f85edfb52f64b"
$expectedApkSigGoModuleVersion = "v1.1.0"

function Resolve-ApkSigGoRoot {
    $goCoreModuleText = Get-Content -LiteralPath (Join-Path $goCoreRoot "go.mod") -Raw -Encoding UTF8
    $requiredVersionPattern = '(?m)^\s*github\.com/agusibrahim/apksig-go\s+' +
        [regex]::Escape($expectedApkSigGoModuleVersion) + '\s*$'
    if ($goCoreModuleText -notmatch $requiredVersionPattern) {
        throw "go-core must require apksig-go $expectedApkSigGoModuleVersion"
    }

    $candidates = @()
    if ($ApkSigGoRoot) {
        $candidates += $ApkSigGoRoot
    }

    $vendoredCandidate = Join-Path $projectRoot "third_party/apksig-go"
    $projectGroupRoot = Split-Path -Parent (Split-Path -Parent $projectRoot)
    $workspaceCandidate = Join-Path $projectGroupRoot "go/apksig-go"
    $candidates += $vendoredCandidate
    $candidates += $workspaceCandidate

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
            continue
        }
        $resolved = (Resolve-Path -LiteralPath $candidate).Path
        $moduleFile = Join-Path $resolved "go.mod"
        if (-not (Test-Path -LiteralPath $moduleFile -PathType Leaf)) {
            continue
        }
        $moduleText = Get-Content -LiteralPath $moduleFile -Raw -Encoding UTF8
        if ($moduleText -notmatch '(?m)^module\s+github\.com/agusibrahim/apksig-go\s*$') {
            continue
        }

        $gitDirectory = Join-Path $resolved ".git"
        if (Test-Path -LiteralPath $gitDirectory) {
            $revision = (& git -C $resolved rev-parse HEAD).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $revision) {
                throw "Unable to read apksig-go revision from $resolved"
            }
            if ($revision -ne $expectedApkSigGoRevision) {
                throw "Unsupported apksig-go revision $revision; expected $expectedApkSigGoRevision"
            }
            $trackedChanges = (& git -C $resolved status --porcelain --untracked-files=no)
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to inspect apksig-go working tree at $resolved"
            }
            if ($trackedChanges) {
                throw "apksig-go has tracked local changes; use the pinned clean revision $expectedApkSigGoRevision"
            }
        }
        return $resolved
    }

    throw "Unable to find apksig-go. Pass -ApkSigGoRoot or set PLAYMESH_APKSIG_GO_ROOT. Expected revision: $expectedApkSigGoRevision"
}

function Add-ApkSigNoticesToAar {
    param(
        [Parameter(Mandatory = $true)][string]$AarPath,
        [Parameter(Mandatory = $true)][string]$ResolvedApkSigGoRoot
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::Open(
        $AarPath,
        [System.IO.Compression.ZipArchiveMode]::Update
    )
    try {
        foreach ($notice in @(
            @{ Source = "LICENSE"; Entry = "META-INF/LICENSE-apksig-go.txt" },
            @{ Source = "NOTICE"; Entry = "META-INF/NOTICE-apksig-go.txt" }
        )) {
            $source = Join-Path $ResolvedApkSigGoRoot $notice.Source
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                throw "Missing apksig-go attribution file: $source"
            }
            $existing = $archive.GetEntry($notice.Entry)
            if ($existing) {
                $existing.Delete()
            }
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive,
                $source,
                $notice.Entry,
                [System.IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    } finally {
        $archive.Dispose()
    }
}

function Assert-MainAppAndroidAar {
    param([Parameter(Mandatory = $true)][string]$AarPath)

    $archive = [IO.Compression.ZipFile]::OpenRead($AarPath)
    try {
        foreach ($requiredEntry in @(
            "classes.jar",
            "META-INF/LICENSE-apksig-go.txt",
            "META-INF/NOTICE-apksig-go.txt"
        )) {
            if (-not $archive.GetEntry($requiredEntry)) {
                throw "Main App AAR is missing $requiredEntry"
            }
        }
        $classStream = $archive.GetEntry("classes.jar").Open()
        try {
            $classes = [IO.Compression.ZipArchive]::new(
                $classStream,
                [IO.Compression.ZipArchiveMode]::Read,
                $false
            )
            try {
                $classNames = @($classes.Entries.FullName)
            } finally {
                $classes.Dispose()
            }
        } finally {
            $classStream.Dispose()
        }
    } finally {
        $archive.Dispose()
    }

    foreach ($requiredClass in @("mobile/Mobile.class", "appnative/Appnative.class")) {
        if ($classNames -notcontains $requiredClass) {
            throw "Main App AAR is missing $requiredClass"
        }
    }
    if (@($classNames | Where-Object { $_ -eq "go/Seq.class" }).Count -ne 1) {
        throw "Main App AAR must contain exactly one Go runtime bridge"
    }
}

function New-GoCoreWorkspace {
    param([Parameter(Mandatory = $true)][string]$ResolvedApkSigGoRoot)

    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("playmesh-go-work-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    Push-Location $temporaryRoot
    try {
        & go work init $goCoreRoot $ResolvedApkSigGoRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to create temporary Go workspace"
        }
    } catch {
        Pop-Location
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        throw
    }
    Pop-Location
    return [pscustomobject]@{
        Root = $temporaryRoot
        File = Join-Path $temporaryRoot "go.work"
    }
}

function Remove-GoCoreWorkspace {
    param([Parameter(Mandatory = $true)]$Workspace)

    $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolvedRoot = [IO.Path]::GetFullPath($Workspace.Root)
    if (-not $resolvedRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Split-Path -Leaf $resolvedRoot).StartsWith("playmesh-go-work-", [StringComparison]::Ordinal)) {
        throw "Refusing to remove unexpected Go workspace path: $resolvedRoot"
    }
    if (Test-Path -LiteralPath $resolvedRoot) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}

function Add-GoBinToPath {
    $goPath = (& go env GOPATH).Trim()
    if (-not $goPath) {
        throw "Unable to resolve GOPATH"
    }

    $goBin = Join-Path $goPath "bin"
    if (-not (($env:Path -split ";") -contains $goBin)) {
        $env:Path = "$goBin;$env:Path"
    }

    return $goBin
}

function Resolve-AndroidSdk {
    foreach ($candidate in @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $localPropertiesPath = Join-Path $projectRoot 'android\local.properties'
    if (Test-Path -LiteralPath $localPropertiesPath -PathType Leaf) {
        $sdkProperty = Get-Content -LiteralPath $localPropertiesPath -Encoding UTF8 |
            Where-Object { $_ -match '^sdk\.dir=(.+)$' } |
            Select-Object -First 1
        if ($sdkProperty -and $sdkProperty -match '^sdk\.dir=(.+)$') {
            $candidate = $matches[1] -replace '\\\\', '\'
            if (Test-Path -LiteralPath $candidate -PathType Container) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }

    throw 'Android SDK is not configured. Set ANDROID_SDK_ROOT/ANDROID_HOME or android/local.properties sdk.dir.'
}

function Build-AndroidCore {
    $goBin = Add-GoBinToPath
    $gomobile = Join-Path $goBin "gomobile.exe"
    if (-not (Test-Path $gomobile)) {
        throw "gomobile is missing; run go install golang.org/x/mobile/cmd/gomobile@latest"
    }
    $androidSdk = Resolve-AndroidSdk
    $resolvedApkSigGoRoot = Resolve-ApkSigGoRoot

    $output = Join-Path $projectRoot "android/app/libs/playmesh_core.aar"
    New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null

    $savedAndroidHome = $env:ANDROID_HOME
    $savedAndroidSdkRoot = $env:ANDROID_SDK_ROOT
    $savedGoWork = $env:GOWORK
    Push-Location $goCoreRoot
    try {
        $env:ANDROID_HOME = $androidSdk
        $env:ANDROID_SDK_ROOT = $androidSdk
        # gomobile creates a temporary gobind module that cannot join a
        # caller-provided workspace. The required v1.1.0 resolves to the same
        # pinned revision validated by Resolve-ApkSigGoRoot.
        $env:GOWORK = "off"
        & $gomobile bind -target=android -androidapi=24 -trimpath '-ldflags=-s -w' -o $output ./mobile ./appnative
        if ($LASTEXITCODE -ne 0) {
            throw "Android Go Core AAR build failed"
        }
    } finally {
        Pop-Location
        $env:ANDROID_HOME = $savedAndroidHome
        $env:ANDROID_SDK_ROOT = $savedAndroidSdkRoot
        $env:GOWORK = $savedGoWork
    }
    Add-ApkSigNoticesToAar -AarPath $output -ResolvedApkSigGoRoot $resolvedApkSigGoRoot
    Assert-MainAppAndroidAar -AarPath $output
}

function Build-WindowsCore {
    $outputDirectory = Join-Path $projectRoot "build/go-core/windows"
    $output = Join-Path $outputDirectory "playmesh-core.exe"
    $apkSignerOutput = Join-Path $outputDirectory "playmesh-apksign.exe"
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

    Push-Location $goCoreRoot
    try {
        & go build -buildvcs=false -trimpath -o $output .
        if ($LASTEXITCODE -ne 0) {
            throw "Windows Go Core build failed"
        }
    } finally {
        Pop-Location
    }

    $resolvedApkSigGoRoot = Resolve-ApkSigGoRoot
    $goWorkspace = New-GoCoreWorkspace -ResolvedApkSigGoRoot $resolvedApkSigGoRoot
    $savedCgoEnabled = $env:CGO_ENABLED
    $savedGoWork = $env:GOWORK
    Push-Location $goCoreRoot
    try {
        $env:CGO_ENABLED = "0"
        $env:GOWORK = $goWorkspace.File
        & go build -buildvcs=false -trimpath '-ldflags=-s -w' -o $apkSignerOutput ./cmd/playmesh-apksign
        if ($LASTEXITCODE -ne 0) {
            throw "Windows APK signer sidecar build failed"
        }
    } finally {
        Pop-Location
        $env:CGO_ENABLED = $savedCgoEnabled
        $env:GOWORK = $savedGoWork
        Remove-GoCoreWorkspace -Workspace $goWorkspace
    }

    Copy-Item -LiteralPath (Join-Path $resolvedApkSigGoRoot "LICENSE") `
        -Destination (Join-Path $outputDirectory "APKSIG-GO-LICENSE.txt") `
        -Force
    Copy-Item -LiteralPath (Join-Path $resolvedApkSigGoRoot "NOTICE") `
        -Destination (Join-Path $outputDirectory "APKSIG-GO-NOTICE.txt") `
        -Force
}

if ($Target -eq "android" -or $Target -eq "all") {
    Build-AndroidCore
}
if ($Target -eq "windows" -or $Target -eq "all") {
    Build-WindowsCore
}
