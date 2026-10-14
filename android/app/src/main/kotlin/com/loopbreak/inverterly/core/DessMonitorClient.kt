package com.loopbreak.inverterly.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import java.security.MessageDigest
import java.time.Instant
import kotlin.math.min
import kotlin.math.pow

// READ-ONLY CLIENT. The Node client's device-control call and its two control-field queries are
// deliberately not ported: nothing here can change an inverter setting.
//
// That is enforced twice. At run time, `DessMonitorClient` signs only the actions listed in
// `DessReadOnly.actions` and refuses everything else before anything is sent. At test time,
// ReadOnlyGuardTest fails if a control action name ever appears in the sources.

// region Profiles

/**
 * Which vendor app the client pretends to be. Same three app identities as the Node client; the
 * company key is the vendor app's public key, not an account secret.
 */
data class CloudProfile(
    val name: String,
    val appID: String,
    val appVersion: String,
    val companyKey: String,
    val baseURL: String,
    val source: Int = 1,
    val appClient: String = "android",
    val locale: String = "en_US",
) {
    companion object {
        val Watchpower = CloudProfile("watchpower", "wifiapp.volfw.watchpower", "1.0.6.3",
            "bnrl_frRFjEz8Mkn", "https://web.dessmonitor.com/public/")
        val Solarpower = CloudProfile("solarpower", "com.voltronicpower.solarpower", "1.0.6.3",
            "bnrl_frRFjEz8Mkn", "http://android.shinemonitor.com/public/")

        /** The SolarPower / WatchPower 1.4 phone app talks to DessMonitor. */
        val Dessmonitor = CloudProfile("dessmonitor", "wifiapp.volfw.watchpower", "1.4.6.1",
            "bnrl_frRFjEz8Mkn", "https://web.dessmonitor.com/public/")

        val All = listOf(Watchpower, Solarpower, Dessmonitor)

        /** Unknown or missing names fall back to watchpower, the same default as the Node client. */
        fun named(name: String?): CloudProfile = All.firstOrNull { it.name == name?.lowercase() } ?: Watchpower
    }
}

// endregion

// region Errors

sealed class DessMonitorError(message: String) : Exception(message) {
    /** No usable session and no username or password to make one. */
    object MissingCredentials : DessMonitorError("No account is saved. Sign in first.")

    /** The vendor refused the login (wrong password, unknown user, locked account). */
    class LoginRejected(val code: Int, val desc: String) :
        DessMonitorError("The inverter cloud refused the login (${desc.ifEmpty { "error $code" }}).")

    /** The vendor answered a signed request with a non-zero `err`. */
    class Api(val action: String, val code: Int, val desc: String) :
        DessMonitorError("The inverter cloud answered $action with ${desc.ifEmpty { "error $code" }}.")

    object TimedOut : DessMonitorError("The inverter cloud did not answer in time.")
    object Offline : DessMonitorError("No connection to the inverter cloud.")
    class Network(val detail: String) : DessMonitorError("Could not reach the inverter cloud: $detail")

    /** The answer was not the JSON envelope the API always sends. */
    class BadResponse(val action: String, val status: Int) :
        DessMonitorError("The inverter cloud sent an unreadable answer to $action (HTTP $status).")

    class InvalidRequest(val action: String) : DessMonitorError("Could not build the request for $action.")

    /** The action is not one of the read-only queries this app sends. Nothing was sent. */
    class ActionNotAllowed(val action: String) :
        DessMonitorError("Inverterly only reads from the inverter. It does not send $action.")

    /**
     * The session is no longer accepted: `ERR_NO_AUTH` (0x000A) or `ERR_SIGN` (0x0004). Numbers from
     * the vendor's error table. `ERR_NO_PERMISSION` (0x000B) is deliberately not one: a new login
     * cannot grant a permission.
     */
    val isAuthFailure: Boolean
        get() {
            if (this !is Api) return false
            if (code == 4 || code == 10) return true
            val upper = desc.uppercase()
            return "NO_AUTH" in upper || "ERR_SIGN" in upper || "TOKEN" in upper
        }

    /** `ERR_NO_RECORD` (0x000C): the query is fine, there is just nothing stored for it yet. */
    val isNoRecord: Boolean
        get() = this is Api && (code == 12 || "NO_RECORD" in desc.uppercase())
}

sealed class InverterDataError(message: String) : Exception(message) {
    /** The login works but no inverter is bound to the account. */
    object NoDevice : InverterDataError("The account has no inverter bound to it yet.")

    /** The cloud answered, but with nothing that reads as a live value. */
    object NoReadings : InverterDataError("The inverter cloud returned no readings.")

    class MissingColumn(val column: String) : InverterDataError("The day history has no \"$column\" column.")
}

// endregion

// region Read-only allow-list

/** The gate every data request passes before it is signed. */
object DessReadOnly {
    /**
     * Every action this app may send. Each one only reads. Adding a name here is a deliberate act
     * that ReadOnlyGuardTest has to be changed to accept.
     */
    val actions: Set<String> = setOf(
        "webQueryDeviceEs", "queryDevices", "queryDeviceLastData", "queryDeviceWarning",
        "queryPlants", "webQueryCollectorsEs", "queryDeviceDataOneDay",
    )

    /** Parameters the client adds itself. An action string must not bring its own, above all not a second `action`. */
    private val reserved = setOf("action", "sign", "salt", "token")

    /**
     * Throws unless [action] is one allow-listed query followed by plain `key=value` parameters.
     * [action] is the action name plus its parameters, e.g. `queryPlants&page=0&pagesize=20`.
     */
    fun check(action: String) {
        val parts = action.split("&")
        val name = parts.first()
        if (name !in actions) throw DessMonitorError.ActionNotAllowed(printable(name))
        for (part in parts.drop(1)) {
            val eq = part.indexOf('=')
            if (eq <= 0) throw DessMonitorError.InvalidRequest(name)
            val key = part.substring(0, eq)
            val value = part.substring(eq + 1)
            if (!key.all(::isKeyChar)) throw DessMonitorError.InvalidRequest(name)
            if (key.lowercase() in reserved) throw DessMonitorError.ActionNotAllowed(printable(name))
            // Serial numbers, dates and locale codes. Nothing that needs escaping, so the string
            // that is signed is byte for byte the string that is sent.
            if (!value.all { isKeyChar(it) || it == '-' || it == '.' || it == ':' }) throw DessMonitorError.InvalidRequest(name)
        }
    }

    private fun isKeyChar(c: Char) = c in '0'..'9' || c in 'A'..'Z' || c in 'a'..'z' || c == '_'

    /** A refused name is shown in an error, so only letters and digits of it are kept. */
    internal fun printable(name: String): String =
        name.filter(::isKeyChar).take(40).ifEmpty { "(unnamed)" }
}

// endregion

// region Signing

/**
 * The vendor's request signing, ported byte for byte from `lib/shinemonitor.js`.
 *
 * Two rules matter and are easy to get wrong:
 * - Login signs the raw username with spaces escaped as `%20`, and sends it `encodeURIComponent`-encoded.
 * - A signed request signs `&action=...` exactly as it is sent, and does not append the app suffix.
 */
object DessSigning {
    /** Lowercase hex SHA-1 of the UTF-8 bytes. SHA-1 is what the vendor API requires. */
    fun sha1Hex(text: String): String = hex(MessageDigest.getInstance("SHA-1").digest(text.toByteArray()))

    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it.toInt() and 0xFF) }

    private const val UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"

    /** JavaScript's `encodeURIComponent`: everything except `A-Z a-z 0-9 - _ . ! ~ * ' ( )` is percent-encoded as UTF-8. */
    fun encodeURIComponent(text: String): String {
        val out = StringBuilder()
        for (byte in text.toByteArray()) {
            val c = (byte.toInt() and 0xFF).toChar()
            if (c.code < 128 && c in UNRESERVED) out.append(c) else out.append("%%%02X".format(byte.toInt() and 0xFF))
        }
        return out.toString()
    }

    /** `String(Date.now())`: whole milliseconds since 1970. */
    fun salt(at: Instant): String = at.toEpochMilli().toString()

    /** The app identification appended to the login action (and only to the login action). */
    fun suffix(p: CloudProfile) =
        "&source=${p.source}&_app_client_=${p.appClient}&_app_id_=${p.appID}&_app_version_=${p.appVersion}&lang=${p.locale}"

    fun loginSign(profile: CloudProfile, username: String, password: String, salt: String): String {
        // The cloud keeps spaces escaped when verifying login; other characters stay raw.
        val signedUser = username.replace(" ", "%20")
        val raw = "&action=authSource&usr=$signedUser&company-key=${profile.companyKey}" + suffix(profile)
        return sha1Hex(salt + sha1Hex(password) + raw)
    }

    fun loginURL(profile: CloudProfile, username: String, password: String, salt: String): String {
        val action = "&action=authSource&usr=${encodeURIComponent(username)}&company-key=${profile.companyKey}" + suffix(profile)
        return "${profile.baseURL}?sign=${loginSign(profile, username, password, salt)}&salt=$salt$action"
    }

    /** [action] is the action name plus its parameters, e.g. `queryPlants&page=0&pagesize=20`. */
    fun requestSign(secret: String, token: String, action: String, salt: String) =
        sha1Hex(salt + secret + token + "&action=$action")

    fun requestURL(profile: CloudProfile, secret: String, token: String, action: String, salt: String): String =
        "${profile.baseURL}?sign=${requestSign(secret, token, action, salt)}&salt=$salt&token=$token&action=$action"
}

// endregion

// region Transport

/** One HTTP GET. An interface so the client can be exercised in tests without the network. */
interface HttpTransport {
    suspend fun get(url: String): Pair<Int, String>
}

/** A plain connection with no cookies and no cache, and a 20 s timeout. */
class UrlConnectionTransport(private val timeoutMs: Int = 20_000) : HttpTransport {
    override suspend fun get(url: String): Pair<Int, String> = withContext(Dispatchers.IO) {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = timeoutMs
            connection.readTimeout = timeoutMs
            connection.useCaches = false
            connection.requestMethod = "GET"
            val status = connection.responseCode
            val stream = if (status >= 400) connection.errorStream else connection.inputStream
            status to (stream?.bufferedReader()?.use { it.readText() } ?: "")
        } finally {
            connection.disconnect()
        }
    }
}

// endregion

// region Session

/** What a login returns, kept between launches so the app does not log in every time. */
internal data class DessSession(
    val profile: String,
    val baseURL: String,
    val secret: String,
    val token: String,
    /** Milliseconds since 1970, like the Node client's `expireAt`. */
    val expireAt: Double,
    /** Fingerprint of profile + username, so a saved session is never used for another account. */
    val account: String,
    /** Milliseconds since 1970 when this login happened. */
    val createdAt: Double,
) {
    /** Valid until one minute before the vendor's expiry, as in the Node client. */
    fun isUsable(profile: CloudProfile, account: String, at: Instant): Boolean =
        this.profile == profile.name && baseURL == profile.baseURL && this.account == account &&
            secret.isNotEmpty() && token.isNotEmpty() && at.toEpochMilli() <= expireAt - 60_000

    // The session holds the secret and token; never let either reach a log through toString.
    override fun toString() = "DessSession(profile: $profile, secret: <redacted>, token: <redacted>)"

    companion object {
        fun fingerprint(profile: CloudProfile, user: String): String {
            val digest = MessageDigest.getInstance("SHA-256").digest("${profile.name}\n$user".toByteArray())
            return digest.take(8).joinToString("") { "%02x".format(it.toInt() and 0xFF) }
        }
    }
}

/** Where the session is kept: a private file in the app's own storage. Null keeps it in memory only. */
class SessionStore(private val file: File?) {
    internal fun load(): DessSession? {
        val text = file?.takeIf { it.exists() }?.readText() ?: return null
        val json = Dat.parse(text) ?: return null
        return DessSession(
            profile = json["profile"].string ?: return null,
            baseURL = json["base_url"].string ?: return null,
            secret = json["secret"].string ?: return null,
            token = json["token"].string ?: return null,
            expireAt = json["expireAt"].double ?: return null,
            account = json["account"].string ?: return null,
            createdAt = json["createdAt"].double ?: return null,
        )
    }

    internal fun save(session: DessSession) {
        val json = buildJsonObject {
            put("profile", session.profile); put("base_url", session.baseURL)
            put("secret", session.secret); put("token", session.token)
            put("expireAt", session.expireAt); put("account", session.account); put("createdAt", session.createdAt)
        }
        writePrivately(file ?: return, json.toString())
    }

    fun clear() { file?.delete() }

    companion object { val MemoryOnly = SessionStore(null) }
}

/** Writes through a temporary file and renames it, so a crash cannot leave half a file. App storage is private to the app. */
internal fun writePrivately(file: File, text: String) {
    file.parentFile?.mkdirs()
    val temporary = File(file.parentFile, ".${file.name}.tmp")
    temporary.writeText(text)
    if (!temporary.renameTo(file)) {
        file.delete()
        if (!temporary.renameTo(file)) { temporary.delete(); throw java.io.IOException("Could not write ${file.name}") }
    }
}

// endregion

// region Client

/**
 * Signed, read-only access to the DessMonitor / ShineMonitor cloud.
 *
 * All state lives on one single-threaded dispatcher, so it behaves like the iOS actor: several
 * requests running at once share one login, and if the saved session has been revoked the first
 * failure logs in again while the others wait for that login.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class DessMonitorClient(
    val profile: CloudProfile,
    private val user: String,
    private val password: String,
    private val store: SessionStore = SessionStore.MemoryOnly,
    private val transport: HttpTransport = UrlConnectionTransport(),
    private val now: () -> Instant = { Instant.now() },
) {
    private val dispatcher: CoroutineDispatcher = Dispatchers.Default.limitedParallelism(1)
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val account = DessSession.fingerprint(profile, user)

    private var session: DessSession? = null
    /** Goes up with every login; lets a failed request tell whether someone already renewed. */
    private var sessionSerial = 0
    private var loginTask: Deferred<DessSession>? = null

    private class Refusal(val until: Instant, val error: DessMonitorError, val count: Int)
    /**
     * After the vendor refuses the credentials, do not ask again for a while: a minute at first,
     * then twice as long after each further refusal, up to 32 minutes. An app that polls would
     * otherwise send a wrong password every minute all day, which is how accounts get frozen.
     */
    private var loginRefusal: Refusal? = null

    private class ActionRefusal(val count: Int, val retryAfter: Instant)
    /** Actions the cloud refused even on a brand-new session, by action name. */
    private val refusals = HashMap<String, ActionRefusal>()

    /**
     * Sends one signed read request and returns its `dat`. [action] is the action name plus its
     * parameters, e.g. `queryPlants&page=0&pagesize=20&i18n=en_US`.
     *
     * If a session that was already in hand is refused, this logs in again once and retries once.
     * Only the queries in [DessReadOnly.actions] are accepted; anything else throws before a login
     * or any other request is made.
     */
    suspend fun request(action: String): JsonElement = withContext(dispatcher) {
        DessReadOnly.check(action)
        val name = actionName(action)
        val current = activeSession()
        try {
            val dat = send(action, current.session)
            refusals.remove(name)
            dat
        } catch (error: DessMonitorError) {
            if (!error.isAuthFailure) throw error
            if (current.fresh) {
                // Refused on a session made for this very request: another login cannot help.
                noteRefusal(name)
                throw error
            }
            refusals[name]?.let { if (now() < it.retryAfter) throw error }
            val renewed = renewSession(current.serial) ?: throw error
            try {
                val dat = send(action, renewed)
                refusals.remove(name)
                dat
            } catch (second: DessMonitorError) {
                if (second.isAuthFailure) noteRefusal(name)
                throw second
            }
        }
    }

    /**
     * The cloud refused [name] even on a brand-new session, so the session is not what is wrong.
     * Wait longer each time before spending another login on it: 1, 2, 4 ... 32 minutes.
     */
    private fun noteRefusal(name: String) {
        val count = (refusals[name]?.count ?: 0) + 1
        refusals[name] = ActionRefusal(count, now().plusMillis((renewalBackoff(count) * 1000).toLong()))
    }

    private class Active(val session: DessSession, val serial: Int, val fresh: Boolean)

    private suspend fun activeSession(): Active {
        session?.let { if (it.isUsable(profile, account, now())) return Active(it, sessionSerial, false) }
        loginTask?.let {
            // A login is already running (first use, or a renewal). Wait for it.
            val fresh = it.await()
            return Active(fresh, sessionSerial, true)
        }
        store.load()?.let {
            if (it.isUsable(profile, account, now())) {
                session = it
                sessionSerial += 1
                return Active(it, sessionSerial, false)
            }
        }
        val fresh = login()
        return Active(fresh, sessionSerial, true)
    }

    /** Null means "do not retry": the refused session is itself brand new. */
    private suspend fun renewSession(afterFailureOf: Int): DessSession? {
        val current = session
        if (sessionSerial != afterFailureOf && current != null && current.isUsable(profile, account, now())) {
            return current   // another request already logged in again
        }
        if (loginTask == null && current != null) {
            // abs: a login stamped in the future (the clock was set back) must not look forever young.
            val ageMs = now().toEpochMilli() - current.createdAt
            if (kotlin.math.abs(ageMs) < MINIMUM_SECONDS_BETWEEN_LOGINS * 1000) return null
        }
        session = null
        store.clear()   // the server refused it; do not let the next launch try it again
        return login()
    }

    /** Concurrent callers share one login. */
    private suspend fun login(): DessSession {
        loginTask?.let { return it.await() }
        val task = scope.async { performLogin() }
        loginTask = task
        try {
            return task.await()
        } finally {
            if (loginTask === task) loginTask = null
        }
    }

    private suspend fun performLogin(): DessSession {
        if (user.isEmpty() || password.isEmpty()) throw DessMonitorError.MissingCredentials
        loginRefusal?.let { if (now() < it.until) throw it.error }

        val started = now()
        val url = DessSigning.loginURL(profile, user, password, DessSigning.salt(started))
        val json = fetchJSON(url, "authSource")
        val code = json["err"].int ?: -1
        if (code != 0) {
            // The password, and the hash of it that the login is signed with.
            val hidden = listOf(password, DessSigning.sha1Hex(password))
            val error = DessMonitorError.LoginRejected(code, scrub(json["desc"].string ?: "", hidden))
            val count = (loginRefusal?.count ?: 0) + 1
            loginRefusal = Refusal(now().plusMillis((renewalBackoff(count) * 1000).toLong()), error, count)
            throw error
        }
        val dat = json["dat"]
        val secret = dat["secret"].nonEmptyString
        val token = dat["token"].nonEmptyString
        if (secret == null || token == null) throw DessMonitorError.BadResponse("authSource", 200)
        // `json.dat.expire || 604800` in the Node client: seven days when the field is missing or zero.
        val lifetime = dat["expire"].double?.takeIf { it > 0 } ?: 604_800.0
        val startedMs = started.toEpochMilli().toDouble()
        val fresh = DessSession(profile.name, profile.baseURL, secret, token,
            startedMs + lifetime * 1000, account, startedMs)
        session = fresh
        sessionSerial += 1
        loginRefusal = null
        try { store.save(fresh) } catch (_: Exception) { }   // a session that cannot be saved still works for this run
        return fresh
    }

    private suspend fun send(action: String, session: DessSession): JsonElement {
        // The one place a data request is signed, so the read-only gate is checked here as well
        // as on the way in: no future caller inside this file can get round it.
        DessReadOnly.check(action)
        val name = actionName(action)
        val url = DessSigning.requestURL(profile, session.secret, session.token, action, DessSigning.salt(now()))
        val json = fetchJSON(url, name)
        val code = json["err"].int ?: -1
        if (code != 0) {
            val desc = scrub(json["desc"].string ?: "", listOf(session.token, session.secret))
            throw DessMonitorError.Api(name, code, desc)
        }
        return json["dat"] ?: JsonNull
    }

    private suspend fun fetchJSON(url: String, action: String): JsonElement {
        // The URL carries the token and the signature. It must never reach an error or a log,
        // which is why transport errors are rebuilt below instead of being passed on.
        val response = try {
            transport.get(url)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            throw safeError(e)
        }
        val json = Dat.parse(response.second)
        if (json !is JsonObject) throw DessMonitorError.BadResponse(action, response.first)
        return json
    }

    companion object {
        /**
         * A request that fails with an auth error on a session younger than this is not retried with
         * yet another login, so a persistent signing problem cannot turn into a login loop.
         */
        const val MINIMUM_SECONDS_BETWEEN_LOGINS = 60.0

        /** The only actions this client will sign. All of them read. */
        val ReadOnlyActions = DessReadOnly.actions

        fun actionName(action: String) = action.substringBefore('&')

        fun renewalBackoff(afterRefusals: Int): Double {
            val doublings = min(maxOf(afterRefusals, 1), 6) - 1
            return MINIMUM_SECONDS_BETWEEN_LOGINS * 2.0.pow(doublings)
        }

        /** A transport failure with the request URL stripped: the message of a connection error can hold it. */
        internal fun safeError(error: Exception): DessMonitorError = when (error) {
            is DessMonitorError -> error
            is SocketTimeoutException -> DessMonitorError.TimedOut
            is UnknownHostException, is ConnectException, is NoRouteToHostException -> DessMonitorError.Offline
            else -> DessMonitorError.Network("The request failed.")
        }

        /** Server text is shown to the user, so anything that could be a secret or a URL is removed first. */
        internal fun scrub(text: String, hiding: List<String>): String {
            var out = text
            for (secret in hiding) if (secret.isNotEmpty()) out = out.replace(secret, "<redacted>")
            out = out.replace(Regex("https?://\\S+"), "<url>")
            return out.take(200)
        }
    }
}
