package com.loopbreak.inverterly

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.loopbreak.inverterly.core.AccountStore
import com.loopbreak.inverterly.core.CloudProfile
import com.loopbreak.inverterly.core.DayCurve
import com.loopbreak.inverterly.core.DayTotals
import com.loopbreak.inverterly.core.DessMonitorError
import com.loopbreak.inverterly.core.DeviceInfo
import com.loopbreak.inverterly.core.EnergySnapshot
import com.loopbreak.inverterly.core.HistoryStore
import com.loopbreak.inverterly.core.InverterService
import com.loopbreak.inverterly.core.MonthTotals
import com.loopbreak.inverterly.core.NoAccountError
import com.loopbreak.inverterly.core.SessionStore
import com.loopbreak.inverterly.core.SnapshotProviding
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Which list the History tab shows. */
enum class HistoryTab(val title: String) { Days("Days"), Months("Months") }

/**
 * Holds the latest reading and polls the provider while the app is in front. The state is Compose
 * state, so screens read it directly and redraw when it changes.
 */
class AppStore(
    application: Application,
    private val provider: SnapshotProviding,
    private val account: AccountStore,
    private val history: HistoryStore,
    private val sessions: SessionStore,
) : AndroidViewModel(application) {

    var snapshot by mutableStateOf<EnergySnapshot?>(null); private set
    var errorMessage by mutableStateOf<String?>(null); private set
    var busy by mutableStateOf(false); private set
    /** True when no account is saved, or the cloud refused the login. */
    var signInRequired by mutableStateOf(false); private set
    var signInError by mutableStateOf<String?>(null); private set
    var today by mutableStateOf<DayCurve?>(null); private set
    var todayLoading by mutableStateOf(false); private set
    var todayError by mutableStateOf<String?>(null); private set
    /** Daily totals read so far, by day ("2026-10-13"). */
    var days by mutableStateOf<Map<String, DayTotals>>(emptyMap()); private set
    var historyLoading by mutableStateOf(false); private set
    var historyError by mutableStateOf<String?>(null); private set
    /** The inverters on the account; more than one means the settings offer a switcher. */
    var devices by mutableStateOf<List<DeviceInfo>>(emptyList()); private set
    /** Ticks while the app is in front so "stale" is re-judged without a new reading. */
    var clock by mutableStateOf(Instant.now()); private set

    var showDetails by mutableStateOf(false)
    var historyTab by mutableStateOf(HistoryTab.Days); private set
    /** True while the app is in front: it drives the faster polling and the hero's animation. */
    var panelOpen by mutableStateOf(false); private set

    /** Whether the account stays signed in from one launch to the next. */
    var rememberMe by mutableStateOf(account.remember); private set

    fun rememberMe(value: Boolean) {
        account.remember = value
        rememberMe = value
    }

    val username: String? get() = account.user

    private var pollJob: Job? = null
    private var lastAttempt = Instant.EPOCH
    private var consecutiveFailures = 0
    private var todayFetchedAt = Instant.EPOCH
    /** When each tab last read its months: Days reads only this one, Months reads back from it. */
    private val historyFetchedAt = HashMap<HistoryTab, Instant>()
    /** Bumped whenever the readings are cleared, so a history load started before that is dropped. */
    private var historyGeneration = 0
    private val prefs = application.getSharedPreferences("app", 0)

    fun start() {
        if (pollJob != null) return
        val savedDevice = prefs.getString(KEY_DEVICE, null)
        pollJob = viewModelScope.launch {
            // Without "Remember me" the last launch's account is dropped before anything is read.
            if (!account.remember) signOut()
            savedDevice?.let { if (account.remember) provider.selectDevice(it) }
            while (true) {
                refresh(force = false)
                // Sleep in short steps so that going to the background or coming back changes the
                // cadence straight away instead of after the current wait.
                while (secondsSince(lastAttempt) < pollInterval) {
                    delay(5_000)
                    clock = Instant.now()
                }
            }
        }
    }

    /**
     * The logger reports to the cloud about every five minutes, so polling faster buys nothing.
     * After a failure the next try comes sooner once, then the normal cadence resumes.
     */
    private val pollInterval: Double
        get() = if (consecutiveFailures == 1) 15.0 else if (panelOpen) 60.0 else 150.0

    fun onForeground(open: Boolean) {
        val opened = open && !panelOpen
        panelOpen = open
        if (opened) viewModelScope.launch {
            if (secondsSince(lastAttempt) > 30) refresh(force = false)
            if (today != null) loadToday()
            if (days.isNotEmpty()) loadHistory()
        }
    }

    suspend fun refresh(force: Boolean) {
        if (busy) return
        busy = true
        lastAttempt = Instant.now()
        try {
            val reading = provider.fetchSnapshot(force)
            snapshot = reading
            errorMessage = null
            signInRequired = false
            consecutiveFailures = 0
            if (devices.isEmpty()) viewModelScope.launch { loadDevices() }
            if (panelOpen && today != null) loadToday()
        } catch (e: CancellationException) {
            // Dropped (another inverter was picked, or the account changed): try again at the next poll, not in a minute.
            lastAttempt = Instant.EPOCH
            throw e
        } catch (e: Exception) {
            errorMessage = describe(e)
            signInRequired = needsSignIn(e)
            consecutiveFailures += 1
        } finally {
            busy = false
            clock = Instant.now()
        }
    }

    /** Saves the account, then reads the inverter with it, trying each app profile. A failure is left in [signInError]. */
    suspend fun signIn(user: String, password: String) {
        signInError = null
        // The three phone apps share one login but sign it with different app identities, and the
        // cloud answers a wrong identity the same way as a wrong password. So try each in turn; the
        // first one the cloud accepts is saved. Only a refused login moves on to the next.
        for (profile in CloudProfile.All) {
            try {
                account.save(profile, user, password)
            } catch (e: Exception) {
                signInError = "Could not save the account: ${e.message}"
                return
            }
            provider.reset()
            sessions.clear()
            snapshot = null
            waitUntilIdle()
            refresh(force = true)
            if (snapshot != null || !signInRequired) break
        }
        if (signInRequired || snapshot == null) signInError = errorMessage ?: "Could not read the inverter."
    }

    /** A refresh already running would land after a reset; let it finish first. */
    private suspend fun waitUntilIdle() { while (busy) delay(100) }

    /** Drops everything read for the current inverter. */
    private fun clearReadings() {
        snapshot = null; errorMessage = null
        today = null; todayError = null; todayFetchedAt = Instant.EPOCH
        days = emptyMap(); historyError = null; historyFetchedAt.clear()
        historyGeneration += 1
    }

    // region Inverters

    /** The name of the inverter shown, when the account has more than one. */
    val selectedDeviceName: String?
        get() = if (devices.size > 1) devices.firstOrNull { it.isSelected }?.name else null

    private suspend fun loadDevices() {
        val found = try { provider.listDevices() } catch (e: CancellationException) { throw e } catch (_: Exception) { return }
        if (found.isEmpty()) return
        devices = found
        // Remembered so that on the next launch the saved history shows before the cloud answers.
        found.firstOrNull { it.isSelected }?.let { prefs.edit().putString(KEY_DEVICE, it.id).apply() }
    }

    /** Shows another inverter. Its reading, chart and history replace the last one's. */
    suspend fun selectDevice(id: String) {
        if (devices.none { it.id == id } || devices.any { it.id == id && it.isSelected }) return
        prefs.edit().putString(KEY_DEVICE, id).apply()
        devices = devices.map { it.copy(isSelected = it.id == id) }
        provider.selectDevice(id)
        waitUntilIdle()
        clearReadings()
        refresh(force = true)
        loadToday(force = true)
        loadHistory(force = true)
    }

    /** Forgets the account and its session and goes back to the sign-in form. */
    suspend fun signOut() {
        account.clear()
        sessions.clear()
        history.clear()
        provider.reset()
        waitUntilIdle()
        clearReadings()
        devices = emptyList()
        prefs.edit().remove(KEY_DEVICE).apply()
        signInError = null
        signInRequired = true
    }

    private fun needsSignIn(error: Exception) =
        error is NoAccountError || error is DessMonitorError.MissingCredentials || error is DessMonitorError.LoginRejected

    // endregion

    // region Today

    suspend fun loadToday(force: Boolean = false) {
        if (todayLoading || !(force || today == null || secondsSince(todayFetchedAt) > 300)) return
        todayLoading = true
        try {
            today = provider.fetchToday()
            todayFetchedAt = Instant.now()
            todayError = null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            todayError = describe(e)
        } finally {
            todayLoading = false
        }
    }

    // endregion

    // region History

    private val zone: ZoneId get() = ZoneId.systemDefault()

    /** The days of the current month that have been read, newest first. */
    val currentMonthDays: List<DayTotals>
        get() {
            val month = LocalDate.now(zone).toString().take(7)
            return days.values.filter { it.day.startsWith(month) }.sortedByDescending { it.day }
        }

    /** Every month that has been read, newest first. */
    val months: List<MonthTotals> get() = MonthTotals.monthly(days.values)

    fun selectHistoryTab(tab: HistoryTab) {
        if (tab == historyTab) return
        historyTab = tab
        viewModelScope.launch { loadHistory() }
    }

    /**
     * Reads the days of this month, and for the Months tab the months before it, until one has
     * nothing. Finished days come from disk after the first time; only today is read again.
     */
    suspend fun loadHistory(force: Boolean = false) {
        if (historyLoading) {
            if (!force) return
            // A forced load (after switching inverter) must not be dropped: let the running one end first.
            while (historyLoading) delay(100)
        }
        // Nothing on screen is always worth a read: the saved days cost no network.
        val tab = historyTab
        val last = historyFetchedAt[tab] ?: Instant.EPOCH
        if (!(force || currentMonthDays.isEmpty() || secondsSince(last) > 300)) return
        val generation = historyGeneration
        historyLoading = true
        historyError = null
        try {
            val today = LocalDate.now(zone)
            val month = today.withDayOfMonth(1)
            val list = daysOf(month, today)
            if (list.isNotEmpty()) {
                // Finished days come from disk at once; today needs the cloud, so it follows on its own.
                readDays(list.dropLast(1), generation)
                readDays(listOf(list.last()), generation)
            }
            if (tab == HistoryTab.Months && generation == historyGeneration) {
                readMonths((1 until 24).map { daysOf(month.minusMonths(it.toLong()), today) }, generation)
            }
        } finally {
            historyLoading = false
            if (generation == historyGeneration) historyFetchedAt[tab] = Instant.now()
        }
    }

    private fun daysOf(month: LocalDate, today: LocalDate): List<String> =
        (0 until month.lengthOfMonth()).map { month.plusDays(it.toLong()) }.filter { !it.isAfter(today) }.map { it.toString() }

    /**
     * Reads these days, three at a time, and publishes them together (one update, not one per day).
     * True if any of them has data.
     */
    private suspend fun readDays(wanted: List<String>, generation: Int): Boolean {
        var failure: Exception? = null
        val read = coroutineScope { fetchDays(wanted, Semaphore(3)) { failure = it } }.await()
        // Readings were cleared (another inverter, a sign-out) while these were out: they are stale.
        if (generation != historyGeneration) return false
        if (read.isNotEmpty()) days = days + read
        failure?.let { historyError = describe(it) }
        return wanted.any { days[it] != null }
    }

    /**
     * Reads earlier months, newest first, until one has nothing. Three days stay in flight across
     * month boundaries (a month no longer waits for the last day of the one before; the gate hands
     * out its permits in order), and each month is published once all of it is in.
     */
    private suspend fun readMonths(months: List<List<String>>, generation: Int) = coroutineScope {
        val gate = Semaphore(3)
        var failure: Exception? = null
        val reads = months.map { fetchDays(it, gate) { e -> failure = e } }
        for ((index, read) in reads.withIndex()) {
            val result = read.await()
            if (generation != historyGeneration) break
            if (result.isNotEmpty()) days = days + result
            failure?.let { historyError = describe(it) }
            if (months[index].none { days[it] != null }) break
        }
        reads.forEach { it.cancel() }
    }

    /** Starts reading the days not already complete; the result holds those that had data. */
    private fun CoroutineScope.fetchDays(wanted: List<String>, gate: Semaphore, onFailure: (Exception) -> Unit): Deferred<Map<String, DayTotals>> {
        val reads = wanted.filter { days[it]?.complete != true }.map { day ->
            async {
                gate.withPermit {
                    try {
                        provider.fetchDayTotals(day)?.let { day to it }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        onFailure(e)
                        null
                    }
                }
            }
        }
        return async { reads.awaitAll().filterNotNull().toMap() }
    }

    // endregion

    /** The raw cloud readings for the current inverter, or the reason they could not be read. */
    suspend fun rawReadings(): String = try {
        provider.fetchRaw()
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        describe(e)
    }

    // region State helpers

    /**
     * True when there is no reading, or the last one is too old to present as current: the logger
     * has been silent for 15 minutes, or nothing has been fetched for 10.
     */
    val readingIsStale: Boolean
        get() {
            val s = snapshot ?: return true
            return s.isStale(now = clock) || secondsBetween(s.fetchedAt, clock) > 600
        }

    private fun secondsSince(time: Instant) = (Instant.now().toEpochMilli() - time.toEpochMilli()) / 1000.0
    private fun secondsBetween(a: Instant, b: Instant) = (b.toEpochMilli() - a.toEpochMilli()) / 1000.0

    private fun describe(error: Exception): String = when (error) {
        is NoAccountError -> "Sign in to read your inverter."
        else -> error.message?.takeIf { it.isNotBlank() } ?: "Could not read the inverter."
    }

    // endregion

    class Factory(private val application: Application, private val demo: Boolean, private val slow: Boolean = false) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            val account = AccountStore(application)
            val dir = File(application.filesDir, "inverterly")
            val sessions = SessionStore(File(dir, "session.json"))
            val history = HistoryStore(File(dir, "history.json"))
            val provider: SnapshotProviding =
                if (demo) DemoProvider(slow) else InverterService(account::load, sessions, history)
            return AppStore(application, provider, account, history, sessions) as T
        }
    }

    private companion object {
        const val KEY_DEVICE = "inverterSN"
    }
}
