package dev.alethia.mobile

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp

@Composable
fun LearnerListScreen(title: Int, rows: List<LearnerRow>, signedIn: Boolean, onRead: ((String) -> Unit)? = null) {
    Text(stringResource(title), style = MaterialTheme.typography.headlineSmall, color = Ice)
    if (!signedIn) Text(stringResource(R.string.backend_login_required), color = Muted)
    else if (rows.isEmpty()) Text(stringResource(R.string.backend_empty), color = Muted)
    rows.forEach { row ->
        Surface(color = Navy900, modifier = Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.medium) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(row.title, color = Ice, style = MaterialTheme.typography.titleMedium)
                Text(row.detail, color = Muted)
                if (!row.isRead && onRead != null) TextButton(onClick = { onRead(row.id) }) {
                    Text(stringResource(R.string.backend_mark_read))
                }
            }
        }
    }
}
