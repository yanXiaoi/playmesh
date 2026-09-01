[CmdletBinding()]
param(
    [string]$OutputRoot,
    [switch]$Force,
    [switch]$Resume
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$runtimeRoot = Split-Path -Parent $PSScriptRoot
$runtimeParent = Split-Path -Parent $runtimeRoot
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $runtimeParent ".."))
$buildScript = Join-Path $PSScriptRoot "build_runtime.ps1"
$sdkStageScript = Join-Path $PSScriptRoot "stage_main_app_sdk.ps1"
$mainSdkRoot = Join-Path $repositoryRoot `
    "assets\playmesh-library\public\sdk\v1"
$runtimeSdkAssetNames = @(
    "playmesh-main.js",
    "playmesh-main.d.ts",
    "playmesh-app.js",
    "playmesh-app.d.ts"
)
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $runtimeParent "resource"
}

$pubspec = Get-Content -LiteralPath (Join-Path $runtimeRoot "pubspec.yaml") -Encoding UTF8
$versionLine = $pubspec |
    Where-Object { $_ -match '^version:\s*(\S+)\s*$' } |
    Select-Object -First 1
if (-not $versionLine -or
    $versionLine -notmatch '^version:\s*((\d+)\.(\d+)\.(\d+))\+(\d+)\s*$') {
    throw "pubspec.yaml version must use MAJOR.MINOR.PATCH+BUILD"
}
$versionName = $matches[1]
$buildNumber = [int]$matches[5]
$releaseName = "v$versionName-build$buildNumber"

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$resolvedOutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path
$outputDir = Join-Path $resolvedOutputRoot $releaseName
if (Test-Path -LiteralPath $outputDir) {
    if (-not $Force) {
        throw "Runtime release already exists: $outputDir. Bump pubspec.yaml or pass -Force."
    }
    $resolvedOutputDir = (Resolve-Path -LiteralPath $outputDir).Path
    if (-not $resolvedOutputDir.StartsWith(
            $resolvedOutputRoot + '\',
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to replace a directory outside the Runtime resource root: $resolvedOutputDir"
    }
    Remove-Item -LiteralPath $resolvedOutputDir -Recurse -Force
}

$buildRoot = Join-Path $runtimeRoot "build"
New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
$stagingRoot = Join-Path $buildRoot "runtime-packages"
$stagingDir = Join-Path $stagingRoot $releaseName
if ((Test-Path -LiteralPath $stagingDir) -and -not $Resume) {
    $resolvedStagingDir = (Resolve-Path -LiteralPath $stagingDir).Path
    $resolvedBuildRoot = (Resolve-Path -LiteralPath $buildRoot).Path
    if (-not $resolvedStagingDir.StartsWith(
            $resolvedBuildRoot + '\',
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean staging outside the Runtime build directory: $resolvedStagingDir"
    }
    Remove-Item -LiteralPath $resolvedStagingDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null

function Resolve-AndroidSdk {
    foreach ($propertiesPath in @(
            (Join-Path $runtimeRoot "android\local.properties"),
            (Join-Path $runtimeRoot "..\..\android\local.properties")
        )) {
        if (-not (Test-Path -LiteralPath $propertiesPath -PathType Leaf)) {
            continue
        }
        $property = Get-Content -LiteralPath $propertiesPath -Encoding UTF8 |
            Where-Object { $_ -match '^sdk\.dir=(.+)$' } |
            Select-Object -First 1
        if ($property -and $property -match '^sdk\.dir=(.+)$') {
            $candidate = $matches[1].Replace('\\', '\')
            if (Test-Path -LiteralPath $candidate -PathType Container) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }
    throw "Android SDK is not configured"
}

function Resolve-AndroidBuildTools([string]$sdkRoot) {
    $buildToolsRoot = Join-Path $sdkRoot "build-tools"
    $candidates = Get-ChildItem -LiteralPath $buildToolsRoot -Directory |
        ForEach-Object {
            try {
                [pscustomobject]@{
                    Version = [Version]$_.Name
                    Path = $_.FullName
                }
            } catch {
                # Ignore preview or otherwise non-versioned directories.
            }
        } |
        Sort-Object Version -Descending
    foreach ($candidate in $candidates) {
        $aapt2 = Join-Path $candidate.Path "aapt2.exe"
        $apksigner = Join-Path $candidate.Path "apksigner.bat"
        $zipalign = Join-Path $candidate.Path "zipalign.exe"
        if ((Test-Path -LiteralPath $aapt2 -PathType Leaf) -and
            (Test-Path -LiteralPath $apksigner -PathType Leaf) -and
            (Test-Path -LiteralPath $zipalign -PathType Leaf)) {
            return [pscustomobject]@{
                Aapt2 = $aapt2
                ApkSigner = $apksigner
                ZipAlign = $zipalign
                Version = $candidate.Version.ToString()
            }
        }
    }
    throw "No complete Android build-tools installation was found under $buildToolsRoot"
}

function Get-RuntimeSdkHashes {
    $hashes = [ordered]@{}
    foreach ($name in $runtimeSdkAssetNames) {
        $source = Join-Path $mainSdkRoot $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or
            (Get-Item -LiteralPath $source).Length -le 0) {
            throw "Main App SDK asset is missing or empty: $source"
        }
        $hashes[$name] = (Get-FileHash -LiteralPath $source `
                -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $hashes
}

function Get-StreamSha256([IO.Stream]$stream) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash($stream)
        return ([BitConverter]::ToString($digest)).Replace(
            "-",
            ""
        ).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Assert-RuntimeSdkArchive(
    [IO.Compression.ZipArchive]$archive,
    [string]$entryPrefix,
    [string]$context
) {
    $sdkEntries = [Collections.Generic.List[object]]::new()
    foreach ($entry in $archive.Entries) {
        $entryPath = $entry.FullName.Replace('\', '/')
        if ($entryPath.StartsWith(
                $entryPrefix,
                [StringComparison]::Ordinal
            )) {
            $sdkEntries.Add($entry)
        }
    }
    if ($sdkEntries.Count -ne $runtimeSdkAssetNames.Count) {
        throw "$context must contain exactly four Main App SDK assets"
    }
    foreach ($name in $runtimeSdkAssetNames) {
        $expectedPath = $entryPrefix + $name
        $matches = @(
            $sdkEntries |
                Where-Object {
                    $_.FullName.Replace('\', '/') -ceq $expectedPath
                }
        )
        if ($matches.Count -ne 1) {
            throw "$context is missing the exact SDK asset $expectedPath"
        }
        $source = Join-Path $mainSdkRoot $name
        $sourceLength = (Get-Item -LiteralPath $source).Length
        if ($matches[0].Length -ne $sourceLength) {
            throw "$context SDK asset length differs from Main App: $name"
        }
        $stream = $matches[0].Open()
        try {
            $actualHash = Get-StreamSha256 $stream
        } finally {
            $stream.Dispose()
        }
        $expectedHash = (Get-FileHash -LiteralPath $source `
                -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -cne $expectedHash) {
            throw "$context SDK asset differs from Main App: $name"
        }
    }
}

function Assert-RuntimeSdkDirectory(
    [string]$bundle,
    [string]$context
) {
    $sdkDirectory = Join-Path $bundle `
        "data\flutter_assets\assets\playmesh-library\public\sdk\v1"
    if (-not (Test-Path -LiteralPath $sdkDirectory -PathType Container)) {
        throw "$context is missing the Main App SDK asset directory"
    }
    $files = @(Get-ChildItem -LiteralPath $sdkDirectory -File -Force)
    $directories = @(Get-ChildItem -LiteralPath $sdkDirectory -Directory -Force)
    if ($files.Count -ne $runtimeSdkAssetNames.Count -or
        $directories.Count -ne 0) {
        throw "$context must contain exactly four Main App SDK assets"
    }
    foreach ($name in $runtimeSdkAssetNames) {
        $source = Join-Path $mainSdkRoot $name
        $packaged = Join-Path $sdkDirectory $name
        if (-not (Test-Path -LiteralPath $packaged -PathType Leaf) -or
            (Get-Item -LiteralPath $packaged).Length -ne
                (Get-Item -LiteralPath $source).Length -or
            (Get-FileHash -LiteralPath $packaged -Algorithm SHA256).Hash -cne
                (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash) {
            throw "$context SDK asset differs from Main App: $name"
        }
    }
}

function Assert-AndroidPackage(
    [string]$apkPath,
    [string]$expectedAbi,
    [object]$buildTools
) {
    if (-not (Test-Path -LiteralPath $apkPath -PathType Leaf)) {
        throw "Android build did not produce $apkPath"
    }

    $badging = & $buildTools.Aapt2 dump badging $apkPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("aapt2 failed for {0}: {1}" -f
            $apkPath,
            ($badging -join [Environment]::NewLine))
    }
    $nativeCodeLine = $badging |
        Where-Object { $_ -match '^native-code:' } |
        Select-Object -First 1
    if (-not $nativeCodeLine) {
        throw "APK does not declare a native ABI: $apkPath"
    }
    $actualAbis = @(
        [regex]::Matches([string]$nativeCodeLine, "'([^']+)'") |
            ForEach-Object { $_.Groups[1].Value }
    )
    if ($actualAbis.Count -ne 1 -or $actualAbis[0] -ne $expectedAbi) {
        throw "APK ABI mismatch. Expected only $expectedAbi, got: $($actualAbis -join ', ')"
    }

    $signature = & $buildTools.ApkSigner verify --verbose --print-certs $apkPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "APK signature verification failed: $($signature -join [Environment]::NewLine)"
    }
    if (-not ($signature -match
            'Verified using v2 scheme \(APK Signature Scheme v2\): true')) {
        throw "APK is not signed with APK Signature Scheme v2: $apkPath"
    }

    $alignment = & $buildTools.ZipAlign -c -P 16 4 $apkPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "APK 16 KiB alignment verification failed: $($alignment -join [Environment]::NewLine)"
    }

    Assert-AndroidRuntimeEncryptionContract $apkPath
}

function New-PackageRecord(
    [string]$path,
    [string]$platform,
    [string]$architecture
) {
    $file = Get-Item -LiteralPath $path
    return [ordered]@{
        file = $file.Name
        platform = $platform
        architecture = $architecture
        versionName = $versionName
        buildNumber = $buildNumber
        sizeBytes = $file.Length
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Copy-RuntimePublicationFile(
    [string]$sourcePath,
    [string]$destinationPath
) {
    $lastError = $null
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            Copy-Item `
                -LiteralPath $sourcePath `
                -Destination $destinationPath `
                -Force
            return
        } catch {
            $lastError = $_
            if ($attempt -lt 60) {
                Start-Sleep -Milliseconds 500
            }
        }
    }
    throw "Unable to publish Runtime file after 30 seconds: $destinationPath. $lastError"
}

function Publish-RuntimePackages(
    [string]$packageDirectory,
    [object[]]$packageRecords,
    [string]$publishedReleaseName
) {
    $releaseRoot = Join-Path $repositoryRoot "resources\runtime"
    if (-not (Test-Path -LiteralPath $releaseRoot -PathType Container)) {
        throw "Runtime publication directory is missing: $releaseRoot"
    }
    $resolvedReleaseRoot = (Resolve-Path -LiteralPath $releaseRoot).Path
    $expectedReleaseRoot = [IO.Path]::GetFullPath(
        (Join-Path $repositoryRoot "resources\runtime")
    )
    if (-not [String]::Equals(
            $resolvedReleaseRoot,
            $expectedReleaseRoot,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Refusing to publish outside resources/runtime: $resolvedReleaseRoot"
    }

    $expectedFiles = @(
        "playmesh-runtime-x86.apk",
        "playmesh-runtime-arm.apk",
        "playmesh-runtime-win.zip"
    )
    $recordsByFile = @{}
    foreach ($record in $packageRecords) {
        $fileName = [string]$record.file
        if ($fileName -notin $expectedFiles -or $recordsByFile.ContainsKey($fileName)) {
            throw "Unexpected or duplicate Runtime publication artifact: $fileName"
        }
        $sourcePath = Join-Path $packageDirectory $fileName
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Runtime publication artifact is missing: $sourcePath"
        }
        $sourceHash = (
            Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if ($sourceHash -cne [string]$record.sha256 -or
            (Get-Item -LiteralPath $sourcePath).Length -ne [int64]$record.sizeBytes) {
            throw "Runtime publication artifact differs from its package record: $fileName"
        }
        $recordsByFile[$fileName] = $record
    }
    foreach ($fileName in $expectedFiles) {
        if (-not $recordsByFile.ContainsKey($fileName)) {
            throw "Runtime publication record is missing: $fileName"
        }
    }

    $updatePath = Join-Path $resolvedReleaseRoot "update.json"
    if (-not (Test-Path -LiteralPath $updatePath -PathType Leaf)) {
        throw "Runtime publication manifest is missing: $updatePath"
    }
    $update = Get-Content -Raw -LiteralPath $updatePath -Encoding UTF8 |
        ConvertFrom-Json
    if ($null -eq $update.platform -or
        $null -eq $update.platform.android -or
        $null -eq $update.platform.android.x86 -or
        $null -eq $update.platform.android.arm -or
        $null -eq $update.platform.windows) {
        throw "Runtime publication manifest has an invalid platform structure: $updatePath"
    }
    $update.version = $publishedReleaseName
    $update.platform.android.x86.sha256 =
        [string]$recordsByFile["playmesh-runtime-x86.apk"].sha256
    $update.platform.android.arm.sha256 =
        [string]$recordsByFile["playmesh-runtime-arm.apk"].sha256
    $update.platform.windows.sha256 =
        [string]$recordsByFile["playmesh-runtime-win.zip"].sha256

    $publicationStagingRoot = Join-Path $buildRoot "runtime-publication"
    $publicationStagingDir = Join-Path $publicationStagingRoot $publishedReleaseName
    if (Test-Path -LiteralPath $publicationStagingDir) {
        $resolvedPublicationStagingDir =
            (Resolve-Path -LiteralPath $publicationStagingDir).Path
        $resolvedBuildRoot = (Resolve-Path -LiteralPath $buildRoot).Path
        if (-not $resolvedPublicationStagingDir.StartsWith(
                $resolvedBuildRoot + '\',
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean publication staging outside the Runtime build directory: $resolvedPublicationStagingDir"
        }
        Remove-Item -LiteralPath $resolvedPublicationStagingDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $publicationStagingDir | Out-Null

    try {
        foreach ($fileName in $expectedFiles) {
            Copy-Item `
                -LiteralPath (Join-Path $packageDirectory $fileName) `
                -Destination (Join-Path $publicationStagingDir $fileName)
        }
        $stagedUpdatePath = Join-Path $publicationStagingDir "update.json"
        $updateJson = $update | ConvertTo-Json -Depth 8
        $updateUtf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText(
            $stagedUpdatePath,
            $updateJson + [Environment]::NewLine,
            $updateUtf8
        )

        foreach ($fileName in $expectedFiles) {
            $stagedPath = Join-Path $publicationStagingDir $fileName
            $stagedHash = (
                Get-FileHash -LiteralPath $stagedPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            if ($stagedHash -cne [string]$recordsByFile[$fileName].sha256) {
                throw "Staged Runtime publication hash mismatch: $fileName"
            }
        }

        # Publish the verified artifacts first and the matching update manifest
        # last, so a successful run never leaves a new manifest pointing at old
        # packages.
        foreach ($fileName in $expectedFiles) {
            Copy-RuntimePublicationFile `
                (Join-Path $publicationStagingDir $fileName) `
                (Join-Path $resolvedReleaseRoot $fileName)
        }
        Copy-RuntimePublicationFile $stagedUpdatePath $updatePath

        $publishedUpdate = Get-Content -Raw -LiteralPath $updatePath -Encoding UTF8 |
            ConvertFrom-Json
        if ([string]$publishedUpdate.version -cne $publishedReleaseName) {
            throw "Published Runtime version does not match $publishedReleaseName"
        }
        foreach ($fileName in $expectedFiles) {
            $publishedPath = Join-Path $resolvedReleaseRoot $fileName
            $publishedHash = (
                Get-FileHash -LiteralPath $publishedPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            if ($publishedHash -cne [string]$recordsByFile[$fileName].sha256) {
                throw "Published Runtime artifact hash mismatch: $fileName"
            }
        }
        if ([string]$publishedUpdate.platform.android.x86.sha256 -cne
                [string]$recordsByFile["playmesh-runtime-x86.apk"].sha256 -or
            [string]$publishedUpdate.platform.android.arm.sha256 -cne
                [string]$recordsByFile["playmesh-runtime-arm.apk"].sha256 -or
            [string]$publishedUpdate.platform.windows.sha256 -cne
                [string]$recordsByFile["playmesh-runtime-win.zip"].sha256) {
            throw "Published Runtime update.json hashes do not match the artifacts"
        }
    } finally {
        if (Test-Path -LiteralPath $publicationStagingDir) {
            Remove-Item -LiteralPath $publicationStagingDir -Recurse -Force
        }
    }

    Write-Output "Published Runtime packages: $resolvedReleaseRoot"
}

function Test-IsRuntimeKeyArtifact([string]$relativePath) {
    $normalized = $relativePath.Replace('\', '/').ToLowerInvariant()
    $leafName = [IO.Path]::GetFileName($normalized)
    $extension = [IO.Path]::GetExtension($leafName)
    # Java service-provider descriptors use the provider interface name as the
    # file name. Obfuscated interfaces such as `i6.a` are text descriptors, not
    # Unix static libraries, even though their names end in `.a`.
    $isMetaInfServiceDescriptor =
        $normalized -match '^meta-inf/services/[^/]+$'
    if ($extension -in @(
            ".pem", ".key", ".der", ".p12", ".pfx", ".jks", ".keystore",
            ".go", ".c", ".cc", ".cpp", ".h", ".hpp", ".lib"
        )) {
        return $true
    }
    if ($extension -eq ".a" -and -not $isMetaInfServiceDescriptor) {
        return $true
    }
    if ($leafName.EndsWith(".generated.h") -or
        $leafName.Contains("private_key") -or
        $leafName.Contains("private-key") -or
        $leafName -eq "go.mod" -or
        $leafName -eq "go.sum" -or
        $leafName -eq "windows-runtime-private.pem" -or
        $leafName -eq "windows_runtime_private_key.generated.h" -or
        $leafName -eq "windows_runtime_public_key.der") {
        return $true
    }
    return $false
}

function Assert-AndroidRuntimeEncryptionContract([string]$apkPath) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $contractEntryName = `
        "assets/flutter_assets/assets/runtime/runtime-contract.json"
    $configEntryName = `
        "assets/flutter_assets/assets/runtime/runtime-config.json"
    $gameEntryName = "assets/flutter_assets/assets/runtime/game.pmp"
    $archive = [IO.Compression.ZipFile]::OpenRead($apkPath)
    try {
        foreach ($entry in $archive.Entries) {
            $entryPath = $entry.FullName.Replace('\', '/')
            if ($entry.Name -and (Test-IsRuntimeKeyArtifact $entryPath)) {
                throw "Android Runtime APK contains a forbidden key/source artifact: $entryPath"
            }
        }
        Assert-RuntimeSdkArchive $archive `
            "assets/flutter_assets/assets/playmesh-library/public/sdk/v1/" `
            "Android Runtime APK"
        $contractEntry = $archive.GetEntry($contractEntryName)
        $configEntry = $archive.GetEntry($configEntryName)
        $gameEntry = $archive.GetEntry($gameEntryName)
        if (-not $contractEntry -or -not $configEntry -or -not $gameEntry) {
            throw "Android Runtime APK is missing its encrypted package contract"
        }
        if ($contractEntry.Length -gt 4096 -or $configEntry.Length -gt 4096 -or
            $gameEntry.Length -le 32) {
            throw "Android Runtime APK has invalid encryption asset sizes"
        }

        $contractReader = New-Object IO.StreamReader(
            $contractEntry.Open(),
            (New-Object Text.UTF8Encoding($false, $true))
        )
        try {
            $contract = $contractReader.ReadToEnd() | ConvertFrom-Json
        } finally {
            $contractReader.Dispose()
        }
        $rootFields = @($contract.PSObject.Properties.Name)
        $androidFields = @($contract.android.PSObject.Properties.Name)
        $windowsFields = @($contract.windows.PSObject.Properties.Name)
        if ($rootFields.Count -ne 3 -or
            "schemaVersion" -notin $rootFields -or
            "android" -notin $rootFields -or
            "windows" -notin $rootFields -or
            $contract.schemaVersion -ne 1 -or
            $androidFields.Count -ne 2 -or
            $windowsFields.Count -ne 2 -or
            $contract.android.packageKeyScheme -ne
                "android-rsa-oaep-sha256-v1" -or
            $contract.android.publicKeySha256 -ne
                "g_DV1Ub-F7SOKEBYYi5j1AEwkY9wIUIWSzN_N28z-d8" -or
            $contract.windows.packageKeyScheme -ne
                "win-rsa-oaep-sha256-v1" -or
            $contract.windows.publicKeySha256 -ne
                "10SbA_plmguDhuFby9uK26FJKk1MlcRKTbpH8QQipFo") {
            throw "Android Runtime APK contains an incompatible runtime-contract.json"
        }

        $configReader = New-Object IO.StreamReader(
            $configEntry.Open(),
            (New-Object Text.UTF8Encoding($false, $true))
        )
        try {
            $config = $configReader.ReadToEnd() | ConvertFrom-Json
        } finally {
            $configReader.Dispose()
        }
        $keyIdPattern = '^android-rsa-oaep-sha256-v1:' +
            'g_DV1Ub-F7SOKEBYYi5j1AEwkY9wIUIWSzN_N28z-d8:' +
            '[A-Za-z0-9_-]{512}$'
        if ($config.schemaVersion -ne 1 -or
            $config.package.asset -ne "assets/runtime/game.pmp" -or
            $config.package.codec -ne "aes-gcm-v1" -or
            ([string]$config.package.keyId) -notmatch $keyIdPattern) {
            throw "Android Runtime APK contains an incompatible encrypted runtime-config.json"
        }

        $gameStream = $gameEntry.Open()
        try {
            $magic = New-Object byte[] 4
            if ($gameStream.Read($magic, 0, 4) -ne 4 -or
                [Text.Encoding]::ASCII.GetString($magic) -ne "PME1") {
                throw "Android Runtime APK game.pmp is not a PME1 envelope"
            }
        } finally {
            $gameStream.Dispose()
        }
    } finally {
        $archive.Dispose()
    }
}

function Assert-NoRuntimeKeyArtifactsInDirectory(
    [string]$directory,
    [string]$context
) {
    $cryptoModules = [Collections.Generic.List[string]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $directory -Recurse -File -Force) {
        $relativePath = $file.FullName.Substring($directory.Length).TrimStart('\', '/')
        if ($file.Name -ieq "playmesh-runtime-crypto.dll") {
            $cryptoModules.Add($relativePath.Replace('\', '/'))
        }
        if (Test-IsRuntimeKeyArtifact $relativePath) {
            throw "$context contains a forbidden Runtime key artifact: $relativePath"
        }
    }
    if ($cryptoModules.Count -ne 1 -or
        $cryptoModules[0] -cne "playmesh-runtime-crypto.dll") {
        throw "$context must contain exactly one root playmesh-runtime-crypto.dll"
    }
}

function Assert-WindowsRuntimePackageConfig($config, [string]$context) {
    if ($null -eq $config) {
        throw "$context is empty"
    }
    $rootFields = @($config.PSObject.Properties.Name)
    if ($rootFields.Count -ne 2 -or
        "schemaVersion" -notin $rootFields -or
        "package" -notin $rootFields -or
        $null -eq $config.package) {
        throw "$context has an invalid root contract"
    }
    $packageFields = @($config.package.PSObject.Properties.Name)
    $keyIdPattern = '^win-rsa-oaep-sha256-v1:' +
        '10SbA_plmguDhuFby9uK26FJKk1MlcRKTbpH8QQipFo:' +
        '[A-Za-z0-9_-]{512}$'
    if ($config.schemaVersion -ne 1 -or
        $packageFields.Count -ne 3 -or
        "asset" -notin $packageFields -or
        "codec" -notin $packageFields -or
        "keyId" -notin $packageFields -or
        $config.package.asset -ne "assets/runtime/game.pmp" -or
        $config.package.codec -ne "aes-gcm-v1" -or
        ([string]$config.package.keyId) -notmatch $keyIdPattern) {
        throw "$context is not the Windows RSA/PME1 package contract"
    }
}

function Assert-WindowsRuntimePME1Stream(
    [IO.Stream]$stream,
    [long]$length,
    [string]$context
) {
    if ($length -le 32) {
        throw "$context has an invalid encrypted package size"
    }
    $magic = New-Object byte[] 4
    if ($stream.Read($magic, 0, 4) -ne 4 -or
        [Text.Encoding]::ASCII.GetString($magic) -ne "PME1") {
        throw "$context game.pmp is not a PME1 envelope"
    }
}

function Assert-WindowsRuntimeContract([string]$bundle) {
    Assert-RuntimeSdkDirectory $bundle "Windows Runtime bundle"
    $relativePath = "data\flutter_assets\assets\runtime\runtime-contract.json"
    $contractPath = Join-Path $bundle $relativePath
    if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
        throw "Windows Runtime bundle is missing $relativePath"
    }
    $contract = Get-Content -LiteralPath $contractPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $propertyNames = @($contract.PSObject.Properties.Name)
    $androidPropertyNames = @($contract.android.PSObject.Properties.Name)
    $windowsPropertyNames = @($contract.windows.PSObject.Properties.Name)
    if ($propertyNames.Count -ne 3 -or
        "schemaVersion" -notin $propertyNames -or
        "android" -notin $propertyNames -or
        "windows" -notin $propertyNames -or
        $contract.schemaVersion -ne 1 -or
        $androidPropertyNames.Count -ne 2 -or
        "packageKeyScheme" -notin $androidPropertyNames -or
        "publicKeySha256" -notin $androidPropertyNames -or
        $contract.android.packageKeyScheme -ne
            "android-rsa-oaep-sha256-v1" -or
        $contract.android.publicKeySha256 -ne
            "g_DV1Ub-F7SOKEBYYi5j1AEwkY9wIUIWSzN_N28z-d8" -or
        $windowsPropertyNames.Count -ne 2 -or
        "packageKeyScheme" -notin $windowsPropertyNames -or
        "publicKeySha256" -notin $windowsPropertyNames -or
        $contract.windows.packageKeyScheme -ne "win-rsa-oaep-sha256-v1" -or
        $contract.windows.publicKeySha256 -ne
            "10SbA_plmguDhuFby9uK26FJKk1MlcRKTbpH8QQipFo") {
        throw "Windows Runtime bundle contains an incompatible runtime-contract.json"
    }

    $configRelativePath = "data\flutter_assets\assets\runtime\runtime-config.json"
    $gameRelativePath = "data\flutter_assets\assets\runtime\game.pmp"
    $configPath = Join-Path $bundle $configRelativePath
    $gamePath = Join-Path $bundle $gameRelativePath
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $gamePath -PathType Leaf)) {
        throw "Windows Runtime bundle is missing its encrypted package assets"
    }
    if ((Get-Item -LiteralPath $configPath).Length -gt 4096) {
        throw "Windows Runtime bundle runtime-config.json exceeds 4096 bytes"
    }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-WindowsRuntimePackageConfig $config `
        "Windows Runtime bundle runtime-config.json"
    $game = [IO.File]::OpenRead($gamePath)
    try {
        Assert-WindowsRuntimePME1Stream $game $game.Length `
            "Windows Runtime bundle"
    } finally {
        $game.Dispose()
    }
}

function New-PortableZipFromDirectory(
    [string]$sourceDirectory,
    [string]$destinationZip
) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $sourceRoot = (Resolve-Path -LiteralPath $sourceDirectory).Path
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw "ZIP source is not a directory: $sourceRoot"
    }
    if (((Get-Item -LiteralPath $sourceRoot).Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "ZIP source must not be a reparse point: $sourceRoot"
    }
    if (Test-Path -LiteralPath $destinationZip) {
        throw "ZIP destination already exists: $destinationZip"
    }

    $sourcePrefix = $sourceRoot.TrimEnd('\') + '\'
    $portableEntries = [Collections.Generic.List[object]]::new()
    $seenEntries = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($item in Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "ZIP source contains a reparse point: $($item.FullName)"
        }
        if ($item.PSIsContainer) {
            continue
        }
        if (-not $item.FullName.StartsWith(
                $sourcePrefix,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "ZIP source file escaped its root: $($item.FullName)"
        }
        $entryPath = $item.FullName.Substring($sourcePrefix.Length).Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($entryPath) -or
            $entryPath.StartsWith('/') -or
            $entryPath.Contains('\') -or
            $entryPath -match '(^|/)\.\.?(/|$)' -or
            -not $seenEntries.Add($entryPath)) {
            throw "ZIP source contains an unsafe or duplicate entry: $entryPath"
        }
        $portableEntries.Add([pscustomobject]@{
                SourcePath = $item.FullName
                EntryPath = $entryPath
            })
    }
    if ($portableEntries.Count -eq 0) {
        throw "ZIP source contains no files: $sourceRoot"
    }

    $zipStream = $null
    $archive = $null
    $completed = $false
    try {
        $zipStream = [IO.File]::Open(
            $destinationZip,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        $archive = New-Object IO.Compression.ZipArchive(
            $zipStream,
            [IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        foreach ($portableEntry in $portableEntries | Sort-Object EntryPath) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive,
                $portableEntry.SourcePath,
                $portableEntry.EntryPath,
                [IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
        $completed = $true
    } finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
        if ($null -ne $zipStream) {
            $zipStream.Dispose()
        }
        if (-not $completed -and
            (Test-Path -LiteralPath $destinationZip -PathType Leaf)) {
            Remove-Item -LiteralPath $destinationZip -Force
        }
    }
}

function Assert-WindowsRuntimeZip([string]$zipPath) {
    $contractEntryName = "data/flutter_assets/assets/runtime/runtime-contract.json"
    $configEntryName = "data/flutter_assets/assets/runtime/runtime-config.json"
    $gameEntryName = "data/flutter_assets/assets/runtime/game.pmp"
    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $cryptoModules = [Collections.Generic.List[string]]::new()
        $entriesByPortablePath = @{}
        foreach ($entry in $archive.Entries) {
            $entryPath = $entry.FullName.Replace('\', '/')
            if ($entriesByPortablePath.ContainsKey($entryPath)) {
                throw "Windows Runtime ZIP contains a duplicate normalized path: $entryPath"
            }
            $entriesByPortablePath[$entryPath] = $entry
            if ($entry.Name -and (Test-IsRuntimeKeyArtifact $entryPath)) {
                throw "Windows Runtime ZIP contains a forbidden Runtime key artifact: $entryPath"
            }
            if ($entry.Name -ieq "playmesh-runtime-crypto.dll") {
                $cryptoModules.Add($entryPath)
            }
        }
        Assert-RuntimeSdkArchive $archive `
            "data/flutter_assets/assets/playmesh-library/public/sdk/v1/" `
            "Windows Runtime ZIP"
        $contractEntry = $entriesByPortablePath[$contractEntryName]
        $configEntry = $entriesByPortablePath[$configEntryName]
        $gameEntry = $entriesByPortablePath[$gameEntryName]
        if (-not $contractEntry -or -not $configEntry -or -not $gameEntry) {
            throw "Windows Runtime ZIP is missing its encrypted package contract"
        }
        if ($cryptoModules.Count -ne 1 -or
            $cryptoModules[0] -cne "playmesh-runtime-crypto.dll") {
            throw "Windows Runtime ZIP must contain exactly one root playmesh-runtime-crypto.dll"
        }
        if ($configEntry.Length -gt 4096) {
            throw "Windows Runtime ZIP runtime-config.json exceeds 4096 bytes"
        }
        $configReader = New-Object IO.StreamReader(
            $configEntry.Open(),
            (New-Object Text.UTF8Encoding($false, $true))
        )
        try {
            $config = $configReader.ReadToEnd() | ConvertFrom-Json
        } finally {
            $configReader.Dispose()
        }
        Assert-WindowsRuntimePackageConfig $config `
            "Windows Runtime ZIP runtime-config.json"
        $gameStream = $gameEntry.Open()
        try {
            Assert-WindowsRuntimePME1Stream $gameStream $gameEntry.Length `
                "Windows Runtime ZIP"
        } finally {
            $gameStream.Dispose()
        }
    } finally {
        $archive.Dispose()
    }
}

function Invoke-RuntimeBuild(
    [string]$target,
    [string]$androidArchitecture,
    [bool]$skipSdkGeneration
) {
    $savedFlutterAlreadyLocked = $env:FLUTTER_ALREADY_LOCKED
    $savedFlutterSuppressAnalytics = $env:FLUTTER_SUPPRESS_ANALYTICS
    try {
        # This repository uses one pre-provisioned Flutter SDK. The package
        # build is serialized, so it can safely reuse an SDK already held by
        # an IDE process without starting a second SDK update operation.
        $env:FLUTTER_ALREADY_LOCKED = "true"
        $env:FLUTTER_SUPPRESS_ANALYTICS = "true"
        $arguments = @{ Target = $target }
        if (-not [string]::IsNullOrWhiteSpace($androidArchitecture)) {
            $arguments.AndroidArchitecture = $androidArchitecture
        }
        if ($skipSdkGeneration) {
            $arguments.SkipSdkGeneration = $true
        }
        & $buildScript @arguments
    } finally {
        if ($null -eq $savedFlutterAlreadyLocked) {
            Remove-Item Env:FLUTTER_ALREADY_LOCKED -ErrorAction SilentlyContinue
        } else {
            $env:FLUTTER_ALREADY_LOCKED = $savedFlutterAlreadyLocked
        }
        if ($null -eq $savedFlutterSuppressAnalytics) {
            Remove-Item Env:FLUTTER_SUPPRESS_ANALYTICS -ErrorAction SilentlyContinue
        } else {
            $env:FLUTTER_SUPPRESS_ANALYTICS = $savedFlutterSuppressAnalytics
        }
    }
}

$androidSdk = Resolve-AndroidSdk
$androidBuildTools = Resolve-AndroidBuildTools $androidSdk
$flutterApk = Join-Path $runtimeRoot "build\app\outputs\flutter-apk\app-release.apk"
$packages = [Collections.Generic.List[object]]::new()
$sdkLockRoot = Join-Path $runtimeRoot "build"
New-Item -ItemType Directory -Force -Path $sdkLockRoot | Out-Null
$sdkLockPath = Join-Path $sdkLockRoot "runtime-sdk-build.lock"
try {
    $sdkGenerationLock = [IO.File]::Open(
        $sdkLockPath,
        [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
} catch {
    throw "Another Runtime build is already using the Main App SDK stage"
}
try {
    try {
        & $sdkStageScript -Action stage
    } finally {
        & $sdkStageScript -Action clean
    }
} finally {
    $sdkGenerationLock.Dispose()
}
$sdkAlreadyGenerated = $true

$x86Apk = Join-Path $stagingDir "playmesh-runtime-x86.apk"
if ($Resume -and (Test-Path -LiteralPath $x86Apk -PathType Leaf)) {
    Write-Output "Reusing staged Runtime Android x86_64..."
    Assert-AndroidPackage $x86Apk "x86_64" $androidBuildTools
    $sdkAlreadyGenerated = $true
} else {
    Write-Output "Building Runtime Android x86_64..."
    Invoke-RuntimeBuild "android" "amd64" $sdkAlreadyGenerated
    Assert-AndroidPackage $flutterApk "x86_64" $androidBuildTools
    Copy-Item -LiteralPath $flutterApk -Destination $x86Apk -Force
    $sdkAlreadyGenerated = $true
}
$packages.Add((New-PackageRecord $x86Apk "android" "x86_64"))

$armApk = Join-Path $stagingDir "playmesh-runtime-arm.apk"
if ($Resume -and (Test-Path -LiteralPath $armApk -PathType Leaf)) {
    Write-Output "Reusing staged Runtime Android arm64-v8a..."
    Assert-AndroidPackage $armApk "arm64-v8a" $androidBuildTools
    $sdkAlreadyGenerated = $true
} else {
    Write-Output "Building Runtime Android arm64-v8a..."
    Invoke-RuntimeBuild "android" "arm64" $sdkAlreadyGenerated
    Assert-AndroidPackage $flutterApk "arm64-v8a" $androidBuildTools
    Copy-Item -LiteralPath $flutterApk -Destination $armApk -Force
    $sdkAlreadyGenerated = $true
}
$packages.Add((New-PackageRecord $armApk "android" "arm64-v8a"))

Write-Output "Building Runtime Windows x64 with HostX64 MSVC and Ninja..."
Invoke-RuntimeBuild "windows" "" $sdkAlreadyGenerated
$windowsBundle = Join-Path $runtimeRoot "build\windows\x64-ninja\runner\Release"
$requiredWindowsFiles = @(
    "playmesh-runtime.exe",
    "playmesh-runtime-crypto.dll",
    "playmesh-core.exe",
    "flutter_windows.dll",
    "WebView2Loader.dll",
    "data\app.so",
    "data\icudtl.dat",
    "data\flutter_assets\assets\runtime\runtime-contract.json",
    "data\flutter_assets\assets\runtime\runtime-config.json",
    "data\flutter_assets\assets\runtime\game.pmp"
)
foreach ($relativePath in $requiredWindowsFiles) {
    $requiredPath = Join-Path $windowsBundle $relativePath
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Windows Runtime bundle is missing $relativePath"
    }
}
Assert-WindowsRuntimeContract $windowsBundle
Assert-NoRuntimeKeyArtifactsInDirectory `
    $windowsBundle `
    "Windows Runtime bundle"

$windowsZip = Join-Path $stagingDir "playmesh-runtime-win.zip"
if (Test-Path -LiteralPath $windowsZip) {
    $resolvedWindowsStagingDir =
        (Resolve-Path -LiteralPath $stagingDir).Path
    $resolvedWindowsZip = (Resolve-Path -LiteralPath $windowsZip).Path
    $expectedWindowsZip = Join-Path $resolvedWindowsStagingDir "playmesh-runtime-win.zip"
    if (-not [String]::Equals(
            $resolvedWindowsZip,
            $expectedWindowsZip,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not (Test-Path -LiteralPath $resolvedWindowsZip -PathType Leaf)) {
        throw "Refusing to replace an invalid staged Windows Runtime ZIP: $resolvedWindowsZip"
    }
    Remove-Item -LiteralPath $resolvedWindowsZip -Force
}
New-PortableZipFromDirectory $windowsBundle $windowsZip
Assert-WindowsRuntimeZip $windowsZip
$packages.Add((New-PackageRecord $windowsZip "windows" "x86_64"))

# Recheck every staged package against the same canonical Main App SDK after
# all three builds. This turns a concurrent SDK rewrite or an incompatible
# -Resume artifact into a hard failure instead of a mixed Runtime release.
Assert-AndroidPackage $x86Apk "x86_64" $androidBuildTools
Assert-AndroidPackage $armApk "arm64-v8a" $androidBuildTools
Assert-WindowsRuntimeZip $windowsZip

$manifestPath = Join-Path $stagingDir "runtime-packages.json"
$manifest = [ordered]@{
    schemaVersion = 1
    runtimeVersion = "$versionName+$buildNumber"
    versionName = $versionName
    buildNumber = $buildNumber
    generatedAtUtc = [DateTime]::UtcNow.ToString("O")
    androidBuildTools = $androidBuildTools.Version
    sdkAssetsSha256 = Get-RuntimeSdkHashes
    packages = $packages
}
$manifestJson = $manifest | ConvertTo-Json -Depth 6
$manifestUtf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText(
    $manifestPath,
    $manifestJson + [Environment]::NewLine,
    $manifestUtf8
)

Publish-RuntimePackages $stagingDir @($packages) $releaseName
Move-Item -LiteralPath $stagingDir -Destination $outputDir
Write-Output "Runtime packages: $outputDir"
foreach ($package in $packages) {
    Write-Output (
        "{0} | {1} | {2} bytes | SHA-256 {3}" -f
        $package.file,
        $package.architecture,
        $package.sizeBytes,
        $package.sha256
    )
}
