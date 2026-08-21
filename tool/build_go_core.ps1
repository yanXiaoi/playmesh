param(
    [ValidateSet("android", "windows", "windows-apksign", "all")]
    [string]$Target = "all"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$goCoreRoot = Join-Path $projectRoot "go-core"
$privateGoCorePreparation = Join-Path $projectRoot "runtime\src\tool\prepare_private_go_core.ps1"
$exporterGoCoreRoot = $null
$exporterGoCoreStagingContainer = $null
$runtimePrivateKeyMarkers = $null
$expectedApkSigGoModuleVersion = "v1.1.0"
$expectedApkSigGoModuleSum = "h1:AIEXsulTTcvpbLxxe5Jq0gJN330BN/Hx3w8Fs32dDPI="
$expectedApkSigGoModSum = "h1:f944h8T5LQkSHTfKve9tkbBRzO9+21ERHyC0daQQeRk="
$apkSigGoAttributionRoot = Join-Path $projectRoot "third_party/licenses/apksig-go"
$winResAttributionRoot = Join-Path $projectRoot "third_party/licenses/winres"
$nfntResizeAttributionRoot = Join-Path $projectRoot "third_party/licenses/nfnt-resize"
$goImageAttributionRoot = Join-Path $projectRoot "third_party/licenses/golang-x-image"

function Get-RuntimePrivateKeyMarkers {
    if ($null -ne $script:runtimePrivateKeyMarkers) {
        return $script:runtimePrivateKeyMarkers
    }
    $markers = [Collections.Generic.List[string]]::new()
    $null = $markers.Add("-----BEGIN PRIVATE KEY-----")
    $binaryEncoding = [Text.Encoding]::GetEncoding(28591)
    $privateKeyRoot = Join-Path $projectRoot "runtime\crypto"
    if (Test-Path -LiteralPath $privateKeyRoot -PathType Container) {
        foreach ($privateKeyFile in Get-ChildItem -LiteralPath $privateKeyRoot `
            -File -Filter "*-runtime-private.pem") {
            $pemText = [IO.File]::ReadAllText($privateKeyFile.FullName)
            $match = [Regex]::Match(
                $pemText,
                '-----BEGIN PRIVATE KEY-----\s*(?<body>[A-Za-z0-9+/=\s]+?)\s*-----END PRIVATE KEY-----',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant
            )
            if (-not $match.Success) {
                throw "Runtime private key is not a PKCS#8 PEM file: $($privateKeyFile.FullName)"
            }
            $null = $markers.Add($pemText.Trim())
            $der = [Convert]::FromBase64String(
                ($match.Groups['body'].Value -replace '\s', '')
            )
            $null = $markers.Add($binaryEncoding.GetString($der))
        }
    }
    $script:runtimePrivateKeyMarkers = @($markers)
    return $script:runtimePrivateKeyMarkers
}

function Assert-NoRuntimePrivateKeyMaterialInFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )
    $binaryEncoding = [Text.Encoding]::GetEncoding(28591)
    $contents = $binaryEncoding.GetString([IO.File]::ReadAllBytes($Path))
    foreach ($marker in Get-RuntimePrivateKeyMarkers) {
        if ($contents.IndexOf($marker, [StringComparison]::Ordinal) -ge 0) {
            throw "$Description contains Runtime private-key material"
        }
    }
}

function Get-ExporterGoCoreRoot {
    if ($script:exporterGoCoreRoot) {
        return $script:exporterGoCoreRoot
    }
    if (-not (Test-Path -LiteralPath $privateGoCorePreparation -PathType Leaf)) {
        throw "Private Go staging helper is missing: $privateGoCorePreparation"
    }
    $privateStagingRoot = [IO.Path]::GetFullPath(
        (Join-Path $projectRoot "runtime\crypto\generated\staging")
    )
    $script:exporterGoCoreStagingContainer = Join-Path $privateStagingRoot (
        "main-exporter-" + [guid]::NewGuid().ToString("N")
    )
    $stagedGoCore = Join-Path $script:exporterGoCoreStagingContainer "go-core"
    $manifestText = (& $privateGoCorePreparation `
        -Variant exporter `
        -Destination $stagedGoCore | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $manifestText) {
        throw "Unable to prepare the private exporter Go staging tree"
    }
    try {
        $manifest = $manifestText | ConvertFrom-Json
    } catch {
        throw "Private Go staging helper returned invalid JSON"
    }
    if ($manifest.variant -ne "exporter" -or
        $manifest.buildTags -ne "playmesh_private_crypto" -or
        $manifest.containsRuntimePrivateKey -ne $false -or
        -not (Test-Path -LiteralPath (Join-Path $manifest.goCoreRoot "go.mod") -PathType Leaf)) {
        throw "Private Go exporter staging contract is invalid"
    }
    $pemFiles = @(Get-ChildItem -LiteralPath $manifest.goCoreRoot -File -Recurse -Filter "*.pem")
    if ($pemFiles.Count -ne 0) {
        throw "Main App exporter staging contains Runtime private-key material"
    }
    $savedGoWork = $env:GOWORK
    $savedGoFlags = $env:GOFLAGS
    Push-Location $manifest.goCoreRoot
    try {
        $env:GOWORK = "off"
        $env:GOFLAGS = "-buildvcs=false"
        & go test -tags playmesh_private_crypto ./runtimecrypto -count=1 |
            ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            throw "Private Runtime crypto provider tests failed"
        }
    } finally {
        Pop-Location
        $env:GOWORK = $savedGoWork
        $env:GOFLAGS = $savedGoFlags
    }
    $script:exporterGoCoreRoot = [IO.Path]::GetFullPath($manifest.goCoreRoot)
    return $script:exporterGoCoreRoot
}

function Remove-ExporterGoCoreStaging {
    if (-not $script:exporterGoCoreStagingContainer) {
        return
    }
    $stagingRoot = [IO.Path]::GetFullPath(
        (Join-Path $projectRoot "runtime\crypto\generated\staging")
    )
    $candidate = [IO.Path]::GetFullPath($script:exporterGoCoreStagingContainer)
    $prefix = $stagingRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Split-Path -Leaf $candidate).StartsWith("main-exporter-", [StringComparison]::Ordinal)) {
        throw "Refusing to clean unexpected private Go staging path: $candidate"
    }
    if (Test-Path -LiteralPath $candidate) {
        try {
            Remove-Item -LiteralPath $candidate -Recurse -Force
        } catch {
            Write-Warning "Unable to clean ignored private Go staging: $($_.Exception.Message)"
        }
    }
    $script:exporterGoCoreRoot = $null
    $script:exporterGoCoreStagingContainer = $null
}

function Assert-ApkSigGoModule {
    $goCoreModuleText = Get-Content -LiteralPath (Join-Path $goCoreRoot "go.mod") -Raw -Encoding UTF8
    $requiredVersionPattern = '(?m)^\s*github\.com/agusibrahim/apksig-go\s+' +
        [regex]::Escape($expectedApkSigGoModuleVersion) + '\s*$'
    if ($goCoreModuleText -notmatch $requiredVersionPattern) {
        throw "go-core must require apksig-go $expectedApkSigGoModuleVersion"
    }

    $goCoreSumLines = @(
        Get-Content -LiteralPath (Join-Path $goCoreRoot "go.sum") -Encoding UTF8
    )
    $requiredSumLines = @(
        "github.com/agusibrahim/apksig-go $expectedApkSigGoModuleVersion $expectedApkSigGoModuleSum",
        "github.com/agusibrahim/apksig-go $expectedApkSigGoModuleVersion/go.mod $expectedApkSigGoModSum"
    )
    foreach ($requiredSumLine in $requiredSumLines) {
        if ($goCoreSumLines -notcontains $requiredSumLine) {
            throw "go.sum is missing the pinned apksig-go checksum: $requiredSumLine"
        }
    }

    foreach ($attributionFile in @("LICENSE", "NOTICE")) {
        $attributionPath = Join-Path $apkSigGoAttributionRoot $attributionFile
        if (-not (Test-Path -LiteralPath $attributionPath -PathType Leaf)) {
            throw "Missing repository-owned apksig-go attribution file: $attributionPath"
        }
    }

    $savedGoWork = $env:GOWORK
    Push-Location $goCoreRoot
    try {
        # The public v1.1.0 module resolves to a0389a9d7f83032504713ac6052f85edfb52f64b.
        # GOWORK=off prevents a developer's surrounding workspace from replacing
        # the checksum-pinned dependency with an arbitrary local checkout.
        $env:GOWORK = "off"
        $downloadJson = (& go mod download -json `
            "github.com/agusibrahim/apksig-go@$expectedApkSigGoModuleVersion" |
            Out-String)
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to obtain checksum-pinned apksig-go $expectedApkSigGoModuleVersion from the Go module cache or configured proxy"
        }
        $download = $downloadJson | ConvertFrom-Json
        if ($download.Path -ne "github.com/agusibrahim/apksig-go" -or
            $download.Version -ne $expectedApkSigGoModuleVersion -or
            $download.Sum -ne $expectedApkSigGoModuleSum -or
            $download.GoModSum -ne $expectedApkSigGoModSum) {
            throw "Resolved apksig-go module does not match the pinned v1.1.0 checksums"
        }
        $selectedModuleJson = (& go list -mod=readonly -m -json `
            "github.com/agusibrahim/apksig-go" | Out-String)
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to inspect the selected apksig-go module"
        }
        $selectedModule = $selectedModuleJson | ConvertFrom-Json
        # `go list -m -json` omits Replace when the selected module has no
        # replacement. The release script enables StrictMode, so directly
        # reading a missing property would abort every clean build.
        $hasModuleReplacement = $null -ne $selectedModule.PSObject.Properties['Replace']
        if ($selectedModule.Path -ne "github.com/agusibrahim/apksig-go" -or
            $selectedModule.Version -ne $expectedApkSigGoModuleVersion -or
            $hasModuleReplacement) {
            throw "go-core must use the public checksum-pinned apksig-go $expectedApkSigGoModuleVersion module without replacement"
        }
    } finally {
        Pop-Location
        $env:GOWORK = $savedGoWork
    }

    return $apkSigGoAttributionRoot
}

function Assert-WindowsResourceModules {
    $modules = @(
        [pscustomobject]@{
            Path = "github.com/tc-hib/winres"
            Version = "v0.3.1"
            Sum = "h1:CwRjEGrKdbi5CvZ4ID+iyVhgyfatxFoizjPhzez9Io4="
            GoModSum = "h1:C/JaNhH3KBvhNKVbvdlDWkbMDO9H4fKKDaN7/07SSuk="
        },
        [pscustomobject]@{
            Path = "github.com/nfnt/resize"
            Version = "v0.0.0-20180221191011-83c6a9932646"
            Sum = "h1:zYyBkD/k9seD2A7fsi6Oo2LfFZAehjjQMERAvZLEDnQ="
            GoModSum = "h1:jpp1/29i3P1S/RLdc7JQKbRpFeM1dOBd8T9ki5s+AY8="
        },
        [pscustomobject]@{
            Path = "golang.org/x/image"
            Version = "v0.44.0"
            Sum = "h1:+tDekMZED9+LrtB3G5xzRggpVh9CARjZqROla3R3R+I="
            GoModSum = "h1:V8K3KE9KKKE+pLpQDOeN18w9oacNSvy1tDOirTu4xtY="
        }
    )
    $goCoreModuleText = Get-Content -LiteralPath (Join-Path $goCoreRoot "go.mod") `
        -Raw -Encoding UTF8
    $goCoreSumLines = @(
        Get-Content -LiteralPath (Join-Path $goCoreRoot "go.sum") -Encoding UTF8
    )
    foreach ($module in $modules) {
        $requiredVersionPattern = '(?m)^\s*' +
            [regex]::Escape($module.Path) + '\s+' +
            [regex]::Escape($module.Version) + '\s*(?://\s+indirect)?\s*$'
        if ($goCoreModuleText -notmatch $requiredVersionPattern) {
            throw "go-core must require $($module.Path) $($module.Version)"
        }
        foreach ($requiredSumLine in @(
            "$($module.Path) $($module.Version) $($module.Sum)",
            "$($module.Path) $($module.Version)/go.mod $($module.GoModSum)"
        )) {
            if ($goCoreSumLines -notcontains $requiredSumLine) {
                throw "go.sum is missing the pinned checksum: $requiredSumLine"
            }
        }
    }

    $attributionFiles = @(
        [pscustomobject]@{
            Path = Join-Path $winResAttributionRoot "LICENSE"
            SHA256 = "0B312A18265BE4D536B0FCC33F0F18E47D10BBD9559FF8B0786606173610E22C"
        },
        [pscustomobject]@{
            Path = Join-Path $nfntResizeAttributionRoot "LICENSE"
            SHA256 = "7B850692B15C71706BC6906B51D6375C1404C2D26233078335B6AAA7DEF8B3F4"
        },
        [pscustomobject]@{
            Path = Join-Path $goImageAttributionRoot "LICENSE"
            SHA256 = "911F8F5782931320F5B8D1160A76365B83AEA6447EE6C04FA6D5591467DB9DAD"
        },
        [pscustomobject]@{
            Path = Join-Path $goImageAttributionRoot "PATENTS"
            SHA256 = "96F408BFAE65BF137FC2525D3ECB030271C50C1E90799F87ABF8846D8DD505CC"
        }
    )
    foreach ($attribution in $attributionFiles) {
        if (-not (Test-Path -LiteralPath $attribution.Path -PathType Leaf)) {
            throw "Missing repository-owned Windows resource attribution file: $($attribution.Path)"
        }
        $actualHash = (Get-FileHash -LiteralPath $attribution.Path -Algorithm SHA256).Hash
        if ($actualHash -ne $attribution.SHA256) {
            throw "Windows resource attribution file does not match its verified upstream text: $($attribution.Path)"
        }
    }

    $savedGoWork = $env:GOWORK
    Push-Location $goCoreRoot
    try {
        $env:GOWORK = "off"
        foreach ($module in $modules) {
            $downloadJson = (& go mod download -json `
                "$($module.Path)@$($module.Version)" | Out-String)
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to obtain checksum-pinned $($module.Path) $($module.Version)"
            }
            $download = $downloadJson | ConvertFrom-Json
            if ($download.Path -ne $module.Path -or
                $download.Version -ne $module.Version -or
                $download.Sum -ne $module.Sum -or
                $download.GoModSum -ne $module.GoModSum) {
                throw "Resolved module does not match pinned checksums: $($module.Path) $($module.Version)"
            }
            $selectedModuleJson = (& go list -mod=readonly -m -json `
                $module.Path | Out-String)
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to inspect selected module: $($module.Path)"
            }
            $selectedModule = $selectedModuleJson | ConvertFrom-Json
            $hasModuleReplacement = $null -ne `
                $selectedModule.PSObject.Properties['Replace']
            if ($selectedModule.Path -ne $module.Path -or
                $selectedModule.Version -ne $module.Version -or
                $hasModuleReplacement) {
                throw "go-core must use public checksum-pinned $($module.Path) $($module.Version) without replacement"
            }
        }
    } finally {
        Pop-Location
        $env:GOWORK = $savedGoWork
    }
}

function Add-ExporterAttributionsToAar {
    param(
        [Parameter(Mandatory = $true)][string]$AarPath,
        [Parameter(Mandatory = $true)][string]$ApkSigAttributionRoot
    )

    $jar = $null
    if ($env:JAVA_HOME) {
        $javaHomeJar = Join-Path $env:JAVA_HOME "bin\jar.exe"
        if (Test-Path -LiteralPath $javaHomeJar -PathType Leaf) {
            $jar = (Resolve-Path -LiteralPath $javaHomeJar).Path
        }
    }
    if (-not $jar) {
        $jarCommand = Get-Command "jar.exe" -CommandType Application `
            -ErrorAction SilentlyContinue
        if ($jarCommand) {
            $jar = $jarCommand.Source
        }
    }
    if (-not $jar) {
        throw "A JDK jar.exe is required to add Android AAR attribution files"
    }

    # Do not update gomobile's AAR with System.IO.Compression.ZipArchiveMode.Update.
    # gomobile writes entries with ZIP data descriptors. On some .NET versions,
    # Update preserves the descriptor flag while omitting the descriptor itself.
    # Central-directory readers can still list/extract that malformed archive, but
    # Gradle's streaming ExtractAarTransform rejects it with "invalid entry size".
    # The JDK jar tool rewrites the archive with internally consistent ZIP metadata.
    $stagingRoot = Join-Path (Split-Path -Parent $AarPath) (
        "aar-attribution-" + [guid]::NewGuid().ToString("N")
    )
    $stagingMetaInf = Join-Path $stagingRoot "META-INF"
    New-Item -ItemType Directory -Path $stagingMetaInf -Force | Out-Null
    try {
        $attributions = @(
            @{ Source = Join-Path $ApkSigAttributionRoot "LICENSE"; Entry = "META-INF/LICENSE-apksig-go.txt" },
            @{ Source = Join-Path $ApkSigAttributionRoot "NOTICE"; Entry = "META-INF/NOTICE-apksig-go.txt" },
            @{ Source = Join-Path $winResAttributionRoot "LICENSE"; Entry = "META-INF/LICENSE-winres.txt" },
            @{ Source = Join-Path $nfntResizeAttributionRoot "LICENSE"; Entry = "META-INF/LICENSE-nfnt-resize.txt" },
            @{ Source = Join-Path $goImageAttributionRoot "LICENSE"; Entry = "META-INF/LICENSE-golang-x-image.txt" },
            @{ Source = Join-Path $goImageAttributionRoot "PATENTS"; Entry = "META-INF/PATENTS-golang-x-image.txt" }
        )
        $jarArguments = @("uf", $AarPath)
        foreach ($attribution in $attributions) {
            $source = $attribution.Source
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                throw "Missing exporter attribution file: $source"
            }
            Copy-Item -LiteralPath $source -Destination (
                Join-Path $stagingRoot $attribution.Entry
            ) -Force
            $jarArguments += @("-C", $stagingRoot, $attribution.Entry)
        }

        & $jar @jarArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to add exporter attribution files to Android AAR"
        }
    } finally {
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force
        }
    }
}

function Assert-MainAppAndroidAar {
    param([Parameter(Mandatory = $true)][string]$AarPath)

    # Keep this validator self-contained. Attribution injection uses the JDK
    # jar tool and therefore no longer loads the .NET ZIP assemblies as a side
    # effect before this function runs.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($AarPath)
    $privateKeyMarkers = @(Get-RuntimePrivateKeyMarkers)
    $binaryEncoding = [Text.Encoding]::GetEncoding(28591)
    try {
        foreach ($requiredEntry in @(
            "classes.jar",
            "META-INF/LICENSE-apksig-go.txt",
            "META-INF/NOTICE-apksig-go.txt",
            "META-INF/LICENSE-winres.txt",
            "META-INF/LICENSE-nfnt-resize.txt",
            "META-INF/LICENSE-golang-x-image.txt",
            "META-INF/PATENTS-golang-x-image.txt"
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
                $mobileClass = $classes.GetEntry("mobile/Mobile.class")
                if ($null -eq $mobileClass) {
                    throw "Main App AAR is missing mobile/Mobile.class"
                }
                $mobileClassStream = $mobileClass.Open()
                try {
                    $mobileClassMemory = [IO.MemoryStream]::new()
                    try {
                        $mobileClassStream.CopyTo($mobileClassMemory)
                        $mobileClassText = [Text.Encoding]::GetEncoding(28591).GetString(
                            $mobileClassMemory.ToArray()
                        )
                    } finally {
                        $mobileClassMemory.Dispose()
                    }
                } finally {
                    $mobileClassStream.Dispose()
                }
                if ($mobileClassText.IndexOf(
                        "decryptRuntimePackage",
                        [StringComparison]::Ordinal
                    ) -ge 0) {
                    throw "Main App AAR must not expose the Runtime-only decryptRuntimePackage bridge"
                }
            } finally {
                $classes.Dispose()
            }
        } finally {
            $classStream.Dispose()
        }
        foreach ($entry in $archive.Entries) {
            $normalized = $entry.FullName -replace '\\', '/'
            if ($normalized -match '(?i)(?:^|/)(?:runtime/crypto|[^/]*private[^/]*\.pem)(?:/|$)') {
                throw "Main App AAR contains a Runtime private-key entry: $normalized"
            }
            if ($entry.Length -eq 0) {
                continue
            }
            $stream = $entry.Open()
            try {
                $memory = [IO.MemoryStream]::new()
                try {
                    $stream.CopyTo($memory)
                    $entryText = $binaryEncoding.GetString($memory.ToArray())
                } finally {
                    $memory.Dispose()
                }
            } finally {
                $stream.Dispose()
            }
            foreach ($marker in $privateKeyMarkers) {
                if ($entryText.IndexOf($marker, [StringComparison]::Ordinal) -ge 0) {
                    throw "Main App AAR contains embedded Runtime private-key material in $normalized"
                }
            }
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
    $apkSigAttribution = Assert-ApkSigGoModule
    Assert-WindowsResourceModules
    $privateGoCoreRoot = Get-ExporterGoCoreRoot

    $output = Join-Path $projectRoot "android/app/libs/playmesh_core.aar"
    New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null
    $temporaryOutputDirectory = Join-Path $projectRoot (
        "build/go-core/android/gomobile-" + [guid]::NewGuid().ToString("N")
    )
    $temporaryOutput = Join-Path $temporaryOutputDirectory "playmesh_core.aar"
    $temporarySources = Join-Path $temporaryOutputDirectory "playmesh_core-sources.jar"
    $sourcesOutput = Join-Path (Split-Path -Parent $output) "playmesh_core-sources.jar"
    New-Item -ItemType Directory -Path $temporaryOutputDirectory -Force | Out-Null

    $savedAndroidHome = $env:ANDROID_HOME
    $savedAndroidSdkRoot = $env:ANDROID_SDK_ROOT
    $savedGoWork = $env:GOWORK
    $savedGoFlags = $env:GOFLAGS
    Push-Location $privateGoCoreRoot
    try {
        $env:ANDROID_HOME = $androidSdk
        $env:ANDROID_SDK_ROOT = $androidSdk
        # gomobile creates a temporary gobind module that cannot join a
        # caller-provided workspace. The dependency is checksum-pinned by
        # go.mod/go.sum and prevalidated by Assert-ApkSigGoModule.
        $env:GOWORK = "off"
        # The temporary gobind module has no meaningful VCS identity. Disabling
        # stamping also avoids inheriting a parent repository with restricted
        # ownership in clean/isolated builders.
        $env:GOFLAGS = "-buildvcs=false"
        & $gomobile bind -target=android -androidapi=24 -trimpath `
            '-tags=playmesh_private_crypto' '-ldflags=-s -w' `
            -o $temporaryOutput ./mobile ./appnative
        if ($LASTEXITCODE -ne 0) {
            throw "Android Go Core AAR build failed"
        }
    } finally {
        Pop-Location
        $env:ANDROID_HOME = $savedAndroidHome
        $env:ANDROID_SDK_ROOT = $savedAndroidSdkRoot
        $env:GOWORK = $savedGoWork
        $env:GOFLAGS = $savedGoFlags
    }
    try {
        Add-ExporterAttributionsToAar `
            -AarPath $temporaryOutput `
            -ApkSigAttributionRoot $apkSigAttribution
        Assert-MainAppAndroidAar -AarPath $temporaryOutput
        Copy-Item -LiteralPath $temporaryOutput -Destination $output -Force
        try {
            # The source archive is IDE-only and can be memory-mapped by a
            # running Gradle/Java process. It must not block the release AAR.
            Copy-Item -LiteralPath $temporarySources -Destination $sourcesOutput -Force
        } catch {
            Write-Warning "Unable to refresh optional Go Core sources archive: $($_.Exception.Message)"
        }
    } finally {
        $androidBuildRoot = [IO.Path]::GetFullPath(
            (Join-Path $projectRoot "build/go-core/android")
        )
        $resolvedTemporaryOutputDirectory = [IO.Path]::GetFullPath(
            $temporaryOutputDirectory
        )
        if (-not $resolvedTemporaryOutputDirectory.StartsWith(
                $androidBuildRoot + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            -not (Split-Path -Leaf $resolvedTemporaryOutputDirectory).StartsWith(
                "gomobile-",
                [StringComparison]::Ordinal
            )) {
            throw "Refusing to clean unexpected Android Go build path: $resolvedTemporaryOutputDirectory"
        }
        if (Test-Path -LiteralPath $resolvedTemporaryOutputDirectory) {
            Remove-Item -LiteralPath $resolvedTemporaryOutputDirectory -Recurse -Force
        }
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

function Build-WindowsApkSigner {
    $outputDirectory = Join-Path $projectRoot "build/go-core/windows"
    $apkSignerOutput = Join-Path $outputDirectory "playmesh-apksign.exe"
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

    $apkSigAttribution = Assert-ApkSigGoModule
    Assert-WindowsResourceModules
    $privateGoCoreRoot = Get-ExporterGoCoreRoot
    $savedCgoEnabled = $env:CGO_ENABLED
    $savedGoWork = $env:GOWORK
    Push-Location $privateGoCoreRoot
    try {
        $env:CGO_ENABLED = "0"
        $env:GOWORK = "off"
        & go build -mod=readonly -buildvcs=false -trimpath `
            -tags playmesh_private_crypto '-ldflags=-s -w' `
            -o $apkSignerOutput ./cmd/playmesh-apksign
        if ($LASTEXITCODE -ne 0) {
            throw "Windows APK signer sidecar build failed"
        }
        Assert-NoRuntimePrivateKeyMaterialInFile `
            -Path $apkSignerOutput `
            -Description "Windows main-App exporter sidecar"
    } finally {
        Pop-Location
        $env:CGO_ENABLED = $savedCgoEnabled
        $env:GOWORK = $savedGoWork
    }

    Copy-Item -LiteralPath (Join-Path $apkSigAttribution "LICENSE") `
        -Destination (Join-Path $outputDirectory "APKSIG-GO-LICENSE.txt") `
        -Force
    Copy-Item -LiteralPath (Join-Path $apkSigAttribution "NOTICE") `
        -Destination (Join-Path $outputDirectory "APKSIG-GO-NOTICE.txt") `
        -Force
    foreach ($attribution in @(
        @{
            Source = Join-Path $winResAttributionRoot "LICENSE"
            Output = "WINRES-LICENSE.txt"
        },
        @{
            Source = Join-Path $nfntResizeAttributionRoot "LICENSE"
            Output = "NFNT-RESIZE-LICENSE.txt"
        },
        @{
            Source = Join-Path $goImageAttributionRoot "LICENSE"
            Output = "GOLANG-X-IMAGE-LICENSE.txt"
        },
        @{
            Source = Join-Path $goImageAttributionRoot "PATENTS"
            Output = "GOLANG-X-IMAGE-PATENTS.txt"
        }
    )) {
        Copy-Item -LiteralPath $attribution.Source `
            -Destination (Join-Path $outputDirectory $attribution.Output) `
            -Force
    }
}

try {
    if ($Target -eq "android" -or $Target -eq "all") {
        Build-AndroidCore
    }
    if ($Target -eq "windows" -or $Target -eq "all") {
        Build-WindowsCore
        Build-WindowsApkSigner
    }
    if ($Target -eq "windows-apksign") {
        Build-WindowsApkSigner
    }
} finally {
    Remove-ExporterGoCoreStaging
}
