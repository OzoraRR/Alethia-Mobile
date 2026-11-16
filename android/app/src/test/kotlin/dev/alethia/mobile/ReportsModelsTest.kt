package dev.alethia.mobile

import org.junit.Assert.assertEquals
import org.junit.Test

class ReportsModelsTest {

    @Test
    fun defangReportUrl_removesSchemeAndDots() {
        assertEquals("example[.]com/path", defangReportUrl("https://example.com/path"))
        assertEquals("example[.]com", defangReportUrl("http://example.com"))
        assertEquals("sub[.]example[.]com", defangReportUrl("sub.example.com"))
        assertEquals("example[.]com", defangReportUrl("example.com")) // no scheme
        assertEquals("example[.]com", defangReportUrl("  https://example.com  ")) // trim
    }

    @Test
    fun reportOrder_newest() {
        assertEquals("created_at.desc,id.desc", reportOrder(ReportSort.Newest))
    }

    @Test
    fun reportOrder_oldest() {
        assertEquals("created_at.asc,id.asc", reportOrder(ReportSort.Oldest))
    }

    @Test
    fun reportOrder_top() {
        assertEquals("signal_score.desc,created_at.desc,id.desc", reportOrder(ReportSort.Top))
    }

    @Test
    fun reportCursorFilter_newest() {
        val cursor = ReportCursor(createdAt = "2026-01-02T12:34:56.789Z", id = "123e4567-e89b-12d3-a456-426614174000")
        val filter = reportCursorFilter(ReportSort.Newest, cursor)
        assertEquals(
            "or=(created_at.lt.2026-01-02T12:34:56.789Z,and(created_at.eq.2026-01-02T12:34:56.789Z,id.lt.123e4567-e89b-12d3-a456-426614174000))",
            filter
        )
    }

    @Test
    fun reportCursorFilter_oldest() {
        val cursor = ReportCursor(createdAt = "2026-01-02T12:34:56.789Z", id = "123e4567-e89b-12d3-a456-426614174000")
        val filter = reportCursorFilter(ReportSort.Oldest, cursor)
        assertEquals(
            "or=(created_at.gt.2026-01-02T12:34:56.789Z,and(created_at.eq.2026-01-02T12:34:56.789Z,id.gt.123e4567-e89b-12d3-a456-426614174000))",
            filter
        )
    }

    @Test
    fun reportCursorFilter_top() {
        val cursor = ReportCursor(signalScore = 5, createdAt = "2026-01-02T12:34:56.789Z", id = "123e4567-e89b-12d3-a456-426614174000")
        val filter = reportCursorFilter(ReportSort.Top, cursor)
        assertEquals(
            "or=(signal_score.lt.5,and(signal_score.eq.5,or(created_at.lt.2026-01-02T12:34:56.789Z,and(created_at.eq.2026-01-02T12:34:56.789Z,id.lt.123e4567-e89b-12d3-a456-426614174000))))",
            filter
        )
    }

    @Test
    fun reportReviewStatus_from() {
        assertEquals(ReportReviewStatus.Queued, ReportReviewStatus.from("queued"))
        assertEquals(ReportReviewStatus.Queued, ReportReviewStatus.from(null))
        assertEquals(ReportReviewStatus.Queued, ReportReviewStatus.from("unknown"))
        assertEquals(ReportReviewStatus.Approved, ReportReviewStatus.from("approved"))
        assertEquals(ReportReviewStatus.Rejected, ReportReviewStatus.from("rejected"))
    }

    @Test
    fun toReportError_mapsStatus() {
        // AuthRequired for 401
        val authEx = LearnerRequestException(401)
        assertEquals(ReportError.AuthRequired, authEx.toReportError())

        // NotAllowed for 403
        val notAllowedEx = LearnerRequestException(403)
        assertEquals(ReportError.NotAllowed, notAllowedEx.toReportError())

        // NotFound for 404
        val notFoundEx = LearnerRequestException(404)
        assertEquals(ReportError.NotFound, notFoundEx.toReportError())

        // InvalidInput for 400
        val invalidEx = LearnerRequestException(400)
        assertEquals(ReportError.InvalidInput, invalidEx.toReportError())

        // Generic for other statuses
        val genericEx = LearnerRequestException(500)
        assertEquals(ReportError.Generic, genericEx.toReportError())

        // Network for IOException
        val ioEx = java.io.IOException("network")
        assertEquals(ReportError.Network, ioEx.toReportError())

        // Generic for other exceptions
        val otherEx = Exception("other")
        assertEquals(ReportError.Generic, otherEx.toReportError())
    }
}