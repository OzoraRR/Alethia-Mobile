package dev.alethia.mobile

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.CreationExtras
import android.util.Patterns
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

data class AuthUiState(
    val isSubmitting: Boolean = false,
    val feedbackResource: Int? = null,
    val feedbackIsError: Boolean = false,
)

class AuthViewModel(private val repository: AuthRepository) : ViewModel() {
    private val mutableUiState = MutableStateFlow(AuthUiState())
    val uiState = mutableUiState.asStateFlow()
    val sessionState = repository.sessionState.stateIn(
        viewModelScope,
        SharingStarted.Eagerly,
        AuthSessionState.Initializing,
    )

    fun clearFeedback() {
        mutableUiState.value = mutableUiState.value.copy(feedbackResource = null, feedbackIsError = false)
    }

    fun showValidationError(resource: Int) {
        mutableUiState.value = AuthUiState(feedbackResource = resource, feedbackIsError = true)
    }

    fun signIn(identifier: String, password: String) {
        if (identifier.isBlank() || password.isBlank()) {
            showValidationError(R.string.auth_required)
            return
        }
        submit { repository.signIn(identifier, password) }
    }

    fun signUp(username: String, email: String, password: String, confirmation: String) {
        val validationError = when {
            username.isBlank() || email.isBlank() || password.isBlank() || confirmation.isBlank() -> R.string.auth_required
            !USERNAME_PATTERN.matches(username.trim()) -> R.string.auth_username_invalid
            !Patterns.EMAIL_ADDRESS.matcher(email.trim()).matches() -> R.string.auth_email_invalid
            password.length < MIN_PASSWORD_LENGTH -> R.string.auth_password_short
            password != confirmation -> R.string.auth_password_mismatch
            else -> null
        }
        if (validationError != null) {
            showValidationError(validationError)
            return
        }
        submit { repository.signUp(username, email, password) }
    }

    private fun submit(operation: suspend () -> AuthResult) {
        if (mutableUiState.value.isSubmitting) return
        viewModelScope.launch {
            mutableUiState.value = AuthUiState(isSubmitting = true)
            val result = try {
                operation()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                AuthResult.Failed(AuthFailure.Unexpected)
            }
            mutableUiState.value = when (result) {
                AuthResult.SignedIn -> AuthUiState()
                is AuthResult.Failed -> AuthUiState(
                    feedbackResource = result.reason.toMessageResource(),
                    feedbackIsError = true,
                )
            }
        }
    }

    class Factory(private val repository: AuthRepository) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>, extras: CreationExtras): T {
            require(modelClass.isAssignableFrom(AuthViewModel::class.java))
            return AuthViewModel(repository) as T
        }
    }

    private companion object {
        const val MIN_PASSWORD_LENGTH = 8
        val USERNAME_PATTERN = Regex("^[A-Za-z0-9_]{3,24}$")
    }
}

private fun AuthFailure.toMessageResource(): Int = when (this) {
    AuthFailure.ConfigurationMissing -> R.string.auth_configuration_missing
    AuthFailure.InvalidCredentials -> R.string.auth_invalid_credentials
    AuthFailure.RateLimited -> R.string.auth_rate_limited
    AuthFailure.UsernameTaken -> R.string.auth_username_taken
    AuthFailure.EmailTaken -> R.string.auth_email_taken
    AuthFailure.WeakPassword -> R.string.auth_password_weak
    AuthFailure.ServiceUnavailable -> R.string.auth_service_unavailable
    AuthFailure.Unexpected -> R.string.auth_unexpected
}
