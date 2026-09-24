package top.fls.fls_for_android

import android.app.Activity
import android.Manifest
import android.content.pm.PackageManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingFileResult: MethodChannel.Result? = null
    private var pendingExportPath: String? = null
    private var pendingNotificationResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "supportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                    "start" -> {
                        val args = call.arguments as? Map<*, *>
                        if (args == null || REQUIRED_PATHS.any { args[it] !is String }) {
                            result.error("invalid_args", "本机服务目录参数无效", null)
                            return@setMethodCallHandler
                        }
                        val intent = Intent(this, LocalPanelService::class.java).apply {
                            action = LocalPanelService.ACTION_START
                            REQUIRED_PATHS.forEach { key ->
                                putExtra(key, args[key] as String)
                            }
                            putExtra("port", args["port"] as? Int ?: 5700)
                        }
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("start_failed", error.message, null)
                        }
                    }
                    "stop" -> {
                        startService(
                            Intent(this, LocalPanelService::class.java)
                                .setAction(LocalPanelService.ACTION_STOP),
                        )
                        result.success(null)
                    }
                    "isRunning" -> result.success(LocalPanelService.isRunning())
                    "status" -> result.success(LocalPanelService.status(this))
                    "setAutoRestart" -> {
                        val enabled = (call.arguments as? Map<*, *>)?.get("enabled") as? Boolean
                        if (enabled == null) {
                            result.error("invalid_args", "自动恢复设置无效", null)
                        } else {
                            LocalPanelService.setAutoRestart(this, enabled)
                            result.success(null)
                        }
                    }
                    "notificationsGranted" -> result.success(notificationsGranted())
                    "requestNotificationPermission" -> requestNotificationPermission(result)
                    "openAppSettings" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$packageName"),
                            ),
                        )
                        result.success(null)
                    }
                    "openBatterySettings" -> {
                        val batteryIntent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        val target = if (batteryIntent.resolveActivity(packageManager) != null) {
                            batteryIntent
                        } else {
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$packageName"),
                            )
                        }
                        startActivity(target)
                        result.success(null)
                    }
                    "readServiceLog" -> result.success(readServiceLog())
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickContainer" -> pickContainer(result)
                    "copyUriToPath" -> {
                        val args = call.arguments as? Map<*, *>
                        val uri = args?.get("uri") as? String
                        val path = args?.get("path") as? String
                        if (uri.isNullOrBlank() || path.isNullOrBlank()) {
                            result.error("invalid_args", "容器文件参数无效", null)
                        } else {
                            copyUriToPath(uri, path, result)
                        }
                    }
                    "saveFile" -> {
                        val args = call.arguments as? Map<*, *>
                        val path = args?.get("path") as? String
                        val filename = args?.get("filename") as? String
                        if (path.isNullOrBlank() || filename.isNullOrBlank() ||
                            !File(path).isFile) {
                            result.error("invalid_args", "待导出的容器文件无效", null)
                        } else {
                            saveFile(path, filename, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun notificationsGranted(): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33 || notificationsGranted()) {
            result.success(true)
            return
        }
        if (pendingNotificationResult != null) {
            result.error("busy", "通知权限请求正在处理", null)
            return
        }
        pendingNotificationResult = result
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
    }

    @Deprecated("Deprecated in Android API")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_NOTIFICATIONS) return
        val result = pendingNotificationResult ?: return
        pendingNotificationResult = null
        result.success(notificationsGranted())
    }

    private fun readServiceLog(): String {
        val logFile = File(filesDir, "fls/local-panel.log")
        if (!logFile.isFile) return "暂无本机服务日志"
        val maxBytes = 128 * 1024L
        val start = (logFile.length() - maxBytes).coerceAtLeast(0L)
        val lines = FileInputStream(logFile).use { input ->
            input.skip(start)
            input.bufferedReader(Charsets.UTF_8).readLines().takeLast(240)
        }
        val header = Regex("(?i)^\\s*(cookie|set-cookie|authorization)\\s*:")
        val secret = Regex(
            "(?i)(token|password|passwd|secret|api[_-]?key)(\\s*[:=]\\s*)(\"[^\"]*\"|'[^']*'|[^\\s,;&]+)",
        )
        return lines.joinToString("\n") { line ->
            val safeLine = header.replace(line) { "${it.groupValues[1]}: [已隐藏]" }
            secret.replace(safeLine) { "${it.groupValues[1]}${it.groupValues[2]}[已隐藏]" }
        }.ifBlank { "暂无本机服务日志" }
    }

    private fun pickContainer(result: MethodChannel.Result) {
        if (pendingFileResult != null) {
            result.error("busy", "已有文件选择操作正在进行", null)
            return
        }
        pendingFileResult = result
        pendingExportPath = null
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("application/gzip", "application/x-gzip", "application/octet-stream"),
            )
        }
        try {
            startActivityForResult(intent, REQUEST_PICK_CONTAINER)
        } catch (error: Exception) {
            pendingFileResult = null
            result.error("picker_failed", error.message, null)
        }
    }

    private fun saveFile(path: String, filename: String, result: MethodChannel.Result) {
        if (pendingFileResult != null) {
            result.error("busy", "已有文件选择操作正在进行", null)
            return
        }
        pendingFileResult = result
        pendingExportPath = path
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/gzip"
            putExtra(Intent.EXTRA_TITLE, filename)
        }
        try {
            startActivityForResult(intent, REQUEST_SAVE_CONTAINER)
        } catch (error: Exception) {
            pendingFileResult = null
            pendingExportPath = null
            result.error("picker_failed", error.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PICK_CONTAINER && requestCode != REQUEST_SAVE_CONTAINER) {
            return
        }
        val result = pendingFileResult ?: return
        val exportPath = pendingExportPath
        pendingFileResult = null
        pendingExportPath = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(if (requestCode == REQUEST_PICK_CONTAINER) null else false)
            return
        }
        val uri = data.data!!
        if (requestCode == REQUEST_PICK_CONTAINER) {
            result.success(uri.toString())
        } else if (exportPath != null) {
            copyFileToUri(exportPath, uri, result)
        } else {
            result.success(false)
        }
    }

    private fun copyUriToPath(uriString: String, path: String, result: MethodChannel.Result) {
        Thread {
            try {
                val input = contentResolver.openInputStream(Uri.parse(uriString))
                    ?: throw IllegalStateException("无法读取所选容器文件")
                File(path).parentFile?.mkdirs()
                input.use { source ->
                    FileOutputStream(path).use { target -> source.copyTo(target) }
                }
                runOnUiThread { result.success(true) }
            } catch (error: Exception) {
                runOnUiThread { result.error("copy_failed", error.message, null) }
            }
        }.start()
    }

    private fun copyFileToUri(path: String, uri: Uri, result: MethodChannel.Result) {
        Thread {
            try {
                val output = contentResolver.openOutputStream(uri)
                    ?: throw IllegalStateException("无法写入目标文件")
                output.use { target ->
                    File(path).inputStream().use { source -> source.copyTo(target) }
                }
                runOnUiThread { result.success(true) }
            } catch (error: Exception) {
                runOnUiThread { result.error("copy_failed", error.message, null) }
            }
        }.start()
    }

    companion object {
        private const val CHANNEL = "top.fls/local_panel"
        private const val FILE_CHANNEL = "top.fls/file_bridge"
        private const val REQUEST_PICK_CONTAINER = 5701
        private const val REQUEST_SAVE_CONTAINER = 5702
        private const val REQUEST_NOTIFICATIONS = 5703
        private val REQUIRED_PATHS = listOf(
            "runtimeDir",
            "projectDir",
            "dataDir",
            "logDir",
            "scriptsDir",
        )
    }
}
