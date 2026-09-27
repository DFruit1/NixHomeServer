package org.sydneybasiniot.youtubedownloader

class ShareBothActivity : ShareActivity() {
  override fun queueShared(url: String) = ShareTarget.queueMusicAndVideo(this, url)
  override fun queuedMessage(): String = "Queued music and video for download"
}
