package com.loopbreak.inverterly.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.loopbreak.inverterly.AppStore
import com.loopbreak.inverterly.R
import kotlinx.coroutines.launch

/** The first screen: the account from the inverter's phone app. The password goes to the Android Keystore. */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun SignInScreen(store: AppStore) {
    val tones = marks
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant
    var user by rememberSaveable { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var showPassword by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val focus = LocalFocusManager.current
    val passwordFocus = remember { FocusRequester() }
    val ready = user.trim().isNotEmpty() && password.isNotEmpty() && !working

    fun submit() {
        if (!ready) return
        focus.clearFocus()
        working = true
        val account = user.trim()
        scope.launch {
            store.signIn(account, password)
            working = false
            password = ""
            if (store.signInRequired) passwordFocus.requestFocus()
        }
    }

    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).imePadding()) {
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).statusBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Column(Modifier.widthIn(max = 440.dp).padding(horizontal = 20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Spacer(Modifier.height(56.dp))
                Image(
                    painterResource(R.drawable.logo), contentDescription = null,
                    modifier = Modifier.size(96.dp).shadow(12.dp, RoundedCornerShape(22.dp)).clip(RoundedCornerShape(22.dp)),
                )
                Text("Inverterly", fontSize = 34.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 24.dp))
                Text("Your solar inverter, live: panels, battery, grid and load.", color = secondary,
                    style = MaterialTheme.typography.bodyLarge, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 6.dp))

                Column(
                    Modifier.padding(top = 40.dp).fillMaxWidth().clip(RoundedCornerShape(16.dp))
                        .background(MaterialTheme.colorScheme.surfaceContainer),
                ) {
                    FieldRow(Icons.Filled.Person) {
                        TextField(
                            user, { user = it }, Modifier.fillMaxWidth().semantics { contentType = ContentType.Username },
                            placeholder = { Text("Username") }, singleLine = true, enabled = !working,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email, imeAction = ImeAction.Next),
                            keyboardActions = KeyboardActions(onNext = { passwordFocus.requestFocus() }),
                            colors = plainFieldColors(),
                        )
                    }
                    HorizontalDivider(Modifier.padding(start = 52.dp), color = MaterialTheme.colorScheme.outlineVariant)
                    FieldRow(Icons.Filled.Lock) {
                        TextField(
                            password, { password = it }, Modifier.fillMaxWidth().focusRequester(passwordFocus)
                                .semantics { contentType = ContentType.Password },
                            placeholder = { Text("Password") }, singleLine = true, enabled = !working,
                            visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Go),
                            keyboardActions = KeyboardActions(onGo = { submit() }),
                            trailingIcon = {
                                IconButton(onClick = { showPassword = !showPassword }) {
                                    Icon(if (showPassword) Icons.Filled.VisibilityOff else Icons.Filled.Visibility,
                                        contentDescription = if (showPassword) "Hide password" else "Show password", tint = secondary)
                                }
                            },
                            colors = plainFieldColors(),
                        )
                    }
                    HorizontalDivider(Modifier.padding(start = 52.dp), color = MaterialTheme.colorScheme.outlineVariant)
                    FieldRow(Icons.Filled.Shield) {
                        Row(Modifier.fillMaxWidth().padding(end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text("Remember me", Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                            Switch(store.rememberMe, { store.rememberMe(it) }, enabled = !working,
                                colors = SwitchDefaults.colors(checkedTrackColor = tones.battery, checkedThumbColor = androidx.compose.ui.graphics.Color.White))
                        }
                    }
                }

                Text("Use the same username and password as your inverter's monitoring app.", color = secondary,
                    style = MaterialTheme.typography.bodySmall, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 8.dp))

                val error = store.signInError
                if (error != null && !working) {
                    Row(
                        Modifier.padding(top = 16.dp).fillMaxWidth().clip(RoundedCornerShape(12.dp))
                            .background(tones.alert.copy(alpha = 0.1f)).padding(12.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(Icons.Filled.ErrorOutline, null, tint = tones.alert, modifier = Modifier.size(18.dp))
                        Text(error, color = tones.alert, style = MaterialTheme.typography.bodySmall)
                    }
                }
                Spacer(Modifier.height(24.dp))
            }
        }

        Column(
            Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 20.dp).padding(top = 12.dp, bottom = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Button(
                onClick = ::submit, enabled = ready,
                modifier = Modifier.widthIn(max = 440.dp).fillMaxWidth().heightIn(min = 52.dp),
                colors = ButtonDefaults.buttonColors(containerColor = tones.solar, contentColor = androidx.compose.ui.graphics.Color.White),
            ) {
                if (working) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = androidx.compose.ui.graphics.Color.White)
                Spacer(Modifier.size(8.dp))
                Text(if (working) "Signing In…" else "Sign In", fontWeight = FontWeight.SemiBold)
            }
            Text("Read-only. It can't change your inverter's settings.", color = secondary, style = MaterialTheme.typography.labelMedium)
        }
    }
}

@Composable
private fun FieldRow(icon: androidx.compose.ui.graphics.vector.ImageVector, content: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 52.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 14.dp).size(24.dp))
        content()
    }
}

@Composable
private fun plainFieldColors() = TextFieldDefaults.colors(
    focusedContainerColor = androidx.compose.ui.graphics.Color.Transparent,
    unfocusedContainerColor = androidx.compose.ui.graphics.Color.Transparent,
    disabledContainerColor = androidx.compose.ui.graphics.Color.Transparent,
    focusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
    unfocusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
    disabledIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
)
