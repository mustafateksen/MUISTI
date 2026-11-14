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
 * JARVIS-style HUD orb (no text): wobbly rings made of teal particles, thin concentric HUD circles with a
 * notched ring, and a slowly turning wireframe sphere in the middle. [level] is the microphone level (0..1);
 * the rings swell with the voice, keep their own rhythm while speaking and spin faster while thinking.
 * [halo] = false draws the compact version (composer button).
 */
@Composable
fun WaveOrb(phase: VoicePhase, level: Float, modifier: Modifier, halo: Boolean = true) {
    val tr = rememberInfiniteTransition(label = "hud")
    val t by tr.animateFloat(0f, (2 * PI).toFloat(), infiniteRepeatable(tween(6000, easing = LinearEasing)), label = "t")
    val spin by tr.animateFloat(0f, (2 * PI).toFloat(),
        infiniteRepeatable(tween(if (phase == VoicePhase.Thinking) 3500 else 14000, easing = LinearEasing)), label = "spin")
    val lvl by animateFloatAsState(level.coerceIn(0f, 1f), spring(stiffness = 200f), label = "lvl")
    val energy = when (phase) {
        VoicePhase.Listening -> 0.25f + 0.75f * lvl
        VoicePhase.Speaking -> 0.5f + 0.4f * ((sin(t * 6) + 1) / 2)
        VoicePhase.Thinking -> 0.35f
        VoicePhase.Idle -> 0.2f
    }
    val compact = !halo
    // particle bands: fixed random jitter per particle, so the rings look like dust, not lines
    val bands = remember(compact) {
        val rnd = java.util.Random(7)
        listOf(0.93f to (if (compact) 180 else 1500), 0.85f to (if (compact) 140 else 1200), 0.99f to (if (compact) 0 else 600)).map { (rf, n) ->
            Triple(rf, FloatArray(n) { rnd.nextFloat() * 2 - 1 }, FloatArray(n) { rnd.nextFloat() })
        }
    }
    Canvas(modifier) {
        val c = center
        val R = size.minDimension / 2 * (if (compact) 0.92f else 0.9f) * (1f + 0.05f * energy)
        val dot = if (compact) 1.8f else 2.6f
        // soft teal glow behind everything
        drawCircle(Brush.radialGradient(listOf(Hud.Teal.copy(alpha = 0.16f), Color.Transparent), c, R * 1.25f), R * 1.25f, c)
        // 1) wobbly particle rings
        bands.forEachIndexed { b, (rf, jit, ph) ->
            val n = jit.size
            if (n == 0) return@forEachIndexed
            val pts = ArrayList<Offset>(n)
            for (i in 0 until n) {
                val a = (2 * PI * i / n).toFloat() + spin * (if (b % 2 == 0) 0.15f else -0.1f)
                val wob = 0.045f * sin(3 * a + t * 1.3f + b) + 0.03f * sin(5 * a - t * 2.1f + 2 * b) + 0.018f * sin(9 * a + t * 3.2f)
                val band = jit[i] * 0.045f * (0.7f + 0.3f * sin(t * 4 + ph[i] * 6.28f))
                val r = R * rf * (1f + (0.35f + energy) * wob + band)
                pts.add(Offset(c.x + r * kotlin.math.cos(a), c.y + r * sin(a)))
            }
            drawPoints(pts, PointMode.Points, Hud.Teal.copy(alpha = if (b == 2) 0.4f else 0.85f), strokeWidth = dot, cap = StrokeCap.Round)
        }
        if (!compact) {
            // 2) thin HUD circles + a notched ring turning slowly
            drawCircle(Hud.Teal.copy(alpha = 0.30f), R * 0.66f, c, style = Stroke(1.2f))
            drawCircle(Hud.Teal.copy(alpha = 0.18f), R * 0.47f, c, style = Stroke(1f))
            val notch = R * 0.57f
            for (k in 0 until 12) {
                drawArc(Hud.Teal.copy(alpha = 0.45f), startAngle = k * 30f + spin * 57.3f * 0.3f, sweepAngle = 19f, useCenter = false,
                    topLeft = Offset(c.x - notch, c.y - notch), size = androidx.compose.ui.geometry.Size(notch * 2, notch * 2), style = Stroke(2.2f))
            }
        }
        // 3) wireframe sphere (meridians turn, parallels stay) with a glowing shell
        val rc = R * (if (compact) 0.42f else 0.3f) * (1f + 0.04f * energy)
        drawCircle(Brush.radialGradient(listOf(Hud.Teal.copy(alpha = 0.22f), Hud.Teal.copy(alpha = 0.04f)), c, rc), rc, c)
        drawCircle(Hud.Teal.copy(alpha = 0.85f), rc, c, style = Stroke(if (compact) 1.4f else 2f))
        val line = Hud.Teal.copy(alpha = 0.5f)
        val w = if (compact) 1f else 1.3f
        for (k in 0 until 6) {
            val a = (PI * k / 6).toFloat() + spin
            val hw = rc * kotlin.math.abs(kotlin.math.cos(a))
            drawOval(line, Offset(c.x - hw, c.y - rc), androidx.compose.ui.geometry.Size(hw * 2, rc * 2), style = Stroke(w))
        }
        for (lat in listOf(-60f, -30f, 0f, 30f, 60f)) {
            val y = rc * sin(Math.toRadians(lat.toDouble()).toFloat())
            val hw = rc * kotlin.math.cos(Math.toRadians(lat.toDouble()).toFloat())
            drawLine(line, Offset(c.x - hw, c.y + y), Offset(c.x + hw, c.y + y), w)
        }
        if (!compact) {
            // a few bright nodes riding on the sphere
            for (k in 0 until 7) {
                val a = spin * 1.2f + k * 0.9f
                val lat = sin(k * 1.7f) * 0.8f
                val x = c.x + rc * kotlin.math.cos(lat) * sin(a)
                val y = c.y + rc * sin(lat)
                if (kotlin.math.cos(a) > 0) drawCircle(Color.White.copy(alpha = 0.8f), 2.6f, Offset(x, y))
            }
        }
    }
}

/** JARVIS HUD colours for the voice orb. */
object Hud {
    val Teal = Color(0xFF4FE3D4)
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
