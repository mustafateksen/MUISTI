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
import androidx.compose.ui.graphics.PointMode
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
 * Voice orb: one bright white disc whose edge waves freely with the voice (no frame, nothing clips it),
 * with two soft translucent white waves around it. [level] = microphone level (0..1): our own voice drives
 * the waves; while MUISTI speaks they keep their own rhythm, while thinking they ripple gently.
 * [halo] = false draws the small version for the composer button.
 */
@Composable
fun WaveOrb(phase: VoicePhase, level: Float, modifier: Modifier, halo: Boolean = true) {
    val tr = rememberInfiniteTransition(label = "blob")
    val t by tr.animateFloat(0f, (2 * PI).toFloat(), infiniteRepeatable(tween(4200, easing = LinearEasing)), label = "t")
    val lvl by animateFloatAsState(level.coerceIn(0f, 1f), spring(stiffness = 700f), label = "lvl")
    val energy = when (phase) {
        VoicePhase.Listening -> 0.12f + 1.7f * lvl
        VoicePhase.Speaking -> 0.45f + 0.45f * ((sin(t * 7) + 1) / 2)
        VoicePhase.Thinking -> 0.3f
        VoicePhase.Idle -> 0.12f
    }
    Canvas(modifier) {
        val c = center
        // the disc is small inside its box so the waves have room to move freely beyond it
        val R = size.minDimension / 2 * (if (halo) 0.5f else 0.62f) * (1f + 0.12f * energy)
        fun blob(radius: Float, amp: Float, phase: Float): Path {
            val p = Path(); val n = 120
            for (i in 0..n) {
                val a = (2 * PI * i / n).toFloat()
                val wob = 0.55f * sin(3 * a + t * 2f + phase) + 0.3f * sin(5 * a - t * 3f + 2 * phase) + 0.15f * sin(7 * a + t * 4.5f)
                val r = radius * (1f + amp * wob)
                val x = c.x + r * kotlin.math.cos(a); val y = c.y + r * sin(a)
                if (i == 0) p.moveTo(x, y) else p.lineTo(x, y)
            }
            p.close(); return p
        }
        val amp = 0.03f + 0.16f * energy
        if (halo) {
            // soft glow + two translucent outer waves, free to move past the disc
            drawCircle(Brush.radialGradient(listOf(Color.White.copy(alpha = 0.10f), Color.Transparent), c, R * 2.1f), R * 2.1f, c)
            drawPath(blob(R * 1.32f, amp * 1.5f, 1.7f), Color.White.copy(alpha = 0.10f))
            drawPath(blob(R * 1.16f, amp * 1.25f, 3.4f), Color.White.copy(alpha = 0.18f))
        }
        // the white disc itself
        drawPath(blob(R, amp, 0f), Color.White)
    }
}

/** JARVIS HUD colours for the voice orb. */
object Hud {
    val Teal = Color(0xFFF2F4F8)   // white (was teal; the name stays so callers don't change)
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
