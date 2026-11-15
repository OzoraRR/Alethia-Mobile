package dev.alethia.core

import java.io.Serializable
import kotlin.math.roundToInt

enum class CourierStage { Briefing, Receive, Inspect, Verify, Decide, Reveal, Complete }
enum class SenderAssessment { Unverified, Trusted }
enum class LinkAssessment { Suspicious, Trusted }
enum class CourierDecision(val wireId: String) {
    OpenLink("open_link"), VerifyOfficialChannel("verify_official_channel"), ReportDelete("report_delete")
}

data class CourierState(
    val stage: CourierStage = CourierStage.Briefing,
    val comparisonSubmitted: Boolean = false,
    val senderMatches: Boolean? = null,
    val linkMatches: Boolean? = null,
    val senderAssessment: SenderAssessment? = null,
    val linkAssessment: LinkAssessment? = null,
    val verificationOpen: Boolean = false,
    val verificationComplete: Boolean = false,
    val decision: CourierDecision? = null,
) : Serializable {
    val canContinueInspection: Boolean get() = comparisonSubmitted && senderAssessment != null && linkAssessment != null
}

sealed interface CourierAction {
    data object Start : CourierAction
    data object Inspect : CourierAction
    data class Compare(val senderMatches: Boolean, val linkMatches: Boolean) : CourierAction
    data class AssessSender(val value: SenderAssessment) : CourierAction
    data class AssessLink(val value: LinkAssessment) : CourierAction
    data object ContinueInspection : CourierAction
    data object OpenOfficialChannel : CourierAction
    data object CloseOfficialChannel : CourierAction
    data object ConfirmVerification : CourierAction
    data class Decide(val value: CourierDecision) : CourierAction
    data object Complete : CourierAction
}

fun reduceCourier(state: CourierState, action: CourierAction): CourierState = when (action) {
    CourierAction.Start -> if (state.stage == CourierStage.Briefing) state.copy(stage = CourierStage.Receive) else state
    CourierAction.Inspect -> if (state.stage == CourierStage.Receive) state.copy(stage = CourierStage.Inspect) else state
    is CourierAction.Compare -> if (state.stage == CourierStage.Inspect) state.copy(
        comparisonSubmitted = true, senderMatches = action.senderMatches, linkMatches = action.linkMatches,
        senderAssessment = null, linkAssessment = null,
    ) else state
    is CourierAction.AssessSender -> if (state.stage == CourierStage.Inspect && state.comparisonSubmitted)
        state.copy(senderAssessment = action.value) else state
    is CourierAction.AssessLink -> if (state.stage == CourierStage.Inspect && state.comparisonSubmitted)
        state.copy(linkAssessment = action.value) else state
    CourierAction.ContinueInspection -> if (state.stage == CourierStage.Inspect && state.canContinueInspection)
        state.copy(stage = CourierStage.Verify) else state
    CourierAction.OpenOfficialChannel -> if (state.stage == CourierStage.Verify) state.copy(verificationOpen = true) else state
    CourierAction.CloseOfficialChannel -> if (state.stage == CourierStage.Verify) state.copy(verificationOpen = false) else state
    CourierAction.ConfirmVerification -> if (state.stage == CourierStage.Verify && state.verificationOpen)
        state.copy(stage = CourierStage.Decide, verificationOpen = false, verificationComplete = true) else state
    is CourierAction.Decide -> if (state.stage == CourierStage.Decide) state.copy(stage = CourierStage.Reveal, decision = action.value) else state
    CourierAction.Complete -> if (state.stage == CourierStage.Reveal && state.decision != null)
        state.copy(stage = CourierStage.Complete) else state
}

data class PracticeScore(val checks: List<Boolean>) {
    init { require(checks.isNotEmpty()) }
    val score: Int get() = (checks.count { it } * 100.0 / checks.size).roundToInt()
    val perfect: Boolean get() = checks.all { it }
}

fun scoreCourier(state: CourierState): PracticeScore {
    require(state.decision != null) { "A decision is required before scoring." }
    return PracticeScore(listOf(
        state.senderAssessment == SenderAssessment.Unverified,
        state.linkAssessment == LinkAssessment.Suspicious,
        state.verificationComplete,
        state.decision != CourierDecision.OpenLink,
    ))
}

/** Stable decision IDs shared with complete_verified_practice_attempt. */
fun courierDecisions(state: CourierState): List<String> {
    require(state.senderAssessment != null && state.linkAssessment != null && state.decision != null)
    return buildList {
        add(if (state.senderAssessment == SenderAssessment.Unverified) "assess:sender_unverified" else "assess:sender_trusted")
        add(if (state.linkAssessment == LinkAssessment.Suspicious) "assess:link_suspicious" else "assess:link_trusted")
        if (state.verificationComplete) add("verify_official_channel")
        add("choose:${state.decision.wireId}")
    }
}

object CourierEvidence {
    const val sender = "+62 811-0000-4821"
    const val defangedLink = "paket-lacak[.]id/konfirmasi"
    const val trackingNumber = "LK-240923-4821"

    fun matchesSender(input: String): Boolean = input.filter(Char::isDigit) == sender.filter(Char::isDigit)
    fun matchesLink(input: String): Boolean = input.trim().lowercase().removePrefix("https://")
        .removePrefix("http://").replace("[.]", ".").trimEnd('/') == defangedLink.replace("[.]", ".")
}
