package org.sydneybasiniot.youtubedownloader

import android.content.Intent
import android.os.Bundle
import androidx.activity.enableEdgeToEdge
import java.io.File

class MainActivity : TauriActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    // A shared link is queued and the activity finishes immediately so sharing
    // never opens the downloader UI.
    if (handleShareIntent(intent)) {
      finish()
      return
    }
    enableEdgeToEdge()
    super.onCreate(savedInstanceState)
  }

  override fun onNewIntent(intent: Intent) {
    if (handleShareIntent(intent)) {
      return
    }
    super.onNewIntent(intent)
  }

  private fun handleShareIntent(intent: Intent?): Boolean {
    if (intent == null || intent.action != Intent.ACTION_SEND) {
      return false
    }
    val shared = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return false
    val url = extractUrl(shared) ?: return true
    return try {
      File(filesDir, "pending-share.jsonl").appendText("$url\n")
      true
    } catch (_: Exception) {
      false
    }
  }

  private fun extractUrl(text: String): String? {
    val match = Regex("https?://\\S+").find(text) ?: return null
    return match.value.trim().trimEnd('.', ',', ')', ']', '}', '\'', '"')
  }
}
