package dev.alethia.mobile

import androidx.test.ext.junit.runners.AndroidJUnit4
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.MemorySessionManager
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.createSupabaseClient
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import dev.alethia.core.ModuleId
import dev.alethia.core.LearningState
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LearnerIntegrationTest {
    @Test fun localAccountPersistsDashboardQuestsReportsAndVerifiedResults() = runBlocking {
        // Never create synthetic users or delete accounts on the hosted profile.
        assumeTrue(URI(BuildConfig.SUPABASE_URL).host in setOf("10.0.2.2", "127.0.0.1", "localhost"))
        val client = createSupabaseClient(BuildConfig.SUPABASE_URL, BuildConfig.SUPABASE_PUBLISHABLE_KEY) {
            install(Auth) { sessionManager = MemorySessionManager(); autoLoadFromStorage = true; autoSaveToStorage = false; enableLifecycleCallbacks = false }
        }
        val suffix = UUID.randomUUID().toString().replace("-", "").take(12)
        val username = "mobile_$suffix"
        val email = "$username@example.test"
        val password = "LocalOnly_${UUID.randomUUID()}"
        val auth = SupabaseAuthRepository(client, BuildConfig.API_BASE_URL)
        val repository = LearnerRepository(client, BuildConfig.SUPABASE_URL, BuildConfig.SUPABASE_PUBLISHABLE_KEY)
        try {
            client.auth.awaitInitialization()
            assertEquals(AuthResult.SignedIn, auth.signUp(username, email, password))
            var snapshot = repository.load()
            assertEquals(username, snapshot.dashboard.displayName)
            assertEquals(1, snapshot.dashboard.streakDays)
            assertFalse(snapshot.dashboard.isPreview)
            assertEquals("available", snapshot.modules["courier-sms"])
            assertEquals(0, snapshot.dashboard.reportSummary!!.uploaded)
            val daily = snapshot.dashboard.quests.first { it.kind == DashboardQuestKind.DailyLogin }
            assertTrue(daily.progress >= daily.target)
            repository.claim(daily)
            val afterClaim = repository.load().dashboard.points
            repository.claim(daily)
            assertEquals(afterClaim, repository.load().dashboard.points)
            val partial = repository.beginAttempt()
            assertEquals(75, repository.completeAttempt(partial, listOf("assess:sender_trusted", "assess:link_suspicious", "verify_official_channel", "choose:report_delete")))
            assertNotEquals("completed", repository.load().modules["courier-sms"])
            val attempt = repository.beginAttempt()
            val decisions = listOf("assess:sender_unverified", "assess:link_suspicious", "verify_official_channel", "choose:report_delete")
            assertEquals(100, repository.completeAttempt(attempt, decisions))
            assertEquals(100, repository.completeAttempt(attempt, decisions)) // Safe retry after a lost response.
            val social = repository.openLearning(ModuleId.SocialEngineering, false)
            val checkpoint = repository.saveLearning(social.copy(state = LearningState(ModuleId.SocialEngineering, stage = 2, artifacts = setOf("visual", "career"))))
            assertEquals(1L, checkpoint.revision)
            assertEquals(checkpoint.state, repository.learningSessions().first { it.state.module == ModuleId.SocialEngineering }.state)
            assertEquals(checkpoint.revision, repository.saveLearning(social.copy(state = checkpoint.state)).revision)
            val socialDecisions = listOf("artifact:visual", "artifact:career", "mitigation:verify", "complete:reconstruction")
            assertNull(repository.completeLearningAttempt(social.attemptId!!, socialDecisions).score)
            assertNull(repository.completeLearningAttempt(social.attemptId, socialDecisions).score)
            assertEquals("available", repository.load().modules["executable-file"])
            val file = repository.openLearning(ModuleId.ExecutableFile, false)
            val fileDecisions = listOf("inspect:filename", "inspect:extension", "verify_official_channel", "choose:report")
            assertEquals(100, repository.completeLearningAttempt(file.attemptId!!, fileDecisions).score)
            val afterAll = repository.load()
            assertTrue(afterAll.modules.values.all { it == "completed" })
            assertEquals(afterClaim + 100, afterAll.dashboard.points)
            val quest = afterAll.dashboard.quests.firstOrNull { it.kind == DashboardQuestKind.CompleteModule && it.progress >= it.target && !it.claimed }
            assertNotNull("completion updates daily module quest", quest)
            repository.claim(quest!!)
            val afterModuleQuest = repository.load().dashboard.points
            repository.claim(quest)
            assertEquals(afterModuleQuest, repository.load().dashboard.points)
            repository.submitReport("Synthetic SMS report", "Synthetic message evidence for local integration", "Requests a suspicious payment through an unverified link")
            repository.setLocale("en")
            snapshot = repository.load()
            assertEquals("completed", snapshot.modules["courier-sms"])
            assertEquals(1, snapshot.dashboard.reportSummary!!.uploaded)
            assertTrue(snapshot.reports.any { it.title == "Synthetic SMS report" })
            assertTrue(snapshot.achievements.isNotEmpty())
            assertEquals("en", snapshot.locale)
            snapshot.notifications.filter { !it.isRead }.forEach { repository.markRead(it.id) }
            assertFalse(repository.load().dashboard.hasUnreadNotifications)
            val expectedPoints = repository.load().dashboard.points
            repository.signOut()
            assertEquals(AuthResult.SignedIn, auth.signIn(username, password))
            assertEquals(expectedPoints, repository.load().dashboard.points)
            assertTrue(repository.load().modules.values.all { it == "completed" })
            assertTrue(repository.learningSessions().any { it.state.module == ModuleId.SocialEngineering })
        } finally {
            val token = client.auth.currentAccessTokenOrNull()
            if (token != null) {
                val connection = URL("${BuildConfig.API_BASE_URL}/api/auth/delete-account").openConnection() as HttpURLConnection
                try {
                    connection.requestMethod = "POST"
                    connection.connectTimeout = 15000; connection.readTimeout = 15000
                    connection.setRequestProperty("Authorization", "Bearer $token")
                    connection.setRequestProperty("Content-Type", "application/json")
                    connection.doOutput = true
                    connection.outputStream.use { it.write(JSONObject().put("confirm", "HAPUS AKUN SAYA").toString().toByteArray()) }
                    assertEquals("Synthetic account cleanup", 200, connection.responseCode)
                } finally { connection.disconnect() }
            }
            client.close()
        }
    }
}
