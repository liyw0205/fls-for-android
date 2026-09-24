package top.fls.fls_for_android

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
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
                        stopService(Intent(this, LocalPanelService::class.java))
                        result.success(null)
                    }
                    "isRunning" -> result.success(LocalPanelService.isRunning())
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        private const val CHANNEL = "top.fls/local_panel"
        private val REQUIRED_PATHS = listOf(
            "runtimeDir",
            "projectDir",
            "dataDir",
            "logDir",
            "scriptsDir",
        )
    }
}
