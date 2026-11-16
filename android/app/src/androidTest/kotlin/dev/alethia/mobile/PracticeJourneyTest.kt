package dev.alethia.mobile

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.alethia.core.*
import kotlinx.coroutines.runBlocking
import io.github.jan.supabase.auth.auth
import androidx.lifecycle.ViewModelProvider
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PracticeJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val learning get() = ViewModelProvider(compose.activity)[LearningViewModel::class.java]
    private val nav get() = ViewModelProvider(compose.activity)[PracticeViewModel::class.java]
    private val reports get() = ViewModelProvider(compose.activity)[ReportsViewModel::class.java]

    @Before fun resetLanguage() {
        runBlocking {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AlethiaApplication
            app.container.client?.auth?.awaitInitialization()
            app.container.client?.auth?.clearSession()
            LanguagePreferences(app).setLanguage("id")
        }
        compose.waitForIdle()
        compose.runOnIdle { learning.open(ModuleId.CourierSms, restart = true); nav.navigate(Screen.Welcome) }
        compose.waitUntil(10000) { !learning.ui.value.busy }
    }
    private fun tap(tag: String, scroll: Boolean = false) {
        val node = compose.onNodeWithTag(tag)
        if (scroll) node.performScrollTo()
        node.performClick()
    }
    private fun capture(name: String) {
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val file = java.io.File(instrumentation.targetContext.getExternalFilesDir(null), "$name.png")
        file.outputStream().use { instrumentation.uiAutomation.takeScreenshot().compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        instrumentation.uiAutomation.executeShellCommand("cp ${file.absolutePath} /sdcard/Download/$name.png").use { descriptor ->
            java.io.FileInputStream(descriptor.fileDescriptor).use { it.readBytes() }
        }
    }
    private fun start() {
        tap("open_training"); tap("open_roadmap", true); tap("open_checkpoint", true); tap("start_checkpoint")
        compose.waitUntil(10000) { !learning.ui.value.busy && learning.ui.value.session?.state?.stage == 1 }
    }
    private fun inspect(sender: String = "sender_unverified") {
        tap("lesson_next")
        tap("copy_sender", true)
        tap("paste_sender_input", true)
        compose.onNodeWithTag("sender_input").assertTextContains(CourierEvidence.sender)
        compose.onNodeWithTag("link_input").performScrollTo().performTextInput(CourierEvidence.defangedLink)
        tap("compare_evidence", true)
        tap(sender, true); tap("link_suspicious", true); tap("lesson_next")
    }
    private fun finishSms() {
        compose.onNodeWithTag("tracking_input").performScrollTo().performTextInput(CourierEvidence.trackingNumber)
        compose.runOnIdle { assertEquals("tracking input", CourierEvidence.trackingNumber, learning.ui.value.session?.state?.trackingInput) }
        tap("check_tracking", true)
        compose.runOnIdle { assertTrue("official check", learning.ui.value.session?.state?.checked == true) }
        tap("lesson_next")
        compose.runOnIdle { assertEquals("decision stage", 4, learning.ui.value.session?.state?.stage) }
        tap("choose_report_delete", true); tap("lesson_next"); tap("complete_practice")
        compose.waitUntil(10000) { learning.ui.value.session?.state?.stage == 6 }
    }
    @Test fun completeGuestPracticeScores100AndCopyPasteWorks() {
        start(); inspect(); finishSms()
        compose.onNodeWithTag("practice_score").assertTextEquals("Skor: 100%")
        tap("retry_practice", true)
        compose.waitUntil(10000) { learning.ui.value.session?.state?.stage == 1 }
        compose.onNodeWithTag("lesson_next").assertExists()
    }
    @Test fun pastingUnchangedEvidenceKeepsAssessmentAndNextEnabled() {
        start(); tap("lesson_next")
        tap("copy_sender", true); tap("paste_sender_input", true)
        compose.onNodeWithTag("link_input").performScrollTo().performTextInput(CourierEvidence.defangedLink)
        tap("compare_evidence", true); tap("sender_unverified", true); tap("link_suspicious", true)
        tap("paste_sender_input", true)
        compose.onNodeWithTag("lesson_next").assertIsEnabled()
        compose.onNodeWithTag("sender_input").performScrollTo().performTextReplacement("different sender")
        compose.onNodeWithTag("lesson_next").assertIsNotEnabled()
    }

    @Test fun incorrectSenderAssessmentScores75() {
        start(); inspect("sender_trusted"); finishSms()
        compose.onNodeWithTag("practice_score").assertTextEquals("Skor: 75%")
    }
    @Test fun recreationAndDurableStorePreserveUnfinishedPractice() {
        start(); tap("lesson_next")
        compose.onNodeWithTag("sender_input").performScrollTo().performTextInput(CourierEvidence.sender)
        compose.runOnIdle { assertEquals("state before recreate", CourierEvidence.sender, learning.ui.value.session?.state?.senderInput) }
        compose.activityRule.scenario.recreate()
        compose.waitForIdle()
        compose.runOnIdle { assertEquals("state after recreate", CourierEvidence.sender, learning.ui.value.session?.state?.senderInput) }
        compose.onNodeWithTag("sender_input").assertTextContains(CourierEvidence.sender)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertEquals(CourierEvidence.sender, LearningDraftStore(context).load("guest", ModuleId.CourierSms)?.state?.senderInput)
    }
    @Test fun hostedRecoveryRebasesDirtyNextCheckpointAfterPreviousStageWasSynced() {
        val host = java.net.URI(BuildConfig.SUPABASE_URL).host
        org.junit.Assume.assumeTrue(host == "zbeaiphxmmwutzmqydlk.supabase.co" &&
            InstrumentationRegistry.getArguments().getString("alethiaHostedAudit") == "true")
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AlethiaApplication
        val auth = app.container.authRepository
        val repo = app.container.learnerRepository!!
        val username = "recovery_${java.util.UUID.randomUUID().toString().replace("-", "").take(12)}"
        val password = "RecoveryOnly_${java.util.UUID.randomUUID()}"
        try {
            tap("start_auth"); tap("go_to_signup", true)
            compose.onNodeWithTag("signup_username").performScrollTo().performTextInput(username)
            compose.onNodeWithTag("signup_email").performScrollTo().performTextInput("$username@example.test")
            compose.onNodeWithTag("signup_password").performScrollTo().performTextInput(password)
            compose.onNodeWithTag("signup_confirm_password").performScrollTo().performTextInput(password)
            tap("signup_submit", true)
            compose.waitUntil(20000) { learning.ui.value.signedIn && nav.backend.value.snapshot != null }

            val opened = runBlocking { repo.openLearning(ModuleId.CourierSms, restart = true) }
            val stageTwo = LearningState(ModuleId.CourierSms, stage = 2,
                senderInput = CourierEvidence.sender, linkInput = CourierEvidence.defangedLink,
                compared = true, sender = SenderAssessment.Unverified, link = LinkAssessment.Suspicious)
            val syncedStageTwo = runBlocking { repo.saveLearning(opened.copy(state = stageTwo)) }
            assertEquals(2, syncedStageTwo.state.stage)
            val userId = app.container.client!!.auth.currentUserOrNull()!!.id
            val store = LearningDraftStore(app)
            // Recreate the crash window: stage 2 reached Supabase, while the later local Next
            // checkpoint was persisted before its revision update reached SharedPreferences.
            val pendingStageThree = syncedStageTwo.copy(
                revision = (syncedStageTwo.revision - 1).coerceAtLeast(0),
                state = syncedStageTwo.state.copy(stage = 3), dirty = true,
            )
            store.save(userId, pendingStageThree)

            val recovered = LearningViewModel(repo, store)
            compose.waitUntil(30000) {
                val session = recovered.ui.value.sessions[ModuleId.CourierSms]
                session != null && !session.dirty
            }
            assertEquals(3, recovered.ui.value.sessions[ModuleId.CourierSms]?.state?.stage)
            runBlocking {
                val hosted = repo.learningSessions().first { it.state.module == ModuleId.CourierSms }
                assertEquals(3, hosted.state.stage)
                assertFalse(store.load(userId, ModuleId.CourierSms)!!.dirty)
            }
        } finally {
            runBlocking {
                if (app.container.client?.auth?.currentAccessTokenOrNull() == null) auth.signIn(username, password)
                val token = app.container.client?.auth?.currentAccessTokenOrNull()
                if (token != null) {
                    val connection = java.net.URL("${BuildConfig.API_BASE_URL}/api/auth/delete-account").openConnection() as java.net.HttpURLConnection
                    try {
                        connection.requestMethod = "POST"; connection.connectTimeout = 15000; connection.readTimeout = 15000
                        connection.setRequestProperty("Authorization", "Bearer $token")
                        connection.setRequestProperty("Content-Type", "application/json")
                        connection.doOutput = true
                        connection.outputStream.use { it.write(org.json.JSONObject().put("confirm", "HAPUS AKUN SAYA").toString().toByteArray()) }
                        assertEquals(200, connection.responseCode)
                    } finally { connection.disconnect() }
                }
                app.container.client?.auth?.clearSession()
            }
        }
    }
    @Test fun allThreeNativeExercisesCanBeCompletedAndRecovered() {
        start(); capture("module-1-sms"); inspect(); finishSms()
        compose.runOnIdle { learning.open(ModuleId.SocialEngineering, restart = true) }
        compose.waitUntil(10000) { learning.ui.value.session?.state?.module == ModuleId.SocialEngineering && !learning.ui.value.busy }
        capture("module-2-social")
        tap("artifact_visual", true); tap("artifact_career", true)
        tap("lesson_next"); tap("lesson_next"); tap("lesson_next")
        tap("mitigation_verify", true); tap("lesson_next"); tap("complete_practice")
        compose.waitUntil(10000) { learning.ui.value.session?.state?.stage == 6 }
        assertNull(learning.ui.value.session?.result?.score)
        compose.runOnIdle { learning.open(ModuleId.ExecutableFile, restart = true) }
        compose.waitUntil(10000) { learning.ui.value.session?.state?.module == ModuleId.ExecutableFile && !learning.ui.value.busy }
        capture("module-3-file")
        tap("lesson_next")
        tap("inspect_filename", true); compose.onNodeWithText("Tutup detail").performClick()
        tap("inspect_extension", true); compose.onNodeWithText("Tutup detail").performClick()
        tap("lesson_next"); tap("file_check_official", true); tap("lesson_next")
        tap("choose_report", true); tap("lesson_next"); tap("complete_practice")
        compose.waitUntil(10000) { learning.ui.value.session?.state?.stage == 6 }
        compose.onNodeWithTag("practice_score").assertTextEquals("Skor: 100%")
        val store = LearningDraftStore(InstrumentationRegistry.getInstrumentation().targetContext)
        ModuleId.entries.forEach { assertEquals(6, store.load("guest", it)?.state?.stage) }
    }
    @Test fun signedInNativeLessonsPersistRewardsAndUnlockTheNextModule() {
        val host = java.net.URI(BuildConfig.SUPABASE_URL).host
        org.junit.Assume.assumeTrue(host in setOf("10.0.2.2", "127.0.0.1", "localhost") ||
            (host == "zbeaiphxmmwutzmqydlk.supabase.co" && InstrumentationRegistry.getArguments().getString("alethiaHostedAudit") == "true"))
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AlethiaApplication
        val auth = app.container.authRepository
        val repo = app.container.learnerRepository!!
        val username = "native_${java.util.UUID.randomUUID().toString().replace("-", "").take(12)}"
        val password = "NativeOnly_${java.util.UUID.randomUUID()}"
        try {
            tap("start_auth"); tap("go_to_signup", true)
            compose.onNodeWithTag("signup_username").performScrollTo().performTextInput(username)
            compose.onNodeWithTag("signup_email").performScrollTo().performTextInput("$username@example.test")
            compose.onNodeWithTag("signup_password").performScrollTo().performTextInput(password)
            compose.onNodeWithTag("signup_confirm_password").performScrollTo().performTextInput(password)
            tap("signup_submit", true)
            compose.waitUntil(20000) { learning.ui.value.signedIn && nav.backend.value.snapshot != null }
            val before = nav.dashboardUiState.value.points
            fun startCategory(category: ModuleCategory) {
                compose.runOnIdle { nav.selectModuleCategory(category); nav.navigate(Screen.Modules) }
                tap("open_roadmap", true); tap("open_checkpoint", true); tap("start_checkpoint")
                compose.waitUntil(15000) { !learning.ui.value.busy && learning.ui.value.session?.state?.module == category.moduleId() }
                assertFalse("lesson opened", learning.ui.value.failed)
            }
            startCategory(ModuleCategory.Phishing); inspect()
            // Establish the checkpoint before changing lifecycle; a queued UI click is not a rollback.
            compose.runOnIdle { assertEquals("checkpoint before background", 3, learning.ui.value.session?.state?.stage) }
            val accountId = app.container.client!!.auth.currentUserOrNull()!!.id
            val store = LearningDraftStore(app)
            assertEquals(3, store.load(accountId, ModuleId.CourierSms)?.state?.stage)
            compose.activityRule.scenario.moveToState(androidx.lifecycle.Lifecycle.State.CREATED)
            Thread.sleep(1000) // Process lifecycle deliberately refreshes Auth after backgrounding.
            compose.activityRule.scenario.moveToState(androidx.lifecycle.Lifecycle.State.RESUMED)
            compose.waitForIdle()
            assertTrue(learning.ui.value.signedIn)
            assertEquals(3, learning.ui.value.session?.state?.stage)
            assertEquals(Screen.Courier, nav.screen.value)
            compose.waitUntil(30000) { learning.ui.value.session?.dirty == false }
            runBlocking { assertEquals(3, repo.learningSessions().first { it.state.module == ModuleId.CourierSms }.state.stage) }
            compose.activityRule.scenario.recreate()
            compose.waitUntil(30000) { !learning.ui.value.busy }
            // Navigation survives recreation; reopening must recover the same hosted checkpoint.
            compose.runOnIdle { learning.open(ModuleId.CourierSms) }
            compose.waitUntil(30000) { !learning.ui.value.busy }
            compose.runOnIdle { assertEquals(3, learning.ui.value.session?.state?.stage) }
            finishSms()
            compose.waitUntil(15000) { !learning.ui.value.busy && nav.backend.value.snapshot?.modules?.get("social-engineering") == "available" }
            assertFalse("result synced", learning.ui.value.session!!.dirty)
            startCategory(ModuleCategory.SocialEngineering)
            tap("artifact_visual", true); tap("artifact_family", true)
            tap("lesson_next"); tap("lesson_next"); tap("lesson_next")
            tap("mitigation_limit", true); tap("lesson_next"); tap("complete_practice")
            compose.waitUntil(15000) { nav.backend.value.snapshot?.modules?.get("executable-file") == "available" && !learning.ui.value.busy }
            startCategory(ModuleCategory.MaliciousDocument)
            tap("lesson_next")
            tap("inspect_filename", true); compose.onNodeWithText("Tutup detail").performClick()
            tap("inspect_extension", true); compose.onNodeWithText("Tutup detail").performClick()
            tap("lesson_next"); tap("file_check_official", true); tap("lesson_next")
            tap("choose_report", true); tap("lesson_next"); tap("complete_practice")
            compose.waitUntil(15000) { !learning.ui.value.busy && nav.backend.value.snapshot?.modules?.values?.all { it == "completed" } == true }
            assertEquals(before + 100, nav.dashboardUiState.value.points)
            assertTrue(nav.dashboardUiState.value.quests.any { it.kind == DashboardQuestKind.CompleteModule && it.progress >= it.target })
            capture("module-3-account-result")
            tap("lesson_roadmap")
            tap("main_nav_achievements")
            compose.onNodeWithText("Pencapaian", useUnmergedTree = true).assertExists()
            assertTrue(nav.backend.value.snapshot!!.achievements.isNotEmpty())
            compose.onNodeWithContentDescription("Notifikasi").performClick()
            compose.onNodeWithText("Notifikasi", useUnmergedTree = true).assertExists()
            compose.waitUntil(30000) { !nav.backend.value.busy }
            repeat(nav.backend.value.snapshot!!.notifications.count { !it.isRead }) {
                compose.onAllNodesWithText("Tandai sudah dibaca").onFirst().performScrollTo().performClick()
                compose.waitUntil(30000) { !nav.backend.value.busy }
            }
            assertTrue("notifications read after explicit action", runBlocking { !repo.load().dashboard.hasUnreadNotifications })
            compose.runOnIdle { compose.activity.onBackPressedDispatcher.onBackPressed() }
            tap("open_profile")
            tap("profile_language_en", true)
            compose.waitUntil(30000) { !nav.backend.value.busy }
            compose.activityRule.scenario.recreate()
            compose.onNodeWithTag("profile_language_en").assertIsSelected()
            tap("profile_language_id", true)
            compose.runOnIdle { nav.navigate(Screen.Reports) }
            compose.waitUntil(30000) {
                reports.list.value.signedIn && !reports.list.value.loading &&
                    reports.list.value.role == ReportRole.Investigator
            }
            val reportTitle = "Hosted report $username"
            tap("reports_add", true)
            compose.onNodeWithTag("report_title_input").performScrollTo().performTextInput(reportTitle)
            compose.onNodeWithTag("report_evidence_input").performScrollTo()
                .performTextInput("Synthetic message evidence for hosted UI verification")
            compose.onNodeWithTag("report_risk_input").performScrollTo()
                .performTextInput("Unknown sender requests payment using a suspicious link")
            compose.onNodeWithTag("report_url_input").performScrollTo()
                .performTextInput("https://bank.example/login")
            tap("report_save", true)
            compose.waitUntil(30000) {
                reports.detail.value.report?.title == reportTitle && !reports.detail.value.loading
            }
            val reportId = reports.detail.value.report!!.id
            val reportRepository = app.container.reportsRepository!!
            runBlocking {
                val savedReport = reportRepository.loadReport(reportId)!!
                assertEquals(reportTitle, savedReport.title)
                assertEquals("bank[.]example/login", savedReport.defangedUrl)
                assertTrue(savedReport.isOwner)
            }

            tap("report_signal", true)
            compose.waitUntil(30000) { reports.detail.value.report?.hasSignaled == true }
            compose.onNodeWithTag("report_note_input").performScrollTo()
                .performTextInput("Verified the sender domain against the official site.")
            tap("report_note_submit", true)
            compose.waitUntil(30000) {
                reports.detail.value.notes.any { it.text == "Verified the sender domain against the official site." }
            }
            compose.onNodeWithTag("report_verdict_reason").performScrollTo()
                .performTextInput("The sender domain does not match the official source.")
            tap("report_verdict_valid", true)
            compose.waitUntil(30000) { reports.detail.value.verdictTotals.valid == 1 }

            tap("report_edit", true)
            compose.onNodeWithTag("report_title_input").performScrollTo()
                .performTextReplacement("$reportTitle revised")
            tap("report_save", true)
            compose.waitUntil(30000) {
                reports.detail.value.report?.title == "$reportTitle revised" && !reports.detail.value.loading
            }
            tap("report_delete", true)
            compose.onNodeWithText(compose.activity.getString(R.string.reports_delete_confirm))
                .performClick()
            compose.waitUntil(30000) {
                !reports.list.value.loading && reports.list.value.reports.none { it.id == reportId }
            }
            runBlocking {
                assertNull(reportRepository.loadReport(reportId))
                assertTrue(
                    reportRepository.loadPage(ReportScope.Mine, ReportSort.Newest, null)
                        .reports.none { it.id == reportId },
                )
            }

            runBlocking {
                val sessions = repo.learningSessions()
                assertEquals(3, sessions.size)
                assertTrue(sessions.all { it.state.stage == 6 })
                repo.signOut()
                assertEquals(AuthResult.SignedIn, auth.signIn(username, password))
                assertTrue(repo.load().modules.values.all { it == "completed" })
                assertEquals(3, repo.learningSessions().size)
            }
        } finally {
            runBlocking {
                if (app.container.client?.auth?.currentAccessTokenOrNull() == null) auth.signIn(username, password)
                val token = app.container.client?.auth?.currentAccessTokenOrNull()
                if (token != null) {
                    val userId = app.container.client!!.auth.currentUserOrNull()!!.id
                    val reports = java.net.URL("${BuildConfig.SUPABASE_URL}/rest/v1/practice_reports?user_id=eq.$userId").openConnection() as java.net.HttpURLConnection
                    try {
                        reports.requestMethod = "DELETE"; reports.connectTimeout = 15000; reports.readTimeout = 15000
                        reports.setRequestProperty("apikey", BuildConfig.SUPABASE_PUBLISHABLE_KEY)
                        reports.setRequestProperty("Authorization", "Bearer $token")
                        assertTrue("synthetic report cleanup", reports.responseCode in 200..299)
                    } finally { reports.disconnect() }
                    val connection = java.net.URL("${BuildConfig.API_BASE_URL}/api/auth/delete-account").openConnection() as java.net.HttpURLConnection
                    try {
                        connection.requestMethod = "POST"; connection.connectTimeout = 15000; connection.readTimeout = 15000
                        connection.setRequestProperty("Authorization", "Bearer $token")
                        connection.setRequestProperty("Content-Type", "application/json")
                        connection.doOutput = true
                        connection.outputStream.use { it.write(org.json.JSONObject().put("confirm", "HAPUS AKUN SAYA").toString().toByteArray()) }
                        assertEquals(200, connection.responseCode)
                    } finally { connection.disconnect() }
                }
                app.container.client?.auth?.clearSession()
            }
        }
    }
    @Test fun languageChoiceSurvivesActivityRecreation() {
        tap("open_training")
        compose.onNodeWithTag("open_profile").performClick()
        compose.onNodeWithTag("profile_language_en").performScrollTo().performClick()
        compose.activityRule.scenario.recreate()
        compose.onNodeWithTag("profile_language_en").assertIsSelected()
    }
}
