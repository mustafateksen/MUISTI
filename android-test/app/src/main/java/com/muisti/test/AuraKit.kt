package com.muisti.test

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.Shield
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.sin

/** "Aura" design (Google Stitch export, Nov 15): black canvas, graphite cards, lilac accent, blue→violet voice. */
object Aura {
    val Bg = Color(0xFF000000)
    val Card = Color(0xFF141416)
    val Card2 = Color(0xFF1E1E21)
    val Hair = Color(0x1FFFFFFF)
    val Text = Color(0xFFF1F3F4)
    val Sub = Color(0xFF9AA0A6)
    val Lilac = Color(0xFF989AFF)        // accent
    val LilacSoft = Color(0xFFD3D4FF)    // user bubble
    val Blurple = Color(0xFF6056F0)
    val Blue = Color(0xFF2F6BFF)         // orb core
    val Violet = Color(0xFF8A2BE2)       // orb core
    val Cyan = Color(0xFF5EE7FF)
    val Pink = Color(0xFFFF6AD5)
    val End = Color(0xFFF25C75)
}

/**
 * Siri-like voice orb: a blue→violet sphere with glowing halos and live sine waves inside.
 * [level] is the microphone level (0..1); while speaking or thinking the waves move on their own.
 */
@Composable
fun WaveOrb(phase: VoicePhase, level: Float, modifier: Modifier, halo: Boolean = true) {
    val tr = rememberInfiniteTransition(label = "wave")
    val t by tr.animateFloat(0f, (2 * PI).toFloat(), infiniteRepeatable(tween(2400, easing = LinearEasing)), label = "t")
    val slow by tr.animateFloat(0f, (2 * PI).toFloat(), infiniteRepeatable(tween(7000, easing = LinearEasing)), label = "s")
    val lvl by animateFloatAsState(level.coerceIn(0f, 1f), spring(stiffness = 220f), label = "lvl")
    // how "loud" the waves are: real mic level when listening, a living rhythm when speaking, small when thinking
    val energy = when (phase) {
        VoicePhase.Listening -> 0.18f + 0.82f * lvl
        VoicePhase.Speaking -> 0.55f + 0.35f * ((sin(t * 3) + 1) / 2)
        VoicePhase.Thinking -> 0.22f
        VoicePhase.Idle -> 0.12f
    }
    Canvas(modifier) {
        val r = size.minDimension / 2 * (if (halo) 0.62f else 0.96f)
        val c = center
        if (halo) {
            // two soft halos, breathing with the voice
            val h1 = r * (1.55f + 0.12f * energy + 0.03f * sin(slow))
            val h2 = r * (1.25f + 0.08f * energy)
            drawCircle(Brush.radialGradient(listOf(Aura.Violet.copy(alpha = 0.22f), Color.Transparent), c, h1), h1, c)
            drawCircle(Brush.radialGradient(listOf(Aura.Blue.copy(alpha = 0.32f), Aura.Violet.copy(alpha = 0.18f), Color.Transparent), c, h2), h2, c)
        }
        // core sphere
        drawCircle(Brush.linearGradient(listOf(Aura.Blue, Aura.Blurple, Aura.Violet),
            start = Offset(c.x - r, c.y - r), end = Offset(c.x + r, c.y + r)), r, c)
        val oval = Path().apply { addOval(androidx.compose.ui.geometry.Rect(c, r)) }
        clipPath(oval) {
            // moving light inside the sphere
            val lx = c.x + r * 0.35f * sin(slow); val ly = c.y - r * 0.25f * sin(slow * 2)
            drawCircle(Brush.radialGradient(listOf(Aura.Cyan.copy(alpha = 0.45f), Color.Transparent), Offset(lx, ly), r * 0.9f), r * 0.9f, Offset(lx, ly))
            // three sine waves (Siri style): amplitude fades towards the sphere's edge
            val waves = listOf(Triple(Color.White, 1.0f, 0f), Triple(Aura.Cyan, 0.75f, 2.1f), Triple(Aura.Pink, 0.6f, 4.2f))
            for ((col, k, off) in waves) {
                val p = Path()
                val steps = 64
                for (i in 0..steps) {
                    val x = -1f + 2f * i / steps                    // -1..1 across the sphere
                    val envelope = exp(-3.2f * x * x)              // calm at the edges
                    val y = sin(x * 5.5f * k + t * (1.3f + 0.4f * k) + off) * envelope * energy * r * 0.42f * k
                    val px = c.x + x * r; val py = c.y + y
                    if (i == 0) p.moveTo(px, py) else p.lineTo(px, py)
                }
                drawPath(p, col.copy(alpha = if (col == Color.White) 0.95f else 0.7f),
                    style = Stroke(width = r * (if (col == Color.White) 0.055f else 0.04f), cap = StrokeCap.Round))
            }
            // glassy highlight
            drawCircle(Brush.radialGradient(listOf(Color.White.copy(alpha = 0.28f), Color.Transparent),
                Offset(c.x - r * 0.35f, c.y - r * 0.45f), r * 0.6f), r * 0.6f, Offset(c.x - r * 0.35f, c.y - r * 0.45f))
        }
    }
}

enum class Tab(val label: String, val icon: ImageVector) {
    Home("Home", Icons.Rounded.AutoAwesome), Timeline("Timeline", Icons.Rounded.CalendarMonth),
    Agent("Agent Center", Icons.Rounded.Notifications), Settings("Settings", Icons.Rounded.Shield)
}

/** Floating pill tab bar (Aura design). */
@Composable
fun AuraTabBar(current: Tab, unread: Int, modifier: Modifier = Modifier, onPick: (Tab) -> Unit) {
    Row(modifier.navigationBarsPadding().padding(horizontal = 14.dp, vertical = 8.dp).fillMaxWidth()
        .shadow(18.dp, RoundedCornerShape(28.dp), clip = false)
        .clip(RoundedCornerShape(28.dp)).background(Aura.Card.copy(alpha = 0.96f)).border(0.5.dp, Aura.Hair, RoundedCornerShape(28.dp))
        .padding(6.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
        for (tab in Tab.entries) {
            val sel = tab == current
            Column(Modifier.weight(1f).clip(RoundedCornerShape(22.dp)).background(if (sel) Aura.Card2 else Color.Transparent)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { onPick(tab) }
                .padding(vertical = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Box {
                    Icon(tab.icon, tab.label, tint = if (sel) Aura.Text else Aura.Sub, modifier = Modifier.size(22.dp))
                    if (tab == Tab.Agent && unread > 0)
                        Box(Modifier.align(Alignment.TopEnd).size(8.dp).clip(RoundedCornerShape(4.dp)).background(Aura.Lilac))
                }
                Spacer(Modifier.height(3.dp))
                Text(tab.label, color = if (sel) Aura.Text else Aura.Sub, fontSize = 11.sp,
                    fontWeight = if (sel) FontWeight.SemiBold else FontWeight.Medium, maxLines = 1)
            }
        }
    }
}
