package dev.alethia.mobile

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.providers.builtin.Email
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.auth.user.UserSession
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.json.JSONObject

enum class AuthSessionState { Initializing, SignedOut, SignedIn }

sealed interface AuthResult {
    data object SignedIn : AuthResult
    data class Failed(val reason: AuthFailure) : AuthResult
}

enum class AuthFailure {
    ConfigurationMissing,
    InvalidCredentials,
    RateLimited,
    UsernameTaken,
    EmailTaken,
    WeakPassword,
    ServiceUnavailable,
    Unexpected,
}

interface AuthRepository {
    val sessionState: Flow<AuthSessionState>
    suspend fun signIn(identifier: String, password: String): AuthResult
    suspend fun signUp(username: String, email: String, password: String): AuthResult
}

object UnavailableAuthRepository : AuthRepository {
    override val sessionState = flowOf(AuthSessionState.SignedOut)

    override suspend fun signIn(identifier: String, password: String) =
        AuthResult.Failed(AuthFailure.ConfigurationMissing)

    override suspend fun signUp(username: String, email: String, password: String) =
        AuthResult.Failed(AuthFailure.ConfigurationMissing)
}

class SupabaseAuthRepository(
    private val client: SupabaseClient,
    private val apiBaseUrl: String,
) : AuthRepository {
    override val sessionState = client.auth.sessionStatus.map { status ->
        when (status) {
            is SessionStatus.Authenticated -> AuthSessionState.SignedIn
            SessionStatus.Initializing -> AuthSessionState.Initializing
            else -> AuthSessionState.SignedOut
        }
    }

    override suspend fun signIn(identifier: String, password: String): AuthResult = try {
        client.auth.awaitInitialization()
        val trimmedIdentifier = identifier.trim()
        if (trimmedIdentifier.contains('@')) {
            client.auth.signInWith(Email) {
                email = trimmedIdentifier
                this.password = password
            }
        } else {
            val baseUrl = apiBaseUrl.trim().trimEnd('/')
            if (baseUrl.isBlank()) return AuthResult.Failed(AuthFailure.ConfigurationMissing)
            when (val result = requestUsernameSession(baseUrl, trimmedIdentifier, password)) {
                is UsernameSessionResult.Failure -> return AuthResult.Failed(result.reason)
                is UsernameSessionResult.Success -> client.auth.importSession(
                    UserSession(
                        accessToken = result.accessToken,
                        refreshToken = result.refreshToken,
                        expiresIn = result.expiresIn,
                        tokenType = result.tokenType,
                        user = client.auth.retrieveUser(result.accessToken),
                    ),
                )
            }
        }
        AuthResult.SignedIn
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Exception) {
        AuthResult.Failed(classify(error))
    }

    override suspend fun signUp(username: String, email: String, password: String): AuthResult = try {
        client.auth.awaitInitialization()
        client.auth.signUpWith(Email) {
            this.email = email.trim()
            this.password = password
            data = buildJsonObject { put("username", username.trim().lowercase(Locale.ROOT)) }
        }
        if (client.auth.sessionStatus.value is SessionStatus.Authenticated) AuthResult.SignedIn
        else AuthResult.Failed(AuthFailure.Unexpected)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Exception) {
        AuthResult.Failed(classify(error))
    }

    private suspend fun requestUsernameSession(
        baseUrl: String,
        username: String,
        password: String,
    ): UsernameSessionResult = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            connection = (URL("$baseUrl/api/auth/username-login").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = REQUEST_TIMEOUT_MS
                readTimeout = REQUEST_TIMEOUT_MS
                doOutput = true
                setRequestProperty("Accept", "application/json")
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
            }
            val requestBody = JSONObject()
                .put("username", username)
                .put("password", password)
                .toString()
                .toByteArray(Charsets.UTF_8)
            connection.outputStream.use { it.write(requestBody) }

            val status = connection.responseCode
            val body = (if (status in 200..299) connection.inputStream else connection.errorStream)
                ?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }
                .orEmpty()
            val json = runCatching { JSONObject(body) }.getOrNull()
            if (status !in 200..299 || json == null) {
                return@withContext UsernameSessionResult.Failure(
                    when (json?.optString("error")) {
                        "invalid_credentials" -> AuthFailure.InvalidCredentials
                        "rate_limited" -> AuthFailure.RateLimited
                        "unavailable" -> AuthFailure.ServiceUnavailable
                        else -> AuthFailure.Unexpected
                    },
                )
            }
            val accessToken = json.optString("access_token")
            val refreshToken = json.optString("refresh_token")
            if (accessToken.isBlank() || refreshToken.isBlank()) {
                return@withContext UsernameSessionResult.Failure(AuthFailure.Unexpected)
            }
            UsernameSessionResult.Success(
                accessToken = accessToken,
                refreshToken = refreshToken,
                expiresIn = json.optLong("expires_in", DEFAULT_SESSION_SECONDS),
                tokenType = json.optString("token_type", "bearer").ifBlank { "bearer" },
            )
        } catch (_: IOException) {
            UsernameSessionResult.Failure(AuthFailure.ServiceUnavailable)
        } catch (_: IllegalArgumentException) {
            UsernameSessionResult.Failure(AuthFailure.ConfigurationMissing)
        } finally {
            connection?.disconnect()
        }
    }

    private fun classify(error: Exception): AuthFailure {
        val message = generateSequence(error as Throwable?) { it.cause }
            .mapNotNull { it.message }
            .joinToString(" ")
            .lowercase(Locale.ROOT)
        return when {
            "username_taken" in message -> AuthFailure.UsernameTaken
            "email_taken" in message || "already registered" in message -> AuthFailure.EmailTaken
            "weak_password" in message || "password should" in message -> AuthFailure.WeakPassword
            "invalid login credentials" in message -> AuthFailure.InvalidCredentials
            "rate limit" in message || "too many requests" in message -> AuthFailure.RateLimited
            "unknownhostexception" in message || "connection refused" in message || "timeout" in message ->
                AuthFailure.ServiceUnavailable
            else -> AuthFailure.Unexpected
        }
    }

    private sealed interface UsernameSessionResult {
        data class Success(
            val accessToken: String,
            val refreshToken: String,
            val expiresIn: Long,
            val tokenType: String,
        ) : UsernameSessionResult

        data class Failure(val reason: AuthFailure) : UsernameSessionResult
    }

    private companion object {
        const val REQUEST_TIMEOUT_MS = 15_000
        const val DEFAULT_SESSION_SECONDS = 3_600L
    }
}
