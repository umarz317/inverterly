package com.loopbreak.inverterly.core

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Keeps a password only where the app can get it back and nothing else can read it. */
interface PasswordStore {
    fun save(password: String)
    fun read(): String?
    fun clear()
}

/**
 * The password is encrypted with an AES-GCM key that lives in the Android Keystore (hardware backed
 * where the phone has it) and never leaves it. Only the ciphertext is written to the app's private
 * preferences, so a copy of that file alone is useless.
 */
class KeystorePasswordStore(context: Context) : PasswordStore {
    private val prefs = context.getSharedPreferences("account_secret", Context.MODE_PRIVATE)

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    override fun save(password: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.ENCRYPT_MODE, key()) }
        val encrypted = cipher.doFinal(password.toByteArray())
        prefs.edit()
            .putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .putString("data", Base64.encodeToString(encrypted, Base64.NO_WRAP))
            .apply()
    }

    override fun read(): String? {
        val iv = prefs.getString("iv", null) ?: return null
        val data = prefs.getString("data", null) ?: return null
        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
            String(cipher.doFinal(Base64.decode(data, Base64.NO_WRAP)))
        } catch (_: Exception) {
            null   // the key is gone (restored phone, cleared lock screen): sign in again
        }
    }

    override fun clear() {
        prefs.edit().clear().apply()
        try {
            KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }.deleteEntry(ALIAS)
        } catch (_: Exception) { }
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "inverterly_password"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}

/** The signed-in account: username and cloud identity in private preferences, password in the Keystore. */
class AccountStore(context: Context, private val passwords: PasswordStore = KeystorePasswordStore(context)) {
    private val prefs = context.getSharedPreferences("account", Context.MODE_PRIVATE)

    /** Whether the account stays signed in from one launch to the next ("Remember me" at sign-in). */
    var remember: Boolean
        get() = prefs.getBoolean("remember", true)
        set(value) { prefs.edit().putBoolean("remember", value).apply() }

    val user: String? get() = prefs.getString("user", null)

    fun save(profile: CloudProfile, user: String, password: String) {
        passwords.save(password)
        prefs.edit().putString("user", user).putString("app", profile.name).apply()
    }

    /** The saved account, or throws [NoAccountError]. */
    fun load(): InverterConfig {
        val user = prefs.getString("user", null)?.takeIf { it.isNotEmpty() } ?: throw NoAccountError()
        val password = passwords.read()?.takeIf { it.isNotEmpty() } ?: throw NoAccountError()
        return InverterConfig(CloudProfile.named(prefs.getString("app", null)), user, password)
    }

    /** Forgets the account: the username, the identity and the password. */
    fun clear() {
        prefs.edit().remove("user").remove("app").apply()
        passwords.clear()
    }
}
