package dev.alethia.mobile

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.status.SessionStatus
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.retryWhen
import kotlinx.coroutines.delay
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import dev.alethia.core.ModuleId

/** Caller JWT is the authority. No server credentials or client-authored scores. */
class LearnerRepository(
    private val client: SupabaseClient,
    private val url: String,
    private val publicKey: String,
) {
    val identity = client.auth.sessionStatus.filter {
        // SDK lifecycle refresh is not a sign-out; retain the owner and recovery state while it runs.
        it !is SessionStatus.Initializing && it !is SessionStatus.RefreshFailure
    }.map {
        if (it is SessionStatus.Authenticated) {
            it.session.user?.id ?: client.auth.retrieveUserForCurrentSession(updateSession = true).id
        } else null
    }.retryWhen { cause, _ ->
        if (cause is CancellationException) false else { delay(3000); true }
    }.distinctUntilChanged()

    suspend fun signOut() = client.auth.signOut()

    internal suspend fun request(
        path: String,
        method: String = "GET",
        body: JSONObject? = null,
        prefer: String? = null,
    ): String {
        val owner = client.auth.currentUserOrNull()?.id ?: error("Authentication required")
        for (attempt in 0..1) {
            val token = client.auth.currentAccessTokenOrNull() ?: error("Authentication required")
            val response = withContext(Dispatchers.IO) {
                val connection = URL("${url.trimEnd('/')}/rest/v1/$path").openConnection() as HttpURLConnection
                try {
                    connection.requestMethod = method
                    connection.connectTimeout = 15000
                    connection.readTimeout = 30000
                    connection.setRequestProperty("apikey", publicKey)
                    connection.setRequestProperty("Authorization", "Bearer $token")
                    connection.setRequestProperty("Accept", "application/json")
                    if (method == "HEAD") connection.setRequestProperty("Prefer", "count=exact")
                    else if (prefer != null) connection.setRequestProperty("Prefer", prefer)
                    if (body != null) {
                        connection.doOutput = true
                        connection.setRequestProperty("Content-Type", "application/json")
                        connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
                    }
                    val code = connection.responseCode
                    val raw = if (method == "HEAD" && code in 200..299) {
                        connection.getHeaderField("Content-Range")?.substringAfterLast('/') ?: error("Missing count")
                    } else if (code == 204) {
                        ""
                    } else (if (code in 200..299) connection.inputStream else connection.errorStream)
                        ?.bufferedReader()?.use { it.readText() }.orEmpty()
                    code to raw
                } finally { connection.disconnect() }
            }
            client.auth.awaitInitialization()
            check(client.auth.currentUserOrNull()?.id == owner) { "Account changed during ${path.substringBefore('?')} (HTTP ${response.first}; sessionPresent=${client.auth.currentUserOrNull() != null})" }
            if (response.first == 401 && attempt == 0) {
                client.auth.refreshCurrentSession()
                check(client.auth.currentUserOrNull()?.id == owner) { "Account changed" }
                continue
            }
            if (response.first !in 200..299) throw LearnerRequestException(response.first)
            return response.second
        }
        error("Authentication required")
    }

    suspend fun rpc(name: String, body: JSONObject = JSONObject()): String = request("rpc/$name", "POST", body)

    suspend fun currentUserId(): String? = client.auth.currentUserOrNull()?.id

    /** Server-authoritative investigator gate; failures fall back to the student UI. */
    suspend fun isInvestigator(): Boolean = rpc("is_investigator").trim() == "true"

    suspend fun load(): LearnerSnapshot {
        rpc("record_daily_activity", JSONObject().put("requested_timezone", java.util.TimeZone.getDefault().id))
        val state = JSONObject(rpc("get_dashboard_state"))
        val owner = state.getJSONObject("profile").getString("id")
        // Explicit owner filters keep community-visible reports out of the personal list.
        val reports = JSONArray(request("practice_reports?user_id=eq.$owner&select=id,title,review_status,created_at&order=created_at.desc&limit=100"))
        val notifications = JSONArray(request("notifications?user_id=eq.$owner&select=id,title,body,is_read,created_at&order=created_at.desc&limit=100"))
        val selectedBadges = JSONArray(request("user_profile_badges?user_id=eq.$owner&selected=eq.true&select=badge_code"))
        val investigationCount = request("report_investigation_notes?user_id=eq.$owner&select=id", "HEAD").toInt()
        val counts = JSONArray()
        for (status in listOf("approved", "queued", "rejected")) {
            val count = request("practice_reports?user_id=eq.$owner&review_status=eq.$status&select=id", "HEAD").toInt()
            counts.put(JSONObject().put("review_status", status).put("count", count))
        }
        return parseLearnerSnapshot(state, reports, notifications, counts, selectedBadges, investigationCount)
    }

    suspend fun beginAttempt(module: ModuleId = ModuleId.CourierSms): String = org.json.JSONTokener(
        rpc("begin_verified_practice_attempt", JSONObject().put("requested_module_id", module.wireId)),
    ).nextValue() as String

    suspend fun completeAttempt(id: String, decisions: List<String>): Int = completeLearningAttempt(id, decisions).score
        ?: error("Unscored module has no numeric score")

    suspend fun completeLearningAttempt(id: String, decisions: List<String>): LearningResult {
        val result = JSONArray(rpc("complete_verified_practice_attempt",
            JSONObject().put("requested_attempt_id", id).put("requested_decisions", JSONArray(decisions)))).getJSONObject(0)
        return LearningResult(if (result.isNull("score")) null else result.getInt("score"),
            if (result.isNull("perfect")) null else result.getBoolean("perfect"))
    }
    suspend fun learningSessions(): List<LearningSession> = JSONArray(rpc("get_learning_sessions")).objects().map(::decodeSession)
    suspend fun openLearning(module: ModuleId, restart: Boolean): LearningSession = decodeSession(JSONObject(rpc("open_learning_session",
        JSONObject().put("requested_module_id", module.wireId).put("requested_restart", restart))))
    suspend fun saveLearning(session: LearningSession): LearningSession {
        val payload = encodeLearningState(session.state).put("result", session.result?.let {
            JSONObject().put("score", it.score ?: JSONObject.NULL).put("perfect", it.perfect ?: JSONObject.NULL)
        })
        return decodeSession(JSONObject(rpc("save_learning_session", JSONObject()
            .put("requested_attempt_id", session.attemptId).put("requested_revision", session.revision).put("requested_state", payload))))
    }

    suspend fun claim(quest: DashboardQuestState) {
        rpc("claim_daily_quest", JSONObject().put("requested_quest_id", quest.id).put("requested_quest_date", quest.questDate))
    }

    suspend fun markRead(id: String) { rpc("mark_notification_read", JSONObject().put("requested_notification_id", id)) }

    suspend fun submitReport(title: String, evidence: String, risk: String) {
        val profile = JSONObject(rpc("get_dashboard_state")).getJSONObject("profile")
        request("practice_reports", "POST", JSONObject()
            .put("user_id", profile.getString("id")).put("author_username", profile.getString("username"))
            .put("title", title.trim()).put("category", "SMS phishing").put("channel", "Text message")
            .put("pattern", "Suspicious SMS").put("evidence", evidence.trim()).put("why_risky", risk.trim()))
    }

    suspend fun setLocale(locale: String) {
        val owner = client.auth.currentUserOrNull()?.id ?: error("Authentication required")
        request("profiles?id=eq.$owner", "PATCH", JSONObject().put("preferred_locale", locale))
    }

    suspend fun setDisplayName(name: String) {
        val owner = client.auth.currentUserOrNull()?.id ?: error("Authentication required")
        request("profiles?id=eq.$owner", "PATCH", JSONObject().put("display_name", name.trim()))
    }

    suspend fun setPassword(password: String) {
        client.auth.updateUser { this.password = password }
    }

    suspend fun setBadge(code: String, selected: Boolean) {
        rpc("set_profile_badge", JSONObject().put("requested_badge_code", code).put("requested_selected", selected))
    }
}

class LearnerRequestException(val status: Int) : Exception("Learner API request failed ($status)")
data class LearnerRow(val id: String, val title: String, val detail: String, val isRead: Boolean = true)
data class ProfileState(
    val username: String,
    val displayName: String,
    val level: Int,
    val points: Int,
    val modulesCompleted: Int,
    val mastery: String,
    val dailyCurrent: Int,
    val dailyLongest: Int,
    val practiceCurrent: Int,
    val practiceLongest: Int,
    val unlockedBadges: Set<String>,
    val equippedBadges: Set<String>,
    val reportCount: Int,
    val approvedReportCount: Int,
    val investigationCount: Int,
)
data class LearnerSnapshot(
    val dashboard: DashboardUiState,
    val modules: Map<String, String>,
    val achievements: List<LearnerRow>,
    val reports: List<LearnerRow>,
    val notifications: List<LearnerRow>,
    val locale: String,
    val profile: ProfileState,
    val moduleScores: Map<String, Int?> = emptyMap(),
)

internal fun parseLearnerSnapshot(state: JSONObject, reports: JSONArray, notifications: JSONArray, counts: JSONArray, selectedBadges: JSONArray = JSONArray(), investigationCount: Int = 0): LearnerSnapshot {
    val profile = state.getJSONObject("profile")
    val points = profile.getInt("points")
    val quests = state.getJSONArray("quests").objects().mapNotNull { q ->
        val kind = when (q.getString("questType")) {
            "daily_login" -> DashboardQuestKind.DailyLogin
            "complete_module" -> DashboardQuestKind.CompleteModule
            "create_report" -> DashboardQuestKind.SubmitReport
            else -> return@mapNotNull null
        }
        DashboardQuestState(kind, q.getInt("progressValue"), q.getInt("targetValue"), q.getInt("rewardPoints"),
            accepted = true, claimed = q.getString("status") == "claimed",
            id = q.getString("id"), questDate = q.getString("questDate"),
            title = q.getString("title"), description = q.getString("description"))
    }
    val reportCounts = counts.objects().associate { it.getString("review_status") to it.getInt("count") }
    val unlocked = state.getJSONArray("achievements").objects().map { it.getString("code") }.toSet()
    val daily = state.getJSONObject("dailyStreak")
    val practice = state.getJSONObject("practiceStreak")
    val name = profile.optString("displayName").takeUnless { it.isBlank() || it == "null" } ?: profile.getString("username")
    return LearnerSnapshot(
        dashboard = DashboardUiState(
            displayName = name,
            streakDays = daily.getInt("current"), points = points,
            pointsForNextLevel = listOf(60, 150, 300, 550).firstOrNull { it > points } ?: maxOf(550, points),
            quests = quests, isPreview = false,
            hasUnreadNotifications = state.getJSONObject("notifications").getInt("unread") > 0,
            reportSummary = DashboardReportSummary(reportCounts.values.sum(), reportCounts["approved"] ?: 0, reportCounts["queued"] ?: 0),
        ),
        modules = state.getJSONArray("modules").objects().associate { it.getString("module_id") to it.getString("accessState") },
        achievements = state.getJSONArray("achievements").objects().map { LearnerRow(it.getString("code"), it.getString("code").replace('_', ' '), it.getString("awardedAt")) },
        reports = reports.objects().map { LearnerRow(it.getString("id"), it.getString("title"), it.getString("review_status")) },
        notifications = notifications.objects().map { LearnerRow(it.getString("id"), it.getString("title"), it.getString("body"), it.getBoolean("is_read")) },
        locale = profile.getString("preferredLocale"),
        profile = ProfileState(
            username = profile.getString("username"), displayName = name,
            level = profile.optInt("level", state.optInt("level", 1)), points = points,
            modulesCompleted = profile.optInt("modulesCompleted"), mastery = profile.optString("mastery", "none"),
            dailyCurrent = daily.getInt("current"), dailyLongest = daily.getInt("longest"),
            practiceCurrent = practice.getInt("current"), practiceLongest = practice.getInt("longest"),
            unlockedBadges = unlocked,
            equippedBadges = selectedBadges.objects().map { it.getString("badge_code") }.toSet(),
            reportCount = reportCounts.values.sum(),
            approvedReportCount = reportCounts["approved"] ?: 0,
            investigationCount = investigationCount,
        ),
        moduleScores = state.getJSONArray("modules").objects().associate { it.getString("module_id") to if (it.isNull("score")) null else it.getInt("score") },
    )
}
private fun JSONArray.objects() = (0 until length()).map { getJSONObject(it) }
