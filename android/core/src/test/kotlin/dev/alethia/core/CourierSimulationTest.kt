package dev.alethia.core

import org.junit.Assert.*
import org.junit.Test

class CourierSimulationTest {
    private fun readyToDecide(sender: SenderAssessment = SenderAssessment.Unverified): CourierState {
        var state = CourierState()
        listOf(
            CourierAction.Start, CourierAction.Inspect, CourierAction.Compare(true, true),
            CourierAction.AssessSender(sender), CourierAction.AssessLink(LinkAssessment.Suspicious),
            CourierAction.ContinueInspection, CourierAction.OpenOfficialChannel, CourierAction.ConfirmVerification,
        ).forEach { state = reduceCourier(state, it) }
        return state
    }

    @Test fun `stages cannot be skipped and evidence assessment is required`() {
        var state = reduceCourier(CourierState(), CourierAction.Start)
        assertEquals(state, reduceCourier(state, CourierAction.Complete))
        state = reduceCourier(state, CourierAction.Inspect)
        assertEquals(CourierStage.Inspect, reduceCourier(state, CourierAction.ContinueInspection).stage)
        assertNull(reduceCourier(state, CourierAction.AssessSender(SenderAssessment.Trusted)).senderAssessment)
    }

    @Test fun `verification cannot be confirmed without opening the official channel`() {
        val state = CourierState(stage = CourierStage.Verify)
        assertEquals(state, reduceCourier(state, CourierAction.ConfirmVerification))
    }

    @Test fun `perfect practice preserves the exact ordered server decisions`() {
        val result = reduceCourier(readyToDecide(), CourierAction.Decide(CourierDecision.ReportDelete))
        assertEquals(100, scoreCourier(result).score)
        assertEquals(listOf("assess:sender_unverified", "assess:link_suspicious", "verify_official_channel", "choose:report_delete"), courierDecisions(result))
        assertEquals(CourierStage.Complete, reduceCourier(result, CourierAction.Complete).stage)
    }

    @Test fun `a trusted sender assessment loses one quarter of the score`() {
        val state = reduceCourier(readyToDecide(SenderAssessment.Trusted), CourierAction.Decide(CourierDecision.VerifyOfficialChannel))
        assertEquals(75, scoreCourier(state).score)
        assertFalse(scoreCourier(state).perfect)
    }

    @Test fun `opening the link remains a risky decision`() {
        val state = reduceCourier(readyToDecide(), CourierAction.Decide(CourierDecision.OpenLink))
        assertEquals(75, scoreCourier(state).score)
        assertEquals("choose:open_link", courierDecisions(state).last())
    }

    @Test fun `evidence comparison accepts only the fictional displayed identifiers`() {
        assertTrue(CourierEvidence.matchesSender("6281100004821"))
        assertFalse(CourierEvidence.matchesSender("6281100004822"))
        assertTrue(CourierEvidence.matchesLink("https://paket-lacak.id/konfirmasi"))
        assertFalse(CourierEvidence.matchesLink("https://another.invalid/konfirmasi"))
    }

    @Test fun `server access is sequential and social completion is unscored`() {
        assertEquals(ModuleAccess.Locked, verifiedModuleAccess(emptyMap())[ModuleId.SocialEngineering])
        val progress = mapOf(
            ModuleId.CourierSms to VerifiedModuleProgress(true, 100),
            ModuleId.SocialEngineering to VerifiedModuleProgress(true, null),
        )
        assertEquals(ModuleAccess.Available, verifiedModuleAccess(progress)[ModuleId.ExecutableFile])
        assertEquals(ModuleAccess.Locked, verifiedModuleAccess(progress + (ModuleId.CourierSms to VerifiedModuleProgress(true, 75)))[ModuleId.SocialEngineering])
    }

    @Test fun `level thresholds match the database curve`() {
        assertEquals(listOf(1, 1, 2, 2, 3, 4, 5, 5), listOf(-1, 59, 60, 149, 150, 300, 550, 1000).map(::levelForPoints))
    }
}
