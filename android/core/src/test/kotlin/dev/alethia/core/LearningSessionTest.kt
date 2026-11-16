package dev.alethia.core

import org.junit.Assert.*
import org.junit.Test

class LearningSessionTest {
    @Test fun onlyStageOnlyForwardSnapshotsCanBeRebasedOverRemoteRevision() {
        val stageTwo = LearningState(ModuleId.CourierSms, stage = 2,
            senderInput = CourierEvidence.sender, linkInput = CourierEvidence.defangedLink,
            compared = true, sender = SenderAssessment.Unverified, link = LinkAssessment.Suspicious)
        assertTrue(stageTwo.copy(stage = 3).isForwardCheckpointFrom(stageTwo))
        assertFalse(stageTwo.isForwardCheckpointFrom(stageTwo.copy(stage = 3)))
        assertFalse(stageTwo.copy(stage = 3, senderInput = "edited locally").isForwardCheckpointFrom(stageTwo))
        assertFalse(stageTwo.copy(stage = 2, senderInput = "edited locally").isForwardCheckpointFrom(stageTwo))
    }

    @Test fun courierRequiresComparisonAssessmentsAndSuccessfulOfficialCheck() {
        var s = LearningState(ModuleId.CourierSms, stage = 1).advance()
        assertEquals(2, s.stage)
        assertEquals(s, s.advance())
        assertEquals(s, s.assessSender(SenderAssessment.Unverified))
        s = s.copy(senderInput = CourierEvidence.sender, linkInput = CourierEvidence.defangedLink).compare()
            .assessSender(SenderAssessment.Unverified).assessLink(LinkAssessment.Suspicious).advance()
        assertEquals(3, s.stage)
        assertEquals(s, s.advance())
        assertFalse(s.copy(trackingInput = "wrong").checkOfficial().checked)
        s = s.copy(trackingInput = CourierEvidence.trackingNumber).checkOfficial().advance().choose("report_delete").advance()
        assertEquals(100, s.score())
        assertEquals(listOf("assess:sender_unverified", "assess:link_suspicious", "verify_official_channel", "choose:report_delete"), s.decisions())
        assertEquals(s, s.choose("open_link"))
    }
    @Test fun wrongCourierDecisionIsStoredAsFailedNotCompletedAccess() {
        val s = LearningState(ModuleId.CourierSms, 5, sender = SenderAssessment.Trusted,
            link = LinkAssessment.Suspicious, verified = true, choice = "open_link")
        assertEquals(50, s.score())
    }
    @Test fun socialNeedsTwoArtifactsAndMitigationAndRemainsUnscored() {
        var s = LearningState(ModuleId.SocialEngineering, stage = 1).toggleArtifact("visual")
        assertEquals(s, s.advance())
        s = s.toggleArtifact("family").toggleArtifact("unknown").advance().advance().advance()
        assertEquals(4, s.stage)
        assertEquals(s, s.advance())
        s = s.mitigate("limit").advance()
        assertNull(s.score())
        assertEquals(listOf("artifact:visual", "artifact:family", "mitigation:limit", "complete:reconstruction"), s.decisions())
    }
    @Test fun fileNeedsTwoDistinctDetailsAndVerification() {
        var s = LearningState(ModuleId.ExecutableFile, stage = 2).inspect("source").inspect("source")
        assertEquals(s, s.advance())
        s = s.inspect("extension").advance()
        assertEquals(s, s.advance())
        s = s.checkOfficial().advance().choose("open").advance()
        assertEquals(67, s.score())
        assertEquals(listOf("inspect:source", "inspect:extension", "verify_official_channel", "choose:open"), s.decisions())
        assertEquals(100, s.copy(choice = "report").score())
    }
}
