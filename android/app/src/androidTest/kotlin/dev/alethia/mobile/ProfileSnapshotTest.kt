package dev.alethia.mobile

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ProfileSnapshotTest {
    @Test fun parsesServerLevelStreakAndBadgeSelection() {
        val state = JSONObject("""{
          "profile":{"id":"learner-1","username":"alya","displayName":"Alya","preferredLocale":"id","points":175,"level":3,"modulesCompleted":2,"mastery":"skilled","badges":["first_report"]},
          "dailyStreak":{"current":4,"longest":7},
          "practiceStreak":{"current":2,"longest":3},
          "modules":[],"quests":[],"achievements":[{"code":"first_report","awardedAt":"2026-11-16"}],
          "notifications":{"unread":0}
        }""")
        val selected = JSONArray("""[{"badge_code":"first_report"}]""")
        val counts = JSONArray("""[{"review_status":"approved","count":1},{"review_status":"queued","count":2},{"review_status":"rejected","count":0}]""")
        val snapshot = parseLearnerSnapshot(state, JSONArray(), JSONArray(), counts, selected, 1)

        assertEquals(3, snapshot.profile.level)
        assertEquals(4, snapshot.profile.dailyCurrent)
        assertEquals(3, snapshot.profile.practiceLongest)
        assertEquals(3, snapshot.profile.reportCount)
        assertEquals(1, snapshot.profile.approvedReportCount)
        assertEquals(1, snapshot.profile.investigationCount)
        assertTrue("first_report" in snapshot.profile.unlockedBadges)
        assertTrue("first_report" in snapshot.profile.equippedBadges)
        assertEquals(300, snapshot.dashboard.pointsForNextLevel)
    }
}
