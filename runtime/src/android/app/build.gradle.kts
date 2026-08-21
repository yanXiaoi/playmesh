plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val runtimeAndroidArchitecture =
    System.getenv("PLAYMESH_RUNTIME_ANDROID_ARCHITECTURE") ?: "all"
val runtimeAndroidAbi = when (runtimeAndroidArchitecture) {
    "arm64" -> "arm64-v8a"
    "arm" -> "armeabi-v7a"
    "amd64" -> "x86_64"
    else -> null
}

android {
    namespace = "top.zfjmm.playmesh_runtime"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Fixed identity for the standalone MVP package.
        applicationId = "top.zfjmm.playmesh.runtime"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        if (runtimeAndroidAbi != null) {
            ndk {
                abiFilters += runtimeAndroidAbi
            }
        }
    }

    buildTypes {
        release {
            // Installable MVP output. Dynamic export and final per-game
            // signing belong to the main App and are intentionally deferred.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    packaging {
        jniLibs {
            if (runtimeAndroidAbi != null) {
                val runtimeAbis = setOf("arm64-v8a", "armeabi-v7a", "x86_64")
                excludes += runtimeAbis
                    .filter { it != runtimeAndroidAbi }
                    .map { "lib/$it/**" }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

val goCoreAar = file("libs/playmesh_core.aar")
val parentGoCoreRoot = rootProject.file("../../../go-core")
val goCoreBuilder = rootProject.file("../tool/build_go_core.ps1")
val privateGoCryptoRoot = rootProject.file("../../crypto")
val privateGoStagingHelper = rootProject.file(
    "../tool/prepare_private_go_core.ps1",
)

val buildParentGoCore by tasks.registering(Exec::class) {
    group = "playmesh runtime"
    description = "Builds the Android AAR from the main repository go-core source."
    inputs.files(
        fileTree(parentGoCoreRoot) {
            include("**/*.go", "go.mod", "go.sum")
        },
    )
    inputs.file(goCoreBuilder)
    inputs.file(privateGoStagingHelper)
    inputs.files(
        fileTree(privateGoCryptoRoot) {
            include(
                "android-runtime-private.pem",
                "go-overlay/common/**/*.go",
                "go-overlay/runtime-common/**/*.go",
                "go-overlay/android-runtime/**/*.go",
            )
            exclude("generated/**")
        },
    )
    inputs.property("runtimeAndroidArchitecture", runtimeAndroidArchitecture)
    outputs.file(goCoreAar)
    val powerShell = if (System.getProperty("os.name").startsWith("Windows")) {
        "powershell.exe"
    } else {
        "pwsh"
    }
    commandLine(
        powerShell,
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        goCoreBuilder.absolutePath,
        "-Output",
        goCoreAar.absolutePath,
        "-Architecture",
        runtimeAndroidArchitecture,
    )
}

dependencies {
    implementation(files(goCoreAar))
    implementation("com.google.ar:core:1.54.0")
    implementation("io.github.webrtc-sdk:android:144.7559.09")
}

tasks.named("preBuild").configure {
    dependsOn(buildParentGoCore)
}
