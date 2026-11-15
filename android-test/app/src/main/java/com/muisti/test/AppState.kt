package com.muisti.test

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap

enum class VoicePhase { Idle, Listening, Thinking, Speaking }

/** One remembered frame shown under an answer (already face-blurred). */
data class Shot(val image: ImageBitmap, val whenText: String, val place: String?, val mapUri: String?,
                val full: ImageBitmap? = null, val detail: ShotDetail? = null)

/** Everything one memory holds, for the detail sheet. */
data class ShotDetail(
    val title: String, val kind: String?, val whenFull: String,
    val signLines: List<String>, val rows: List<Pair<String, String>>,
    val phone: String?, val hours: String?, val caption: String?, val things: List<String>,
) { fun signText(): String? = (signLines + rows.map { "${it.first}: ${it.second}" }).joinToString("\n").ifEmpty { null } }

/** An agent proposal shown with Confirm / Cancel ([status]: open, done, cancelled, expired). */
data class ConfirmCard(val id: String, val count: Int, val thumbs: List<ImageBitmap>, val status: String = "open")

sealed class Msg {
    data class Question(val text: String) : Msg()
    data class Answer(
        val label: String,
        val text: String,
        val shots: List<Shot> = emptyList(),
        val pending: Boolean = false,
        val place: String? = null,           // street (or coordinates) of the memory used
        val mapUri: String? = null,          // geo: link to open it in Maps
        val confirm: ConfirmCard? = null,     // an action waiting for the user's OK
    ) : Msg()
}

/** Everything the screen shows. Plain Compose state, owned by the activity. */
class AppState {
    var serverUrl by mutableStateOf("")
    var cameraReady by mutableStateOf(false)
    var recording by mutableStateOf(false)
    var online by mutableStateOf(false)          // calls can be authorised (dev key or paired proxy)
    var network by mutableStateOf(true)          // the phone has a validated internet connection
    var queued by mutableIntStateOf(0)           // frames waiting for the network
    var zone by mutableStateOf<String?>(null)            // inside this no-record zone: nothing is captured
    var capturePause by mutableStateOf<String?>(null)   // non-null = capture held by the scheduler ("phone is too hot")
    var captureMode by mutableStateOf("")                // e.g. "still · 3.0 s"
    var memories by mutableIntStateOf(0)
    var framesSent by mutableIntStateOf(0)
    var lastFrame by mutableStateOf("")
    var blurrySkipped by mutableIntStateOf(0)
    var facesBlurred by mutableIntStateOf(0)
    var privacy by mutableStateOf<String?>(null)        // non-null = privacy pause, with the reason ("a bathroom")
    var privacyScore by mutableFloatStateOf(0f)
    var privacyPauses by mutableIntStateOf(0)
    var privacyDropped by mutableIntStateOf(0)         // frames that never left the phone because of privacy
    var hasLocation by mutableStateOf(false)
    var street by mutableStateOf<String?>(null)
    var sameSkipped by mutableIntStateOf(0)
    var fps by mutableIntStateOf(0)
    var focusX by mutableFloatStateOf(0f)
    var focusY by mutableFloatStateOf(0f)
    var focusTick by mutableIntStateOf(0)   // bumps on every tap-to-focus (drives the ring animation)
    var useGlasses by mutableStateOf(false)    // camera source: phone or Ray-Ban Meta
    var glassesStatus by mutableStateOf("")
    var glassesNeedsUpdate by mutableStateOf(false)
    var glassesPreview by mutableStateOf<ImageBitmap?>(null)
    var live by mutableStateOf(false)          // live voice conversation open
    var phase by mutableStateOf(VoicePhase.Idle)
    var partial by mutableStateOf("")
    var level by mutableFloatStateOf(0f)
    var voiceLang by mutableStateOf("auto")     // live voice: auto (detect EN/TR) | en | tr
    var spoken by mutableStateOf("")             // what MUISTI is saying (lyrics view)
    var spokenFrom by mutableIntStateOf(0)        // current word [from, to) in [spoken]
    var spokenTo by mutableIntStateOf(0)
    var toastText by mutableStateOf<String?>(null)
    val messages = mutableStateListOf<Msg>()
    var openShot by mutableStateOf<Shot?>(null)   // detail sheet
    val translations = androidx.compose.runtime.mutableStateMapOf<String, String>()   // sign text -> English
    var showGallery by mutableStateOf(false)
    var gallery by mutableStateOf<List<Shot>?>(null)   // null = loading

    var privacySettings by mutableStateOf(com.muisti.privacy.PrivacySettings())
    var showPrivacy by mutableStateOf(false)
    var timeline by mutableStateOf<com.muisti.ui.TimelineDay?>(null)   // non-null = timeline open
    var agentCenter by mutableStateOf<com.muisti.ui.AgentCenterState?>(null)   // non-null = Agent Center open
    var unreadNotices by mutableIntStateOf(0)

    fun toast(text: String) { toastText = text }
}
