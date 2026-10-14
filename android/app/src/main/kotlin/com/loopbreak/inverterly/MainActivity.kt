package com.loopbreak.inverterly

import android.os.Bundle
import android.os.SystemClock
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
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
        // Hold the splash until the first reading (or the sign-in form) is ready, but never longer than a moment:
        // after that the Now tab's own loading card takes over.
        val started = SystemClock.uptimeMillis()
        installSplashScreen().setKeepOnScreenCondition {
            store.snapshot == null && !store.signInRequired && SystemClock.uptimeMillis() - started < 1200
        }
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
