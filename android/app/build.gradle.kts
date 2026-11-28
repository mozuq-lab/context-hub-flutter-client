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

    // 公開用の鍵は、リリースのワークフロー（.github/workflows/release.yml）が
    // GitHubのSecretsから取り出して環境変数で渡す。指定がなければ手元検証用の鍵で署名する。
    val releaseKeystore = System.getenv("CONTEXT_HUB_ANDROID_KEYSTORE")?.takeIf { it.isNotEmpty() }
    signingConfigs {
        create("localTest") {
            storeFile = rootProject.file("../.local-signing/context-hub-test.jks")
            storePassword = "android"
            keyAlias = "context-hub-local"
            keyPassword = "android"
        }
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = System.getenv("CONTEXT_HUB_ANDROID_STORE_PASSWORD")
                keyAlias = System.getenv("CONTEXT_HUB_ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("CONTEXT_HUB_ANDROID_KEY_PASSWORD")
            }
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (releaseKeystore != null) "release" else "localTest")
        }
    }
}

flutter {
    source = "../.."
}
