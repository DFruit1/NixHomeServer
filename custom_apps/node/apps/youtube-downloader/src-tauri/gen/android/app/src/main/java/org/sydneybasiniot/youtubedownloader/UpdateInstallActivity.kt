package org.sydneybasiniot.youtubedownloader

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.core.content.FileProvider
import java.io.File

/**
 * Hands the APK that the install_app_update command cached to the system
 * package installer. Reached through the app's custom scheme so Rust never
 * needs direct JNI access, mirroring ReturnActivity. The system installer
 * still shows its own confirmation; this activity only prepares the hand-off.
 */
class UpdateInstallActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    val apkPath = intent?.data?.getQueryParameter("path")
    val apk = if (!apkPath.isNullOrBlank()) File(apkPath) else File(cacheDir, "youtube-downloader-update.apk")
    val dataDirPath = applicationInfo.dataDir
    val insideAppData = try {
      apk.canonicalPath.startsWith(File(dataDirPath).canonicalPath)
    } catch (_: Exception) {
      false
    }
    if (!apk.isFile || !insideAppData) {
      Toast.makeText(this, "The downloaded update was not found.", Toast.LENGTH_SHORT).show()
      finish()
      return
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
      // First run: send the user to this app's "install unknown apps"
      // toggle, then they tap Install update once more.
      try {
        startActivity(
          Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:$packageName"),
          ),
        )
      } catch (_: Exception) {
        Toast.makeText(this, "Allow installs for this app, then try again.", Toast.LENGTH_SHORT).show()
      }
      finish()
      return
    }
    try {
      val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)
      startActivity(
        Intent(Intent.ACTION_VIEW)
          .setDataAndType(uri, "application/vnd.android.package-archive")
          .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
      )
    } catch (_: Exception) {
      Toast.makeText(this, "Couldn't start the installer.", Toast.LENGTH_SHORT).show()
    }
    finish()
  }
}
