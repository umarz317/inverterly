package com.loopbreak.inverterly.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.loopbreak.inverterly.AppStore
import com.loopbreak.inverterly.BuildConfig
import com.loopbreak.inverterly.core.PowerFormat
import kotlinx.coroutines.launch

/** The account, which inverter to show, and signing out, laid out as a sheet over the tabs. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsSheet(store: AppStore, onDismiss: () -> Unit) {
    val tones = marks
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant
    val scope = rememberCoroutineScope()
    var confirmSignOut by remember { mutableStateOf(false) }
    var showRaw by remember { mutableStateOf(false) }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = MaterialTheme.colorScheme.background) {
        Column(
            Modifier.verticalScroll(rememberScrollState()).navigationBarsPadding().padding(horizontal = 16.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("Settings", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 4.dp))

            PhoneCard {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    Box(
                        Modifier.size(56.dp).background(Brush.linearGradient(listOf(tones.solar, Color(0xFFFFD60A).copy(alpha = 0.9f))), CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text((store.username ?: "?").take(1).uppercase(), color = Color.White, style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.SemiBold)
                    }
                    Column {
                        Text(store.username ?: "Signed in", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1)
                        val parts = mutableListOf("Inverter cloud account")
                        store.snapshot?.ratedPowerW?.let { if (it > 0) { parts.clear(); parts += PowerFormat.kilowatts(it) + " inverter" } }
                        store.selectedDeviceName?.let { parts.add(0, it) }
                        Text(parts.joinToString(" · "), style = MaterialTheme.typography.bodyMedium, color = secondary, maxLines = 1)
                    }
                }
            }

            if (store.devices.size > 1) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Inverter", style = MaterialTheme.typography.labelLarge, color = secondary, modifier = Modifier.padding(horizontal = 4.dp))
                    PhoneCard(padding = false) {
                        store.devices.forEachIndexed { index, device ->
                            if (index > 0) HorizontalDivider(Modifier.padding(start = 16.dp), color = MaterialTheme.colorScheme.outlineVariant)
                            Row(
                                Modifier.fillMaxWidth().clickable { scope.launch { store.selectDevice(device.id) } }.padding(horizontal = 12.dp, vertical = 4.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                RadioButton(device.isSelected, { scope.launch { store.selectDevice(device.id) } })
                                Text(device.name, style = MaterialTheme.typography.bodyLarge)
                            }
                        }
                    }
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                PhoneCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Remember Me", Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                        Switch(store.rememberMe, { store.rememberMe(it) },
                            colors = SwitchDefaults.colors(checkedTrackColor = tones.battery, checkedThumbColor = Color.White))
                    }
                }
                Text("With Remember Me off, you sign in again each time the app is opened.", style = MaterialTheme.typography.bodySmall,
                    color = secondary, modifier = Modifier.padding(horizontal = 16.dp))
            }

            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                PhoneCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Version", Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                        Text("${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})", color = secondary, style = MaterialTheme.typography.bodyLarge)
                    }
                }
                Text("Inverterly only reads your inverter. It cannot change any setting.", style = MaterialTheme.typography.bodySmall,
                    color = secondary, modifier = Modifier.padding(horizontal = 16.dp))
            }

            PhoneCard(padding = false) {
                Row(Modifier.fillMaxWidth().clickable { showRaw = true }.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Raw readings", Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                    Text("For troubleshooting", color = secondary, style = MaterialTheme.typography.bodyMedium)
                }
            }

            PhoneCard(padding = false) {
                Box(Modifier.fillMaxWidth().clickable { confirmSignOut = true }.padding(16.dp), contentAlignment = Alignment.Center) {
                    Text("Sign Out", color = tones.alert, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium)
                }
            }
            Spacer(Modifier.height(8.dp))
        }
    }

    if (showRaw) RawReadingsDialog(store) { showRaw = false }

    if (confirmSignOut) {
        AlertDialog(
            onDismissRequest = { confirmSignOut = false },
            title = { Text("Sign out of this account?") },
            text = { Text("Your saved login and history on this phone are removed.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmSignOut = false
                    scope.launch { store.signOut() }
                    onDismiss()
                }) { Text("Sign Out", color = tones.alert) }
            },
            dismissButton = { TextButton(onClick = { confirmSignOut = false }) { Text("Cancel") } },
        )
    }
}
