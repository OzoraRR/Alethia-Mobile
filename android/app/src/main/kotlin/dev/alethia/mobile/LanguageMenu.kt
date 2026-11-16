package dev.alethia.mobile

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/** One language control shared by every app top bar. */
@Composable
fun LanguageMenu(language: String, onLanguageChange: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val description = stringResource(R.string.profile_language_title)
    Box {
        IconButton(
            onClick = { expanded = true },
            modifier = Modifier.size(44.dp).testTag("language_globe")
                .semantics { contentDescription = description },
        ) {
            Canvas(Modifier.size(23.dp)) {
                val stroke = 1.8.dp.toPx()
                drawCircle(Ice, style = Stroke(stroke))
                drawOval(Ice, topLeft = Offset(size.width * 0.32f, 0f),
                    size = Size(size.width * 0.36f, size.height), style = Stroke(stroke))
                drawLine(Ice, Offset(0f, size.height / 2f), Offset(size.width, size.height / 2f), stroke)
            }
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }, containerColor = Navy900) {
            Text(description, color = Muted,
                fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
            listOf("id" to R.string.language_indonesian, "en" to R.string.language_english).forEach { (code, label) ->
                DropdownMenuItem(
                    text = { Text(stringResource(label), color = if (language == code) Signal else Ice) },
                    trailingIcon = { if (language == code) Text("✓", color = Signal) },
                    onClick = {
                        expanded = false
                        if (language != code) onLanguageChange(code)
                    },
                    modifier = Modifier.testTag("language_option_$code").semantics { selected = language == code },
                )
            }
        }
    }
}
