package org.sydneybasiniot.youtubedownloader

import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.WebView
import androidx.activity.enableEdgeToEdge
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

class MainActivity : TauriActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    enableEdgeToEdge()
    super.onCreate(savedInstanceState)
    applySafeAreaInsets()
    ShareTarget.publishShortcuts(this)
  }

  override fun onWebViewCreate(webView: WebView) {
    super.onWebViewCreate(webView)
    // The WebView does not grant the async clipboard permission, so the
    // Paste button reads through this read-only bridge instead.
    webView.addJavascriptInterface(ClipboardBridge(applicationContext), "AndroidClipboard")
  }

  /**
   * targetSdk 35+ forces edge-to-edge, so inset the webview ourselves instead
   * of letting content run under the status bar and camera cutout. The strip
   * behind the inset matches the app background in light and dark mode.
   */
  private fun applySafeAreaInsets() {
    window.decorView.setBackgroundColor(ContextCompat.getColor(this, R.color.app_background))
    val content = findViewById<View>(android.R.id.content)
    ViewCompat.setOnApplyWindowInsetsListener(content) { view, insets ->
      val bars = insets.getInsets(
        WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout(),
      )
      view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
      insets
    }
  }

  /** Exposes only the current plain-text clip to the bundled UI. */
  private class ClipboardBridge(private val context: Context) {
    @JavascriptInterface
    fun readText(): String {
      val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return ""
      val clip = clipboard.primaryClip ?: return ""
      if (clip.itemCount == 0) {
        return ""
      }
      return clip.getItemAt(0).coerceToText(context)?.toString() ?: ""
    }
  }
}
