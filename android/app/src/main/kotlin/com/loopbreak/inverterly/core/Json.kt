package com.loopbreak.inverterly.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.math.abs

/**
 * The vendor cloud is loose about types: a power reading is the string "1154", a device code is
 * the number 2452, a flag can be `false` or "false". These accessors coerce instead of failing,
 * the same way the iOS app's `JSONValue` does. A missing member or a JSON null is Kotlin null.
 */
object Dat {
    fun parse(text: String): JsonElement? = try {
        Json.parseToJsonElement(text)
    } catch (_: Exception) {
        null
    }
}

/** Member of an object; null when this is not an object, the key is absent or the value is null. */
operator fun JsonElement?.get(key: String): JsonElement? {
    val value = (this as? JsonObject)?.get(key)
    return if (value == null || value is JsonNull) null else value
}

/** First member that exists, for fields the API spells more than one way (`devcode` / `devCode`). */
fun JsonElement?.any(vararg keys: String): JsonElement? {
    for (key in keys) this[key]?.let { return it }
    return null
}

/** First member that is non-empty text: the JS client's `a.title || a.desc || a.code`. */
fun JsonElement?.firstText(vararg keys: String): String? {
    for (key in keys) this[key].nonEmptyString?.let { return it }
    return null
}

val JsonElement?.array: List<JsonElement>? get() = (this as? JsonArray)?.toList()
val JsonElement?.obj: Map<String, JsonElement>? get() = (this as? JsonObject)

/** Text of a scalar. Numbers come back without a trailing ".0" so 2452 reads "2452". */
val JsonElement?.string: String?
    get() {
        val p = this as? JsonPrimitive ?: return null
        if (p is JsonNull) return null
        if (p.isString) return p.content
        val number = p.content.toDoubleOrNull() ?: return p.content   // true / false
        return plain(number)
    }

val JsonElement?.nonEmptyString: String? get() = string?.takeIf { it.isNotEmpty() }

/** A number, or a string that is exactly a number ("233.3", " 86 "). */
val JsonElement?.double: Double?
    get() {
        val p = this as? JsonPrimitive ?: return null
        if (p is JsonNull) return null
        if (!p.isString && (p.content == "true" || p.content == "false")) return null
        return p.content.trim().toDoubleOrNull()?.takeIf { it.isFinite() }
    }

val JsonElement?.int: Int?
    get() {
        val v = double ?: return null
        return if (abs(v) < 9e15) v.toLong().toInt() else null
    }

/** `true`/`false`, 1/0, or "true"/"false"/"1"/"0". */
val JsonElement?.bool: Boolean?
    get() {
        val p = this as? JsonPrimitive ?: return null
        if (p is JsonNull) return null
        if (!p.isString) {
            p.content.toBooleanStrictOrNull()?.let { return it }
            return p.content.toDoubleOrNull()?.let { it != 0.0 }
        }
        return when (p.content.trim().lowercase()) {
            "true", "1", "yes" -> true
            "false", "0", "no" -> false
            else -> null
        }
    }

/**
 * A reading that may carry decoration ("990M", "52.7 V"): everything but digits, "." and "-" is
 * dropped first. An empty or unparseable value is null rather than 0, so a missing reading is not
 * shown as a real zero.
 */
val JsonElement?.looseNumber: Double?
    get() {
        val p = this as? JsonPrimitive ?: return null
        if (p is JsonNull) return null
        if (!p.isString) return p.content.toDoubleOrNull()?.takeIf { it.isFinite() }
        val kept = p.content.filter { it in '0'..'9' || it == '.' || it == '-' }
        return kept.toDoubleOrNull()?.takeIf { it.isFinite() }
    }

private fun plain(number: Double): String =
    if (number.isFinite() && number == Math.rint(number) && abs(number) < 9e15) number.toLong().toString()
    else number.toString()
