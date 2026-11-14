package com.muisti.test

import android.Manifest
import android.content.pm.PackageManager
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.meta.wearable.dat.camera.Camera
import com.meta.wearable.dat.camera.addCamera
import com.meta.wearable.dat.camera.types.StreamConfiguration
import com.meta.wearable.dat.camera.types.StreamState
import com.meta.wearable.dat.camera.types.VideoFrame
import com.meta.wearable.dat.camera.types.VideoQuality
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.selectors.AutoDeviceSelector
import com.meta.wearable.dat.core.session.DeviceSession
import com.meta.wearable.dat.core.session.DeviceSessionState
import com.meta.wearable.dat.core.types.DeviceCompatibility
import com.meta.wearable.dat.core.types.HingeState
import com.meta.wearable.dat.core.types.LinkState
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.core.types.RegistrationState
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * Ray-Ban Meta camera through Meta's Wearables Device Access Toolkit.
 *
 * Order (as in Meta's CameraAccess sample): Bluetooth permission -> Wearables.initialize ->
 * register with the Meta AI app -> camera permission (granted inside Meta AI) -> device session ->
 * camera stream. Frames are RAW (compressVideo = false): the SDK decodes them to I420
 * (MediaCodec color-format 19), so no HEVC decoder is needed here.
 *
 * Must be constructed during the activity's construction (it registers activity-result launchers).
 */
class GlassesSource(private val activity: ComponentActivity, private val state: AppState,
                    private val onFrame: (VideoFrame) -> Unit) {

    private var session: DeviceSession? = null
    private var camera: Camera? = null
    private var job: Job? = null
    private var initialized = false
    // read lazily: the activity is not ready for preferences while it is being constructed
    private val prefs by lazy { activity.getSharedPreferences("glasses", android.content.Context.MODE_PRIVATE) }
    private val cameraGrantedSaved get() = prefs.getBoolean("glassesCam", false)
    private var cameraGranted = false

    private var btCont: CancellableContinuation<Boolean>? = null
    private val btLauncher = activity.registerForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        btCont?.resume(ok); btCont = null
    }
    private var permCont: CancellableContinuation<PermissionStatus>? = null
    private val permLauncher = activity.registerForActivityResult(Wearables.RequestPermissionContract()) { result ->
        permCont?.resume(result.getOrDefault(PermissionStatus.Denied)); permCont = null
    }

    private fun status(s: String) { state.glassesStatus = s; Log.i("MuistiGlasses", s) }

    fun connect() {
        if (job?.isActive == true) return
        state.glassesNeedsUpdate = false
        job = activity.lifecycleScope.launch {
            // 1. Bluetooth (runtime permission on Android 12+)
            if (ContextCompat.checkSelfPermission(activity, Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
                status("Asking for Bluetooth permission…")
                val ok = suspendCancellableCoroutine<Boolean> { btCont = it; btLauncher.launch(Manifest.permission.BLUETOOTH_CONNECT) }
                if (!ok) { status("Bluetooth permission denied"); return@launch }
            }
            // 2. SDK
            if (!initialized) {
                Wearables.initialize(activity.applicationContext)   // a second call only reports ALREADY_INITIALIZED
                initialized = true
            }
            // 3. Register this app with the Meta AI app (opens Meta AI once, then comes back)
            if (Wearables.registrationState.value != RegistrationState.REGISTERED) {
                status("Registering with Meta AI…")
                Wearables.startRegistration(activity)
                Wearables.registrationState.first { it == RegistrationState.REGISTERED }   // waits until Meta AI confirms
            }
            // 4. Wait until Meta AI actually has the glasses connected. Creating a session before that fails
            //    with "No eligible device available" (the device list fills in a moment after initialize,
            //    and stays empty while the glasses are in the case / asleep / connected to another phone).
            val dev = waitForGlasses() ?: return@launch
            // 5. Camera permission (granted inside Meta AI) - asked once; later Try agains don't ask again
            if (!cameraGranted) cameraGranted = cameraGrantedSaved
            if (!cameraGranted) {
                status("Checking camera permission…")
                val current = Wearables.checkPermissionStatus(Permission.CAMERA).getOrNull()
                cameraGranted = current == PermissionStatus.Granted ||
                    suspendCancellableCoroutine<PermissionStatus> { permCont = it; permLauncher.launch(Permission.CAMERA) } == PermissionStatus.Granted
                if (!cameraGranted) { status("Camera permission denied in Meta AI"); return@launch }
                prefs.edit().putBoolean("glassesCam", true).apply()
            }
            // 6. Session -> 7. stream (a few tries: the link can still be settling right after it connects)
            status("Connecting to $dev…")
            var s: DeviceSession? = null
            for (attempt in 1..4) {
                var failed = ""
                Wearables.createSession(AutoDeviceSelector()).onSuccess { s = it }.onFailure { e, _ -> failed = e.description }
                if (s != null) break
                if (attempt == 4) { status("Could not connect: $failed"); return@launch }
                status("Glasses not ready yet ($failed), retrying…")
                kotlinx.coroutines.delay(2000)
                waitForGlasses() ?: return@launch
            }
            val sess = s!!
            session = sess
            launch {
                sess.errors.collect {
                    // e.g. "Your glasses need an update. Go to App Connections page in Meta AI to update"
                    if (it.description.contains("update", ignoreCase = true)) state.glassesNeedsUpdate = true
                    status("Glasses: ${it.description}")
                }
            }
            launch {
                sess.state.collect { st ->
                    when (st) {
                        DeviceSessionState.STARTED -> startStream(sess)
                        DeviceSessionState.STOPPED -> { camera = null; if (state.useGlasses) status("Glasses disconnected") }
                        else -> status("Glasses: ${st.name.lowercase()}…")
                    }
                }
            }
            sess.start()
        }
    }

    /**
     * Waits (up to 60 s) for glasses that Meta AI reports as CONNECTED and compatible, and says what is
     * missing meanwhile. Returns the glasses' name, or null (status explains why).
     */
    private suspend fun waitForGlasses(): String? {
        val deadline = System.currentTimeMillis() + 60_000
        while (System.currentTimeMillis() < deadline) {
            val devs = Wearables.devices.value.mapNotNull { Wearables.devicesMetadata[it]?.value }
            val ready = devs.firstOrNull { it.linkState == LinkState.CONNECTED && it.compatibility == DeviceCompatibility.COMPATIBLE }
            if (ready != null) return ready.name.ifBlank { "your glasses" }
            val d = devs.firstOrNull()
            when {
                d == null -> status("Waiting for your glasses… open the case / put them on, and check they're connected in Meta AI…")
                d.compatibility == DeviceCompatibility.DEVICE_UPDATE_REQUIRED -> {
                    state.glassesNeedsUpdate = true; status("Your glasses need an update in Meta AI"); return null
                }
                d.compatibility == DeviceCompatibility.SDK_UPDATE_REQUIRED -> { status("This app's glasses SDK is too old for these glasses"); return null }
                d.hingeState == HingeState.CLOSED -> status("${d.name}: the glasses are folded - unfold them…")
                d.linkState != LinkState.CONNECTED -> status("${d.name}: ${d.linkState.name.lowercase()} - waiting for Bluetooth…")
                else -> status("${d.name}: getting ready…")
            }
            kotlinx.coroutines.delay(1000)
        }
        status("Couldn't find connected glasses. Check Meta AI shows them connected, then Try again")
        return null
    }

    private fun startStream(s: DeviceSession) {
        if (camera != null) return
        // HIGH = 720x1280 (best for reading signs); 15 fps is plenty for "sharpest frame per half second"
        s.addCamera(StreamConfiguration(null, VideoQuality.HIGH, 15, false))
            .onSuccess { cam ->
                camera = cam
                val stream = cam.stream
                // frames are converted/scored off the main thread
                activity.lifecycleScope.launch(Dispatchers.Default) { stream.videoStream.collect { onFrame(it) } }
                activity.lifecycleScope.launch {
                    stream.state.collect { st ->
                        status(when (st) {
                            StreamState.STREAMING -> "Streaming from glasses"
                            StreamState.PAUSED -> "Glasses stream paused"
                            else -> "Glasses stream: ${st.name.lowercase()}"
                        })
                    }
                }
                activity.lifecycleScope.launch {
                    stream.errorStream.collect {
                        if (it.description.contains("permission", ignoreCase = true)) {   // revoked in Meta AI: ask again next time
                            cameraGranted = false
                            prefs.edit().putBoolean("glassesCam", false).apply()
                        }
                        status("Stream error: ${it.description}")
                    }
                }
                stream.start().onFailure { e, _ -> status("Stream would not start: ${e.description}") }
            }
            .onFailure { e, _ -> status("Camera would not attach: ${e.description}") }
    }

    /** Opens Meta AI's update page for the toolkit app that runs ON the glasses. */
    fun openUpdate() {
        Wearables.openDATGlassesAppUpdate(activity).onFailure { e, _ -> status("Could not open Meta AI: ${e.description}") }
    }

    fun disconnect() {
        job?.cancel(); job = null
        runCatching { camera?.stop() }
        runCatching { session?.stop() }
        camera = null; session = null
        status("Glasses off")
    }
}
