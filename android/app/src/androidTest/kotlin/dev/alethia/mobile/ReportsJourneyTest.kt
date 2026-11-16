package dev.alethia.mobile

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.lifecycle.ViewModelProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ReportsJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test
    fun reportEditorComposesWithScreenshotPicker() {
        compose.runOnIdle {
            ViewModelProvider(compose.activity)[PracticeViewModel::class.java]
                .navigate(Screen.ReportEditor)
        }

        compose.onNodeWithTag("report_screenshot_pick").assertExists()
    }
}
