package com.loopbreak.inverterly.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.Canvas
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ShowChart
import androidx.compose.material.icons.filled.AccessTime
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.NightsStay
import androidx.compose.material.icons.filled.Power
import androidx.compose.material.icons.filled.PowerOff
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material.icons.filled.Battery0Bar
import androidx.compose.material.icons.filled.Battery2Bar
import androidx.compose.material.icons.filled.Battery4Bar
import androidx.compose.material.icons.filled.Battery6Bar
import androidx.compose.material.icons.filled.BatteryFull
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.loopbreak.inverterly.AppStore
import com.loopbreak.inverterly.HistoryTab
import com.loopbreak.inverterly.core.DayCurve
import com.loopbreak.inverterly.core.EnergySnapshot
import com.loopbreak.inverterly.core.InverterMode
import com.loopbreak.inverterly.core.PowerFormat
import kotlinx.coroutines.launch
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

private enum class PhoneTab(val title: String, val icon: ImageVector) {
    Now("Now", Icons.Filled.Bolt),
    Today("Today", Icons.AutoMirrored.Filled.ShowChart),
    History("History", Icons.Filled.CalendarMonth),
}

/** The app: sign-in until there is an account, then three tabs. */
@Composable
fun InverterlyApp(store: AppStore) {
    InverterlyTheme {
        // Until the first reading lands there is nothing to show but a loading screen: no header, no tab bar.
        val loading = store.snapshot == null && store.errorMessage == null && !store.signInRequired
        LightBars(!loading)
        if (store.signInRequired && store.snapshot == null) SignInScreen(store)
        else if (loading) LoadingScreen()
        else Tabs(store)
    }
}

/** Dark status and navigation bar icons on the app's light pages; light ones on the dark loading screen. */
@Composable
private fun LightBars(followTheme: Boolean) {
    val view = androidx.compose.ui.platform.LocalView.current
    val dark = androidx.compose.foundation.isSystemInDarkTheme()
    androidx.compose.runtime.SideEffect {
        val window = (view.context as? android.app.Activity)?.window ?: return@SideEffect
        val controller = androidx.core.view.WindowCompat.getInsetsController(window, view)
        val darkIcons = followTheme && !dark
        controller.isAppearanceLightStatusBars = darkIcons
        controller.isAppearanceLightNavigationBars = darkIcons
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Tabs(store: AppStore) {
    var tab by rememberSaveable { mutableStateOf(PhoneTab.Now) }
    var showSettings by rememberSaveable { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        bottomBar = {
            NavigationBar(containerColor = MaterialTheme.colorScheme.surfaceContainer) {
                for (entry in PhoneTab.entries) {
                    NavigationBarItem(
                        selected = tab == entry,
                        onClick = { tab = entry },
                        icon = { Icon(entry.icon, contentDescription = null) },
                        label = { Text(entry.title) },
                        colors = NavigationBarItemDefaults.colors(
                            selectedIconColor = MaterialTheme.colorScheme.onSecondaryContainer,
                            selectedTextColor = MaterialTheme.colorScheme.onSecondaryContainer,
                            indicatorColor = MaterialTheme.colorScheme.secondaryContainer,
                        ),
                    )
                }
            }
        },
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = {
                scope.launch {
                    refreshing = true
                    store.refresh(force = true)
                    when (tab) {
                        PhoneTab.Today -> store.loadToday(force = true)
                        PhoneTab.History -> store.loadHistory(force = true)
                        else -> {}
                    }
                    refreshing = false
                }
            },
            modifier = Modifier.fillMaxSize().padding(padding),
        ) {
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).statusBarsPadding(),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Column(
                    Modifier.widthIn(max = 600.dp).fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 24.dp),
                    verticalArrangement = Arrangement.spacedBy(20.dp),
                ) {
                    PhoneHeader(tab.title, store) { showSettings = true }
                    when (tab) {
                        PhoneTab.Now -> NowScreen(store)
                        PhoneTab.Today -> TodayScreen(store)
                        PhoneTab.History -> HistoryScreen(store)
                    }
                }
            }
        }
    }
    if (showSettings) SettingsSheet(store) { showSettings = false }
}

/** The tab's title with the reading's freshness under it, and the settings button beside them. */
@Composable
private fun PhoneHeader(title: String, store: AppStore, openSettings: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(start = 4.dp, top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, fontSize = 34.sp, fontWeight = FontWeight.Bold)
            LiveStatus(store)
        }
        IconButton(onClick = openSettings, Modifier.size(44.dp)) {
            Icon(Icons.Filled.Settings, contentDescription = "Settings", tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** Green while readings are fresh, orange once the logger has gone quiet, grey before the first one. */
@Composable
private fun LiveStatus(store: AppStore) {
    val tones = marks
    val snapshot = store.snapshot
    val (color, text) = if (snapshot == null) {
        Color.Gray to (if (store.errorMessage == null) "Connecting…" else "Not connected")
    } else {
        val parts = mutableListOf("Updated " + clockTime(snapshot.deviceTime ?: snapshot.fetchedAt))
        store.selectedDeviceName?.let { parts += it }
        (if (store.readingIsStale) tones.warning else tones.battery) to parts.joinToString(" · ")
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.size(8.dp).background(color, CircleShape))
        Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

// region Now

/** The battery and the grid in a few words: "Battery 78%, charging · grid available". */
private val EnergySnapshot.statusLine: String
    get() {
        val parts = mutableListOf<String>()
        batteryPercent?.let {
            val verb = if (batteryPowerW > 30) "charging" else if (batteryPowerW < -30) "discharging" else "idle"
            parts += "Battery ${it.roundToInt()}%, $verb"
        }
        parts += if (exportPowerW > 0) "exporting ${PowerFormat.watts(exportPowerW)}" else if (gridPresent) "grid available" else "grid outage"
        return parts.joinToString(" · ")
    }

/** The load as a share of the inverter's rating, 0...1. */
private val EnergySnapshot.loadFraction: Double
    get() {
        ratedPowerW?.let { if (it > 0) return (loadPowerW / it).coerceIn(0.0, 1.0) }
        return ((loadPercent ?: 0.0) / 100).coerceIn(0.0, 1.0)
    }

private fun EnergySnapshot.staleText(): String {
    val time = deviceTime ?: return "The logger has stopped reporting."
    val minutes = Duration.between(time, Instant.now()).toMinutes()
    val ago = when {
        minutes < 60 -> "$minutes min ago"
        minutes < 48 * 60 -> "${minutes / 60} h ago"
        else -> "${minutes / 1440} days ago"
    }
    return "The logger last reported $ago. Numbers may be old."
}

private fun batteryIcon(percent: Double?, charging: Boolean): ImageVector = when {
    charging -> Icons.Filled.BatteryChargingFull
    percent == null -> Icons.Filled.Battery0Bar
    percent < 13 -> Icons.Filled.Battery0Bar
    percent < 38 -> Icons.Filled.Battery2Bar
    percent < 63 -> Icons.Filled.Battery4Bar
    percent < 88 -> Icons.Filled.Battery6Bar
    else -> Icons.Filled.BatteryFull
}

@Composable
private fun NowScreen(store: AppStore) {
    val snapshot = store.snapshot
    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        if (snapshot != null) {
            store.errorMessage?.let { Banner(Icons.Filled.WarningAmber, it, marks.alert) }
            snapshot.activeWarning?.let { Banner(Icons.Filled.Bolt, "Inverter warning: $it", marks.alert) }
            if (snapshot.isStale(now = store.clock)) Banner(Icons.Filled.AccessTime, snapshot.staleText(), marks.warning)
            LiveCard(snapshot, store)
            Readings(snapshot)
            Details(snapshot, store)
        } else if (store.errorMessage != null) {
            FailedView(store.errorMessage.orEmpty())
        }
    }
}

/** What carries the load, the hero and the load itself. */
@Composable
private fun LiveCard(snapshot: EnergySnapshot, store: AppStore) {
    PhoneCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(snapshot.mode.label, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                Text(snapshot.statusLine, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Spacer(Modifier.width(8.dp))
            BatteryRing(snapshot.batteryPercent, snapshot.batteryPowerW)
        }
        HeroFlow(snapshot, store.panelOpen, Modifier.fillMaxWidth().height(HERO_HEIGHT_DP.dp))
        val (number, unit) = PowerFormat.split(snapshot.loadPowerW)
        Row(verticalAlignment = Alignment.Bottom) {
            Text(number, fontSize = 48.sp, fontWeight = FontWeight.Light, fontFamily = FontFamily.SansSerif, lineHeight = 52.sp)
            Spacer(Modifier.width(4.dp))
            Text("$unit load", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(bottom = 8.dp))
            Spacer(Modifier.weight(1f))
            Text("${(snapshot.loadFraction * 100).roundToInt()}% of capacity", style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(bottom = 8.dp))
        }
    }
}

/** The battery's level as a ring, with an arrow for the direction it is moving. */
@Composable
private fun BatteryRing(percent: Double?, powerW: Double) {
    val tones = marks
    val ink = MaterialTheme.colorScheme.onSurface
    val fraction = ((percent ?: 0.0) / 100).coerceIn(0.0, 1.0).toFloat()
    val low = (percent ?: 100.0) < 20
    val state = if (powerW > 30) "charging at ${PowerFormat.watts(powerW)}" else if (powerW < -30) "discharging at ${PowerFormat.watts(powerW)}" else "idle"
    val description = (percent?.let { "Battery ${it.roundToInt()}%" } ?: "Battery level unknown") + ", $state"
    Box(Modifier.size(34.dp).semantics { contentDescription = description }, contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val stroke = 2.dp.toPx()
            drawCircle(ink.copy(alpha = 0.10f), (size.minDimension - stroke) / 2, style = androidx.compose.ui.graphics.drawscope.Stroke(stroke))
            drawArc(if (low) tones.alert else ink.copy(alpha = 0.85f), -90f, 360f * fraction, false,
                androidx.compose.ui.geometry.Offset(stroke / 2, stroke / 2),
                androidx.compose.ui.geometry.Size(size.width - stroke, size.height - stroke),
                style = androidx.compose.ui.graphics.drawscope.Stroke(stroke, cap = androidx.compose.ui.graphics.StrokeCap.Round))
        }
        Text(if (powerW > 30) "↑" else if (powerW < -30) "↓" else "–", fontSize = 12.sp, fontWeight = FontWeight.Bold,
            color = if (powerW > 30) tones.battery else ink.copy(alpha = 0.75f))
    }
}

/** Solar, battery, grid and output in one card. */
@Composable
private fun Readings(snapshot: EnergySnapshot) {
    val tones = marks
    val battery = snapshot.batteryPowerW
    PhoneCard {
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Reading(
                if (snapshot.pvPowerW > 20) Icons.Filled.WbSunny else Icons.Filled.NightsStay, tones.solar, "Solar",
                PowerFormat.watts(snapshot.pvPowerW), snapshot.pvVoltage?.let { "%.0f V".format(Locale.US, it) } ?: "–",
                quiet = snapshot.pvPowerW < 1, modifier = Modifier.weight(1f),
            )
            Reading(
                batteryIcon(snapshot.batteryPercent, battery > 30), tones.battery, "Battery",
                snapshot.batteryPercent?.let { "${it.roundToInt()}%" } ?: "–",
                if (abs(battery) > 30) "${if (battery > 0) "Charging" else "Discharging"} ${PowerFormat.watts(abs(battery))}" else "Idle",
                modifier = Modifier.weight(1f),
            )
        }
        Spacer(Modifier.height(4.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Reading(
                if (snapshot.gridPresent) Icons.Filled.Power else Icons.Filled.PowerOff,
                if (snapshot.gridPresent) tones.grid else tones.alert, "Grid",
                if (!snapshot.gridPresent) "Outage" else if (snapshot.exportPowerW > 0) PowerFormat.watts(snapshot.exportPowerW)
                else if (snapshot.gridPowerW > 0) PowerFormat.watts(snapshot.gridPowerW) else "Standby",
                if (!snapshot.gridPresent) "No supply" else if (snapshot.exportPowerW > 0) "Exporting (est.)"
                else "%.0f V".format(Locale.US, snapshot.gridVoltage ?: 0.0),
                quiet = snapshot.gridPresent && snapshot.gridPowerW < 1 && snapshot.exportPowerW < 1, modifier = Modifier.weight(1f),
            )
            Reading(
                Icons.Filled.Home, MaterialTheme.colorScheme.onSurfaceVariant, "Output",
                snapshot.outputVoltage?.let { "%.0f V".format(Locale.US, it) } ?: "–",
                snapshot.outputHz?.let { "%.1f Hz".format(Locale.US, it) } ?: "–",
                modifier = Modifier.weight(1f),
            )
        }
    }
}

/** One reading: a small tinted symbol and caption, the value, and a detail under it. */
@Composable
private fun Reading(icon: ImageVector, tint: Color, caption: String, value: String, detail: String, modifier: Modifier = Modifier, quiet: Boolean = false) {
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant
    Column(modifier.semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(icon, null, tint = tint, modifier = Modifier.size(18.dp))
            Text(caption, style = MaterialTheme.typography.bodyMedium, color = secondary)
        }
        Text(value, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold,
            color = if (quiet) secondary else MaterialTheme.colorScheme.onSurface, maxLines = 1)
        Text(detail, style = MaterialTheme.typography.bodySmall, color = secondary, maxLines = 1)
    }
}

/** The full list, folded away until asked for. */
@Composable
private fun Details(snapshot: EnergySnapshot, store: AppStore) {
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant
    PhoneCard {
        Row(Modifier.fillMaxWidth().clickable { store.showDetails = !store.showDetails }, verticalAlignment = Alignment.CenterVertically) {
            Text("Details", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
            Icon(if (store.showDetails) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, null, tint = secondary)
        }
        if (store.showDetails) {
            fun v(value: Double?, format: String) = value?.let { format.format(Locale.US, it) }
            val rows = mutableListOf<Pair<String, List<String?>>>()
            rows += "Solar input" to listOf(PowerFormat.watts(snapshot.pvPowerW), v(snapshot.pvVoltage, "%.1f V"))
            val current = when {
                snapshot.batteryChargeA > 0.4 -> "+%.0f A".format(Locale.US, snapshot.batteryChargeA)
                snapshot.batteryDischargeA > 0.4 -> "−%.0f A".format(Locale.US, snapshot.batteryDischargeA)
                else -> "0 A"
            }
            rows += "Battery" to listOf(v(snapshot.batteryVoltage, "%.1f V"), current)
            rows += "Grid input" to if (snapshot.gridPresent) listOf(v(snapshot.gridVoltage, "%.1f V"), v(snapshot.gridHz, "%.1f Hz")) else listOf("No supply")
            rows += "Output" to listOf(v(snapshot.outputVoltage, "%.1f V"), v(snapshot.outputHz, "%.1f Hz"))
            rows += "Load" to listOf(PowerFormat.watts(snapshot.loadPowerW), snapshot.loadApparentVA?.let { "${it.roundToInt()} VA" })
            if (snapshot.gridPowerW > 0) rows += "Grid draw (estimated)" to listOf(PowerFormat.watts(snapshot.gridPowerW))
            if (snapshot.exportPowerW > 0) rows += "Grid export (estimated)" to listOf(PowerFormat.watts(snapshot.exportPowerW))
            snapshot.machineType?.let { rows += "Type" to listOf(it) }
            snapshot.collectorOnline?.let { rows += "Logger" to listOf(if (it) "Online" else "Offline") }
            snapshot.deviceTime?.let {
                rows += "Last report" to listOf(DateTimeFormatter.ofPattern("MMM d, ", Locale.getDefault()).format(it.atZone(ZoneId.systemDefault())) + clockTime(it))
            }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                for ((title, values) in rows) {
                    Row(verticalAlignment = Alignment.Top) {
                        Text(title, style = MaterialTheme.typography.bodyMedium, color = secondary)
                        Spacer(Modifier.weight(1f))
                        Text(values.filterNotNull().joinToString("  ·  "), style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
                    }
                }
            }
        }
    }
}

@Composable
private fun FailedView(message: String) {
    PhoneCard {
        Column(Modifier.fillMaxWidth().padding(vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(Icons.Filled.WarningAmber, null, tint = marks.alert, modifier = Modifier.size(36.dp))
            Text("Could not read the inverter", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
            Text("Pull down to try again.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

// endregion

// region Today

@Composable
private fun TodayScreen(store: AppStore) {
    var selection by remember { mutableStateOf<Instant?>(null) }
    LaunchedEffect(Unit) { store.loadToday() }
    val curve = store.today
    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        if (curve != null && curve.points.isNotEmpty()) {
            val totals = remember(curve, store.clock) { curve.totals() }
            MixSummary(totals.solarKWh, totals.gridKWh, totals.loadKWh, totals.exportKWh)
            PhoneCard { PowerChart(curve, selection, { selection = it }) }
            if (curve.points.any { it.batteryPercent != null }) {
                PhoneCard { BatteryChart(curve, selection, { selection = it }) }
            }
        } else {
            Placeholder(loading = store.todayLoading, loadingText = "Loading today's readings…",
                message = store.todayError ?: "No readings for today yet.", icon = Icons.AutoMirrored.Filled.ShowChart)
        }
    }
}

@Composable
private fun Placeholder(loading: Boolean, loadingText: String, message: String, icon: ImageVector) {
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant
    PhoneCard {
        Column(Modifier.fillMaxWidth().padding(vertical = 40.dp, horizontal = 8.dp), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (loading) {
                CircularProgressIndicator(modifier = Modifier.size(28.dp), color = marks.solar)
                Text(loadingText, style = MaterialTheme.typography.bodyMedium, color = secondary)
            } else {
                Icon(icon, null, tint = secondary.copy(alpha = 0.6f), modifier = Modifier.size(40.dp))
                Text(message, style = MaterialTheme.typography.bodyMedium, color = secondary, textAlign = TextAlign.Center)
            }
        }
    }
}

/** A period's share of solar as one large figure and a bar, with the three totals under it. */
@Composable
private fun MixSummary(solarKWh: Double, gridKWh: Double, loadKWh: Double, exportKWh: Double = 0.0) {
    val tones = marks
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant
    // What went to the grid was made by the panels but did not serve the house, so it is left out of the share.
    val usedSolar = max(0.0, solarKWh - exportKWh)
    val supplied = usedSolar + gridKWh
    val share = if (supplied > 0) usedSolar / supplied else 0.0
    PhoneCard(Modifier.semantics(mergeDescendants = true) {}) {
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("${(share * 100).roundToInt()}%", fontSize = 40.sp, fontWeight = FontWeight.SemiBold, lineHeight = 44.sp)
            Text("from solar", style = MaterialTheme.typography.titleMedium, color = secondary, modifier = Modifier.padding(bottom = 6.dp))
        }
        Row(Modifier.fillMaxWidth().height(6.dp).clip(RoundedCornerShape(3.dp)).background(secondary.copy(alpha = 0.15f)),
            horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            if (usedSolar > 0) Box(Modifier.weight(share.toFloat().coerceAtLeast(0.02f)).fillMaxSize().background(tones.solar))
            if (gridKWh > 0) Box(Modifier.weight((1 - share).toFloat().coerceAtLeast(0.02f)).fillMaxSize().background(tones.grid))
        }
        Row {
            Total(EnergySource.Solar, solarKWh, Modifier.weight(1f))
            Total(EnergySource.Grid, gridKWh, Modifier.weight(1f))
            Total(EnergySource.Load, loadKWh, Modifier.weight(1f))
            if (exportKWh > 0) Total(EnergySource.Export, exportKWh, Modifier.weight(1f))
        }
    }
}

@Composable
private fun Total(source: EnergySource, kWh: Double, modifier: Modifier) {
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            SourceIcon(source, 14.dp)
            Text(source.title, style = MaterialTheme.typography.labelMedium, color = secondary)
        }
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(PowerFormat.kWhNumber(kWh), style = MaterialTheme.typography.titleMedium)
            Text("kWh", style = MaterialTheme.typography.labelSmall, color = secondary, modifier = Modifier.padding(bottom = 2.dp))
        }
    }
}

// endregion

// region History

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HistoryScreen(store: AppStore) {
    var selection by remember { mutableStateOf<Period?>(null) }
    LaunchedEffect(Unit) { store.loadHistory() }
    LaunchedEffect(store.historyTab) { selection = null }
    val byDay = store.historyTab == HistoryTab.Days
    val periods = remember(store.days, store.historyTab) {
        if (byDay) store.currentMonthDays.mapNotNull { d ->
            val date = runCatching { LocalDate.parse(d.day) }.getOrNull() ?: return@mapNotNull null
            Period(d.day, date, dayLabel(date), d.solarKWh, d.gridKWh, d.loadKWh, !d.complete, d.exportKWh)
        } else store.months.mapNotNull { m ->
            val date = runCatching { LocalDate.parse(m.month + "-01") }.getOrNull() ?: return@mapNotNull null
            Period(m.month, date, DateTimeFormatter.ofPattern("MMMM yyyy", Locale.getDefault()).format(date),
                m.solarKWh, m.gridKWh, m.loadKWh, false, m.exportKWh)
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            HistoryTab.entries.forEachIndexed { index, tab ->
                SegmentedButton(
                    selected = store.historyTab == tab,
                    onClick = { store.selectHistoryTab(tab) },
                    shape = SegmentedButtonDefaults.itemShape(index, HistoryTab.entries.size),
                    label = { Text(tab.title) },
                )
            }
        }
        if (periods.isEmpty()) {
            Placeholder(loading = store.historyLoading, loadingText = "Reading history…",
                message = store.historyError ?: "No history yet.", icon = Icons.Filled.CalendarMonth)
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(summaryTitle(store.historyTab, periods.size), style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 4.dp))
                MixSummary(periods.sumOf { it.solar }, periods.sumOf { it.grid }, periods.sumOf { it.load }, periods.sumOf { it.export })
            }
            PhoneCard { PeriodChart(periods, byDay, selection, { selection = it }) }
            PeriodList(periods)
            if (store.historyLoading || store.historyError != null) {
                Row(Modifier.padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (store.historyLoading) {
                        CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = marks.solar)
                        Text("Updating…", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    } else {
                        Text(store.historyError.orEmpty(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

private fun summaryTitle(tab: HistoryTab, count: Int) =
    if (tab == HistoryTab.Days) "This month" else if (count == 1) "This month" else "Last $count months"

private fun dayLabel(date: LocalDate): String {
    val today = LocalDate.now()
    return when (date) {
        today -> "Today"
        today.minusDays(1) -> "Yesterday"
        else -> date.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.getDefault()) + " " + date.dayOfMonth
    }
}

/** Every period, newest first, with its three totals. */
@Composable
private fun PeriodList(periods: List<Period>) {
    val tones = marks
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant
    // The Export column appears only when some period sent power to the grid.
    val showExport = periods.any { it.export > 0 }
    PhoneCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Spacer(Modifier.weight(1f))
            ListColumn(EnergySource.Solar)
            ListColumn(EnergySource.Grid)
            ListColumn(EnergySource.Load)
            if (showExport) ListColumn(EnergySource.Export)
        }
        periods.forEachIndexed { index, period ->
            if (index > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            val color = if (period.live) secondary else MaterialTheme.colorScheme.onSurface
            Row(
                Modifier.fillMaxWidth().padding(vertical = 2.dp).semantics(mergeDescendants = true) {
                    contentDescription = "${period.label}${if (period.live) ", so far" else ""}: solar ${PowerFormat.kWh(period.solar)}, " +
                        "grid ${PowerFormat.kWh(period.grid)}, load ${PowerFormat.kWh(period.load)}" +
                        (if (period.export > 0) ", exported ${PowerFormat.kWh(period.export)}" else "")
                },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(period.label, Modifier.weight(1f), color = color, maxLines = 1, overflow = TextOverflow.Ellipsis)
                for ((i, value) in listOfNotNull(period.solar, period.grid, period.load, if (showExport) period.export else null).withIndex()) {
                    Text(PowerFormat.kWhNumber(value), Modifier.width(58.dp), textAlign = TextAlign.End, color = color,
                        fontWeight = if (i == 2) FontWeight.SemiBold else FontWeight.Normal)
                }
            }
        }
    }
}

@Composable
private fun ListColumn(source: EnergySource) {
    Row(Modifier.width(58.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp, Alignment.End)) {
        SourceIcon(source, 12.dp)
        Text(source.title, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

// endregion
