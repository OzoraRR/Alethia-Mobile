import java.util.Base64
import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// A fresh clone can run against the shared hosted backend. A developer's local
// profile overrides the whole config; missing fields never mix two databases.
val requestedProfile = providers.gradleProperty("alethiaConfig").orNull
val configFile = when {
    requestedProfile != null -> rootProject.file(requestedProfile)
    rootProject.file("alethia.properties").isFile -> rootProject.file("alethia.properties")
    else -> rootProject.file("config/hosted.properties")
}
require(configFile.isFile) {
    "Alethia config file not found: ${configFile.name}. Use config/hosted.properties or create a local profile."
}
val localConfig = Properties().apply {
    configFile.takeIf { it.exists() }?.inputStream()?.use { load(it) }
}
fun publicSetting(name: String): String = providers.environmentVariable(name)
    .orNull ?: localConfig.getProperty(name, "")
fun quoted(value: String) = "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r") + "\""
val publicKey = publicSetting("ALETHIA_SUPABASE_PUBLISHABLE_KEY")
val legacyClaims = runCatching {
    String(Base64.getUrlDecoder().decode(publicKey.split('.').getOrElse(1) { "" }))
}.getOrDefault("")
require(!publicKey.startsWith("sb_secret_") && !legacyClaims.contains("service_role")) {
    "Use a Supabase publishable/anon key. Server secret keys must not be packaged in Android."
}

android {
    namespace = "dev.alethia.mobile"
    compileSdk = 37
    defaultConfig {
        applicationId = "dev.alethia.mobile"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "SUPABASE_URL", quoted(publicSetting("ALETHIA_SUPABASE_URL")))
        buildConfigField("String", "SUPABASE_PUBLISHABLE_KEY", quoted(publicKey))
        buildConfigField("String", "API_BASE_URL", quoted(publicSetting("ALETHIA_API_BASE_URL")))
    }
    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            manifestPlaceholders["usesCleartextTraffic"] = "true"
        }
        release {
            manifestPlaceholders["usesCleartextTraffic"] = "false"
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { compose = true; buildConfig = true }
    bundle { language { enableSplit = false } }
    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
}
kotlin { compilerOptions { jvmTarget.set(JvmTarget.JVM_17) } }

dependencies {
    implementation(project(":core"))
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.androidx.core.splashscreen)
    implementation(platform(libs.supabase.bom))
    implementation(libs.supabase.auth)
    implementation(libs.ktor.client.android)
    implementation(libs.kotlinx.serialization.json)
    // Upgrade Compose's transitive native path library for 16 KB page-size support.
    implementation(libs.androidx.graphics.path)
    debugImplementation(libs.androidx.compose.ui.tooling)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
    testImplementation(libs.junit)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test)
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.androidx.test.espresso)
}
