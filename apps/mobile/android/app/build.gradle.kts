import java.net.URI

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

fun buildValue(name: String, fallback: String = ""): String =
    providers.environmentVariable(name).getOrElse(fallback)

fun javaString(value: String): String =
    "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"")
        .replace("\r", "\\r").replace("\n", "\\n") + "\""

val uploadMode = buildValue("ITDA_UPLOAD_MODE", "disabled")
require(uploadMode in setOf("disabled", "mock", "staging", "live")) {
    "ITDA_UPLOAD_MODE must be disabled, mock, staging, or live."
}

val staging = uploadMode == "staging"
val mock = uploadMode == "mock"
val uploadEnabled = uploadMode != "disabled"
val prefix = if (staging) "ITDA_STAGING_" else "ITDA_"
val endpointSettings = listOf("API_BASE_URL", "SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY")
if (uploadEnabled) {
    val otherPrefix = if (staging) "ITDA_" else "ITDA_STAGING_"
    require(endpointSettings.none { buildValue(otherPrefix + it).isNotEmpty() }) {
        "Staging endpoint settings and the other upload endpoint settings must use separate build environments."
    }
}

fun endpoint(setting: String): String {
    if (!uploadEnabled) return ""
    val name = prefix + setting
    val value = buildValue(name)
    val uri = runCatching { URI(value) }.getOrNull()
    val scheme = uri?.scheme?.lowercase()
    val validTransport = if (mock) {
        scheme in setOf("http", "https") && uri?.host?.lowercase() in setOf("localhost", "127.0.0.1", "10.0.2.2")
    } else {
        scheme == "https"
    }
    require(uri != null && validTransport && !uri.host.isNullOrEmpty() && uri.port in -1..65535 &&
        uri.port != 0 && uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null) {
        "$name must be an absolute ${if (mock) "loopback HTTP(S)" else "HTTPS"} base URL without credentials, a query, or a fragment."
    }
    return value
}

val apiBaseUrl = endpoint("API_BASE_URL")
val supabaseUrl = endpoint("SUPABASE_URL")
val keySetting = prefix + "SUPABASE_PUBLISHABLE_KEY"
val supabasePublishableKey = if (uploadEnabled) buildValue(keySetting) else ""
require(!uploadEnabled || supabasePublishableKey.matches(Regex("sb_publishable_[A-Za-z0-9_-]+"))) {
    "$keySetting must be a Supabase publishable key."
}

android {
    namespace = "com.itda.itda_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.itda.itda_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        manifestPlaceholders["itdaAppName"] = "@string/app_name"
        manifestPlaceholders["itdaNetworkPolicy"] = "@xml/https_network_security"
        buildConfigField("String", "UPLOAD_MODE", javaString(uploadMode))
        buildConfigField("String", "API_BASE_URL", javaString(apiBaseUrl))
        buildConfigField("String", "SUPABASE_URL", javaString(supabaseUrl))
        buildConfigField("String", "SUPABASE_PUBLISHABLE_KEY", javaString(supabasePublishableKey))
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        debug {
            if (staging) {
                applicationIdSuffix = ".staging"
                manifestPlaceholders["itdaAppName"] = "@string/staging_app_name"
            }
            if (mock || !uploadEnabled) {
                manifestPlaceholders["itdaNetworkPolicy"] = "@xml/debug_network_security"
            }
        }
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

androidComponents {
    beforeVariants { variant ->
        if ((staging || mock) && variant.buildType != "debug") variant.enable = false
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("androidx.core:core:1.18.0")
    implementation("androidx.work:work-runtime:2.12.0")
    implementation("com.squareup.okhttp3:okhttp:5.3.2")
    androidTestImplementation("androidx.test:core:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("com.squareup.okhttp3:mockwebserver3:5.3.2")
}
