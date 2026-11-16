package dev.alethia.mobile

import androidx.compose.foundation.Image
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.Alignment
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun LearnerListScreen(title: Int, rows: List<LearnerRow>, signedIn: Boolean, onRead: ((String) -> Unit)? = null) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(stringResource(title), color = Ice,
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold)
        Box(Modifier.fillMaxWidth().height(2.dp).background(Signal.copy(alpha = 0.35f)))
        if (title == R.string.achievements_title) AchievementBadgePreview()
        if (!signedIn || rows.isEmpty()) {
            Surface(color = Navy900, shape = SteppedFrameShape,
                border = BorderStroke(1.dp, Navy700), modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(if (!signedIn) R.string.backend_login_required else R.string.backend_empty),
                    color = Muted, modifier = Modifier.padding(24.dp),
                    style = MaterialTheme.typography.bodyMedium)
            }
        }
        rows.forEach { row ->
            Surface(color = Navy900, modifier = Modifier.fillMaxWidth(), shape = SteppedFrameShape,
                border = BorderStroke(1.dp, if (row.isRead) Navy700 else Signal.copy(alpha = 0.5f))) {
                Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (!row.isRead) Box(Modifier.size(8.dp).background(Signal))
                    Text(row.title, color = Ice, style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold)
                    Text(row.detail, color = Muted, style = MaterialTheme.typography.bodyMedium)
                    if (!row.isRead && onRead != null) {
                        OutlinedButton(onClick = { onRead(row.id) }, shape = SteppedFrameShape,
                            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                            border = BorderStroke(1.dp, Signal.copy(alpha = 0.5f)),
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = Signal)) {
                            Text(stringResource(R.string.backend_mark_read),
                                fontFamily = FontFamily(Font(R.font.quest_pixel)),
                                fontSize = 10.sp, letterSpacing = 1.sp)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AchievementBadgePreview() {
    Surface(color = Navy900, shape = SteppedFrameShape,
        border = BorderStroke(1.dp, Navy700), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(stringResource(R.string.badge_preview_label), color = Muted,
                style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace,
                letterSpacing = 1.sp)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                listOf(R.string.badge_preview_first, R.string.badge_preview_observer,
                    R.string.badge_preview_guardian).forEachIndexed { index, label ->
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Surface(shape = SteppedFrameShape,
                            color = Signal.copy(alpha = if (index == 0) 0.12f else 0.03f),
                            border = BorderStroke(1.dp, if (index == 0) Signal else Navy700)) {
                            Image(painterResource(R.drawable.nav_achievement_pixel), contentDescription = null,
                                modifier = Modifier.padding(12.dp).size(48.dp),
                                alpha = if (index == 0) 1f else 0.35f)
                        }
                        Text(stringResource(label), color = if (index == 0) Ice else Muted,
                            style = MaterialTheme.typography.labelMedium,
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                    }
                }
            }
        }
    }
}
