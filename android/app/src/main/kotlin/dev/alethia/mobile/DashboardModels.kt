package dev.alethia.mobile

enum class DashboardQuestKind {
    DailyLogin,
    CompleteModule,
    SubmitReport,
}

data class DashboardQuestState(
    val kind: DashboardQuestKind,
    val progress: Int,
    val target: Int,
    val rewardPoints: Int,
    val rewardCredits: Int = 0,
    val accepted: Boolean = false,
    val claimed: Boolean = false,
    val id: String = "",
    val questDate: String = "",
    val title: String? = null,
    val description: String? = null,
)

data class DashboardReportSummary(
    val uploaded: Int,
    val verified: Int,
    val pending: Int,
)

data class DashboardUiState(
    val displayName: String,
    val streakDays: Int,
    val points: Int,
    val pointsForNextLevel: Int = 150,
    val quests: List<DashboardQuestState>,
    val isPreview: Boolean,
    val hasUnreadNotifications: Boolean = false,
    val credits: Int = 0,
    val featuredQuestKind: DashboardQuestKind? = null,
    val reportSummary: DashboardReportSummary? = null,
) {
    companion object {
        fun preview() = DashboardUiState(
            displayName = "Alya",
            reportSummary = DashboardReportSummary(uploaded = 8, verified = 5, pending = 3),
            streakDays = 4,
            points = 120,
            pointsForNextLevel = 150,
            hasUnreadNotifications = true,
            featuredQuestKind = DashboardQuestKind.CompleteModule,
            quests = listOf(
                DashboardQuestState(
                    DashboardQuestKind.DailyLogin,
                    progress = 0,
                    target = 2,
                    rewardPoints = 150,
                    rewardCredits = 40,
                ),
                DashboardQuestState(
                    DashboardQuestKind.CompleteModule,
                    progress = 0,
                    target = 2,
                    rewardPoints = 200,
                    rewardCredits = 60,
                ),
                DashboardQuestState(
                    DashboardQuestKind.SubmitReport,
                    progress = 0,
                    target = 2,
                    rewardPoints = 250,
                    rewardCredits = 80,
                ),
            ),
            isPreview = true,
        )
    }
}
