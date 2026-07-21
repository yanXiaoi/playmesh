param(
    [ValidateSet("android", "windows", "all")]
    [string]$Target = "all"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$goCoreRoot = Join-Path $projectRoot "go-core"

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

function Build-AndroidCore {
    $goBin = Add-GoBinToPath
    $gomobile = Join-Path $goBin "gomobile.exe"
    if (-not (Test-Path $gomobile)) {
        throw "gomobile is missing; run go install golang.org/x/mobile/cmd/gomobile@latest"
    }
    if (-not $env:ANDROID_HOME) {
        throw "ANDROID_HOME is not configured"
    }

    $output = Join-Path $projectRoot "android/app/libs/playmesh_core.aar"
    New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null

    Push-Location $goCoreRoot
    try {
        & $gomobile bind -target=android -androidapi=24 -o $output ./mobile
        if ($LASTEXITCODE -ne 0) {
            throw "Android Go Core AAR build failed"
        }
    } finally {
        Pop-Location
    }
}

function Build-WindowsCore {
    $outputDirectory = Join-Path $projectRoot "build/go-core/windows"
    $output = Join-Path $outputDirectory "playmesh-core.exe"
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
}

if ($Target -eq "android" -or $Target -eq "all") {
    Build-AndroidCore
}
if ($Target -eq "windows" -or $Target -eq "all") {
    Build-WindowsCore
}
