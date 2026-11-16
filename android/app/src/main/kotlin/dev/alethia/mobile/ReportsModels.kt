package dev.alethia.mobile

import org.json.JSONArray
import org.json.JSONObject

enum class ReportSort { Top, Newest, Oldest }

enum class ReportScope { All, Mine }

enum class ReportReviewStatus {
    Queued,
    Approved,
    Rejected;

    companion object {
        fun from(value: String?): ReportReviewStatus = when (value) {
            "approved" -> Approved
            "rejected" -> Rejected
            else -> Queued
        }
    }
}

enum class ReportRole { Student, Investigator }

enum class ReportError {
    AuthRequired,
    NotConfigured,
    NotFound,
    NotAllowed,
    InvalidInput,
    Network,
    Generic,
}

enum class ReportValidationError {
    TitleLength,
    EvidenceLength,
    RiskLength,
    UrlTooLong,
    ScreenshotTooLarge,
    ImageUnreadable,
    ImageType,
    NoteLength,
    VerdictReasonLength,
}

enum class ReportNotice {
    SignalAdded,
    SignalRemoved,
    NoteAdded,
    VerdictSaved,
}

val REPORT_CATEGORIES: List<String> = listOf(
    "SMS phishing",
    "Marketplace scam",
    "Account impersonation",
)

val REPORT_CHANNELS: List<String> = listOf(
    "Text message",
    "Marketplace chat",
    "Direct message",
)

val REPORT_PATTERNS: List<String> = listOf(
    "Urgency",
    "Trust transfer",
    "Channel shift",
    "Unusual payment request",
)

const val MAX_REPORT_SCREENSHOT_BYTES: Int = 500 * 1024
internal const val MAX_REPORT_SCREENSHOT_DATA_BYTES: Int = 700_000

data class PracticeReport(
    val id: String,
    val userId: String,
    val moduleId: String?,
    val attemptId: String?,
    val title: String,
    val category: String,
    val channel: String,
    val pattern: String,
    val author: String,
    val createdAt: String,
    val updatedAt: String,
    val status: String,
    val review: ReportReviewStatus,
    val evidence: String = "",
    val whyRisky: String = "",
    val defangedUrl: String? = null,
    val screenshotDataUrl: String? = null,
    val signalScore: Int = 0,
    val hasSignaled: Boolean = false,
    val isOwner: Boolean = false,
    val reviewerFeedback: String? = null,
    val investigatorVerdict: String? = null,
)

data class ReportCursor(
    val signalScore: Int? = null,
    val createdAt: String,
    val id: String,
)

data class ReportPage(
    val reports: List<PracticeReport>,
    val nextCursor: ReportCursor?,
    val hasMore: Boolean,
)

data class ReportInput(
    val title: String,
    val category: String,
    val channel: String,
    val pattern: String,
    val evidence: String,
    val whyRisky: String,
    val defangedUrl: String? = null,
    val screenshotDataUrl: String? = null,
)

data class InvestigationNote(
    val id: String,
    val reportId: String,
    val authorRole: ReportRole,
    val authorUsername: String?,
    val text: String,
    val createdAt: String,
)

data class ReportVerdict(
    val userId: String,
    val authorUsername: String?,
    val verdict: String,
    val reason: String,
    val updatedAt: String,
)

data class ReportVerdictTotals(
    val valid: Int = 0,
    val invalid: Int = 0,
)

data class SignalResult(
    val active: Boolean,
    val score: Int,
)

class ReportException(val error: ReportError, cause: Throwable? = null) : Exception(error.name, cause)

internal fun Throwable.toReportError(): ReportError = when (this) {
    is ReportException -> error
    is LearnerRequestException -> when (status) {
        401 -> ReportError.AuthRequired
        403 -> ReportError.NotAllowed
        404 -> ReportError.NotFound
        400, 409, 422 -> ReportError.InvalidInput
        else -> ReportError.Generic
    }
    is java.io.IOException -> ReportError.Network
    else -> ReportError.Generic
}

fun defangReportUrl(value: String): String =
    value.trim()
        .replace(Regex("^https?://", RegexOption.IGNORE_CASE), "")
        .replace(".", "[.]")

internal fun JSONArray.jsonObjects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }

internal fun JSONObject.nullableString(name: String): String? =
    if (!has(name) || isNull(name)) null else optString(name).takeIf { it.isNotBlank() }

internal fun parseReport(
    row: JSONObject,
    currentUserId: String?,
    hasSignaled: Boolean,
): PracticeReport? {
    val id = row.nullableString("id") ?: return null
    val userId = row.nullableString("user_id") ?: return null
    val title = row.nullableString("title") ?: return null
    val category = row.nullableString("category") ?: return null
    val channel = row.nullableString("channel") ?: return null
    val pattern = row.nullableString("pattern") ?: return null
    val author = row.nullableString("author_username") ?: return null
    val createdAt = row.nullableString("created_at") ?: return null
    val updatedAt = row.nullableString("updated_at") ?: return null
    val status = row.nullableString("status") ?: return null
    return PracticeReport(
        id = id,
        userId = userId,
        moduleId = row.nullableString("module_id"),
        attemptId = row.nullableString("attempt_id"),
        title = title,
        category = category,
        channel = channel,
        pattern = pattern,
        author = author,
        createdAt = createdAt,
        updatedAt = updatedAt,
        status = status,
        review = ReportReviewStatus.from(row.nullableString("review_status")),
        evidence = row.nullableString("evidence").orEmpty(),
        whyRisky = row.nullableString("why_risky").orEmpty(),
        defangedUrl = row.nullableString("defanged_url"),
        screenshotDataUrl = row.nullableString("screenshot_data_url"),
        signalScore = row.optInt("signal_score", 0).coerceAtLeast(0),
        hasSignaled = hasSignaled,
        isOwner = userId == currentUserId,
        reviewerFeedback = row.nullableString("reviewer_feedback"),
        investigatorVerdict = row.nullableString("investigator_verdict"),
    )
}

internal fun parseNote(row: JSONObject): InvestigationNote? {
    val id = row.nullableString("id") ?: return null
    val reportId = row.nullableString("report_id") ?: return null
    val text = row.nullableString("text") ?: return null
    val createdAt = row.nullableString("created_at") ?: return null
    val role = if (row.nullableString("author_role") == "investigator") {
        ReportRole.Investigator
    } else {
        ReportRole.Student
    }
    return InvestigationNote(
        id = id,
        reportId = reportId,
        authorRole = role,
        authorUsername = row.nullableString("author_username"),
        text = text,
        createdAt = createdAt,
    )
}

internal fun parseVerdict(row: JSONObject): ReportVerdict? {
    val userId = row.nullableString("user_id") ?: return null
    val verdict = row.nullableString("verdict") ?: return null
    if (verdict != "valid" && verdict != "invalid") return null
    val reason = row.nullableString("reason") ?: return null
    val updatedAt = row.nullableString("updated_at")
        ?: row.nullableString("created_at")
        ?: return null
    return ReportVerdict(
        userId = userId,
        authorUsername = row.nullableString("author_username"),
        verdict = verdict,
        reason = reason,
        updatedAt = updatedAt,
    )
}

internal fun reportOrder(sort: ReportSort): String = when (sort) {
    ReportSort.Top -> "signal_score.desc,created_at.desc,id.desc"
    ReportSort.Newest -> "created_at.desc,id.desc"
    ReportSort.Oldest -> "created_at.asc,id.asc"
}

internal fun reportCursorFilter(
    sort: ReportSort,
    cursor: ReportCursor,
    encode: (String) -> String = { it },
): String {
    val timestamp = encode(cursor.createdAt)
    val id = encode(cursor.id)
    return when (sort) {
        ReportSort.Newest ->
            "or=(created_at.lt.$timestamp,and(created_at.eq.$timestamp,id.lt.$id))"
        ReportSort.Oldest ->
            "or=(created_at.gt.$timestamp,and(created_at.eq.$timestamp,id.gt.$id))"
        ReportSort.Top -> {
            val score = cursor.signalScore ?: 0
            "or=(signal_score.lt.$score,and(signal_score.eq.$score," +
                "or(created_at.lt.$timestamp,and(created_at.eq.$timestamp,id.lt.$id))))"
        }
    }
}
