package dev.alethia.mobile

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
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

