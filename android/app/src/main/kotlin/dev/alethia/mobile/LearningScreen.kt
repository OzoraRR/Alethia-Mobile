package dev.alethia.mobile

import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.alethia.core.*
import org.json.JSONObject

internal class LearningCopy(private val context: Context) {
    val content: JSONObject = context.assets.open("learning/${if (context.resources.configuration.locales[0].language == "en") "en" else "id"}.json")
        .bufferedReader().use { JSONObject(it.readText()) }
    fun t(id: Int, vararg args: Any): String = context.getString(id, *args)
    fun title(module: ModuleId) = t(when (module) {
        ModuleId.CourierSms -> R.string.learn_title_sms
        ModuleId.SocialEngineering -> R.string.learn_title_social
        ModuleId.ExecutableFile -> R.string.learn_title_file
    })
    val social get() = content.getJSONObject("socialEngineering")
    val file get() = content.getJSONObject("executableFile")
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LearningScreen(
    model: LearningViewModel,
    onExit: () -> Unit,
    onAccountChanged: () -> Unit,
    language: String,
    onLanguageChange: (String) -> Unit,
) {
    val ui by model.ui.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val copy = remember(context) { LearningCopy(context) }
    val session = ui.session
    val state = session?.state
    var exitOpen by remember { mutableStateOf(false) }
    var detail by remember { mutableStateOf<Pair<String, String>?>(null) }
    val scroll = rememberScrollState()
    LaunchedEffect(state?.module, state?.stage) { scroll.scrollTo(0); detail = null }
    BackHandler { if (ui.busy) return@BackHandler else exitOpen = true }
    val steps = if (state?.module == ModuleId.SocialEngineering)
        listOf(R.string.learn_select, R.string.learn_extract, R.string.learn_pretext, R.string.learn_mitigate, R.string.learn_learn)
        else listOf(R.string.learn_observe, R.string.learn_inspect, R.string.learn_verify, R.string.learn_decide, R.string.learn_learn)
    Scaffold(
        containerColor = Navy950,
        topBar = {
            Column(Modifier.statusBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    TextButton(shape = SteppedFrameShape, onClick = { exitOpen = true }, enabled = !ui.busy, modifier = Modifier.testTag("lesson_exit")) { Text("‹ " + copy.t(R.string.learn_exit)) }
                    Text(state?.module?.let(copy::title).orEmpty(), color = Ice, style = MaterialTheme.typography.titleSmall,
                        modifier = Modifier.weight(1f).padding(start = 8.dp))
                    LanguageMenu(language, onLanguageChange)
                }
                if (state != null && state.stage in 1..5) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        steps.forEachIndexed { index, _ -> Box(Modifier.weight(1f).height(3.dp)
                            .background(if (index < state.stage) Signal else Navy700)) }
                    }
                    Text(copy.t(R.string.learn_step, state.stage, 5) + " · " + copy.t(steps[state.stage - 1]),
                        color = Signal, fontFamily = FontFamily.Monospace, fontSize = 11.sp)
                }
            }
        },
        bottomBar = {
            Column(Modifier.navigationBarsPadding().imePadding().background(Navy950).padding(horizontal = 24.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp)) {
                if (state != null) {
                    Text(copy.t(when {
                        !ui.signedIn -> R.string.learn_local
                        ui.saveFailed -> R.string.learn_save_failed
                        session.dirty -> R.string.learn_saving
                        else -> R.string.learn_saved
                    }), color = if (ui.saveFailed) Warning else Muted, fontSize = 11.sp)
                    if (ui.saveFailed) TextButton(shape = SteppedFrameShape, onClick = model::retrySave, enabled = !ui.busy) { Text(copy.t(R.string.learn_retry)) }
                    if (state.stage < 6) LessonButton(
                        label = copy.t(when (state.stage) { 0 -> R.string.learn_start; 4 -> R.string.learn_choose; 5 -> R.string.learn_finish; else -> R.string.learn_next }),
                        tag = if (state.stage == 5) "complete_practice" else "lesson_next",
                        enabled = state.canAdvance && !ui.busy,
                        onClick = { if (state.stage == 5) model.complete(onAccountChanged) else model.change { it.advance() } },
                    ) else LessonButton(copy.t(R.string.learn_leave), "lesson_roadmap", !ui.busy, onExit)
                }
            }
        },
    ) { insets ->
        Column(Modifier.fillMaxSize().padding(insets).consumeWindowInsets(insets).verticalScroll(scroll)
            .padding(horizontal = 24.dp, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            if (ui.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (ui.failed) {
                Text(copy.t(R.string.learn_error), color = Warning)
                if (state != null) TextButton(shape = SteppedFrameShape, onClick = {
                    if (state.stage == 5) model.complete(onAccountChanged)
                    else if (state.stage == 6) model.retrySave()
                    else model.open(state.module)
                }, enabled = !ui.busy) { Text(copy.t(R.string.learn_retry)) }
                else {
                    TextButton(shape = SteppedFrameShape, onClick = { ui.requestedModule?.let { model.open(it) } }, enabled = !ui.busy) { Text(copy.t(R.string.learn_retry)) }
                    LessonButton(copy.t(R.string.learn_leave), "lesson_failed_back", !ui.busy, onExit)
                }
            }
            if (state != null) {
                if (state.stage == 6) LessonResult(session, copy, ui.signedIn, !ui.busy) { model.open(state.module, restart = true) }
                else {
                    Text(copy.t(R.string.learn_safe_note), color = Muted, fontSize = 10.sp, fontFamily = FontFamily.Monospace)
                    when (state.module) {
                        ModuleId.CourierSms -> CourierLesson(state, copy, model::change, { detail = it })
                        ModuleId.SocialEngineering -> SocialLesson(state, copy, model::change)
                        ModuleId.ExecutableFile -> FileLesson(state, copy, model::change, { detail = it })
                    }
                }
            }
        }
    }
    detail?.let { (title, value) ->
        ModalBottomSheet(onDismissRequest = { detail = null }, containerColor = Navy900) {
            Column(Modifier.fillMaxWidth().padding(24.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(title, color = Ice, style = MaterialTheme.typography.titleLarge)
                EvidenceLine(title, value, copy)
                if (state?.module == ModuleId.ExecutableFile) Text(copy.file.getJSONObject("inspect").getString("note"), color = Muted)
                TextButton(shape = SteppedFrameShape, onClick = { detail = null }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(copy.t(R.string.checkpoint_close)) }
            }
        }
    }
    if (exitOpen) {
        val title = copy.t(R.string.learn_exit_title)
        val body = copy.t(R.string.learn_exit_body)
        AlertDialog(onDismissRequest = { exitOpen = false }, title = { Text(title) }, text = { Text(body) },
            confirmButton = { TextButton(shape = SteppedFrameShape, onClick = { exitOpen = false; onExit() }, modifier = Modifier.testTag("lesson_confirm_exit")) { Text(copy.t(R.string.learn_leave)) } },
            dismissButton = { TextButton(shape = SteppedFrameShape, onClick = { exitOpen = false }) { Text(copy.t(R.string.learn_stay)) } }, containerColor = Navy900)
    }
}

@Composable
private fun LessonPanel(title: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Surface(color = Navy900, shape = SteppedFrameShape, border = BorderStroke(1.dp, Color(0xFF2A4141)),
        modifier = Modifier.fillMaxWidth().gameFrame(strength = 0.5f)) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (title != null) Text(title, color = Ice, style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold, modifier = Modifier.semantics { heading() })
            content()
        }
    }
}

@Composable
private fun LessonButton(label: String, tag: String, enabled: Boolean = true, onClick: () -> Unit) {
    Button(onClick = onClick, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).testTag(tag),
        shape = SteppedFrameShape, colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF83AE39), contentColor = Navy950)) {
        Text(label, fontFamily = FontFamily(Font(R.font.quest_pixel)), fontSize = 10.sp, lineHeight = 17.sp)
    }
}

@Suppress("DEPRECATION")
@Composable
private fun EvidenceLine(label: String, value: String, copy: LearningCopy) {
    val clipboard = LocalClipboardManager.current
    var copied by remember(value) { mutableStateOf(false) }
    LaunchedEffect(copied) { if (copied) { kotlinx.coroutines.delay(1600); copied = false } }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(label, color = Muted, style = MaterialTheme.typography.labelSmall)
            androidx.compose.foundation.text.selection.SelectionContainer {
                Text(value, color = Ice, style = MaterialTheme.typography.bodyMedium)
            }
        }
        TextButton(shape = SteppedFrameShape, onClick = { clipboard.setText(AnnotatedString(value)); copied = true },
            modifier = Modifier.heightIn(min = 48.dp).semantics { contentDescription = copy.t(R.string.learn_copy) + " " + label }.testTag("copy_${if (value == CourierEvidence.sender) "sender" else if (value == CourierEvidence.trackingNumber) "tracking" else "evidence"}")) {
            Text(copy.t(if (copied) R.string.learn_copied else R.string.learn_copy), fontSize = 11.sp)
        }
    }
}

@Suppress("DEPRECATION")
@Composable
private fun EvidenceInput(value: String, label: String, tag: String, copy: LearningCopy, onChange: (String) -> Unit) {
    val clipboard = LocalClipboardManager.current
    OutlinedTextField(value = value, onValueChange = { onChange(it.take(300)) }, label = { Text(label) },
        modifier = Modifier.fillMaxWidth().testTag(tag), shape = SteppedFrameShape, singleLine = true,
        trailingIcon = { TextButton(shape = SteppedFrameShape, onClick = { clipboard.getText()?.text?.let(onChange) }, modifier = Modifier.semantics { contentDescription = copy.t(R.string.learn_paste) + " " + label }.testTag("paste_$tag")) {
            Text(copy.t(R.string.learn_paste), fontSize = 11.sp)
        } })
}

@Composable
private fun ChoiceRow(label: String, selected: Boolean, tag: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().background(if (selected) Color(0xFF1D3224) else Navy900, SteppedFrameShape)
        .border(1.dp, if (selected) Signal else Navy700, SteppedFrameShape)
        .selectable(selected = selected, role = Role.RadioButton, onClick = onClick).testTag(tag).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        RadioButton(selected = selected, onClick = null)
        Text(label, color = Ice, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun SmsMessage(copy: LearningCopy) {
    LessonPanel(copy.title(ModuleId.CourierSms)) {
        EvidenceLine(copy.t(R.string.learn_sender), CourierEvidence.sender, copy)
        Text(copy.t(R.string.learn_sms_body), color = Ice, lineHeight = 24.sp)
        EvidenceLine(copy.t(R.string.learn_link), CourierEvidence.defangedLink, copy)
        EvidenceLine(copy.t(R.string.learn_tracking), CourierEvidence.trackingNumber, copy)
    }
}

@Composable
private fun CourierLesson(s: LearningState, copy: LearningCopy, change: ((LearningState) -> LearningState) -> Unit, detail: (Pair<String, String>) -> Unit) {
    when (s.stage) {
        0 -> { Text(copy.t(R.string.learn_observe_hint), color = Muted) }
        1 -> { Text(copy.t(R.string.learn_observe_hint), color = Muted); SmsMessage(copy) }
        2 -> {
            Text(copy.t(R.string.learn_inspect_hint), color = Muted)
            SmsMessage(copy)
            EvidenceInput(s.senderInput, copy.t(R.string.learn_sender), "sender_input", copy) { value -> change { if (it.senderInput == value) it else it.copy(senderInput = value, compared = false, sender = null, link = null) } }
            EvidenceInput(s.linkInput, copy.t(R.string.learn_link), "link_input", copy) { value -> change { if (it.linkInput == value) it else it.copy(linkInput = value, compared = false, sender = null, link = null) } }
            LessonButton(copy.t(R.string.learn_compare), "compare_evidence", s.senderInput.isNotBlank() && s.linkInput.isNotBlank()) { change { it.compare() } }
            if (s.compared) {
                Text(copy.t(R.string.learn_sender) + " · " + copy.t(if (CourierEvidence.matchesSender(s.senderInput)) R.string.learn_match else R.string.learn_mismatch), color = Muted)
                Text(copy.t(R.string.learn_link) + " · " + copy.t(if (CourierEvidence.matchesLink(s.linkInput)) R.string.learn_match else R.string.learn_mismatch), color = Muted)
                Text(copy.t(R.string.learn_sender_assess), color = Ice)
                ChoiceRow(copy.t(R.string.learn_unverified), s.sender == SenderAssessment.Unverified, "sender_unverified") { change { it.assessSender(SenderAssessment.Unverified) } }
                ChoiceRow(copy.t(R.string.learn_trusted), s.sender == SenderAssessment.Trusted, "sender_trusted") { change { it.assessSender(SenderAssessment.Trusted) } }
                Text(copy.t(R.string.learn_link_assess), color = Ice)
                ChoiceRow(copy.t(R.string.learn_suspicious), s.link == LinkAssessment.Suspicious, "link_suspicious") { change { it.assessLink(LinkAssessment.Suspicious) } }
                ChoiceRow(copy.t(R.string.learn_trusted), s.link == LinkAssessment.Trusted, "link_trusted") { change { it.assessLink(LinkAssessment.Trusted) } }
            }
        }
        3 -> LessonPanel(copy.t(R.string.learn_official_title)) {
            Text(copy.t(R.string.learn_official_note), color = Muted)
            TextButton(shape = SteppedFrameShape, onClick = { detail(copy.t(R.string.learn_tracking) to CourierEvidence.trackingNumber) }) { Text(copy.t(R.string.learn_read_message)) }
            EvidenceInput(s.trackingInput, copy.t(R.string.learn_tracking), "tracking_input", copy) { value -> change { if (it.trackingInput == value) it else it.copy(trackingInput = value, checked = false) } }
            LessonButton(copy.t(R.string.learn_check_tracking), "check_tracking", s.trackingInput.isNotBlank()) { change { it.checkOfficial() } }
            if (s.checked) Text(copy.t(R.string.learn_tracking_found), color = Signal)
            else if (s.trackingInput.isNotBlank() && !s.trackingInput.trim().equals(CourierEvidence.trackingNumber, true)) Text(copy.t(R.string.learn_tracking_invalid), color = Muted)
        }
        4 -> {
            Text(copy.t(R.string.learn_choice_hint), color = Muted)
            listOf("open_link" to R.string.learn_open_link, "verify_official_channel" to R.string.learn_official_choice,
                "report_delete" to R.string.learn_report_delete).forEach { (id, label) ->
                ChoiceRow(copy.t(label), s.choice == id, "choose_$id") { change { it.choose(id) } }
            }
        }
        5 -> {
            ImpactPanel(s, copy)
            ExpandText(copy.t(R.string.learn_attacker), copy.t(R.string.learn_attacker_sms))
        }
    }
}

@Composable
private fun SocialLesson(s: LearningState, copy: LearningCopy, change: ((LearningState) -> LearningState) -> Unit) {
    val c = copy.social
    val artifacts = c.getJSONObject("board").getJSONArray("artifacts")
    val selected = (0 until artifacts.length()).map { artifacts.getJSONObject(it) }.filter { it.getString("id") in s.artifacts }
    val pairings = c.getJSONObject("pairings")
    val pairs = buildList {
        LearningState.artifactIds.forEachIndexed { i, first -> LearningState.artifactIds.drop(i + 1).forEach { second ->
            if (first in s.artifacts && second in s.artifacts) add(pairings.getJSONObject("${first}_$second"))
        } }
    }
    when (s.stage) {
        0 -> Text(c.getString("description"), color = Muted)
        1 -> {
            Text(c.getJSONObject("board").getString("description"), color = Muted)
            Text(copy.t(R.string.learn_selected, s.artifacts.size), color = Signal)
            for (i in 0 until artifacts.length()) {
                val item = artifacts.getJSONObject(i)
                val id = item.getString("id")
                Surface(shape = SteppedFrameShape, color = if (id in s.artifacts) Color(0xFF1D3224) else Navy900,
                    border = BorderStroke(1.dp, if (id in s.artifacts) Signal else Navy700),
                    modifier = Modifier.fillMaxWidth().selectable(selected = id in s.artifacts, role = Role.Checkbox,
                        onClick = { change { it.toggleArtifact(id) } }).testTag("artifact_$id")) {
                    Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(checked = id in s.artifacts, onCheckedChange = null)
                        Column(Modifier.weight(1f).padding(start = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(item.getString("clue"), color = Signal, style = MaterialTheme.typography.labelSmall)
                            Text(item.getString("title"), color = Ice, fontWeight = FontWeight.SemiBold)
                            Text(item.getString("value"), color = Muted, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
        }
        2 -> {
            Text(c.getJSONObject("extraction").getString("description"), color = Muted)
            selected.forEach { item -> LessonPanel(item.getString("title")) { Text(item.getString("exposure"), color = Ice) } }
            pairs.forEach { pair -> ExpandText(pair.getString("title"), pair.getString("extraction")) }
        }
        3 -> {
            Text(c.getJSONObject("pretext").getString("description"), color = Muted)
            pairs.forEach { pair -> LessonPanel(pair.getString("title")) { Text(pair.getString("pretext"), color = Ice, lineHeight = 24.sp) } }
        }
        4 -> {
            Text(c.getJSONObject("mitigation").getString("description"), color = Muted)
            selected.forEach { item -> ExpandText(item.getString("title"), item.getString("mitigation")) }
            val options = c.getJSONObject("mitigation").getJSONArray("options")
            for (i in 0 until options.length()) {
                val option = options.getJSONObject(i)
                ChoiceRow(option.getString("label") + "\n" + option.getString("description"),
                    s.mitigation == option.getString("id"), "mitigation_${option.getString("id")}") { change { it.mitigate(option.getString("id")) } }
            }
        }
        5 -> {
            LessonPanel(c.getJSONObject("complete").getString("title")) { Text(c.getJSONObject("complete").getString("description"), color = Ice) }
            pairs.forEach { pair -> ExpandText(pair.getString("title"), pair.getString("mitigation")) }
        }
    }
}

@Composable
private fun FileLesson(s: LearningState, copy: LearningCopy, change: ((LearningState) -> LearningState) -> Unit, detail: (Pair<String, String>) -> Unit) {
    val c = copy.file
    val scenario = c.getJSONObject("scenario")
    val labels = c.getJSONObject("inspect")
    val fields = listOf("source" to "sender", "filename" to "fileName", "extension" to "extension", "link" to "link")
    fun fieldLabel(id: String) = labels.getString(if (id == "filename") "file" else id)
    when (s.stage) {
        0 -> Text(c.getString("description"), color = Muted)
        1, 2 -> {
            LessonPanel(c.getString("recipient")) {
                EvidenceLine(copy.t(R.string.learn_sender), scenario.getString("sender"), copy)
                Text(scenario.getString("message"), color = Ice, lineHeight = 24.sp)
                Row(Modifier.fillMaxWidth().background(Navy950, SteppedFrameShape).padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Canvas(Modifier.size(32.dp)) {
                        val cell = size.width / 12f
                        val pixels = listOf("..######....", "..#....##...", "..#....###..", "..#....###..", "..#......#..", "..#.####.#..", "..#......#..", "..#.####.#..", "..#......#..", "..#.###..#..", "..#......#..", "..########..")
                        pixels.forEachIndexed { y, row -> row.forEachIndexed { x, pixel ->
                            if (pixel == '#') drawRect(Signal, androidx.compose.ui.geometry.Offset(x * cell, y * cell), androidx.compose.ui.geometry.Size(cell, cell))
                        } }
                    }
                    Text(scenario.getString("fileName"), color = Ice, modifier = Modifier.weight(1f))
                }
            }
            if (s.stage == 2) {
                Text(copy.t(R.string.learn_file_requirement, s.inspected.size), color = Muted)
                fields.forEach { (id, key) ->
                    OutlinedButton(onClick = { change { it.inspect(id) }; detail(fieldLabel(id) to scenario.getString(key)) },
                        modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).testTag("inspect_$id"), shape = SteppedFrameShape) {
                        Text((if (id in s.inspected) "✓  " else "+  ") + fieldLabel(id), modifier = Modifier.weight(1f))
                        Text("↗")
                    }
                }
            }
        }
        3 -> LessonPanel(copy.t(R.string.learn_official_title)) {
            Text(c.getJSONObject("verify").getString("description"), color = Muted)
            LessonButton(copy.t(R.string.learn_open_official), "file_check_official") { change { it.checkOfficial() } }
            if (s.checked) {
                Text(c.getJSONObject("verify").getString("resultTitle"), color = Signal, fontWeight = FontWeight.Bold)
                Text(c.getJSONObject("verify").getString("resultBody"), color = Ice)
            }
        }
        4 -> {
            Text(copy.t(R.string.learn_choice_hint), color = Muted)
            listOf("open" to R.string.learn_file_open, "verify" to R.string.learn_file_verify, "ignore" to R.string.learn_file_ignore,
                "report" to R.string.learn_file_report).forEach { (id, label) -> ChoiceRow(copy.t(label), s.choice == id, "choose_$id") { change { it.choose(id) } } }
        }
        5 -> {
            ImpactPanel(s, copy)
            ExpandText(c.getJSONObject("analysis").getString("why"), c.getJSONObject("analysis").getString("whyValue"))
            ExpandText(c.getJSONObject("analysis").getString("safer"), c.getJSONObject("analysis").getString("saferValue"))
        }
    }
}

@Composable
private fun ExpandText(title: String, body: String) {
    var expanded by remember(title, body) { mutableStateOf(false) }
    LessonPanel {
        TextButton(shape = SteppedFrameShape, onClick = { expanded = !expanded }, modifier = Modifier.fillMaxWidth()) {
            Text((if (expanded) "−  " else "+  ") + title, modifier = Modifier.weight(1f))
        }
        if (expanded) Text(body, color = Ice, lineHeight = 24.sp)
    }
}

@Composable
private fun ImpactPanel(s: LearningState, copy: LearningCopy) {
    val unsafe = s.choice in setOf("open_link", "open")
    LessonPanel(copy.t(R.string.learn_impact)) {
        Text(copy.t(if (unsafe) R.string.learn_unsafe else R.string.learn_safe), color = if (unsafe) Warning else Signal, fontWeight = FontWeight.Bold)
        Text(if (s.module == ModuleId.CourierSms) copy.t(if (unsafe) R.string.learn_sms_unsafe else R.string.learn_sms_safe)
            else copy.file.getJSONObject("analysis").getString(if (unsafe) "unsafe" else "safe"), color = Ice, lineHeight = 24.sp)
    }
}

@Composable
private fun LessonResult(session: LearningSession, copy: LearningCopy, signedIn: Boolean, enabled: Boolean, onRepeat: () -> Unit) {
    val s = session.state
    val result = session.result
    LessonPanel(copy.t(R.string.learn_result)) {
        if (s.module == ModuleId.SocialEngineering) Text(copy.t(R.string.learn_unscored), color = Signal, style = MaterialTheme.typography.headlineSmall)
        else Text(result?.score?.let { copy.t(R.string.learn_score, it) } ?: copy.t(R.string.learn_history), color = Signal,
            style = MaterialTheme.typography.headlineMedium, modifier = Modifier.testTag("practice_score"))
        Text(copy.t(if (s.module == ModuleId.SocialEngineering || result?.perfect == true) R.string.learn_complete else R.string.learn_needs_practice), color = Ice)
        Text(copy.t(if (signedIn) R.string.learn_server_rewards else R.string.learn_guest_rewards), color = Muted, style = MaterialTheme.typography.bodySmall)
    }
    if (s.module != ModuleId.SocialEngineering && s.choice != null) {
        val checks = if (s.module == ModuleId.CourierSms) listOf(
            R.string.learn_check_sender to (s.sender == SenderAssessment.Unverified), R.string.learn_check_link to (s.link == LinkAssessment.Suspicious),
            R.string.learn_check_verify to s.verified, R.string.learn_check_choice to (s.choice != "open_link"))
        else listOf(R.string.learn_check_file to (s.inspected.size >= 2), R.string.learn_check_verify to s.verified, R.string.learn_check_choice to (s.choice != "open"))
        LessonPanel(copy.t(R.string.learn_analysis)) { checks.forEach { (label, correct) -> Text((if (correct) "✓  " else "·  ") + copy.t(label), color = if (correct) Signal else Warning) } }
    }
    OutlinedButton(onClick = onRepeat, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("retry_practice"), shape = SteppedFrameShape) {
        Text(copy.t(R.string.learn_repeat))
    }
}
