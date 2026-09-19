package org.sydneybasiniot.youtubedownloader

import android.app.Activity
import android.os.Bundle
import android.widget.Toast

/**
 * Invisible share target. It queues the shared link and finishes without ever
 * showing UI or bringing the main task to the foreground.
 */
class ShareActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    val shared = intent?.getStringExtra(android.content.Intent.EXTRA_TEXT)
    val url = shared?.let { ShareTarget.extractUrl(it) }
    if (url != null) {
      try {
        ShareTarget.queue(this, url)
        Toast.makeText(applicationContext, "Queued for download", Toast.LENGTH_SHORT).show()
        ShareTarget.publishShortcut(this)
      } catch (_: Exception) {
        // The link stays shareable another way; do not crash the share target.
      }
    }
    finish()
  }
}
