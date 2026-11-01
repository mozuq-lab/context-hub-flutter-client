plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.mozuqlab.context_hub_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.mozuqlab.context_hub_client"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("localTest") {
            storeFile = rootProject.file("../.local-signing/context-hub-test.jks")
            storePassword = "android"
            keyAlias = "context-hub-local"
            keyPassword = "android"
        }
    }
    buildTypes {
        release {
            // 手元検証用。公開配布の署名ではない。
            signingConfig = signingConfigs.getByName("localTest")
        }
    }
}

flutter {
    source = "../.."
}
