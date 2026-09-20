package org.sydneybasiniot.youtubedownloader

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Invisible share target that opens the app with the shared link prefilled so
 * the user can choose options before queueing.
 */
class SharePromptActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    val shared = intent?.getStringExtra(Intent.EXTRA_TEXT)
    val url = shared?.let { ShareTarget.extractUrl(it) }
    if (url != null) {
      try {
        ShareTarget.queuePrompt(this, url)
        ShareTarget.publishShortcuts(this)
      } catch (_: Exception) {
        // Never fail the share target over a best-effort hand-off.
      }
      val launch = Intent(this, MainActivity::class.java).addFlags(
        Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP,
      )
      startActivity(launch)
    }
    finish()
  }
}
