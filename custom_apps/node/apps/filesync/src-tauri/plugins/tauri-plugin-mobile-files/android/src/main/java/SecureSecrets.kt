package org.nixhomeserver.filesync.mobilefiles

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal object SecureSecrets {
  private const val KEY_ALIAS = "org.nixhomeserver.filesync.oidc-session.v1"
  private const val PREFS = "org.nixhomeserver.filesync.secure-session.v1"

  fun store(context: Context, slot: String, value: String) {
    require(slot.matches(Regex("[a-z0-9-]{1,48}"))) { "Invalid secure storage slot" }
    require(value.toByteArray(Charsets.UTF_8).size <= 65_536) { "Secure data is too large" }
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.ENCRYPT_MODE, sessionKey())
    val encrypted = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
    val stored = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
      .putString(slot, Base64.encodeToString(encrypted, Base64.NO_WRAP))
      .commit()
    check(stored) { "Could not persist secure data" }
  }

  fun load(context: Context, slot: String): String? {
    require(slot.matches(Regex("[a-z0-9-]{1,48}"))) { "Invalid secure storage slot" }
    val encoded = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(slot, null) ?: return null
    val encrypted = Base64.decode(encoded, Base64.NO_WRAP)
    require(encrypted.size > 12) { "Stored secure data is invalid" }
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.DECRYPT_MODE, sessionKey(), GCMParameterSpec(128, encrypted.copyOfRange(0, 12)))
    return cipher.doFinal(encrypted.copyOfRange(12, encrypted.size)).toString(Charsets.UTF_8)
  }

  fun clear(context: Context, slot: String) {
    require(slot.matches(Regex("[a-z0-9-]{1,48}"))) { "Invalid secure storage slot" }
    val cleared = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(slot).commit()
    check(cleared) { "Could not persist secure-data removal" }
  }

  private fun sessionKey(): SecretKey {
    val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    if (!keyStore.containsAlias(KEY_ALIAS)) {
      val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
      generator.init(
        KeyGenParameterSpec.Builder(
          KEY_ALIAS,
          KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
          .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
          .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
          .setRandomizedEncryptionRequired(true)
          .build(),
      )
      generator.generateKey()
    }
    return keyStore.getKey(KEY_ALIAS, null) as SecretKey
  }
}
