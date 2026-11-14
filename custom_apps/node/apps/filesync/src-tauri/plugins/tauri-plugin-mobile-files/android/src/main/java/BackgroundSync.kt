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
// The size check may hash changed files on the server before it answers.
private const val ESTIMATE_TIMEOUT_MS = 180_000
private const val TRANSFER_READ_TIMEOUT_MS = 60_000
private const val NETWORK_ATTEMPTS = 3
private const val RETRY_DELAY_MS = 2_000L
private const val PROGRESS_NOTIFY_INTERVAL_MS = 750L
private const val COPY_BUFFER_BYTES = 128 * 1024
// Temporary and backup names File Sync writes into the user's folder.
private const val INTERNAL_FILE_PREFIX = ".filesync-"
private const val SYNC_CHANNEL_ID = "filesync-sync"
private const val WORKER_NOTIFICATION_ID = 41
private const val MANUAL_NOTIFICATION_ID = 42
// Downloads may use at most this share of the device's free space.
private const val DOWNLOAD_SPACE_FRACTION = 0.99

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
    // Android 12+ refuses to start a foreground service from the background
    // for ordinary periodic work. The sync can still run as a normal worker,
    // so a refusal must not end the run before it starts.
    runCatching { setForeground(foregroundInfo()) }
    return withContext(Dispatchers.IO) {
      try {
        SyncEngine.syncAll(applicationContext)
        androidx.work.ListenableWorker.Result.success()
      } catch (error: SyncFailure) {
        SyncEngine.writeStatus(applicationContext, error.message ?: "Background sync could not finish.")
        if (error.needsSignIn) BackgroundSyncScheduler.update(applicationContext, false)
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
  /** One sync at a time; size checks do not take it, so they never wait on a long sync. */
  private val syncLock = Semaphore(1)
  /**
   * Guards the stored session while a refresh rotates its refresh token. Kept
   * separate from [syncLock] so a long sync never blocks sign-in, sign-out or
   * the app's own API calls waiting to refresh a token.
   */
  private val sessionLock = Semaphore(1)

  @Volatile private var memoryProgress: String? = null
  @Volatile private var lastNotificationAt = 0L
  /** The account behind the last access token checked against `/me`. */
  @Volatile private var verifiedIdentity: Pair<String, String>? = null

  fun acquireSessionLock() = sessionLock.acquire()
  fun releaseSessionLock() = sessionLock.release()

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
    // Android drops notification updates posted faster than a few per second,
    // and building each one costs more than copying a small file.
    val now = System.currentTimeMillis()
    if (currentFile.isNotBlank() && now - lastNotificationAt < PROGRESS_NOTIFY_INTERVAL_MS) return
    lastNotificationAt = now
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
      syncLock.acquire()
      locked = true
      val pair = JSONObject(pairJson)
      val tokens = TokenSource(context)
      val pairName = pair.optString("name", "Folder pair").ifBlank { "Folder pair" }
      reportProgress(context, MANUAL_NOTIFICATION_ID, pairName, listOf(pairName),
        pair.optString("direction"), "", 0, 0)
      val result = syncOne(context, tokens, pair, MANUAL_NOTIFICATION_ID)
      writeStatus(context, "Last sync finished: ${result["transferred"] as Int} files copied.")
      return result
    } catch (error: InterruptedException) {
      Thread.currentThread().interrupt()
      throw SyncFailure("Sync was interrupted.", true)
    } catch (error: SyncFailure) {
      writeStatus(context, error.message ?: "Sync could not finish.")
      if (error.needsSignIn) BackgroundSyncScheduler.update(context, false)
      throw error
    } catch (error: Exception) {
      writeStatus(context, "Sync could not finish. Open File Sync to review the connection and folder access.")
      throw SyncFailure("Sync could not finish: ${error.message ?: "check the server and folder access"}.", true)
    } finally {
      clearProgress(context, MANUAL_NOTIFICATION_ID)
      if (locked) syncLock.release()
    }
  }

  fun syncAll(context: Context) {
    var locked = false
    try {
      syncLock.acquire()
      locked = true
      val config = SecureSecrets.load(context, PAIRS_SLOT)
      val pairs = if (config.isNullOrBlank()) JSONArray() else JSONArray(config)
      if (pairs.length() == 0) {
        writeStatus(context, "Background sync is off because no folder pairs are saved.")
        return
      }
      val tokens = TokenSource(context)
      cleanupStagedFiles(context)
      var transferred = 0
      var completedPairs = 0
      var retryableFailure = false
      val warnings = mutableListOf<String>()
      val activeNames = (0 until pairs.length())
        .map { pairs.getJSONObject(it).optString("name", "Folder pair").ifBlank { "Folder pair" } }
      for (index in 0 until pairs.length()) {
        val pair = pairs.getJSONObject(index)
        try {
          val result = syncOne(context, tokens, pair, WORKER_NOTIFICATION_ID, activeNames)
          transferred += result["transferred"] as Int
          completedPairs++
        } catch (error: SyncFailure) {
          if (error.needsSignIn) throw error
          retryableFailure = retryableFailure || error.retryable
          warnings.add("${pair.optString("name", "Folder pair")}: ${error.message ?: "needs attention"}")
        }
      }
      if (completedPairs == 0 && warnings.isNotEmpty()) {
        // Keep WorkManager's retry and periodic checks alive after temporary
        // server failures. Only persistent pair errors require user repair.
        if (retryableFailure) throw SyncFailure(warnings.joinToString(" "), true)
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
      if (locked) syncLock.release()
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

  /**
   * Return a session whose access token is good for at least another minute.
   *
   * [rejectedToken] is a token the server just refused: if the stored session
   * still holds it, it is refreshed even though it has not expired. Another
   * caller may have refreshed while this one waited for the lock, in which case
   * the newer session is used as is — refreshing again would spend a rotated
   * refresh token twice.
   */
  private fun currentSession(context: Context, rejectedToken: String? = null): JSONObject {
    sessionLock.acquire()
    try {
      val raw = SecureSecrets.load(context, SESSION_SLOT)
        ?: throw SyncFailure("Sign in with Kanidm to resume background sync.", false, needsSignIn = true)
      val session = JSONObject(raw)
      val fresh = session.optLong("expiresAt") > epochSeconds() + 60
      val refused = rejectedToken != null && session.optString("accessToken") == rejectedToken
      if (fresh && !refused) return session
      val form = mapOf(
        "grant_type" to "refresh_token",
        "client_id" to session.getString("clientId"),
        "refresh_token" to session.getString("refreshToken"),
      )
      val response = try {
        request(URL(session.getString("tokenEndpoint")), "POST", form = form)
      } catch (error: java.io.IOException) {
        throw SyncFailure("Kanidm could not be reached to refresh the session. Sync will retry.", true)
      }
      if (response.code !in 200..299) {
        val oauthError = runCatching { JSONObject(response.body).optString("error") }.getOrNull()
        if (oauthError == "invalid_grant") {
          SecureSecrets.clear(context, SESSION_SLOT)
          throw SyncFailure("Kanidm session expired or was revoked. Sign in again to resume background sync.", false, needsSignIn = true)
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
    } finally {
      sessionLock.release()
    }
  }

  /**
   * Hands out an access token that is valid *now*.
   *
   * A sync used to read the token once and use it for its whole run. A
   * library larger than the token's lifetime then failed part way with 401,
   * which read as "sign in again" and switched background sync off.
   */
  private class TokenSource(private val context: Context) {
    private var session = currentSession(context)
    val apiBase: String get() = session.getString("apiBase").trimEnd('/')
    /** The account the current pair belongs to, once [loadPlan] verified it. */
    private var account: String? = null
    private var checkedToken: String? = null

    fun token(): String {
      if (session.optLong("expiresAt") <= epochSeconds() + 60) session = currentSession(context)
      return verified(session.getString("accessToken"))
    }

    fun refreshAfterRejection(rejected: String): String {
      session = currentSession(context, rejectedToken = rejected)
      return verified(session.getString("accessToken"))
    }

    fun bind(account: String, token: String) {
      this.account = account
      checkedToken = token
    }

    /**
     * Sign-in no longer waits for a running sync, so a new token may belong to
     * someone else. Check it before a single file moves under it.
     */
    private fun verified(token: String): String {
      val expected = account ?: return token
      if (token == checkedToken) return token
      val response = request(URL("$apiBase/api/v1/me"), "GET", token)
      if (response.code !in 200..299) failHttp(response.code, "The sync account could not be checked.")
      if (JSONObject(response.body).optString("username") != expected) {
        throw SyncFailure("A different account signed in while File Sync was syncing, so the sync stopped.", false)
      }
      checkedToken = token
      return token
    }
  }

  /** [request] with the current token, refreshing once if the server rejects it. */
  private fun authed(
    tokens: TokenSource,
    url: URL,
    method: String,
    json: String? = null,
    file: File? = null,
    checksum: String? = null,
    readTimeoutMs: Int = HTTP_TIMEOUT_MS,
  ): HttpResponse {
    val token = tokens.token()
    val first = request(url, method, token, json = json, file = file, checksum = checksum, readTimeoutMs = readTimeoutMs)
    if (first.code != 401) return first
    val renewed = tokens.refreshAfterRejection(token)
    return request(url, method, renewed, json = json, file = file, checksum = checksum, readTimeoutMs = readTimeoutMs)
  }

  private data class SyncPlan(
    val pairName: String,
    val direction: String,
    val apiBase: String,
    val folderUri: String,
    val deviceSubpath: String,
    val serverPath: String,
    val root: String,
  )

  private fun loadPlan(context: Context, tokens: TokenSource, pair: JSONObject): SyncPlan {
    val pairName = pair.optString("name", "Folder pair").ifBlank { "Folder pair" }
    val direction = pair.getString("direction")
    if (direction != "phone-to-server" && direction != "server-to-phone") {
      throw SyncFailure("This sync direction is not supported for background sync.", false)
    }
    val account = pair.optString("account")
    if (account.isBlank()) throw SyncFailure("This folder pair needs to be recreated before background sync.", false)
    val apiBase = tokens.apiBase
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
    if (signedInAccount(tokens, apiBase) != account) {
      throw SyncFailure("This folder pair belongs to another Kanidm account.", false)
    }
    tokens.bind(account, tokens.token())
    val localSubpath = safePath(pair.optString("localSubpath"))
    val deviceSubpath = if (folderUri.startsWith("content")) localSubpath else ""
    return SyncPlan(
      pairName = pairName,
      direction = direction,
      apiBase = apiBase,
      folderUri = folderUri,
      deviceSubpath = deviceSubpath,
      serverPath = safePath(pair.optString("serverPath")),
      root = safeRoot(pair.optString("serverRoot", "files")),
    )
  }

  /** The account behind the current token, asked of the server once per token. */
  private fun signedInAccount(tokens: TokenSource, apiBase: String): String {
    val token = tokens.token()
    verifiedIdentity?.let { (checked, username) -> if (checked == token) return username }
    val identity = withRetries("The sync account check") { authed(tokens, URL("$apiBase/api/v1/me"), "GET") }
    if (identity.code !in 200..299) failHttp(identity.code, "The sync account could not be checked.")
    val username = JSONObject(identity.body).optString("username")
    verifiedIdentity = tokens.token() to username
    return username
  }

  private fun downloadLimit(freeBytes: Long): Long =
    (freeBytes * DOWNLOAD_SPACE_FRACTION).toLong().coerceAtLeast(0L)

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

  /** The device side of one pair: its files keyed by path relative to the pair. */
  private class LocalView(
    val plan: SyncPlan,
    /** Every listed entry, keyed by its path inside the selected folder. */
    val all: Map<String, Entry>,
    /** Files under the pair's subfolder, keyed by path relative to it. */
    val files: Map<String, Entry>,
  ) {
    fun devicePath(relative: String): String =
      if (plan.deviceSubpath.isEmpty()) relative else "${plan.deviceSubpath}/$relative"
  }

  private fun localView(context: Context, plan: SyncPlan): LocalView {
    val all = listLocalFiles(context, plan.folderUri).associateBy { it.path }
    val prefix = if (plan.deviceSubpath.isEmpty()) "" else "${plan.deviceSubpath}/"
    val files = all.values
      .filter { it.kind == "file" && it.path.startsWith(prefix) }
      .associateBy { it.path.removePrefix(prefix) }
    return LocalView(plan, all, files)
  }

  /** SHA-256 of a device file, from the cache when its size and mtime are unchanged. */
  private fun localHash(context: Context, view: LocalView, cache: HashCache, relative: String): String {
    val entry = view.files[relative] ?: throw SyncFailure("Selected file no longer exists: $relative", false)
    val devicePath = view.devicePath(relative)
    cache.get(devicePath, entry.size, entry.modifiedUnixMs)?.let { return it }
    val tree = Uri.parse(view.plan.folderUri)
    val hash = if (tree.scheme == "file") {
      val file = File(File(requireNotNull(tree.path) { "The selected folder is invalid." }), devicePath)
      if (!file.isFile) throw SyncFailure("Selected file no longer exists: $relative", false)
      try { sha256(file) } catch (error: java.io.IOException) {
        throw SyncFailure("A file in the selected folder cannot be read: $relative", false)
      }
    } else {
      hashDocument(context, documentUri(context, tree, devicePath, entry))
    }
    cache.put(devicePath, entry.size, entry.modifiedUnixMs, hash)
    return hash
  }

  private fun documentUri(context: Context, tree: Uri, devicePath: String, entry: Entry?): Uri =
    if (entry != null && entry.documentId.isNotEmpty()) DocumentsContract.buildDocumentUriUsingTree(tree, entry.documentId)
    else resolveDocument(context, tree, devicePath)

  /**
   * Ask the server what differs, settling metadata mismatches with hashes.
   *
   * The first pass sends only `(path, size, mtime)`. Files the server cannot
   * decide on come back as `needsHash` and are answered from the device hash
   * cache, so a library that is already in sync is never re-read.
   */
  private fun diffWithServer(
    context: Context,
    tokens: TokenSource,
    view: LocalView,
    cache: HashCache,
    list: Boolean,
  ): EstimateData {
    val local = view.files.map { (relative, entry) -> LocalFile(relative, entry.size, entry.modifiedUnixMs, null) }
      .sortedBy { it.path }
    var data = postEstimate(tokens, view.plan, local, list)
    if (data.needsHash.isNotEmpty()) {
      val wanted = data.needsHash.toSet()
      val settled = local.map { file ->
        if (file.path in wanted) file.copy(hash = localHash(context, view, cache, file.path)) else file
      }
      data = postEstimate(tokens, view.plan, settled, list)
      if (data.needsHash.isNotEmpty()) {
        throw SyncFailure(
          "${data.needsHash.take(3).joinToString(", ")} could not be compared with the server. Sync to review it.",
          true,
        )
      }
    }
    return data
  }

  private fun syncOne(
    context: Context,
    tokens: TokenSource,
    pair: JSONObject,
    notificationId: Int,
    activePairs: List<String>? = null,
  ): Map<String, Any> {
    val plan = loadPlan(context, tokens, pair)
    val names = activePairs ?: listOf(plan.pairName)
    var transferred = 0
    var skipped = 0
    fun progress(currentFile: String) {
      reportProgress(context, notificationId, plan.pairName, names, plan.direction, currentFile, transferred, skipped)
    }
    progress("")
    val cache = HashCache.open(context, plan)
    try {
      val view = localView(context, plan)
      cache.retainOnly(view.files.keys.map { view.devicePath(it) }.toSet())
      val data = diffWithServer(context, tokens, view, cache, list = true)
      val pending = data.pending
      // Servers without the pending list, or a folder too large to walk in
      // one go, fall back to comparing full listings.
      if (pending == null || data.truncated) {
        return legacySync(context, tokens, view, cache, ::progress, { transferred = it }, { skipped = it })
      }
      skipped = data.skipped
      if (plan.direction == "phone-to-server") {
        // The server could not read its own copy of these, so it cannot tell
        // whether they changed; uploading replaces them either way.
        val uploads = pending.map { it.path } + data.unreadable
        for (relative in uploads.distinct()) {
          if (view.files[relative] == null) continue
          progress(relative)
          uploadOne(context, tokens, view, cache, relative)
          transferred++
        }
      } else {
        val blockLimit = checkDownloadSpace(context, plan, data.pendingBytes)
        val docIndex = DocumentIndex(view.all)
        var writtenBytes = 0L
        for (item in pending) {
          // A server-side upload in progress (or abandoned) is not user data.
          if (item.path.split('/').any { it.startsWith(INTERNAL_FILE_PREFIX) }) continue
          progress(item.path)
          writtenBytes += downloadOne(context, tokens, view, cache, docIndex, item.path, item.mtimeUnixMs)
          if (writtenBytes > blockLimit) throw outOfSpace(plan.pairName, writtenBytes)
          transferred++
        }
        if (data.unreadable.isNotEmpty()) {
          throw SyncFailure(
            "${data.unreadable.take(3).joinToString(", ")} could not be read on the server and was not copied. Sync will retry.",
            true,
          )
        }
      }
      return mapOf("transferred" to transferred, "skipped" to skipped, "direction" to plan.direction)
    } finally {
      cache.save()
    }
  }

  private fun checkDownloadSpace(context: Context, plan: SyncPlan, pendingBytes: Long): Long {
    val stats = storageStats(context)
    val blockLimit = downloadLimit(stats.freeBytes)
    if (pendingBytes > 0 && pendingBytes > blockLimit) {
      throw SyncFailure(
        "Not enough free space: “${plan.pairName}” needs ${formatBytes(pendingBytes)} but this " +
          "device has ${formatBytes(stats.freeBytes)} free. Free up space, then sync again.",
        false,
      )
    }
    return blockLimit
  }

  private fun outOfSpace(pairName: String, writtenBytes: Long) = SyncFailure(
    "Sync stopped: “$pairName” ran out of free space after ${formatBytes(writtenBytes)}. " +
      "Free up space, then sync again.",
    false,
  )

  /** Stage, hash and upload one device file, retrying transient failures. */
  private fun uploadOne(context: Context, tokens: TokenSource, view: LocalView, cache: HashCache, relative: String) {
    val plan = view.plan
    val entry = view.files[relative] ?: return
    withRetries(relative) {
      val (staged, hash) = localStep("read $relative") { stageLocalFile(context, view, relative) }
      try {
        val response = authed(
          tokens, fileUrl(plan.apiBase, join(plan.serverPath, relative), plan.root), "PUT",
          file = staged, checksum = hash, readTimeoutMs = TRANSFER_READ_TIMEOUT_MS,
        )
        if (response.code !in 200..299) failHttp(response.code, "The server could not save $relative")
        // Only cache the hash if the file did not change while it was copied;
        // otherwise the next sync compares it afresh.
        if (localMetadata(context, view, relative, entry) == Installed(entry.size, entry.modifiedUnixMs)) {
          cache.put(view.devicePath(relative), entry.size, entry.modifiedUnixMs, hash)
        }
      } finally {
        staged.delete()
      }
    }
  }

  /** Download and install one server file; returns the bytes written. */
  private fun downloadOne(
    context: Context,
    tokens: TokenSource,
    view: LocalView,
    cache: HashCache,
    docIndex: DocumentIndex?,
    relative: String,
    serverMtime: Long,
    expectedHash: String? = null,
  ): Long {
    val plan = view.plan
    return withRetries(relative) {
      val download = downloadToCache(context, tokens, fileUrl(plan.apiBase, join(plan.serverPath, relative), plan.root), relative)
      try {
        if (expectedHash != null && download.sha256 != expectedHash) {
          throw SyncFailure("Downloaded file failed its checksum: $relative", true)
        }
        val devicePath = view.devicePath(relative)
        val installed = localStep("save $relative") {
          installLocalFile(context, plan.folderUri, devicePath, download.file, serverMtime, docIndex)
        }
        cache.put(devicePath, installed.size, installed.modifiedUnixMs, download.sha256)
        download.file.length()
      } finally {
        download.file.delete()
      }
    }
  }

  /**
   * The previous engine: list the whole server folder with hashes and compare.
   *
   * Only used against servers that cannot return the pending list. Device
   * hashes still come from the cache, so it no longer re-reads the device.
   */
  private fun legacySync(
    context: Context,
    tokens: TokenSource,
    view: LocalView,
    cache: HashCache,
    progress: (String) -> Unit,
    setTransferred: (Int) -> Unit,
    setSkipped: (Int) -> Unit,
  ): Map<String, Any> {
    val plan = view.plan
    val remoteEntries = fetchRemoteTree(tokens, plan.apiBase, plan.serverPath, plan.root)
      .filter { it.kind == "file" }.associateBy { it.path }
    var transferred = 0
    var skipped = 0
    if (plan.direction == "phone-to-server") {
      for (relative in view.files.keys) {
        val remote = remoteEntries[relative]
        if (remote != null && remote.sha256 == localHash(context, view, cache, relative)) { skipped++; setSkipped(skipped); continue }
        progress(relative)
        uploadOne(context, tokens, view, cache, relative)
        transferred++
        setTransferred(transferred)
      }
    } else {
      val pending = remoteEntries.filter { (relative, entry) ->
        view.files[relative] == null || localHash(context, view, cache, relative) != entry.sha256
      }.toList()
      skipped = remoteEntries.size - pending.size
      setSkipped(skipped)
      val blockLimit = checkDownloadSpace(context, plan, pending.sumOf { (_, entry) -> entry.size })
      val docIndex = DocumentIndex(view.all)
      var writtenBytes = 0L
      for ((relative, entry) in pending) {
        progress(relative)
        writtenBytes += downloadOne(context, tokens, view, cache, docIndex, relative, entry.modifiedUnixMs, entry.sha256)
        if (writtenBytes > blockLimit) throw outOfSpace(plan.pairName, writtenBytes)
        transferred++
        setTransferred(transferred)
      }
    }
    return mapOf("transferred" to transferred, "skipped" to skipped, "direction" to plan.direction)
  }

  private fun fetchRemoteTree(tokens: TokenSource, apiBase: String, base: String, root: String): List<Entry> {
    val result = mutableListOf<Entry>()
    val pending = ArrayDeque<String>()
    pending.add(base)
    while (pending.isNotEmpty()) {
      val directory = pending.removeLast()
      val url = URL("$apiBase/api/v1/tree?path=${encode(directory)}&root=${encode(root)}&hashes=true")
      // The old server hashes every file in the folder for this listing.
      val response = withRetries("The server folder listing") { authed(tokens, url, "GET", readTimeoutMs = ESTIMATE_TIMEOUT_MS) }
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
          modifiedUnixMs = item.optLong("modifiedUnixMs"),
        ))
      }
    }
    return result
  }

  /**
   * List the device's files under [folderUri], without reading any content.
   *
   * File Sync's own temporary and backup files (`.filesync-*`) are left out:
   * an interrupted install could otherwise leave one behind to be uploaded,
   * and a size check running during a sync would count half-written files.
   */
  private fun listLocalFiles(context: Context, folderUri: String): List<Entry> {
    val tree = Uri.parse(folderUri)
    if (tree.scheme == "file") return listLocalFilesFile(File(requireNotNull(tree.path) { "The selected folder is invalid." }))
    val result = mutableListOf<Entry>()
    val projection = arrayOf(
      DocumentsContract.Document.COLUMN_DOCUMENT_ID,
      DocumentsContract.Document.COLUMN_DISPLAY_NAME,
      DocumentsContract.Document.COLUMN_MIME_TYPE,
      DocumentsContract.Document.COLUMN_SIZE,
      DocumentsContract.Document.COLUMN_LAST_MODIFIED,
    )
    fun walk(parentId: String, prefix: String) {
      val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
      val cursor = context.contentResolver.query(children, projection, null, null, null)
        ?: throw SyncFailure("The selected folder cannot be listed. Reauthorize it in File Sync.", false)
      val directories = mutableListOf<Pair<String, String>>()
      cursor.use {
        while (it.moveToNext()) {
          val id = it.getString(0)
          val name = it.getString(1) ?: continue
          if (!usableName(name)) continue
          val path = join(prefix, name)
          val kind = if (it.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) "directory" else "file"
          result.add(
            Entry(
              path,
              kind,
              "",
              if (kind == "file" && !it.isNull(3)) it.getLong(3) else 0L,
              if (kind == "file" && !it.isNull(4)) it.getLong(4) else 0L,
              id,
            ),
          )
          if (kind == "directory") directories.add(id to path)
        }
      }
      // Recurse after closing this cursor so deep trees do not hold one
      // provider cursor open per level.
      for ((id, path) in directories) walk(id, path)
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
        if (!usableName(name)) continue
        if (java.nio.file.Files.isSymbolicLink(child.toPath())) continue
        val path = join(prefix, name)
        if (child.isDirectory) {
          result.add(Entry(path, "directory", "", 0L, 0L))
          walk(child, path)
        } else {
          result.add(Entry(path, "file", "", child.length(), child.lastModified()))
        }
      }
    }
    walk(dir, "")
    return result
  }

  private fun usableName(name: String): Boolean =
    name.isNotBlank() && name != "." && name != ".." && !name.contains('/') && !name.startsWith(INTERNAL_FILE_PREFIX)

  private fun hashDocument(context: Context, uri: Uri): String {
    val digest = MessageDigest.getInstance("SHA-256")
    context.contentResolver.openInputStream(uri)?.use { input ->
      val buffer = ByteArray(COPY_BUFFER_BYTES)
      while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
    } ?: throw SyncFailure("A file in the selected folder cannot be read.", false)
    return digest.digest().toHex()
  }

  /**
   * Copy a device file into private cache, hashing it on the way.
   *
   * The upload sends the staged copy, so its hash is the one the server must
   * see — reading the file once for both avoids a second pass over it.
   */
  private fun stageLocalFile(context: Context, view: LocalView, relative: String): Pair<File, String> {
    val devicePath = view.devicePath(relative)
    val tree = Uri.parse(view.plan.folderUri)
    val input = if (tree.scheme == "file") {
      val source = File(File(requireNotNull(tree.path) { "The selected folder is invalid." }), devicePath)
      if (!source.isFile) throw SyncFailure("Selected file no longer exists: $relative", false)
      FileInputStream(source)
    } else {
      context.contentResolver.openInputStream(documentUri(context, tree, devicePath, view.files[relative]))
        ?: throw SyncFailure("A selected file could not be opened.", false)
    }
    val target = File.createTempFile("filesync-", ".upload", context.cacheDir)
    try {
      val hash = input.use { copyHashing(it, target) }
      return target to hash
    } catch (error: Exception) {
      target.delete()
      throw error
    }
  }

  private fun copyHashing(input: java.io.InputStream, target: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    FileOutputStream(target).use { output ->
      val buffer = ByteArray(COPY_BUFFER_BYTES)
      while (true) {
        val count = input.read(buffer)
        if (count < 0) break
        digest.update(buffer, 0, count)
        output.write(buffer, 0, count)
      }
    }
    return digest.digest().toHex()
  }

  /**
   * Document ids for the selected tree, keyed by path inside it.
   *
   * Installing a file used to query every parent folder's full child list to
   * find each path part, which made a large first download quadratic in the
   * folder size. The listing already had the ids.
   */
  private class DocumentIndex(entries: Map<String, Entry>) {
    private val ids = HashMap<String, String>()
    /** Folders this sync created; nothing else can be in them yet. */
    private val created = HashSet<String>()
    init { for ((path, entry) in entries) if (entry.documentId.isNotEmpty()) ids[path] = entry.documentId }
    operator fun get(path: String): String? = ids[path]
    operator fun set(path: String, id: String) { ids[path] = id }
    fun remove(path: String) { ids.remove(path) }
    fun markCreated(path: String) { created.add(path) }
    /** Whether a name missing from the index can be trusted to be absent. */
    fun isFresh(parentPath: String): Boolean = parentPath in created
  }

  private data class Installed(val size: Long, val modifiedUnixMs: Long)

  private fun installLocalFile(
    context: Context,
    folderUri: String,
    relative: String,
    staged: File,
    serverMtime: Long,
    index: DocumentIndex?,
  ): Installed {
    val tree = Uri.parse(folderUri)
    if (tree.scheme == "file") {
      return installLocalFileFile(File(requireNotNull(tree.path) { "The selected folder is invalid." }), safePath(relative).split('/'), staged, serverMtime)
    }
    val parts = safePath(relative).split('/')
    var parentId = DocumentsContract.getTreeDocumentId(tree)
    var parentPath = ""
    for (part in parts.dropLast(1)) {
      val path = join(parentPath, part)
      val known = index?.get(path)
      val existing = if (known != null) DocumentsContract.buildDocumentUriUsingTree(tree, known)
        else if (index == null || !index.isFresh(parentPath)) findChild(context, tree, parentId, part) else null
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
        index?.set(path, parentId)
        index?.markCreated(path)
      }
      parentPath = path
    }
    val parent = DocumentsContract.buildDocumentUriUsingTree(tree, parentId)
    val temporary = DocumentsContract.createDocument(context.contentResolver, parent, "application/octet-stream", "$INTERNAL_FILE_PREFIX${System.nanoTime()}.tmp")
      ?: throw SyncFailure("Could not create a temporary destination file.", true)
    try {
      context.contentResolver.openOutputStream(temporary, "wt")?.use { output -> FileInputStream(staged).use { it.copyTo(output, COPY_BUFFER_BYTES) } }
        ?: throw SyncFailure("The destination file cannot be opened for writing.", false)
      val finalName = parts.last()
      val knownFinal = index?.get(relative)
      // A name missing from the index is looked up only in folders that
      // existed before this sync, so a file that appeared since is replaced
      // rather than duplicated, without a lookup per file in new folders.
      val existing = if (knownFinal != null) DocumentsContract.buildDocumentUriUsingTree(tree, knownFinal)
        else if (index == null || !index.isFresh(parentPath)) findChild(context, tree, parentId, finalName) else null
      if (existing != null && context.contentResolver.getType(existing) == DocumentsContract.Document.MIME_TYPE_DIR) {
        // Replacing goes through a backup that is deleted afterwards; for a
        // folder that would delete everything in it.
        throw SyncFailure("A folder on this device has the same name as a server file: $relative", false)
      }
      val installed = if (existing == null) {
        DocumentsContract.renameDocument(context.contentResolver, temporary, finalName)
          ?: throw SyncFailure("The storage provider cannot safely install this file.", false)
      } else {
        val backup = DocumentsContract.renameDocument(context.contentResolver, existing, "$INTERNAL_FILE_PREFIX${System.nanoTime()}.backup")
          ?: throw SyncFailure("The storage provider cannot safely replace this file.", false)
        val renamed = try {
          DocumentsContract.renameDocument(context.contentResolver, temporary, finalName)
            ?: throw SyncFailure("Could not install the downloaded file.", true)
        } catch (error: Exception) {
          DocumentsContract.renameDocument(context.contentResolver, backup, finalName)
          throw error
        }
        runCatching { DocumentsContract.deleteDocument(context.contentResolver, backup) }
        renamed
      }
      index?.set(relative, DocumentsContract.getDocumentId(installed))
      return documentMetadata(context, installed)
    } catch (error: Exception) {
      runCatching { DocumentsContract.deleteDocument(context.contentResolver, temporary) }
      index?.remove(relative)
      throw error
    }
  }

  /** Size and mtime as the provider will report them in the next listing. */
  private fun documentMetadata(context: Context, uri: Uri): Installed {
    return runCatching {
      context.contentResolver.query(
        uri,
        arrayOf(DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED),
        null, null, null,
      )?.use { cursor ->
        if (!cursor.moveToFirst()) return@use null
        Installed(
          if (cursor.isNull(0)) 0L else cursor.getLong(0),
          if (cursor.isNull(1)) 0L else cursor.getLong(1),
        )
      }
    }.getOrNull() ?: Installed(0L, 0L)
  }

  private fun installLocalFileFile(dir: File, parts: List<String>, staged: File, serverMtime: Long): Installed {
    var current = dir
    for (part in parts.dropLast(1)) {
      current = File(current, part)
      if (!current.isDirectory && !current.mkdir()) throw SyncFailure("Could not create a destination folder: $part", true)
    }
    val target = File(current, parts.last())
    if (target.isDirectory) throw SyncFailure("A folder on this device has the same name as a server file: ${parts.joinToString("/")}", false)
    val temporary = File.createTempFile(INTERNAL_FILE_PREFIX, ".tmp", current)
    try {
      FileInputStream(staged).use { input -> FileOutputStream(temporary).use { input.copyTo(it, COPY_BUFFER_BYTES) } }
      val existing = if (target.isFile) target else null
      if (existing != null) {
        val backup = File(current, "$INTERNAL_FILE_PREFIX${System.nanoTime()}.backup")
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
    // Keeping the server's mtime lets later checks match this file by size and
    // mtime alone, so neither side has to read it again.
    if (serverMtime > 0) runCatching { target.setLastModified(serverMtime) }
    return Installed(target.length(), target.lastModified())
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
    }?.forEach { file ->
      if (file.isDirectory && file.name.startsWith("filesync-share-")) {
        file.listFiles()?.filter { it.isFile }?.forEach { it.delete() }
      }
      file.delete()
    }
  }

  private fun fileUrl(apiBase: String, path: String, root: String): URL =
    URL("$apiBase/api/v1/file?path=${encode(path)}&root=${encode(root)}")

  /**
   * Run one network step, retrying connection drops and server hiccups.
   *
   * A single dropped connection used to abandon the whole folder until the
   * next scheduled run. Failures the user has to fix are not retried.
   */
  private fun <T> withRetries(label: String, block: () -> T): T {
    var attempt = 1
    while (true) {
      try {
        return block()
      } catch (error: java.io.IOException) {
        if (attempt >= NETWORK_ATTEMPTS) {
          throw SyncFailure("$label failed: the connection to the server was lost. Sync will retry.", true)
        }
      } catch (error: SyncFailure) {
        if (!error.retryable || error.needsSignIn || attempt >= NETWORK_ATTEMPTS) throw error
      }
      Thread.sleep(RETRY_DELAY_MS * attempt)
      attempt++
    }
  }

  /**
   * Run a step that only touches device storage. Its I/O errors (a full disk,
   * a file deleted mid-sync) are not network drops: retrying them three times
   * and then reporting a lost connection hid problems the user has to fix.
   */
  private fun <T> localStep(action: String, block: () -> T): T =
    try { block() } catch (error: java.io.IOException) {
      throw SyncFailure("Could not $action on this device: ${error.message ?: "storage error"}.", false)
    }

  private fun localMetadata(context: Context, view: LocalView, relative: String, entry: Entry): Installed {
    val tree = Uri.parse(view.plan.folderUri)
    if (tree.scheme == "file") {
      val file = File(File(requireNotNull(tree.path) { "The selected folder is invalid." }), view.devicePath(relative))
      return Installed(file.length(), file.lastModified())
    }
    return documentMetadata(context, documentUri(context, tree, view.devicePath(relative), entry))
  }

  private data class Download(val file: File, val sha256: String)

  /** Stream a server file into private cache, hashing it and checking its length. */
  private fun downloadToCache(context: Context, tokens: TokenSource, url: URL, relative: String): Download {
    fun open(token: String): HttpURLConnection = connect(url, "GET", token, TRANSFER_READ_TIMEOUT_MS)
    val token = tokens.token()
    var connection = open(token)
    try {
      if (connection.responseCode == 401) {
        connection.disconnect()
        connection = open(tokens.refreshAfterRejection(token))
      }
      val code = connection.responseCode
      if (code !in 200..299) failHttp(code, "The server could not provide $relative")
      val expected = connection.contentLengthLong
      val staged = File.createTempFile("filesync-", ".download", context.cacheDir)
      try {
        val hash = connection.inputStream.use { copyHashing(it, staged) }
        if (expected >= 0 && staged.length() != expected) {
          throw SyncFailure("The download of $relative was cut short.", true)
        }
        return Download(staged, hash)
      } catch (error: Exception) {
        staged.delete()
        throw error
      }
    } finally {
      connection.disconnect()
    }
  }

  private fun connect(url: URL, method: String, accessToken: String?, readTimeoutMs: Int): HttpURLConnection {
    require(url.protocol == "https") { "Sync requests require HTTPS" }
    return (url.openConnection() as HttpURLConnection).apply {
      requestMethod = method
      connectTimeout = HTTP_TIMEOUT_MS
      readTimeout = readTimeoutMs
      instanceFollowRedirects = false
      setRequestProperty("User-Agent", "NixHomeServer-FileSync-Android/0.1")
      accessToken?.let { setRequestProperty("Authorization", "Bearer $it") }
    }
  }

  private fun request(
    url: URL,
    method: String,
    accessToken: String? = null,
    form: Map<String, String>? = null,
    json: String? = null,
    file: File? = null,
    checksum: String? = null,
    readTimeoutMs: Int = HTTP_TIMEOUT_MS,
  ): HttpResponse {
    val connection = connect(url, method, accessToken, readTimeoutMs)
    try {
      when {
        form != null -> {
          connection.doOutput = true
          connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
          val encoded = form.entries.joinToString("&") { "${encode(it.key)}=${encode(it.value)}" }.toByteArray(Charsets.UTF_8)
          connection.setFixedLengthStreamingMode(encoded.size)
          connection.outputStream.use { it.write(encoded) }
        }
        json != null -> {
          connection.doOutput = true
          connection.setRequestProperty("Content-Type", "application/json")
          val encoded = json.toByteArray(Charsets.UTF_8)
          connection.setFixedLengthStreamingMode(encoded.size)
          connection.outputStream.use { it.write(encoded) }
        }
        file != null -> {
          connection.doOutput = true
          connection.setRequestProperty("x-filesync-sha256", checksum)
          connection.setFixedLengthStreamingMode(file.length())
          FileInputStream(file).use { input -> connection.outputStream.use { input.copyTo(it, COPY_BUFFER_BYTES) } }
        }
      }
      val code = connection.responseCode
      val stream = if (code in 200..299) connection.inputStream else connection.errorStream
      val body = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
      return HttpResponse(code, body)
    } finally { connection.disconnect() }
  }

  private fun failHttp(code: Int, message: String): Nothing {
    when (code) {
      401 -> throw SyncFailure("The sync server no longer accepts this session. Open File Sync and sign in again.", false, needsSignIn = true)
      403 -> throw SyncFailure("$message: the server refused access (HTTP 403).", false)
      in 500..599, 408, 429 -> throw SyncFailure("$message (HTTP $code). Sync will retry.", true)
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
      val buffer = ByteArray(COPY_BUFFER_BYTES)
      while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
    }
    digest.digest().toHex()
  }

  private val HEX = "0123456789abcdef".toCharArray()
  private fun ByteArray.toHex(): String {
    val out = CharArray(size * 2)
    for ((index, byte) in withIndex()) {
      val value = byte.toInt() and 0xff
      out[index * 2] = HEX[value ushr 4]
      out[index * 2 + 1] = HEX[value and 0x0f]
    }
    return String(out)
  }

  private data class Entry(
    val path: String,
    val kind: String,
    val sha256: String,
    val size: Long,
    val modifiedUnixMs: Long = 0L,
    /** The SAF document id; empty for plain files. */
    val documentId: String = "",
  )
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

  /**
   * Report what a sync of one pair would move.
   *
   * Deliberately does not take the sync lock: it only reads, so it can answer
   * while a long background sync runs instead of leaving the app on
   * "Checking…" until that sync ends.
   */
  fun estimatePair(context: Context, pairJson: String): Map<String, Any> {
    try {
      val pair = JSONObject(pairJson)
      val tokens = TokenSource(context)
      val plan = loadPlan(context, tokens, pair)
      val cache = HashCache.open(context, plan)
      val data = try {
        diffWithServer(context, tokens, localView(context, plan), cache, list = false)
      } finally {
        cache.save()
      }
      if (data.unreadable.isNotEmpty()) {
        throw SyncFailure(
          "${data.unreadable.take(3).joinToString(", ")} could not be read on the server. Try again in a moment.",
          true,
        )
      }
      val stats = storageStats(context)
      return mapOf(
        "pendingBytes" to data.pendingBytes,
        "pendingCount" to data.pendingCount,
        "skipped" to data.skipped,
        "direction" to plan.direction,
        "freeBytes" to stats.freeBytes,
        "totalBytes" to stats.totalBytes,
        // totalBytes above is device storage; the folder's own size comes from
        // the server, which is the only side that can see all of it.
        "remoteTotalBytes" to data.remoteTotalBytes,
      )
    } catch (error: InterruptedException) {
      Thread.currentThread().interrupt()
      throw SyncFailure("Size check was interrupted.", true)
    }
  }

  private data class LocalFile(
    val path: String,
    val size: Long,
    val modifiedUnixMs: Long,
    val hash: String?,
  )

  private data class PendingFile(val path: String, val size: Long, val mtimeUnixMs: Long)

  private data class EstimateData(
    val pendingBytes: Long,
    val pendingCount: Int,
    val skipped: Int,
    val remoteTotalBytes: Long,
    val needsHash: List<String>,
    val unreadable: List<String>,
    val truncated: Boolean,
    /** Null when the server predates the pending list. */
    val pending: List<PendingFile>?,
  )

  private fun postEstimate(tokens: TokenSource, plan: SyncPlan, local: List<LocalFile>, list: Boolean): EstimateData {
    val payload = JSONObject().apply {
      put("root", plan.root)
      put("path", plan.serverPath)
      put("direction", plan.direction)
      if (list) put("list", true)
      put("local", JSONArray().apply {
        for (file in local) {
          put(JSONObject().apply {
            put("path", file.path)
            put("size", file.size)
            put("mtimeUnixMs", file.modifiedUnixMs)
            file.hash?.let { put("hash", it) }
          })
        }
      })
    }.toString()
    val response = withRetries("The size check") {
      authed(tokens, URL("${plan.apiBase}/api/v1/estimate"), "POST", json = payload, readTimeoutMs = ESTIMATE_TIMEOUT_MS)
    }
    if (response.code !in 200..299) failHttp(response.code, "The size check was refused.")
    val data = JSONObject(response.body).getJSONObject("data")
    val pending = data.optJSONArray("pending")?.let { array ->
      (0 until array.length()).map { index ->
        val item = array.getJSONObject(index)
        PendingFile(item.getString("path"), item.optLong("size"), item.optLong("mtimeUnixMs"))
      }
    }
    return EstimateData(
      pendingBytes = data.optLong("pendingBytes"),
      pendingCount = data.optInt("pendingCount"),
      skipped = data.optInt("skipped"),
      remoteTotalBytes = data.optLong("remoteTotalBytes"),
      needsHash = data.optJSONArray("needsHash").toStringList(),
      unreadable = data.optJSONArray("unreadable").toStringList(),
      truncated = data.optBoolean("truncated"),
      pending = pending,
    )
  }

  private fun JSONArray?.toStringList(): List<String> {
    if (this == null) return emptyList()
    return (0 until length()).map { getString(it) }
  }

  private data class HttpResponse(val code: Int, val body: String)

  /**
   * SHA-256 of device files, remembered by path, size and mtime.
   *
   * Files copied by a sync never keep the other side's mtime on most storage
   * providers, so the server always asked to compare them by content, and the
   * device re-read every synced file on every check. With the cache, a file is
   * read again only when its size or mtime changes.
   */
  private class HashCache private constructor(private val file: File) {
    private val entries = HashMap<String, CachedHash>()
    private var unsaved = 0

    private data class CachedHash(val size: Long, val modifiedUnixMs: Long, val sha256: String)

    fun get(path: String, size: Long, modifiedUnixMs: Long): String? {
      if (modifiedUnixMs <= 0L) return null
      val cached = entries[path] ?: return null
      return if (cached.size == size && cached.modifiedUnixMs == modifiedUnixMs) cached.sha256 else null
    }

    fun put(path: String, size: Long, modifiedUnixMs: Long, sha256: String) {
      // Without an mtime a changed file could look unchanged; do not cache it.
      if (modifiedUnixMs <= 0L) return
      entries[path] = CachedHash(size, modifiedUnixMs, sha256)
      if (++unsaved >= SAVE_EVERY) save()
    }

    /** Forget files that no longer exist, so the cache tracks the folder. */
    fun retainOnly(paths: Set<String>) {
      if (entries.keys.retainAll(paths)) unsaved++
    }

    fun save() {
      if (unsaved == 0) return
      val json = JSONObject()
      for ((path, value) in entries) json.put(path, JSONArray().put(value.size).put(value.modifiedUnixMs).put(value.sha256))
      synchronized(HashCache::class.java) {
        runCatching {
          file.parentFile?.mkdirs()
          val temporary = File(file.parentFile, "${file.name}.tmp")
          temporary.writeText(json.toString(), Charsets.UTF_8)
          if (!temporary.renameTo(file)) temporary.delete()
        }
      }
      unsaved = 0
    }

    companion object {
      private const val SAVE_EVERY = 200

      // One cache per pair: pairs can share a device folder, and each prunes
      // its cache to its own files.
      fun open(context: Context, plan: SyncPlan): HashCache {
        val key = "${plan.folderUri}\u0000${plan.deviceSubpath}"
        val name = MessageDigest.getInstance("SHA-256").digest(key.toByteArray()).toHex().take(32)
        val cache = HashCache(File(File(context.filesDir, "filesync-hashes"), "$name.json"))
        synchronized(HashCache::class.java) {
          runCatching {
            if (!cache.file.isFile) return@runCatching
            val json = JSONObject(cache.file.readText(Charsets.UTF_8))
            for (path in json.keys()) {
              val value = json.optJSONArray(path) ?: continue
              cache.entries[path] = CachedHash(value.optLong(0), value.optLong(1), value.optString(2))
            }
          }
        }
        return cache
      }
    }
  }
}

internal class SyncFailure(
  message: String,
  val retryable: Boolean,
  /** The session is gone; background sync stays off until the user signs in. */
  val needsSignIn: Boolean = false,
) : Exception(message)
