package com.muisti.test

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Call
import androidx.compose.material.icons.rounded.ChatBubbleOutline
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Map
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.heightIn
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.delay
import kotlin.math.cos
import kotlin.math.sin

// ---- palette: same values as the iOS app (ios/Muisti/UI/Design/Palette.swift) ----
// black & white theme: every former colour accent is the one purple (text highlights) or white/grey
private val Brand = Color(0xFFE8EAED)
private val BrandBlue = Color(0xFFE8EAED)
private val BrandSky = Color(0xFFE8EAED)
private val Ink = Color(0xFF1C2B33)
private val Amber = Color(0xFFBDBDBD)
private val Rose = Color(0xFFF1F3F4)
private val Violet = Color(0xFFE8EAED)

private data class Tones(
    val bg: Color, val card: Color, val card2: Color, val text: Color, val sub: Color, val hair: Color,
)

private val LightTones = Tones(Color(0xFFF2F2F7), Color.White, Color(0xFFE9E9EF), Color(0xFF0B0B0F), Color(0xFF8E8E93), Color(0x14000000))
private val DarkTones = Tones(Aura.Bg, Aura.Card, Aura.Card2, Aura.Text, Aura.Sub, Aura.Hair)

private val Suggestions = listOf(
    "What did the last sign say?",
    "Where did I see a QR code?",
    "Which floor is the sauna on?",
    "What's the dentist's phone number?",
)

@Composable
fun MuistiApp(act: MainActivity) {
    val dark = true                                   // the Aura design is a dark app
    val t = DarkTones
    val scheme = darkColorScheme(primary = Aura.Lilac, onPrimary = Color.Black, background = Aura.Bg, surface = Aura.Card)
    val s = act.state
    var showSettings by remember { mutableStateOf(false) }
    var expanded by remember { mutableStateOf(true) }
    // the live view folds into a mini player as soon as there is a conversation
    LaunchedEffect(s.messages.size) { if (s.messages.isNotEmpty()) expanded = false }

    MaterialTheme(colorScheme = scheme) {
        Box(Modifier.fillMaxSize().background(t.bg)) {
            Aura(dark)
            BoxWithConstraints(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding()) {
                val heroMax = maxHeight * 0.46f
                Column(Modifier.fillMaxSize()) {
                    Header(s, t, onAgent = { act.openAgentCenter() }) { showSettings = true }
                    LiveCard(act, s, t, expanded || s.messages.isEmpty(), heroMax) { expanded = !expanded }
                    AnimatedVisibility(expanded || s.messages.isEmpty(), enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
                        StatsRow(s, t) { act.openTimeline(0) }
                    }
                    Box(Modifier.weight(1f)) {
                        if (s.messages.isEmpty()) Welcome(t) { act.ask(it, spoken = false) }
                        else Transcript(act, s, t)
                    }
                    Composer(t, s, onSend = { act.ask(it, spoken = false) }, onMic = { act.startListening() }, onAdd = { act.pickPhoto() })
                    Spacer(Modifier.height(TabBarSpace))
                }
            }

            if (s.showGallery) GallerySheet(s, t, onOpen = { sh -> s.showGallery = false; s.openShot = sh }) { s.showGallery = false }
            s.openShot?.let { shot -> ShotSheet(shot, t, act) { s.openShot = null } }
            Toast(s, t)

            if (showSettings) SettingsDialog(s.serverUrl, onPhoto = { showSettings = false; act.pickPhoto() }, onSave = { act.saveServer(it); showSettings = false },
                onClear = { act.clearChat(); showSettings = false }, onPrivacy = { showSettings = false; s.showPrivacy = true },
                pairing = !act.engine.devKeys, onPair = { u, c -> act.pair(u, c); showSettings = false }, onDismiss = { showSettings = false })
            s.agentCenter?.let { c ->
                androidx.activity.compose.BackHandler { s.agentCenter = null }
                com.muisti.ui.AgentCenterScreen(c, act.agentActions)
            }
            s.timeline?.let { d ->
                androidx.activity.compose.BackHandler { s.timeline = null }
                com.muisti.ui.TimelineScreen(d, act.timelineActions)
            }
            if (s.showPrivacy) {
                androidx.activity.compose.BackHandler { s.showPrivacy = false }
                com.muisti.ui.PrivacyScreen(s.privacySettings, s.zone, act.privacyActions)
            }
            // floating tab bar over every screen (Aura design); the live voice view covers it
            val tab = when { s.timeline != null -> Tab.Timeline; s.agentCenter != null -> Tab.Agent; s.showPrivacy -> Tab.Settings; else -> Tab.Home }
            AuraTabBar(tab, s.unreadNotices, Modifier.align(Alignment.BottomCenter)) { pick ->
                if (pick == tab) return@AuraTabBar
                s.timeline = null; s.agentCenter = null; s.showPrivacy = false
                when (pick) {
                    Tab.Home -> {}
                    Tab.Timeline -> act.openTimeline(0)
                    Tab.Agent -> act.openAgentCenter()
                    Tab.Settings -> s.showPrivacy = true
                }
            }
            VoiceOverlay(s, t, onClose = { act.stopVoice() }, onOrb = { act.interrupt() })
        }
    }
}

/** Slowly drifting blue/violet light behind the header - the "alive" feel of the iOS app. */
@Composable
private fun Aura(dark: Boolean) {
    val drift by rememberInfiniteTransition(label = "aura").animateFloat(0f, 1f,
        infiniteRepeatable(tween(9000, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "d")
    val a = if (dark) 1f else 0.55f
    // black & white version of the drifting light: white and silver glows that slowly move
    Canvas(Modifier.fillMaxWidth().height(460.dp)) {
        val w = size.width; val h = size.height
        drawRect(Brush.radialGradient(listOf(Color.White.copy(alpha = 0.20f * a), Color.Transparent),
            center = Offset(w * (0.15f + 0.15f * drift), h * 0.05f), radius = w * 0.85f))
        drawRect(Brush.radialGradient(listOf(Color(0xFFBDC1C6).copy(alpha = 0.16f * a), Color.Transparent),
            center = Offset(w * (0.95f - 0.2f * drift), h * (0.18f + 0.1f * drift)), radius = w * 0.75f))
        drawRect(Brush.radialGradient(listOf(Color.White.copy(alpha = 0.08f * a), Color.Transparent),
            center = Offset(w * 0.5f, h * (0.55f - 0.15f * drift)), radius = w * 0.6f))
    }
}

private fun greeting(): String {
    val h = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)
    return when (h) { in 5..11 -> "Good morning"; in 12..17 -> "Good afternoon"; in 18..22 -> "Good evening"; else -> "Hello, night owl" }
}

// ---------------- header ----------------

@Composable
private fun Header(s: AppState, t: Tones, onAgent: () -> Unit = {}, onSettings: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(start = 22.dp, end = 14.dp, top = 10.dp, bottom = 14.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text("MUISTI", color = Aura.Lilac, fontSize = 13.sp, fontWeight = FontWeight.Bold, letterSpacing = 3.sp)
            Text(greeting(), color = t.text, fontSize = 30.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.6).sp)
        }
        val (label, color) = when {
            s.zone != null -> "No-record zone" to Amber
            !s.network -> (if (s.queued > 0) "Offline · ${s.queued} queued" else "Offline") to Amber
            s.recording && s.capturePause != null -> "Paused · ${s.capturePause}" to Amber
            s.recording -> "Remembering" to Rose
            !s.online -> "Not connected to Nemotron" to Amber
            else -> "Ready" to Aura.Lilac
        }
        Row(Modifier.clip(CircleShape).background(t.card.copy(alpha = 0.85f)).border(0.5.dp, t.hair, CircleShape)
            .padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            if (s.recording) PulsingDot(color) else Box(Modifier.size(8.dp).clip(CircleShape).background(color))
            Spacer(Modifier.width(7.dp))
            Text(label, color = t.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.width(8.dp))
        Box(Modifier.size(40.dp).clip(CircleShape).background(t.card.copy(alpha = 0.85f)).border(0.5.dp, t.hair, CircleShape)
            .clickable(onClick = onAgent), contentAlignment = Alignment.Center) {
            Icon(Icons.Rounded.Notifications, contentDescription = "Agent Center", tint = if (s.unreadNotices > 0) BrandBlue else t.text, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.width(8.dp))
        Box(Modifier.size(40.dp).clip(CircleShape).background(t.card.copy(alpha = 0.85f)).border(0.5.dp, t.hair, CircleShape)
            .clickable(onClick = onSettings), contentAlignment = Alignment.Center) {
            Icon(Icons.Rounded.Settings, contentDescription = "Settings", tint = t.text, modifier = Modifier.size(20.dp))
        }
    }
}

// ---------------- live view: hero <-> mini player ----------------

/**
 * One camera view that animates between a hero card and a mini player (the PreviewView must never
 * have two parents, so it is the same view resized, not two views swapped).
 */
@Composable
private fun LiveCard(act: MainActivity, s: AppState, t: Tones, expanded: Boolean, heroMax: androidx.compose.ui.unit.Dp, onToggle: () -> Unit) {
    val haptics = LocalHapticFeedback.current
    val h by animateDpAsState(if (expanded) heroMax else 84.dp, spring(dampingRatio = 0.86f, stiffness = 380f), label = "h")
    val r by animateDpAsState(if (expanded) 32.dp else 26.dp, label = "r")
    Box(Modifier.padding(horizontal = 14.dp).fillMaxWidth().height(h)
        .shadow(if (expanded) 18.dp else 8.dp, RoundedCornerShape(r), clip = false)
        .clip(RoundedCornerShape(r)).background(Ink)
        .then(if (!expanded) Modifier.clickable(onClick = onToggle) else Modifier)) {

        if (s.useGlasses) {
            val frame = s.glassesPreview
            if (frame != null) Image(frame, contentDescription = "Glasses view", contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            else Box(Modifier.fillMaxSize().background(Brush.linearGradient(listOf(Ink, Color(0xFF0B1E3A)))), contentAlignment = Alignment.Center) {
                if (expanded) Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(28.dp)) {
                    Text("🕶", fontSize = 40.sp)
                    Spacer(Modifier.height(10.dp))
                    Text(s.glassesStatus.ifEmpty { "Connecting to your glasses…" }, color = Color.White.copy(alpha = 0.9f),
                        fontSize = 15.sp, textAlign = TextAlign.Center)
                    // any state that is not still in progress ("…") gets a Try again (e.g. "no eligible device")
                    val stuck = s.glassesStatus.isNotEmpty() && !s.glassesStatus.endsWith("…")
                    if (s.glassesNeedsUpdate || stuck) {
                        Spacer(Modifier.height(14.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            if (s.glassesNeedsUpdate) PillButton("Update glasses", BrandBlue) { act.openGlassesUpdate() }
                            PillButton("Try again", if (s.glassesNeedsUpdate) Color.White.copy(alpha = 0.18f) else BrandBlue) { act.retryGlasses() }
                        }
                    }
                }
            }
        } else AndroidView(factory = { act.previewView }, modifier = Modifier.fillMaxSize())

        // shading so the controls read on any scene
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(
            0f to Color.Black.copy(alpha = 0.45f), 0.28f to Color.Transparent,
            0.62f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.6f))))

        // privacy pause: the view is covered; nothing is being remembered or sent
        androidx.compose.animation.AnimatedVisibility(s.privacy != null, enter = androidx.compose.animation.fadeIn(),
            exit = androidx.compose.animation.fadeOut(), modifier = Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxSize().background(Brush.linearGradient(listOf(Color(0xF20B1E3A), Color(0xF2102A22)))),
                contentAlignment = Alignment.Center) {
                if (expanded) Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(24.dp)) {
                    Text("🔒", fontSize = 40.sp)
                    Spacer(Modifier.height(10.dp))
                    Text("Privacy mode", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                    Text("Looks like ${s.privacy ?: "a private place"}. Nothing is being remembered or sent.",
                        color = Color.White.copy(alpha = 0.85f), fontSize = 14.sp, textAlign = TextAlign.Center,
                        modifier = Modifier.padding(top = 6.dp))
                    Text("Resumes by itself when you leave", color = Color(0xFF7CE0A0), fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 10.dp))
                }
            }
        }

        if (expanded) {
            FocusRing(s)
            Row(Modifier.align(Alignment.TopStart).padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                GlassCapsule {
                    if (s.privacy != null) Box(Modifier.size(7.dp).clip(CircleShape).background(Aura.Lilac))
                    else if (s.recording) PulsingDot(Rose) else Box(Modifier.size(7.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.7f)))
                    Spacer(Modifier.width(7.dp))
                    Text(if (s.privacy != null) "PRIVATE" else if (s.recording) "LIVE" else "PAUSED", color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.2.sp)
                    if (s.recording && s.fps > 0) Text("  ${s.fps} fps", color = Color.White.copy(alpha = 0.7f), fontSize = 11.sp)
                }
            }
            SourceSwitch(s.useGlasses, Modifier.align(Alignment.TopEnd).padding(14.dp)) { act.setSource(it) }
            Column(Modifier.align(Alignment.BottomStart).padding(start = 18.dp, bottom = 18.dp, end = 96.dp)) {
                Text(if (s.useGlasses) "Ray-Ban Meta" else "Phone camera", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Text(when {
                    s.recording && s.lastFrame.isNotEmpty() -> s.lastFrame
                    s.recording -> "Watching for things worth remembering…"
                    else -> "Tap record to start remembering"
                }, color = Color.White.copy(alpha = 0.78f), fontSize = 13.sp, maxLines = 1)
            }
            if (s.messages.isNotEmpty())
                Box(Modifier.align(Alignment.TopCenter).padding(top = 10.dp).size(34.dp, 5.dp).clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.5f)).clickable(onClick = onToggle))
            RecordButton(s.recording, Modifier.align(Alignment.BottomEnd).padding(16.dp)) {
                haptics.performHapticFeedback(HapticFeedbackType.LongPress); act.toggleRecording()
            }
        } else {
            // mini player
            Row(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (s.recording) PulsingDot(Rose) else Box(Modifier.size(7.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.7f)))
                        Spacer(Modifier.width(7.dp))
                        Text(if (s.privacy != null) "Privacy pause" else if (s.recording) "Remembering" else "Paused", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                    }
                    Text("${if (s.useGlasses) "Glasses" else "Phone"} · ${s.memories} memories · tap to expand",
                        color = Color.White.copy(alpha = 0.72f), fontSize = 12.sp, maxLines = 1)
                }
                MiniRecord(s.recording) { haptics.performHapticFeedback(HapticFeedbackType.LongPress); act.toggleRecording() }
            }
        }
    }
}

@Composable
private fun PillButton(text: String, bg: Color, onClick: () -> Unit) {
    Text(text, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
        modifier = Modifier.clip(CircleShape).background(bg).clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 10.dp))
}

@Composable
private fun MiniRecord(recording: Boolean, onClick: () -> Unit) {
    val corner by animateFloatAsState(if (recording) 0.25f else 0.5f, tween(220), label = "c")
    val inner by animateFloatAsState(if (recording) 0.42f else 0.72f, spring(dampingRatio = 0.6f), label = "i")
    Box(Modifier.size(44.dp).clip(CircleShape).border(2.5.dp, Color.White, CircleShape).clickable(onClick = onClick),
        contentAlignment = Alignment.Center) {
        Box(Modifier.size(44.dp * inner).clip(RoundedCornerShape(percent = (corner * 100).toInt())).background(Rose))
    }
}

/** Three glanceable facts under the live view. */
@Composable
private fun StatsRow(s: AppState, t: Tones, onMemories: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        StatTile(Modifier.weight(1f).clip(RoundedCornerShape(20.dp)).clickable { onMemories() }, t, "Memories", "${s.memories}  ›", BrandBlue)
        StatTile(Modifier.weight(1f), t, "Privacy", when {
            s.privacy != null -> "Paused now"
            s.privacyDropped > 0 -> "${s.privacyDropped} kept private"
            s.facesBlurred > 0 -> "${s.facesBlurred} blurred"
            else -> "Guard on"
        }, Aura.Lilac)
        StatTile(Modifier.weight(1f), t, "Place", s.street ?: (if (s.hasLocation) "Locating…" else "—"), Violet)
    }
}

@Composable
private fun StatTile(modifier: Modifier, t: Tones, title: String, value: String, accent: Color) {
    Column(modifier.clip(RoundedCornerShape(20.dp)).background(t.card.copy(alpha = 0.9f)).border(0.5.dp, t.hair, RoundedCornerShape(20.dp))
        .padding(horizontal = 14.dp, vertical = 12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(6.dp).clip(CircleShape).background(accent))
            Spacer(Modifier.width(6.dp))
            Text(title, color = t.sub, fontSize = 12.sp, fontWeight = FontWeight.Medium)
        }
        Spacer(Modifier.height(4.dp))
        Text(value, color = t.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

/** iOS-style yellow focus square where the user tapped; fades out. */
@Composable
private fun FocusRing(s: AppState) {
    if (s.focusTick == 0) return
    val alpha = remember { androidx.compose.animation.core.Animatable(0f) }
    val scale = remember { androidx.compose.animation.core.Animatable(1.4f) }
    LaunchedEffect(s.focusTick) {
        alpha.snapTo(1f); scale.snapTo(1.4f)
        scale.animateTo(1f, spring(dampingRatio = 0.55f))
        delay(900)
        alpha.animateTo(0f, tween(400))
    }
    val half = 36.dp
    val density = androidx.compose.ui.platform.LocalDensity.current
    Box(Modifier
        .offset { androidx.compose.ui.unit.IntOffset((s.focusX - with(density) { half.toPx() }).toInt(),
                                                     (s.focusY - with(density) { half.toPx() }).toInt()) }
        .size(half * 2)
        .scale(scale.value)
        .border(1.5.dp, Color(0xFFFFD60A).copy(alpha = alpha.value), RoundedCornerShape(6.dp)))
}

/** iOS-style segmented control: Phone | Glasses. */
@Composable
private fun SourceSwitch(glasses: Boolean, modifier: Modifier, onPick: (Boolean) -> Unit) {
    Row(modifier.clip(CircleShape).background(Color.Black.copy(alpha = 0.38f))
        .border(0.5.dp, Color.White.copy(alpha = 0.18f), CircleShape).padding(3.dp)) {
        listOf(false to "Phone", true to "Glasses").forEach { (v, label) ->
            val selected = v == glasses
            Text(label, color = if (selected) Ink else Color.White, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clip(CircleShape).background(if (selected) Color.White else Color.Transparent)
                    .clickable { onPick(v) }.padding(horizontal = 12.dp, vertical = 6.dp))
        }
    }
}

@Composable
private fun GlassCapsule(content: @Composable () -> Unit) {
    Row(Modifier.clip(CircleShape).background(Color.Black.copy(alpha = 0.38f))
        .border(0.5.dp, Color.White.copy(alpha = 0.18f), CircleShape)
        .padding(horizontal = 12.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) { content() }
}

@Composable
private fun PulsingDot(color: Color) {
    val a by rememberInfiniteTransition(label = "pulse").animateFloat(
        1f, 0.25f, infiniteRepeatable(tween(800, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "a")
    Box(Modifier.size(8.dp).clip(CircleShape).background(color.copy(alpha = a)))
}

/** iOS camera-style shutter: white ring, red disc that morphs into a rounded square while recording. */
@Composable
private fun RecordButton(recording: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val inner by animateFloatAsState(if (recording) 0.46f else 0.78f, spring(dampingRatio = 0.6f), label = "inner")
    val corner by animateFloatAsState(if (recording) 0.22f else 0.5f, tween(250), label = "corner")
    Box(modifier.size(64.dp).clip(CircleShape).border(3.5.dp, Color.White, CircleShape)
        .clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Box(Modifier.size(64.dp * inner).clip(RoundedCornerShape(percent = (corner * 100).toInt())).background(Rose))
    }
}

// ---------------- conversation ----------------

private val SuggestionIcons = listOf("🪧", "🔳", "🛗", "📞")

@Composable
private fun Welcome(t: Tones, onPick: (String) -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 6.dp)) {
        Text("Ask me anything you've seen", color = t.text, fontSize = 22.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.3).sp)
        Spacer(Modifier.height(4.dp))
        Text("Type, or tap the orb and just talk.", color = t.sub, fontSize = 15.sp)
        Spacer(Modifier.height(14.dp))
        Suggestions.chunked(2).forEachIndexed { row, pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.padding(bottom = 10.dp)) {
                pair.forEachIndexed { i, q ->
                    Column(Modifier.weight(1f).height(104.dp).clip(RoundedCornerShape(22.dp)).background(t.card.copy(alpha = 0.92f))
                        .border(0.5.dp, t.hair, RoundedCornerShape(22.dp)).clickable { onPick(q) }.padding(14.dp),
                        verticalArrangement = Arrangement.SpaceBetween) {
                        Text(SuggestionIcons[row * 2 + i], fontSize = 22.sp)
                        Text(q, color = t.text, fontSize = 14.sp, fontWeight = FontWeight.Medium, lineHeight = 18.sp, maxLines = 3)
                    }
                }
            }
        }
    }
}

@Composable
private fun Transcript(act: MainActivity, s: AppState, t: Tones) {
    val list = rememberLazyListState()
    LaunchedEffect(s.messages.size, (s.messages.lastOrNull() as? Msg.Answer)?.pending) {
        if (s.messages.isNotEmpty()) list.animateScrollToItem(s.messages.size - 1)
    }
    Box(Modifier.fillMaxSize()) {
        LazyColumn(state = list, modifier = Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp, 14.dp, 16.dp, 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            itemsIndexed(s.messages) { _, m ->
                Appear { when (m) {
                    is Msg.Question -> QuestionBubble(m.text)
                    is Msg.Answer -> AnswerBlock(m, t, onOpen = { s.openShot = it }, onConfirm = { id, yes -> act.resolve(id, yes, spoken = false) }) { uri -> act.openMap(uri) }
                } }
            }
        }
        // content fades out under the live card, like the iOS top bar
        Box(Modifier.fillMaxWidth().height(18.dp).background(Brush.verticalGradient(listOf(t.bg, Color.Transparent))))
    }
}

@Composable
private fun QuestionBubble(text: String) {
    Box(Modifier.fillMaxWidth().padding(start = 56.dp), contentAlignment = Alignment.CenterEnd) {
        Text(text, color = Color(0xFF15153A), fontSize = 16.sp, lineHeight = 21.sp, fontWeight = FontWeight.Medium,
            modifier = Modifier.shadow(10.dp, RoundedCornerShape(22.dp, 22.dp, 6.dp, 22.dp), ambientColor = Color.White, spotColor = Color.White)
                .clip(RoundedCornerShape(22.dp, 22.dp, 6.dp, 22.dp))
                .background(Aura.LilacSoft)
                .padding(horizontal = 16.dp, vertical = 11.dp))
    }
}

/** Assistant turn: small orb, a "seen / not sure" badge, the answer, and the frames that prove it. */
@Composable
private fun AnswerBlock(m: Msg.Answer, t: Tones, onOpen: (Shot) -> Unit, onConfirm: (String, Boolean) -> Unit = { _, _ -> }, onMap: (String) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(end = 28.dp)) {
        Column(Modifier.clip(RoundedCornerShape(22.dp, 22.dp, 22.dp, 6.dp)).background(t.card)
            .border(0.5.dp, t.hair, RoundedCornerShape(22.dp, 22.dp, 22.dp, 6.dp)).padding(horizontal = 16.dp, vertical = 12.dp)) {
            if (m.pending) { ThinkingDots(); return@Column }
            LabelPill(m.label)
            Spacer(Modifier.height(7.dp))
            Text(m.text, color = t.text, fontSize = 16.sp, lineHeight = 23.sp)
            m.confirm?.let { c -> ConfirmRow(c, t) { yes -> onConfirm(c.id, yes) } }
            if (m.shots.isNotEmpty()) {
                Spacer(Modifier.height(12.dp))
                LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    items(m.shots.size) { i -> EvidenceCard(m.shots[i], t) { onOpen(m.shots[i]) } }
                }
            } else if (m.place != null) {
                Spacer(Modifier.height(10.dp))
                PlaceChip(m.place, m.mapUri, onMap)
            }
        }
    }
}

/** Confirm / Cancel for an agent proposal, with what it affects (count + thumbnails). */
@Composable
private fun ConfirmRow(c: ConfirmCard, t: Tones, onAnswer: (Boolean) -> Unit) {
    Spacer(Modifier.height(10.dp))
    if (c.thumbs.isNotEmpty()) {
        LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            items(c.thumbs.size) { i ->
                Image(c.thumbs[i], null, Modifier.size(56.dp).clip(RoundedCornerShape(8.dp)), contentScale = ContentScale.Crop)
            }
        }
        Spacer(Modifier.height(8.dp))
    }
    when (c.status) {
        "open" -> Row {
            Button(onClick = { onAnswer(true) }, colors = ButtonDefaults.buttonColors(containerColor = Rose)) {
                Text(if (c.count > 0) "Confirm (${c.count})" else "Confirm") }
            Spacer(Modifier.width(10.dp))
            TextButton(onClick = { onAnswer(false) }) { Text("Cancel", color = t.sub) }
        }
        "done" -> Text("Done", color = Aura.Lilac, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        "cancelled" -> Text("Cancelled", color = t.sub, fontSize = 13.sp)
        else -> Text("Not confirmed", color = t.sub, fontSize = 13.sp)
    }
}

/** One remembered frame (already face-blurred): image, when, and where with a map pin. */
@Composable
private fun EvidenceCard(shot: Shot, t: Tones, onOpen: () -> Unit) {
    Column(Modifier.width(176.dp).clip(RoundedCornerShape(20.dp)).background(t.card).border(0.5.dp, t.hair, RoundedCornerShape(20.dp))
        .clickable(onClick = onOpen).padding(6.dp)) {
        Image(shot.image, contentDescription = "Seen here", contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxWidth().height(118.dp).clip(RoundedCornerShape(15.dp)))
        Column(Modifier.padding(horizontal = 6.dp, vertical = 7.dp)) {
            Text(shot.whenText, color = t.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
            Text(if (shot.place != null) "📍 ${shot.place}" else "No location", color = if (shot.mapUri != null) BrandBlue else t.sub,
                fontSize = 12.sp, maxLines = 1)
        }
    }
}

@Composable
private fun PlaceChip(place: String, mapUri: String?, onMap: (String) -> Unit) {
    Row(Modifier.clip(CircleShape).background(BrandBlue.copy(alpha = 0.14f))
        .clickable(enabled = mapUri != null) { mapUri?.let(onMap) }
        .padding(horizontal = 12.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
        Text("📍  $place", color = BrandBlue, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        if (mapUri != null) Text("  ·  Open in Maps", color = BrandBlue, fontSize = 13.sp)
    }
}

/** The voice orb's little sibling, as the assistant's avatar. */
@Composable
private fun AvatarOrb(thinking: Boolean) {
    val spin by rememberInfiniteTransition(label = "av").animateFloat(0f, 360f,
        infiniteRepeatable(tween(if (thinking) 1400 else 7000, easing = LinearEasing)), label = "s")
    Box(Modifier.size(30.dp).clip(CircleShape)
        .background(Brush.sweepGradient(listOf(BrandSky, BrandBlue, Violet, BrandSky)))) {
        Canvas(Modifier.fillMaxSize()) {
            val r = size.minDimension / 2
            val rad = Math.toRadians(spin.toDouble())
            drawCircle(Brush.radialGradient(listOf(Color.White.copy(alpha = 0.6f), Color.Transparent),
                center = Offset(center.x + r * 0.4f * cos(rad).toFloat(), center.y + r * 0.4f * sin(rad).toFloat()), radius = r * 0.8f), radius = r)
        }
    }
}

@Composable
private fun LabelPill(label: String) {
    val (text, color) = when (label) {
        "SEEN" -> "Seen" to Aura.Lilac
        "UNSURE" -> "Not sure" to Amber
        "DONT_KNOW" -> "Didn't see it" to Color(0xFF8E8E93)
        "FORGOT" -> "Forgotten" to Violet
        "CONFIRM" -> "Needs your OK" to Amber
        "NOTED" -> "Noted" to BrandSky
        "CHAT" -> "Muisti" to Violet
        "WEB" -> "From the web" to Violet
        else -> "Error" to Rose
    }
    Text(text.uppercase(), color = color, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
}

@Composable
private fun ThinkingDots() {
    val tr = rememberInfiniteTransition(label = "dots")
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(vertical = 9.dp)) {
        repeat(3) { i ->
            val a by tr.animateFloat(0.25f, 1f, infiniteRepeatable(tween(500, delayMillis = i * 150), RepeatMode.Reverse), label = "d$i")
            Box(Modifier.size(8.dp).clip(CircleShape).background(Aura.Lilac.copy(alpha = a)))
        }
    }
}

// ---------------- composer ----------------

/** Space kept free at the bottom of a screen for the floating tab bar. */
private val TabBarSpace = 86.dp

/** Aura composer: + (add a photo) · text · the wave orb (talk), which turns into a lilac send button once text is typed. */
@Composable
private fun Composer(t: Tones, s: AppState, onSend: (String) -> Unit, onMic: () -> Unit, onAdd: () -> Unit) {
    var text by remember { mutableStateOf("") }
    val haptics = LocalHapticFeedback.current
    val send = { if (text.isNotBlank()) { onSend(text); text = "" } }
    Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp)
        .shadow(14.dp, CircleShape, clip = false)
        .clip(CircleShape).background(t.card).border(0.5.dp, t.hair, CircleShape)
        .padding(start = 6.dp, end = 6.dp, top = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(40.dp).clip(CircleShape).background(t.card2).clickable(onClick = onAdd), contentAlignment = Alignment.Center) {
            Icon(Icons.Rounded.Add, "Add a photo", tint = t.text, modifier = Modifier.size(22.dp))
        }
        Spacer(Modifier.width(12.dp))
        BasicTextField(
            value = text, onValueChange = { text = it }, singleLine = true,
            textStyle = TextStyle(color = t.text, fontSize = 16.sp),
            cursorBrush = SolidColor(Aura.Lilac),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { send() }),
            modifier = Modifier.weight(1f),
            decorationBox = { inner ->
                if (text.isEmpty()) Text("Ask MUISTI…", color = t.sub, fontSize = 16.sp)
                inner()
            })
        Spacer(Modifier.width(8.dp))
        val typing = text.isNotBlank()
        Box(Modifier.size(46.dp).clip(CircleShape)
            .clickable { haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove); if (typing) send() else onMic() },
            contentAlignment = Alignment.Center) {
            if (typing) {
                Box(Modifier.size(40.dp).clip(CircleShape).background(Aura.LilacSoft), contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.ArrowUpward, "Send", tint = Color(0xFF15153A), modifier = Modifier.size(22.dp))
                }
            } else WaveOrb(VoicePhase.Idle, 0f, Modifier.size(46.dp), halo = false)
        }
    }
}

// ---------------- voice overlay ----------------

@Composable
private fun VoiceOverlay(s: AppState, t: Tones, onClose: () -> Unit, onOrb: () -> Unit) {
    AnimatedVisibility(s.live, enter = fadeIn(tween(250)), exit = fadeOut(tween(300))) {
        // swallow touches so the screen below does not react; only the orb, X and End do something
        Box(Modifier.fillMaxSize().background(Aura.Bg)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}) {
            Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(horizontal = 22.dp, vertical = 14.dp),
                horizontalAlignment = Alignment.CenterHorizontally) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(40.dp).clip(RoundedCornerShape(12.dp)).background(t.card).border(0.5.dp, t.hair, RoundedCornerShape(12.dp))
                        .clickable(onClick = onClose), contentAlignment = Alignment.Center) {
                        Icon(Icons.Rounded.Close, "Close", tint = t.text, modifier = Modifier.size(20.dp))
                    }
                    Spacer(Modifier.width(12.dp))
                    Text("Live with MUISTI", color = t.text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                }
                Spacer(Modifier.weight(0.45f))
                // no clip: the waves may move past the orb's box
                Box(Modifier.clickable(interactionSource = remember { MutableInteractionSource() },
                    indication = null, onClick = onOrb)) {
                    WaveOrb(s.phase, s.level, Modifier.size(300.dp))
                }
                Spacer(Modifier.height(18.dp))
                Text(when (s.phase) {
                    VoicePhase.Listening -> "LISTENING"
                    VoicePhase.Thinking -> "THINKING"
                    VoicePhase.Speaking -> "SPEAKING · TAP TO INTERRUPT"
                    VoicePhase.Idle -> "CONNECTING"
                }, color = Aura.Lilac, fontSize = 12.sp, fontWeight = FontWeight.Bold, letterSpacing = 2.sp)
                Spacer(Modifier.height(14.dp))
                val lastQ = s.messages.filterIsInstance<Msg.Question>().lastOrNull()?.text
                val answer = (s.messages.lastOrNull() as? Msg.Answer)?.takeIf { !it.pending }?.text
                val big = when (s.phase) {
                    VoicePhase.Listening -> s.partial.ifEmpty { "Ask about anything you've seen" }
                    VoicePhase.Thinking -> lastQ?.let { "“$it”" } ?: ""
                    VoicePhase.Speaking -> answer.orEmpty()
                    VoicePhase.Idle -> ""
                }
                Text(big, color = if (s.phase == VoicePhase.Listening && s.partial.isEmpty()) t.sub else t.text,
                    fontSize = if (s.phase == VoicePhase.Speaking) 21.sp else 27.sp, fontWeight = FontWeight.Bold,
                    textAlign = TextAlign.Center, lineHeight = 33.sp, maxLines = 6)
                if (s.phase == VoicePhase.Thinking) {
                    Spacer(Modifier.height(10.dp))
                    Text("Thinking…", color = t.sub, fontSize = 16.sp)
                }
                Spacer(Modifier.weight(1f))
                // the only way out of the live conversation
                Box(Modifier.fillMaxWidth().height(56.dp)
                    .clip(CircleShape).background(Aura.End).border(0.5.dp, t.hair, CircleShape).clickable(onClick = onClose), contentAlignment = Alignment.Center) {
                    Text("End", color = Aura.Lilac, fontSize = 17.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.5.sp)
                }
            }
        }
    }
}

/** Soft blob orb: colours follow the phase, size follows the microphone level. */
@Composable
private fun Orb(phase: VoicePhase, level: Float, modifier: Modifier) {
    val colors = when (phase) {
        VoicePhase.Listening -> listOf(BrandSky, BrandBlue, Brand)
        VoicePhase.Thinking -> listOf(Violet, Brand, BrandBlue)
        VoicePhase.Speaking -> listOf(BrandSky, Amber, BrandBlue)
        VoicePhase.Idle -> listOf(BrandBlue, Brand, Ink)
    }
    val tr = rememberInfiniteTransition(label = "orb")
    val speed = if (phase == VoicePhase.Thinking) 2600 else 5200
    val angle by tr.animateFloat(0f, 360f, infiniteRepeatable(tween(speed, easing = LinearEasing)), label = "ang")
    val breathe by tr.animateFloat(0.94f, 1.04f, infiniteRepeatable(tween(1600, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "br")
    val lvl by animateFloatAsState(level, spring(stiffness = 300f), label = "lvl")
    val c0 by animateColorAsState(colors[0], tween(600), label = "c0")
    val c1 by animateColorAsState(colors[1], tween(600), label = "c1")
    val c2 by animateColorAsState(colors[2], tween(600), label = "c2")

    Canvas(modifier.scale(breathe + 0.18f * lvl)) {
        val r = size.minDimension / 2
        drawCircle(Brush.radialGradient(listOf(c1.copy(alpha = 0.35f), Color.Transparent), radius = r * 1.25f), radius = r * 1.25f)
        drawCircle(Brush.radialGradient(listOf(c2, c1), radius = r), radius = r * 0.92f)
        val blobs = listOf(c0 to 0f, c1 to 120f, c2 to 240f)
        blobs.forEachIndexed { i, (col, off) ->
            val a = Math.toRadians((angle * (if (i % 2 == 0) 1 else -1) + off).toDouble())
            val d = r * (0.32f + 0.12f * lvl)
            val c = Offset(center.x + d * cos(a).toFloat(), center.y + d * sin(a).toFloat())
            drawCircle(Brush.radialGradient(listOf(col.copy(alpha = 0.9f), Color.Transparent), center = c, radius = r * 0.75f),
                radius = r * 0.75f, center = c)
        }
        drawCircle(Brush.radialGradient(listOf(Color.White.copy(alpha = 0.55f), Color.Transparent),
            center = Offset(center.x - r * 0.3f, center.y - r * 0.35f), radius = r * 0.55f), radius = r * 0.55f,
            center = Offset(center.x - r * 0.3f, center.y - r * 0.35f))
    }
}

// ---------------- toast + settings ----------------

@Composable
private fun Toast(s: AppState, t: Tones) {
    val msg = s.toastText
    LaunchedEffect(msg) { if (msg != null) { delay(2600); s.toastText = null } }
    Box(Modifier.fillMaxSize().navigationBarsPadding().padding(bottom = 90.dp), contentAlignment = Alignment.BottomCenter) {
        AnimatedVisibility(msg != null, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
            Text(msg.orEmpty(), color = Color.White, fontSize = 14.sp,
                modifier = Modifier.clip(CircleShape).background(Ink.copy(alpha = 0.92f)).padding(horizontal = 18.dp, vertical = 11.dp))
        }
    }
}

@Composable
private fun SettingsDialog(current: String, onPhoto: () -> Unit, onSave: (String) -> Unit, onClear: () -> Unit, onPrivacy: () -> Unit,
                           pairing: Boolean, onPair: (String, String) -> Unit, onDismiss: () -> Unit) {
    var url by remember { mutableStateOf(current) }
    var code by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        shape = RoundedCornerShape(24.dp),
        title = { Text("Settings", fontWeight = FontWeight.SemiBold) },
        text = {
            Column {
                Text("Everything runs on this phone: Nemotron is called directly and your memories are stored here, " +
                    "not on a server.", fontSize = 14.sp, color = Color(0xFF8E8E93))
                Spacer(Modifier.height(10.dp))
                if (pairing) {
                    // release build: no key inside the app; pair once with the MUISTI server's token proxy
                    OutlinedTextField(url, { url = it }, label = { Text("MUISTI server URL") }, singleLine = true)
                    OutlinedTextField(code, { code = it }, label = { Text("Pairing code") }, singleLine = true)
                    TextButton(onClick = { onPair(url, code) }, enabled = url.isNotBlank() && code.isNotBlank()) { Text("Pair this phone", color = BrandBlue) }
                }
                TextButton(onClick = onPrivacy) { Text("Privacy settings", color = BrandBlue) }
                TextButton(onClick = onPhoto) { Text("Add a photo to memory", color = BrandBlue) }
                TextButton(onClick = onClear) { Text("Clear conversation", color = Rose) }
            }
        },
        confirmButton = { TextButton(onClick = { onSave(url) }) { Text("Save", fontWeight = FontWeight.SemiBold) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

// ---------------- memory detail sheet ----------------

/**
 * Tap on an evidence card: a sheet slides up (not full height - the chat stays visible above it)
 * with the whole frame, when/where, actions (Call if a number was read, Maps if there is a place,
 * Copy the sign text) and everything that was read or noticed in that memory.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun ShotSheet(shot: Shot, t: Tones, act: MainActivity, onClose: () -> Unit) {
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val close: () -> Unit = { scope.launch { sheet.hide() }.invokeOnCompletion { onClose() } }
    val d = shot.detail
    ModalBottomSheet(onDismissRequest = onClose, sheetState = sheet, containerColor = t.bg,
        shape = RoundedCornerShape(topStart = 30.dp, topEnd = 30.dp),
        dragHandle = { Box(Modifier.padding(top = 10.dp, bottom = 4.dp).size(38.dp, 5.dp).clip(CircleShape).background(t.sub.copy(alpha = 0.45f))) }) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(0.9f).verticalScroll(rememberScrollState()).padding(horizontal = 18.dp)) {
            // title row with the close button top-right
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 4.dp, bottom = 12.dp)) {
                Column(Modifier.weight(1f)) {
                    Text(d?.kind?.uppercase() ?: "MEMORY", color = BrandBlue, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.2.sp)
                    Text(d?.title ?: "What I saw", color = t.text, fontSize = 24.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.4).sp, maxLines = 2)
                }
                Box(Modifier.size(36.dp).clip(CircleShape).background(t.card).clickable(onClick = close), contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.Close, "Close", tint = t.text, modifier = Modifier.size(18.dp))
                }
            }
            // the whole frame (already face-blurred), uncropped
            Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(Ink), contentAlignment = Alignment.Center) {
                // the same frame, blurred, fills the letterbox (as iOS does) - the real frame sits on top, uncropped
                Image(shot.image, contentDescription = null, contentScale = ContentScale.Crop,
                    modifier = Modifier.matchParentSize().blur(28.dp), alpha = 0.55f)
                Image(shot.full ?: shot.image, contentDescription = "Remembered frame", contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxWidth().heightIn(max = 360.dp))
                Row(Modifier.align(Alignment.BottomStart).padding(10.dp)) {
                    GlassCapsule { Text("Faces blurred on the phone", color = Color.White, fontSize = 11.sp) }
                }
            }
            Spacer(Modifier.height(14.dp))
            // when / where
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                InfoTile(Modifier.weight(1f), t, "When", d?.whenFull ?: shot.whenText)
                InfoTile(Modifier.weight(1f), t, "Where", shot.place ?: "No location")
            }
            // actions
            val phone = d?.phone
            val copyText = d?.signText()
            run {
                Spacer(Modifier.height(14.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    // black & white (Aura): the first action is the white primary, the rest graphite
                    var first = true
                    fun primary() = first.also { first = false }
                    if (phone != null) ActionButton(Modifier.weight(1f), Icons.Rounded.Call, "Call", primary()) { act.dial(phone) }
                    if (shot.mapUri != null) ActionButton(Modifier.weight(1f), Icons.Rounded.Map, "Maps", primary()) { act.openMap(shot.mapUri) }
                    if (copyText != null) ActionButton(Modifier.weight(1f), Icons.Rounded.ContentCopy, "Copy", primary()) { act.copyText(copyText) }
                    ActionButton(Modifier.weight(1f), Icons.Rounded.ChatBubbleOutline, "Ask", primary()) { act.askAbout(shot) }
                }
                if (phone != null) Text(phone, color = t.sub, fontSize = 13.sp, modifier = Modifier.padding(top = 6.dp, start = 4.dp))
            }
            if (d != null) {
                if (d.signLines.isNotEmpty()) Section(t, "Text on the sign") {
                    d.signLines.forEach { Text(it, color = t.text, fontSize = 16.sp, fontWeight = FontWeight.Medium, modifier = Modifier.padding(vertical = 2.dp)) }
                    val key = d.signText() ?: ""
                    val tr = act.state.translations[key]
                    Spacer(Modifier.height(8.dp))
                    if (tr == null) {
                        Text("🌐  Translate", color = BrandBlue, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.clip(CircleShape).background(BrandBlue.copy(alpha = 0.12f))
                                .clickable { act.translate(key) }.padding(horizontal = 12.dp, vertical = 7.dp))
                    } else {
                        Box(Modifier.fillMaxWidth().height(0.5.dp).background(t.hair))
                        Spacer(Modifier.height(8.dp))
                        Text("IN ENGLISH", color = t.sub, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
                        Text(tr, color = t.text, fontSize = 15.sp, lineHeight = 21.sp, modifier = Modifier.padding(top = 4.dp))
                    }
                }
                if (d.rows.isNotEmpty()) Section(t, "Listed here") {
                    d.rows.forEachIndexed { i, (label, value) ->
                        if (i > 0) Box(Modifier.fillMaxWidth().height(0.5.dp).background(t.hair))
                        Row(Modifier.padding(vertical = 9.dp)) {
                            Text(label, color = BrandBlue, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(110.dp))
                            Text(value, color = t.text, fontSize = 14.sp)
                        }
                    }
                }
                if (d.hours != null) Section(t, "Opening hours") { Text(d.hours, color = t.text, fontSize = 15.sp) }
                if (d.caption != null) Section(t, "The scene") { Text(d.caption, color = t.text, fontSize = 15.sp, lineHeight = 21.sp) }
                if (d.things.isNotEmpty()) Section(t, "Things I noticed") {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        d.things.forEach {
                            Text(it, color = t.text, fontSize = 13.sp, modifier = Modifier.clip(CircleShape).background(t.card2)
                                .padding(horizontal = 12.dp, vertical = 6.dp))
                        }
                    }
                }
            }
            Spacer(Modifier.height(28.dp))
        }
    }
}

@Composable
private fun InfoTile(modifier: Modifier, t: Tones, title: String, value: String) {
    Column(modifier.clip(RoundedCornerShape(18.dp)).background(t.card).padding(horizontal = 14.dp, vertical = 11.dp)) {
        Text(title, color = t.sub, fontSize = 12.sp, fontWeight = FontWeight.Medium)
        Text(value, color = t.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 2)
    }
}

@Composable
private fun ActionButton(modifier: Modifier, icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, primary: Boolean, onClick: () -> Unit) {
    val bg = if (primary) Color(0xFFF1F3F4) else Aura.Card2
    val fg = if (primary) Color(0xFF111113) else Aura.Text
    Column(modifier.clip(RoundedCornerShape(18.dp)).background(bg)
        .border(0.5.dp, if (primary) Color.Transparent else Aura.Hair, RoundedCornerShape(18.dp)).clickable(onClick = onClick)
        .padding(vertical = 14.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(icon, label, tint = fg, modifier = Modifier.size(22.dp))
        Spacer(Modifier.height(6.dp))
        Text(label, color = fg, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun Section(t: Tones, title: String, content: @Composable () -> Unit) {
    Spacer(Modifier.height(18.dp))
    Text(title.uppercase(), color = t.sub, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
    Spacer(Modifier.height(8.dp))
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(t.card).padding(horizontal = 16.dp, vertical = 12.dp)) { content() }
}

// ---------------- memory gallery ----------------

/** All recent memories as a grid; tap one for its detail sheet. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun GallerySheet(s: AppState, t: Tones, onOpen: (Shot) -> Unit, onClose: () -> Unit) {
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val close: () -> Unit = { scope.launch { sheet.hide() }.invokeOnCompletion { onClose() } }
    ModalBottomSheet(onDismissRequest = onClose, sheetState = sheet, containerColor = t.bg,
        shape = RoundedCornerShape(topStart = 30.dp, topEnd = 30.dp),
        dragHandle = { Box(Modifier.padding(top = 10.dp, bottom = 4.dp).size(38.dp, 5.dp).clip(CircleShape).background(t.sub.copy(alpha = 0.45f))) }) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(0.9f).padding(horizontal = 16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 4.dp, bottom = 14.dp)) {
                Column(Modifier.weight(1f)) {
                    Text("YOUR VISUAL MEMORY", color = BrandBlue, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.2.sp)
                    Text("Memories", color = t.text, fontSize = 26.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.4).sp)
                }
                Box(Modifier.size(36.dp).clip(CircleShape).background(t.card).clickable(onClick = close), contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.Close, "Close", tint = t.text, modifier = Modifier.size(18.dp))
                }
            }
            val shots = s.gallery
            when {
                shots == null -> Box(Modifier.fillMaxWidth().height(200.dp), contentAlignment = Alignment.Center) { ThinkingDots() }
                shots.isEmpty() -> Text("Nothing remembered yet. Tap record and look around.", color = t.sub, fontSize = 15.sp)
                else -> LazyVerticalGrid(GridCells.Fixed(2), horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(bottom = 24.dp)) {
                    items(shots.size) { i ->
                        val sh = shots[i]
                        Column(Modifier.clip(RoundedCornerShape(20.dp)).background(t.card).border(0.5.dp, t.hair, RoundedCornerShape(20.dp))
                            .clickable { onOpen(sh) }.padding(6.dp)) {
                            Image(sh.image, contentDescription = null, contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxWidth().height(130.dp).clip(RoundedCornerShape(15.dp)))
                            Column(Modifier.padding(horizontal = 6.dp, vertical = 7.dp)) {
                                // the place type is the title; text read on a sign is shown as a quote (OCR can garble it)
                                val kind = sh.detail?.kind?.replaceFirstChar { it.uppercase() }
                                val read = sh.detail?.title?.takeIf { it != kind && sh.detail.signLines.isNotEmpty() }
                                Text(kind ?: sh.detail?.title ?: "Memory", color = t.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                                if (read != null) Text("“$read”", color = BrandBlue, fontSize = 12.sp, fontWeight = FontWeight.Medium, maxLines = 1)
                                Text(listOfNotNull(sh.whenText, sh.place).joinToString(" · "), color = t.sub, fontSize = 12.sp, maxLines = 1)
                            }
                        }
                    }
                }
            }
        }
    }
}

/** New chat messages slide up and fade in instead of popping. */
@Composable
private fun Appear(content: @Composable () -> Unit) {
    val p = remember { androidx.compose.animation.core.Animatable(0f) }
    LaunchedEffect(Unit) { p.animateTo(1f, spring(dampingRatio = 0.8f, stiffness = 300f)) }
    Box(Modifier.graphicsLayer { alpha = p.value; translationY = (1f - p.value) * 40f }) { content() }
}
