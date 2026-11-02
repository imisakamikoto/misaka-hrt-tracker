import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.oyama.hrt_tracker"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications uses java.time, which needs desugaring on
        // the older API levels the app still supports.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.oyama.hrt_tracker"
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

// The model lives in a plain Rust cdylib (libhrt_core.so) so it can be reused by
// other clients. It is cross-compiled for every ABI before packaging. When the
// Rust toolchain is not installed the task is skipped and the libraries already
// in src/main/jniLibs are used, so a Flutter-only build still works.
val cargoExecutable: String? = listOfNotNull(
    System.getenv("CARGO_HOME"),
    "${System.getProperty("user.home")}/.cargo",
).map { "$it/bin/cargo" }.firstOrNull { File(it).canExecute() }

val androidSdkDir: String? = run {
    val props = Properties()
    val local = file("../local.properties")
    if (local.exists()) local.inputStream().use { props.load(it) }
    props.getProperty("sdk.dir") ?: System.getenv("ANDROID_HOME") ?: System.getenv("ANDROID_SDK_ROOT")
}

tasks.register<Exec>("buildRustCore") {
    group = "build"
    description = "Cross-compiles rust/ into jniLibs for all Android ABIs"
    workingDir = file("../rust")
    onlyIf { cargoExecutable != null && file("../rust/Cargo.toml").exists() }
    doFirst {
        val cargo = cargoExecutable ?: return@doFirst
        androidSdkDir?.let { environment("ANDROID_HOME", it) }
        commandLine(
            cargo,
            "ndk",
            "-t", "arm64-v8a",
            "-t", "armeabi-v7a",
            "-t", "x86_64",
            "-o", file("src/main/jniLibs").absolutePath,
            "build",
            "--release",
        )
    }
}

tasks.matching { it.name == "preBuild" }.configureEach {
    dependsOn("buildRustCore")
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
