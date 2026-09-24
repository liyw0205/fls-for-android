package top.fls.fls_for_android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.Handler
import android.os.Looper
import java.io.File

class LocalPanelService : Service() {
    private var process: Process? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopPanel()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (intent?.action != ACTION_START) return START_NOT_STICKY

        val paths = REQUIRED_PATHS.associateWith { intent.getStringExtra(it) }
        if (paths.values.any { it.isNullOrBlank() }) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        startForeground(NOTIFICATION_ID, buildNotification())
        if (process?.isAlive == true) return START_NOT_STICKY

        try {
            startPanel(paths.mapValues { it.value!! }, intent.getIntExtra("port", 5700))
        } catch (error: Exception) {
            File(filesDir, "fls/local-panel.log").apply {
                parentFile?.mkdirs()
                appendText("\n[service] ${error.message}\n")
            }
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    private fun startPanel(paths: Map<String, String>, port: Int) {
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
        process = builder.start()
        val startedProcess = process
        Thread {
            try {
                startedProcess?.waitFor()
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
            Handler(Looper.getMainLooper()).post {
                if (process === startedProcess) {
                    process = null
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }
            .apply { name = "fls-panel-waiter" }
            .start()
    }

    private fun stopPanel() {
        process?.destroy()
        process = null
    }

    override fun onDestroy() {
        stopPanel()
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

    private fun buildNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_upload_done)
                .setContentTitle("FLS 本机面板运行中")
                .setContentText("127.0.0.1:5700")
                .setContentIntent(openApp)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setSmallIcon(android.R.drawable.stat_sys_upload_done)
                .setContentTitle("FLS 本机面板运行中")
                .setContentText("127.0.0.1:5700")
                .setContentIntent(openApp)
                .setOngoing(true)
                .build()
        }
    }

    companion object {
        const val ACTION_START = "top.fls.local_panel.START"
        const val ACTION_STOP = "top.fls.local_panel.STOP"
        private const val CHANNEL_ID = "fls-local-panel"
        private const val NOTIFICATION_ID = 5700
        private val REQUIRED_PATHS = listOf(
            "runtimeDir",
            "projectDir",
            "dataDir",
            "logDir",
            "scriptsDir",
        )
        @Volatile private var instance: LocalPanelService? = null

        fun isRunning(): Boolean = instance?.process?.isAlive == true
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
    }
}
