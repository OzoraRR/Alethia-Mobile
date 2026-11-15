package dev.alethia.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@Composable
fun LoginScreen(
    authModel: AuthViewModel,
    onSignUp: () -> Unit,
    onDashboardPreview: () -> Unit,
) {
    var identifier by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    val uiState by authModel.uiState.collectAsStateWithLifecycle()

    AuthTitle(stringResource(R.string.login_title))
    Text(stringResource(R.string.login_description), color = Muted, fontSize = 16.sp)
    AuthField(
        value = identifier,
        onValueChange = { identifier = it; authModel.clearFeedback() },
        label = stringResource(R.string.login_identifier),
        tag = "login_identifier",
        keyboardType = KeyboardType.Email,
        imeAction = ImeAction.Next,
    )
    AuthField(
        value = password,
        onValueChange = { password = it; authModel.clearFeedback() },
        label = stringResource(R.string.auth_password),
        tag = "login_password",
        password = true,
        imeAction = ImeAction.Done,
    )
    uiState.feedbackResource?.let {
        Text(stringResource(it), color = if (uiState.feedbackIsError) Warning else Muted, fontFamily = FontFamily.Monospace)
    }
    AuthPrimaryButton(
        label = stringResource(if (uiState.isSubmitting) R.string.auth_loading else R.string.sign_in),
        onClick = { authModel.signIn(identifier, password) },
        enabled = !uiState.isSubmitting,
        tag = "login_submit",
    )
    TextButton(onClick = onSignUp, Modifier.fillMaxWidth().testTag("go_to_signup")) {
        Text(stringResource(R.string.login_switch_signup), fontFamily = FontFamily.Monospace, color = LandingAuthGreen)
    }
    if (BuildConfig.DEBUG) {
        TextButton(onClick = onDashboardPreview, Modifier.fillMaxWidth().testTag("open_dashboard_preview")) {
            Text(stringResource(R.string.dashboard_preview_open), fontFamily = FontFamily.Monospace, color = Muted)
        }
    }
}

@Composable
fun SignUpScreen(authModel: AuthViewModel, onLogin: () -> Unit) {
    var username by remember { mutableStateOf("") }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    val uiState by authModel.uiState.collectAsStateWithLifecycle()

    AuthTitle(stringResource(R.string.signup_title))
    Text(stringResource(R.string.signup_description), color = Muted, fontSize = 16.sp)
    AuthField(
        value = username,
        onValueChange = { username = it; authModel.clearFeedback() },
        label = stringResource(R.string.auth_username),
        tag = "signup_username",
        imeAction = ImeAction.Next,
    )
    AuthField(
        value = email,
        onValueChange = { email = it; authModel.clearFeedback() },
        label = stringResource(R.string.auth_email),
        tag = "signup_email",
        keyboardType = KeyboardType.Email,
        imeAction = ImeAction.Next,
    )
    AuthField(
        value = password,
        onValueChange = { password = it; authModel.clearFeedback() },
        label = stringResource(R.string.auth_password),
        tag = "signup_password",
        password = true,
        imeAction = ImeAction.Next,
    )
    AuthField(
        value = confirmation,
        onValueChange = { confirmation = it; authModel.clearFeedback() },
        label = stringResource(R.string.auth_confirm_password),
        tag = "signup_confirm_password",
        password = true,
        imeAction = ImeAction.Done,
    )
    uiState.feedbackResource?.let {
        Text(stringResource(it), color = if (uiState.feedbackIsError) Warning else Muted, fontFamily = FontFamily.Monospace)
    }
    AuthPrimaryButton(
        label = stringResource(if (uiState.isSubmitting) R.string.auth_loading else R.string.sign_up),
        onClick = { authModel.signUp(username, email, password, confirmation) },
        enabled = !uiState.isSubmitting,
        tag = "signup_submit",
    )
    TextButton(onClick = onLogin, Modifier.fillMaxWidth().testTag("go_to_login")) {
        Text(stringResource(R.string.signup_switch_login), fontFamily = FontFamily.Monospace, color = LandingAuthGreen)
    }
}

@Composable
private fun AuthTitle(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.headlineMedium.copy(fontFamily = FontFamily.Monospace),
        fontWeight = FontWeight.Bold,
        modifier = Modifier.semantics { heading() },
    )
}

@Composable
private fun AuthField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    tag: String,
    keyboardType: KeyboardType = KeyboardType.Text,
    imeAction: ImeAction = ImeAction.Next,
    password: Boolean = false,
) {
    var passwordVisible by remember { mutableStateOf(false) }
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label, fontFamily = FontFamily.Monospace) },
        modifier = Modifier.fillMaxWidth().testTag(tag),
        singleLine = true,
        textStyle = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Monospace),
        keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
            keyboardType = if (password) KeyboardType.Password else keyboardType,
            imeAction = imeAction,
        ),
        visualTransformation = if (password && !passwordVisible) PasswordVisualTransformation() else VisualTransformation.None,
        trailingIcon = if (password) {
            {
                IconButton(onClick = { passwordVisible = !passwordVisible }) {
                    Icon(
                        painter = painterResource(if (passwordVisible) R.drawable.alethia_eye_open else R.drawable.alethia_eye_closed),
                        contentDescription = stringResource(if (passwordVisible) R.string.auth_hide_password else R.string.auth_show_password),
                        tint = LandingAuthGreen,
                    )
                }
            }
        } else null,
    )
}

private val LandingAuthGreen = Color(0xFF8FD744)
private val LandingAuthGreenShadow = Color(0xFF263F0D)

@Composable
private fun AuthPrimaryButton(label: String, onClick: () -> Unit, enabled: Boolean, tag: String) {
    val shape = RoundedCornerShape(6.dp)
    Box(Modifier.fillMaxWidth().height(64.dp)) {
        Surface(
            modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(58.dp),
            shape = shape,
            color = LandingAuthGreenShadow,
        ) {}
        Box(
            modifier = Modifier.align(Alignment.TopCenter).fillMaxWidth().height(58.dp)
                .clip(shape)
                .background(if (enabled) LandingAuthGreen else LandingAuthGreen.copy(alpha = 0.55f))
                .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
                .testTag(tag),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = label,
                color = Color(0xFF08100A),
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Bold,
                letterSpacing = 0.6.sp,
                fontSize = 17.sp,
            )
        }
    }
}
