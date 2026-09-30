package org.nixhomeserver.filesync.mobilefiles

import android.Manifest
import android.content.Context
import android.app.NotificationChannel
import android.content.pm.PackageManager
import android.os.Environment
import android.os.StatFs
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.content.pm.ServiceInfo
import androidx.core.app.NotificationCompat
import androidx.annotation.Keep
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

private const val EXTERNAL_STORAGE_PROVIDER = "com.android.externalstorage.documents"
private const val PAIRS_SLOT = "background-sync-pairs"
private const val SESSION_SLOT = "oidc-session"
private const val STATUS_SLOT = "background-sync-status"
private const val PERIODIC_WORK = "filesync-periodic"
private const val IMMEDIATE_WORK = "filesync-immediate"
private const val HTTP_TIMEOUT_MS = 30_000
private const val SYNC_CHANNEL_ID = "filesync-sync"
private const val WORKER_NOTIFICATION_ID = 41
private const val MANUAL_NOTIFICATION_ID = 42
private const val STORAGE_FLOOR_FRACTION = 0.15
private const val DEFAULT_BLOCK_FRACTION = 0.95

internal object BackgroundSyncScheduler {
  fun update(context: Context, enabled: Boolean) {
    val manager = WorkManager.getInstance(context)
    if (!enabled) {
      manager.cancelUniqueWork(PERIODIC_WORK)
      manager.cancelUniqueWork(IMMEDIATE_WORK)
      return
    }
    val constraints = Constraints.Builder()
      .setRequiredNetworkType(NetworkType.UNMETERED)
      .build()
    val periodic = PeriodicWorkRequestBuilder<BackgroundSyncWorker>(15, TimeUnit.MINUTES)
      .setConstraints(constraints)
      .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
      .build()
    manager.enqueueUniquePeriodicWork(PERIODIC_WORK, ExistingPeriodicWorkPolicy.UPDATE, periodic)
    val immediate = OneTimeWorkRequestBuilder<BackgroundSyncWorker>()
      .setConstraints(constraints)
      .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
      .build()
    manager.enqueueUniqueWork(IMMEDIATE_WORK, ExistingWorkPolicy.REPLACE, immediate)
  }
}

@Keep
internal class BackgroundSyncWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
  override suspend fun doWork(): androidx.work.ListenableWorker.Result {
    setForeground(foregroundInfo())
    return withContext(Dispatchers.IO) {
      try {
        SyncEngine.syncAll(applicationContext)
        androidx.work.ListenableWorker.Result.success()
      } catch (error: SyncFailure) {
        SyncEngine.writeStatus(applicationContext, error.message ?: "Background sync could not finish.")
        if (error.message?.contains("Sign in", ignoreCase = true) == true || error.message?.contains("session expired", ignoreCase = true) == true) {
          BackgroundSyncScheduler.update(applicationContext, false)
        }
        if (error.retryable) androidx.work.ListenableWorker.Result.retry()
        else androidx.work.ListenableWorker.Result.success()
      } catch (error: kotlinx.coroutines.CancellationException) {
        throw error
      } catch (error: Exception) {
        SyncEngine.writeStatus(applicationContext, "Background sync stopped. Open File Sync to review the connection and folder access.")
        androidx.work.ListenableWorker.Result.retry()
      }
    }
  }

  private fun foregroundInfo(): androidx.work.ForegroundInfo {
    val channelId = "filesync-background"
    val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      manager.createNotificationChannel(NotificationChannel(channelId, "File Sync", NotificationManager.IMPORTANCE_LOW))
    }
    val launchIntent = applicationContext.packageManager.getLaunchIntentForPackage(applicationContext.packageName)
    val pendingIntent = launchIntent?.let {
      PendingIntent.getActivity(applicationContext, 0, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    val notification = NotificationCompat.Builder(applicationContext, channelId)
      .setSmallIcon(android.R.drawable.stat_sys_upload)
      .setContentTitle("File Sync is running")
      .setContentText("Checking saved folders")
      .setOngoing(true)
      .setOnlyAlertOnce(true)
      .setContentIntent(pendingIntent)
      .build()
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      androidx.work.ForegroundInfo(41, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
    } else {
      androidx.work.ForegroundInfo(41, notification)
    }
  }
}

internal object SyncEngine {
  private val syncLock = Semaphore(1)

  @Volatile private var memoryProgress: String? = null

  fun acquireSyncLock() = syncLock.acquire()
  fun releaseSyncLock() = syncLock.release()

  fun updateConfiguration(context: Context, pairsJson: String, enabled: Boolean) {
    // Store the new pair list without taking the sync lock. A running sync
    // already loaded its work list, so blocking removal on a long book sync
    // froze the UI. The next run picks up the stored configuration.
    SecureSecrets.store(context, PAIRS_SLOT, pairsJson)
    val hasSession = !SecureSecrets.load(context, SESSION_SLOT).isNullOrBlank()
    BackgroundSyncScheduler.update(context, enabled && hasSession)
  }

  fun readProgress(): String? = memoryProgress

  private fun reportProgress(
    context: Context,
    notificationId: Int,
    pairName: String,
    activePairs: List<String>,
    direction: String,
    currentFile: String,
    transferred: Int,
    skipped: Int,
  ) {
    val payload = JSONObject()
      .put("active", true)
      .put("pair", pairName)
      .put("pairs", JSONArray(activePairs))
      .put("direction", direction)
      .put("currentFile", currentFile)
      .put("transferred", transferred)
      .put("skipped", skipped)
      .toString()
    memoryProgress = payload
    val arrow = if (direction == "server-to-phone") "↓" else "↑"
    val title = if (activePairs.size > 1) "Syncing ${activePairs.size} folders" else "Syncing $pairName"
    val text = if (currentFile.isBlank()) "Preparing…" else "$arrow $currentFile"
    showSyncNotification(context, notificationId, title, text)
  }

  private fun clearProgress(context: Context, notificationId: Int) {
    memoryProgress = null
    runCatching {
      (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(notificationId)
    }
  }

  private fun showSyncNotification(context: Context, notificationId: Int, title: String, text: String) {
    try {
      if (Build.VERSION.SDK_INT >= 33 &&
        context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
      ) {
        return
      }
      val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        manager.createNotificationChannel(
          NotificationChannel(SYNC_CHANNEL_ID, "File Sync activity", NotificationManager.IMPORTANCE_LOW),
        )
      }
      val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
      val pendingIntent = launchIntent?.let {
        PendingIntent.getActivity(context, 0, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
      }
      val notification = NotificationCompat.Builder(context, SYNC_CHANNEL_ID)
        .setSmallIcon(android.R.drawable.stat_sys_upload)
        .setContentTitle(title)
        .setContentText(text)
        .setStyle(NotificationCompat.BigTextStyle().bigText(text))
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setContentIntent(pendingIntent)
        .build()
      manager.notify(notificationId, notification)
    } catch (_: Exception) {
      // Notifications are best-effort; sync must continue without them.
    }
  }

  fun syncPair(context: Context, pairJson: String): Map<String, Any> {
    var locked = false
    try {
      acquireSyncLock()
      locked = true
      val pair = JSONObject(pairJson)
      val session = currentSession(context)
      val pairName = pair.optString("name", "Folder pair").ifBlank { "Folder pair" }
      reportProgress(context, MANUAL_NOTIFICATION_ID, pairName, listOf(pairName),
        pair.optString("direction"), "", 0, 0)
      val result = syncOne(context, session, pair, MANUAL_NOTIFICATION_ID)
      writeStatus(context, "Last sync finished: ${result["transferred"] as Int} files copied.")
      return result
    } catch (error: InterruptedException) {
      Thread.currentThread().interrupt()
      throw SyncFailure("Sync was interrupted.", true)
    } catch (error: SyncFailure) {
      writeStatus(context, error.message ?: "Sync could not finish.")
      if (error.message?.contains("Sign in", ignoreCase = true) == true || error.message?.contains("session expired", ignoreCase = true) == true) {
        BackgroundSyncScheduler.update(context, false)
      }
      throw error
    } catch (error: Exception) {
      writeStatus(context, "Sync could not finish. Open File Sync to review the connection and folder access.")
      throw SyncFailure("Sync could not finish: ${error.message ?: "check the server and folder access"}.", true)
    } finally {
      clearProgress(context, MANUAL_NOTIFICATION_ID)
      if (locked) releaseSyncLock()
    }
  }

  fun syncAll(context: Context) {
    var locked = false
    try {
      acquireSyncLock()
      locked = true
      val config = SecureSecrets.load(context, PAIRS_SLOT)
      val pairs = if (config.isNullOrBlank()) JSONArray() else JSONArray(config)
      if (pairs.length() == 0) {
        writeStatus(context, "Background sync is off because no folder pairs are saved.")
        return
      }
      val session = currentSession(context)
      cleanupStagedFiles(context)
      var transferred = 0
      var completedPairs = 0
      val warnings = mutableListOf<String>()
      val activeNames = (0 until pairs.length())
        .map { pairs.getJSONObject(it).optString("name", "Folder pair").ifBlank { "Folder pair" } }
      for (index in 0 until pairs.length()) {
        val pair = pairs.getJSONObject(index)
        try {
          val result = syncOne(context, session, pair, WORKER_NOTIFICATION_ID, activeNames)
          transferred += result["transferred"] as Int
          completedPairs++
        } catch (error: SyncFailure) {
          if (error.message?.contains("Sign in", ignoreCase = true) == true || error.message?.contains("session expired", ignoreCase = true) == true) throw error
          warnings.add("${pair.optString("name", "Folder pair")}: ${error.message ?: "needs attention"}")
        }
      }
      if (completedPairs == 0 && warnings.isNotEmpty()) {
        BackgroundSyncScheduler.update(context, false)
        writeStatus(context, warnings.joinToString(" "))
      } else {
        val summary = "Background sync finished: $transferred files copied."
        writeStatus(context, if (warnings.isEmpty()) summary else "$summary ${warnings.joinToString(" ")}")
      }
    } catch (error: InterruptedException) {
      Thread.currentThread().interrupt()
      throw SyncFailure("Background sync was interrupted.", true)
    } catch (error: SyncFailure) {
      throw error
    } catch (error: Exception) {
      throw SyncFailure("Background sync could not finish: ${error.message ?: "check the server and folder access"}.", true)
    } finally {
      runCatching { clearProgress(context, WORKER_NOTIFICATION_ID) }
      if (locked) releaseSyncLock()
    }
  }

  fun writeStatus(context: Context, message: String) {
    runCatching {
      SecureSecrets.store(
        context,
        STATUS_SLOT,
        JSONObject().put("checkedAt", System.currentTimeMillis()).put("message", message).toString(),
      )
    }
  }

  fun readStatus(context: Context): String? = SecureSecrets.load(context, STATUS_SLOT)

  private fun currentSession(context: Context): JSONObject {
    val raw = SecureSecrets.load(context, SESSION_SLOT)
      ?: throw SyncFailure("Sign in with Kanidm to resume background sync.", false)
    val session = JSONObject(raw)
    if (session.optLong("expiresAt") > epochSeconds() + 60) return session
    val form = mapOf(
      "grant_type" to "refresh_token",
      "client_id" to session.getString("clientId"),
      "refresh_token" to session.getString("refreshToken"),
    )
    val response = request(
      URL(session.getString("tokenEndpoint")), "POST", form = form, allowErrorBody = true,
    )
    if (response.code !in 200..299) {
      val oauthError = runCatching { JSONObject(response.body).optString("error") }.getOrNull()
      if (oauthError == "invalid_grant") {
        SecureSecrets.clear(context, SESSION_SLOT)
        throw SyncFailure("Kanidm session expired or was revoked. Sign in again to resume background sync.", false)
      }
      throw SyncFailure("Kanidm could not refresh the session. Background sync will retry.", true)
    }
    val token = JSONObject(response.body)
    if (!token.optString("token_type").equals("bearer", ignoreCase = true) || token.optLong("expires_in") <= 0L) {
      throw SyncFailure("Kanidm returned an invalid refreshed session.", false)
    }
    session.put("accessToken", token.getString("access_token"))
    if (token.has("refresh_token")) session.put("refreshToken", token.getString("refresh_token"))
    session.put("expiresAt", epochSeconds() + token.optLong("expires_in"))
    SecureSecrets.store(context, SESSION_SLOT, session.toString())
    return session
  }

  private data class SyncPlan(
    val pairName: String,
    val direction: String,
    val apiBase: String,
    val accessToken: String,
    val folderUri: String,
    val deviceSubpath: String,
    val serverPath: String,
    val root: String,
    val blockFraction: Double,
  )

  private fun loadPlan(context: Context, session: JSONObject, pair: JSONObject): SyncPlan {
    val pairName = pair.optString("name", "Folder pair").ifBlank { "Folder pair" }
    val direction = pair.getString("direction")
    if (direction != "phone-to-server" && direction != "server-to-phone") {
      throw SyncFailure("This sync direction is not supported for background sync.", false)
    }
    val account = pair.optString("account")
    if (account.isBlank()) throw SyncFailure("This folder pair needs to be recreated before background sync.", false)
    val apiBase = session.getString("apiBase").trimEnd('/')
    if (!apiBase.startsWith("https://")) throw SyncFailure("The saved sync server must use HTTPS.", false)
    val pairServer = pair.optString("server")
    if (pairServer.isNotBlank() && pairServer.trimEnd('/') != apiBase) {
      throw SyncFailure("This folder pair belongs to another server.", false)
    }
    val storedUri = pair.getJSONObject("local").getString("uri")
    val folderUri = normalizeFolderUri(context, storedUri)
    val folderSlot = "folder-${sha256(folderUri.toByteArray()).take(32)}"
    val storedSlot = "folder-${sha256(storedUri.toByteArray()).take(32)}"
    val authorized = (SecureSecrets.load(context, folderSlot) == folderUri ||
      SecureSecrets.load(context, storedSlot) == storedUri) && hasTreeGrant(context, folderUri)
    if (!authorized) {
      throw SyncFailure("Folder access expired. Open File Sync and choose the device folder again.", false)
    }
    val identity = request(URL("$apiBase/api/v1/me"), "GET", accessToken = session.getString("accessToken"))
    if (JSONObject(identity.body).optString("username") != account) {
      throw SyncFailure("This folder pair belongs to another Kanidm account.", false)
    }
    val localSubpath = safePath(pair.optString("localSubpath"))
    val deviceSubpath = if (folderUri.startsWith("content")) localSubpath else ""
    return SyncPlan(
      pairName = pairName,
      direction = direction,
      apiBase = apiBase,
      accessToken = session.getString("accessToken"),
      folderUri = folderUri,
      deviceSubpath = deviceSubpath,
      serverPath = safePath(pair.optString("serverPath")),
      root = safeRoot(pair.optString("serverRoot", "files")),
      blockFraction = pair.optDouble("storageBlock", DEFAULT_BLOCK_FRACTION),
    )
  }

  private fun storageBudget(freeBytes: Long, totalBytes: Long): Long =
    (freeBytes - (totalBytes * STORAGE_FLOOR_FRACTION).toLong()).coerceAtLeast(0L)

  private fun formatBytes(value: Long): String {
    if (value < 1024) return "$value B"
    val units = arrayOf("KB", "MB", "GB", "TB")
    var amount = value.toDouble() / 1024
    var unit = units[0]
    for (candidate in units) {
      unit = candidate
      if (amount < 1024 || candidate == "TB") break
      amount /= 1024
    }
    return if (amount >= 100) "${amount.toInt()} $unit" else "${"%.1f".format(amount)} $unit"
  }
  private fun syncOne(
    context: Context,
    session: JSONObject,
    pair: JSONObject,
    notificationId: Int,
    activePairs: List<String>? = null,
  ): Map<String, Any> {
    val plan = loadPlan(context, session, pair)
    val pairName = plan.pairName
    val names = activePairs ?: listOf(pairName)
    val direction = plan.direction
    val folderUri = plan.folderUri
    val deviceSubpath = plan.deviceSubpath
    val serverPath = plan.serverPath
    val root = plan.root
    val apiBase = plan.apiBase
    val localEntries = listLocalFiles(context, folderUri).filter { entry ->
      entry.kind == "file" && (deviceSubpath.isEmpty() || entry.path.startsWith("$deviceSubpath/"))
    }.associateBy { entry -> if (deviceSubpath.isEmpty()) entry.path else entry.path.removePrefix("$deviceSubpath/") }
    val remoteEntries = fetchRemoteTree(apiBase, plan.accessToken, serverPath, root)
      .filter { it.kind == "file" }.associateBy { it.path }
    var transferred = 0
    var skipped = 0
    fun progress(currentFile: String) {
      reportProgress(context, notificationId, pairName, names, direction, currentFile, transferred, skipped)
    }
    progress("")
    if (direction == "phone-to-server") {
      for ((relative, entry) in localEntries) {
        if (remoteEntries[relative]?.sha256 == entry.sha256) { skipped++; continue }
        progress(relative)
        val staged = stageLocalFile(context, folderUri, join(deviceSubpath, relative), entry.sha256)
        try {
          val target = join(serverPath, relative)
          val response = request(
            fileUrl(apiBase, target, root), "PUT", accessToken = plan.accessToken,
            file = staged, checksum = entry.sha256,
          )
          if (response.code !in 200..299) failHttp(response.code, "The server could not save $relative")
          transferred++
        } finally { staged.delete() }
      }
    } else {
      // Downloads consume device space: pre-check the estimate, then enforce
      // the block limit against real bytes written in case the estimate moved.
      val pending = remoteEntries.filter { (relative, entry) ->
        localEntries[relative]?.sha256 != entry.sha256
      }.toList()
      skipped += remoteEntries.size - pending.size
      val pendingBytes = pending.sumOf { (_, entry) -> entry.size }
      val stats = storageStats(context)
      val budget = storageBudget(stats.freeBytes, stats.totalBytes)
      val blockLimit = (budget * plan.blockFraction).toLong()
      if (pendingBytes > 0 && pendingBytes > blockLimit) {
        throw SyncFailure(
          "Not enough free space: “$pairName” needs ${formatBytes(pendingBytes)} but only " +
            "${formatBytes(blockLimit)} may be used (keeps 15% of device storage free). " +
            "Free up space or raise the limit in Settings.",
          false,
        )
      }
      var writtenBytes = 0L
      for ((relative, entry) in pending) {
        progress(relative)
        val response = request(fileUrl(apiBase, join(serverPath, relative), root), "GET", accessToken = plan.accessToken, streamToCache = context.cacheDir)
        if (response.code !in 200..299) failHttp(response.code, "The server could not provide $relative")
        val staged = response.file ?: throw SyncFailure("The download could not be staged.", true)
        try {
          if (sha256(staged) != entry.sha256) throw SyncFailure("Downloaded file failed its checksum: $relative", true)
          installLocalFile(context, folderUri, join(deviceSubpath, relative), staged)
          writtenBytes += staged.length()
          if (writtenBytes > blockLimit) {
            throw SyncFailure(
              "Sync stopped: “$pairName” passed its free-space limit after ${formatBytes(writtenBytes)}. " +
                "Free up space or raise the limit in Settings, then sync again.",
              false,
            )
          }
          transferred++
        } finally { staged.delete() }
      }
    }
    // Return a plain Map so Tauri's Jackson serializer emits real JSON.
    // A JSONObject would serialize as a bean (empty/mapped fields) and the
    // Rust side would reject it as "Android sync returned an invalid result."
    return mapOf("transferred" to transferred, "skipped" to skipped, "direction" to direction)
  }

  private fun fetchRemoteTree(apiBase: String, accessToken: String, base: String, root: String): List<Entry> {
    val result = mutableListOf<Entry>()
    val pending = ArrayDeque<String>()
    pending.add(base)
    while (pending.isNotEmpty()) {
      val directory = pending.removeLast()
      val url = URL("$apiBase/api/v1/tree?path=${encode(directory)}&root=${encode(root)}&hashes=true")
      val response = request(url, "GET", accessToken = accessToken)
      if (response.code !in 200..299) failHttp(response.code, "The server folder could not be read")
      val entries = JSONObject(response.body).getJSONArray("data")
      for (index in 0 until entries.length()) {
        val item = entries.getJSONObject(index)
        val name = item.getString("name")
        val absolute = join(directory, name)
        if (item.getString("kind") == "directory") pending.add(absolute)
        result.add(Entry(
          path = if (base.isEmpty()) absolute else absolute.removePrefix("$base/"),
          kind = item.getString("kind"),
          sha256 = item.optString("sha256"),
          size = item.optLong("size"),
        ))
      }
    }
    return result
  }

  private fun listLocalFiles(context: Context, folderUri: String): List<Entry> {
    val tree = Uri.parse(folderUri)
    if (tree.scheme == "file") return listLocalFilesFile(File(requireNotNull(tree.path) { "The selected folder is invalid." }))
    val result = mutableListOf<Entry>()
    fun walk(parentId: String, prefix: String) {
      val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
      val projection = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_SIZE,
      )
      val cursor = context.contentResolver.query(children, projection, null, null, null)
        ?: throw SyncFailure("The selected folder cannot be listed. Reauthorize it in File Sync.", false)
      cursor.use {
        while (it.moveToNext()) {
          val id = it.getString(0)
          val name = it.getString(1) ?: continue
          if (name.isBlank() || name == "." || name == ".." || name.contains('/')) continue
          val path = join(prefix, name)
          val kind = if (it.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) "directory" else "file"
          val checksum = if (kind == "file") hashDocument(context, DocumentsContract.buildDocumentUriUsingTree(tree, id)) else ""
          result.add(Entry(path, kind, checksum, if (kind == "file" && !it.isNull(3)) it.getLong(3) else 0L))
          if (kind == "directory") walk(id, path)
        }
      }
    }
    walk(DocumentsContract.getTreeDocumentId(tree), "")
    return result
  }

  private fun listLocalFilesFile(dir: File): List<Entry> {
    if (!dir.isDirectory) throw SyncFailure("The selected folder cannot be listed. Reauthorize it in File Sync.", false)
    val result = mutableListOf<Entry>()
    fun walk(dir: File, prefix: String) {
      val children = dir.listFiles() ?: throw SyncFailure("The selected folder cannot be listed. Reauthorize it in File Sync.", false)
      for (child in children) {
        val name = child.name
        if (name.isBlank() || name == "." || name == ".." || name.contains('/')) continue
        if (java.nio.file.Files.isSymbolicLink(child.toPath())) continue
        val path = join(prefix, name)
        if (child.isDirectory) {
          walk(child, path)
        } else {
          val checksum = try {
            sha256(child)
          } catch (error: java.io.IOException) {
            throw SyncFailure("A file in the selected folder cannot be read.", false)
          }
          result.add(Entry(path, "file", checksum, child.length()))
        }
      }
    }
    walk(dir, "")
    return result
  }

  private fun hashDocument(context: Context, uri: Uri): String {
    val digest = MessageDigest.getInstance("SHA-256")
    context.contentResolver.openInputStream(uri)?.use { input ->
      val buffer = ByteArray(64 * 1024)
      while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
    } ?: throw SyncFailure("A file in the selected folder cannot be read.", false)
    return digest.digest().toHex()
  }

  private fun stageLocalFile(context: Context, folderUri: String, relative: String, expectedHash: String): File {
    val tree = Uri.parse(folderUri)
    if (tree.scheme == "file") {
      val source = File(File(requireNotNull(tree.path) { "The selected folder is invalid." }), relative)
      if (!source.isFile) throw SyncFailure("Selected file no longer exists: $relative", false)
      val target = File.createTempFile("filesync-", ".upload", context.cacheDir)
      try {
        FileInputStream(source).use { input -> FileOutputStream(target).use { input.copyTo(it) } }
        if (sha256(target) != expectedHash) throw SyncFailure("A local file changed while sync was preparing it. It will be checked again later.", true)
        return target
      } catch (error: Exception) { target.delete(); throw error }
    }
    val document = resolveDocument(context, tree, relative)
    val target = File.createTempFile("filesync-", ".upload", context.cacheDir)
    try {
      context.contentResolver.openInputStream(document)?.use { input -> FileOutputStream(target).use { input.copyTo(it) } }
        ?: throw SyncFailure("A selected file could not be opened.", false)
      if (sha256(target) != expectedHash) throw SyncFailure("A local file changed while sync was preparing it. It will be checked again later.", true)
      return target
    } catch (error: Exception) { target.delete(); throw error }
  }

  private fun installLocalFile(context: Context, folderUri: String, relative: String, staged: File) {
    val tree = Uri.parse(folderUri)
    if (tree.scheme == "file") {
      installLocalFileFile(File(requireNotNull(tree.path) { "The selected folder is invalid." }), safePath(relative).split('/'), staged)
      return
    }
    val parts = safePath(relative).split('/')
    var parentId = DocumentsContract.getTreeDocumentId(tree)
    for (part in parts.dropLast(1)) {
      val existing = findChild(context, tree, parentId, part)
      if (existing != null) {
        if (context.contentResolver.getType(existing) != DocumentsContract.Document.MIME_TYPE_DIR) {
          throw SyncFailure("A destination path is a file: $part", false)
        }
        parentId = DocumentsContract.getDocumentId(existing)
      } else {
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, parentId)
        val folder = DocumentsContract.createDocument(context.contentResolver, parent, DocumentsContract.Document.MIME_TYPE_DIR, part)
          ?: throw SyncFailure("Could not create a destination folder: $part", true)
        parentId = DocumentsContract.getDocumentId(folder)
      }
    }
    val parent = DocumentsContract.buildDocumentUriUsingTree(tree, parentId)
    val temporary = DocumentsContract.createDocument(context.contentResolver, parent, "application/octet-stream", ".filesync-${System.nanoTime()}.tmp")
      ?: throw SyncFailure("Could not create a temporary destination file.", true)
    try {
      context.contentResolver.openOutputStream(temporary, "wt")?.use { output -> FileInputStream(staged).use { it.copyTo(output) } }
        ?: throw SyncFailure("The destination file cannot be opened for writing.", false)
      val finalName = parts.last()
      val existing = findChild(context, tree, parentId, finalName)
      if (existing == null) {
        DocumentsContract.renameDocument(context.contentResolver, temporary, finalName)
          ?: throw SyncFailure("The storage provider cannot safely install this file.", false)
      } else {
        val backup = DocumentsContract.renameDocument(context.contentResolver, existing, ".filesync-${System.nanoTime()}.backup")
          ?: throw SyncFailure("The storage provider cannot safely replace this file.", false)
        try {
          DocumentsContract.renameDocument(context.contentResolver, temporary, finalName)
            ?: throw SyncFailure("Could not install the downloaded file.", true)
        } catch (error: Exception) {
          DocumentsContract.renameDocument(context.contentResolver, backup, finalName)
          throw error
        }
        runCatching { DocumentsContract.deleteDocument(context.contentResolver, backup) }
      }
    } catch (error: Exception) {
      runCatching { DocumentsContract.deleteDocument(context.contentResolver, temporary) }
      throw error
    }
  }

  private fun installLocalFileFile(dir: File, parts: List<String>, staged: File) {
    var current = dir
    for (part in parts.dropLast(1)) {
      current = File(current, part)
      if (!current.isDirectory && !current.mkdir()) throw SyncFailure("Could not create a destination folder: $part", true)
    }
    val temporary = File.createTempFile(".filesync-", ".tmp", current)
    try {
      FileInputStream(staged).use { input -> FileOutputStream(temporary).use { input.copyTo(it) } }
      val target = File(current, parts.last())
      val existing = if (target.isFile) target else null
      if (existing != null) {
        val backup = File(current, ".filesync-${System.nanoTime()}.backup")
        if (!existing.renameTo(backup)) throw SyncFailure("The selected folder cannot safely replace an existing file.", false)
        try {
          if (!temporary.renameTo(target)) throw SyncFailure("Could not install the downloaded file.", true)
        } catch (error: Exception) {
          backup.renameTo(target)
          throw error
        }
        backup.delete()
      } else if (!temporary.renameTo(target)) {
        throw SyncFailure("Could not install the downloaded file.", true)
      }
    } catch (error: Exception) {
      temporary.delete()
      throw error
    }
  }

  private fun resolveDocument(context: Context, tree: Uri, relative: String): Uri {
    var parentId = DocumentsContract.getTreeDocumentId(tree)
    var found: Uri? = null
    for (part in safePath(relative).split('/')) {
      val child = findChild(context, tree, parentId, part) ?: throw SyncFailure("Selected file no longer exists: $relative", false)
      parentId = DocumentsContract.getDocumentId(child)
      found = child
    }
    return found ?: throw SyncFailure("A file path is required.", false)
  }

  private fun findChild(context: Context, tree: Uri, parentId: String, name: String): Uri? {
    val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
    context.contentResolver.query(
      children,
      arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME),
      null, null, null,
    )?.use { cursor ->
      while (cursor.moveToNext()) {
        if (cursor.getString(1) == name) return DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0))
      }
    }
    return null
  }

  private fun hasTreeGrant(context: Context, raw: String): Boolean {
    val uri = Uri.parse(raw)
    if (uri.scheme == "file") return hasStorageAccess(context)
    if (uri.authority == EXTERNAL_STORAGE_PROVIDER && hasStorageAccess(context)) return true
    return context.contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission && it.isWritePermission }
  }

  private fun normalizeFolderUri(context: Context, raw: String): String {
    val uri = Uri.parse(raw)
    if (uri.scheme != "content" || uri.authority != EXTERNAL_STORAGE_PROVIDER) return raw
    val hasGrant = context.contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission && it.isWritePermission }
    if (hasGrant || !hasStorageAccess(context)) return raw
    val docId = runCatching { DocumentsContract.getTreeDocumentId(uri) }.getOrNull() ?: return raw
    if (!docId.startsWith("primary:")) return raw
    val relative = docId.removePrefix("primary:").trimEnd('/')
    if (relative.isEmpty() || relative.split('/').any { it.isEmpty() || it == "." || it == ".." }) return raw
    return Uri.fromFile(File(Environment.getExternalStorageDirectory(), relative)).toString()
  }

  private fun hasStorageAccess(context: Context): Boolean {
    if (Environment.isExternalStorageManager()) return true
    return Build.VERSION.SDK_INT < Build.VERSION_CODES.R &&
      context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
  }

  internal fun cleanupStagedFiles(context: Context) {
    val cutoff = System.currentTimeMillis() - TimeUnit.DAYS.toMillis(1)
    context.cacheDir.listFiles()?.filter { file ->
      file.name.startsWith("filesync-") && file.lastModified() < cutoff
    }?.forEach { file -> file.delete() }
  }

  private fun fileUrl(apiBase: String, path: String, root: String): URL =
    URL("$apiBase/api/v1/file?path=${encode(path)}&root=${encode(root)}")

  private fun request(
    url: URL,
    method: String,
    accessToken: String? = null,
    form: Map<String, String>? = null,
    file: File? = null,
    checksum: String? = null,
    streamToCache: File? = null,
    allowErrorBody: Boolean = false,
  ): HttpResponse {
    require(url.protocol == "https") { "Sync requests require HTTPS" }
    val connection = (url.openConnection() as HttpURLConnection).apply {
      requestMethod = method
      connectTimeout = HTTP_TIMEOUT_MS
      readTimeout = HTTP_TIMEOUT_MS
      instanceFollowRedirects = false
      setRequestProperty("User-Agent", "NixHomeServer-FileSync-Android/0.1")
      accessToken?.let { setRequestProperty("Authorization", "Bearer $it") }
    }
    try {
      when {
        form != null -> {
          connection.doOutput = true
          connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
          val encoded = form.entries.joinToString("&") { "${encode(it.key)}=${encode(it.value)}" }.toByteArray(Charsets.UTF_8)
          connection.setFixedLengthStreamingMode(encoded.size)
          connection.outputStream.use { it.write(encoded) }
        }
        file != null -> {
          connection.doOutput = true
          connection.setRequestProperty("x-filesync-sha256", checksum)
          connection.setChunkedStreamingMode(64 * 1024)
          FileInputStream(file).use { input -> connection.outputStream.use { input.copyTo(it) } }
        }
      }
      val code = connection.responseCode
      val stream = if (code in 200..299) connection.inputStream else connection.errorStream
      if (streamToCache != null && code in 200..299) {
        val staged = File.createTempFile("filesync-", ".download", streamToCache)
        try { stream?.use { input -> FileOutputStream(staged).use { input.copyTo(it) } } ?: throw SyncFailure("The download response was empty.", true) }
        catch (error: Exception) { staged.delete(); throw error }
        return HttpResponse(code, "", staged)
      }
      val body = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
      if (code !in 200..299 && !allowErrorBody) return HttpResponse(code, body)
      return HttpResponse(code, body)
    } finally { connection.disconnect() }
  }

  private fun failHttp(code: Int, message: String): Nothing {
    when (code) {
      401, 403 -> throw SyncFailure("The sync server no longer accepts this session or folder access. Open File Sync and sign in again.", false)
      in 500..599, 408, 429 -> throw SyncFailure("$message (HTTP $code). Background sync will retry.", true)
      else -> throw SyncFailure("$message (HTTP $code).", false)
    }
  }

  private fun safePath(value: String): String {
    val clean = value.trim('/')
    if (clean.isEmpty()) return ""
    require(!clean.contains('\\') && !clean.contains('\u0000') && clean.split('/').all { it.isNotEmpty() && it != "." && it != ".." }) { "Invalid sync path" }
    return clean
  }

  private fun safeRoot(value: String): String {
    require(value.isNotEmpty() && value.all { it.isLowerCase() || it.isDigit() || it == '-' || it == '_' || it == '.' }) { "Invalid server root" }
    return value
  }

  private fun join(left: String, right: String): String = listOf(left.trim('/'), right.trim('/')).filter { it.isNotEmpty() }.joinToString("/")
  private fun encode(value: String): String = URLEncoder.encode(value, "UTF-8")
  private fun epochSeconds(): Long = System.currentTimeMillis() / 1000L
  private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).toHex()
  private fun sha256(file: File): String = MessageDigest.getInstance("SHA-256").let { digest ->
    FileInputStream(file).use { input ->
      val buffer = ByteArray(64 * 1024)
      while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
    }
    digest.digest().toHex()
  }
  private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

  private data class Entry(val path: String, val kind: String, val sha256: String, val size: Long)
  internal data class StorageStats(val freeBytes: Long, val totalBytes: Long)

  fun storageStats(context: Context): StorageStats {
    // Sync destinations live on shared storage, so measure that volume.
    // A SAF folder on removable media may sit elsewhere; treat this as the
    // primary-volume estimate and let the pre-sync check stay conservative.
    val stat = StatFs(Environment.getExternalStorageDirectory().path)
    return StorageStats(
      freeBytes = stat.availableBlocksLong * stat.blockSizeLong,
      totalBytes = stat.blockCountLong * stat.blockSizeLong,
    )
  }

  fun estimatePair(context: Context, pairJson: String): Map<String, Any> {
    var locked = false
    try {
      acquireSyncLock()
      locked = true
      val pair = JSONObject(pairJson)
      val session = currentSession(context)
      val plan = loadPlan(context, session, pair)
      val localEntries = listLocalFiles(context, plan.folderUri).filter { entry ->
        entry.kind == "file" && (plan.deviceSubpath.isEmpty() || entry.path.startsWith("${plan.deviceSubpath}/"))
      }.associateBy { entry -> if (plan.deviceSubpath.isEmpty()) entry.path else entry.path.removePrefix("${plan.deviceSubpath}/") }
      val remoteEntries = fetchRemoteTree(plan.apiBase, plan.accessToken, plan.serverPath, plan.root)
        .filter { it.kind == "file" }.associateBy { it.path }
      var pendingBytes = 0L
      var pendingCount = 0
      var skipped = 0
      if (plan.direction == "phone-to-server") {
        for ((relative, entry) in localEntries) {
          if (remoteEntries[relative]?.sha256 == entry.sha256) { skipped++; continue }
          pendingBytes += entry.size
          pendingCount++
        }
      } else {
        for ((relative, entry) in remoteEntries) {
          if (localEntries[relative]?.sha256 == entry.sha256) { skipped++; continue }
          pendingBytes += entry.size
          pendingCount++
        }
      }
      val stats = storageStats(context)
      return mapOf(
        "pendingBytes" to pendingBytes,
        "pendingCount" to pendingCount,
        "skipped" to skipped,
        "direction" to plan.direction,
        "freeBytes" to stats.freeBytes,
        "totalBytes" to stats.totalBytes,
      )
    } catch (error: InterruptedException) {
      Thread.currentThread().interrupt()
      throw SyncFailure("Size check was interrupted.", true)
    } finally {
      if (locked) releaseSyncLock()
    }
  }
  private data class HttpResponse(val code: Int, val body: String, val file: File? = null)
}

internal class SyncFailure(message: String, val retryable: Boolean) : Exception(message)
