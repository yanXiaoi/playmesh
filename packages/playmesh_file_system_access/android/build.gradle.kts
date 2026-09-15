group = "top.zfjmm.playmesh_file_system_access"
version = "1.0"

plugins {
    id("com.android.library")
}

android {
    namespace = "top.zfjmm.playmesh_file_system_access"
    compileSdk = flutter.compileSdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 24
    }
}
