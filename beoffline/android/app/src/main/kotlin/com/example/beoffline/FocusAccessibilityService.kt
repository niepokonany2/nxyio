package com.example.beoffline

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.widget.Toast
import org.json.JSONObject
import java.util.Calendar

class FocusAccessibilityService : AccessibilityService() {

    // false = bramka tylko przed NOWĄ sesją (wznowienie bez bramki) - ZALECANE
    // true = bramka przy KAŻDYM wejściu, nawet wznowieniu pauzy
    private val ALWAYS_GATE_ON_RESUME = false

    private val handler = Handler(Looper.getMainLooper())
    private var currentForegroundPackage: String? = null
    private var lastGatePackage: String? = null
    private var lastGateTime = 0L
    private var sessionCheckRunnable: Runnable? = null
    private var launcherPackage: String? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        launcherPackage = findLauncherPackage()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event?.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val pkg = event.packageName?.toString() ?: return

        // Duplikat tego samego okna - ignoruj
        if (pkg == currentForegroundPackage) return

        currentForegroundPackage = pkg

        // Własna apka, launcher, system - pauzuj, nie licz
        if (isIgnoredPackage(pkg)) {
            cancelSessionCheck()
            return
        }

        val limits = getAppLimits()
        if (!limits.has(pkg)) {
            cancelSessionCheck()
            return
        }

        val cfg = limits.getJSONObject(pkg)
        val dailyMinutes = cfg.optInt("dailyLimitMinutes", 60)
        val sessionMinutes = cfg.optInt("sessionMinutes", 10)
        val waitSeconds = cfg.optInt("waitSeconds", 30)
        val sessionSec = sessionMinutes * 60

        val totalSessions = if (sessionSec <= 0) 1
            else (dailyMinutes * 60 + sessionSec - 1) / sessionSec
        val usedTodaySec = getUsedTodaySec(pkg)
        val dailyLimitSec = dailyMinutes * 60

        // Limit dzienny wyczerpany - pokaż bramkę z blokadą
        if (dailyLimitSec > 0 && usedTodaySec >= dailyLimitSec) {
            showGate(pkg, dailyMinutes, sessionMinutes, waitSeconds, totalSessions, 0)
            return
        }

        // Aktywna sesja z zapasem? Wpuść bez bramki
        if (!ALWAYS_GATE_ON_RESUME) {
            val remaining = getRemainingSessionSec(pkg)
            if (remaining > 0) {
                startSessionCheck(pkg)
                return
            }
        }

        // Debounce 2s żeby nie wystrzelić 2 bramek na 1 otwarcie
        val now = SystemClock.elapsedRealtime()
        if (pkg == lastGatePackage && now - lastGateTime < 2000) return
        lastGatePackage = pkg
        lastGateTime = now

        val usedSessions = if (sessionSec <= 0) 0 else (usedTodaySec / sessionSec).toInt()
        val remainingSessions = (totalSessions - usedSessions).coerceAtLeast(0)

        showGate(pkg, dailyMinutes, sessionMinutes, waitSeconds, totalSessions, remainingSessions)
    }

    private fun showGate(
        pkg: String, dailyMin: Int, sessionMin: Int, waitSec: Int,
        total: Int, remaining: Int
    ) {
        cancelSessionCheck()
        val appName = try {
            packageManager.getApplicationLabel(
                packageManager.getApplicationInfo(pkg, 0)
            ).toString()
        } catch (_: Exception) { pkg.substringAfterLast('.') }

        val intent = Intent(this, GateActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_NO_ANIMATION)
            putExtra("EXTRA_PACKAGE", pkg)
            putExtra("EXTRA_APP_NAME", appName)
            putExtra("EXTRA_DAILY_MINUTES", dailyMin)
            putExtra("EXTRA_SESSION_MINUTES", sessionMin)
            putExtra("EXTRA_WAIT_SECONDS", waitSec)
            putExtra("EXTRA_REMAINING_SESSIONS", remaining)
            putExtra("EXTRA_TOTAL_SESSIONS", total)
        }
        startActivity(intent)
    }

    private fun startSessionCheck(pkg: String) {
        cancelSessionCheck()
        val r = object : Runnable {
            override fun run() {
                // Pauza - wyszedł z apki, nie sprawdzaj dalej
                if (currentForegroundPackage != pkg) return

                val remaining = getRemainingSessionSec(pkg)
                val usedToday = getUsedTodaySec(pkg)
                val dailyLimit = getDailyLimitSec(pkg)

                if (remaining <= 0 || (dailyLimit > 0 && usedToday >= dailyLimit)) {
                    endSessionAndKickOut(pkg)
                    return
                }
                handler.postDelayed(this, 1000)
            }
        }
        sessionCheckRunnable = r
        handler.postDelayed(r, 1000)
    }

    private fun cancelSessionCheck() {
        sessionCheckRunnable?.let { handler.removeCallbacks(it) }
        sessionCheckRunnable = null
    }

    private fun endSessionAndKickOut(pkg: String) {
        clearSession(pkg)
        cancelSessionCheck()
        performGlobalAction(GLOBAL_ACTION_HOME)
        Toast.makeText(applicationContext, "Koniec sesji! Czas na przerwę.", Toast.LENGTH_LONG).show()
    }

    private fun getRemainingSessionSec(pkg: String): Long {
        val prefs = getSharedPreferences("beoffline_sessions", Context.MODE_PRIVATE)
        val sessions = try {
            JSONObject(prefs.getString("active_sessions", "{}") ?: "{}")
        } catch (_: Exception) { JSONObject() }

        if (!sessions.has(pkg)) return 0
        val entry = sessions.getJSONObject(pkg)
        val startUsage = entry.optLong("startUsageSec", 0L)
        val duration = entry.optLong("durationSec", 0L)
        if (duration <= 0) return 0

        val currentUsage = getUsedTodaySec(pkg)
        val usedInSession = (currentUsage - startUsage).coerceAtLeast(0L)
        val remaining = duration - usedInSession

        if (remaining <= 0) {
            clearSession(pkg)
            return 0
        }
        return remaining
    }

    private fun clearSession(pkg: String) {
        val prefs = getSharedPreferences("beoffline_sessions", Context.MODE_PRIVATE)
        val sessions = try {
            JSONObject(prefs.getString("active_sessions", "{}") ?: "{}")
        } catch (_: Exception) { JSONObject() }
        sessions.remove(pkg)
        prefs.edit().putString("active_sessions", sessions.toString()).apply()
    }

    private fun getUsedTodaySec(pkg: String): Long {
        val now = System.currentTimeMillis()
        val cal = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        return try {
            MainActivity.calculateActiveUsageSeconds(applicationContext, cal.timeInMillis, now)[pkg] ?: 0L
        } catch (_: Exception) { 0L }
    }

    private fun getDailyLimitSec(pkg: String): Long {
        val limits = getAppLimits()
        if (!limits.has(pkg)) return 0
        return limits.getJSONObject(pkg).optInt("dailyLimitMinutes", 0) * 60L
    }

    private fun getAppLimits(): JSONObject {
        val prefs = getSharedPreferences("beoffline_sessions", Context.MODE_PRIVATE)
        return try {
            JSONObject(prefs.getString("app_limits", "{}") ?: "{}")
        } catch (_: Exception) { JSONObject() }
    }

    private fun isIgnoredPackage(pkg: String): Boolean {
        if (pkg == packageName) return true // własna apka + GateActivity
        if (pkg == "com.android.systemui") return true
        if (pkg == launcherPackage) return true
        if (pkg.contains("launcher")) return true
        return false
    }

    private fun findLauncherPackage(): String? {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        return packageManager.resolveActivity(intent, 0)?.activityInfo?.packageName
    }

    override fun onInterrupt() {
        cancelSessionCheck()
    }
}