import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Keys come from local.properties (git-ignored) and are compiled into this build only.
val local = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
fun prop(k: String) = "\"" + (local.getProperty(k) ?: "") + "\""

android {
    namespace = "com.muisti.test"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.muisti.test"
        minSdk = 29   // Meta Wearables Device Access Toolkit
        targetSdk = 34
        versionCode = 2
        versionName = "0.3"
        ndk { abiFilters += listOf("arm64-v8a") }   // modern phones only: the APK was 134 MB with every ABI
        // Meta glasses: empty in Developer Mode (as Meta's sample; a bare "0" is parsed as a number and the
        // SDK cannot read it); real values from the Wearables Developer Center for a published app
        manifestPlaceholders["mwdat_application_id"] = local.getProperty("mwdat_application_id") ?: ""
        manifestPlaceholders["mwdat_client_token"] = local.getProperty("mwdat_client_token") ?: ""
        buildConfigField("String", "LLM_BASE_URL", prop("muisti.llmBaseUrl"))
        buildConfigField("String", "LLM_MODEL", prop("muisti.llmModel"))
        buildConfigField("String", "LLM_KEY", prop("muisti.llmKey"))
        buildConfigField("String", "EMBED_KEY", prop("muisti.embedKey"))
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true; buildConfig = true }
}

// The prompts are NOT copied by hand: the app reads the same docs/prompts.json the Python
// pipeline is exported to (tools/export_prompts.py), so both always use identical text.
val copyPrompts by tasks.registering(Copy::class) {
    from(rootProject.file("../nemotron/docs/prompts.json"))
    into(layout.projectDirectory.dir("src/main/assets"))
}
tasks.named("preBuild") { dependsOn(copyPrompts) }

// Parity tests talk to the real model with the same keys (eval against the Python pipeline).
tasks.withType<Test>().configureEach {
    for (k in listOf("llmBaseUrl", "llmModel", "llmKey", "embedKey")) local.getProperty("muisti.$k")?.let { systemProperty("muisti.$k", it) }
    systemProperty("muisti.repo", rootProject.file("..").absolutePath)
    System.getProperty("muisti.mem")?.let { systemProperty("muisti.mem", it) }
    System.getProperty("muisti.q")?.let { systemProperty("muisti.q", it) }
    testLogging { showStandardStreams = true; events("failed") }
    outputs.upToDateWhen { false }
}

dependencies {
    val bom = platform("androidx.compose:compose-bom:2024.06.00")
    implementation(bom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    val camerax = "1.3.4"
    implementation("androidx.camera:camera-core:$camerax")
    implementation("androidx.camera:camera-camera2:$camerax")
    implementation("androidx.camera:camera-lifecycle:$camerax")
    implementation("androidx.camera:camera-view:$camerax")
    implementation("com.google.mlkit:text-recognition:16.0.1")   // on-device, bundled model
    // privacy (Ahmet's face blur, ported): faces + body pose, on device
    implementation("com.google.mlkit:face-detection:16.1.7")
    implementation("com.google.mlkit:pose-detection:18.0.0-beta5")
    // where each memory was made (Mustafa's LocationProvider, ported)
    implementation("com.google.android.gms:play-services-location:21.3.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // Ray-Ban Meta glasses camera (Wearables Device Access Toolkit)
    implementation("com.meta.wearable:mwdat-core:1.0.1")
    implementation("com.meta.wearable:mwdat-camera:1.0.1")

    // engine parity tests run on the JVM against the Python test memories
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
