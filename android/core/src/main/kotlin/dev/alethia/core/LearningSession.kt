package dev.alethia.core

/** Stages are presentation checkpoints; only server-verified completion can unlock an account module. */
data class LearningState(
    val module: ModuleId,
    val stage: Int = 0,
    val inspected: Set<String> = emptySet(),
    val sender: SenderAssessment? = null,
    val link: LinkAssessment? = null,
    val senderInput: String = "",
    val linkInput: String = "",
    val trackingInput: String = "",
    val compared: Boolean = false,
    val checked: Boolean = false,
    val verified: Boolean = false,
    val choice: String? = null,
    val artifacts: Set<String> = emptySet(),
    val mitigation: String? = null,
) {
    /** True only when the local snapshot differs from a synced snapshot by forward checkpoint stage alone. */
    fun isForwardCheckpointFrom(previous: LearningState): Boolean =
        module == previous.module && stage > previous.stage && copy(stage = previous.stage) == previous

    val canAdvance: Boolean get() = when (stage) {
        0, 1 -> module != ModuleId.SocialEngineering || stage == 0 || artifacts.size in 2..5
        2 -> when (module) {
            ModuleId.CourierSms -> compared && sender != null && link != null
            ModuleId.SocialEngineering -> true
            ModuleId.ExecutableFile -> inspected.size >= 2
        }
        3 -> module == ModuleId.SocialEngineering || checked
        4 -> if (module == ModuleId.SocialEngineering) mitigation != null else choice != null
        5 -> true
        else -> false
    }
    fun advance(): LearningState {
        if (!canAdvance || stage >= 5) return this
        return copy(stage = stage + 1, verified = verified || (stage == 3 && module != ModuleId.SocialEngineering))
    }
    fun toggleArtifact(id: String): LearningState = if (module == ModuleId.SocialEngineering && stage == 1 && id in artifactIds)
        copy(artifacts = if (id in artifacts) artifacts - id else artifacts + id) else this
    fun inspect(id: String): LearningState = if (module == ModuleId.ExecutableFile && stage == 2 && id in fileFields)
        copy(inspected = inspected + id) else this
    fun choose(id: String): LearningState = if (stage == 4 && id in choices(module)) copy(choice = id) else this
    fun mitigate(id: String): LearningState = if (module == ModuleId.SocialEngineering && stage == 4 && id in mitigations)
        copy(mitigation = id) else this
    fun assessSender(value: SenderAssessment): LearningState = if (stage == 2 && compared && module == ModuleId.CourierSms) copy(sender = value) else this
    fun assessLink(value: LinkAssessment): LearningState = if (stage == 2 && compared && module == ModuleId.CourierSms) copy(link = value) else this
    fun compare(): LearningState = if (stage == 2 && module == ModuleId.CourierSms && senderInput.isNotBlank() && linkInput.isNotBlank()) copy(compared = true) else this
    fun checkOfficial(): LearningState = if (stage == 3) copy(checked = if (module == ModuleId.CourierSms)
        trackingInput.trim().equals(CourierEvidence.trackingNumber, ignoreCase = true) else true) else this
    fun decisions(): List<String> {
        require(stage >= 5)
        return when (module) {
            ModuleId.CourierSms -> {
                require(sender != null && link != null && choice in choices(module) && verified)
                listOf(if (sender == SenderAssessment.Unverified) "assess:sender_unverified" else "assess:sender_trusted",
                    if (link == LinkAssessment.Suspicious) "assess:link_suspicious" else "assess:link_trusted",
                    "verify_official_channel", "choose:$choice")
            }
            ModuleId.SocialEngineering -> {
                require(artifacts.size in 2..5 && mitigation in mitigations)
                artifactIds.filter { it in artifacts }.map { "artifact:$it" } + listOf("mitigation:$mitigation", "complete:reconstruction")
            }
            ModuleId.ExecutableFile -> {
                require(inspected.size >= 2 && verified && choice in choices(module))
                fileFields.filter { it in inspected }.map { "inspect:$it" } + listOf("verify_official_channel", "choose:$choice")
            }
        }
    }
    fun score(): Int? = when (module) {
        ModuleId.SocialEngineering -> null
        ModuleId.CourierSms -> PracticeScore(listOf(sender == SenderAssessment.Unverified,
            link == LinkAssessment.Suspicious, verified, choice != "open_link")).score
        ModuleId.ExecutableFile -> PracticeScore(listOf(inspected.size >= 2, verified, choice != "open")).score
    }
    companion object {
        val artifactIds = listOf("visual", "routine", "complaint", "career", "family")
        val fileFields = listOf("source", "filename", "extension", "link")
        val mitigations = listOf("limit", "separate", "verify")
        fun choices(module: ModuleId) = when (module) {
            ModuleId.CourierSms -> listOf("open_link", "verify_official_channel", "report_delete")
            ModuleId.ExecutableFile -> listOf("open", "verify", "ignore", "report")
            ModuleId.SocialEngineering -> emptyList()
        }
    }
}
