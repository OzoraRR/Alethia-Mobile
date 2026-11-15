package dev.alethia.mobile

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.text.AnnotatedString
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.alethia.core.CourierEvidence
import kotlinx.coroutines.runBlocking
import io.github.jan.supabase.auth.auth
import androidx.lifecycle.ViewModelProvider
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PracticeJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Before fun resetLanguage() {
        runBlocking {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AlethiaApplication
            app.container.client?.auth?.awaitInitialization()
            app.container.client?.auth?.clearSession()
            LanguagePreferences(app).setLanguage("id")
        }
        compose.runOnIdle { ViewModelProvider(compose.activity)[PracticeViewModel::class.java].navigate(Screen.Welcome) }
        compose.waitForIdle()
    }

    private fun click(tag: String) {
        val node = compose.onNodeWithTag(tag)
        if (tag != "open_training") node.performScrollTo()
        node.performClick()
    }
    private fun start() { click("open_training"); click("open_roadmap"); click("open_checkpoint"); compose.onNodeWithTag("start_checkpoint").performClick(); click("begin_courier"); click("inspect_message") }
    private fun inspect(sender: String = "sender_unverified") {
        compose.onNodeWithTag("sender_input").performScrollTo().performTextInput(CourierEvidence.sender)
        compose.onNodeWithTag("link_input").performScrollTo().performTextInput(CourierEvidence.defangedLink)
        click("compare_evidence")
        click(sender)
        click("link_suspicious")
        click("continue_inspection")
    }
    private fun verifyAndFinish() {
        click("open_official")
        compose.onNodeWithTag("tracking_input").performScrollTo().performTextInput(CourierEvidence.trackingNumber)
        click("check_tracking")
        click("confirm_verification")
        click("choose_report")
        click("complete_practice")
    }

    @Test fun completeGuestPracticeScores100WithoutBackendConfiguration() {
        start(); inspect(); verifyAndFinish()
        compose.onNodeWithTag("practice_score").assertTextEquals("Skor: 100%")
        click("retry_practice")
        compose.onNodeWithTag("begin_courier").assertExists()
    }

    @Test fun incorrectSenderAssessmentScores75() {
        start(); inspect("sender_trusted"); verifyAndFinish()
        compose.onNodeWithTag("practice_score").assertTextEquals("Skor: 75%")
    }

    @Test fun recreationPreservesAnUnfinishedPractice() {
        start()
        compose.onNodeWithTag("sender_input").performTextInput(CourierEvidence.sender)
        compose.activityRule.scenario.recreate()
        compose.onNodeWithTag("sender_input").assert(SemanticsMatcher.expectValue(
            SemanticsProperties.EditableText, AnnotatedString(CourierEvidence.sender)))
        compose.onNodeWithTag("link_input").assertExists()
    }

    @Test fun languageChoiceSurvivesActivityRecreation() {
        click("open_training")
        compose.onNodeWithTag("open_profile").performClick()
        compose.onNodeWithTag("profile_language_en").performScrollTo().performClick()
        compose.waitForIdle()
        compose.activityRule.scenario.recreate()
        compose.onNodeWithTag("profile_language_en").assertIsSelected()
    }
}
