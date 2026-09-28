package org.nixhomeserver.filesync.mobilefiles

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import androidx.activity.result.ActivityResult
import app.tauri.annotation.ActivityCallback
import app.tauri.annotation.Command
import app.tauri.annotation.Permission
import app.tauri.annotation.PermissionCallback
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.Plugin
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.Executors

@TauriPlugin(permissions = [Permission(strings = [Manifest.permission.WRITE_EXTERNAL_STORAGE], alias = "writeExternalStorage")])
class MobileFilesPlugin(private val activity: Activity) : Plugin(activity) {
  @Command
  fun acquireSyncLock(invoke: Invoke) {
    lockExecutor.execute {
      try {
        SyncEngine.acquireSyncLock()
        invoke.resolve()
      } catch (error: InterruptedException) {
        Thread.currentThread().interrupt()
        invoke.reject("Android sync was interrupted", error, null)
      }
    }
  }

  @Command
  fun releaseSyncLock(invoke: Invoke) {
    try {
      SyncEngine.releaseSyncLock()
      invoke.resolve()
    } catch (error: Exception) {
      invoke.reject("Android sync lock could not be released", error, null)
    }
  }

  @Command
  fun updateBackgroundSchedule(invoke: Invoke) {
    try {
      BackgroundSyncScheduler.update(activity, invoke.getArgs().getString("enabled") == "true")
      invoke.resolve()
    } catch (error: Exception) {
      invoke.reject("Could not update Android background sync", error, null)
    }
  }

  @Command
  fun updateBackgroundSyncs(invoke: Invoke) {
    val pairsJson = invoke.getArgs().getString("pairsJson")
    val enabled = invoke.getArgs().getString("enabled") == "true"
    configExecutor.execute {
      try {
        SyncEngine.updateConfiguration(activity, pairsJson, enabled)
        invoke.resolve()
      } catch (error: Exception) {
        invoke.reject("Could not save Android background sync settings", error, null)
      }
    }
  }

  @Command
  fun runSyncPair(invoke: Invoke) {
    val pairJson = invoke.getArgs().getString("pairJson")
    syncExecutor.execute {
      try {
        invoke.resolveObject(SyncEngine.syncPair(activity, pairJson))
      } catch (error: Exception) {
        invoke.reject(error.message ?: "The folder pair could not be synced", error, null)
      }
    }
  }

  @Command
  fun backgroundSyncStatus(invoke: Invoke) {
    try {
      invoke.resolveObject(mapOf("value" to SyncEngine.readStatus(activity)))
    } catch (error: Exception) {
      invoke.reject("Could not read Android background sync status", error, null)
    }
  }

  @Command
  fun ensureAllFilesAccess(invoke: Invoke) {
    invoke.resolveObject(mapOf("value" to hasAllFilesAccess()))
  }

  @Command
  fun requestAllFilesAccess(invoke: Invoke) {
    if (hasAllFilesAccess()) {
      invoke.resolveObject(mapOf("value" to true))
      return
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
        data = Uri.parse("package:${activity.packageName}")
      }
      startActivityForResult(invoke, intent, "allFilesAccessRequested")
    } else {
      requestPermissionForAlias("writeExternalStorage", invoke, "onWriteStoragePermissionResult")
    }
  }

  @ActivityCallback
  fun allFilesAccessRequested(invoke: Invoke, result: ActivityResult) {
    invoke.resolveObject(mapOf("value" to hasAllFilesAccess()))
  }

  @PermissionCallback
  fun onWriteStoragePermissionResult(invoke: Invoke) {
    invoke.resolveObject(mapOf("value" to hasAllFilesAccess()))
  }

  @Command
  fun createLocalFolder(invoke: Invoke) {
    try {
      val subpath = invoke.getArgs().getString("subpath")
      require(subpath.matches(Regex("[A-Za-z0-9._ -]+(?:/[A-Za-z0-9._ -]+)*"))) { "Invalid folder path" }
      require(hasAllFilesAccess()) { "All files access is required to create this folder" }
      val folder = File(Environment.getExternalStorageDirectory(), subpath)
      if (!folder.exists() && !folder.mkdirs()) {
        throw IllegalStateException("The folder could not be created on this device")
      }
      invoke.resolveObject(mapOf("value" to mapOf("uri" to Uri.fromFile(folder).toString(), "displayName" to "This device")))
    } catch (error: Exception) {
      invoke.reject("Could not create the folder on this device", error, null)
    }
  }

  @Command
  fun pickLocalFolder(invoke: Invoke) {
    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
      addFlags(
        Intent.FLAG_GRANT_READ_URI_PERMISSION or
          Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
          Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
      )
    }
    startActivityForResult(invoke, intent, "folderPicked")
  }

  @Command
  fun createTempFile(invoke: Invoke) {
    try {
      val file = File.createTempFile("filesync-", ".stage", activity.cacheDir)
      invoke.resolveObject(mapOf("value" to file.absolutePath))
    } catch (error: Exception) {
      invoke.reject("Could not create private transfer storage", error, null)
    }
  }

  @Command
  fun releaseLocalFolder(invoke: Invoke) {
    try {
      val uri = Uri.parse(invoke.getArgs().getString("folderUri"))
      val grant = activity.contentResolver.persistedUriPermissions.firstOrNull { it.uri == uri }
      if (grant != null) {
        var flags = 0
        if (grant.isReadPermission) flags = flags or Intent.FLAG_GRANT_READ_URI_PERMISSION
        if (grant.isWritePermission) flags = flags or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        if (flags != 0) activity.contentResolver.releasePersistableUriPermission(uri, flags)
      }
      invoke.resolve()
    } catch (error: Exception) {
      invoke.reject("Could not release access to the selected folder", error, null)
    }
  }

  @Command
  fun listLocalFiles(invoke: Invoke) {
    try {
      val root = Uri.parse(invoke.getArgs().getString("folderUri"))
      val result = mutableListOf<Map<String, Any>>()
      if (root.scheme == "file") {
        collectLocalFilesFile(File(requireNotNull(root.path) { "The selected folder is invalid." }), "", result)
      } else {
        walkTree(root, DocumentsContract.getTreeDocumentId(root), "", result)
      }
      invoke.resolveObject(mapOf("entries" to result))
    } catch (error: Exception) {
      invoke.reject("Could not read the selected folder", error, null)
    }
  }

  @Command
  fun stageLocalFile(invoke: Invoke) {
    try {
      val root = Uri.parse(invoke.getArgs().getString("folderUri"))
      val relativePath = invoke.getArgs().getString("relativePath")
      val target = File(activity.cacheDir, "filesync-${java.util.UUID.randomUUID()}.stage")
      if (root.scheme == "file") {
        val source = File(File(requireNotNull(root.path) { "The selected folder is invalid." }), relativePath)
        require(source.isFile) { "The selected file could not be opened" }
        FileInputStream(source).use { input -> FileOutputStream(target).use { input.copyTo(it) } }
      } else {
        val uri = resolveDocument(root, relativePath)
        activity.contentResolver.openInputStream(uri).use { input ->
          requireNotNull(input) { "The selected file could not be opened" }
          FileOutputStream(target).use { output -> input.copyTo(output) }
        }
      }
      invoke.resolveObject(mapOf("value" to target.absolutePath))
    } catch (error: Exception) {
      invoke.reject("Could not stage the selected file", error, null)
    }
  }

  @Command
  fun installLocalFile(invoke: Invoke) {
    var temporary: Uri? = null
    try {
      val root = Uri.parse(invoke.getArgs().getString("folderUri"))
      val relativePath = invoke.getArgs().getString("relativePath")
      val source = File(invoke.getArgs().getString("stagedPath"))
      require(source.isFile && source.canonicalPath.startsWith(activity.cacheDir.canonicalPath + File.separator)) { "The staged file is invalid" }
      if (root.scheme == "file") {
        installLocalFileFile(File(requireNotNull(root.path) { "The selected folder is invalid." }), safeRelative(relativePath), source)
        source.delete()
        invoke.resolve()
        return
      }
      val uri = createTemporaryDocument(root, relativePath)
      temporary = uri
      activity.contentResolver.openOutputStream(uri, "wt").use { output ->
        requireNotNull(output) { "The destination file could not be opened" }
        FileInputStream(source).use { input -> input.copyTo(output) }
      }
      installTemporaryDocument(root, relativePath, uri)
      source.delete()
      temporary = null
      invoke.resolve()
    } catch (error: Exception) {
      temporary?.let { runCatching { DocumentsContract.deleteDocument(activity.contentResolver, it) } }
      invoke.reject("Could not write the file to the selected folder", error, null)
    }
  }

  @ActivityCallback
  fun folderPicked(invoke: Invoke, result: ActivityResult) {
    if (result.resultCode != Activity.RESULT_OK) {
      invoke.resolveObject(mapOf("value" to null))
      return
    }
    val uri = result.data?.data
    if (uri == null) {
      invoke.reject("The folder picker returned no folder")
      return
    }
    try {
      val grantFlags = result.data?.flags?.and(
        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
      ) ?: 0
      activity.contentResolver.takePersistableUriPermission(uri, grantFlags)
      invoke.resolveObject(mapOf("value" to mapOf("uri" to uri.toString(), "displayName" to displayName(uri))))
    } catch (error: Exception) {
      invoke.reject("Android could not keep access to that folder", error, null)
    }
  }

  @Command
  fun storeSecret(invoke: Invoke) {
    val slot = safeSlot(invoke.getArgs().getString("slot"))
    val secret = invoke.getArgs().getString("secret")
    secretsExecutor.execute {
      try {
        SecureSecrets.store(activity, slot, secret)
        invoke.resolve()
      } catch (error: Exception) {
        invoke.reject("Could not store the Kanidm session securely", error, null)
      }
    }
  }

  @Command
  fun loadSecret(invoke: Invoke) {
    val slot = safeSlot(invoke.getArgs().getString("slot"))
    secretsExecutor.execute {
      try {
        invoke.resolveObject(mapOf("value" to SecureSecrets.load(activity, slot)))
      } catch (error: Exception) {
        invoke.reject("Could not read the Kanidm session securely", error, null)
      }
    }
  }

  @Command
  fun clearSecret(invoke: Invoke) {
    val slot = safeSlot(invoke.getArgs().getString("slot"))
    secretsExecutor.execute {
      try {
        SecureSecrets.clear(activity, slot)
        invoke.resolve()
      } catch (error: Exception) {
        invoke.reject("Could not clear the Kanidm session", error, null)
      }
    }
  }

  private fun hasAllFilesAccess(): Boolean {
    if (Environment.isExternalStorageManager()) return true
    return Build.VERSION.SDK_INT < Build.VERSION_CODES.R &&
      activity.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
  }

  private fun safeSlot(value: String): String {
    require(value.matches(Regex("[a-z0-9-]{1,48}"))) { "Invalid secure storage slot" }
    return value
  }

  companion object {
    private val syncExecutor = Executors.newSingleThreadExecutor()
    private val lockExecutor = Executors.newSingleThreadExecutor()
    private val configExecutor = Executors.newSingleThreadExecutor()
    private val secretsExecutor = Executors.newSingleThreadExecutor()
  }

  private fun walkTree(tree: Uri, parentId: String, prefix: String, result: MutableList<Map<String, Any>>) {
    val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
    val projection = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
      DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED)
    activity.contentResolver.query(children, projection, null, null, null)?.use { cursor ->
      while (cursor.moveToNext()) {
        val id = cursor.getString(0)
        val name = cursor.getString(1) ?: continue
        if (name == "." || name == ".." || name.contains('/')) continue
        val mime = cursor.getString(2) ?: ""
        val path = if (prefix.isEmpty()) name else "$prefix/$name"
        val isDirectory = mime == DocumentsContract.Document.MIME_TYPE_DIR
        val sha256 = if (isDirectory) "" else {
          val document = DocumentsContract.buildDocumentUriUsingTree(tree, id)
          val digest = MessageDigest.getInstance("SHA-256")
          activity.contentResolver.openInputStream(document).use { input ->
            requireNotNull(input) { "A selected file could not be opened" }
            val buffer = ByteArray(64 * 1024)
            while (true) {
              val count = input.read(buffer)
              if (count < 0) break
              digest.update(buffer, 0, count)
            }
          }
          digest.digest().joinToString("") { byte -> "%02x".format(byte) }
        }
        result.add(mapOf("path" to path, "kind" to if (isDirectory) "directory" else "file",
          "size" to if (cursor.isNull(3)) 0L else cursor.getLong(3), "modifiedUnixMs" to if (cursor.isNull(4)) 0L else cursor.getLong(4), "sha256" to sha256))
        if (isDirectory) walkTree(tree, id, path, result)
      }
    } ?: throw IllegalStateException("The selected folder cannot be listed")
  }

  private fun collectLocalFilesFile(dir: File, prefix: String, result: MutableList<Map<String, Any>>) {
    val children = dir.listFiles() ?: throw IllegalStateException("The selected folder cannot be listed")
    for (child in children) {
      val name = child.name
      if (name.isBlank() || name == "." || name == ".." || name.contains('/')) continue
      val path = if (prefix.isEmpty()) name else "$prefix/$name"
      val isDirectory = child.isDirectory
      val sha256 = if (isDirectory) "" else {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(child).use { input ->
          val buffer = ByteArray(64 * 1024)
          while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
          }
        }
        digest.digest().joinToString("") { byte -> "%02x".format(byte) }
      }
      result.add(mapOf("path" to path, "kind" to if (isDirectory) "directory" else "file",
        "size" to if (isDirectory) 0L else child.length(), "modifiedUnixMs" to child.lastModified(), "sha256" to sha256))
      if (isDirectory) collectLocalFilesFile(child, path, result)
    }
  }

  private fun installLocalFileFile(dir: File, parts: List<String>, source: File) {
    var current = dir
    for (part in parts.dropLast(1)) {
      current = File(current, part)
      if (!current.isDirectory && !current.mkdir()) throw IllegalStateException("Could not create a destination folder")
    }
    val temporary = File.createTempFile(".filesync-", ".tmp", current)
    try {
      FileInputStream(source).use { input -> FileOutputStream(temporary).use { input.copyTo(it) } }
      val target = File(current, parts.last())
      val existing = if (target.isFile) target else null
      if (existing != null) {
        val backup = File(current, ".filesync-${java.util.UUID.randomUUID()}.backup")
        if (!existing.renameTo(backup)) throw IllegalStateException("The selected folder cannot safely replace an existing file")
        try {
          if (!temporary.renameTo(target)) throw IllegalStateException("Could not install the downloaded file")
        } catch (error: Exception) {
          backup.renameTo(target)
          throw error
        }
        backup.delete()
      } else if (!temporary.renameTo(target)) {
        throw IllegalStateException("Could not install the downloaded file")
      }
    } catch (error: Exception) {
      temporary.delete()
      throw error
    }
  }

  private fun resolveDocument(tree: Uri, relativePath: String): Uri {
    val parts = safeRelative(relativePath)
    var parentId = DocumentsContract.getTreeDocumentId(tree)
    var found: Uri? = null
    for (part in parts) {
      val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
      val projection = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME)
      var matchId: String? = null
      activity.contentResolver.query(children, projection, null, null, null)?.use { cursor ->
        while (cursor.moveToNext()) if (cursor.getString(1) == part) { matchId = cursor.getString(0); break }
      }
      parentId = matchId ?: throw java.io.FileNotFoundException("Selected file does not exist")
      found = DocumentsContract.buildDocumentUriUsingTree(tree, parentId)
    }
    return found ?: throw java.io.FileNotFoundException("A file path is required")
  }

  private fun createTemporaryDocument(tree: Uri, relativePath: String): Uri {
    val parts = safeRelative(relativePath)
    require(parts.isNotEmpty()) { "A file path is required" }
    var parentId = DocumentsContract.getTreeDocumentId(tree)
    for (part in parts.dropLast(1)) {
      val found = findChild(tree, parentId, part)
      parentId = if (found != null) {
        require(activity.contentResolver.getType(found) == DocumentsContract.Document.MIME_TYPE_DIR) { "A parent path is a file" }
        DocumentsContract.getDocumentId(found)
      } else {
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, parentId)
        val created = DocumentsContract.createDocument(activity.contentResolver, parent, DocumentsContract.Document.MIME_TYPE_DIR, part)
          ?: throw IllegalStateException("Could not create a destination folder")
        DocumentsContract.getDocumentId(created)
      }
    }
    val parent = DocumentsContract.buildDocumentUriUsingTree(tree, parentId)
    val temporaryName = ".filesync-${java.util.UUID.randomUUID()}.tmp"
    return DocumentsContract.createDocument(activity.contentResolver, parent, "application/octet-stream", temporaryName)
      ?: throw IllegalStateException("Could not create the destination file")
  }

  private fun installTemporaryDocument(tree: Uri, relativePath: String, temporary: Uri) {
    val parts = safeRelative(relativePath)
    val parentId = resolveParentId(tree, parts.dropLast(1))
    val finalName = parts.last()
    val existing = findChild(tree, parentId, finalName)
    if (existing == null) {
      DocumentsContract.renameDocument(activity.contentResolver, temporary, finalName)
        ?: throw IllegalStateException("The selected storage provider cannot safely install the downloaded file")
      return
    }
    val backupName = ".filesync-${java.util.UUID.randomUUID()}.backup"
    val backup = DocumentsContract.renameDocument(activity.contentResolver, existing, backupName)
      ?: throw IllegalStateException("The selected storage provider cannot safely replace an existing file")
    try {
      DocumentsContract.renameDocument(activity.contentResolver, temporary, finalName)
        ?: throw IllegalStateException("Could not install the downloaded file")
    } catch (error: Exception) {
      DocumentsContract.renameDocument(activity.contentResolver, backup, finalName)
      throw error
    }
    runCatching { DocumentsContract.deleteDocument(activity.contentResolver, backup) }
  }

  private fun resolveParentId(tree: Uri, parts: List<String>): String {
    var parentId = DocumentsContract.getTreeDocumentId(tree)
    for (part in parts) {
      val child = findChild(tree, parentId, part) ?: throw java.io.FileNotFoundException("Destination folder does not exist")
      require(activity.contentResolver.getType(child) == DocumentsContract.Document.MIME_TYPE_DIR) { "A parent path is a file" }
      parentId = DocumentsContract.getDocumentId(child)
    }
    return parentId
  }

  private fun findChild(tree: Uri, parentId: String, name: String): Uri? {
    val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
    activity.contentResolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
      while (cursor.moveToNext()) if (cursor.getString(1) == name) return DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0))
    }
    return null
  }

  private fun safeRelative(value: String): List<String> {
    require(value.isNotEmpty() && !value.startsWith('/') && !value.contains('\\') && !value.contains('\u0000')) { "Invalid relative path" }
    val parts = value.split('/')
    require(parts.all { it.isNotEmpty() && it != "." && it != ".." }) { "Invalid relative path" }
    return parts
  }

  private fun displayName(uri: Uri): String {
    activity.contentResolver.query(
      uri,
      arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
      null,
      null,
      null,
    )?.use { cursor ->
      if (cursor.moveToFirst()) {
        val index = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        if (index >= 0) return cursor.getString(index)
      }
    }
    return uri.lastPathSegment ?: "Selected folder"
  }

}
