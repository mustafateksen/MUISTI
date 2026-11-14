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
            // 4. Camera permission (granted inside Meta AI)
            status("Checking camera permission…")
            val current = Wearables.checkPermissionStatus(Permission.CAMERA).getOrNull()
            val granted = current == PermissionStatus.Granted ||
                suspendCancellableCoroutine<PermissionStatus> { permCont = it; permLauncher.launch(Permission.CAMERA) } == PermissionStatus.Granted
            if (!granted) { status("Camera permission denied in Meta AI"); return@launch }
            // 5. Session -> 6. stream
            status("Connecting to the glasses…")
            Wearables.createSession(AutoDeviceSelector())
                .onSuccess { s ->
                    session = s
                    launch {
                        s.errors.collect {
                            // e.g. "Your glasses need an update. Go to App Connections page in Meta AI to update"
                            if (it.description.contains("update", ignoreCase = true)) state.glassesNeedsUpdate = true
                            status("Glasses: ${it.description}")
                        }
                    }
                    launch {
                        s.state.collect { st ->
                            when (st) {
                                DeviceSessionState.STARTED -> startStream(s)
                                DeviceSessionState.STOPPED -> { camera = null; if (state.useGlasses) status("Glasses disconnected") }
                                else -> status("Glasses: ${st.name.lowercase()}…")
                            }
                        }
                    }
                    s.start()
                }
                .onFailure { e, _ -> status("Could not connect: ${e.description}") }
        }
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
                activity.lifecycleScope.launch { stream.errorStream.collect { status("Stream error: ${it.description}") } }
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
