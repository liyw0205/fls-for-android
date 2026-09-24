package top.fls.fls_for_android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.pm.ServiceInfo
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.io.File

class LocalPanelService : Service() {
    private var process: Process? = null
    private var activePaths: Map<String, String>? = null
    private var restartAttempts = 0
    private val handler = Handler(Looper.getMainLooper())

    private val preferences
        get() = getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    override fun onCreate() {
        super.onCreate()
        instance = this
        restartAttempts = preferences.getInt(KEY_RESTART_ATTEMPTS, 0)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            preferences.edit()
                .putBoolean(KEY_DESIRED, false)
                .putString(KEY_STATE, STATE_STOPPED)
                .putInt(KEY_RESTART_ATTEMPTS, 0)
                .remove(KEY_EXIT_CODE)
                .apply()
            restartAttempts = 0
            handler.removeCallbacksAndMessages(null)
            val activeProcess = process
            if (activeProcess == null || !activeProcess.isAlive) {
                process = null
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf(startId)
            } else {
                activeProcess.destroy()
            }
            return START_NOT_STICKY
        }

        val isUserStart = intent?.action == ACTION_START
        if (isUserStart) restartAttempts = 0
        val paths = when {
            intent == null && preferences.getBoolean(KEY_DESIRED, false) &&
                preferences.getBoolean(KEY_AUTO_RESTART, false) -> savedPaths()
            intent?.action == ACTION_START -> pathsFromIntent(intent)
            else -> null
        }
        if (paths == null) {
            if (intent == null && preferences.getBoolean(KEY_DESIRED, false)) {
                preferences.edit().putString(KEY_STATE, STATE_INTERRUPTED).apply()
            } else {
                preferences.edit().putString(KEY_STATE, STATE_FAILED).apply()
            }
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (process?.isAlive == true) return START_STICKY

        val port = intent?.getIntExtra(KEY_PORT, DEFAULT_PORT)
            ?: preferences.getInt(KEY_PORT, DEFAULT_PORT)
        preferences.edit()
            .putBoolean(KEY_DESIRED, true)
            .putString(KEY_STATE, STATE_STARTING)
            .putInt(KEY_RESTART_ATTEMPTS, restartAttempts)
            .putInt(KEY_PORT, port)
            .apply()
        if (preferences.getBoolean(KEY_AUTO_RESTART, false)) {
            preferences.edit()
                .putString(KEY_RUNTIME, paths.getValue("runtimeDir"))
                .putString(KEY_PROJECT, paths.getValue("projectDir"))
                .putString(KEY_DATA, paths.getValue("dataDir"))
                .putString(KEY_LOG, paths.getValue("logDir"))
                .putString(KEY_SCRIPTS, paths.getValue("scriptsDir"))
                .apply()
        }
        try {
            startForegroundWithType(buildNotification("正在启动本机面板"))
            if (intent == null) {
                if (restartAttempts >= RESTART_DELAYS_SECONDS.size) {
                    finishAfterCrash(preferences.getInt(KEY_EXIT_CODE, -1))
                } else {
                    scheduleRestart(paths, preferences.getInt(KEY_EXIT_CODE, -1))
                }
                return START_STICKY
            }
            startPanel(paths, port)
        } catch (error: Exception) {
            appendServiceLog("服务启动失败: ${error.message}")
            handleUnexpectedExit(paths, null)
        }
        return START_STICKY
    }

    private fun pathsFromIntent(intent: Intent): Map<String, String>? {
        val paths = REQUIRED_PATHS.associateWith { intent.getStringExtra(it) }
        return if (paths.values.any { it.isNullOrBlank() }) null
        else paths.mapValues { it.value!! }
    }

    private fun savedPaths(): Map<String, String>? {
        val paths = mapOf(
            "runtimeDir" to preferences.getString(KEY_RUNTIME, null),
            "projectDir" to preferences.getString(KEY_PROJECT, null),
            "dataDir" to preferences.getString(KEY_DATA, null),
            "logDir" to preferences.getString(KEY_LOG, null),
            "scriptsDir" to preferences.getString(KEY_SCRIPTS, null),
        )
        return if (paths.values.any { it.isNullOrBlank() }) null
        else paths.mapValues { it.value!! }
    }

    private fun startPanel(paths: Map<String, String>, port: Int) {
        activePaths = paths
        val runtime = File(paths.getValue("runtimeDir"))
        val rootfs = File(runtime, "rootfs")
        val python = File(rootfs, "opt/fls-venv/bin/python")
        val proot = File(applicationInfo.nativeLibraryDir, "libdaidai_proot.so")
        val loader = File(applicationInfo.nativeLibraryDir, "libproot_loader.so")
        val project = File(paths.getValue("projectDir"))
        val data = File(paths.getValue("dataDir"))
        val log = File(paths.getValue("logDir"))
        val scripts = File(paths.getValue("scriptsDir"))
        listOf(data, log, scripts, File(runtime, "tmp")).forEach { it.mkdirs() }
        if (!proot.canExecute() || !loader.canExecute() || !python.exists() ||
            !File(project, "fls-manager.py").exists()) {
            throw IllegalStateException("Android PRoot、loader、Python 或 FLS 程序文件缺失")
        }

        val command = mutableListOf(
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
            "-w", "/opt/fls",
            "/opt/fls-venv/bin/python",
            "/opt/fls/fls-manager.py",
        )
        val output = File(filesDir, "fls/local-panel.log").apply { parentFile?.mkdirs() }
        val builder = ProcessBuilder(command)
            .directory(filesDir)
            .redirectErrorStream(true)
            .redirectOutput(ProcessBuilder.Redirect.appendTo(output))
        builder.environment().apply {
            put("LD_LIBRARY_PATH", applicationInfo.nativeLibraryDir)
            put("PROOT_LOADER", loader.absolutePath)
            put("PROOT_TMP_DIR", File(runtime, "tmp").absolutePath)
            put("FLS_BASE_DIR", "/opt/fls")
            put("FLS_PYTHON", "/opt/fls-venv/bin/python")
            put("FLS_HOST", "127.0.0.1")
            put("FLS_PORT", port.toString())
            put("LANG", "C.UTF-8")
            put("LC_ALL", "C.UTF-8")
        }
        val startedProcess = builder.start()
        process = startedProcess
        preferences.edit()
            .putString(KEY_STATE, STATE_RUNNING)
            .putLong(KEY_STARTED_AT, System.currentTimeMillis())
            .remove(KEY_EXIT_CODE)
            .apply()
        updateForegroundNotification("127.0.0.1:$port")

        Thread {
            val exitCode = try {
                startedProcess.waitFor()
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                -1
            }
            handler.post {
                if (process === startedProcess) {
                    process = null
                    preferences.edit().putInt(KEY_EXIT_CODE, exitCode).apply()
                    appendServiceLog("FLS 进程退出，退出码: $exitCode")
                    handleUnexpectedExit(paths, exitCode)
                }
            }
        }.apply { name = "fls-panel-waiter" }.start()

        handler.postDelayed({
            if (process === startedProcess && startedProcess.isAlive) {
                restartAttempts = 0
                preferences.edit().putInt(KEY_RESTART_ATTEMPTS, 0).apply()
            }
        }, STABLE_RUN_MILLIS)
    }

    private fun handleUnexpectedExit(paths: Map<String, String>, exitCode: Int?) {
        if (!preferences.getBoolean(KEY_DESIRED, false)) {
            markStopped()
            stopSelf()
            return
        }

        if (preferences.getBoolean(KEY_AUTO_RESTART, false) &&
            restartAttempts < RESTART_DELAYS_SECONDS.size) {
            scheduleRestart(paths, exitCode)
            return
        }
        finishAfterCrash(exitCode)
    }

    private fun scheduleRestart(paths: Map<String, String>, exitCode: Int?) {
        if (restartAttempts >= RESTART_DELAYS_SECONDS.size) {
            finishAfterCrash(exitCode)
            return
        }
        val delay = RESTART_DELAYS_SECONDS[restartAttempts]
        restartAttempts++
        preferences.edit()
            .putString(KEY_STATE, STATE_RETRYING)
            .putInt(KEY_RESTART_ATTEMPTS, restartAttempts)
            .apply()
        updateForegroundNotification(
            "异常退出，${delay} 秒后尝试恢复 ($restartAttempts/${RESTART_DELAYS_SECONDS.size})",
        )
        handler.postDelayed({
            if (!preferences.getBoolean(KEY_DESIRED, false)) return@postDelayed
            if (!preferences.getBoolean(KEY_AUTO_RESTART, false)) {
                finishAfterCrash(exitCode)
                return@postDelayed
            }
            preferences.edit().putString(KEY_STATE, STATE_STARTING).apply()
            try {
                startPanel(paths, preferences.getInt(KEY_PORT, DEFAULT_PORT))
            } catch (error: Exception) {
                appendServiceLog("恢复失败: ${error.message}")
                handleUnexpectedExit(paths, exitCode)
            }
        }, delay * 1000L)
    }

    private fun finishAfterCrash(exitCode: Int?) {
        val editor = preferences.edit()
            .putString(KEY_STATE, STATE_CRASHED)
            .putInt(KEY_RESTART_ATTEMPTS, restartAttempts)
        if (exitCode == null) {
            editor.remove(KEY_EXIT_CODE)
        } else {
            editor.putInt(KEY_EXIT_CODE, exitCode)
        }
        editor.apply()
        postCrashNotification(exitCode)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun markStopped() {
        preferences.edit()
            .putString(KEY_STATE, STATE_STOPPED)
            .putInt(KEY_RESTART_ATTEMPTS, 0)
            .remove(KEY_EXIT_CODE)
            .apply()
    }

    private fun onAutoRestartChanged(enabled: Boolean) {
        if (enabled) return
        if (preferences.getString(KEY_STATE, null) == STATE_RETRYING) {
            handler.removeCallbacksAndMessages(null)
            val exitCode = if (preferences.contains(KEY_EXIT_CODE)) {
                preferences.getInt(KEY_EXIT_CODE, -1)
            } else null
            finishAfterCrash(exitCode)
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        if (preferences.getBoolean(KEY_DESIRED, false) &&
            preferences.getString(KEY_STATE, null) == STATE_RUNNING) {
            preferences.edit().putString(KEY_STATE, STATE_INTERRUPTED).apply()
        }
        process?.destroy()
        process = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "FLS 本机面板",
            NotificationManager.IMPORTANCE_LOW,
        )
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun startForegroundWithType(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            } else {
                0
            }
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            @Suppress("DEPRECATION")
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(message: String): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopService = PendingIntent.getService(
            this,
            1,
            Intent(this, LocalPanelService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setContentTitle("FLS 本机面板")
            .setContentText(message)
            .setContentIntent(openApp)
            .setOngoing(true)
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_media_pause,
                    "停止",
                    stopService,
                ).build(),
            )
            .build()
    }

    private fun updateForegroundNotification(message: String) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification(message))
    }

    private fun postCrashNotification(exitCode: Int?) {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle("FLS 本机面板已停止")
            .setContentText("进程异常退出，退出码: ${exitCode ?: "未知"}")
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .build()
        getSystemService(NotificationManager::class.java)
            .notify(CRASH_NOTIFICATION_ID, notification)
    }

    private fun appendServiceLog(message: String) {
        File(filesDir, "fls/local-panel.log").apply {
            parentFile?.mkdirs()
            appendText("\n[service] $message\n")
        }
    }

    companion object {
        const val ACTION_START = "top.fls.local_panel.START"
        const val ACTION_STOP = "top.fls.local_panel.STOP"
        const val STATE_STOPPED = "stopped"
        const val STATE_STARTING = "starting"
        const val STATE_RUNNING = "running"
        const val STATE_RETRYING = "retrying"
        const val STATE_CRASHED = "crashed"
        const val STATE_FAILED = "failed"
        const val STATE_INTERRUPTED = "interrupted"
        private const val PREFERENCES = "fls_local_panel_service"
        private const val CHANNEL_ID = "fls-local-panel"
        private const val NOTIFICATION_ID = 5700
        private const val CRASH_NOTIFICATION_ID = 5701
        private const val DEFAULT_PORT = 5700
        private const val KEY_DESIRED = "desired"
        private const val KEY_AUTO_RESTART = "auto_restart"
        private const val KEY_STATE = "state"
        private const val KEY_STARTED_AT = "started_at"
        private const val KEY_EXIT_CODE = "exit_code"
        private const val KEY_RESTART_ATTEMPTS = "restart_attempts"
        private const val KEY_PORT = "port"
        private const val KEY_RUNTIME = "runtime"
        private const val KEY_PROJECT = "project"
        private const val KEY_DATA = "data"
        private const val KEY_LOG = "log"
        private const val KEY_SCRIPTS = "scripts"
        private const val STABLE_RUN_MILLIS = 60_000L
        private val RESTART_DELAYS_SECONDS = listOf(2L, 5L, 15L)
        private val REQUIRED_PATHS = listOf(
            "runtimeDir",
            "projectDir",
            "dataDir",
            "logDir",
            "scriptsDir",
        )
        @Volatile private var instance: LocalPanelService? = null

        fun isRunning(): Boolean = instance?.process?.isAlive == true

        fun status(context: Context): Map<String, Any?> {
            val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            val stored = preferences.getString(KEY_STATE, STATE_STOPPED) ?: STATE_STOPPED
            val state = when {
                isRunning() -> STATE_RUNNING
                stored == STATE_RUNNING && preferences.getBoolean(KEY_DESIRED, false) -> STATE_INTERRUPTED
                else -> stored
            }
            return mapOf(
                "state" to state,
                "startedAtMs" to preferences.getLong(KEY_STARTED_AT, 0L),
                "exitCode" to if (preferences.contains(KEY_EXIT_CODE)) {
                    preferences.getInt(KEY_EXIT_CODE, -1)
                } else null,
                "restartAttempts" to preferences.getInt(KEY_RESTART_ATTEMPTS, 0),
                "autoRestart" to preferences.getBoolean(KEY_AUTO_RESTART, false),
            )
        }

        fun setAutoRestart(context: Context, enabled: Boolean) {
            val editor = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_AUTO_RESTART, enabled)
            if (!enabled) {
                editor.remove(KEY_RUNTIME)
                    .remove(KEY_PROJECT)
                    .remove(KEY_DATA)
                    .remove(KEY_LOG)
                    .remove(KEY_SCRIPTS)
            }
            if (enabled) {
                instance?.activePaths?.let { paths ->
                    editor
                        .putString(KEY_RUNTIME, paths.getValue("runtimeDir"))
                        .putString(KEY_PROJECT, paths.getValue("projectDir"))
                        .putString(KEY_DATA, paths.getValue("dataDir"))
                        .putString(KEY_LOG, paths.getValue("logDir"))
                        .putString(KEY_SCRIPTS, paths.getValue("scriptsDir"))
                }
            }
            editor.apply()
            instance?.onAutoRestartChanged(enabled)
        }

        fun autoRestartEnabled(context: Context): Boolean =
            context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .getBoolean(KEY_AUTO_RESTART, false)
    }
}
