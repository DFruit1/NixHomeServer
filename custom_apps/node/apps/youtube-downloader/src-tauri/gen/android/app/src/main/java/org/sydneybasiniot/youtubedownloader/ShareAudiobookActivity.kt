package org.sydneybasiniot.youtubedownloader

class ShareAudiobookActivity : ShareActivity() {
  override fun saveAudioToAudiobooks(): Boolean = true
  override fun queuedMessage(): String = "Queued audiobook for download"
}
