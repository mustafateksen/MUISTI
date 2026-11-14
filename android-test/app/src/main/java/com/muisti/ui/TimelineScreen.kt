package com.muisti.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** One episode as the timeline shows it. [frames] are stored frame names; thumbnails load lazily while scrolling. */
data class EpisodeCard(val id: String, val time: String, val place: String?, val summary: String?, val detail: String,
                       val count: Int, val frames: List<String>)

/** Timeline state: [cards] null = loading. */
data class TimelineDay(val title: String, val canGoForward: Boolean, val cards: List<EpisodeCard>?, val error: String? = null)

interface TimelineActions {
    fun day(delta: Int)
    /** Small JPEG decode of a stored frame (off the main thread), or null if it is gone. */
    suspend fun thumb(frame: String): ImageBitmap?
    fun openFrame(frame: String)
    /** The flat recent-photos gallery (what the Memories tile opened before). */
    fun gallery()
    fun close()
}

/** Day-by-day episodes: time range, place, AI summary (when there is one) and key frames. */
@Composable
fun TimelineScreen(d: TimelineDay, a: TimelineActions) {
    val sub = Color(0xFF8E8E93)
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { a.day(-1) }) { Text("‹ Earlier") }
                Text(d.title, fontSize = 20.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                if (d.canGoForward) TextButton(onClick = { a.day(1) }) { Text("Later ›") }
                TextButton(onClick = a::gallery) { Text("Photos") }
                TextButton(onClick = a::close) { Text("Done", fontWeight = FontWeight.SemiBold) }
            }
            when {
                d.error != null -> Text(d.error, color = Color(0xFFE8EAED), modifier = Modifier.padding(20.dp))
                d.cards == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                d.cards.isEmpty() -> Text("No memories on this day.", color = sub, modifier = Modifier.padding(20.dp))
                else -> LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    items(d.cards, key = { it.id }) { c -> EpisodeRow(c, a) }
                }
            }
        }
    }
}

@Composable
private fun EpisodeRow(c: EpisodeCard, a: TimelineActions) {
    Column(Modifier.fillMaxWidth().background(Color(0x10808080), RoundedCornerShape(18.dp)).padding(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(c.time, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
            Spacer(Modifier.size(8.dp))
            Text(c.place ?: "", color = Color(0xFF8E8E93), fontSize = 13.sp, modifier = Modifier.weight(1f))
            Text("${c.count}", color = Color(0xFF8E8E93), fontSize = 13.sp)
        }
        Spacer(Modifier.height(4.dp))
        Text(c.summary ?: c.detail, fontSize = 15.sp, lineHeight = 21.sp)
        if (c.frames.isNotEmpty()) {
            Spacer(Modifier.height(10.dp))
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(c.frames, key = { it }) { f -> Thumb(f, a) }
            }
        }
    }
}

@Composable
private fun Thumb(frame: String, a: TimelineActions) {
    val img by produceState<ImageBitmap?>(null, frame) { value = a.thumb(frame) }
    Box(Modifier.size(92.dp).clip(RoundedCornerShape(12.dp)).background(Color(0x22808080)).clickable { a.openFrame(frame) }) {
        img?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
    }
}
