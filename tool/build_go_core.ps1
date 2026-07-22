param(
    [ValidateSet("harmony", "android", "windows", "all")]
    [string]$Target = "all",
    [string]$HarmonyNdk,
    [string]$HarmonyGo
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

function Resolve-HarmonyNativeSdk {
    param([string]$ConfiguredPath)

    $roots = [System.Collections.Generic.List[string]]::new()
    if ($ConfiguredPath) {
        $roots.Add($ConfiguredPath)
    } else {
        foreach ($value in @(
            $env:PLAYMESH_HARMONY_NDK,
            $env:DEVECO_SDK_HOME,
            $env:OHOS_SDK_HOME,
            $env:HARMONYOS_SDK_HOME,
            (Join-Path $env:LOCALAPPDATA 'OpenHarmony\Sdk'),
            (Join-Path $env:LOCALAPPDATA 'Huawei\Sdk')
        )) {
            if ($value) {
                $roots.Add($value)
            }
        }
    }

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }
        $resolvedRoot = (Resolve-Path -LiteralPath $root).Path
        $directClang = Join-Path $resolvedRoot 'llvm\bin\clang.exe'
        if ((Test-Path -LiteralPath $directClang) -and
            (Test-Path -LiteralPath (Join-Path $resolvedRoot 'sysroot'))) {
            return $resolvedRoot
        }

        $clang = Get-ChildItem -LiteralPath $resolvedRoot `
            -Recurse -Filter clang.exe -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -match '[\\/]native[\\/]llvm[\\/]bin[\\/]clang\.exe$'
            } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($clang) {
            $nativeRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $clang.FullName))
            if (Test-Path -LiteralPath (Join-Path $nativeRoot 'sysroot')) {
                return $nativeRoot
            }
        }
    }

    throw 'HarmonyOS Native SDK was not found. Pass -HarmonyNdk or set PLAYMESH_HARMONY_NDK to the SDK native directory (it must contain llvm/bin/clang.exe and sysroot).'
}

function Resolve-HarmonyGo {
    param([string]$ConfiguredPath)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($ConfiguredPath) {
        $candidates.Add($ConfiguredPath)
    } elseif ($env:PLAYMESH_HARMONY_GO) {
        $candidates.Add($env:PLAYMESH_HARMONY_GO)
    } else {
        $runtimeRoot = 'D:\KaiFaTool\runtime\go'
        if (Test-Path -LiteralPath $runtimeRoot) {
            Get-ChildItem -LiteralPath $runtimeRoot -Directory -Filter 'go-*-openharmony' |
                Sort-Object Name -Descending |
                ForEach-Object { $candidates.Add($_.FullName) }
        }
        $candidates.Add((Join-Path $projectRoot 'build\toolchains\ohos-go-src'))
    }

    foreach ($candidate in $candidates) {
        $executable = $candidate
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $executable = Join-Path $candidate 'bin\go.exe'
        }
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            continue
        }

        $targets = & $executable tool dist list 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -and $targets -match '(?m)^openharmony/arm64\s*$') {
            return (Resolve-Path -LiteralPath $executable).Path
        }
    }

    throw 'OpenHarmony SIG Go was not found. Run tool/install_harmony_go.ps1, pass -HarmonyGo, or set PLAYMESH_HARMONY_GO. The toolchain must support openharmony/arm64.'
}

function Build-HarmonyCore {
    $nativeSdk = Resolve-HarmonyNativeSdk $HarmonyNdk
    $harmonyGoExecutable = Resolve-HarmonyGo $HarmonyGo
    $clang = Join-Path $nativeSdk 'llvm\bin\clang.exe'
    $sysroot = Join-Path $nativeSdk 'sysroot'
    $outputDirectory = Join-Path $projectRoot 'build\go-core\harmony\arm64-v8a'
    $output = Join-Path $outputDirectory 'libplaymesh_core.so'
    $destinationDirectory = Join-Path $projectRoot 'ohos\playmesh_harmony_capabilities\src\main\libs\arm64-v8a'
    $destination = Join-Path $destinationDirectory 'libplaymesh_core.so'
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null

    $compilerWrapper = Join-Path $outputDirectory 'ohos-clang.cmd'
    $wrapperText = "@echo off`r`n`"$clang`" --target=aarch64-linux-ohos --sysroot=`"$sysroot`" %*`r`n"
    [IO.File]::WriteAllText(
        $compilerWrapper,
        $wrapperText,
        [Text.ASCIIEncoding]::new()
    )

    $savedEnvironment = @{
        GOOS = $env:GOOS
        GOARCH = $env:GOARCH
        CGO_ENABLED = $env:CGO_ENABLED
        CC = $env:CC
        GOTOOLCHAIN = $env:GOTOOLCHAIN
    }
    Push-Location $goCoreRoot
    try {
        $env:GOOS = 'openharmony'
        $env:GOARCH = 'arm64'
        $env:CGO_ENABLED = '1'
        $env:CC = $compilerWrapper
        $env:GOTOOLCHAIN = 'local'
        & $harmonyGoExecutable build '-modfile=go.harmony.mod' `
            -buildvcs=false -trimpath -buildmode=c-shared `
            -ldflags='-s -w -extldflags=-Wl,-soname,libplaymesh_core.so' `
            -o $output .\harmony
        if ($LASTEXITCODE -ne 0) {
            throw 'HarmonyOS Go Core shared-library build failed.'
        }
    } finally {
        Pop-Location
        $env:GOOS = $savedEnvironment.GOOS
        $env:GOARCH = $savedEnvironment.GOARCH
        $env:CGO_ENABLED = $savedEnvironment.CGO_ENABLED
        $env:CC = $savedEnvironment.CC
        $env:GOTOOLCHAIN = $savedEnvironment.GOTOOLCHAIN
    }

    if (-not (Test-Path -LiteralPath $output)) {
        throw "HarmonyOS Go Core output is missing: $output"
    }
    $header = [IO.File]::ReadAllBytes($output)
    if ($header.Length -lt 4 -or
        $header[0] -ne 0x7f -or
        $header[1] -ne 0x45 -or
        $header[2] -ne 0x4c -or
        $header[3] -ne 0x46) {
        throw "HarmonyOS Go Core output is not an ELF shared library: $output"
    }

    $llvmNm = Join-Path $nativeSdk 'llvm\bin\llvm-nm.exe'
    if (-not (Test-Path -LiteralPath $llvmNm)) {
        throw "llvm-nm.exe is missing from the HarmonyOS Native SDK: $llvmNm"
    }
    $symbols = & $llvmNm -D --defined-only $output 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect HarmonyOS Go Core exports: $symbols"
    }
    foreach ($requiredSymbol in @('PlaymeshCoreStart', 'PlaymeshCoreStop', 'PlaymeshCoreFree')) {
        if ($symbols -notmatch "\b$requiredSymbol\b") {
            throw "HarmonyOS Go Core is missing export $requiredSymbol."
        }
    }

    $llvmReadElf = Join-Path $nativeSdk 'llvm\bin\llvm-readelf.exe'
    if (-not (Test-Path -LiteralPath $llvmReadElf)) {
        throw "llvm-readelf.exe is missing from the HarmonyOS Native SDK: $llvmReadElf"
    }
    $elfHeader = & $llvmReadElf -h $output 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $elfHeader -notmatch 'Machine:\s+AArch64') {
        throw "HarmonyOS Go Core is not an AArch64 ELF library: $elfHeader"
    }
    $dynamicSection = & $llvmReadElf -d $output 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or
        $dynamicSection -notmatch 'SONAME.*\[libplaymesh_core\.so\]') {
        throw 'HarmonyOS Go Core must advertise SONAME libplaymesh_core.so.'
    }

    Copy-Item -LiteralPath $output -Destination $destination -Force
    Write-Output "HarmonyOS Go Core: $destination"
}

if ($Target -eq "android" -or $Target -eq "all") {
    Build-AndroidCore
}
if ($Target -eq "harmony" -or $Target -eq "all") {
    Build-HarmonyCore
}
if ($Target -eq "windows" -or $Target -eq "all") {
    Build-WindowsCore
}
