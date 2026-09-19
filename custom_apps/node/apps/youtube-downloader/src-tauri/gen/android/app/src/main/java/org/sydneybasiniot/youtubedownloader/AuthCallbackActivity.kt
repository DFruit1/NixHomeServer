package org.sydneybasiniot.youtubedownloader

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import java.io.File

/**
 * Receives the Kanidm custom-scheme redirect, hands the query to Rust, and
 * returns to the app. Theme.NoDisplay means no intermediate page is shown.
 */
class AuthCallbackActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    val data = intent?.data
    val query = data?.query ?: intent?.dataString?.substringAfter('?', "")
    if (!query.isNullOrEmpty()) {
      try {
        listOfNotNull(filesDir, filesDir.parentFile, dataDir).distinct()
          .forEach { directory -> File(directory, "oauth-callback.txt").writeText(query) }
      } catch (_: Exception) {
        // The sign-in flow will time out and can be retried.
      }
    }
    try {
      startActivity(
        Intent(this, MainActivity::class.java)
          .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
      )
    } catch (_: Exception) {
    }
    finish()
  }
}
