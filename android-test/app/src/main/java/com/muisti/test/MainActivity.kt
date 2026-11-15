package com.muisti.test

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Base64
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import android.annotation.SuppressLint
import android.view.MotionEvent
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import android.util.Size
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.google.mlkit.vision.common.InputImage
import com.muisti.engine.Obs
import com.muisti.privacy.OldMemoryScan
import com.muisti.privacy.PrivacyText
import com.muisti.privacy.SceneRules
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import java.util.concurrent.Executors
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume

/**
 * MUISTI test app (Android, phone camera instead of the glasses).
 *
 * Memory: continuous camera stream, sharpest frame per half second (see 'memory stream') -> ML Kit reads text ON THE PHONE with positions ->
 *   POST /ingest {frame_jpeg_b64, ocr_observations:[{text, conf, box:[x,y,w,h]}]}  (0..1, top-left)
 *   - the same format Apple Vision uses on iOS, so the server's line join / repair work the same.
 * Assistant: type or speak (English) -> POST /ask -> answer card + spoken answer.
 * Live voice: once the orb is opened it keeps listening -> answering -> listening until the user ends it.
 */
class MainActivity : ComponentActivity() {

    val state = AppState()
    val engine get() = AppGraph.engine
    /** Ray-Ban Meta camera (created here: it registers activity-result launchers). */
    private val glasses = GlassesSource(this, state) { onGlassesFrame(it) }
    /** Ahmet's head masking: nothing leaves the phone or is stored unblurred. */
    private val blurrer by lazy { VisualRedactor() }
    private val location by lazy { LocationTracker(applicationContext) }
    private val locationPermission = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { res ->
        if (res.values.any { it } && state.recording) { location.start(); state.hasLocation = true }
    }
    private var cameraProvider: ProcessCameraProvider? = null
    private var phoneUseCases: Array<androidx.camera.core.UseCase> = emptyArray()
    private var glassesFormatLogged = false
    private var lastPreviewAt = 0L
    /** Latest camera view (JPEG), refreshed ~2x per second, for "what are you seeing right now?". */
    @Volatile private var liveJpeg: ByteArray? = null
    private var lastLiveAt = 0L
    lateinit var previewView: PreviewView

    private val http = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS).readTimeout(120, TimeUnit.SECONDS).build()
    private val jsonType = "application/json; charset=utf-8".toMediaType()
    private val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    private var camera: Camera? = null
    private val sharpHistory = ArrayDeque<Double>()
    private var statsJob: Job? = null
    private var speech: SpeechRecognizer? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private val earcon by lazy { runCatching { android.media.ToneGenerator(android.media.AudioManager.STREAM_MUSIC, 35) }.getOrNull() }
    private var lastFiller = -1
    private val fillers = listOf("One sec.", "Let me check.", "Hmm, let me think.", "Looking back at what I saw.",
        "Give me a moment.", "Let me see.", "Okay, checking.")

    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { res ->
        if (res[Manifest.permission.CAMERA] == true) startCamera()
        else state.toast("Camera permission is needed to remember things.")
    }

    /** Temporary: add a photo to memory (picker, "Share to MUISTI", or a test file) - same path as a camera frame. */
    private val photoPicker = registerForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri?.let { u -> importImage { contentResolver.openInputStream(u)?.use { it.readBytes() } } }
    }

    fun pickPhoto() = photoPicker.launch(androidx.activity.result.PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))

    private fun handleImportIntent(i: Intent?) {
        if (i == null) return
        if (i.action == Intent.ACTION_SEND && i.type?.startsWith("image/") == true) {
            @Suppress("DEPRECATION")
            val uri = i.getParcelableExtra<android.net.Uri>(Intent.EXTRA_STREAM) ?: return
            importImage { contentResolver.openInputStream(uri)?.use { it.readBytes() } }
        }
        // test hook (adb): a file inside this app's own storage only
        i.getStringExtra("muisti_import")?.let { path ->
            val f = java.io.File(path)
            if (f.canonicalPath.startsWith(filesDir.canonicalPath)) importImage { f.readBytes() }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleImportIntent(intent)
        if (intent.getBooleanExtra("open_agent", false)) openAgentCenter()
    }

    private fun importImage(read: () -> ByteArray?) {
        state.toast("Adding photo to memory…")
        lifecycleScope.launch {
            val msg = runCatching {
                withContext(Dispatchers.IO) {
                    val bytes = read() ?: return@withContext "Couldn't read that photo."
                    var bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return@withContext "That isn't an image."
                    val l = maxOf(bmp.width, bmp.height)
                    if (l > 1536) bmp = Bitmap.createScaledBitmap(bmp, bmp.width * 1536 / l, bmp.height * 1536 / l, true)
                    val ocr = withContext(Dispatchers.Main) { readText(bmp) }
                    val (obs, plates) = plateFilter(bmp, ocr)
                    // the same privacy gate as the live stream (one photo: judged on its own)
                    if (!privacy.available) return@withContext "Not saved: the privacy check isn't available (nothing was sent)."
                    val sc = runCatching { privacy.score(bmp) }.getOrNull()
                        ?: return@withContext "Not saved: the privacy check failed (nothing was sent)."
                    val importVec = sc.vec
                    android.util.Log.i("MuistiPrivacy", "import: stop %.2f (%s) drop %.2f (%s) text %.2f, %d ms".format(sc.stop, sc.stopClass, sc.pin, sc.dropClass, sc.textual, sc.ms))
                    SceneRules.blockReason(sc.byClass, privacySettings.current)?.let { return@withContext "Not saved: $it (privacy)." }
                    PrivacyText.check(ocr.obs.map { it.text }, sc.hint)?.let { return@withContext "Not saved: it shows $it (privacy)." }
                    val safe = blurrer.process(bmp, plates) ?: return@withContext "Skipped: privacy check failed."
                    val jpeg = ByteArrayOutputStream().also { safe.image.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
                    // where and when: the photo's own EXIF (a camera photo knows both), else right now
                    val exif = runCatching { android.media.ExifInterface(java.io.ByteArrayInputStream(bytes)) }.getOrNull()
                    val ll = FloatArray(2).takeIf { exif?.getLatLong(it) == true }?.map { it.toDouble() }
                    val taken = exif?.getAttribute(android.media.ExifInterface.TAG_DATETIME_ORIGINAL)?.let {
                        runCatching { java.text.SimpleDateFormat("yyyy:MM:dd HH:mm:ss", java.util.Locale.US).parse(it)?.time }.getOrNull()
                    }
                    if (ll != null) com.muisti.privacy.Zones.inside(ll[0], ll[1], 0f, privacySettings.current.zones)?.let {
                        return@withContext "Not saved: taken in the no-record zone \"${it.name}\"." }
                    val hasPerm = ContextCompat.checkSelfPermission(this@MainActivity, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
                    val fix = when {
                        ll != null -> Fix(ll[0], ll[1], 0f, taken ?: System.currentTimeMillis(), location.streetAt(ll[0], ll[1]))
                        else -> location.fresh(60_000) ?: if (hasPerm) location.currentFix() else null
                    }
                    val ok = engine.ingest(jpeg, obs, taken ?: System.currentTimeMillis(), dHash(bmp), fix, importVec)
                    if (ok) { state.memories = engine.store.sightings().size; "Remembered · ${obs.size} text lines" } else "Nothing worth keeping in that photo."
                }
            }.getOrElse { "Couldn't add the photo: ${it.message?.take(60)}" }
            state.toast(msg)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppGraph.init(applicationContext)
        enableEdgeToEdge()
        state.serverUrl = getPreferences(MODE_PRIVATE).getString("server", "http://10.0.34.200:8000")!!
        previewView = PreviewView(this).apply { scaleType = PreviewView.ScaleType.FILL_CENTER }
        setContent { MuistiApp(this) }
        state.privacySettings = privacySettings.current
        privacySettings.listen { s -> runOnUiThread { state.privacySettings = s } }
        privacySettings.listen { s -> ZoneGeofences.sync(applicationContext, s.zones) }
        ZoneGeofences.sync(applicationContext, privacySettings.current.zones)
        handleImportIntent(intent)

        tts = TextToSpeech(this, { status ->
            if (status == TextToSpeech.SUCCESS) {
                tts?.language = Locale.US
                runCatching { pickVoice() }
                tts?.setSpeechRate(1.0f); tts?.setPitch(1.0f)
                ttsReady = true
            }
        }, "com.google.android.tts")   // Google's engine: its neural voices sound far more human
        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String?) { if (id?.startsWith("answer") == true) runOnUiThread { state.phase = VoicePhase.Speaking } }
            // every spoken word gives the orb a pulse, so it moves with MUISTI's real speech
            override fun onRangeStart(id: String?, start: Int, end: Int, frame: Int) {
                if (id?.startsWith("answer") != true) return
                val peak = 0.55f + java.util.Random().nextFloat() * 0.45f * minOf(1f, (end - start) / 6f + 0.3f)
                runOnUiThread { state.level = peak; state.spokenFrom = start; state.spokenTo = end }
                mainHandler.postDelayed({ if (state.phase == VoicePhase.Speaking) state.level = 0.08f }, 120)
            }
            // a filler ("One sec.") is not the end of the turn: only the answer hands the mic back
            override fun onDone(id: String?) { if (id == "answer") runOnUiThread { afterTurn() } }
            @Deprecated("Deprecated in Java")
            override fun onError(id: String?) { if (id == "answer") runOnUiThread { afterTurn() } }
        })
        engine.warm()
        Thread {
            // loads the model; from now on every image leaving the phone is checked at the exit too (fail-closed before this)
            privacy.loadError?.let { e -> runOnUiThread { state.toast("Privacy model missing: nothing will be sent ($e)") } }
            engine.setGate(privacy.gate)
            // memories stored before the privacy gate existed: checked in WorkManager, resumable (OldMemoryScanWorker)
            OldMemoryScanWorker.schedule(applicationContext)
        }.start()

        val need = (listOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO,
            Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR) +
            (if (android.os.Build.VERSION.SDK_INT >= 33) listOf(Manifest.permission.POST_NOTIFICATIONS) else emptyList()))
            .filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
        if (need.isEmpty()) startCamera() else permissions.launch(need.toTypedArray())
        pollStats()
        watchNetwork()
    }

    private var netCallback: android.net.ConnectivityManager.NetworkCallback? = null
    private var drainJob: Job? = null

    /** Offline state from the system (validated internet), and the queue drained when it comes back. */
    private fun watchNetwork() {
        val cm = getSystemService(android.net.ConnectivityManager::class.java) ?: return
        fun hasNet() = cm.getNetworkCapabilities(cm.activeNetwork)?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
        state.network = hasNet()
        val cb = object : android.net.ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(n: android.net.Network, c: android.net.NetworkCapabilities) {
                val ok = c.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                runOnUiThread { if (ok && !state.network) android.util.Log.i("MuistiRate", "network back: ${engine.pending.size()} queued"); state.network = ok }
            }
            override fun onLost(n: android.net.Network) { runOnUiThread { state.network = hasNet() } }
        }
        netCallback = cb
        cm.registerDefaultNetworkCallback(cb)
        drainJob = lifecycleScope.launch(Dispatchers.IO) {
            val drainer = com.muisti.capture.Drainer(engine.pending)
            var lastSummary = 0L
            var lastNoticeCheck = 0L
            while (isActive) {
                // Agent Center: notice sources once a minute (local only, no model call)
                if (System.currentTimeMillis() - lastNoticeCheck > 60_000) {
                    lastNoticeCheck = System.currentTimeMillis()
                    runCatching { engine.checkSafety(lastNoticeCheck) + engine.checkNotices(lastNoticeCheck, location.fresh(60_000), upcomingEvents()) }
                        .onSuccess { it.forEach { n -> deliver(n) } }
                        .onFailure { android.util.Log.w("MuistiAgent", "notices failed: ${it.message}") }
                }
                // closed episodes get their summary in the background (one call each, at most 2 a minute)
                if (state.network && System.currentTimeMillis() - lastSummary > 60_000) {
                    lastSummary = System.currentTimeMillis()
                    runCatching { engine.summarizePending(lastSummary) }
                }
                state.queued = engine.pending.size()
                if (state.network && state.queued > 0) {
                    val n = drainer.drain({ state.network }, engine::ingestPending, maxFrames = 20)
                    if (n > 0) { android.util.Log.i("MuistiRate", "queue: $n frame(s) ingested after reconnect, ${engine.pending.size()} left")
                        state.memories = engine.store.sightings().size }
                }
                delay(5000)
            }
        }
    }

    override fun onDestroy() {
        netCallback?.let { runCatching { getSystemService(android.net.ConnectivityManager::class.java)?.unregisterNetworkCallback(it) } }
        drainJob?.cancel()
        statsJob?.cancel(); analysisExec.shutdown(); glassesExec.shutdown(); glasses.disconnect(); location.stop()
        speech?.destroy(); tts?.shutdown(); recognizer.close()
        super.onDestroy()
    }

    fun saveServer(url: String) {
        state.serverUrl = url.trim().trimEnd('/')
        getPreferences(MODE_PRIVATE).edit().putString("server", state.serverUrl).apply()
        pollStats()
    }

    // ---------------- camera + memory stream ----------------
    //
    // The camera runs like a video (~30 fps) into ImageAnalysis. Nothing waits for focus:
    //  - each frame gets a cheap sharpness score on the grey (Y) plane,
    //  - every scheduler window (0.5-7.5 s: motion, speed, battery, heat; see CaptureScheduler) the sharpest frame is kept,
    //  - it is dropped if it is blurry compared with recent windows (same rule as process_video.py)
    //    or if the view has not changed since the last frame sent (dHash),
    //  - the rest go to an upload queue: at most MAX_UPLOADS requests at once; when the queue is
    //    full the OLDEST waiting frame is dropped, so memory always follows what is in front of you.

    /** Window length comes from the adaptive scheduler (motion, speed, battery, heat); see capture/CaptureScheduler. */
    private val scheduler = com.muisti.capture.CaptureScheduler()
    private val motion by lazy { MotionMeter(applicationContext) }
    @Volatile private var decision = com.muisti.capture.CaptureDecision(1500, com.muisti.capture.Motion.UNKNOWN, 1.0, false, "starting")
    private var decidedAt = 0L

    private fun signals(): com.muisti.capture.CaptureSignals {
        val pm = getSystemService(android.os.PowerManager::class.java)
        val bm = getSystemService(android.os.BatteryManager::class.java)
        val (speed, acc) = location.speed()
        val g = if (state.useGlasses) glasses.current() else null
        return com.muisti.capture.CaptureSignals(motion.rms(), speed, acc,
            bm?.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)?.takeIf { it in 0..100 },
            pm?.isPowerSaveMode == true, pm?.currentThermalStatus ?: 0, g?.battery?.takeIf { it in 0..100 }, g?.thermal)
    }

    /** Re-decided once a second while recording. */
    private fun currentDecision(now: Long): com.muisti.capture.CaptureDecision {
        if (now - decidedAt >= 1000) {
            decidedAt = now
            val d = scheduler.decide(signals())
            if (d.paused != decision.paused) android.util.Log.i("MuistiRate", if (d.paused) "capture paused: ${d.reason}" else "capture resumed")
            decision = d
            runOnUiThread {
                state.capturePause = if (d.paused) d.reason else null
                state.captureMode = if (d.paused) "" else "${d.reason} · %.1f s".format(d.intervalMs / 1000.0)
                if (d.paused && state.recording) state.lastFrame = "Paused · ${d.reason}"
            }
        }
        return decision
    }
    private val MAX_UPLOADS = 3
    private val uploads = Channel<Held>(capacity = 2, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    private val analysisExec = Executors.newSingleThreadExecutor()
    private var windowStart = 0L
    private var windowBest: Bitmap? = null
    private var windowBestScore = -1.0
    private var lastSentHash = -1L
    private var framesThisSecond = 0
    private var secondStart = 0L

    // ---------------- privacy gate (see PrivacyGuard) ----------------
    /** The user's privacy choices (persisted); every check below reads the live copy. */
    val privacySettings get() = AppGraph.privacySettings
    private val privacy get() = AppGraph.privacy
    val privacyActions = object : com.muisti.ui.PrivacyActions {
        override fun setClass(cls: String, on: Boolean) {
            // a newly switched-on class also applies to older memories: check them again
            privacySettings.update { s -> s.withClass(cls, on).let { n -> if (on && !s.isActive(cls)) OldMemoryScan.restart(n) else n } }
            if (on) OldMemoryScanWorker.schedule(applicationContext)
        }
        override fun setPlateBlur(on: Boolean) { privacySettings.update { it.copy(plateBlur = on) } }
        override fun addZoneHere() {
            lifecycleScope.launch {
                val fix = withContext(Dispatchers.IO) { location.fresh(30_000) ?: if (ContextCompat.checkSelfPermission(this@MainActivity,
                    Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED) location.currentFix() else null }
                if (fix == null) { state.toast("No location yet: allow location and try again"); return@launch }
                val z = com.muisti.privacy.Zones.newZone(fix.street?.let { "Near $it" } ?: "Zone", fix.lat, fix.lon)
                privacySettings.update { it.copy(zones = it.zones + z) }
                state.toast("No-record zone added (${z.radiusM.toInt()} m)")
            }
        }
        override fun removeZone(id: String) { privacySettings.update { s -> s.copy(zones = s.zones.filter { it.id != id }) } }
        override val canSimulate = BuildConfig.DEBUG
        override fun simulateAt(z: com.muisti.privacy.Zone?) {
            if (!BuildConfig.DEBUG) return
            location.simulated = z?.let { Fix(it.lat, it.lon, 5f, System.currentTimeMillis(), "simulated: ${it.name}") }
            state.toast(if (z == null) "Location simulation off" else "Simulating a position inside \"${z.name}\"")
        }
        override fun scanNow() { OldMemoryScanWorker.now(applicationContext); state.toast("Checking older memories…") }
        override fun setSensitiveOcr(on: Boolean) { privacySettings.update { it.copy(sensitiveOcr = on) } }
        override fun close() { state.showPrivacy = false }
    }
    private val DELAY_MS = 3000L                       // frames wait this long on the phone before they may leave it
    private class Held(val bmp: Bitmap, val hash: Long, val at: Long, val vec: FloatArray? = null)
    /** Image vector of the frame isPrivate() checked last (same thread): kept with the frame for visual search. */
    @Volatile private var lastVec: FloatArray? = null
    private val held = ArrayDeque<Held>()

    /**
     * THE gate, on the phone, for every image before it can leave the phone (memory stream, "what am I
     * seeing?", imports). True = this image must not go to Nemotron. Fail-closed: if the model is missing or
     * the check throws, the image is treated as private. Also drives the pause/resume state.
     */
    @Synchronized
    private fun isPrivate(bmp: Bitmap, now: Long = System.currentTimeMillis()): Boolean {
        if (!privacy.available) { state.privacy = state.privacy ?: "an unchecked view (privacy model missing)"; return true }
        val s = runCatching { privacy.score(bmp) }.getOrNull() ?: return true
        lastVec = s.vec
        state.privacyScore = s.priv
        when (privacy.update(s, now)) {
            PrivacyGuard.Event.ENTER, PrivacyGuard.Event.UPGRADE -> onPrivacyEnter()
            PrivacyGuard.Event.EXIT -> onPrivacyExit()
            null -> {}
        }
        // during a pause nothing leaves; outside a pause, a single frame that leans private is still not sent
        return privacy.paused || s.stop >= 0.7f || s.pin >= 0.7f
    }

    private fun onPrivacyEnter() {
        // the frames from just before the moment it was recognised are thrown away too
        val dropped = synchronized(held) { held.size.also { held.clear() } }
        liveJpeg = null
        val why = privacy.reason ?: "something private"
        val room = privacy.kind == PrivacyGuard.Kind.STOP
        runOnUiThread {
            state.privacy = why
            state.privacyPauses++
            state.privacyDropped += dropped
            state.lastFrame = if (room) "Paused · privacy ($why)" else "Not saving · $why"
            if (room && state.recording && ttsReady && state.phase != VoicePhase.Speaking)
                tts?.speak("Privacy mode. I've stopped remembering.", TextToSpeech.QUEUE_ADD, null, "privacy")
        }
    }

    private fun onPrivacyExit() {
        runOnUiThread {
            val wasRoom = state.privacy != null
            state.privacy = null
            state.lastFrame = "Privacy mode off · remembering again"
            if (wasRoom && state.recording && ttsReady && state.phase != VoicePhase.Speaking)
                tts?.speak("I'm remembering again.", TextToSpeech.QUEUE_ADD, null, "privacy")
        }
    }

    /** Frames whose wait is over leave the phone (OCR, blur, Nemotron) - only if no privacy pause started meanwhile. */
    private fun releaseHeld(now: Long) {
        while (true) {
            val h = synchronized(held) {
                if (privacy.paused) { state.privacyDropped += held.size; held.clear(); null }
                else held.firstOrNull()?.takeIf { now - it.at >= DELAY_MS }?.also { held.removeFirst() }
            } ?: return
            uploads.trySend(h)
        }
    }

    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            val provider = future.get()
            val preview = Preview.Builder().build().also { it.setSurfaceProvider(previewView.surfaceProvider) }
            val analysis = ImageAnalysis.Builder()
                .setResolutionSelector(ResolutionSelector.Builder().setResolutionStrategy(
                    ResolutionStrategy(Size(1920, 1080), ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER)).build())
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            analysis.setAnalyzer(analysisExec) { img -> onFrame(img) }
            cameraProvider = provider
            phoneUseCases = arrayOf(preview, analysis)
            if (!state.useGlasses) bindPhone()
            state.cameraReady = true
            enableTapToFocus()
        }, ContextCompat.getMainExecutor(this))
        repeat(MAX_UPLOADS) {
            lifecycleScope.launch {
                for (h in uploads) runCatching { upload(h.bmp, h.hash, h.vec) }
                    .onFailure { state.lastFrame = "Nemotron unreachable: ${it.message?.take(60)}"; state.online = false }
            }
        }
    }

    private fun bindPhone() {
        val p = cameraProvider ?: return
        p.unbindAll()
        camera = p.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, *phoneUseCases)
    }

    /** Phone camera <-> Ray-Ban Meta. Everything after the frame (selection, OCR, Nemotron, memory) is the same. */
    fun setSource(useGlasses: Boolean) {
        if (state.useGlasses == useGlasses) return
        state.useGlasses = useGlasses
        windowBest = null; windowBestScore = -1.0; windowStart = 0L; sharpHistory.clear()
        if (useGlasses) {
            cameraProvider?.unbindAll()
            glasses.connect()
        } else {
            glasses.disconnect()
            state.glassesPreview = null
            bindPhone()
        }
    }

    fun openGlassesUpdate() = glasses.openUpdate()

    private val PHONE = Regex("""\+?\d[\d\s\-().]{5,}\d""")

    /** The memory (sighting) a frame belongs to, as the detail sheet shows it. */
    private fun detailFor(frame: String, seenAt: Long, whenText: String): ShotDetail? {
        val s = engine.store.sightings().firstOrNull { sg ->
            val fr = sg.optJSONArray("frames") ?: return@firstOrNull false
            (0 until fr.length()).any { fr.optString(it) == frame }
        } ?: return null
        fun str(k: String) = if (s.has(k) && !s.isNull(k)) s.optString(k).ifEmpty { null } else null
        val name = str("name")
        val sign = listOfNotNull(name) + (str("other_text")?.split(" / ")?.map { it.trim() }?.filter { it.isNotEmpty() } ?: emptyList())
        val items = s.optJSONArray("items")
        val rows = (0 until (items?.length() ?: 0)).mapNotNull { i -> items!!.optJSONObject(i) }
            .map { it.optString("label") to it.optString("value") }
        val objs = s.optJSONArray("objects")
        val things = (0 until (objs?.length() ?: 0)).mapNotNull { i -> objs!!.optJSONObject(i) }
            .filter { !it.optBoolean("uncertain") }
            .map { o -> o.optString("name") + (if (o.optInt("count", 1) > 1) " ×${o.optInt("count")}" else "") }
        // a number to call: the verified phone field, else a phone-like number read on the sign
        val phone = str("phone") ?: (sign + rows.map { it.second } + rows.map { it.first }).firstNotNullOfOrNull { line ->
            PHONE.findAll(line).map { it.value.trim() }.firstOrNull { v -> v.count { it.isDigit() } in 7..15 }
        }
        val kind = str("subtype") ?: str("kind")
        val stamp = java.text.SimpleDateFormat("EEE d MMM, HH:mm", java.util.Locale.US).format(java.util.Date(seenAt))
        return ShotDetail(
            title = name ?: kind?.replaceFirstChar { it.uppercase() } ?: "What I saw",
            kind = kind, whenFull = if (whenText.startsWith("Today")) stamp else "$stamp · $whenText", signLines = sign, rows = rows,
            phone = phone, hours = str("hours"), caption = str("caption"), things = things)
    }

    /** Opens the dialer with the number filled in; the user presses call (nothing is dialled automatically). */
    fun dial(phone: String) {
        val digits = phone.filter { it.isDigit() || it == '+' }
        runCatching { startActivity(Intent(Intent.ACTION_DIAL, android.net.Uri.parse("tel:$digits"))) }
            .onFailure { state.toast("No phone app found.") }
    }

    fun copyText(text: String) {
        val cm = getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager
        cm.setPrimaryClip(android.content.ClipData.newPlainText("MUISTI", text))
        state.toast("Copied")
    }

    /** Recent memories for the gallery: newest first, one card per memory (its best frame). */
    fun openGallery() {
        state.showGallery = true
        state.gallery = null
        lifecycleScope.launch {
            state.gallery = withContext(Dispatchers.IO) {
                val now = System.currentTimeMillis()
                engine.store.sightings().sortedByDescending { it.optLong("seen_at") }.take(40).mapNotNull { s ->
                    val frame = s.optString("evidence_frame").ifEmpty { null } ?: return@mapNotNull null
                    val file = engine.frameFile(frame)
                    if (!file.exists()) return@mapNotNull null
                    val img = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = 2 })?.asImageBitmap()
                        ?: return@mapNotNull null
                    val seen = s.optLong("seen_at")
                    val mins = ((now - seen) / 60000).toInt()
                    val whenText = when {
                        mins < 2 -> "Just now"
                        mins < 60 -> "$mins min ago"
                        else -> "Today " + java.text.SimpleDateFormat("HH:mm", java.util.Locale.US).format(java.util.Date(seen))
                    }
                    val lat = if (s.has("lat") && !s.isNull("lat")) s.getDouble("lat") else null
                    val lon = if (s.has("lon") && !s.isNull("lon")) s.getDouble("lon") else null
                    val street = if (s.has("street") && !s.isNull("street")) s.optString("street") else null
                    val place = street ?: lat?.let { "%.4f, %.4f".format(it, lon) }
                    val uri = lat?.let { "geo:$it,$lon?q=$it,$lon(${android.net.Uri.encode(street ?: "Seen here")})" }
                    Shot(img, whenText, place, uri, null, detailFor(frame, seen, whenText))
                }
            }
        }
    }

    // ---------------- Agent Center ----------------

    /** Calendar events starting in the next 45 minutes (needs READ_CALENDAR; empty without it). */
    private fun upcomingEvents(): List<com.muisti.engine.CalEvent> {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CALENDAR) != PackageManager.PERMISSION_GRANTED) return emptyList()
        val now = System.currentTimeMillis()
        val uri = android.provider.CalendarContract.Instances.CONTENT_URI.buildUpon().also {
            android.content.ContentUris.appendId(it, now); android.content.ContentUris.appendId(it, now + 45 * 60_000L) }.build()
        val proj = arrayOf(android.provider.CalendarContract.Instances.EVENT_ID, android.provider.CalendarContract.Instances.TITLE,
            android.provider.CalendarContract.Instances.BEGIN, android.provider.CalendarContract.Instances.EVENT_LOCATION)
        val out = ArrayList<com.muisti.engine.CalEvent>()
        runCatching { contentResolver.query(uri, proj, null, null, null)?.use { c ->
            while (c.moveToNext()) out.add(com.muisti.engine.CalEvent(c.getLong(0), c.getString(1) ?: "", c.getLong(2), c.getString(3)))
        } }
        return out
    }

    /** An alert: Android notification, plus spoken when the voice conversation is open and quiet. */
    private fun deliver(n: com.muisti.engine.Notice) {
        android.util.Log.i("MuistiAgent", "notice alert: ${n.type} '${n.title}'")
        val nm = getSystemService(android.app.NotificationManager::class.java) ?: return
        nm.createNotificationChannel(android.app.NotificationChannel("notices", "MUISTI notices", android.app.NotificationManager.IMPORTANCE_DEFAULT))
        val open = android.app.PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).putExtra("open_agent", true),
            android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT)
        val note = android.app.Notification.Builder(this, "notices").setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(n.title).setContentText(n.body).setStyle(android.app.Notification.BigTextStyle().bigText(n.body))
            .setContentIntent(open).setAutoCancel(true).build()
        if (android.os.Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)
            nm.notify(n.id.hashCode(), note)
        runOnUiThread {
            state.unreadNotices++
            if (state.live && ttsReady && state.phase == VoicePhase.Listening) tts?.speak("${n.title}. ${n.body}", TextToSpeech.QUEUE_ADD, null, "notice")
        }
    }

    fun openAgentCenter() {
        state.unreadNotices = 0
        val labels = com.muisti.engine.Notice.LABELS.filterKeys { it != com.muisti.engine.Notice.PATTERN }
        state.agentCenter = com.muisti.ui.AgentCenterState(null, engine.mutedNotices, labels)
        lifecycleScope.launch {
            val f = java.text.SimpleDateFormat("EEE HH:mm", Locale.US)
            val rows = withContext(Dispatchers.IO) { engine.notices.all().reversed().take(100).map { (n, d) ->
                com.muisti.ui.NoticeRow(n.id, n.type, n.title, n.body, f.format(java.util.Date(n.createdAt)),
                    if (d == com.muisti.engine.Delivery.ALERT) "Alerted" else "Inbox only", n.evidence) } }
            state.agentCenter?.let { state.agentCenter = it.copy(rows = rows) }
        }
    }

    val agentActions = object : com.muisti.ui.AgentCenterActions {
        override fun mute(type: String, muted: Boolean) {
            engine.mutedNotices = if (muted) engine.mutedNotices + type else engine.mutedNotices - type
            state.agentCenter?.let { state.agentCenter = it.copy(muted = engine.mutedNotices) }
        }
        override fun openFrame(frame: String) = timelineActions.openFrame(frame)
        override fun close() { state.agentCenter = null }
    }

    // ---------------- timeline (episodes by day) ----------------
    private var timelineOffset = 0
    private val thumbCache = android.util.LruCache<String, androidx.compose.ui.graphics.ImageBitmap>(160)

    /** Opens / moves the timeline: [delta] days from the shown day (0 = today when opening). */
    fun openTimeline(delta: Int) {
        timelineOffset = if (state.timeline == null) 0 else minOf(0, timelineOffset + delta)
        val off = timelineOffset
        val cal = java.util.Calendar.getInstance().apply {
            set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0); set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
            add(java.util.Calendar.DAY_OF_YEAR, off)
        }
        val from = cal.timeInMillis; val to = from + 24 * 3600_000L
        val title = when (off) { 0 -> "Today"; -1 -> "Yesterday"; else -> java.text.SimpleDateFormat("EEE d MMM", Locale.US).format(java.util.Date(from)) }
        state.timeline = com.muisti.ui.TimelineDay(title, off < 0, null)
        lifecycleScope.launch {
            val cards = runCatching { withContext(Dispatchers.IO) {
                val f = java.text.SimpleDateFormat("HH:mm", Locale.US)
                engine.episodes().filter { it.start in from until to }.sortedByDescending { it.start }.map { e ->
                    val span = if (e.end - e.start < 60_000) f.format(java.util.Date(e.start)) else "${f.format(java.util.Date(e.start))}–${f.format(java.util.Date(e.end))}"
                    com.muisti.ui.EpisodeCard(e.id, span, e.place, engine.summaries[e.id],
                        com.muisti.engine.Episodes.headline(e).substringAfter("): "), e.members.size, e.keyFrames)
                }
            } }
            if (timelineOffset == off && state.timeline != null)
                state.timeline = com.muisti.ui.TimelineDay(title, off < 0, cards.getOrNull(), cards.exceptionOrNull()?.let { "Couldn't load: ${it.message?.take(60)}" })
        }
    }

    val timelineActions = object : com.muisti.ui.TimelineActions {
        override fun day(delta: Int) = openTimeline(delta)
        override suspend fun thumb(frame: String) = thumbCache.get(frame) ?: withContext(Dispatchers.IO) {
            engine.frameFile(frame).takeIf { it.exists() }?.let { BitmapFactory.decodeFile(it.path, BitmapFactory.Options().apply { inSampleSize = 4 }) }
                ?.asImageBitmap()?.also { thumbCache.put(frame, it) }
        }
        override fun openFrame(frame: String) {
            lifecycleScope.launch {
                val shot = withContext(Dispatchers.IO) {
                    val file = engine.frameFile(frame).takeIf { it.exists() } ?: return@withContext null
                    val s = engine.store.sightings().firstOrNull { sg -> sg.optJSONArray("frames")?.let { a -> (0 until a.length()).any { a.optString(it) == frame } } == true }
                    val seen = s?.optLong("seen_at") ?: file.lastModified()
                    val whenText = java.text.SimpleDateFormat("EEE d MMM, HH:mm", Locale.US).format(java.util.Date(seen))
                    val img = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = 2 })?.asImageBitmap() ?: return@withContext null
                    Shot(img, whenText, s?.optString("street")?.ifEmpty { null }, null, BitmapFactory.decodeFile(file.path)?.asImageBitmap(), detailFor(frame, seen, whenText))
                }
                if (shot != null) state.openShot = shot else state.toast("That frame is no longer stored.")
            }
        }
        override fun gallery() { openGallery() }
        override fun close() { state.timeline = null }
    }

    /** "Ask about this" from the detail sheet. */
    fun askAbout(shot: Shot) {
        state.openShot = null
        state.showGallery = false
        val name = shot.detail?.title ?: "this"
        ask("Tell me more about what I saw at $name", spoken = false)
    }

    fun translate(text: String) {
        if (state.translations.containsKey(text)) return
        state.translations[text] = "…"
        lifecycleScope.launch {
            state.translations[text] = runCatching { withContext(Dispatchers.IO) { engine.translate(text) } }
                .getOrElse { "Couldn't translate right now." }
        }
    }

    fun openMap(uri: String) {
        runCatching { startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(uri))) }
            .onFailure { state.toast("No maps app found.") }
    }

    /** The live frame for "what am I looking at?": heads and plates masked like a stored frame; null = not sent. */
    private suspend fun blurJpeg(jpeg: ByteArray): ByteArray? {
        val bmp = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) ?: return null
        val plates = plateFilter(bmp, withContext(Dispatchers.Main) { readText(bmp) }).second
        val safe = blurrer.process(bmp, plates) ?: return null
        return ByteArrayOutputStream().also { safe.image.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
    }

    /** Back from Meta AI (e.g. after updating): try again. */
    fun retryGlasses() { if (state.useGlasses) { glasses.disconnect(); glasses.connect() } }

    fun toggleRecording() {
        state.recording = !state.recording
        if (state.recording) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED) {
                location.start(); state.hasLocation = true
            } else locationPermission.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
            motion.start()
        } else { location.stop(); motion.stop(); state.capturePause = null }
        windowBest = null; windowBestScore = -1.0; windowStart = 0L
    }

    /** Runs on the analysis thread for every camera frame. */
    private fun onFrame(img: ImageProxy) {
        try {
            val now = System.currentTimeMillis()
            if (now - secondStart >= 1000) { state.fps = framesThisSecond; framesThisSecond = 0; secondStart = now }
            framesThisSecond++
            considerFrame(now, { lumaSharpness(img) }, { upright(img) })
        } finally {
            img.close()
        }
    }

    /**
     * No-record zones, checked FIRST for every frame (before OCR, the privacy model and the network):
     * the latest fix inside a zone, or the geofence saying so, means nothing is captured.
     */
    private fun zoneNow(): com.muisti.privacy.Zone? {
        val zones = privacySettings.current.zones
        if (zones.isEmpty()) return null
        val fix = location.fresh(60_000)
        return fix?.let { com.muisti.privacy.Zones.inside(it.lat, it.lon, it.accuracyM, zones) }
            ?: ZoneGeofences.insideId?.let { id -> zones.firstOrNull { it.id == id } }
    }
    private var lastZoneCheck = 0L
    @Volatile private var inZone: com.muisti.privacy.Zone? = null

    /** Same for every source: live frame ~2x/s, and while recording the sharpest frame of each window. */
    private fun considerFrame(now: Long, score: () -> Double, bitmap: () -> Bitmap) {
        if (now - lastZoneCheck >= 500) {
            lastZoneCheck = now
            val z = zoneNow()
            if (z?.id != inZone?.id) {
                android.util.Log.i("MuistiPrivacy", if (z != null) "no-record zone: entered ${z.name}" else "no-record zone: left")
                runOnUiThread { state.zone = z?.name; if (z != null) state.lastFrame = "No-record zone · ${z.name}" else if (state.recording) state.lastFrame = "Left the no-record zone" }
            }
            inZone = z
        }
        if (inZone != null) {                    // nothing from here on: no live frame, no window, no queue
            liveJpeg = null; windowBest = null; windowBestScore = -1.0; windowStart = 0L
            synchronized(held) { held.clear() }
            return
        }
        if (now - lastLiveAt >= 500) {
            lastLiveAt = now
            val b = bitmap()
            // not recording: this tick is what keeps the pause state current (while recording, offerFrame does it).
            // The live frame is checked again, on its own, when a question actually wants to send it.
            val priv = if (!state.recording) isPrivate(b, now) else privacy.paused
            liveJpeg = if (priv) null
                else ByteArrayOutputStream().also { b.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
        }
        releaseHeld(now)
        if (!state.recording) return
        val d = currentDecision(now)
        if (d.paused) { windowBest = null; windowBestScore = -1.0; windowStart = 0L; return }
        if (windowStart == 0L) windowStart = now
        val sc = score()
        if (sc > windowBestScore) {            // only the window's new best is turned into a bitmap
            windowBestScore = sc
            windowBest = bitmap()
        }
        if (now - windowStart >= d.intervalMs) {
            val best = windowBest
            val s = windowBestScore
            windowBest = null; windowBestScore = -1.0; windowStart = now
            if (best != null) offerFrame(best, s)
        }
    }

    /**
     * Raw glasses frame: I420 (Y plane, then U, then V), as the SDK's decoder is configured
     * (MediaCodec color-format 19). Sharpness is read straight off the Y plane.
     */
    private fun onGlassesFrame(f: com.meta.wearable.dat.camera.types.VideoFrame) {
        if (!state.useGlasses) return
        if (f.isCompressed) { state.glassesStatus = "Compressed frames arrived; expected raw"; return }
        val w = f.width; val h = f.height
        val buf = f.buffer.duplicate()
        val n = buf.remaining()
        if (!glassesFormatLogged) {
            glassesFormatLogged = true
            android.util.Log.i("MuistiGlasses", "first frame ${w}x$h, $n bytes (I420 would be ${w * h * 3 / 2})")
        }
        if (n < w * h * 3 / 2) return
        val data = ByteArray(w * h * 3 / 2)
        buf.get(data)
        val now = System.currentTimeMillis()
        if (now - secondStart >= 1000) { state.fps = framesThisSecond; framesThisSecond = 0; secondStart = now }
        framesThisSecond++
        // preview: half resolution, converted directly (a few ms) - ~15 fps
        if (now - lastPreviewAt >= 60) {
            lastPreviewAt = now
            state.glassesPreview = i420ToBitmap(data, w, h, step = 2).asImageBitmap()
        }
        // everything heavy (full-size bitmap, privacy model, OCR queue) runs on its own thread;
        // frames that arrive while it is busy are simply not considered, so the stream never waits
        if (glassesBusy) return
        glassesBusy = true
        glassesExec.execute {
            try {
                var cached: Bitmap? = null
                val toBitmap = { cached ?: i420ToBitmap(data, w, h).also { cached = it } }
                considerFrame(now, { yPlaneSharpness(data, w, h) }, toBitmap)
            } catch (e: Exception) {
                android.util.Log.w("MuistiGlasses", "frame processing failed", e)
            } finally { glassesBusy = false }
        }
    }
    private val glassesExec = Executors.newSingleThreadExecutor()
    @Volatile private var glassesBusy = false

    private fun yPlaneSharpness(y: ByteArray, w: Int, h: Int): Double {
        val step = 3
        var sum = 0.0; var sum2 = 0.0; var n = 0
        var yy = step
        while (yy < h - step) {
            var x = step
            while (x < w - step) {
                val i = yy * w + x
                val lap = (4 * (y[i].toInt() and 255) - (y[i - step].toInt() and 255) - (y[i + step].toInt() and 255) -
                    (y[i - step * w].toInt() and 255) - (y[i + step * w].toInt() and 255)).toDouble()
                sum += lap; sum2 += lap * lap; n++
                x += step * 2
            }
            yy += step * 2
        }
        if (n == 0) return 0.0
        val mean = sum / n
        return sum2 / n - mean * mean
    }

    /** I420 -> NV21 -> JPEG -> Bitmap (YuvImage only takes NV21). */
    /** I420 -> ARGB directly (BT.601), every [step]-th pixel. No JPEG round trip. */
    private fun i420ToBitmap(i420: ByteArray, w: Int, h: Int, step: Int = 1): Bitmap {
        val ow = w / step; val oh = h / step
        val px = IntArray(ow * oh)
        val ySize = w * h
        val cw = w / 2
        val uOff = ySize; val vOff = ySize + ySize / 4
        var o = 0
        for (oy in 0 until oh) {
            val y = oy * step
            val yRow = y * w
            val cRow = (y / 2) * cw
            for (ox in 0 until ow) {
                val x = ox * step
                val yy = ((i420[yRow + x].toInt() and 255) - 16).coerceAtLeast(0) * 1192
                val ci = cRow + x / 2
                val u = (i420[uOff + ci].toInt() and 255) - 128
                val v = (i420[vOff + ci].toInt() and 255) - 128
                val r = ((yy + 1634 * v) shr 10).coerceIn(0, 255)
                val g = ((yy - 833 * v - 400 * u) shr 10).coerceIn(0, 255)
                val b = ((yy + 2066 * u) shr 10).coerceIn(0, 255)
                px[o++] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
            }
        }
        return Bitmap.createBitmap(px, ow, oh, Bitmap.Config.ARGB_8888)
    }

    private fun offerFrame(bmp: Bitmap, score: Double) {
        // every frame that could be remembered is checked itself, on the phone, before anything else
        if (isPrivate(bmp)) { state.privacyDropped++; return }   // private: not kept, not sent
        val vec = lastVec
        if (isBlurry(score)) { state.blurrySkipped++; state.lastFrame = "Skipped · blurry"; return }
        val h = dHash(bmp)
        if (lastSentHash != -1L && java.lang.Long.bitCount(h xor lastSentHash) <= 6) {
            state.sameSkipped++; return                     // same view as the last frame sent
        }
        if (lastSentHash != -1L) scheduler.onKept(java.lang.Long.bitCount(h xor lastSentHash))
        lastSentHash = h
        synchronized(held) { held.addLast(Held(bmp, h, System.currentTimeMillis(), vec)); while (held.size > 12) held.removeFirst() }
    }

    /** Variance of a 4-neighbour Laplacian on the Y (grey) plane, sampled on a sparse grid. ~1 ms per frame. */
    private fun lumaSharpness(img: ImageProxy): Double {
        val plane = img.planes[0]
        val buf = plane.buffer
        val rs = plane.rowStride
        val ps = plane.pixelStride
        val w = img.width
        val h = img.height
        val step = 3
        var sum = 0.0
        var sum2 = 0.0
        var n = 0
        var y = step
        while (y < h - step) {
            var x = step
            while (x < w - step) {
                val c = buf.get(y * rs + x * ps).toInt() and 255
                val l = buf.get(y * rs + (x - step) * ps).toInt() and 255
                val r = buf.get(y * rs + (x + step) * ps).toInt() and 255
                val u = buf.get((y - step) * rs + x * ps).toInt() and 255
                val d = buf.get((y + step) * rs + x * ps).toInt() and 255
                val lap = (4 * c - l - r - u - d).toDouble()
                sum += lap; sum2 += lap * lap; n++
                x += step * 2
            }
            y += step * 2
        }
        if (n == 0) return 0.0
        val mean = sum / n
        return sum2 / n - mean * mean
    }

    /** 64-bit difference hash: near-identical views differ in only a few bits. */
    private fun dHash(bmp: Bitmap): Long {
        val small = Bitmap.createScaledBitmap(bmp, 9, 8, true)
        var hash = 0L
        for (y in 0 until 8) for (x in 0 until 8) {
            val a = small.getPixel(x, y)
            val b = small.getPixel(x + 1, y)
            val ga = (a shr 16 and 255) + (a shr 8 and 255) + (a and 255)
            val gb = (b shr 16 and 255) + (b shr 8 and 255) + (b and 255)
            hash = (hash shl 1) or (if (ga > gb) 1L else 0L)
        }
        return hash
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun enableTapToFocus() {
        previewView.setOnTouchListener { v, e ->
            if (e.action == MotionEvent.ACTION_UP) {
                val point = previewView.meteringPointFactory.createPoint(e.x, e.y)
                camera?.cameraControl?.startFocusAndMetering(
                    FocusMeteringAction.Builder(point, FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE)
                        .setAutoCancelDuration(5, TimeUnit.SECONDS).build())
                state.focusX = e.x; state.focusY = e.y; state.focusTick++
                v.performClick()
            }
            true
        }
    }

    /** Same rule as process_video.py: blurry = under half the median of recent windows. */
    private fun isBlurry(s: Double): Boolean {
        val median = sharpHistory.sorted().let { if (it.isEmpty()) 0.0 else it[it.size / 2] }
        sharpHistory.addLast(s)
        if (sharpHistory.size > 20) sharpHistory.removeFirst()
        return sharpHistory.size >= 4 && s < 0.5 * median
    }

    private suspend fun upload(bmp: Bitmap, dhash: Long, vec: FloatArray? = null) {
        val seenAt = System.currentTimeMillis()
        val fix = location.fresh()
        val ocr = readText(bmp)                  // text is read from the raw frame, on the phone
        val (obs, plates) = plateFilter(bmp, ocr)
        if (privacy.paused) { state.privacyDropped++; return }
        // privacy: card numbers, IBAN, ID numbers, PIN/password screens never leave the phone
        PrivacyText.check(ocr.obs.map { it.text }, privacy.lastHint)?.let { why ->
            state.privacyDropped++
            if (privacy.textHit(why, System.currentTimeMillis()) != null) onPrivacyEnter()
            return
        }
        // privacy: heads are masked BEFORE the frame goes to Nemotron or into memory; on failure drop it
        val safe = withContext(Dispatchers.Default) { blurrer.process(bmp, plates) }
        if (safe == null) { state.lastFrame = "Skipped · privacy check failed"; return }
        state.facesBlurred += safe.faceCount
        val jpeg = withContext(Dispatchers.Default) { ByteArrayOutputStream().also { safe.image.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray() }
        // offline (or Nemotron unreachable after its retries): the redacted frame waits on disk, nothing is lost
        fun queue(): Unit {
            engine.pending.add(com.muisti.capture.PendingFrame(java.util.UUID.randomUUID().toString().take(8), jpeg, obs, seenAt, dhash, fix?.lat, fix?.lon, fix?.street, vec))
            state.queued = engine.pending.size(); state.lastFrame = "Offline · frame queued (${state.queued})"
        }
        if (!state.network) { withContext(Dispatchers.IO) { queue() }; return }
        val stored = try {
            withContext(Dispatchers.IO) { engine.ingest(jpeg, obs, seenAt, dhash, fix, vec) }
        } catch (e: Exception) {
            if (e is com.muisti.engine.Unreachable || e is java.io.IOException) { withContext(Dispatchers.IO) { queue() }; return }
            throw e
        }
        state.online = true
        state.framesSent++
        // safety: the new memory is checked at once (stored text, no model call unless a rule matches)
        if (stored) lifecycleScope.launch(Dispatchers.IO) { runCatching { engine.checkSafety(System.currentTimeMillis()) }.getOrNull()?.forEach { deliver(it) } }
        state.lastFrame = if (stored) {
            state.memories = withContext(Dispatchers.IO) { engine.store.sightings().size }
            "Remembered · ${obs.size} text line${if (obs.size == 1) "" else "s"}"
        } else "Skipped · nothing worth keeping"
    }

    /** Rotated the way the user saw it; long side at most 1536 px (the server downscales to that anyway). */
    private fun upright(image: ImageProxy): Bitmap {
        var bmp = image.toBitmap()
        val rot = image.imageInfo.rotationDegrees
        if (rot != 0) {
            bmp = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, Matrix().apply { postRotate(rot.toFloat()) }, true)
        }
        val longSide = maxOf(bmp.width, bmp.height)
        if (longSide > 1536) {
            val s = 1536f / longSide
            bmp = Bitmap.createScaledBitmap(bmp, (bmp.width * s).toInt(), (bmp.height * s).toInt(), true)
        }
        return bmp
    }

    /** ML Kit lines -> the same observation shape Apple Vision produces on iOS. */
    /** The phone's OCR of one frame: lines for Nemotron (obs) and the same lines as boxes with their block size (plates). */
    class Ocr(val obs: List<Obs>, val boxes: List<com.muisti.privacy.TextBox>)

    private suspend fun readText(bmp: Bitmap): Ocr = suspendCancellableCoroutine { cont ->
        recognizer.process(InputImage.fromBitmap(bmp, 0))
            .addOnSuccessListener { text ->
                val w = bmp.width.toDouble(); val h = bmp.height.toDouble()
                val obs = ArrayList<Obs>(); val boxes = ArrayList<com.muisti.privacy.TextBox>()
                for (block in text.textBlocks) for (line in block.lines) {
                    val r = line.boundingBox ?: continue
                    obs.add(Obs(line.text, (line.confidence.takeIf { it > 0f } ?: 1f).toDouble(),
                        r.left / w, r.top / h, r.width() / w, r.height() / h))
                    boxes.add(com.muisti.privacy.TextBox(line.text, r.left / w, r.top / h, r.width() / w, r.height() / h, block.lines.size))
                }
                if (cont.isActive) cont.resume(Ocr(obs, boxes))
            }
            .addOnFailureListener { if (cont.isActive) cont.resume(Ocr(emptyList(), emptyList())) }
    }

    /**
     * Licence plates (setting "Blur licence plates"): their boxes are masked by the redactor (padded 25 %, as on iOS)
     * and their text is removed from the OCR lines, so neither the picture nor the text of a plate leaves the phone.
     */
    private fun plateFilter(bmp: Bitmap, ocr: Ocr): Pair<List<Obs>, List<android.graphics.RectF>> {
        if (!privacySettings.current.plateBlur) return ocr.obs to emptyList()
        val plates = com.muisti.privacy.PlateDetector.find(ocr.boxes, bmp.width, bmp.height).toSet()
        if (plates.isEmpty()) return ocr.obs to emptyList()
        val w = bmp.width.toFloat(); val h = bmp.height.toFloat()
        val rects = plates.map { b ->
            android.graphics.RectF((b.x * w).toFloat(), (b.y * h).toFloat(), ((b.x + b.w) * w).toFloat(), ((b.y + b.h) * h).toFloat())
                .apply { inset(-width() * 0.25f, -height() * 0.25f) }
        }
        android.util.Log.i("MuistiPrivacy", "plates masked: ${plates.size}")
        return ocr.obs.filterIndexed { i, _ -> ocr.boxes[i] !in plates } to rects
    }

    private fun pollStats() {
        statsJob?.cancel()
        statsJob = lifecycleScope.launch {
            state.online = engine.canCall
            while (isActive) {
                runCatching { state.memories = withContext(Dispatchers.IO) { engine.store.sightings().size } }
                if (location.running) location.fresh(60_000)?.street?.let { state.street = it }
                android.util.Log.i("MuistiRate", "Nemotron requests in the last minute: ${com.muisti.engine.Llm.perMinute()}, " +
                    "peak concurrent ${com.muisti.engine.Llm.peakConcurrent()}, queued ${state.queued}, network ${state.network}, " +
                    "capture ${if (decision.paused) "paused (${decision.reason})" else "${decision.reason} ${decision.intervalMs} ms"} " +
                    "(recording=${state.recording}, source=${if (state.useGlasses) "glasses" else "phone"}, sent frames=${state.framesSent})")
                delay(6000)
            }
        }
    }

    // ---------------- assistant ----------------

    /** The agent's open proposal (zone, deletion...), confirmed by tap or by a spoken yes/no. */
    private var pendingAction: com.muisti.engine.PendingAction? = null

    private fun setCardStatus(id: String, status: String) {
        val i = state.messages.indexOfFirst { (it as? Msg.Answer)?.confirm?.id == id }
        if (i >= 0) (state.messages[i] as Msg.Answer).let { a -> state.messages[i] = a.copy(confirm = a.confirm!!.copy(status = status)) }
    }

    fun resolve(id: String, yes: Boolean, spoken: Boolean) {
        val p = pendingAction?.takeIf { it.id == id } ?: return
        pendingAction = null
        setCardStatus(id, if (yes) "done" else "cancelled")
        lifecycleScope.launch {
            val say = if (!yes) "Okay, I won't." else runCatching { withContext(Dispatchers.IO) { engine.execute(p.action) } }
                .getOrElse { "That didn't work: ${it.message?.take(60)}" }
            state.memories = withContext(Dispatchers.IO) { engine.store.sightings().size }
            state.messages.add(Msg.Answer(label = if (yes) "CHAT" else "CHAT", text = say))
            if (spoken && ttsReady && state.live) speakHuman(say, TextToSpeech.QUEUE_FLUSH) else if (spoken) afterTurn()
        }
    }

    fun ask(question: String, spoken: Boolean, heard: List<String> = emptyList(), lang: String = "en") {
        val q = question.trim()
        if (q.isEmpty()) return
        // a spoken (or typed) yes/no to the open proposal; anything else drops the proposal and is asked normally
        pendingAction?.let { p ->
            val yes = com.muisti.engine.Confirmations.answer(q)
            if (yes != null) { state.messages.add(Msg.Question(q)); resolve(p.id, yes, spoken); return }
            pendingAction = null; setCardStatus(p.id, "expired")
        }
        tts?.stop()
        state.messages.add(Msg.Question(q))
        val pending = Msg.Answer(label = "", text = "", pending = true)
        state.messages.add(pending)
        state.phase = if (spoken) VoicePhase.Thinking else VoicePhase.Idle
        // feels like a person listening: a soft "got it" tick
        if (spoken) runCatching { earcon?.startTone(android.media.ToneGenerator.TONE_PROP_BEEP, 70) }
        // no spoken filler ("One sec…"): it got repetitive; the tick + the thinking animation are enough
        val filler: Job? = if (false) lifecycleScope.launch {
            delay(1300)
            var i: Int
            do { i = fillers.indices.random() } while (i == lastFiller)
            lastFiller = i
            tts?.speak(fillers[i], TextToSpeech.QUEUE_FLUSH, null, "filler")
        } else null
        lifecycleScope.launch {
            val answer = runCatching {
                // the live frame for "what am I seeing?" is masked too; if masking fails it is not sent
                // the live frame is checked on the phone right now; a private view is never sent with a question
                val live = withContext(Dispatchers.Default) {
                    liveJpeg?.let { j -> BitmapFactory.decodeByteArray(j, 0, j.size)?.takeIf { !isPrivate(it) }?.let { blurJpeg(j) } }
                }
                // never leave the user waiting: 45 s, then a clear error (the HTTP call is interrupted)
                val fix = location.fresh(60_000)
                // Turkish: translate the question for the English agent, and its answer back (both on Nemotron)
                val qAgent = if (lang == "tr") withContext(Dispatchers.IO) { engine.translateTo(q, "English") } else q
                val r0 = kotlinx.coroutines.withTimeout(45_000) { kotlinx.coroutines.runInterruptible(Dispatchers.IO) { engine.ask(qAgent, live, heard, fix) } }
                val r = r0
                val answerText = if (lang == "tr") withContext(Dispatchers.IO) { engine.translateTo(r0.answer, "Turkish") } else r0.answer
                if (r.label == "FORGOT") state.memories = withContext(Dispatchers.IO) { engine.store.sightings().size }
                val shots = withContext(Dispatchers.IO) { loadShots(r) }
                val used = r.evidence.filter { it.id in r.used }.ifEmpty { r.evidence.take(1) }
                val where = used.firstOrNull { it.lat != null }
                val confirm = r.parsed.optJSONObject("pending")?.takeIf { r.label == com.muisti.engine.PendingAction.LABEL }?.let { j ->
                    val p = com.muisti.engine.PendingAction.fromJson(j)
                    pendingAction = p
                    val thumbs = withContext(Dispatchers.IO) { p.frames.take(8).mapNotNull { f -> engine.frameFile(f).takeIf { it.exists() }
                        ?.let { BitmapFactory.decodeFile(it.path, BitmapFactory.Options().apply { inSampleSize = 4 })?.asImageBitmap() } } }
                    ConfirmCard(p.id, p.count, thumbs)
                }
                Msg.Answer(label = r.label, text = answerText, shots = if (confirm != null) emptyList() else shots, confirm = confirm,
                    place = where?.let { it.street ?: "%.5f, %.5f".format(it.lat, it.lon) }.takeIf { r.label == "SEEN" || r.label == "UNSURE" },
                    mapUri = where?.let { "geo:${it.lat},${it.lon}?q=${it.lat},${it.lon}(${android.net.Uri.encode(it.street ?: "Seen here")})" }
                        .takeIf { r.label == "SEEN" || r.label == "UNSURE" })
            }.getOrElse {
                val msg = if (it is kotlinx.coroutines.TimeoutCancellationException) "That took too long, so I stopped. Please ask again."
                    else "I couldn't reach Nemotron (${it.message?.take(80)})."
                Msg.Answer(label = "ERROR", text = msg)
            }
            filler?.cancel()
            val i = state.messages.indexOf(pending)
            if (i >= 0) state.messages[i] = answer else state.messages.add(answer)
            if (spoken && ttsReady && state.live) {
                // QUEUE_ADD: if the filler is mid-sentence, the answer follows it instead of cutting it off
                speakHuman(answer.text, TextToSpeech.QUEUE_ADD, lang)
            } else if (spoken) afterTurn()
        }
    }

    /** Evidence frames for the answer card: image + when + where (with a Maps link). */
    private fun loadShots(r: com.muisti.engine.Answer): List<Shot> {
        if (r.label != "SEEN" && r.label != "UNSURE") return emptyList()
        val used = r.used.toSet()
        val now = System.currentTimeMillis()
        return r.evidence.sortedByDescending { it.id in used }.filter { it.frame != null }.distinctBy { it.frame }.take(4).mapNotNull { e ->
            runCatching {
                val file = engine.frameFile(e.frame!!)
                if (!file.exists()) return@runCatching null
                val img = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = 2 })?.asImageBitmap() ?: return@runCatching null
                val mins = ((now - e.seenAt) / 60000).toInt()
                val whenText = when {
                    mins < 2 -> "Just now"
                    mins < 60 -> "$mins min ago"
                    else -> "Today " + java.text.SimpleDateFormat("HH:mm", java.util.Locale.US).format(java.util.Date(e.seenAt))
                }
                val place = e.street ?: e.lat?.let { "%.4f, %.4f".format(it, e.lon) }
                val uri = e.lat?.let { "geo:${it},${e.lon}?q=${it},${e.lon}(${android.net.Uri.encode(e.street ?: "Seen here")})" }
                val full = BitmapFactory.decodeFile(file.path)?.asImageBitmap()
                Shot(img, whenText, place, uri, full, detailFor(e.frame, e.seenAt, whenText))
            }.getOrNull()
        }
    }

    /** Opens the live conversation: listen -> answer -> listen again, until the user ends it. */
    fun startListening() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            permissions.launch(arrayOf(Manifest.permission.RECORD_AUDIO)); return
        }
        if (!SpeechRecognizer.isRecognitionAvailable(this)) { state.toast("Speech recognition isn't available on this phone."); return }
        state.live = true
        engine.warm()
        listen()
    }

    /** Tap on the orb while it is talking: stop talking and listen (barge-in). */
    fun interrupt() {
        if (!state.live) return
        if (state.phase == VoicePhase.Speaking) { tts?.stop(); listen() }
    }

    /** After an answer was spoken (or could not be): keep the conversation going. */
    private fun afterTurn() {
        if (state.live) listen() else state.phase = VoicePhase.Idle
    }

    private fun listen() {
        if (!state.live) return
        tts?.stop()
        if (speech == null) {
            speech = SpeechRecognizer.createSpeechRecognizer(this).apply { setRecognitionListener(listener) }
        } else speech?.cancel()
        state.partial = ""
        detectedLang = null
        state.phase = VoicePhase.Listening
        speech?.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, if (state.voiceLang == "tr") "tr-TR" else "en-US")
            if (state.voiceLang == "auto" && android.os.Build.VERSION.SDK_INT >= 34) {
                // let the recognizer notice Turkish and switch its model to it mid-sentence
                val langs = arrayListOf("en-US", "tr-TR")
                putExtra(RecognizerIntent.EXTRA_ENABLE_LANGUAGE_DETECTION, true)
                putStringArrayListExtra(RecognizerIntent.EXTRA_LANGUAGE_DETECTION_ALLOWED_LANGUAGES, langs)
                putExtra(RecognizerIntent.EXTRA_ENABLE_LANGUAGE_SWITCH, RecognizerIntent.LANGUAGE_SWITCH_BALANCED)
                putStringArrayListExtra(RecognizerIntent.EXTRA_LANGUAGE_SWITCH_ALLOWED_LANGUAGES, langs)
            }
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5)      // alternatives go to Nemotron, which picks the sensible one
            if (android.os.Build.VERSION.SDK_INT >= 33)           // nudge the recognizer toward what people say to MUISTI
                putStringArrayListExtra(RecognizerIntent.EXTRA_BIASING_STRINGS, arrayListOf("note it", "note that", "remember this",
                    "MUISTI", "add it to my calendar", "forget the last", "what did the sign say", "where did I see", "translate it",
                    "what am I looking at", "read this"))
            // quick turn-taking: ~1 s of silence ends the question (1.5 s felt like the app was lagging)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 1000L)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 800L)
        })
    }

    private fun relistenSoon(ms: Long) {
        lifecycleScope.launch { delay(ms); if (state.live && state.phase == VoicePhase.Listening) listen() }
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(p: Bundle?) { state.phase = VoicePhase.Listening }
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rms: Float) { state.level = ((rms + 2f) / 12f).coerceIn(0f, 1f) }
        override fun onBufferReceived(b: ByteArray?) {}
        override fun onEndOfSpeech() { state.level = 0f }
        override fun onError(error: Int) {
            state.level = 0f
            if (!state.live) { state.phase = VoicePhase.Idle; return }
            when (error) {
                // silence or nothing understood: just keep listening, the conversation stays open
                SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> relistenSoon(250)
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> { stopVoice(); state.toast("Microphone permission is needed.") }
                SpeechRecognizer.ERROR_RECOGNIZER_BUSY, SpeechRecognizer.ERROR_CLIENT -> relistenSoon(700)
                else -> relistenSoon(1200)  // network/server hiccup: try again a bit later
            }
        }
        override fun onResults(b: Bundle?) {
            val all = b?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION).orEmpty()
            val text = all.firstOrNull().orEmpty()
            state.partial = text
            if (text.isBlank()) { if (state.live) relistenSoon(250) else state.phase = VoicePhase.Idle }
            else {
                val tr = when (state.voiceLang) {
                    "tr" -> true
                    "en" -> false
                    else -> (detectedLang ?: b?.getString(SpeechRecognizer.DETECTED_LANGUAGE))?.startsWith("tr") == true || looksTurkish(text)
                }
                android.util.Log.i("MuistiLang", "heard '${text.take(60)}' detected=$detectedLang -> ${if (tr) "tr" else "en"}")
                ask(text, spoken = true, heard = if (tr) emptyList() else all.drop(1), lang = if (tr) "tr" else "en")
            }
        }
        override fun onLanguageDetection(results: Bundle) {
            detectedLang = results.getString(SpeechRecognizer.DETECTED_LANGUAGE)
        }
        override fun onPartialResults(b: Bundle?) {
            b?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.let { state.partial = it }
        }
        override fun onEvent(t: Int, b: Bundle?) {}
    }

    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    /**
     * The most natural English voice: Google's network (neural) en-US voices first, they sound far more
     * human than the offline ones; then the best offline voice. All candidates are logged (MuistiVoice).
     */
    private fun pickVoice() {
        val all = tts?.voices?.filter { it.locale.language == "en" && TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED !in it.features }.orEmpty()
        for (v in all.sortedBy { it.name }) android.util.Log.i("MuistiVoice", "${v.name} q=${v.quality} lat=${v.latency} net=${v.isNetworkConnectionRequired}")
        val preferred = listOf("en-us-x-tpf-network", "en-us-x-iog-network", "en-us-x-sfg-network", "en-us-x-tpc-network", "en-us-x-iom-network")
        val v = preferred.firstNotNullOfOrNull { n -> all.firstOrNull { it.name == n } }
            ?: all.filter { it.locale.country == "US" }.sortedWith(compareByDescending<android.speech.tts.Voice> { it.isNetworkConnectionRequired }
                .thenByDescending { it.quality }).firstOrNull()
        v?.let { tts?.voice = it; enVoice = it; android.util.Log.i("MuistiVoice", "using ${it.name}") }
        val tr = tts?.voices?.filter { it.locale.language == "tr" && TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED !in it.features }.orEmpty()
        for (t in tr.sortedBy { it.name }) android.util.Log.i("MuistiVoice", "${t.name} q=${t.quality} net=${t.isNetworkConnectionRequired}")
        trVoice = tr.sortedWith(compareByDescending<android.speech.tts.Voice> { it.isNetworkConnectionRequired }.thenByDescending { it.quality }).firstOrNull()
        android.util.Log.i("MuistiVoice", "turkish: ${trVoice?.name}")
    }
    private var enVoice: android.speech.tts.Voice? = null
    private var trVoice: android.speech.tts.Voice? = null
    @Volatile private var detectedLang: String? = null

    /** Fallback when the recognizer does not report a language: Turkish letters or several common Turkish words. */
    private fun looksTurkish(t: String): Boolean {
        if (t.any { it in "çğıöşüÇĞİÖŞÜ" }) return true
        val words = t.lowercase().split(Regex("[^a-zçğıöşü]+")).toSet()
        return listOf("ne", "nerede", "neydi", "nedir", "hangi", "kaç", "bu", "bir", "mi", "mı", "var", "gördüm", "nasıl", "benim", "saat", "nereye")
            .count { it in words } >= 2
    }

    /** Live-screen switch: Auto (detect) -> EN -> TR. Restarts listening in the new language. */
    fun cycleVoiceLang() {
        state.voiceLang = when (state.voiceLang) { "auto" -> "en"; "en" -> "tr"; else -> "auto" }
        if (state.live && state.phase == VoicePhase.Listening) listen()
    }

    /** One natural utterance (no splitting, no pitch tricks: those made it sound robotic); the lyrics view follows it. */
    private fun speakHuman(text: String, queueMode: Int, lang: String = "en") {
        (if (lang == "tr") trVoice else enVoice)?.let { tts?.voice = it }
        val said = if (lang == "tr") text.trim() else spokenText(text)
        state.spoken = said; state.spokenFrom = 0; state.spokenTo = 0
        tts?.speak(said.ifEmpty { " " }, queueMode, null, "answer")
    }

    /** Text as a person would say it: "8-20" -> "8 to 20", no quote marks, separators become pauses. */
    private fun spokenText(t: String): String = t
        .replace(Regex("""\b(\d{1,2}(?::\d{2})?)\s*[-–]\s*(\d{1,2}(?::\d{2})?)\b"""), "\$1 to \$2")   // hours only, not phone numbers
        .replace(Regex("""["“”*_#]"""), "")
        .replace(" · ", ", ").replace(" / ", " or ")
        .replace(Regex("""\s+"""), " ").trim()

    /** Ends the live conversation (the only way out: the End button). */
    fun stopVoice() {
        state.live = false
        speech?.cancel()
        tts?.stop()
        state.level = 0f
        state.phase = VoicePhase.Idle
    }

    fun clearChat() = state.messages.clear()

    /** Release builds: pair this phone with the token proxy (the code is shown by the MUISTI server). */
    fun pair(url: String, code: String) {
        lifecycleScope.launch {
            val r = runCatching { withContext(Dispatchers.IO) { engine.tokens.pair(url, code); engine.tokens.token().isNotEmpty() } }
            state.toast(r.fold({ if (it) "Paired with the MUISTI server" else "Paired, but no token yet (server unreachable?)" },
                { "Pairing failed: ${it.message?.take(60)}" }))
            state.online = engine.canCall
        }
    }


}
