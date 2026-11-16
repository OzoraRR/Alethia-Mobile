package dev.alethia.mobile

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.createSavedStateHandle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.CreationExtras
import dev.alethia.core.CourierAction
import dev.alethia.core.CourierState
import dev.alethia.core.reduceCourier
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.collectLatest
import dev.alethia.core.courierDecisions
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

enum class Screen {
    Welcome, Login, SignUp, Dashboard, Modules, Catalog,
    ModuleRoadmapPhishing, ModuleRoadmapSocialEngineering, ModuleRoadmapMaliciousDocument,
    Courier, Achievements, Reports, ReportDetail, ReportEditor, Notifications, Profile,
}

class PracticeViewModel(
    private val saved: SavedStateHandle,
    private val preferences: LanguagePreferences,
    private val repository: LearnerRepository? = null,
) : ViewModel() {
    private val mutableDashboardUiState = MutableStateFlow(DashboardUiState.preview())
    val dashboardUiState = mutableDashboardUiState.asStateFlow()
    private val mutableBackend = MutableStateFlow(LearnerUiState())
    val backend = mutableBackend.asStateFlow()
    private var owner: String? = null
    private var operationJob: Job? = null
    private var localeJob: Job? = null
    private var localeRestored = false

    init {
        repository?.let { repo -> viewModelScope.launch {
            repo.identity.collectLatest { identity ->
                operationJob?.cancel()
                localeJob?.cancel()
                localeRestored = false
                val oldOwner = owner
                owner = identity
                mutableBackend.value = LearnerUiState(signedIn = identity != null)
                if (identity != null) {
                    mutableDashboardUiState.value = emptyDashboard()
                    if (saved.get<String>("practiceOwner") != identity) {
                        restart()
                        saved["practiceOwner"] = identity
                    }
                    operation { refreshSnapshot() }
                } else {
                    mutableDashboardUiState.value = DashboardUiState.preview()
                    if (oldOwner != null) {
                        restart()
                        saved["practiceOwner"] = null
                        navigate(Screen.Welcome)
                    }
                }
            }
        } }
    }

    private fun operation(block: suspend () -> Unit) {
        if (operationJob?.isActive == true) return
        val identity = owner ?: return
        operationJob = viewModelScope.launch {
            mutableBackend.value = mutableBackend.value.copy(busy = true, failed = false)
            try { block() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) {
                if (owner == identity) mutableBackend.value = mutableBackend.value.copy(failed = true)
            } finally {
                if (owner == identity) mutableBackend.value = mutableBackend.value.copy(busy = false)
            }
        }
    }

    private suspend fun refreshSnapshot() {
        val identity = owner
        val snapshot = repository!!.load()
        if (identity != owner) return
        if (!localeRestored) {
            preferences.setLanguage(snapshot.locale)
            localeRestored = true
        }
        mutableDashboardUiState.value = snapshot.dashboard
        mutableBackend.value = mutableBackend.value.copy(snapshot = snapshot)
    }
    fun refreshBackend() {
        val expected = owner
        viewModelScope.launch {
            operationJob?.join()
            if (owner == expected && expected != null) operation { refreshSnapshot() }
        }
    }
    fun signOut() { operation { repository!!.signOut() } }
    fun submitReport(title: String, evidence: String, risk: String) {
        operation {
            repository!!.submitReport(title, evidence, risk)
            mutableBackend.value = mutableBackend.value.copy(reportRevision = mutableBackend.value.reportRevision + 1)
            refreshSnapshot()
        }
    }
    fun readNotification(id: String) { operation { repository!!.markRead(id); refreshSnapshot() } }
    private fun emptyDashboard() = DashboardUiState("…", 0, 0, quests = emptyList(), isPreview = false)


    val screen = saved.getStateFlow("screen", Screen.Welcome)
    val courierParent = saved.getStateFlow("courierParent", Screen.Catalog)
    val selectedModuleCategoryKey = saved.getStateFlow("selectedModuleCategory", ModuleCategory.Phishing.storageKey)
    val moduleRoadmapScroll = saved.getStateFlow("moduleRoadmapScroll", 0)
    val courier = saved.getStateFlow("courier", CourierState())
    val senderInput = saved.getStateFlow("senderInput", "")
    val linkInput = saved.getStateFlow("linkInput", "")
    val trackingInput = saved.getStateFlow("trackingInput", "")
    val trackingChecked = saved.getStateFlow("trackingChecked", false)
    val language = preferences.language.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "id")

    fun navigate(destination: Screen) { saved["screen"] = destination }
    fun selectModuleCategory(category: ModuleCategory) {
        val current = ModuleCategory.fromStorageKey(selectedModuleCategoryKey.value)
        if (current != category) saved["moduleRoadmapScroll"] = 0
        saved["selectedModuleCategory"] = category.storageKey
    }
    fun saveModuleRoadmapScroll(position: Int) {
        val safePosition = position.coerceAtLeast(0)
        if (moduleRoadmapScroll.value != safePosition) saved["moduleRoadmapScroll"] = safePosition
    }
    fun startModulePractice(roadmapScrollPosition: Int, roadmapParent: Screen) {
        saveModuleRoadmapScroll(roadmapScrollPosition)
        if (courier.value.stage == dev.alethia.core.CourierStage.Complete) restart()
        openCourier(roadmapParent)
    }
    fun returnToTraining() { navigate(courierParent.value) }
    fun openCourier(parent: Screen) {
        saved["courierParent"] = parent
        navigate(Screen.Courier)
    }
    fun dispatch(action: CourierAction) {
        if (owner == null) { saved["courier"] = reduceCourier(courier.value, action); return }
        if (mutableBackend.value.busy) return
        when {
            action == CourierAction.Start && courier.value.stage == dev.alethia.core.CourierStage.Briefing -> operation {
                saved["attemptId"] = repository!!.beginAttempt()
                saved["courier"] = reduceCourier(courier.value, action)
            }
            action == CourierAction.Complete && courier.value.stage == dev.alethia.core.CourierStage.Reveal -> operation {
                val attemptId = saved.get<String>("attemptId") ?: error("Missing attempt")
                val score = repository!!.completeAttempt(attemptId, courierDecisions(courier.value))
                saved["verifiedScore"] = score
                saved["courier"] = reduceCourier(courier.value, action)
                refreshSnapshot()
            }
            else -> { saved["courier"] = reduceCourier(courier.value, action) }
        }
    }
    fun markNotificationsRead() {
        val current = mutableDashboardUiState.value
        if (!current.isPreview) return
        if (current.hasUnreadNotifications) {
            mutableDashboardUiState.value = current.copy(hasUnreadNotifications = false)
        }
    }
    fun setSender(value: String) { saved["senderInput"] = value.take(64); invalidateComparison() }
    fun setLink(value: String) { saved["linkInput"] = value.take(256); invalidateComparison() }
    fun setTracking(value: String) { saved["trackingInput"] = value.take(64); saved["trackingChecked"] = false }
    fun checkTracking() { saved["trackingChecked"] = true }
    fun setLanguage(value: String) {
        viewModelScope.launch { preferences.setLanguage(value) }
        if (owner != null) {
            localeRestored = true
            localeJob?.cancel()
            val identity = owner
            localeJob = viewModelScope.launch {
                try { repository!!.setLocale(value) }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { if (owner == identity) mutableBackend.value = mutableBackend.value.copy(failed = true) }
            }
        }
    }
    fun acceptDashboardQuest(selected: DashboardQuestState) {
        val current = mutableDashboardUiState.value
        if (!current.isPreview) return

        mutableDashboardUiState.value = current.copy(
            quests = current.quests.map {
                if (it.kind == selected.kind && !it.claimed) it.copy(accepted = true) else it
            },
        )
    }
    fun claimDashboardQuest(selected: DashboardQuestState) {
        val current = mutableDashboardUiState.value
        if (!current.isPreview) {
            val quest = current.quests.firstOrNull { it.id == selected.id && !it.claimed && it.progress >= it.target } ?: return
            operation { repository!!.claim(quest); refreshSnapshot() }
            return
        }

        val quest = current.quests.firstOrNull { it.kind == selected.kind } ?: return
        if (!quest.accepted || quest.claimed || quest.progress < quest.target) return

        mutableDashboardUiState.value = current.copy(
            points = current.points + quest.rewardPoints,
            credits = current.credits + quest.rewardCredits,
            quests = current.quests.map {
                if (it.kind == selected.kind) it.copy(claimed = true) else it
            },
        )
    }
    val verifiedScore = saved.getStateFlow<Int?>("verifiedScore", null)
    fun restart() {
        saved["attemptId"] = null
        saved["verifiedScore"] = null
        saved["courier"] = CourierState()
        saved["senderInput"] = ""
        saved["linkInput"] = ""
        saved["trackingInput"] = ""
        saved["trackingChecked"] = false
    }
    private fun invalidateComparison() {
        saved["courier"] = courier.value.copy(
            comparisonSubmitted = false, senderMatches = null, linkMatches = null,
            senderAssessment = null, linkAssessment = null,
        )
    }
    class Factory(private val preferences: LanguagePreferences, private val repository: LearnerRepository? = null) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>, extras: CreationExtras): T {
            require(modelClass.isAssignableFrom(PracticeViewModel::class.java))
            return PracticeViewModel(extras.createSavedStateHandle(), preferences, repository) as T
        }
    }
}

data class LearnerUiState(
    val signedIn: Boolean = false,
    val busy: Boolean = false,
    val failed: Boolean = false,
    val snapshot: LearnerSnapshot? = null,
    val reportRevision: Int = 0,
)
