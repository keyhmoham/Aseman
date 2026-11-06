import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// What this build is for: the platform's app id, name and node
// (aseman-platform-client writes client.properties before it builds), and the
// key that signs every version of the platform's app alike (key.properties).
fun props(name: String): Properties = Properties().apply {
    val f = rootProject.file(name)
    if (f.exists()) f.inputStream().use { load(it) }
}
val client = props("client.properties")
val signing = props("key.properties")

android {
    namespace = "io.aseman.aseman_platform_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = client.getProperty("applicationId", "io.aseman.platform.example")
        manifestPlaceholders["appLabel"] = client.getProperty("label", "Aseman platform")
        manifestPlaceholders["cleartext"] = client.getProperty("cleartext", "false")
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (signing.getProperty("storeFile") != null) {
            create("platform") {
                storeFile = file(signing.getProperty("storeFile"))
                storePassword = signing.getProperty("storePassword")
                keyAlias = signing.getProperty("keyAlias")
                keyPassword = signing.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // The platform's own key when there is one (updates install over
            // the version before); the debug key otherwise, for development.
            signingConfig = signingConfigs.findByName("platform") ?: signingConfigs.getByName("debug")
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
