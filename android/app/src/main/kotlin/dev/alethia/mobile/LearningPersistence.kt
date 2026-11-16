package dev.alethia.mobile

import android.content.Context
import dev.alethia.core.*
import org.json.JSONArray
import org.json.JSONObject

/** Only synthetic lesson fields are stored here; no auth tokens or personal message data. */
class LearningDraftStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences("learning_recovery_v1", Context.MODE_PRIVATE)
    fun load(owner: String, module: ModuleId): LearningSession? = runCatching {
        preferences.getString("$owner:${module.wireId}", null)?.let { decodeSession(JSONObject(it)) }
    }.getOrNull()
    fun save(owner: String, session: LearningSession) {
        check(preferences.edit().putString("$owner:${session.state.module.wireId}", encodeSession(session).toString()).commit())
    }
}

data class LearningSession(
    val attemptId: String?, val revision: Long, val state: LearningState,
    val result: LearningResult? = null, val dirty: Boolean = false,
)
data class LearningResult(val score: Int?, val perfect: Boolean?)

internal fun encodeLearningState(s: LearningState): JSONObject = JSONObject()
    .put("version", 1).put("stage", s.stage).put("inspected", JSONArray(s.inspected.toList()))
    .put("sender", s.sender?.name).put("link", s.link?.name)
    .put("senderInput", s.senderInput).put("linkInput", s.linkInput).put("trackingInput", s.trackingInput)
    .put("compared", s.compared).put("checked", s.checked).put("verified", s.verified).put("choice", s.choice)
    .put("artifacts", JSONArray(s.artifacts.toList())).put("mitigation", s.mitigation)

internal fun decodeLearningState(module: ModuleId, j: JSONObject): LearningState {
    fun strings(key: String) = j.optJSONArray(key)?.let { a -> (0 until a.length()).map { a.getString(it) }.toSet() } ?: emptySet()
    fun text(key: String) = j.optString(key).takeUnless { it.isBlank() || it == "null" }
    val state = LearningState(module, j.optInt("stage", 0).coerceIn(0, 6),
        inspected = strings("inspected").intersect(LearningState.fileFields.toSet()),
        sender = SenderAssessment.entries.firstOrNull { it.name == text("sender") },
        link = LinkAssessment.entries.firstOrNull { it.name == text("link") },
        senderInput = text("senderInput").orEmpty().take(200), linkInput = text("linkInput").orEmpty().take(300),
        trackingInput = text("trackingInput").orEmpty().take(100), compared = j.optBoolean("compared"),
        checked = j.optBoolean("checked"), verified = j.optBoolean("verified"), choice = text("choice"),
        artifacts = strings("artifacts").intersect(LearningState.artifactIds.toSet()), mitigation = text("mitigation"))
    if (state.stage >= 5) runCatching { state.decisions() }.getOrElse { return LearningState(module) }
    return state
}
internal fun encodeSession(s: LearningSession): JSONObject = JSONObject()
    .put("module_id", s.state.module.wireId).put("attempt_id", s.attemptId).put("revision", s.revision)
    .put("state", encodeLearningState(s.state)).put("dirty", s.dirty)
    .put("result", s.result?.let { JSONObject().put("score", it.score ?: JSONObject.NULL).put("perfect", it.perfect ?: JSONObject.NULL) })
internal fun decodeSession(j: JSONObject): LearningSession {
    val module = ModuleId.entries.first { it.wireId == j.getString("module_id") }
    val result = (j.optJSONObject("result") ?: j.optJSONObject("state")?.optJSONObject("result"))?.let { LearningResult(if (it.isNull("score")) null else it.getInt("score"), if (it.isNull("perfect")) null else it.getBoolean("perfect")) }
    return LearningSession(j.optString("attempt_id").takeUnless { it.isBlank() || it == "null" }, j.optLong("revision"),
        decodeLearningState(module, j.optJSONObject("state") ?: JSONObject()), result, j.optBoolean("dirty"))
}
