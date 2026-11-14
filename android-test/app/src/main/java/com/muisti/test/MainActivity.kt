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
    val engine by lazy { PhoneEngine(applicationContext) }
    /** Ray-Ban Meta camera (created here: it registers activity-result launchers). */
    private val glasses = GlassesSource(this, state) { onGlassesFrame(it) }
    /** Ahmet's head masking: nothing leaves the phone or is stored unblurred. */
    private val blurrer by lazy { FaceBlurrer() }
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

    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { res ->
        if (res[Manifest.permission.CAMERA] == true) startCamera()
        else state.toast("Camera permission is needed to remember things.")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        state.serverUrl = getPreferences(MODE_PRIVATE).getString("server", "http://10.0.34.200:8000")!!
        previewView = PreviewView(this).apply { scaleType = PreviewView.ScaleType.FILL_CENTER }
        setContent { MuistiApp(this) }

        tts = TextToSpeech(this) { status ->
            if (status == TextToSpeech.SUCCESS) {
                tts?.language = Locale.US
                tts?.setSpeechRate(1.02f)
                ttsReady = true
            }
        }
        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String?) { runOnUiThread { state.phase = VoicePhase.Speaking } }
            override fun onDone(id: String?) { runOnUiThread { afterTurn() } }
            @Deprecated("Deprecated in Java")
            override fun onError(id: String?) { runOnUiThread { afterTurn() } }
        })

        val need = listOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
            .filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
        if (need.isEmpty()) startCamera() else permissions.launch(need.toTypedArray())
        pollStats()
    }

    override fun onDestroy() {
        statsJob?.cancel(); analysisExec.shutdown(); glasses.disconnect(); location.stop()
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
    //  - every WINDOW_MS the sharpest frame of that window is kept (2 per second),
    //  - it is dropped if it is blurry compared with recent windows (same rule as process_video.py)
    //    or if the view has not changed since the last frame sent (dHash),
    //  - the rest go to an upload queue: at most MAX_UPLOADS requests at once; when the queue is
    //    full the OLDEST waiting frame is dropped, so memory always follows what is in front of you.

    private val WINDOW_MS = 500L
    private val MAX_UPLOADS = 3
    private val uploads = Channel<Pair<Bitmap, Long>>(capacity = 2, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    private val analysisExec = Executors.newSingleThreadExecutor()
    private var windowStart = 0L
    private var windowBest: Bitmap? = null
    private var windowBestScore = -1.0
    private var lastSentHash = -1L
    private var framesThisSecond = 0
    private var secondStart = 0L

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
                for ((bmp, h) in uploads) runCatching { upload(bmp, h) }
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

    fun openMap(uri: String) {
        runCatching { startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(uri))) }
            .onFailure { state.toast("No maps app found.") }
    }

    private fun blurJpeg(jpeg: ByteArray): ByteArray? {
        val bmp = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) ?: return null
        val safe = blurrer.process(bmp) ?: return null
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
        } else location.stop()
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

    /** Same for every source: live frame ~2x/s, and while recording the sharpest frame of each window. */
    private fun considerFrame(now: Long, score: () -> Double, bitmap: () -> Bitmap) {
        if (now - lastLiveAt >= 500) {
            lastLiveAt = now
            val b = bitmap()
            liveJpeg = ByteArrayOutputStream().also { b.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
        }
        if (!state.recording) return
        if (windowStart == 0L) windowStart = now
        val sc = score()
        if (sc > windowBestScore) {            // only the window's new best is turned into a bitmap
            windowBestScore = sc
            windowBest = bitmap()
        }
        if (now - windowStart >= WINDOW_MS) {
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
        var cached: Bitmap? = null
        val toBitmap = { cached ?: i420ToBitmap(data, w, h).also { cached = it } }
        considerFrame(now, { yPlaneSharpness(data, w, h) }, toBitmap)
        if (now - lastPreviewAt >= 150) {     // ~6 fps preview of what the glasses see
            lastPreviewAt = now
            state.glassesPreview = toBitmap().asImageBitmap()
        }
    }

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
    private fun i420ToBitmap(i420: ByteArray, w: Int, h: Int): Bitmap {
        val ySize = w * h
        val q = ySize / 4
        val nv21 = ByteArray(ySize + 2 * q)
        System.arraycopy(i420, 0, nv21, 0, ySize)
        for (i in 0 until q) {
            nv21[ySize + 2 * i] = i420[ySize + q + i]      // V
            nv21[ySize + 2 * i + 1] = i420[ySize + i]      // U
        }
        val out = ByteArrayOutputStream()
        android.graphics.YuvImage(nv21, android.graphics.ImageFormat.NV21, w, h, null)
            .compressToJpeg(android.graphics.Rect(0, 0, w, h), 90, out)
        val bytes = out.toByteArray()
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
    }

    private fun offerFrame(bmp: Bitmap, score: Double) {
        if (isBlurry(score)) { state.blurrySkipped++; state.lastFrame = "Skipped · blurry"; return }
        val h = dHash(bmp)
        if (lastSentHash != -1L && java.lang.Long.bitCount(h xor lastSentHash) <= 6) {
            state.sameSkipped++; return                     // same view as the last frame sent
        }
        lastSentHash = h
        uploads.trySend(bmp to h)
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

    private suspend fun upload(bmp: Bitmap, dhash: Long) {
        val seenAt = System.currentTimeMillis()
        val fix = location.fresh()
        val obs = readText(bmp)                  // text is read from the raw frame, on the phone
        // privacy: heads are masked BEFORE the frame goes to Nemotron or into memory; on failure drop it
        val safe = withContext(Dispatchers.Default) { blurrer.process(bmp) }
        if (safe == null) { state.lastFrame = "Skipped · privacy check failed"; return }
        state.facesBlurred += safe.faceCount
        val stored = withContext(Dispatchers.IO) {
            val jpeg = ByteArrayOutputStream().also { safe.image.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
            engine.ingest(jpeg, obs, seenAt, dhash, fix)
        }
        state.online = true
        state.framesSent++
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
    private suspend fun readText(bmp: Bitmap): List<Obs> = suspendCancellableCoroutine { cont ->
        recognizer.process(InputImage.fromBitmap(bmp, 0))
            .addOnSuccessListener { text ->
                val w = bmp.width.toDouble(); val h = bmp.height.toDouble()
                val obs = ArrayList<Obs>()
                for (block in text.textBlocks) for (line in block.lines) {
                    val r = line.boundingBox ?: continue
                    obs.add(Obs(line.text, (line.confidence.takeIf { it > 0f } ?: 1f).toDouble(),
                        r.left / w, r.top / h, r.width() / w, r.height() / h))
                }
                if (cont.isActive) cont.resume(obs)
            }
            .addOnFailureListener { if (cont.isActive) cont.resume(emptyList()) }
    }

    private fun pollStats() {
        statsJob?.cancel()
        statsJob = lifecycleScope.launch {
            state.online = BuildConfig.LLM_KEY.isNotEmpty()
            while (isActive) {
                runCatching { state.memories = withContext(Dispatchers.IO) { engine.store.sightings().size } }
                delay(6000)
            }
        }
    }

    // ---------------- assistant ----------------

    fun ask(question: String, spoken: Boolean) {
        val q = question.trim()
        if (q.isEmpty()) return
        tts?.stop()
        state.messages.add(Msg.Question(q))
        val pending = Msg.Answer(label = "", text = "", pending = true)
        state.messages.add(pending)
        state.phase = if (spoken) VoicePhase.Thinking else VoicePhase.Idle
        lifecycleScope.launch {
            val answer = runCatching {
                // the live frame for "what am I seeing?" is masked too; if masking fails it is not sent
                val live = withContext(Dispatchers.Default) { liveJpeg?.let { blurJpeg(it) } }
                val r = withContext(Dispatchers.IO) { engine.ask(q, live) }
                if (r.label == "FORGOT") state.memories = withContext(Dispatchers.IO) { engine.store.sightings().size }
                val thumbs = withContext(Dispatchers.IO) { loadThumbs(r) }
                val used = r.evidence.filter { it.id in r.used }.ifEmpty { r.evidence.take(1) }
                val where = used.firstOrNull { it.lat != null }
                Msg.Answer(label = r.label, text = r.answer, thumbs = thumbs,
                    place = where?.let { it.street ?: "%.5f, %.5f".format(it.lat, it.lon) }.takeIf { r.label == "SEEN" || r.label == "UNSURE" },
                    mapUri = where?.let { "geo:${it.lat},${it.lon}?q=${it.lat},${it.lon}(${android.net.Uri.encode(it.street ?: "Seen here")})" }
                        .takeIf { r.label == "SEEN" || r.label == "UNSURE" })
            }.getOrElse { Msg.Answer(label = "ERROR", text = "I couldn't reach Nemotron (${it.message?.take(80)}).") }
            val i = state.messages.indexOf(pending)
            if (i >= 0) state.messages[i] = answer else state.messages.add(answer)
            if (spoken && ttsReady && state.live) {
                tts?.speak(answer.text, TextToSpeech.QUEUE_FLUSH, null, "answer")
            } else if (spoken) afterTurn()
        }
    }

    private fun loadThumbs(r: com.muisti.engine.Answer): List<androidx.compose.ui.graphics.ImageBitmap> {
        val used = r.used.toSet()
        val frames = r.evidence.sortedByDescending { it.id in used }.mapNotNull { it.frame }.distinct().take(3)
        return frames.mapNotNull { f ->
            runCatching {
                val file = engine.frameFile(f)
                if (!file.exists()) return@runCatching null
                BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = 4 })?.asImageBitmap()
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
        state.phase = VoicePhase.Listening
        speech?.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "en-US")
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            // give the user time to think between questions
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 1500L)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 1500L)
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
            val text = b?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
            state.partial = text
            if (text.isBlank()) { if (state.live) relistenSoon(250) else state.phase = VoicePhase.Idle }
            else ask(text, spoken = true)
        }
        override fun onPartialResults(b: Bundle?) {
            b?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.let { state.partial = it }
        }
        override fun onEvent(t: Int, b: Bundle?) {}
    }

    /** Ends the live conversation (the only way out: the End button). */
    fun stopVoice() {
        state.live = false
        speech?.cancel()
        tts?.stop()
        state.level = 0f
        state.phase = VoicePhase.Idle
    }

    fun clearChat() = state.messages.clear()


}
