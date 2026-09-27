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
  protected open fun saveAudioToAudiobooks(): Boolean = false
  protected open fun queueShared(url: String) = ShareTarget.queue(this, url, mediaType(), saveAudioToAudiobooks())
  protected open fun queuedMessage(): String = "Queued ${mediaType()} for download"

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    val shared = intent?.getStringExtra(Intent.EXTRA_TEXT)
    val url = shared?.let { ShareTarget.extractUrl(it) }
    if (url != null) {
      try {
        queueShared(url)
        Toast.makeText(applicationContext, queuedMessage(), Toast.LENGTH_SHORT).show()
        ShareTarget.publishShortcuts(this)
      } catch (_: Exception) {
        // The link stays shareable another way; do not crash the share target.
      }
    } else {
      Toast.makeText(applicationContext, "Share a valid YouTube link", Toast.LENGTH_SHORT).show()
    }
    finish()
  }
}
