package org.sydneybasiniot.youtubedownloader

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
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
      val line = "$url\n"
      // The Rust side resolves app data through the Tauri path API, which has
      // historically differed from filesDir on Android; write to every
      // plausible hand-off location and let the queue deduplicate by URL.
      listOfNotNull(filesDir, filesDir.parentFile, dataDir)
        .distinct()
        .forEach { directory -> File(directory, "pending-share.jsonl").appendText(line) }
      Toast.makeText(applicationContext, "Queued for download", Toast.LENGTH_SHORT).show()
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
