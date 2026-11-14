package com.muisti.test

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap

enum class VoicePhase { Idle, Listening, Thinking, Speaking }

sealed class Msg {
    data class Question(val text: String) : Msg()
    data class Answer(
        val label: String,
        val text: String,
        val thumbs: List<ImageBitmap> = emptyList(),
        val pending: Boolean = false,
        val place: String? = null,           // street (or coordinates) of the memory used
        val mapUri: String? = null,          // geo: link to open it in Maps
    ) : Msg()
}

/** Everything the screen shows. Plain Compose state, owned by the activity. */
class AppState {
    var serverUrl by mutableStateOf("")
    var cameraReady by mutableStateOf(false)
    var recording by mutableStateOf(false)
    var online by mutableStateOf(false)
    var memories by mutableIntStateOf(0)
    var framesSent by mutableIntStateOf(0)
    var lastFrame by mutableStateOf("")
    var blurrySkipped by mutableIntStateOf(0)
    var facesBlurred by mutableIntStateOf(0)
    var hasLocation by mutableStateOf(false)
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
    var toastText by mutableStateOf<String?>(null)
    val messages = mutableStateListOf<Msg>()

    fun toast(text: String) { toastText = text }
}
