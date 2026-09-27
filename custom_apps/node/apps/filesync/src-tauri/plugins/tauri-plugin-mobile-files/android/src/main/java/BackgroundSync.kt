package org.nixhomeserver.filesync.mobilefiles

import android.content.Context
import android.app.NotificationChannel
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

private const val PAIRS_SLOT = "background-sync-pairs"
private const val SESSION_SLOT = "oidc-session"
private const val STATUS_SLOT = "background-sync-status"
private const val PERIODIC_WORK = "filesync-periodic"
private const val IMMEDIATE_WORK = "filesync-immediate"
private const val HTTP_TIMEOUT_MS = 30_000

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

  fun acquireSyncLock() = syncLock.acquire()
  fun releaseSyncLock() = syncLock.release()

  fun updateConfiguration(context: Context, pairsJson: String, enabled: Boolean) {
    acquireSyncLock()
    try {
      SecureSecrets.store(context, PAIRS_SLOT, pairsJson)
      val hasSession = !SecureSecrets.load(context, SESSION_SLOT).isNullOrBlank()
      BackgroundSyncScheduler.update(context, enabled && hasSession)
    } finally {
      releaseSyncLock()
    }
  }

  fun syncPair(context: Context, pairJson: String): JSONObject {
    var locked = false
    try {
      acquireSyncLock()
      locked = true
      val pair = JSONObject(pairJson)
      val session = currentSession(context)
      val result = syncOne(context, session, pair)
      writeStatus(context, "Last sync finished: ${result.getInt("transferred")} files copied.")
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
      for (index in 0 until pairs.length()) {
        val pair = pairs.getJSONObject(index)
        try {
          val result = syncOne(context, session, pair)
          transferred += result.getInt("transferred")
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

  private fun syncOne(context: Context, session: JSONObject, pair: JSONObject): JSONObject {
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
    val folderUri = pair.getJSONObject("local").getString("uri")
    val folderSlot = "folder-${sha256(folderUri.toByteArray()).take(32)}"
    if (SecureSecrets.load(context, folderSlot) != folderUri || !hasTreeGrant(context, folderUri)) {
      throw SyncFailure("Folder access expired. Open File Sync and choose the device folder again.", false)
    }
    val identity = request(URL("$apiBase/api/v1/me"), "GET", accessToken = session.getString("accessToken"))
    if (JSONObject(identity.body).optString("username") != account) {
      throw SyncFailure("This folder pair belongs to another Kanidm account.", false)
    }
    val localSubpath = safePath(pair.optString("localSubpath"))
    val serverPath = safePath(pair.optString("serverPath"))
    val root = safeRoot(pair.optString("serverRoot", "files"))
    val localEntries = listLocalFiles(context, folderUri).filter { entry ->
      entry.kind == "file" && (localSubpath.isEmpty() || entry.path.startsWith("$localSubpath/"))
    }.associateBy { entry -> if (localSubpath.isEmpty()) entry.path else entry.path.removePrefix("$localSubpath/") }
    val remoteEntries = fetchRemoteTree(apiBase, session.getString("accessToken"), serverPath, root)
      .filter { it.kind == "file" }.associateBy { it.path }
    var transferred = 0
    var skipped = 0
    if (direction == "phone-to-server") {
      for ((relative, entry) in localEntries) {
        if (remoteEntries[relative]?.sha256 == entry.sha256) { skipped++; continue }
        val staged = stageLocalFile(context, folderUri, join(localSubpath, relative), entry.sha256)
        try {
          val target = join(serverPath, relative)
          val response = request(
            fileUrl(apiBase, target, root), "PUT", accessToken = session.getString("accessToken"),
            file = staged, checksum = entry.sha256,
          )
          if (response.code !in 200..299) failHttp(response.code, "The server could not save $relative")
          transferred++
        } finally { staged.delete() }
      }
    } else {
      for ((relative, entry) in remoteEntries) {
        if (localEntries[relative]?.sha256 == entry.sha256) { skipped++; continue }
        val response = request(fileUrl(apiBase, join(serverPath, relative), root), "GET", accessToken = session.getString("accessToken"), streamToCache = context.cacheDir)
        if (response.code !in 200..299) failHttp(response.code, "The server could not provide $relative")
        val staged = response.file ?: throw SyncFailure("The download could not be staged.", true)
        try {
          if (sha256(staged) != entry.sha256) throw SyncFailure("Downloaded file failed its checksum: $relative", true)
          installLocalFile(context, folderUri, join(localSubpath, relative), staged)
          transferred++
        } finally { staged.delete() }
      }
    }
    return JSONObject().put("transferred", transferred).put("skipped", skipped).put("direction", direction)
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
        ))
      }
    }
    return result
  }

  private fun listLocalFiles(context: Context, folderUri: String): List<Entry> {
    val tree = Uri.parse(folderUri)
    val result = mutableListOf<Entry>()
    fun walk(parentId: String, prefix: String) {
      val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
      val projection = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
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
          result.add(Entry(path, kind, checksum))
          if (kind == "directory") walk(id, path)
        }
      }
    }
    walk(DocumentsContract.getTreeDocumentId(tree), "")
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

  private fun hasTreeGrant(context: Context, raw: String): Boolean =
    context.contentResolver.persistedUriPermissions.any { it.uri == Uri.parse(raw) && it.isReadPermission && it.isWritePermission }

  private fun cleanupStagedFiles(context: Context) {
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

  private data class Entry(val path: String, val kind: String, val sha256: String)
  private data class HttpResponse(val code: Int, val body: String, val file: File? = null)
}

internal class SyncFailure(message: String, val retryable: Boolean) : Exception(message)
