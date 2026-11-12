package com.example.beoffline

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.*
import org.json.JSONObject
import java.util.*
import java.util.concurrent.TimeUnit

class UsageMonitorWorker(
    private val context: Context,
    params: WorkerParameters
) : Worker(context, params) {

    override fun doWork(): Result {
        checkAppLimitsAndNotify()
        return Result.success()
    }

    private fun checkAppLimitsAndNotify() {
        val prefs = context.getSharedPreferences("beoffline_sessions", Context.MODE_PRIVATE)
        val limitsJson = prefs.getString("app_limits", "{}") ?: "{}"
        if (limitsJson == "{}") return

        val limits = JSONObject(limitsJson)
        val now = System.currentTimeMillis()

        val cal = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        val startOfDay = cal.timeInMillis

        val usage = MainActivity.calculateActiveUsageSeconds(context, startOfDay, now)

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "beoffline_alerts"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Alerty limitów beOFFline",
                NotificationManager.IMPORTANCE_HIGH
            )
            nm.createNotificationChannel(channel)
        }

        for (pkg in limits.keys()) {
            val limitConfig = limits.getJSONObject(pkg)
            val dailyLimitMin = limitConfig.optInt("dailyLimitMinutes", 0)
            if (dailyLimitMin <= 0) continue

            val dailyLimitSec = dailyLimitMin * 60
            val usedSec = usage[pkg] ?: 0L
            val pct = (usedSec.toDouble() / dailyLimitSec * 100).toInt()

            val notifiedKey = "notified_${pkg}_${cal.get(Calendar.DAY_OF_YEAR)}"
            val lastNotifiedPct = prefs.getInt(notifiedKey, 0)

            val triggerLevel = when {
                pct >= 100 && lastNotifiedPct < 100 -> 100
                pct >= 80 && lastNotifiedPct < 80 -> 80
                pct >= 50 && lastNotifiedPct < 50 -> 50
                else -> null
            }

            if (triggerLevel != null) {
                val appName = pkg.substringAfterLast('.')
                val message = when (triggerLevel) {
                    100 -> "Osiągnięto dzienny limit dla $appName! Czas odłożyć telefon 📵"
                    80 -> "Wykorzystano 80% limitu dla $appName."
                    else -> "Połowa limitu dla $appName minęła."
                }

                val notification = NotificationCompat.Builder(context, channelId)
                    .setSmallIcon(android.R.drawable.ic_dialog_alert)
                    .setContentTitle("beOFFline")
                    .setContentText(message)
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .setAutoCancel(true)
                    .build()

                nm.notify(pkg.hashCode(), notification)
                prefs.edit().putInt(notifiedKey, triggerLevel).apply()
            }
        }
    }

    companion object {
        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<UsageMonitorWorker>(15, TimeUnit.MINUTES).build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                "beoffline_usage_worker",
                ExistingPeriodicWorkPolicy.KEEP,
                request
            )
        }
    }
}