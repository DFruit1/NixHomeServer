package org.sydneybasiniot.youtubedownloader

import android.app.Activity
import android.os.Bundle

/**
 * Invisible deep-link target used after a prompted share is queued: moving the
 * task to the back reveals the app the link came from (usually YouTube).
 */
class ReturnActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    moveTaskToBack(true)
    finish()
  }
}
