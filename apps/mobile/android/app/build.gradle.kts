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

val supabasePublishableKey = buildValue("ITDA_SUPABASE_PUBLISHABLE_KEY")
require(supabasePublishableKey.isEmpty() || supabasePublishableKey.matches(Regex("sb_publishable_[A-Za-z0-9_-]+"))) {
    "ITDA_SUPABASE_PUBLISHABLE_KEY must be a Supabase publishable key."
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
        buildConfigField("String", "UPLOAD_MODE", javaString(buildValue("ITDA_UPLOAD_MODE", "disabled")))
        buildConfigField("String", "API_BASE_URL", javaString(buildValue("ITDA_API_BASE_URL")))
        buildConfigField("String", "SUPABASE_URL", javaString(buildValue("ITDA_SUPABASE_URL")))
        buildConfigField("String", "SUPABASE_PUBLISHABLE_KEY", javaString(supabasePublishableKey))
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("androidx.work:work-runtime:2.12.0")
    implementation("com.squareup.okhttp3:okhttp:5.3.2")
    androidTestImplementation("androidx.test:core:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("com.squareup.okhttp3:mockwebserver3:5.3.2")
}
