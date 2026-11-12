package com.example.beoffline

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.work.*
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.*
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private val executor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Rejestracja cyklicznego sprawdzania w tle (WorkManager)
        UsageMonitorWorker.schedule(applicationContext)

        // Kanał ikon i metadanych
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "beoffline/app_metadata")
            .setMethodCallHandler { call, result ->
                if (call.method == "getAppMetadata") {
                    val packages = (call.arguments as? List<*>)?.filterIsInstance<String>()?.distinct().orEmpty()
                    executor.execute {
                        try {
                            val rows = packages.map { readAppMetadata(it) }
                            runOnUiThread { result.success(rows) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("APP_META", e.message, null) }
                        }
                    }
                } else {
                    result.notImplemented()
                }
            }

        // Kanał sesji, limitów i dokładnego czasu
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "beoffline/sessions")
            .setMethodCallHandler { call, result ->
                val prefs = getSharedPreferences("beoffline_sessions", Context.MODE_PRIVATE)

                when (call.method) {
                    "getInstalledApps" -> {
                        executor.execute {
                            try {
                                val apps = listInstalledApps()
                                val json = JSONArray()
                                for (app in apps) {
                                    val item = JSONObject()
                                    item.put("packageName", app["packageName"] as String)
                                    item.put("name", app["name"] as String)
                                    json.put(item)
                                }
                                runOnUiThread { result.success(json.toString()) }
                            } catch (e: Exception) {
                                runOnUiThread { result.success("[]") }
                            }
                        }
                    }

                    "openAccessibility" -> {
                        try {
                            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }

                    "openAppSettings" -> {
                        try {
                            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")).apply {
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }

                    "setAppLimits" -> {
                        prefs.edit().putString("app_limits", call.arguments as? String ?: "{}").apply()
                        result.success(true)
                    }

                    "getAppLimits" -> {
                        result.success(prefs.getString("app_limits", "{}") ?: "{}")
                    }

                    // POPRAWKA: prawdziwe sprawdzanie, czy usługa beOFFline jest włączona
                    "isAccessibilityEnabled" -> {
                        try {
                            result.success(isBeofflineAccessibilityEnabled().toString())
                        } catch (e: Exception) {
                            result.success(false.toString())
                        }
                    }

                    "getStreak" -> {
                        result.success(prefs.getString("streak", "{}") ?: "{}")
                    }

                    "saveStreak" -> {
                        prefs.edit().putString("streak", call.arguments as? String ?: "{}").apply()
                        result.success(true)
                    }

                    // Precyzyjne zliczanie aktywnego czasu w sekundach
                    "queryUsageRange" -> {
                        val start = (call.argument<Number>("start"))?.toLong() ?: 0L
                        val end = (call.argument<Number>("end"))?.toLong() ?: System.currentTimeMillis()

                        executor.execute {
                            try {
                                val usageInSeconds = calculateActiveUsageSeconds(applicationContext, start, end)
                                val json = JSONObject()
                                for ((pkg, sec) in usageInSeconds) {
                                    json.put(pkg, sec)
                                }
                                runOnUiThread { result.success(json.toString()) }
                            } catch (e: Exception) {
                                runOnUiThread { result.success("{}") }
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // POPRAWKA: sprawdza systemową listę włączonych usług dostępności
    private fun isBeofflineAccessibilityEnabled(): Boolean {
        return try {
            val expected = android.content.ComponentName(
                applicationContext,
                "com.example.beoffline.FocusAccessibilityService"
            )
            val enabledServices: String = Settings.Secure.getString(
                contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
            ) ?: return false
            if (enabledServices.isEmpty()) return false

            val splitter = android.text.TextUtils.SimpleStringSplitter(':')
            splitter.setString(enabledServices)
            var found = false
            while (splitter.hasNext()) {
                val component = android.content.ComponentName.unflattenFromString(splitter.next())
                if (component != null && component == expected) {
                    found = true
                    break
                }
            }
            found
        } catch (e: Exception) {
            false
        }
    }

    private fun listInstalledApps(): List<Map<String, Any?>> {
        val pm = applicationContext.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val resolved = pm.queryIntentActivities(intent, 0)

        return resolved.map { ri ->
            mapOf(
                "packageName" to ri.activityInfo.packageName,
                "name" to ri.loadLabel(pm).toString()
            )
        }.distinctBy { it["packageName"] as String }
         .sortedBy { (it["name"] as String).lowercase() }
    }

    private fun readAppMetadata(packageName: String): Map<String, Any?> {
        val pm = applicationContext.packageManager
        val info = try {
            pm.getApplicationInfo(packageName, 0)
        } catch (e: Exception) {
            return mapOf(
                "packageName" to packageName,
                "name" to packageName.substringAfterLast('.'),
                "icon" to null
            )
        }

        val drawable = pm.getApplicationIcon(info)
        val bitmap = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
        val bytes = try {
            drawable.setBounds(0, 0, bitmap.width, bitmap.height)
            drawable.draw(Canvas(bitmap))
            ByteArrayOutputStream().use {
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
                it.toByteArray()
            }
        } finally {
            bitmap.recycle()
        }

        return mapOf(
            "packageName" to packageName,
            "name" to pm.getApplicationLabel(info).toString(),
            "icon" to bytes
        )
    }

    companion object {
        fun isSystemPackage(pkg: String, launcherPkg: String?): Boolean {
            if (pkg.isBlank()) return true
            if (pkg == launcherPkg) return true
            if (pkg == "com.android.systemui") return true
            if (pkg == "com.google.android.apps.nexuslauncher") return true
            return pkg.startsWith("com.android.launcher") ||
                    pkg.startsWith("com.sec.android.app.launcher") ||
                    pkg.startsWith("com.miui.home")
        }

        // Prawdziwy analizator zdarzeń systemu Android
        fun calculateActiveUsageSeconds(context: Context, startMs: Long, endMs: Long): Map<String, Long> {
            val usm = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
            val pm = context.packageManager
            val homeIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
            val launcherPkg = pm.resolveActivity(homeIntent, 0)?.activityInfo?.packageName
            val myPackage = context.packageName

            val events = usm.queryEvents(startMs, endMs)
            val event = UsageEvents.Event()

            val appUsageMs = mutableMapOf<String, Long>()
            var currentApp: String? = null
            var lastEventTime = startMs

            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                val time = event.timeStamp
                val pkg = event.packageName

                when (event.eventType) {
                    UsageEvents.Event.ACTIVITY_RESUMED,
                    UsageEvents.Event.MOVE_TO_FOREGROUND -> {
                        if (currentApp != null && time > lastEventTime) {
                            val duration = time - lastEventTime
                            appUsageMs[currentApp] = (appUsageMs[currentApp] ?: 0L) + duration
                        }
                        if (pkg == myPackage || isSystemPackage(pkg, launcherPkg)) {
                            currentApp = null
                        } else {
                            currentApp = pkg
                            lastEventTime = time
                        }
                    }

                    UsageEvents.Event.ACTIVITY_PAUSED,
                    UsageEvents.Event.ACTIVITY_STOPPED,
                    UsageEvents.Event.MOVE_TO_BACKGROUND -> {
                        if (currentApp == pkg && time > lastEventTime) {
                            val duration = time - lastEventTime
                            appUsageMs[currentApp] = (appUsageMs[currentApp] ?: 0L) + duration
                            currentApp = null
                        }
                    }

                    UsageEvents.Event.SCREEN_NON_INTERACTIVE,
                    UsageEvents.Event.KEYGUARD_SHOWN -> {
                        // Zablokowanie telefonu lub wyłączenie ekranu
                        if (currentApp != null && time > lastEventTime) {
                            val duration = time - lastEventTime
                            appUsageMs[currentApp] = (appUsageMs[currentApp] ?: 0L) + duration
                            currentApp = null
                        }
                    }
                }
            }

            if (currentApp != null && endMs > lastEventTime) {
                val duration = endMs - lastEventTime
                appUsageMs[currentApp] = (appUsageMs[currentApp] ?: 0L) + duration
            }

            // Konwersja na sekundy
            return appUsageMs.mapValues { it.value / 1000 }
        }
    }

    override fun onDestroy() {
        executor.shutdown()
        super.onDestroy()
    }
}