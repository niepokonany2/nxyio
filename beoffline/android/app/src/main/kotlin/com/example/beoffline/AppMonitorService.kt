package com.example.beoffline

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import org.json.JSONObject

class AppMonitorService : Service() {

    companion object {
        @Volatile
        private var running = false

        fun start(context: Context) {
            context.startService(Intent(context, AppMonitorService::class.java))
            running = true
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, AppMonitorService::class.java))
            running = false
        }

        fun isRunning(): Boolean = running

        fun prefs(context: Context) =
            context.getSharedPreferences("beoffline_monitor", Context.MODE_PRIVATE)

        fun clearActiveSession(context: Context) {
            prefs(context).edit()
                .remove("active_package")
                .remove("active_elapsed")
                .remove("active_wall")
                .apply()
        }

        fun dayStart(milliseconds: Long): Long {
            val calendar = java.util.Calendar.getInstance()
            calendar.timeInMillis = milliseconds
            calendar.set(java.util.Calendar.HOUR_OF_DAY, 0)
            calendar.set(java.util.Calendar.MINUTE, 0)
            calendar.set(java.util.Calendar.SECOND, 0)
            calendar.set(java.util.Calendar.MILLISECOND, 0)
            return calendar.timeInMillis
        }

        fun getUsageBetween(
            context: Context,
            start: Long,
            end: Long
        ): JSONObject {
            // Tu powinna być logika zbierająca aktywny czas
            // zwróć JSON z sekundami, nie milisekundami
            return JSONObject()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null
}