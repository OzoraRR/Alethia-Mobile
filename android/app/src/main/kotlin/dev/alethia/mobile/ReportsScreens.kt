package dev.alethia.mobile

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Base64
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.io.ByteArrayOutputStream
import java.io.InputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun ReportsListScreen(
    state: ReportsListState,
    onRefresh: () -> Unit,
    onLoadMore: () -> Unit,
    onScope: (ReportScope) -> Unit,
    onSort: (ReportSort) -> Unit,
    onOpenReport: (String) -> Unit,
    onNewReport: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth().testTag("reports_screen"),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            text = stringResource(R.string.reports_eyebrow),
            color = Signal,
            fontFamily = FontFamily.Monospace,
            style = MaterialTheme.typography.labelSmall,
            letterSpacing = 2.sp,
        )
        Text(
            text = stringResource(R.string.reports_headline),
            color = Ice,
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
        )
        Text(
            text = stringResource(R.string.reports_description),
            color = Muted,
            style = MaterialTheme.typography.bodyMedium,
        )
        RolePill(state.role)
        Box(Modifier.fillMaxWidth().height(2.dp).background(Signal.copy(alpha = 0.35f)))

        if (!state.signedIn) {
            ReportSection(stringResource(R.string.reports_title)) {
                Text(stringResource(R.string.backend_login_required), color = Muted)
                if (state.error != null && state.error != ReportError.AuthRequired) {
                    ReportErrorText(state.error)
                }
            }
        } else {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ReportPrimaryButton(
                    onClick = onNewReport,
                    modifier = Modifier.weight(1f)
                        .heightIn(min = 48.dp)
                        .testTag("reports_add"),
                ) {
                    Text(stringResource(R.string.reports_add))
                }
                ReportTextButton(onClick = onRefresh, enabled = !state.loading) {
                    Text(
                        text = stringResource(R.string.reports_refresh),
                        style = MaterialTheme.typography.labelMedium,
                        maxLines = 1,
                    )
                }
            }

            Surface(
                color = Navy900,
                border = BorderStroke(1.dp, Navy700),
                shape = SteppedFrameShape,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(
                    modifier = Modifier.padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    ReportChoiceRow(
                        label = stringResource(R.string.reports_scope_label),
                        choices = listOf(
                            ReportChoice(
                                ReportScope.All,
                                stringResource(R.string.reports_scope_all),
                                "reports_scope_all",
                            ),
                            ReportChoice(
                                ReportScope.Mine,
                                stringResource(R.string.reports_scope_mine),
                                "reports_scope_mine",
                            ),
                        ),
                        selected = state.scope,
                        onSelect = onScope,
                    )
                    ReportChoiceRow(
                        label = stringResource(R.string.reports_sort_label),
                        choices = listOf(
                            ReportChoice(
                                ReportSort.Top,
                                stringResource(R.string.reports_sort_top),
                                "reports_sort_top",
                            ),
                            ReportChoice(
                                ReportSort.Newest,
                                stringResource(R.string.reports_sort_newest),
                                "reports_sort_newest",
                            ),
                            ReportChoice(
                                ReportSort.Oldest,
                                stringResource(R.string.reports_sort_oldest),
                                "reports_sort_oldest",
                            ),
                        ),
                        selected = state.sort,
                        onSelect = onSort,
                    )
                }
            }

            if (state.loading && state.reports.isEmpty()) {
                LinearProgressIndicator(Modifier.fillMaxWidth())
                Text(
                    text = stringResource(R.string.reports_loading),
                    color = Muted,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            ReportErrorText(state.error)
            if (!state.loading && state.error == null && state.reports.isEmpty()) {
                Surface(
                    color = Navy900,
                    border = BorderStroke(1.dp, Navy700),
                    shape = SteppedFrameShape,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 32.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        Surface(
                            color = Signal.copy(alpha = 0.08f),
                            shape = SteppedFrameShape,
                            border = BorderStroke(1.dp, Signal.copy(alpha = 0.35f)),
                        ) {
                            Text("[ / ]", color = Signal, fontFamily = FontFamily.Monospace,
                                fontSize = 26.sp, modifier = Modifier.padding(18.dp))
                        }
                        Text(
                            text = stringResource(
                                if (state.scope == ReportScope.Mine) R.string.reports_empty_mine
                                else R.string.reports_empty_all,
                            ),
                            color = Ice,
                            style = MaterialTheme.typography.titleMedium,
                            textAlign = TextAlign.Center,
                        )
                        Text(
                            stringResource(R.string.reports_description),
                            color = Muted,
                            style = MaterialTheme.typography.bodySmall,
                            textAlign = TextAlign.Center,
                        )
                    }
                }
            }

            state.reports.forEach { report ->
                ReportCard(report) { onOpenReport(report.id) }
            }

            if (state.hasMore) {
                ReportOutlineButton(
                    onClick = onLoadMore,
                    enabled = !state.loadingMore,
                    modifier = Modifier.fillMaxWidth().testTag("reports_load_more"),
                ) {
                    if (state.loadingMore) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(18.dp),
                            strokeWidth = 2.dp,
                        )
                    } else {
                        Text(stringResource(R.string.reports_load_more))
                    }
                }
            }

            Surface(
                color = Warning.copy(alpha = 0.06f),
                border = BorderStroke(1.dp, Warning.copy(alpha = 0.24f)),
                shape = SteppedFrameShape,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    text = stringResource(R.string.reports_guest_note),
                    color = Muted,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(12.dp),
                )
            }
        }
    }
}

@Composable
fun ReportDetailScreen(
    state: ReportDetailState,
    onRetry: () -> Unit,
    onToggleSignal: () -> Unit,
    onAddNote: (String, () -> Unit) -> Unit,
    onCastVerdict: (String, String, () -> Unit) -> Unit,
    onClearValidation: () -> Unit,
    onEdit: (PracticeReport) -> Unit,
    onDelete: () -> Unit,
) {
    val report = state.report
    if (state.loading && report == null) {
        Text(stringResource(R.string.reports_loading), color = Muted)
        LinearProgressIndicator(Modifier.fillMaxWidth())
        return
    }
    if (report == null) {
        ReportErrorText(state.error ?: ReportError.NotFound)
        ReportOutlineButton(
            onClick = onRetry,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(stringResource(R.string.reports_refresh))
        }
        return
    }

    Column(
        modifier = Modifier.fillMaxWidth().testTag("report_detail_screen"),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())

    Text(
        text = stringResource(R.string.reports_eyebrow),
        color = Signal,
        fontFamily = FontFamily.Monospace,
        style = MaterialTheme.typography.labelMedium,
        letterSpacing = 2.sp,
    )
    Text(
        text = report.title,
        color = Ice,
        style = MaterialTheme.typography.headlineSmall,
        fontWeight = FontWeight.Bold,
    )
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ReviewPill(report.review)
        Text(
            text = reportStatusLabel(report.status),
            color = Muted,
            style = MaterialTheme.typography.labelSmall,
        )
    }
    Text(
        text = "${report.category} · ${report.channel} · ${report.pattern}",
        color = Muted,
        style = MaterialTheme.typography.bodySmall,
    )
    Text(
        text = if (report.isOwner) {
            stringResource(R.string.reports_your_report)
        } else {
            stringResource(R.string.reports_detail_author, report.author)
        },
        color = if (report.isOwner) Signal else Muted,
        style = MaterialTheme.typography.labelMedium,
    )

    if (report.isOwner) {
        OwnerActions(
            reportTitle = report.title,
            busy = state.busy,
            onEdit = { onEdit(report) },
            onDelete = onDelete,
        )
    }

    ReportSection(stringResource(R.string.reports_detail_evidence)) {
        Text(report.evidence.ifBlank { "—" }, color = Ice)
    }
    ReportSection(stringResource(R.string.reports_detail_risk)) {
        Text(report.whyRisky.ifBlank { "—" }, color = Ice)
    }
    val screenshot = report.screenshotDataUrl
    if (!screenshot.isNullOrBlank()) {
        ReportScreenshot(
            dataUrl = screenshot,
            contentDescription = stringResource(
                R.string.reports_screenshot_description,
                report.title,
            ),
        )
    }
    val url = report.defangedUrl
    if (!url.isNullOrBlank()) {
        Text(
            text = url,
            color = Warning,
            fontFamily = FontFamily.Monospace,
            style = MaterialTheme.typography.bodySmall,
        )
    }
    val feedback = report.reviewerFeedback
    if (!feedback.isNullOrBlank()) {
        ReportSection(stringResource(R.string.reports_reviewer_feedback)) {
            Text(feedback, color = Warning)
        }
    }

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ReportOutlineButton(
            onClick = onToggleSignal,
            enabled = state.role == ReportRole.Investigator && !state.busy,
            modifier = Modifier.testTag("report_signal"),
            border = BorderStroke(
                1.dp,
                if (report.hasSignaled) Signal else Navy700,
            ),
        ) {
            Text(
                text = stringResource(R.string.reports_signal_count, report.signalScore),
                color = if (report.hasSignaled) Signal else Ice,
            )
        }
        if (state.role != ReportRole.Investigator) {
            Text(
                text = stringResource(R.string.reports_detail_signal_hint),
                color = Muted,
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }

    VerdictSection(
        state = state,
        onCastVerdict = onCastVerdict,
        onClearValidation = onClearValidation,
    )
    NoteSection(
        state = state,
        onAddNote = onAddNote,
        onClearValidation = onClearValidation,
    )

        ReportNoticeText(state.notice)
        ReportValidationText(state.validation)
        ReportErrorText(state.error)
    }
}

@Composable
private fun OwnerActions(
    reportTitle: String,
    busy: Boolean,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    var confirmDelete by remember { mutableStateOf(false) }
    Surface(
        color = Signal.copy(alpha = 0.06f),
        border = BorderStroke(1.dp, Signal.copy(alpha = 0.32f)),
        shape = SteppedFrameShape,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                text = stringResource(R.string.reports_owner_note),
                color = Signal,
                style = MaterialTheme.typography.bodySmall,
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                ReportPrimaryButton(
                    onClick = onEdit,
                    enabled = !busy,
                    modifier = Modifier.weight(1f).testTag("report_edit"),
                ) {
                    Text(stringResource(R.string.reports_detail_edit))
                }
                ReportOutlineButton(
                    onClick = { confirmDelete = true },
                    enabled = !busy,
                    modifier = Modifier.weight(1f).testTag("report_delete"),
                    border = BorderStroke(1.dp, ModuleAccent),
                ) {
                    Text(
                        text = stringResource(
                            if (busy) {
                                R.string.reports_detail_deleting
                            } else {
                                R.string.reports_detail_delete
                            },
                        ),
                        color = ModuleAccent,
                    )
                }
            }
        }
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text(stringResource(R.string.reports_detail_delete_title)) },
            text = {
                Text(
                    stringResource(
                        R.string.reports_detail_delete_body,
                        reportTitle,
                    ),
                )
            },
            confirmButton = {
                ReportTextButton(
                    onClick = {
                        confirmDelete = false
                        onDelete()
                    },
                ) {
                    Text(
                        stringResource(R.string.reports_delete_confirm),
                        color = ModuleAccent,
                    )
                }
            },
            dismissButton = {
                ReportTextButton(onClick = { confirmDelete = false }) {
                    Text(stringResource(R.string.reports_cancel))
                }
            },
        )
    }
}

@Composable
private fun VerdictSection(
    state: ReportDetailState,
    onCastVerdict: (String, String, () -> Unit) -> Unit,
    onClearValidation: () -> Unit,
) {
    val report = state.report ?: return
    var reason by rememberSaveable(report.id) { mutableStateOf("") }
    val existingVote = state.verdicts.firstOrNull { it.userId == state.currentUserId }
    ReportSection(stringResource(R.string.reports_verdict_title)) {
        Text(
            text = stringResource(
                R.string.reports_verdict_counts,
                state.verdictTotals.valid,
                state.verdictTotals.invalid,
            ),
            color = Ice,
            fontWeight = FontWeight.SemiBold,
        )
        if (state.verdicts.isEmpty()) {
            Text(stringResource(R.string.reports_verdict_empty), color = Muted)
        }
        state.verdicts.forEach { verdict ->
            val valid = verdict.verdict == "valid"
            Surface(
                color = Navy950,
                shape = SteppedFrameShape,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(
                    modifier = Modifier.padding(10.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Text(
                            text = stringResource(
                                if (valid) {
                                    R.string.reports_verdict_valid
                                } else {
                                    R.string.reports_verdict_invalid
                                },
                            ),
                            color = if (valid) Signal else ModuleAccent,
                            style = MaterialTheme.typography.labelMedium,
                            fontFamily = FontFamily.Monospace,
                            fontWeight = FontWeight.Bold,
                        )
                        verdict.authorUsername?.let {
                            Text(
                                text = stringResource(R.string.reports_verdict_by, it),
                                color = Muted,
                                style = MaterialTheme.typography.labelSmall,
                            )
                        }
                    }
                    Text(verdict.reason, color = Ice)
                    Text(
                        verdict.updatedAt.take(10),
                        color = Muted,
                        style = MaterialTheme.typography.labelSmall,
                    )
                }
            }
        }
        if (state.role == ReportRole.Investigator) {
            existingVote?.let { vote ->
                val label = stringResource(
                    if (vote.verdict == "valid") {
                        R.string.reports_verdict_valid
                    } else {
                        R.string.reports_verdict_invalid
                    },
                )
                Text(
                    text = stringResource(R.string.reports_verdict_your_vote, label),
                    color = Muted,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            OutlinedTextField(
        shape = SteppedFrameShape,
                value = reason,
                onValueChange = {
                    reason = it.take(2000)
                    onClearValidation()
                },
                label = { Text(stringResource(R.string.reports_verdict_reason_label)) },
                placeholder = { Text(stringResource(R.string.reports_verdict_reason_placeholder)) },
                minLines = 2,
                enabled = !state.busy,
                modifier = Modifier.fillMaxWidth().testTag("report_verdict_reason"),
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                ReportPrimaryButton(
                    onClick = { onCastVerdict("valid", reason) { reason = "" } },
                    enabled = reason.trim().length >= 4 && !state.busy,
                    modifier = Modifier.weight(1f).testTag("report_verdict_valid"),
                ) {
                    Text(stringResource(R.string.reports_verdict_valid))
                }
                ReportOutlineButton(
                    onClick = { onCastVerdict("invalid", reason) { reason = "" } },
                    enabled = reason.trim().length >= 4 && !state.busy,
                    modifier = Modifier.weight(1f).testTag("report_verdict_invalid"),
                    border = BorderStroke(1.dp, ModuleAccent),
                ) {
                    Text(
                        stringResource(R.string.reports_verdict_invalid),
                        color = ModuleAccent,
                    )
                }
            }
        }
    }
}

@Composable
private fun NoteSection(
    state: ReportDetailState,
    onAddNote: (String, () -> Unit) -> Unit,
    onClearValidation: () -> Unit,
) {
    val report = state.report ?: return
    var draft by rememberSaveable(report.id) { mutableStateOf("") }
    ReportSection(
        stringResource(R.string.reports_detail_investigation, state.notes.size),
    ) {
        if (state.notes.isEmpty()) {
            Text(stringResource(R.string.reports_detail_no_notes), color = Muted)
        }
        state.notes.forEach { note ->
            val investigator = note.authorRole == ReportRole.Investigator
            Surface(
                color = Navy950,
                shape = SteppedFrameShape,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(
                    modifier = Modifier.padding(10.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Text(
                            text = stringResource(
                                if (investigator) {
                                    R.string.reports_role_investigator_short
                                } else {
                                    R.string.reports_role_student_short
                                },
                            ),
                            color = if (investigator) Signal else Muted,
                            style = MaterialTheme.typography.labelSmall,
                            fontFamily = FontFamily.Monospace,
                        )
                        note.authorUsername?.let {
                            Text(
                                text = it,
                                color = Muted,
                                style = MaterialTheme.typography.labelSmall,
                            )
                        }
                    }
                    Text(note.text, color = Ice)
                    Text(
                        note.createdAt.take(10),
                        color = Muted,
                        style = MaterialTheme.typography.labelSmall,
                    )
                }
            }
        }
        if (state.role == ReportRole.Investigator) {
            OutlinedTextField(
        shape = SteppedFrameShape,
                value = draft,
                onValueChange = {
                    draft = it.take(3000)
                    onClearValidation()
                },
                label = { Text(stringResource(R.string.reports_detail_note_label)) },
                placeholder = {
                    Text(stringResource(R.string.reports_detail_note_placeholder))
                },
                minLines = 2,
                enabled = !state.busy,
                modifier = Modifier.fillMaxWidth().testTag("report_note_input"),
            )
            ReportPrimaryButton(
                onClick = { onAddNote(draft) { draft = "" } },
                enabled = draft.trim().length >= 4 && !state.busy,
                modifier = Modifier.fillMaxWidth().testTag("report_note_submit"),
            ) {
                Text(stringResource(R.string.reports_detail_investigate))
            }
        }
    }
}

@Composable
fun ReportEditorScreen(
    state: ReportEditorState,
    onTitle: (String) -> Unit,
    onCategory: (String) -> Unit,
    onChannel: (String) -> Unit,
    onPattern: (String) -> Unit,
    onEvidence: (String) -> Unit,
    onRisk: (String) -> Unit,
    onUrl: (String) -> Unit,
    onScreenshot: (String) -> Unit,
    onScreenshotError: (ReportValidationError) -> Unit,
    onRemoveScreenshot: () -> Unit,
    onSave: () -> Unit,
    onCancel: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth().testTag("report_editor_screen"),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        val context = LocalContext.current
        val scope = rememberCoroutineScope()
        val picker = rememberLauncherForActivityResult(
            ActivityResultContracts.GetContent(),
        ) { uri ->
            if (uri != null) {
                scope.launch {
                    when (val result = withContext(Dispatchers.IO) {
                        readReportScreenshot(context, uri)
                    }) {
                        is ScreenshotResult.Success -> onScreenshot(result.dataUrl)
                        is ScreenshotResult.Failure -> onScreenshotError(result.error)
                    }
                }
            }
        }

    Text(
        text = stringResource(R.string.reports_eyebrow),
        color = Signal,
        fontFamily = FontFamily.Monospace,
        style = MaterialTheme.typography.labelMedium,
        letterSpacing = 2.sp,
    )
    Text(
        text = stringResource(
            if (state.isEditing) {
                R.string.reports_editor_edit_title
            } else {
                R.string.reports_editor_new_title
            },
        ),
        color = Ice,
        style = MaterialTheme.typography.headlineSmall,
        fontWeight = FontWeight.Bold,
    )
    Text(stringResource(R.string.reports_editor_description), color = Muted)
    if (state.saving) LinearProgressIndicator(Modifier.fillMaxWidth())

    OutlinedTextField(
        shape = SteppedFrameShape,
        value = state.title,
        onValueChange = onTitle,
        label = { Text(stringResource(R.string.reports_editor_title)) },
        singleLine = true,
        enabled = !state.saving,
        modifier = Modifier.fillMaxWidth().testTag("report_title_input"),
    )
    ReportChoiceRow(
        label = stringResource(R.string.reports_editor_category),
        choices = REPORT_CATEGORIES.map { ReportChoice(it, it) },
        selected = state.category,
        enabled = !state.saving,
        onSelect = onCategory,
    )
    ReportChoiceRow(
        label = stringResource(R.string.reports_editor_channel),
        choices = REPORT_CHANNELS.map { ReportChoice(it, it) },
        selected = state.channel,
        enabled = !state.saving,
        onSelect = onChannel,
    )
    ReportChoiceRow(
        label = stringResource(R.string.reports_editor_pattern),
        choices = REPORT_PATTERNS.map { ReportChoice(it, it) },
        selected = state.pattern,
        enabled = !state.saving,
        onSelect = onPattern,
    )
    OutlinedTextField(
        shape = SteppedFrameShape,
        value = state.evidence,
        onValueChange = onEvidence,
        label = { Text(stringResource(R.string.reports_editor_evidence)) },
        minLines = 4,
        maxLines = 10,
        enabled = !state.saving,
        modifier = Modifier.fillMaxWidth().testTag("report_evidence_input"),
    )
    OutlinedTextField(
        shape = SteppedFrameShape,
        value = state.whyRisky,
        onValueChange = onRisk,
        label = { Text(stringResource(R.string.reports_editor_risk)) },
        minLines = 4,
        maxLines = 10,
        enabled = !state.saving,
        modifier = Modifier.fillMaxWidth().testTag("report_risk_input"),
    )
    OutlinedTextField(
        shape = SteppedFrameShape,
        value = state.url,
        onValueChange = onUrl,
        label = { Text(stringResource(R.string.reports_editor_url)) },
        singleLine = true,
        enabled = !state.saving,
        supportingText = {
            Text(stringResource(R.string.reports_editor_url_hint))
        },
        modifier = Modifier.fillMaxWidth().testTag("report_url_input"),
    )

    Text(
        text = stringResource(R.string.reports_editor_screenshot),
        color = ModeLabelColor,
        style = MaterialTheme.typography.labelMedium,
        fontFamily = FontFamily.Monospace,
    )
    if (!state.screenshotDataUrl.isNullOrBlank()) {
        ReportScreenshot(
            dataUrl = state.screenshotDataUrl,
            contentDescription = stringResource(R.string.reports_screenshot_preview),
            maxHeight = 240.dp,
        )
        ReportOutlineButton(
            onClick = onRemoveScreenshot,
            enabled = !state.saving,
            modifier = Modifier.fillMaxWidth(),
            border = BorderStroke(1.dp, ModuleAccent),
        ) {
            Text(
                stringResource(R.string.reports_editor_remove_screenshot),
                color = ModuleAccent,
            )
        }
    }
    ReportOutlineButton(
        onClick = { picker.launch("image/*") },
        enabled = !state.saving,
        modifier = Modifier.fillMaxWidth().testTag("report_screenshot_pick"),
    ) {
        Text(stringResource(R.string.reports_editor_choose_screenshot))
    }
    Text(
        text = stringResource(R.string.reports_editor_screenshot_hint),
        color = Muted,
        style = MaterialTheme.typography.bodySmall,
    )

    ReportValidationText(state.validation)
    ReportErrorText(state.error)

    ReportPrimaryButton(
        onClick = onSave,
        enabled = !state.saving &&
            state.title.trim().length >= 4 &&
            state.evidence.trim().length >= 10 &&
            state.whyRisky.trim().length >= 10,
        modifier = Modifier.fillMaxWidth()
            .heightIn(min = 52.dp)
            .testTag("report_save"),
    ) {
        Text(
            stringResource(
                if (state.saving) {
                    R.string.reports_editor_saving
                } else {
                    R.string.reports_editor_save
                },
            ),
        )
    }
        ReportOutlineButton(
            onClick = onCancel,
            enabled = !state.saving,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(stringResource(R.string.reports_cancel))
        }
    }
}

@Composable
private fun ReportCard(report: PracticeReport, onClick: () -> Unit) {
    Surface(
        color = Navy900,
        shape = SteppedFrameShape,
        border = BorderStroke(
            1.dp,
            if (report.isOwner) Signal.copy(alpha = 0.45f) else Navy700,
        ),
        modifier = Modifier.fillMaxWidth().clip(SteppedFrameShape).clickable(
            role = Role.Button,
            onClick = onClick,
        ),
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Text(
                    text = report.title,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                    color = Ice,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                ReviewPill(report.review)
            }
            Text(
                text = "${report.category} · ${report.channel} · ${report.pattern}",
                color = Muted,
                style = MaterialTheme.typography.bodySmall,
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = if (report.isOwner) {
                        stringResource(R.string.reports_your_report)
                    } else {
                        report.author
                    },
                    color = if (report.isOwner) Signal else Muted,
                    style = MaterialTheme.typography.labelMedium,
                )
                Text(
                    text = stringResource(
                        R.string.reports_signal_count,
                        report.signalScore,
                    ),
                    color = Signal,
                    style = MaterialTheme.typography.labelMedium,
                )
            }
            report.investigatorVerdict?.let { verdict ->
                val valid = verdict == "valid"
                Text(
                    text = stringResource(
                        if (valid) {
                            R.string.reports_verdict_valid
                        } else {
                            R.string.reports_verdict_invalid
                        },
                    ),
                    color = if (valid) Signal else ModuleAccent,
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                )
            }
            Text(
                text = report.createdAt.take(10),
                color = Muted,
                style = MaterialTheme.typography.labelSmall,
            )
        }
    }
}

@Composable
private fun ReviewPill(review: ReportReviewStatus) {
    val label = when (review) {
        ReportReviewStatus.Queued -> R.string.reports_queued
        ReportReviewStatus.Approved -> R.string.reports_approved
        ReportReviewStatus.Rejected -> R.string.reports_rejected
    }
    val color = when (review) {
        ReportReviewStatus.Queued -> Warning
        ReportReviewStatus.Approved -> Signal
        ReportReviewStatus.Rejected -> ModuleAccent
    }
    Surface(
        color = color.copy(alpha = 0.12f),
        shape = SteppedFrameShape,
        border = BorderStroke(1.dp, color.copy(alpha = 0.4f)),
    ) {
        Text(
            text = stringResource(label),
            color = color,
            style = MaterialTheme.typography.labelSmall,
            fontFamily = FontFamily.Monospace,
            modifier = Modifier.padding(horizontal = 7.dp, vertical = 4.dp),
        )
    }
}

@Composable
private fun RolePill(role: ReportRole) {
    val investigator = role == ReportRole.Investigator
    val color = if (investigator) Signal else Muted
    Surface(
        color = color.copy(alpha = 0.1f),
        shape = SteppedFrameShape,
        border = BorderStroke(1.dp, color.copy(alpha = 0.3f)),
    ) {
        Text(
            text = stringResource(
                if (investigator) {
                    R.string.reports_role_investigator
                } else {
                    R.string.reports_role_student
                },
            ),
            color = color,
            style = MaterialTheme.typography.labelSmall,
            fontFamily = FontFamily.Monospace,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 5.dp),
        )
    }
}

@Composable
private fun ReportSection(
    title: String,
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        color = Navy900,
        border = BorderStroke(1.dp, Navy700),
        shape = SteppedFrameShape,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = title,
                color = Signal,
                style = MaterialTheme.typography.labelMedium,
                fontFamily = FontFamily.Monospace,
                letterSpacing = 1.sp,
            )
            content()
        }
    }
}

@Composable
private fun ReportErrorText(error: ReportError?) {
    if (error == null) return
    val text = when (error) {
        ReportError.AuthRequired -> stringResource(R.string.reports_error_auth)
        ReportError.NotConfigured -> stringResource(R.string.reports_error_not_configured)
        ReportError.NotFound -> stringResource(R.string.reports_error_not_found)
        ReportError.NotAllowed -> stringResource(R.string.reports_error_not_allowed)
        ReportError.InvalidInput -> stringResource(R.string.reports_error_invalid)
        ReportError.Network -> stringResource(R.string.reports_error_network)
        ReportError.Generic -> stringResource(R.string.reports_error_generic)
    }
    Text(text, color = Warning)
}

@Composable
private fun ReportValidationText(error: ReportValidationError?) {
    if (error == null) return
    val text = when (error) {
        ReportValidationError.TitleLength -> stringResource(R.string.reports_validation_title)
        ReportValidationError.EvidenceLength -> stringResource(R.string.reports_validation_evidence)
        ReportValidationError.RiskLength -> stringResource(R.string.reports_validation_risk)
        ReportValidationError.UrlTooLong -> stringResource(R.string.reports_validation_url)
        ReportValidationError.ScreenshotTooLarge ->
            stringResource(R.string.reports_editor_screenshot_too_large)
        ReportValidationError.ImageUnreadable ->
            stringResource(R.string.reports_editor_image_unreadable)
        ReportValidationError.ImageType -> stringResource(R.string.reports_editor_image_type)
        ReportValidationError.NoteLength -> stringResource(R.string.reports_validation_note)
        ReportValidationError.VerdictReasonLength ->
            stringResource(R.string.reports_validation_reason)
    }
    Text(text, color = Warning)
}

@Composable
private fun ReportNoticeText(notice: ReportNotice?) {
    if (notice == null) return
    val text = when (notice) {
        ReportNotice.SignalAdded -> stringResource(R.string.reports_notice_signal_added)
        ReportNotice.SignalRemoved -> stringResource(R.string.reports_notice_signal_removed)
        ReportNotice.NoteAdded -> stringResource(R.string.reports_notice_note_added)
        ReportNotice.VerdictSaved -> stringResource(R.string.reports_notice_verdict_saved)
    }
    Text(text, color = Signal)
}

@Composable
private fun reportStatusLabel(status: String): String = when (status) {
    "Queued for developer review" -> stringResource(R.string.reports_status_queued)
    "Triaged" -> stringResource(R.string.reports_status_triaged)
    "Learning note" -> stringResource(R.string.reports_status_learning)
    else -> status
}

@Composable
private fun <T> ReportChoiceRow(
    label: String,
    choices: List<ReportChoice<T>>,
    selected: T,
    enabled: Boolean = true,
    onSelect: (T) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            text = label,
            color = ModeLabelColor,
            style = MaterialTheme.typography.labelMedium,
            fontFamily = FontFamily.Monospace,
        )
        FlowRow(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            choices.forEach { choice ->
                FilterChip(
                    selected = choice.value == selected,
                    onClick = { onSelect(choice.value) },
                    label = { Text(choice.label, style = MaterialTheme.typography.labelMedium) },
                    shape = SteppedFrameShape,
                    enabled = enabled,
                    colors = FilterChipDefaults.filterChipColors(
                        containerColor = Navy950,
                        labelColor = Muted,
                        selectedContainerColor = Signal.copy(alpha = 0.14f),
                        selectedLabelColor = Signal,
                    ),
                    modifier = choice.tag?.let { Modifier.testTag(it) } ?: Modifier,
                )
            }
        }
    }
}

private data class ReportChoice<T>(
    val value: T,
    val label: String,
    val tag: String? = null,
)

@Composable
private fun ReportScreenshot(
    dataUrl: String,
    contentDescription: String,
    maxHeight: Dp = 320.dp,
) {
    val bitmap = remember(dataUrl) { decodeReportImage(dataUrl) }
    if (bitmap == null) {
        Text(
            text = stringResource(R.string.reports_editor_image_unreadable),
            color = Muted,
            style = MaterialTheme.typography.bodySmall,
        )
        return
    }
    Image(
        bitmap = bitmap.asImageBitmap(),
        contentDescription = contentDescription,
        contentScale = ContentScale.Fit,
        modifier = Modifier.fillMaxWidth()
            .heightIn(max = maxHeight)
            .clip(SteppedFrameShape)
            .background(Navy950),
    )
}

private fun decodeReportImage(dataUrl: String): Bitmap? {
    val comma = dataUrl.indexOf(',')
    if (comma <= 0) return null
    val header = dataUrl.substring(0, comma)
    if (!header.startsWith("data:image/") || !header.contains(";base64")) return null
    val bytes = try {
        Base64.decode(dataUrl.substring(comma + 1), Base64.DEFAULT)
    } catch (_: IllegalArgumentException) {
        return null
    }
    if (bytes.isEmpty()) return null
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
    var sample = 1
    while (bounds.outWidth / sample > 1400 || bounds.outHeight / sample > 1400) {
        sample *= 2
    }
    val options = BitmapFactory.Options().apply { inSampleSize = sample }
    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
}

private sealed interface ScreenshotResult {
    data class Success(val dataUrl: String) : ScreenshotResult
    data class Failure(val error: ReportValidationError) : ScreenshotResult
}

private val SUPPORTED_SCREENSHOT_TYPES = setOf(
    "image/png",
    "image/jpeg",
    "image/jpg",
    "image/webp",
    "image/gif",
)

private fun readReportScreenshot(context: Context, uri: Uri): ScreenshotResult {
    val resolver = context.contentResolver
    val mime = resolver.getType(uri)?.lowercase().orEmpty()
    if (mime !in SUPPORTED_SCREENSHOT_TYPES) {
        return ScreenshotResult.Failure(ReportValidationError.ImageType)
    }
    val declaredSize = try {
        resolver.query(
            uri,
            arrayOf(OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getLong(0) else null
        }
    } catch (_: Exception) {
        null
    }
    if (declaredSize != null && declaredSize > MAX_REPORT_SCREENSHOT_BYTES) {
        return ScreenshotResult.Failure(ReportValidationError.ScreenshotTooLarge)
    }
    val bytes = try {
        resolver.openInputStream(uri)?.use { input ->
            readAtMost(input, MAX_REPORT_SCREENSHOT_BYTES + 1)
        }
    } catch (_: Exception) {
        null
    } ?: return ScreenshotResult.Failure(ReportValidationError.ImageUnreadable)
    if (bytes.isEmpty()) {
        return ScreenshotResult.Failure(ReportValidationError.ImageUnreadable)
    }
    if (bytes.size > MAX_REPORT_SCREENSHOT_BYTES) {
        return ScreenshotResult.Failure(ReportValidationError.ScreenshotTooLarge)
    }
    val dataUrl = "data:$mime;base64," + Base64.encodeToString(bytes, Base64.NO_WRAP)
    if (dataUrl.toByteArray(Charsets.UTF_8).size > MAX_REPORT_SCREENSHOT_DATA_BYTES) {
        return ScreenshotResult.Failure(ReportValidationError.ScreenshotTooLarge)
    }
    return ScreenshotResult.Success(dataUrl)
}

private fun readAtMost(input: InputStream, max: Int): ByteArray {
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(8192)
    var total = 0
    while (total < max) {
        val read = input.read(buffer)
        if (read < 0) break
        val remaining = max - total
        if (read > remaining) {
            output.write(buffer, 0, remaining)
            total = max
            break
        }
        output.write(buffer, 0, read)
        total += read
    }
    return output.toByteArray()
}

private val ModeLabelColor = Muted

// Match the pixel buttons used by the native module screens.
@Composable
private fun ReportPrimaryButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit,
) {
    Button(
        onClick = onClick, enabled = enabled,
        modifier = modifier.heightIn(min = 52.dp),
        shape = SteppedFrameShape,
        colors = ButtonDefaults.buttonColors(
            containerColor = Color(0xFF83AE39), contentColor = Navy950,
            disabledContainerColor = Navy700, disabledContentColor = Muted,
        ),
    ) { ReportButtonLabel { content() } }
}

@Composable
private fun ReportOutlineButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    border: BorderStroke = BorderStroke(1.dp, Signal.copy(alpha = 0.5f)),
    content: @Composable RowScope.() -> Unit,
) {
    OutlinedButton(
        onClick = onClick, enabled = enabled,
        modifier = modifier.heightIn(min = 48.dp), shape = SteppedFrameShape,
        border = border,
        colors = ButtonDefaults.outlinedButtonColors(contentColor = Signal, disabledContentColor = Muted),
    ) { ReportButtonLabel { content() } }
}

@Composable
private fun ReportTextButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit,
) {
    TextButton(onClick = onClick, enabled = enabled, modifier = modifier.heightIn(min = 48.dp),
        shape = SteppedFrameShape) { ReportButtonLabel { content() } }
}

@Composable
private fun ReportButtonLabel(content: @Composable () -> Unit) {
    androidx.compose.material3.ProvideTextStyle(
        MaterialTheme.typography.labelMedium.copy(
            fontFamily = FontFamily(Font(R.font.quest_pixel)),
            fontSize = 10.sp, letterSpacing = 1.sp,
        ), content = content,
    )
}
