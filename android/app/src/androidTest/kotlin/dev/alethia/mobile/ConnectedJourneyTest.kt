package dev.alethia.mobile

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.MemorySessionManager
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.createSupabaseClient
import java.net.URI
import java.net.URL
import java.net.HttpURLConnection
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import androidx.test.platform.app.InstrumentationRegistry
import androidx.lifecycle.ViewModelProvider
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ConnectedJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Before fun resetSession() {
        runBlocking {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AlethiaApplication
            app.container.client?.auth?.awaitInitialization()
            app.container.client?.auth?.clearSession()
        }
        compose.runOnIdle { ViewModelProvider(compose.activity)[PracticeViewModel::class.java].navigate(Screen.Welcome) }
    }

    @Test fun usernameLoginLoadsRealDashboardAndLogoutClearsAccount() {
        assumeTrue(URI(BuildConfig.SUPABASE_URL).host in setOf("10.0.2.2", "127.0.0.1", "localhost"))
        val client = createSupabaseClient(BuildConfig.SUPABASE_URL, BuildConfig.SUPABASE_PUBLISHABLE_KEY) {
            install(Auth) { sessionManager = MemorySessionManager(); autoLoadFromStorage = true; autoSaveToStorage = false; enableLifecycleCallbacks = false }
        }
        val username = "ui_${UUID.randomUUID().toString().replace("-", "").take(12)}"
        val password = "LocalOnly_${UUID.randomUUID()}"
        try {
            runBlocking {
                assertEquals(AuthResult.SignedIn, SupabaseAuthRepository(client, BuildConfig.API_BASE_URL).signUp(username, "$username@example.test", password))
            }
            compose.onNodeWithTag("start_auth").performClick()
            compose.onNodeWithTag("login_identifier").performScrollTo().performTextInput(username)
            compose.onNodeWithTag("login_password").performScrollTo().performTextInput(password)
            compose.onNodeWithTag("login_submit").performScrollTo().performClick()
            compose.waitUntil(20000) { compose.onAllNodesWithTag("open_profile").fetchSemanticsNodes().isNotEmpty() &&
                compose.onAllNodesWithText(username, substring = true).fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithTag("open_profile").performClick()
            compose.onNodeWithTag("sign_out").performScrollTo().performClick()
            compose.waitUntil(15000) { compose.onAllNodesWithTag("start_auth").fetchSemanticsNodes().isNotEmpty() }
            compose.onAllNodesWithText(username, substring = true).assertCountEquals(0)
        } finally {
            runBlocking {
                val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AlethiaApplication
                app.container.client?.auth?.clearSession()
                val token = client.auth.currentAccessTokenOrNull()
                if (token != null) {
                    val connection = URL("${BuildConfig.API_BASE_URL}/api/auth/delete-account").openConnection() as HttpURLConnection
                    try {
                        connection.requestMethod = "POST"; connection.connectTimeout = 15000; connection.readTimeout = 15000
                        connection.setRequestProperty("Authorization", "Bearer $token")
                        connection.setRequestProperty("Content-Type", "application/json")
                        connection.doOutput = true
                        connection.outputStream.use { it.write(JSONObject().put("confirm", "HAPUS AKUN SAYA").toString().toByteArray()) }
                        assertEquals(200, connection.responseCode)
                    } finally { connection.disconnect() }
                }
                client.close()
            }
        }
    }
}
