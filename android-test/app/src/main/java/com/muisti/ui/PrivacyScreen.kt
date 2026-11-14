package com.muisti.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LinearProgressIndicator
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
import com.muisti.privacy.PrivacySettings
import com.muisti.privacy.Zone

/** Everything the privacy screen can change; the activity implements it on top of PrivacySettingsRepo. */
interface PrivacyActions {
    fun setClass(cls: String, on: Boolean)
    fun setSensitiveOcr(on: Boolean)
    fun setPlateBlur(on: Boolean)
    fun scanNow()
    fun close()
}

/**
 * Privacy settings (full screen). Bathroom and nudity are shown switched on and locked; the sensitive-text block
 * defaults to off (team decision) and is never changed without the user touching it.
 */
@Composable
fun PrivacyScreen(s: PrivacySettings, insideZone: String?, a: PrivacyActions) {
    val sub = Color(0xFF8E8E93)
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().verticalScroll(rememberScrollState()).padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Privacy", fontSize = 28.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                TextButton(onClick = a::close) { Text("Done", fontWeight = FontWeight.SemiBold) }
            }
            Text("Checked on this phone before anything is stored or sent to Nemotron.", color = sub, fontSize = 14.sp)

            Section("Never leaves the phone")
            for (c in PrivacySettings.LOCKED.sorted()) ToggleRow(PrivacySettings.LABELS[c] ?: c, "Always on", true, enabled = false) {}
            Section("Also pause or drop")
            for (c in PrivacySettings.OPTIONAL_STOP + PrivacySettings.OPTIONAL_DROP)
                ToggleRow(PrivacySettings.LABELS[c] ?: c, if (c in PrivacySettings.OPTIONAL_STOP) "Recording pauses" else "Those frames are discarded",
                    s.isActive(c)) { a.setClass(c, it) }

            Section("Text on frames")
            ToggleRow("Block frames with card numbers / IBAN / ID numbers / PINs",
                "Checked on the phone's OCR (Luhn, IBAN, Finnish ID). Off by team decision.", s.sensitiveOcr) { a.setSensitiveOcr(it) }
            ToggleRow("Blur licence plates", "Plates are blurred before a frame is stored or sent.", s.plateBlur) { a.setPlateBlur(it) }

            Section("Older memories")
            val sc = s.scan
            when {
                sc.done -> Text("Checked all ${sc.total} older frames · removed ${sc.removed}.", color = sub, fontSize = 14.sp)
                sc.total > 0 -> {
                    Text("Checking older frames… up to #${sc.lastScannedId} of ${sc.total} · removed ${sc.removed}", color = sub, fontSize = 14.sp)
                    Spacer(Modifier.height(6.dp))
                    LinearProgressIndicator(progress = { (sc.lastScannedId.toFloat() / sc.total).coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth())
                }
                else -> Text("Waiting to check older frames (runs when the phone is idle).", color = sub, fontSize = 14.sp)
            }
            if (!sc.done) TextButton(onClick = a::scanNow) { Text("Check now") }
            Spacer(Modifier.height(40.dp))
        }
    }
}

@Composable
private fun Section(title: String) {
    Spacer(Modifier.height(22.dp))
    Text(title.uppercase(), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFF8E8E93))
    Spacer(Modifier.height(6.dp))
}

@Composable
private fun ToggleRow(title: String, sub: String, on: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween) {
        Column(Modifier.weight(1f).padding(end = 12.dp)) {
            Text(title, fontSize = 16.sp)
            Text(sub, fontSize = 12.sp, color = Color(0xFF8E8E93))
        }
        Switch(checked = on, onCheckedChange = onChange, enabled = enabled)
    }
}

@Composable
private fun ZoneRow(z: Zone, onRemove: () -> Unit) {
    Row(Modifier.fillMaxWidth().background(Color(0x14000000), RoundedCornerShape(12.dp)).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(z.name, fontSize = 16.sp)
            Text("%.5f, %.5f · %d m".format(z.lat, z.lon, z.radiusM.toInt()), fontSize = 12.sp, color = Color(0xFF8E8E93))
        }
        TextButton(onClick = onRemove) { Text("Remove", color = Color(0xFFF25C75)) }
    }
    Spacer(Modifier.height(6.dp))
}
