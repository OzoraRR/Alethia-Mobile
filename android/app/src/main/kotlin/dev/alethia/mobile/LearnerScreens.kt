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

@Composable
fun ReportForm(enabled: Boolean, onSubmit: (String, String, String) -> Unit) {
    var title by rememberSaveable { mutableStateOf("") }
    var evidence by rememberSaveable { mutableStateOf("") }
    var risk by rememberSaveable { mutableStateOf("") }
    Text(stringResource(R.string.backend_new_report), color = Ice, style = MaterialTheme.typography.titleLarge)
    Text(stringResource(R.string.backend_report_scope), color = Muted)
    OutlinedTextField(title, { title = it.take(160) }, label = { Text(stringResource(R.string.backend_report_title)) }, enabled = enabled, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(evidence, { evidence = it.take(5000) }, label = { Text(stringResource(R.string.backend_report_evidence)) }, enabled = enabled, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(risk, { risk = it.take(5000) }, label = { Text(stringResource(R.string.backend_report_risk)) }, enabled = enabled, modifier = Modifier.fillMaxWidth())
    Button(onClick = { onSubmit(title, evidence, risk) }, enabled = enabled && title.trim().length >= 4 && evidence.trim().length >= 10 && risk.trim().length >= 10) {
        Text(stringResource(R.string.backend_submit_report))
    }
}
