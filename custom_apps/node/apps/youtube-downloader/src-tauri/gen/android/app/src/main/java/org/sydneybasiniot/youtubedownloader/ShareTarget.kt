package org.sydneybasiniot.youtubedownloader

import android.content.Context
import android.content.Intent
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import org.json.JSONObject
import java.io.File

/** Shared helpers for the Android share targets. */
object ShareTarget {
  const val HANDOFF_FILE = "pending-share.jsonl"

  /** Pull the first http(s) URL out of a shared blob of text. */
  fun extractUrl(text: String): String? {
    val match = Regex("https?://\\S+").find(text) ?: return null
    return match.value.trim().trimEnd('.', ',', ')', ']', '}', '\'', '"')
  }

  /**
   * The Rust side resolves app data through the Tauri path API, which has
   * historically differed from filesDir on Android; write to every plausible
   * hand-off location and let the queue deduplicate by URL.
   */
  fun queue(context: Context, url: String, mediaType: String) {
    val json = JSONObject().put("url", url).put("mediaType", mediaType).toString()
    val line = "$json\n"
    listOfNotNull(context.filesDir, context.filesDir.parentFile, context.dataDir)
      .distinct()
      .forEach { directory ->
        File(directory, HANDOFF_FILE).appendText(line)
      }
  }

  /** Publish the audio and video Direct Share targets. */
  fun publishShortcuts(context: Context) {
    publish(context, "share-audio", R.string.share_audio_label, ShareAudioActivity::class.java, 0)
    publish(context, "share-video", R.string.share_video_label, ShareVideoActivity::class.java, 1)
  }

  private fun publish(
    context: Context,
    id: String,
    labelRes: Int,
    activity: Class<*>,
    rank: Int,
  ) {
    try {
      val label = context.getString(labelRes)
      val shortcut = ShortcutInfoCompat.Builder(context, id)
        .setShortLabel(label)
        .setLongLabel(label)
        .setIcon(IconCompat.createWithResource(context, R.mipmap.ic_launcher))
        .setIntent(
          Intent(context, activity)
            .setAction(Intent.ACTION_SEND)
            .setType("text/plain"),
        )
        .setLongLived(true)
        // Rank asks the system to prefer these in the Direct Share row.
        .setRank(rank)
        .setCategories(setOf("com.android.intent.action.SEND"))
        .build()
      ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
    } catch (_: Exception) {
      // Share ranking is best-effort; never fail the app over it.
    }
  }
}
