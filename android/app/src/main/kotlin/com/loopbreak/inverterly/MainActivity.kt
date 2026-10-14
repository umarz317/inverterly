package com.loopbreak.inverterly

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import com.loopbreak.inverterly.ui.InverterlyApp

/** The app: sign-in, then the Now, Today and History tabs, reading while the app is in front. */
class MainActivity : ComponentActivity() {
    // `adb shell am start -n com.loopbreak.inverterly/.MainActivity --ez demo true` shows made-up readings (debug builds only).
    private val store: AppStore by viewModels {
        AppStore.Factory(application, demo = BuildConfig.DEBUG && intent.getBooleanExtra("demo", false))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            // "Open" drives the faster polling, the hero's animation and catching up on return.
            LifecycleEventEffect(Lifecycle.Event.ON_START) { store.onForeground(true) }
            LifecycleEventEffect(Lifecycle.Event.ON_STOP) { store.onForeground(false) }
            LifecycleEventEffect(Lifecycle.Event.ON_CREATE) { store.start() }
            InverterlyApp(store)
        }
    }
}
