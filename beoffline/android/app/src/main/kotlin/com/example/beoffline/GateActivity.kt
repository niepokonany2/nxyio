package com.example.beoffline

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.CountDownTimer
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject
import java.util.Calendar

class GateActivity : Activity() {

    private var countDownTimer: CountDownTimer? = null
    private var targetPackage: String = ""
    private var sessionMinutes: Int = 10

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_gate)

        targetPackage = intent.getStringExtra("EXTRA_PACKAGE") ?: ""
        val appName = intent.getStringExtra("EXTRA_APP_NAME") ?: targetPackage.substringAfterLast('.')
        val sessionMin = intent.getIntExtra("EXTRA_SESSION_MINUTES", 10)
        val waitSeconds = intent.getIntExtra("EXTRA_WAIT_SECONDS", 30)
        val remainingSessions = intent.getIntExtra("EXTRA_REMAINING_SESSIONS", 1)
        val totalSessions = intent.getIntExtra("EXTRA_TOTAL_SESSIONS", 1)
        sessionMinutes = sessionMin

        val txtAppName = findViewById<TextView>(R.id.gateAppName)
        val txtSessionInfo = findViewById<TextView>(R.id.gateSessionInfo)
        val txtTimer = findViewById<TextView>(R.id.gateTimerText)
        val dotsContainer = findViewById<LinearLayout>(R.id.gateDotsContainer)
        val btnOpen = findViewById<Button>(R.id.btnOpenApp)
        val btnClose = findViewById<Button>(R.id.btnCloseApp)

        txtAppName.text = appName
        txtSessionInfo.text = "Pozostałe sesje: $remainingSessions z $totalSessions"

        dotsContainer.removeAllViews()
        for (i in 0 until totalSessions.coerceAtMost(12)) {
            val dot = View(this).apply {
                val size = 28
                layoutParams = LinearLayout.LayoutParams(size, size).apply {
                    setMargins(8, 0, 8, 0)
                }
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(if (i < remainingSessions) Color.parseColor("#FFFFFF") else Color.parseColor("#444444"))
                }
            }
            dotsContainer.addView(dot)
        }

        if (remainingSessions <= 0) {
            txtTimer.text = "Limit wyczerpany"
            txtTimer.textSize = 20f
            findViewById<TextView>(R.id.gateTimerHint).text = "Dzisiejszy limit został osiągnięty."
            btnOpen.visibility = View.GONE
        } else if (waitSeconds <= 0) {
            txtTimer.text = "Gotowe!"
            btnOpen.isEnabled = true
            btnOpen.setBackgroundColor(Color.parseColor("#FFFFFF"))
            btnOpen.setTextColor(Color.parseColor("#000000"))
        } else {
            countDownTimer = object : CountDownTimer((waitSeconds * 1000).toLong(), 1000) {
                override fun onTick(millisUntilFinished: Long) {
                    val sec = (millisUntilFinished / 1000) + 1
                    txtTimer.text = String.format("00:%02d", sec)
                }
                override fun onFinish() {
                    txtTimer.text = "Gotowe!"
                    btnOpen.isEnabled = true
                    btnOpen.setBackgroundColor(Color.parseColor("#FFFFFF"))
                    btnOpen.setTextColor(Color.parseColor("#000000"))
                }
            }.start()
        }

        btnOpen.setOnClickListener {
            // Zapisz NOWĄ sesję: start = aktualne zużycie dzisiaj
            val prefs = getSharedPreferences("beoffline_sessions", Context.MODE_PRIVATE)
            prefs.edit().remove("active_focus_session").apply() // migracja ze starego

            val cal = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
            }
            val now = System.currentTimeMillis()
            val usageMap = try {
                MainActivity.calculateActiveUsageSeconds(applicationContext, cal.timeInMillis, now)
            } catch (_: Exception) { emptyMap() }
            val startUsage = usageMap[targetPackage] ?: 0L

            val sessions = try {
                JSONObject(prefs.getString("active_sessions", "{}") ?: "{}")
            } catch (_: Exception) { JSONObject() }

            sessions.put(targetPackage, JSONObject().apply {
                put("startUsageSec", startUsage)
                put("durationSec", sessionMinutes * 60)
                put("createdAt", now)
            })
            prefs.edit().putString("active_sessions", sessions.toString()).apply()

            val launchIntent = packageManager.getLaunchIntentForPackage(targetPackage)
            if (launchIntent != null) {
                launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(launchIntent)
            }
            finish()
        }

        btnClose.setOnClickListener {
            // Zamknięcie NIE zużywa sesji
            val homeIntent = Intent(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_HOME)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(homeIntent)
            finish()
        }
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        val homeIntent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_HOME)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        startActivity(homeIntent)
        finish()
    }

    override fun onDestroy() {
        countDownTimer?.cancel()
        super.onDestroy()
    }
}