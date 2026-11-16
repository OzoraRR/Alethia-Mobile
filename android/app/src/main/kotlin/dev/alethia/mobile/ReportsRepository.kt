package dev.alethia.mobile

import java.net.URLEncoder
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import org.json.JSONArray
import org.json.JSONObject

/** Report hub data layer. All authorization remains server-side through RLS/RPCs. */
class ReportsRepository(private val learner: LearnerRepository) {
    val identity = learner.identity

    private val listSelect =
        "id,user_id,module_id,title,category,channel,pattern,author_username," +
            "created_at,updated_at,status,review_status,signal_score,investigator_verdict"

    private val detailSelect =
        "$listSelect,attempt_id,evidence,why_risky,defanged_url," +
            "screenshot_data_url,reviewer_feedback"

    suspend fun currentUserId(): String? = learner.currentUserId()

    /** The server is the authority; a failed probe only hides investigator controls. */
    suspend fun isInvestigator(): Boolean = try {
        learner.isInvestigator()
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        false
    }

    suspend fun loadPage(
        scope: ReportScope,
        sort: ReportSort,
        cursor: ReportCursor?,
        limit: Int = 20,
    ): ReportPage {
        val owner = requireOwner()
        val query = buildList {
            add("select=$listSelect")
            add("order=${reportOrder(sort)}")
            add("limit=${limit + 1}")
            if (scope == ReportScope.Mine) add("user_id=eq.$owner")
            if (cursor != null) add(reportCursorFilter(sort, cursor, ::encodeQuery))
        }
        val rows = JSONArray(
            learner.request("practice_reports?${query.joinToString("&")}"),
        ).jsonObjects()
        val pageRows = rows.take(limit)
        val signaled = signaledReportIds(owner, pageRows.mapNotNull { it.nullableString("id") })
        val reports = pageRows.mapNotNull { row ->
            val id = row.nullableString("id") ?: return@mapNotNull null
            parseReport(row, owner, id in signaled)
        }
        val last = pageRows.lastOrNull()
        val hasMore = rows.size > limit
        val nextCursor = if (hasMore && last != null) {
            val createdAt = last.nullableString("created_at")
            val id = last.nullableString("id")
            if (createdAt != null && id != null) {
                ReportCursor(
                    signalScore = if (sort == ReportSort.Top) {
                        last.optInt("signal_score", 0)
                    } else {
                        null
                    },
                    createdAt = createdAt,
                    id = id,
                )
            } else {
                null
            }
        } else {
            null
        }
        return ReportPage(
            reports = reports,
            nextCursor = nextCursor,
            hasMore = hasMore && nextCursor != null,
        )
    }

    suspend fun loadReport(reportId: String): PracticeReport? {
        val owner = requireOwner()
        val id = safeReportId(reportId)
        val raw = learner.request(
            "practice_reports?id=eq.$id&select=$detailSelect&limit=1",
        )
        val row = JSONArray(raw).jsonObjects().firstOrNull() ?: return null
        val signaled = id in signaledReportIds(owner, listOf(id))
        return parseReport(row, owner, signaled)
    }

    suspend fun create(input: ReportInput): PracticeReport {
        val owner = requireOwner()
        val body = contentBody(input).apply {
            put("user_id", owner)
            put("source", "manual")
            put("screenshot_data_url", input.screenshotDataUrl ?: JSONObject.NULL)
        }
        val raw = learner.request(
            "practice_reports?select=$listSelect",
            "POST",
            body,
            prefer = "return=representation",
        )
        val row = JSONArray(raw).jsonObjects().firstOrNull()
            ?: throw ReportException(ReportError.Generic)
        return parseReport(row, owner, false) ?: throw ReportException(ReportError.Generic)
    }

    suspend fun update(reportId: String, input: ReportInput): PracticeReport {
        val owner = requireOwner()
        val id = safeReportId(reportId)
        val body = contentBody(input).apply {
            put("screenshot_data_url", input.screenshotDataUrl ?: JSONObject.NULL)
        }
        val raw = learner.request(
            "practice_reports?id=eq.$id&user_id=eq.$owner&select=$listSelect",
            "PATCH",
            body,
            prefer = "return=representation",
        )
        val row = JSONArray(raw).jsonObjects().firstOrNull()
            ?: throw ReportException(ReportError.NotFound)
        return parseReport(row, owner, id in signaledReportIds(owner, listOf(id)))
            ?: throw ReportException(ReportError.Generic)
    }

    suspend fun delete(reportId: String) {
        val owner = requireOwner()
        val id = safeReportId(reportId)
        val existing = JSONArray(
            learner.request(
                "practice_reports?id=eq.$id&user_id=eq.$owner&select=id&limit=1",
            ),
        ).jsonObjects()
        if (existing.isEmpty()) throw ReportException(ReportError.NotFound)
        learner.request("practice_reports?id=eq.$id&user_id=eq.$owner", "DELETE")
    }

    suspend fun toggleSignal(reportId: String): SignalResult {
        val owner = requireOwner()
        val id = safeReportId(reportId)
        val existing = JSONArray(
            learner.request(
                "report_signals?report_id=eq.$id&user_id=eq.$owner&select=report_id&limit=1",
            ),
        ).jsonObjects().isNotEmpty()
        if (existing) {
            learner.request("report_signals?report_id=eq.$id&user_id=eq.$owner", "DELETE")
        } else {
            learner.request(
                "report_signals",
                "POST",
                JSONObject().put("report_id", id).put("user_id", owner),
            )
        }
        val raw = learner.request("practice_reports?id=eq.$id&select=signal_score&limit=1")
        val score = JSONArray(raw).jsonObjects().firstOrNull()
            ?.optInt("signal_score", 0)
            ?: 0
        return SignalResult(active = !existing, score = score.coerceAtLeast(0))
    }

    suspend fun loadNotes(reportId: String): List<InvestigationNote> {
        val id = safeReportId(reportId)
        val raw = learner.request(
            "report_investigation_notes?report_id=eq.$id" +
                "&select=id,report_id,author_role,author_username,text,created_at" +
                "&order=created_at.asc&limit=200",
        )
        return JSONArray(raw).jsonObjects().mapNotNull(::parseNote)
    }

    suspend fun addNote(reportId: String, text: String): InvestigationNote {
        val owner = requireOwner()
        val id = safeReportId(reportId)
        val body = JSONObject()
            .put("report_id", id)
            .put("user_id", owner)
            .put("text", text.trim())
        val raw = learner.request(
            "report_investigation_notes" +
                "?select=id,report_id,author_role,author_username,text,created_at",
            "POST",
            body,
            prefer = "return=representation",
        )
        val row = JSONArray(raw).jsonObjects().firstOrNull()
            ?: throw ReportException(ReportError.Generic)
        return parseNote(row) ?: throw ReportException(ReportError.Generic)
    }

    suspend fun loadVerdicts(reportId: String): List<ReportVerdict> {
        val id = safeReportId(reportId)
        val raw = learner.request(
            "report_verdicts?report_id=eq.$id" +
                "&select=user_id,author_username,verdict,reason,created_at,updated_at" +
                "&order=updated_at.desc,user_id.desc&limit=200",
        )
        return JSONArray(raw).jsonObjects().mapNotNull(::parseVerdict)
    }

    suspend fun loadVerdictTotals(reportId: String): ReportVerdictTotals = coroutineScope {
        val id = safeReportId(reportId)
        val valid = async {
            learner.request(
                "report_verdicts?report_id=eq.$id&verdict=eq.valid&select=report_id",
                "HEAD",
            ).toIntOrNull() ?: 0
        }
        val invalid = async {
            learner.request(
                "report_verdicts?report_id=eq.$id&verdict=eq.invalid&select=report_id",
                "HEAD",
            ).toIntOrNull() ?: 0
        }
        ReportVerdictTotals(valid.await(), invalid.await())
    }

    suspend fun castVerdict(
        reportId: String,
        verdict: String,
        reason: String,
    ): ReportVerdictTotals {
        val id = safeReportId(reportId)
        val raw = learner.rpc(
            "cast_report_verdict",
            JSONObject()
                .put("requested_report_id", id)
                .put("requested_verdict", verdict)
                .put("requested_reason", reason.trim()),
        )
        val json = JSONObject(raw)
        return ReportVerdictTotals(
            valid = json.optInt("valid", 0).coerceAtLeast(0),
            invalid = json.optInt("invalid", 0).coerceAtLeast(0),
        )
    }

    private suspend fun requireOwner(): String =
        learner.currentUserId() ?: throw ReportException(ReportError.AuthRequired)

    private fun contentBody(input: ReportInput): JSONObject = JSONObject()
        .put("title", input.title.trim())
        .put("category", input.category)
        .put("channel", input.channel)
        .put("pattern", input.pattern)
        .put("evidence", input.evidence.trim())
        .put("why_risky", input.whyRisky.trim())
        .put("defanged_url", input.defangedUrl ?: JSONObject.NULL)

    /** Signal state is decorative; never fail the report feed because it was unavailable. */
    private suspend fun signaledReportIds(owner: String, ids: List<String>): Set<String> = try {
        if (ids.isEmpty()) {
            emptySet()
        } else {
            val inList = ids.joinToString(",") { safeReportId(it) }
            val raw = learner.request(
                "report_signals?user_id=eq.$owner" +
                    "&report_id=in.($inList)&select=report_id&limit=${ids.size}",
            )
            JSONArray(raw).jsonObjects()
                .mapNotNull { it.nullableString("report_id") }
                .toSet()
        }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        emptySet()
    }

    private fun safeReportId(value: String): String = try {
        UUID.fromString(value).toString()
    } catch (_: IllegalArgumentException) {
        throw ReportException(ReportError.InvalidInput)
    }

    private fun encodeQuery(value: String): String =
        URLEncoder.encode(value, Charsets.UTF_8.name())
}
