package com.loopbreak.inverterly.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.loopbreak.inverterly.AppStore

/**
 * What the cloud reports for the inverter, unprocessed, with the serial number and logger PN removed.
 * For finding out whether a model reports a figure the app does not show yet (grid or feed-in power):
 * copy it or share it.
 */
@Composable
fun RawReadingsDialog(store: AppStore, onDismiss: () -> Unit) {
    val context = LocalContext.current
    var text by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { text = store.rawReadings() }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.statusBarsPadding().navigationBarsPadding().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(Modifier.fillMaxWidth()) {
                    Text("Raw readings", Modifier.weight(1f), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                    TextButton(onClick = onDismiss) { Text("Close") }
                }
                val current = text
                if (current == null) {
                    CircularProgressIndicator(color = marks.solar)
                    Text("Asking the cloud…", color = MaterialTheme.colorScheme.onSurfaceVariant)
                } else {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(onClick = { share(context, current) }, colors = ButtonDefaults.buttonColors(containerColor = marks.solar, contentColor = androidx.compose.ui.graphics.Color.White)) { Text("Share") }
                        OutlinedButton(onClick = { copy(context, current) }) { Text("Copy") }
                    }
                    SelectionContainer(Modifier.weight(1f)) {
                        Text(current, Modifier.verticalScroll(rememberScrollState()).fillMaxWidth(), fontFamily = FontFamily.Monospace, fontSize = 12.sp, lineHeight = 17.sp)
                    }
                }
            }
        }
    }
}

private fun copy(context: Context, text: String) {
    (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("Inverterly raw readings", text))
}

private fun share(context: Context, text: String) {
    val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_SUBJECT, "Inverterly raw readings").putExtra(Intent.EXTRA_TEXT, text)
    context.startActivity(Intent.createChooser(send, "Share raw readings"))
}
