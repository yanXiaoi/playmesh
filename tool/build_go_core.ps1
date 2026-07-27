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

    $output = Join-Path $projectRoot "android/app/libs/playmesh_core.aar"
    New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null

    $savedAndroidHome = $env:ANDROID_HOME
    $savedAndroidSdkRoot = $env:ANDROID_SDK_ROOT
    Push-Location $goCoreRoot
    try {
        $env:ANDROID_HOME = $androidSdk
        $env:ANDROID_SDK_ROOT = $androidSdk
        & $gomobile bind -target=android -androidapi=24 -o $output ./mobile
        if ($LASTEXITCODE -ne 0) {
            throw "Android Go Core AAR build failed"
        }
    } finally {
        Pop-Location
        $env:ANDROID_HOME = $savedAndroidHome
        $env:ANDROID_SDK_ROOT = $savedAndroidSdkRoot
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
