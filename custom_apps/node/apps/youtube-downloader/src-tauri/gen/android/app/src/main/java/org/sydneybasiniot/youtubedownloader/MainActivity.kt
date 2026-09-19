package org.sydneybasiniot.youtubedownloader

import android.graphics.Color
import android.os.Bundle
import android.view.View
import androidx.activity.enableEdgeToEdge
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

class MainActivity : TauriActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    enableEdgeToEdge()
    super.onCreate(savedInstanceState)
    applySafeAreaInsets()
    ShareTarget.publishShortcut(this)
  }

  /**
   * targetSdk 35+ forces edge-to-edge, so inset the webview ourselves instead
   * of letting content run under the status bar and camera cutout. The strip
   * behind the inset matches the app background.
   */
  private fun applySafeAreaInsets() {
    window.decorView.setBackgroundColor(Color.rgb(0xF7, 0xF3, 0xF3))
    val content = findViewById<View>(android.R.id.content)
    ViewCompat.setOnApplyWindowInsetsListener(content) { view, insets ->
      val bars = insets.getInsets(
        WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout(),
      )
      view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
      insets
    }
  }
}
