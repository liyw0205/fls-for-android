package top.fls.fls_for_android

import android.app.Activity
import android.Manifest
import android.content.pm.PackageManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.BufferedReader
import java.io.InputStreamReader
import java.util.concurrent.TimeUnit
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingFileResult: MethodChannel.Result? = null
    private var pendingExportPath: String? = null
    private var pendingNotificationResult: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var containerCommandProcess: Process? = null
    @Volatile private var containerCommandSink: EventChannel.EventSink? = null
    private var containerCommandRunning = false
    private var containerCommandCancelled = false

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
                    "runContainerCommand" -> runContainerCommand(call.arguments, result)
                    "cancelContainerCommand" -> cancelContainerCommand(result)
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, COMMAND_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(
                    arguments: Any?,
                    events: EventChannel.EventSink,
                ) {
                    containerCommandSink = events
                }

                override fun onCancel(arguments: Any?) {
                    containerCommandSink = null
                }
            })
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

    private fun runContainerCommand(
        rawArguments: Any?,
        result: MethodChannel.Result,
    ) {
        val args = rawArguments as? Map<*, *>
        if (args == null || REQUIRED_PATHS.any { args[it] !is String }) {
            result.error("invalid_args", "在线脚本运行目录参数无效", null)
            return
        }
        val command = args["command"] as? String
        if (command.isNullOrBlank() || command.length > MAX_SCRIPT_COMMAND_LENGTH) {
            result.error("invalid_args", "在线脚本安装命令无效", null)
            return
        }
        synchronized(this) {
            if (containerCommandRunning) {
                result.error("command_busy", "另一个本机容器命令正在运行", null)
                return
            }
            containerCommandRunning = true
            containerCommandCancelled = false
        }

        val paths = REQUIRED_PATHS.associateWith { args[it] as String }
        Thread {
            var temporaryDirectory: File? = null
            var process: Process? = null
            try {
                val runtime = File(paths.getValue("runtimeDir"))
                val rootfs = File(runtime, "rootfs")
                val proot = File(applicationInfo.nativeLibraryDir, "libdaidai_proot.so")
                val loader = File(applicationInfo.nativeLibraryDir, "libproot_loader.so")
                val project = File(paths.getValue("projectDir"))
                val data = File(paths.getValue("dataDir"))
                val log = File(paths.getValue("logDir"))
                val scripts = File(paths.getValue("scriptsDir"))
                if (!rootfs.isDirectory || !proot.canExecute() || !loader.canExecute()) {
                    throw IllegalStateException("本机容器运行环境不完整，请先修复或重新安装环境")
                }
                listOf(project, data, log, scripts).forEach { it.mkdirs() }
                temporaryDirectory = File(
                    runtime,
                    "tmp-fls-script-${System.currentTimeMillis()}",
                ).apply { mkdirs() }

                val processCommand = mutableListOf(
                    proot.absolutePath,
                    "--kill-on-exit",
                    "--link2symlink",
                    "-k", "4.14.0",
                    "-0",
                    "-r", rootfs.absolutePath,
                    "-b", "/dev",
                    "-b", "/proc",
                    "-b", "/sys",
                    "-b", "${project.absolutePath}:/opt/fls",
                    "-b", "${data.absolutePath}:/opt/fls/data",
                    "-b", "${log.absolutePath}:/opt/fls/log",
                    "-b", "${scripts.absolutePath}:/opt/fls/scripts",
                    "-w", "/opt/fls/scripts",
                    "/bin/sh",
                    "-lc",
                    command,
                )
                val builder = ProcessBuilder(processCommand)
                    .directory(filesDir)
                    .redirectErrorStream(true)
                builder.environment().apply {
                    put("HOME", "/root")
                    put(
                        "PATH",
                        "/opt/fls-venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                    )
                    put("LD_LIBRARY_PATH", applicationInfo.nativeLibraryDir)
                    put("PROOT_LOADER", loader.absolutePath)
                    put("PROOT_TMP_DIR", temporaryDirectory.absolutePath)
                    put("FLS_BASE_DIR", "/opt/fls")
                    put("FLS_PYTHON", "/opt/fls-venv/bin/python")
                    put("LANG", "C.UTF-8")
                    put("LC_ALL", "C.UTF-8")
                }
                val activeProcess = synchronized(this) {
                    if (containerCommandCancelled) {
                        throw IllegalStateException("在线脚本安装已取消")
                    }
                    builder.start().also {
                        process = it
                        containerCommandProcess = it
                    }
                }
                val reader = Thread {
                    try {
                        BufferedReader(InputStreamReader(activeProcess.inputStream)).use { input ->
                            while (true) {
                                val line = input.readLine() ?: break
                                mainHandler.post { containerCommandSink?.success(line) }
                            }
                        }
                    } catch (_: Exception) {
                        // The command may be cancelled while output is being read.
                    }
                }.apply { name = "fls-script-command-output" }
                reader.start()

                if (!activeProcess.waitFor(SCRIPT_COMMAND_TIMEOUT_MINUTES, TimeUnit.MINUTES)) {
                    activeProcess.destroyForcibly()
                    reader.join(2_000)
                    throw IllegalStateException("在线脚本依赖安装超时")
                }
                reader.join(2_000)
                val exitCode = activeProcess.exitValue()
                runOnUiThread {
                    if (exitCode == 0) result.success(exitCode)
                    else result.error("command_failed", "安装命令退出码：$exitCode", exitCode)
                }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("command_failed", error.message ?: "运行在线脚本命令失败", null)
                }
            } finally {
                synchronized(this) {
                    if (containerCommandProcess === process) containerCommandProcess = null
                    containerCommandRunning = false
                    containerCommandCancelled = false
                }
                temporaryDirectory?.deleteRecursively()
            }
        }.apply { name = "fls-script-command" }.start()
    }

    private fun cancelContainerCommand(result: MethodChannel.Result) {
        val activeProcess = synchronized(this) {
            containerCommandCancelled = true
            containerCommandProcess
        }
        if (activeProcess == null) {
            result.success(null)
            return
        }
        Thread {
            try {
                activeProcess.destroyForcibly()
                activeProcess.waitFor()
                runOnUiThread { result.success(null) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("cancel_failed", error.message ?: "取消本机命令失败", null)
                }
            }
        }.apply { name = "fls-script-command-cancel" }.start()
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
        private const val COMMAND_CHANNEL = "top.fls/container_command"
        private const val FILE_CHANNEL = "top.fls/file_bridge"
        private const val MAX_SCRIPT_COMMAND_LENGTH = 64 * 1024
        private const val SCRIPT_COMMAND_TIMEOUT_MINUTES = 20L
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
