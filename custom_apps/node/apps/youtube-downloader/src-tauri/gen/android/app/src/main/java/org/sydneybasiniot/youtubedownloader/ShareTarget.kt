package org.sydneybasiniot.youtubedownloader

import android.content.Context
import android.content.Intent
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import java.io.File

/** Shared helpers for the Android share target. */
object ShareTarget {
  const val SHORTCUT_ID = "share-youtube-downloader"
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
  fun queue(context: Context, url: String) {
    val line = "$url\n"
    listOfNotNull(context.filesDir, context.filesDir.parentFile, context.dataDir)
      .distinct()
      .forEach { directory ->
        File(directory, HANDOFF_FILE).appendText(line)
      }
  }

  /** Publish a Direct Share target so the app surfaces near the top of the sheet. */
  fun publishShortcut(context: Context) {
    try {
      val shortcut = ShortcutInfoCompat.Builder(context, SHORTCUT_ID)
        .setShortLabel(context.getString(R.string.app_name))
        .setLongLabel(context.getString(R.string.app_name))
        .setIcon(IconCompat.createWithResource(context, R.mipmap.ic_launcher))
        .setIntent(
          Intent(context, ShareActivity::class.java)
            .setAction(Intent.ACTION_SEND)
            .setType("text/plain"),
        )
        .setLongLived(true)
        // Rank 0 asks the system to prefer this target in the Direct Share row.
        .setRank(0)
        .setCategories(setOf("com.android.intent.action.SEND"))
        .build()
      ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
    } catch (_: Exception) {
      // Share ranking is best-effort; never fail the app over it.
    }
  }
}
