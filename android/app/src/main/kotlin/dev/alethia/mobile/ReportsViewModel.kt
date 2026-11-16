package dev.alethia.mobile

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.createSavedStateHandle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.CreationExtras
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

data class ReportsListState(
    val signedIn: Boolean = false,
    val role: ReportRole = ReportRole.Student,
    val scope: ReportScope = ReportScope.All,
    val sort: ReportSort = ReportSort.Top,
    val reports: List<PracticeReport> = emptyList(),
    val loading: Boolean = false,
    val loadingMore: Boolean = false,
    val hasMore: Boolean = false,
    val nextCursor: ReportCursor? = null,
    val error: ReportError? = null,
)

data class ReportDetailState(
    val reportId: String? = null,
    val report: PracticeReport? = null,
    val notes: List<InvestigationNote> = emptyList(),
    val verdicts: List<ReportVerdict> = emptyList(),
    val verdictTotals: ReportVerdictTotals = ReportVerdictTotals(),
    val role: ReportRole = ReportRole.Student,
    val currentUserId: String? = null,
    val loading: Boolean = false,
    val busy: Boolean = false,
    val error: ReportError? = null,
    val validation: ReportValidationError? = null,
    val notice: ReportNotice? = null,
)

data class ReportEditorState(
    val reportId: String? = null,
    val title: String = "",
    val category: String = REPORT_CATEGORIES.first(),
    val channel: String = REPORT_CHANNELS.first(),
    val pattern: String = REPORT_PATTERNS.first(),
    val evidence: String = "",
    val whyRisky: String = "",
    val url: String = "",
    val screenshotDataUrl: String? = null,
    val screenshotRemoved: Boolean = false,
    val saving: Boolean = false,
    val error: ReportError? = null,
    val validation: ReportValidationError? = null,
) {
    val isEditing: Boolean get() = reportId != null
}

class ReportsViewModel(
    private val saved: SavedStateHandle,
    private val repository: ReportsRepository? = null,
) : ViewModel() {
    private val mutableList = MutableStateFlow(
        ReportsListState(
            signedIn = repository != null,
            loading = repository != null,
            error = if (repository == null) ReportError.NotConfigured else null,
        ),
    )
    val list = mutableList.asStateFlow()

    private val mutableDetail = MutableStateFlow(ReportDetailState())
    val detail = mutableDetail.asStateFlow()

    private val mutableEditor = MutableStateFlow(ReportEditorState())
    val editor = mutableEditor.asStateFlow()

    val detailId = saved.getStateFlow<String?>("reportDetailId", null)
    val editorParent = saved.getStateFlow("reportEditorParent", Screen.Reports)

    private var owner: String? = null
    private var listJob: Job? = null
    private var detailJob: Job? = null
    private var actionJob: Job? = null
    private var editorJob: Job? = null

    init {
        repository?.identity?.let { identityFlow ->
            viewModelScope.launch {
                identityFlow.collectLatest { identity ->
                    if (identity == null) {
                        resetForSignedOut()
                    } else if (identity != owner) {
                        owner = identity
                        detailJob?.cancel()
                        actionJob?.cancel()
                        editorJob?.cancel()
                        mutableDetail.value = ReportDetailState()
                        mutableEditor.value = ReportEditorState()
                        saved["reportDetailId"] = null
                        saved["reportEditorId"] = null
                        mutableList.value = ReportsListState(signedIn = true)
                        refresh()
                    }
                }
            }
        }
    }

    fun refresh() {
        val repo = repository ?: run {
            mutableList.value = mutableList.value.copy(
                loading = false,
                loadingMore = false,
                error = ReportError.NotConfigured,
            )
            return
        }
        val current = mutableList.value
        listJob?.cancel()
        listJob = viewModelScope.launch {
            mutableList.value = current.copy(
                loading = true,
                loadingMore = false,
                error = null,
            )
            try {
                val role = if (repo.isInvestigator()) {
                    ReportRole.Investigator
                } else {
                    ReportRole.Student
                }
                val page = repo.loadPage(current.scope, current.sort, null)
                mutableList.value = mutableList.value.copy(
                    signedIn = true,
                    role = role,
                    reports = page.reports,
                    hasMore = page.hasMore,
                    nextCursor = page.nextCursor,
                    loading = false,
                    loadingMore = false,
                    error = null,
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (caught: Exception) {
                val error = caught.toReportError()
                mutableList.value = mutableList.value.copy(
                    signedIn = mutableList.value.signedIn &&
                        error != ReportError.AuthRequired,
                    loading = false,
                    loadingMore = false,
                    error = error,
                )
            }
        }
    }

    fun loadMore() {
        val repo = repository ?: return
        val current = mutableList.value
        if (current.loading || current.loadingMore || !current.hasMore ||
            current.nextCursor == null
        ) {
            return
        }
        listJob?.cancel()
        listJob = viewModelScope.launch {
            mutableList.value = current.copy(loadingMore = true, error = null)
            try {
                val page = repo.loadPage(current.scope, current.sort, current.nextCursor)
                val latest = mutableList.value
                mutableList.value = latest.copy(
                    reports = (latest.reports + page.reports).distinctBy { it.id },
                    hasMore = page.hasMore,
                    nextCursor = page.nextCursor,
                    loadingMore = false,
                    error = null,
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (caught: Exception) {
                mutableList.value = mutableList.value.copy(
                    loadingMore = false,
                    error = caught.toReportError(),
                )
            }
        }
    }

    fun setScope(scope: ReportScope) {
        if (mutableList.value.scope == scope) return
        mutableList.value = mutableList.value.copy(scope = scope)
        refresh()
    }

    fun setSort(sort: ReportSort) {
        if (mutableList.value.sort == sort) return
        mutableList.value = mutableList.value.copy(sort = sort)
        refresh()
    }

    fun openDetail(reportId: String) {
        saved["reportDetailId"] = reportId
        loadDetail(reportId)
    }

    fun loadDetail(reportId: String) {
        val repo = repository ?: run {
            mutableDetail.value = ReportDetailState(
                reportId = reportId,
                error = ReportError.NotConfigured,
            )
            return
        }
        detailJob?.cancel()
        detailJob = viewModelScope.launch {
            mutableDetail.value = ReportDetailState(reportId = reportId, loading = true)
            try {
                val currentUser = repo.currentUserId()
                    ?: throw ReportException(ReportError.AuthRequired)
                val role = if (repo.isInvestigator()) {
                    ReportRole.Investigator
                } else {
                    ReportRole.Student
                }
                coroutineScope {
                    val report = async { repo.loadReport(reportId) }
                    val notes = async { repo.loadNotes(reportId) }
                    val verdicts = async { repo.loadVerdicts(reportId) }
                    val totals = async { repo.loadVerdictTotals(reportId) }
                    val loaded = report.await()
                        ?: throw ReportException(ReportError.NotFound)
                    mutableDetail.value = ReportDetailState(
                        reportId = reportId,
                        report = loaded,
                        notes = notes.await(),
                        verdicts = verdicts.await(),
                        verdictTotals = totals.await(),
                        role = role,
                        currentUserId = currentUser,
                        loading = false,
                    )
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (caught: Exception) {
                mutableDetail.value = mutableDetail.value.copy(
                    loading = false,
                    error = caught.toReportError(),
                )
            }
        }
    }

    fun openNewEditor() {
        saved["reportEditorId"] = null
        saved["reportEditorParent"] = Screen.Reports
        mutableEditor.value = ReportEditorState()
    }

    fun openEditor(report: PracticeReport) {
        if (!report.isOwner) return
        saved["reportEditorId"] = report.id
        saved["reportEditorParent"] = Screen.ReportDetail
        mutableEditor.value = editorStateFrom(report)
    }

    /** Rehydrates an editor after process death without overwriting edits in progress. */
    fun ensureEditorLoaded() {
        val repo = repository ?: return
        val id = saved.get<String>("reportEditorId") ?: return
        val current = mutableEditor.value
        if (current.reportId == id &&
            (current.title.isNotBlank() || current.evidence.isNotBlank())
        ) {
            return
        }
        editorJob?.cancel()
        editorJob = viewModelScope.launch {
            try {
                val report = repo.loadReport(id) ?: return@launch
                if (mutableEditor.value.reportId != id) return@launch
                if (mutableEditor.value.title.isNotBlank() ||
                    mutableEditor.value.evidence.isNotBlank()
                ) {
                    return@launch
                }
                mutableEditor.value = editorStateFrom(report)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                // The blank editor remains usable; the user can cancel or retry.
            }
        }
    }

    fun setEditorTitle(value: String) = updateEditor {
        it.copy(title = value.take(160), validation = null, error = null)
    }

    fun setEditorCategory(value: String) = updateEditor {
        it.copy(category = value, validation = null, error = null)
    }

    fun setEditorChannel(value: String) = updateEditor {
        it.copy(channel = value, validation = null, error = null)
    }

    fun setEditorPattern(value: String) = updateEditor {
        it.copy(pattern = value, validation = null, error = null)
    }

    fun setEditorEvidence(value: String) = updateEditor {
        it.copy(evidence = value.take(5000), validation = null, error = null)
    }

    fun setEditorRisk(value: String) = updateEditor {
        it.copy(whyRisky = value.take(5000), validation = null, error = null)
    }

    fun setEditorUrl(value: String) = updateEditor {
        it.copy(url = value.take(2048), validation = null, error = null)
    }

    fun setEditorScreenshot(dataUrl: String) = updateEditor {
        it.copy(
            screenshotDataUrl = dataUrl,
            screenshotRemoved = false,
            validation = null,
            error = null,
        )
    }

    fun removeEditorScreenshot() = updateEditor {
        it.copy(
            screenshotDataUrl = null,
            screenshotRemoved = true,
            validation = null,
            error = null,
        )
    }

    fun setEditorValidation(error: ReportValidationError) = updateEditor {
        it.copy(validation = error, error = null)
    }

    fun saveEditor(onSaved: (String) -> Unit) {
        val repo = repository ?: run {
            updateEditor { it.copy(error = ReportError.NotConfigured) }
            return
        }
        val state = mutableEditor.value
        val title = state.title.trim()
        val evidence = state.evidence.trim()
        val risk = state.whyRisky.trim()
        when {
            title.length !in 4..160 -> {
                setEditorValidation(ReportValidationError.TitleLength)
                return
            }
            evidence.length !in 10..5000 -> {
                setEditorValidation(ReportValidationError.EvidenceLength)
                return
            }
            risk.length !in 10..5000 -> {
                setEditorValidation(ReportValidationError.RiskLength)
                return
            }
            state.url.trim().length > 2048 -> {
                setEditorValidation(ReportValidationError.UrlTooLong)
                return
            }
        }
        editorJob?.cancel()
        editorJob = viewModelScope.launch {
            mutableEditor.value = mutableEditor.value.copy(
                saving = true,
                error = null,
                validation = null,
            )
            try {
                val input = ReportInput(
                    title = title,
                    category = state.category,
                    channel = state.channel,
                    pattern = state.pattern,
                    evidence = evidence,
                    whyRisky = risk,
                    defangedUrl = state.url.trim()
                        .takeIf { it.isNotEmpty() }
                        ?.let(::defangReportUrl),
                    screenshotDataUrl = if (state.screenshotRemoved) {
                        null
                    } else {
                        state.screenshotDataUrl
                    },
                )
                val savedReport = if (state.reportId == null) {
                    repo.create(input)
                } else {
                    repo.update(state.reportId, input)
                }
                mutableEditor.value = mutableEditor.value.copy(saving = false)
                if (state.reportId == null) {
                    mutableList.value = mutableList.value.copy(sort = ReportSort.Newest)
                }
                refresh()
                onSaved(savedReport.id)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (caught: Exception) {
                mutableEditor.value = mutableEditor.value.copy(
                    saving = false,
                    error = caught.toReportError(),
                )
            }
        }
    }

    fun deleteReport(onDeleted: () -> Unit) {
        val repo = repository ?: return
        val state = mutableDetail.value
        val report = state.report ?: return
        if (!report.isOwner || state.busy) return
        actionJob?.cancel()
        actionJob = viewModelScope.launch {
            mutableDetail.value = state.copy(
                busy = true,
                error = null,
                validation = null,
                notice = null,
            )
            try {
                repo.delete(report.id)
                mutableDetail.value = ReportDetailState()
                saved["reportDetailId"] = null
                refresh()
                onDeleted()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (caught: Exception) {
                mutableDetail.value = mutableDetail.value.copy(
                    busy = false,
                    error = caught.toReportError(),
                )
            }
        }
    }

    fun toggleSignal() {
        val repo = repository ?: return
        val state = mutableDetail.value
        val report = state.report ?: return
        if (state.busy || state.role != ReportRole.Investigator) return
        actionJob?.cancel()
        actionJob = viewModelScope.launch {
            mutableDetail.value = state.copy(
                busy = true,
                error = null,
                validation = null,
                notice = null,
            )
            try {
                val result = repo.toggleSignal(report.id)
                mutableDetail.value = mutableDetail.value.copy(
                    report = mutableDetail.value.report?.copy(
                        hasSignaled = result.active,
                        signalScore = result.score,
                    ),
                    busy = false,
                    notice = if (result.active) {
                        ReportNotice.SignalAdded
                    } else {
                        ReportNotice.SignalRemoved
                    },
                )
                mutableList.value = mutableList.value.copy(
                    reports = mutableList.value.reports.map {
                        if (it.id == report.id) {
                            it.copy(
                                hasSignaled = result.active,
                                signalScore = result.score,
                            )
                        } else {
                            it
                        }
                    },
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (caught: Exception) {
                mutableDetail.value = mutableDetail.value.copy(
                    busy = false,
                    error = caught.toReportError(),
                )
            }
        }
    }

    fun addNote(text: String, onAdded: () -> Unit) {
        val repo = repository ?: return
        val state = mutableDetail.value
        val report = state.report ?: return
        if (state.busy || state.role != ReportRole.Investigator) return
        val clean = text.trim()
        if (clean.length !in 4..3000) {
            mutableDetail.value = state.copy(
                validation = ReportValidationError.NoteLength,
                notice = null,
            )
            return
        }
        actionJob?.cancel()
        actionJob = viewModelScope.launch {
            mutableDetail.value = mutableDetail.value.copy(
                busy = true,
                error = null,
                validation = null,
                notice = null,
            )
            try {
                val note = repo.addNote(report.id, clean)
                mutableDetail.value = mutableDetail.value.copy(
                    notes = mutableDetail.value.notes + note,
                    busy = false,
                    notice = ReportNotice.NoteAdded,
                )
                onAdded()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (caught: Exception) {
                mutableDetail.value = mutableDetail.value.copy(
                    busy = false,
                    error = caught.toReportError(),
                )
            }
        }
    }

    fun castVerdict(verdict: String, reason: String, onSaved: () -> Unit) {
        val repo = repository ?: return
        val state = mutableDetail.value
        val report = state.report ?: return
        if (state.busy || state.role != ReportRole.Investigator) return
        if (verdict != "valid" && verdict != "invalid") return
        val clean = reason.trim()
        if (clean.length !in 4..2000) {
            mutableDetail.value = state.copy(
                validation = ReportValidationError.VerdictReasonLength,
                notice = null,
            )
            return
        }
        actionJob?.cancel()
        actionJob = viewModelScope.launch {
            mutableDetail.value = mutableDetail.value.copy(
                busy = true,
                error = null,
                validation = null,
                notice = null,
            )
            try {
                val totals = repo.castVerdict(report.id, verdict, clean)
                val verdicts = try {
                    repo.loadVerdicts(report.id)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    state.verdicts
                }
                mutableDetail.value = mutableDetail.value.copy(
                    verdicts = verdicts,
                    verdictTotals = totals,
                    report = mutableDetail.value.report?.copy(
                        investigatorVerdict = verdict,
                    ),
                    busy = false,
                    notice = ReportNotice.VerdictSaved,
                )
                mutableList.value = mutableList.value.copy(
                    reports = mutableList.value.reports.map {
                        if (it.id == report.id) {
                            it.copy(investigatorVerdict = verdict)
                        } else {
                            it
                        }
                    },
                )
                onSaved()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (caught: Exception) {
                mutableDetail.value = mutableDetail.value.copy(
                    busy = false,
                    error = caught.toReportError(),
                )
            }
        }
    }

    fun clearDetailValidation() {
        if (mutableDetail.value.validation != null) {
            mutableDetail.value = mutableDetail.value.copy(validation = null)
        }
    }

    private fun resetForSignedOut() {
        owner = null
        listJob?.cancel()
        detailJob?.cancel()
        actionJob?.cancel()
        editorJob?.cancel()
        mutableList.value = ReportsListState()
        mutableDetail.value = ReportDetailState()
        mutableEditor.value = ReportEditorState()
        saved["reportDetailId"] = null
        saved["reportEditorId"] = null
    }

    private fun editorStateFrom(report: PracticeReport) = ReportEditorState(
        reportId = report.id,
        title = report.title,
        category = report.category,
        channel = report.channel,
        pattern = report.pattern,
        evidence = report.evidence,
        whyRisky = report.whyRisky,
        url = report.defangedUrl.orEmpty(),
        screenshotDataUrl = report.screenshotDataUrl,
    )

    private inline fun updateEditor(
        transform: (ReportEditorState) -> ReportEditorState,
    ) {
        mutableEditor.value = transform(mutableEditor.value)
    }

    class Factory(
        private val repository: ReportsRepository?,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(
            modelClass: Class<T>,
            extras: CreationExtras,
        ): T {
            require(modelClass.isAssignableFrom(ReportsViewModel::class.java))
            return ReportsViewModel(
                extras.createSavedStateHandle(),
                repository,
            ) as T
        }
    }
}
