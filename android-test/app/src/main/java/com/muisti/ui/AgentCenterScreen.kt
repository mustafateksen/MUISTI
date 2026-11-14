package com.muisti.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** One inbox row: [how] = "Alerted" / "Inbox only" (quiet hours or rate limit). */
data class NoticeRow(val id: String, val type: String, val title: String, val body: String, val time: String, val how: String,
                     val evidence: List<String>)

data class AgentCenterState(val rows: List<NoticeRow>?, val muted: Set<String>, val labels: Map<String, String>)

interface AgentCenterActions {
    fun mute(type: String, muted: Boolean)
    fun openFrame(frame: String)
    fun close()
}

/** Notices MUISTI raised by itself, newest first, and which kinds it may raise. */
@Composable
fun AgentCenterScreen(s: AgentCenterState, a: AgentCenterActions) {
    val sub = Color(0xFF8E8E93)
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        LazyColumn(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding(), contentPadding = PaddingValues(18.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Agent Center", fontSize = 28.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                    TextButton(onClick = a::close) { Text("Done", fontWeight = FontWeight.SemiBold) }
                }
                Text("At most one alert every 15 minutes; nothing loud between 22:00 and 07:00 (safety excepted).", color = sub, fontSize = 13.sp)
            }
            when {
                s.rows == null -> item { Text("Loading…", color = sub) }
                s.rows.isEmpty() -> item { Text("No notices yet. They appear before calendar events, near places with your notes, " +
                    "and when a place you saw is about to close.", color = sub, fontSize = 14.sp) }
                else -> items(s.rows, key = { it.id }) { r ->
                    Column(Modifier.fillMaxWidth().background(Color(0x10808080), RoundedCornerShape(16.dp)).padding(14.dp)) {
                        Row { Text(r.title, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f)); Text(r.time, color = sub, fontSize = 12.sp) }
                        Spacer(Modifier.height(4.dp))
                        Text(r.body, fontSize = 14.sp)
                        Spacer(Modifier.height(4.dp))
                        Row {
                            Text(r.how, color = sub, fontSize = 12.sp, modifier = Modifier.weight(1f))
                            r.evidence.firstOrNull()?.let { f -> Text("Show memory", color = Color(0xFF0081FB), fontSize = 12.sp,
                                modifier = Modifier.clickable { a.openFrame(f) }) }
                        }
                    }
                }
            }
            item {
                Spacer(Modifier.height(16.dp))
                Text("NOTICE TYPES", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = sub)
            }
            items(s.labels.entries.toList(), key = { it.key }) { (type, label) ->
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(label, modifier = Modifier.weight(1f))
                    Switch(checked = type !in s.muted, onCheckedChange = { on -> a.mute(type, !on) })
                }
            }
        }
    }
}
