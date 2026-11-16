package dev.alethia.mobile

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private val PanelShape = RoundedCornerShape(14.dp)
private val FieldShape = RoundedCornerShape(8.dp)
private val Slate = Color(0xFF0C1A2B)

private data class BadgeDefinition(val code: String, val title: Int, val requirement: Int, val target: Int, val icon: String)

private val badgeCatalog = listOf(
    BadgeDefinition("module_courier_sms", R.string.badge_courier, R.string.badge_module_requirement, 1, "✉"),
    BadgeDefinition("module_social_engineering", R.string.badge_social, R.string.badge_module_requirement, 1, "◎"),
    BadgeDefinition("module_executable_file", R.string.badge_document, R.string.badge_module_requirement, 1, "▣"),
    BadgeDefinition("first_report", R.string.badge_first_report, R.string.badge_report_requirement, 1, "✎"),
    BadgeDefinition("report_contributor", R.string.badge_reporter, R.string.badge_report_requirement, 3, "✎"),
    BadgeDefinition("report_analyst", R.string.badge_analyst, R.string.badge_report_requirement, 5, "⌕"),
    BadgeDefinition("approved_report", R.string.badge_approved_report, R.string.badge_approved_requirement, 1, "✓"),
    BadgeDefinition("first_investigation", R.string.badge_investigation, R.string.badge_investigation_requirement, 1, "⌕"),
    BadgeDefinition("streak_7", R.string.badge_streak, R.string.badge_streak_requirement, 7, "✦"),
    BadgeDefinition("level_3", R.string.badge_level_three, R.string.badge_level_requirement, 3, "★"),
    BadgeDefinition("level_5", R.string.badge_level_five, R.string.badge_level_requirement, 5, "★"),
)

@Composable
fun ProfileTopBar(language: String, onLanguageChange: (String) -> Unit, onBack: () -> Unit) {
    Surface(color = Navy950, border = BorderStroke(1.dp, Navy700)) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                AlethiaLogo(Modifier.size(34.dp))
                Text(stringResource(R.string.brand_name), color = Ice, fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Bold, letterSpacing = 1.2.sp, fontSize = 18.sp)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack) { Text("← ${stringResource(R.string.back)}", color = Muted) }
                LanguageMenu(language, onLanguageChange)
            }
        }
    }
}

@Composable
private fun Panel(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Surface(
        color = Navy900, shape = PanelShape, border = BorderStroke(1.dp, Navy700),
        modifier = modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) { content() }
    }
}

@Composable
private fun Eyebrow(label: String) {
    Text(label, color = Signal, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold, fontSize = 11.sp, letterSpacing = 1.5.sp)
}

@Composable
private fun SectionHeading(eyebrow: String, title: String, description: String? = null) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Eyebrow(eyebrow)
        Text(title, color = Ice, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        if (description != null) Text(description, color = Muted, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun Avatar(name: String, modifier: Modifier = Modifier) {
    val initials = name.trim().split(' ').filter { it.isNotEmpty() }.take(2).joinToString("") { it.first().uppercase() }.ifBlank { "A" }
    Surface(shape = CircleShape, color = Slate, border = BorderStroke(1.dp, Signal.copy(alpha = 0.55f)), modifier = modifier.size(64.dp)) {
        Box(contentAlignment = Alignment.Center) {
            Text(initials, color = Signal, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold, fontSize = 23.sp)
        }
    }
}

@Composable
private fun ProfileMessage(message: Int?) {
    if (message == null) return
    val success = message == R.string.profile_saved
    Surface(color = if (success) Signal.copy(alpha = 0.12f) else Warning.copy(alpha = 0.12f),
        shape = FieldShape, border = BorderStroke(1.dp, if (success) Signal else Warning), modifier = Modifier.fillMaxWidth()) {
        Text(stringResource(message), color = if (success) Signal else Warning, modifier = Modifier.padding(12.dp))
    }
}

@Composable
fun ProfileScreen(
    profile: ProfileState?, busy: Boolean, message: Int?,
    onEdit: () -> Unit, onBadge: (String) -> Unit, onSignOut: () -> Unit,
) {
    Eyebrow(stringResource(R.string.profile_eyebrow))
    Text(stringResource(R.string.profile_title), color = Ice, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
    Text(stringResource(R.string.profile_intro), color = Muted, style = MaterialTheme.typography.bodyMedium)
    ProfileMessage(message)

    if (profile == null) {
        Panel { Text(stringResource(R.string.profile_sign_in_required), color = Muted) }
    } else {
        ProfileHero(profile, busy, onEdit)
        ProfileStats(profile)
        EquippedBadges(profile)
        BadgeCollection(profile, busy, onBadge)
        OutlinedButton(onClick = onSignOut, enabled = !busy, modifier = Modifier.fillMaxWidth().testTag("sign_out"),
            border = BorderStroke(1.dp, Warning.copy(alpha = 0.65f)), shape = FieldShape) {
            Text(stringResource(R.string.backend_sign_out), color = Warning)
        }
    }
}

@Composable
private fun ProfileHero(profile: ProfileState, busy: Boolean, onEdit: () -> Unit) {
    Panel {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Avatar(profile.displayName)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Eyebrow(stringResource(R.string.profile_level_label, profile.level))
                Text(profile.displayName, color = Ice, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                Text("@${profile.username}", color = Muted, fontFamily = FontFamily.Monospace)
            }
        }
        val thresholds = listOf(0, 60, 150, 300, 550)
        val floor = thresholds[(profile.level - 1).coerceIn(0, 4)]
        val next = thresholds.getOrNull(profile.level)
        Surface(color = Slate, shape = FieldShape, border = BorderStroke(1.dp, Navy700), modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(stringResource(R.string.profile_progress_label), color = Muted, fontFamily = FontFamily.Monospace, fontSize = 11.sp)
                    Text(stringResource(R.string.profile_points_short, profile.points), color = Ice, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
                }
                LinearProgressIndicator(
                    progress = { if (next == null) 1f else ((profile.points - floor).toFloat() / (next - floor)).coerceIn(0f, 1f) },
                    color = Signal, trackColor = Navy700, modifier = Modifier.fillMaxWidth().height(6.dp),
                )
                Text(if (next == null) stringResource(R.string.profile_max_level) else stringResource(R.string.profile_next_level, (next - profile.points).coerceAtLeast(0)),
                    color = Muted, style = MaterialTheme.typography.bodySmall)
            }
        }
        Button(onClick = onEdit, enabled = !busy, modifier = Modifier.fillMaxWidth().testTag("open_edit_profile"),
            colors = ButtonDefaults.buttonColors(containerColor = Signal, contentColor = Navy950), shape = FieldShape) {
            Text(stringResource(R.string.profile_edit), fontWeight = FontWeight.Bold)
        }
    }
}

@Composable
private fun ProfileStats(profile: ProfileState) {
    val masteryLabel = when (profile.mastery) {
        "familiar" -> R.string.profile_mastery_familiar
        "skilled" -> R.string.profile_mastery_skilled
        "needs_practice" -> R.string.profile_mastery_practice
        else -> R.string.profile_mastery_not_started
    }
    Panel {
        SectionHeading(stringResource(R.string.profile_progress_eyebrow), stringResource(R.string.profile_statistics))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            StatTile("✦", profile.dailyCurrent.toString(), stringResource(R.string.profile_daily_label),
                stringResource(R.string.profile_best, profile.dailyLongest), Modifier.weight(1f))
            StatTile("▣", profile.practiceCurrent.toString(), stringResource(R.string.profile_practice_label),
                stringResource(R.string.profile_best, profile.practiceLongest), Modifier.weight(1f))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            StatTile("✓", profile.modulesCompleted.toString(), stringResource(R.string.profile_modules_label),
                null, Modifier.weight(1f))
            StatTile("★", stringResource(masteryLabel), stringResource(R.string.profile_mastery_label),
                null, Modifier.weight(1f))
        }
    }
}

@Composable
private fun StatTile(icon: String, value: String, label: String, detail: String?, modifier: Modifier) {
    Surface(color = Slate, shape = FieldShape, border = BorderStroke(1.dp, Navy700), modifier = modifier) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(icon, color = Signal, fontSize = 16.sp)
            Text(value, color = Ice, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.titleSmall, maxLines = 2)
            Text(label, color = Muted, style = MaterialTheme.typography.labelSmall)
            if (detail != null) Text(detail, color = Signal, style = MaterialTheme.typography.labelSmall)
        }
    }
}

@Composable
private fun EquippedBadges(profile: ProfileState) {
    Panel {
        SectionHeading(stringResource(R.string.profile_showcase_eyebrow), stringResource(R.string.profile_equipped_title),
            stringResource(R.string.profile_equipped_description))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            val selected = profile.equippedBadges.sorted().take(3)
            repeat(3) { index ->
                val code = selected.getOrNull(index)
                val badge = badgeCatalog.firstOrNull { it.code == code }
                Surface(color = if (code == null) Navy950 else Signal.copy(alpha = 0.10f),
                    border = BorderStroke(1.dp, if (code == null) Navy700 else Signal.copy(alpha = 0.65f)),
                    shape = FieldShape, modifier = Modifier.weight(1f).height(88.dp)) {
                    Column(Modifier.padding(8.dp), horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center) {
                        Text(if (code == null) "+" else badge?.icon ?: "★", color = if (code == null) Muted else Signal, fontSize = 23.sp)
                        Text(if (code == null) stringResource(R.string.profile_empty_badge) else badge?.let { stringResource(it.title) } ?: code.replace('_', ' '),
                            color = if (code == null) Muted else Ice, style = MaterialTheme.typography.labelSmall, maxLines = 2)
                    }
                }
            }
        }
    }
}

@Composable
private fun BadgeCollection(profile: ProfileState, busy: Boolean, onBadge: (String) -> Unit) {
    Panel {
        SectionHeading(stringResource(R.string.profile_collection_eyebrow), stringResource(R.string.profile_badges),
            stringResource(R.string.profile_badge_hint))
        val unlockedCount = badgeCatalog.count { it.code in profile.unlockedBadges }
        Text(stringResource(R.string.profile_badge_count, unlockedCount, badgeCatalog.size),
            color = Signal, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
        badgeCatalog.chunked(2).forEach { pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                pair.forEach { badge ->
                    BadgeTile(badge, profile, busy, onBadge, Modifier.weight(1f))
                }
                if (pair.size == 1) Box(Modifier.weight(1f))
            }
        }
        profile.unlockedBadges.filterNot { code -> badgeCatalog.any { it.code == code } }.sorted().forEach { code ->
            val equipped = code in profile.equippedBadges
            Row(Modifier.fillMaxWidth().testTag("badge_item_$code"), verticalAlignment = Alignment.CenterVertically) {
                Text(code.replace('_', ' '), color = Ice, modifier = Modifier.weight(1f))
                TextButton(onClick = { onBadge(code) }, enabled = !busy, modifier = Modifier.testTag("equipped_badge_$code")) {
                    Text(stringResource(if (equipped) R.string.profile_unequip else R.string.profile_equip))
                }
            }
        }
    }
}

@Composable
private fun BadgeTile(badge: BadgeDefinition, profile: ProfileState, busy: Boolean, onBadge: (String) -> Unit, modifier: Modifier) {
    val unlocked = badge.code in profile.unlockedBadges
    val equipped = badge.code in profile.equippedBadges
    val progress = when (badge.code) {
        "first_report", "report_contributor", "report_analyst" -> profile.reportCount
        "approved_report" -> profile.approvedReportCount
        "first_investigation" -> profile.investigationCount
        "streak_7" -> profile.dailyLongest
        "level_3", "level_5" -> profile.level
        else -> if (unlocked) 1 else 0
    }.coerceAtMost(badge.target)
    Surface(color = if (equipped) Signal.copy(alpha = 0.10f) else Slate, shape = FieldShape,
        border = BorderStroke(1.dp, if (equipped) Signal else Navy700), modifier = modifier.testTag("badge_item_${badge.code}")) {
        Column(Modifier.padding(11.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(badge.icon, color = if (unlocked) Signal else Muted, fontSize = 24.sp)
            Text(stringResource(badge.title), color = if (unlocked) Ice else Muted, fontWeight = FontWeight.SemiBold,
                style = MaterialTheme.typography.bodyMedium, maxLines = 2)
            Text(stringResource(badge.requirement, progress, badge.target), color = Muted,
                style = MaterialTheme.typography.labelSmall)
            LinearProgressIndicator(progress = { progress.toFloat() / badge.target },
                color = if (unlocked) Signal else Muted, trackColor = Navy700,
                modifier = Modifier.fillMaxWidth().height(3.dp))
            if (unlocked) {
                TextButton(onClick = { onBadge(badge.code) }, enabled = !busy,
                    modifier = Modifier.testTag("equipped_badge_${badge.code}")) {
                    Text(stringResource(if (equipped) R.string.profile_unequip else R.string.profile_equip), color = Signal)
                }
            } else {
                Text(stringResource(R.string.profile_locked), color = Muted, style = MaterialTheme.typography.labelSmall)
            }
        }
    }
}

@Composable
fun EditProfileScreen(profile: ProfileState?, busy: Boolean, message: Int?, onSave: (String, String, String) -> Unit, onCancel: () -> Unit) {
    var name by remember(profile?.username) { mutableStateOf(profile?.displayName.orEmpty()) }
    var password by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    var showPassword by remember { mutableStateOf(false) }
    Eyebrow(stringResource(R.string.profile_account_eyebrow))
    Text(stringResource(R.string.profile_edit), color = Ice, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
    Text(stringResource(R.string.profile_edit_intro), color = Muted, style = MaterialTheme.typography.bodyMedium)
    ProfileMessage(message)

    Panel {
        SectionHeading(stringResource(R.string.profile_identity_eyebrow), stringResource(R.string.profile_identity_title),
            stringResource(R.string.profile_identity_description))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Avatar(name, Modifier.size(54.dp))
            Column {
                Text(name.ifBlank { profile?.username.orEmpty() }, color = Ice, fontWeight = FontWeight.Bold)
                Text("@${profile?.username.orEmpty()}", color = Muted, fontFamily = FontFamily.Monospace)
            }
        }
        OutlinedTextField(value = name, onValueChange = { name = it.take(32) },
            label = { Text(stringResource(R.string.profile_display_name)) }, singleLine = true,
            supportingText = { Text(stringResource(R.string.profile_name_count, name.trim().length)) },
            enabled = !busy, shape = FieldShape, modifier = Modifier.fillMaxWidth().testTag("edit_name_field"))
    }

    Panel {
        SectionHeading(stringResource(R.string.profile_security_eyebrow), stringResource(R.string.profile_password_title),
            stringResource(R.string.profile_password_optional))
        OutlinedTextField(value = password, onValueChange = { password = it },
            label = { Text(stringResource(R.string.profile_new_password)) }, singleLine = true, enabled = !busy,
            visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
            trailingIcon = {
                IconButton(onClick = { showPassword = !showPassword }) {
                    Icon(painter = painterResource(if (showPassword) R.drawable.alethia_eye_open else R.drawable.alethia_eye_closed),
                        contentDescription = stringResource(if (showPassword) R.string.auth_hide_password else R.string.auth_show_password),
                        tint = Signal)
                }
            },
            shape = FieldShape, modifier = Modifier.fillMaxWidth().testTag("edit_password_field"))
        OutlinedTextField(value = confirmation, onValueChange = { confirmation = it },
            label = { Text(stringResource(R.string.auth_confirm_password)) }, singleLine = true, enabled = !busy,
            visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
            shape = FieldShape, modifier = Modifier.fillMaxWidth().testTag("edit_confirm_password_field"))
        Text(stringResource(R.string.profile_password_rule), color = Muted, style = MaterialTheme.typography.bodySmall)
    }

    Button(onClick = { onSave(name, password, confirmation) }, enabled = !busy && profile != null,
        colors = ButtonDefaults.buttonColors(containerColor = Signal, contentColor = Navy950),
        shape = FieldShape, modifier = Modifier.fillMaxWidth().height(52.dp).testTag("save_profile")) {
        Text(stringResource(if (busy) R.string.auth_loading else R.string.profile_save), fontWeight = FontWeight.Bold)
    }
    OutlinedButton(onClick = onCancel, enabled = !busy, shape = FieldShape, modifier = Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.profile_cancel), color = Ice)
    }
}
