package org.sydneybasiniot.youtubedownloader

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Toast

/**
 * Invisible share target base. Queues the shared link for the media type and
 * finishes without showing UI or bringing the main task to the foreground.
 */
abstract class ShareActivity : Activity() {
  protected open fun mediaType(): String = "audio"

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    val shared = intent?.getStringExtra(Intent.EXTRA_TEXT)
    val url = shared?.let { ShareTarget.extractUrl(it) }
    if (url != null) {
      try {
        ShareTarget.queue(this, url, mediaType())
        Toast.makeText(applicationContext, "Queued ${mediaType()} for download", Toast.LENGTH_SHORT).show()
        ShareTarget.publishShortcuts(this)
      } catch (_: Exception) {
        // The link stays shareable another way; do not crash the share target.
      }
    }
    finish()
  }
}
