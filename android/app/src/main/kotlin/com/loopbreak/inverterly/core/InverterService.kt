package com.loopbreak.inverterly.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.time.Instant
import java.time.ZoneId

/** The cloud account: which vendor app to pose as, and the login. Never printed. */
class InverterConfig(
    val profile: CloudProfile,
    val user: String,
    val password: String,
    /** Wi-Fi stick PN to prefer when the account has more than one device. Null picks the first. */
    val collectorPN: String? = null,
    /** Inverter serial to prefer when the account has more than one device. Null picks the first. */
    val inverterSN: String? = null,
) {
    override fun toString() = "InverterConfig(profile: ${profile.name}, account: <redacted>)"
}

/** Thrown when no account has been saved yet; the UI shows the sign-in form. */
class NoAccountError : Exception("No account is saved. Sign in first.")

/** What the UI needs from a data source. [InverterService] is the live one; a demo provider returns canned values. */
interface SnapshotProviding {
    /** The current reading. [force] skips the cache. */
    suspend fun fetchSnapshot(force: Boolean = false): EnergySnapshot

    /** Today's readings for the chart. */
    suspend fun fetchToday(): DayCurve

    /** Solar, grid and load energy for one plant day ("2026-10-13"). Null when the cloud has nothing for it. */
    suspend fun fetchDayTotals(day: String): DayTotals?

    /** The inverters on the account. Empty when the source has only the one. */
    suspend fun listDevices(): List<DeviceInfo>

    /** Make the readings be about this inverter (its serial number). */
    suspend fun selectDevice(id: String)

    /** Forget the account, session and readings so the next fetch starts from the saved account again. */
    suspend fun reset()

    /** What the cloud says about this inverter, as plain text for the raw-readings screen. */
    suspend fun fetchRaw(): String
}

/** Daily totals kept on disk, so a finished day is read from the cloud only once. */
class HistoryStore(private val file: File?) {
    internal fun load(): MutableMap<String, DayTotals> {
        val text = file?.takeIf { it.exists() }?.readText() ?: return HashMap()
        val json = Dat.parse(text).obj ?: return HashMap()
        val out = HashMap<String, DayTotals>()
        for ((key, value) in json) {
            // Keys are "<inverter serial>/<day>".
            if ("/" !in key) continue
            out[key] = DayTotals(
                day = value["day"].string ?: continue,
                solarKWh = value["solarKWh"].double ?: continue,
                gridKWh = value["gridKWh"].double ?: continue,
                loadKWh = value["loadKWh"].double ?: continue,
                complete = value["complete"].bool ?: continue,
                // Entries saved before export was estimated have no figure; skipping them reads those days again.
                exportKWh = value["exportKWh"].double ?: continue,
            )
        }
        return out
    }

    internal fun save(days: Map<String, DayTotals>) {
        file ?: return
        val json = buildJsonObject {
            for ((key, d) in days.toSortedMap()) {
                put(key, buildJsonObject {
                    put("day", d.day); put("solarKWh", d.solarKWh); put("gridKWh", d.gridKWh)
                    put("loadKWh", d.loadKWh); put("complete", d.complete); put("exportKWh", d.exportKWh)
                })
            }
        }
        // A history that cannot be saved still works for this run; it is just read again next time.
        try { writePrivately(file, json.toString()) } catch (_: Exception) { }
    }

    fun clear() { file?.delete() }

    companion object { val MemoryOnly = HistoryStore(null) }
}

/**
 * Live, READ-ONLY view of the inverter through the vendor cloud.
 *
 * The actions it sends are all queries: `webQueryDeviceEs` / `queryDevices` (find the inverter),
 * `queryDeviceLastData` (the reading), `queryDeviceWarning`, `queryPlants`, `webQueryCollectorsEs`
 * and `queryDeviceDataOneDay`. There is no control action anywhere in this app.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class InverterService(
    /** Reads the saved account; throws [NoAccountError] when there is none. */
    private val loadConfig: () -> InverterConfig,
    private val sessionStore: SessionStore = SessionStore.MemoryOnly,
    private val historyStore: HistoryStore = HistoryStore.MemoryOnly,
    private val transport: HttpTransport = UrlConnectionTransport(),
    private val now: () -> Instant = { Instant.now() },
    /**
     * How long the side lookups (warning, logger status, plant) may run on after the reading
     * itself has arrived before a snapshot is built without them.
     */
    private val sideLookupGraceMs: Long = 2500,
) : SnapshotProviding {

    private val dispatcher: CoroutineDispatcher = Dispatchers.Default.limitedParallelism(1)
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)

    private var config: InverterConfig? = null
    private var client: DessMonitorClient? = null
    /** Found once and kept for the life of the process. */
    private var device: DeviceRef? = null
    private var allDevices: List<DeviceRef> = emptyList()
    /** The inverter picked in the app; it wins over the account's own preference for this run. */
    private var chosenSN: String? = null
    private var deviceTask: Deferred<DeviceRef>? = null
    private var plant: Pair<Instant, PlantInfo>? = null
    private var plantTask: Deferred<PlantInfo?>? = null

    private var snapshotCache: Pair<Instant, EnergySnapshot>? = null
    private var snapshotTask: Deferred<EnergySnapshot>? = null
    private class CurveCache(val at: Instant, val zone: ZoneId, val value: DayCurve)
    private var curveCache: CurveCache? = null
    private var curveTask: Deferred<DayCurve>? = null
    /** Daily totals by "<serial>/<day>", read from disk on first use. */
    private var dayTotals: MutableMap<String, DayTotals>? = null
    private var historySave: Job? = null

    /** Drops everything tied to the old account; the next fetch reads the saved account again. */
    override suspend fun reset() = withContext(dispatcher) {
        config = null; client = null; device = null; allDevices = emptyList(); chosenSN = null; plant = null
        snapshotCache = null; curveCache = null; dayTotals = null
        historySave?.cancel(); historySave = null   // a sign-out has just deleted the file; do not write it back
        deviceTask?.cancel(); plantTask?.cancel(); snapshotTask?.cancel(); curveTask?.cancel()
        deviceTask = null; plantTask = null; snapshotTask = null; curveTask = null
    }

    // region Snapshot

    /**
     * One reading of the inverter. Answers from a 20 s cache unless [force] is set, and callers that
     * arrive while a fetch is running share that fetch.
     *
     * The reading itself must succeed. The plant name, the active warning and the logger status are
     * fetched alongside and simply stay null if their calls fail.
     */
    override suspend fun fetchSnapshot(force: Boolean): EnergySnapshot = withContext(dispatcher) {
        if (!force) snapshotCache?.let { (at, value) ->
            if (secondsBetween(at, now()) < SNAPSHOT_LIFETIME) return@withContext value
        }
        snapshotTask?.let { return@withContext it.await() }
        val task = scope.async { loadSnapshot() }
        snapshotTask = task
        try { task.await() } finally { if (snapshotTask === task) snapshotTask = null }
    }

    private suspend fun loadSnapshot(): EnergySnapshot {
        val client = loadClient()
        val device = loadDevice(client)
        val query = device.query

        // The reading is what the screen is waiting for. The three side lookups run alongside it
        // and get a short grace once it has landed; one that is still out by then is left out of
        // this snapshot instead of holding it up.
        val warningsTask = scope.async { tolerating { client.request("queryDeviceWarning&$query&i18n=en_US&page=0&pagesize=50") } }
        val collectorsTask = scope.async { tolerating { client.request("webQueryCollectorsEs&page=0&pagesize=50") } }
        val plantLookup = scope.async { loadPlant(client, device.plantID) }

        val reading = try {
            client.request("queryDeviceLastData&$query&i18n=en_US")
        } catch (error: Exception) {
            warningsTask.cancel(); collectorsTask.cancel(); plantLookup.cancel()
            // If the cloud no longer knows this device (re-bound stick, new device code), look it
            // up again next time instead of repeating a query that cannot work.
            if (error is DessMonitorError.Api && !error.isAuthFailure) this.device = null
            throw error
        }

        val deadline = System.nanoTime() + sideLookupGraceMs * 1_000_000
        val warnings = valueBy(warningsTask, deadline)
        val collectors = valueBy(collectorsTask, deadline)
        // A plant lookup that is late still finishes and is cached for the next reading.
        val plantInfo = valueBy(plantLookup, deadline, cancelLate = false) ?: plant?.second

        val fetchedAt = now()
        val snapshot = SnapshotParser.snapshot(reading, warnings, plantInfo, collectors, device, fetchedAt = fetchedAt)
        snapshotCache = fetchedAt to snapshot
        return snapshot
    }

    // endregion

    // region Day curve

    /** Today's logger reports (one about every 5 minutes) as chart points. Cached for 5 minutes, and dropped when the plant's day rolls over. */
    override suspend fun fetchToday(): DayCurve = withContext(dispatcher) {
        curveCache?.let {
            if (secondsBetween(it.at, now()) < DAY_CURVE_LIFETIME &&
                it.value.day == SnapshotParser.dayString(now(), it.zone)) return@withContext it.value
        }
        curveTask?.let { return@withContext it.await() }
        val task = scope.async { loadToday() }
        curveTask = task
        try { task.await() } finally { if (curveTask === task) curveTask = null }
    }

    private suspend fun loadToday(): DayCurve {
        val client = loadClient()
        val device = loadDevice(client)
        val zone = plantZone(client, device)
        val fetchedAt = now()
        val day = SnapshotParser.dayString(fetchedAt, zone)

        val curve = try {
            val dat = client.request("queryDeviceDataOneDay&${device.query}&date=$day&i18n=en_US")
            SnapshotParser.dayCurve(dat, day, zone, fetchedAt)
        } catch (error: DessMonitorError) {
            // Just after midnight there is nothing stored for the new day yet. That is an empty chart, not a failure.
            if (!error.isNoRecord) throw error
            SnapshotParser.dayCurve(JsonNull, day, zone, fetchedAt)
        }
        curveCache = CurveCache(fetchedAt, zone, curve)
        return curve
    }

    /**
     * Solar, grid and load energy for one plant day. A finished day is read once and kept on disk;
     * the day still going is read again every time.
     */
    override suspend fun fetchDayTotals(day: String): DayTotals? = withContext(dispatcher) {
        // A finished day already on disk needs no login and no device lookup, as long as the
        // inverter is known (found earlier, or picked in the app).
        (device?.sn ?: chosenSN)?.let { sn -> savedDay(sn, day)?.let { return@withContext it.value } }
        val client = loadClient()
        val device = loadDevice(client)
        savedDay(device.sn, day)?.let { return@withContext it.value }
        val key = "${device.sn}/$day"

        val zone = plantZone(client, device)
        val moment = now()
        val complete = day < SnapshotParser.dayString(moment, zone)
        val dat: JsonElement = try {
            client.request("queryDeviceDataOneDay&${device.query}&date=$day&i18n=en_US")
        } catch (error: DessMonitorError) {
            if (!error.isNoRecord) throw error
            if (complete) markEmpty(key, day)
            return@withContext null
        }
        val totals = SnapshotParser.dayTotals(dat, day, zone, complete, moment)
        if (totals == null) {
            if (complete) markEmpty(key, day)
            return@withContext null
        }
        dayTotals?.put(key, totals)
        if (complete) scheduleHistorySave()
        totals
    }

    /** A saved answer for a finished day: a box holding the totals, a box holding null for a day the cloud had nothing for, or null when it has not been read yet. */
    private class Saved(val value: DayTotals?)

    private fun savedDay(sn: String, day: String): Saved? {
        val known = dayTotals ?: historyStore.load().also { dayTotals = it }
        val key = "$sn/$day"
        known[key]?.let { if (it.complete) return Saved(it) }
        if (known["empty/$key"] != null) return Saved(null)
        return null
    }

    /** Remembers on disk that a finished day has no reports, so it is not asked for again on every launch. */
    private fun markEmpty(key: String, day: String) {
        dayTotals?.put("empty/$key", DayTotals(day, 0.0, 0.0, 0.0, true))
        scheduleHistorySave()
    }

    /** Writes the finished days to disk once a burst of reads has settled, not after every day. */
    private fun scheduleHistorySave() {
        if (historySave != null) return
        historySave = scope.launch {
            delay(1000)   // cancelled by a reset
            historySave = null
            historyStore.save((dayTotals ?: emptyMap()).filterValues { it.complete })
        }
    }

    // endregion

    // region Raw readings

    /**
     * Everything the cloud reports for the inverter that might hold a figure the app does not use
     * yet (a grid or feed-in power, say): the live rows, the vendor's flow summary and the columns
     * of today's history with their latest values. Each part that fails says so instead of failing
     * the rest. The serial number and logger PN are replaced, so the text is safe to send on.
     */
    override suspend fun fetchRaw(): String = withContext(dispatcher) {
        val client = loadClient()
        val device = loadDevice(client)
        val query = device.query
        val zone = plantZone(client, device)
        val day = SnapshotParser.dayString(now(), zone)
        val out = StringBuilder()
        out.appendLine("Inverterly raw readings, ${now()}")
        out.appendLine("Device code ${device.devcode}, address ${device.devaddr}")

        suspend fun section(title: String, action: String, render: (JsonElement) -> String) {
            out.appendLine().appendLine("== $title ==")
            try {
                out.appendLine(render(client.request(action)))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                out.appendLine("(${e.message})")
            }
        }
        section("Live rows (queryDeviceLastData)", "queryDeviceLastData&$query&i18n=en_US") { dat ->
            SnapshotParser.tableRows(dat).joinToString("\n") { row ->
                "${row.title} = ${row.value.string ?: ""}${if (row.unit.isNotEmpty()) " " + row.unit else ""}"
            }.ifEmpty { prettyJson.encodeToString(JsonElement.serializer(), dat) }
        }
        section("Flow summary (webQueryDeviceEnergyFlowEs)", "webQueryDeviceEnergyFlowEs&$query") { dat ->
            prettyJson.encodeToString(JsonElement.serializer(), dat)
        }
        section("Today's columns, latest report (queryDeviceDataOneDay)", "queryDeviceDataOneDay&$query&date=$day&i18n=en_US") { dat ->
            val titles = (dat["title"].array ?: emptyList()).map { it["title"].string ?: it.string ?: "?" }
            val last = dat["row"].array?.lastOrNull()
            val fields = (last["field"].array ?: last.array ?: emptyList()).map { it.string ?: "" }
            if (titles.isEmpty()) "(no columns)" else titles.indices.joinToString("\n") { i -> "${titles[i]} = ${fields.getOrNull(i) ?: ""}" }
        }
        out.toString().replace(device.sn, "<serial>").replace(device.pn, "<logger>")
    }

    // endregion

    // region Inverters

    /** The inverters on the account, by the name given in the phone app, else by what each one says it is. */
    override suspend fun listDevices(): List<DeviceInfo> = withContext(dispatcher) {
        val client = loadClient()
        val current = loadDevice(client)
        tolerating { client.request(FULL_DEVICE_LIST) }?.let { listing ->
            allDevices = SnapshotParser.allDevices(listing).filter { it.isQueryable }
        }
        val found = allDevices.ifEmpty { listOf(current) }
        val types = found.filter { it.alias.isEmpty() }.map { ref ->
            scope.async {
                val reading = tolerating { client.request("queryDeviceLastData&${ref.query}&i18n=en_US") }
                val type = reading?.let { runCatching { SnapshotParser.snapshot(it, device = ref).machineType }.getOrNull() }
                ref.sn to type
            }
        }.awaitAll().mapNotNull { (sn, type) -> type?.let { sn to it } }.toMap()
        val names = found.mapIndexed { index, ref ->
            ref.alias.ifEmpty { types[ref.sn] ?: "Inverter ${index + 1}" }
        }.toMutableList()
        // Two of the same kind would be told apart by position.
        for (index in names.indices) {
            if (names.count { it == names[index] } > 1) names[index] = "${names[index]} ${index + 1}"
        }
        found.zip(names).map { (ref, name) -> DeviceInfo(ref.sn, name, ref.sn == current.sn) }
    }

    /** Switches the readings to another inverter. What was read for the last one is dropped. */
    override suspend fun selectDevice(id: String) = withContext(dispatcher) {
        if (id == device?.sn) { chosenSN = id; return@withContext }
        chosenSN = id
        device = allDevices.firstOrNull { it.sn == id }   // null makes the next fetch look it up again
        snapshotTask?.cancel(); curveTask?.cancel()
        snapshotCache = null; snapshotTask = null; curveCache = null; curveTask = null
    }

    // endregion

    // region Shared lookups

    /** The plant's time zone, waiting a short while for the plant lookup. */
    private suspend fun plantZone(client: DessMonitorClient, device: DeviceRef): ZoneId {
        val lookup = scope.async { loadPlant(client, device.plantID) }
        val deadline = System.nanoTime() + sideLookupGraceMs * 1_000_000
        val info = valueBy(lookup, deadline, cancelLate = false) ?: plant?.second
        return info?.timeZone ?: device.timeZone ?: ZoneId.systemDefault()
    }

    private fun loadClient(): DessMonitorClient {
        client?.let { return it }
        val config = this.config ?: loadConfig()
        this.config = config
        return DessMonitorClient(config.profile, config.user, config.password, sessionStore, transport, now)
            .also { client = it }
    }

    /** The inverter to ask about. Found once per process; the snapshot and the day curve share the lookup when they start together. */
    private suspend fun loadDevice(client: DessMonitorClient): DeviceRef {
        device?.let { return it }
        deviceTask?.let { return it.await() }
        val task = scope.async { discoverDevice(client) }
        deviceTask = task
        try { return task.await() } finally { if (deviceTask === task) deviceTask = null }
    }

    /** `webQueryDeviceEs` first, `queryDevices` if that fails, as in the Node client. */
    private suspend fun discoverDevice(client: DessMonitorClient): DeviceRef {
        val listing: JsonElement = try {
            // The plain request (as the Node client sends it) lists only the first inverter. A
            // specific one is asked for with a page size, which lists them all.
            val specific = chosenSN != null || config?.inverterSN != null || config?.collectorPN != null
            client.request(if (specific) FULL_DEVICE_LIST else "webQueryDeviceEs")
        } catch (first: DessMonitorError) {
            if (!secondListMayHelp(first)) throw first
            runCatching { client.request("queryDevices&page=0&pagesize=50&i18n=en_US") }.getOrNull() ?: throw first
        }
        val wantedSN = chosenSN ?: config?.inverterSN
        val found = SnapshotParser.pickDevice(listing, if (chosenSN == null) config?.collectorPN else null, wantedSN)
        if (found == null || !found.isQueryable) throw InverterDataError.NoDevice
        device = found
        return found
    }

    /**
     * The Node client tries the second list after any failure. Here it is skipped when it cannot
     * succeed either (no connection, login refused), so the real error reaches the user at once.
     */
    private fun secondListMayHelp(error: DessMonitorError): Boolean = when (error) {
        is DessMonitorError.Api -> !error.isAuthFailure
        is DessMonitorError.BadResponse, DessMonitorError.TimedOut, is DessMonitorError.Network -> true
        else -> false
    }

    /** The plant gives the display name and the time zone the logger's timestamps are in. It rarely changes, so it is asked for at most once an hour. */
    private suspend fun loadPlant(client: DessMonitorClient, preferID: Int?): PlantInfo? {
        plant?.let { if (secondsBetween(it.first, now()) < PLANT_LIFETIME) return it.second }
        plantTask?.let { return it.await() }
        val task = scope.async { refreshPlant(client, preferID) }
        plantTask = task
        try { return task.await() } finally { if (plantTask === task) plantTask = null }
    }

    private suspend fun refreshPlant(client: DessMonitorClient, preferID: Int?): PlantInfo? {
        val dat = tolerating { client.request("queryPlants&page=0&pagesize=20&i18n=en_US") }
        val info = SnapshotParser.plant(dat, preferID) ?: return plant?.second
        plant = now() to info
        return info
    }

    /** Runs a side lookup whose failure must not fail the reading. */
    private suspend fun <T> tolerating(operation: suspend () -> T): T? = try {
        operation()
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

    /** The task's value if it is ready by [deadline] (a System.nanoTime value), otherwise null, without waiting any longer. */
    private suspend fun <T> valueBy(task: Deferred<T?>, deadline: Long, cancelLate: Boolean = true): T? {
        // withTimeoutOrNull(0) gives up without looking, so a task that has already finished is read directly.
        if (task.isCompleted && !task.isCancelled) return task.getCompleted()
        val remainingMs = ((deadline - System.nanoTime()) / 1_000_000).coerceAtLeast(1)
        val value = withTimeoutOrNull(remainingMs) { task.await() }
        if (value == null && cancelLate && !task.isCompleted) task.cancel()
        return value
    }

    // endregion

    private val prettyJson = kotlinx.serialization.json.Json { prettyPrint = true }

    companion object {
        /** The logger only reports about every 5 minutes, so asking more often than this buys nothing. */
        const val SNAPSHOT_LIFETIME = 20.0
        const val DAY_CURVE_LIFETIME = 5 * 60.0
        const val PLANT_LIFETIME = 60 * 60.0
        private const val FULL_DEVICE_LIST = "webQueryDeviceEs&page=0&pagesize=50&i18n=en_US"
    }
}
