package dev.alethia.mobile

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

@Composable
fun PlaceholderScreen(title: Int, description: Int) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(stringResource(title), color = Ice, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Surface(
            color = Navy900,
            shape = MaterialTheme.shapes.large,
            border = androidx.compose.foundation.BorderStroke(1.dp, Navy700),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(stringResource(description), color = Muted, modifier = Modifier.padding(18.dp),
                style = MaterialTheme.typography.bodyMedium)
        }
    }
}

@Composable
fun ProfileScreen(language: String, onLanguageChange: (String) -> Unit, displayName: String? = null, onSignOut: () -> Unit = {}, busy: Boolean = false) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (displayName != null) {
            Text(displayName, color = Ice, style = MaterialTheme.typography.titleLarge)
            androidx.compose.material3.OutlinedButton(onClick = onSignOut, enabled = !busy, modifier = Modifier.testTag("sign_out")) { Text(stringResource(R.string.backend_sign_out)) }
        }
        Text(
            stringResource(R.string.profile_title),
            color = Ice,
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
        )
        Surface(
            color = Navy900,
            shape = MaterialTheme.shapes.large,
            border = androidx.compose.foundation.BorderStroke(1.dp, Navy700),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    stringResource(R.string.profile_language_title),
                    color = Ice,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    stringResource(R.string.profile_language_description),
                    color = Muted,
                    style = MaterialTheme.typography.bodyMedium,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(
                        selected = language == "id",
                        onClick = { onLanguageChange("id") },
                        label = { Text(stringResource(R.string.language_indonesian)) },
                        colors = FilterChipDefaults.filterChipColors(
                            containerColor = Navy950,
                            labelColor = Muted,
                            selectedContainerColor = Signal,
                            selectedLabelColor = Navy950,
                        ),
                        modifier = Modifier.testTag("profile_language_id"),
                    )
                    FilterChip(
                        selected = language == "en",
                        onClick = { onLanguageChange("en") },
                        label = { Text(stringResource(R.string.language_english)) },
                        colors = FilterChipDefaults.filterChipColors(
                            containerColor = Navy950,
                            labelColor = Muted,
                            selectedContainerColor = Signal,
                            selectedLabelColor = Navy950,
                        ),
                        modifier = Modifier.testTag("profile_language_en"),
                    )
                }
            }
        }
        Surface(
            color = Navy900,
            shape = MaterialTheme.shapes.large,
            border = androidx.compose.foundation.BorderStroke(1.dp, Navy700),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(
                stringResource(R.string.profile_placeholder),
                color = Muted,
                modifier = Modifier.padding(18.dp),
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}
