package com.example.beoffline

import android.app.Activity
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.CountDownTimer
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class SessionActivity : Activity() {
    private var timer: CountDownTimer? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val pkg = intent.getStringExtra("package_name") ?: ""
        val limitReached = intent.getBooleanExtra("limit_reached", false)
        val prefs = AppMonitorService.prefs(this)

        // Nazwa aplikacji – bez try jako expression
        var appName = pkg.substringAfterLast('.')
        try {
            val info = packageManager.getApplicationInfo(pkg, 0)
            appName = packageManager.getApplicationLabel(info).toString()
        } catch (e: Exception) {
            // zostaje domyślna nazwa
        }

        // Konfiguracja
        val limitsJson = prefs.getString("app_limits", "{}") ?: "{}"
        val config = JSONObject(limitsJson).optJSONObject(pkg)
        val sessionMinutes = config?.optInt("sessionMinutes", 10) ?: 10
        val waitSeconds = config?.optInt("waitSeconds", 30) ?: 30

        // Sesje
        val today = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
        val usageJson = prefs.getString("usage_$today", "{}") ?: "{}"
        val usedMs = JSONObject(usageJson).optLong(pkg, 0)
        val dailyLimitMinutes = config?.optInt("dailyLimitMinutes", 60) ?: 60
        val dailyLimitMs = dailyLimitMinutes * 60L * 1000L
        val totalSessions = (dailyLimitMs / (sessionMinutes * 60L * 1000L))
            .toInt().coerceAtLeast(1)
        val usedSessions = (usedMs / (sessionMinutes * 60L * 1000L)).toInt()
        val remainingSessions = (totalSessions - usedSessions).coerceAtLeast(0)

        // Motyw
        val isDark = (resources.configuration.uiMode and
                Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

        val bg = if (isDark) "#0D0D0D" else "#FAF8F5"
        val txtColor = if (isDark) "#E0E0E0" else "#2C2C2C"
        val subColor = if (isDark) "#A0A0A0" else "#757575"
        val accentColor = if (isDark) "#FFFFFF" else "#556B2F"
        val btnBgColor = if (isDark) "#E8E8E8" else "#556B2F"
        val btnTxtColor = if (isDark) "#0D0D0D" else "#FFFFFF"

        val scroll = ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
        }

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(32), dp(48), dp(32), dp(32))
        }

        // Logo
        root.addView(ImageView(this).apply {
            setImageResource(R.mipmap.ic_launcher)
            layoutParams = LinearLayout.LayoutParams(dp(72), dp(72))
        })
        root.addView(spacer(20))

        // Pytanie
        root.addView(TextView(this).apply {
            text = if (limitReached) "Limit dzienny osiągnięty!"
                   else "Po co otwierasz tę aplikację?"
            textSize = 22f
            setTextColor(Color.parseColor(txtColor))
            gravity = Gravity.CENTER
            setTypeface(null, Typeface.BOLD)
        })
        root.addView(spacer(8))

        // Nazwa aplikacji
        root.addView(TextView(this).apply {
            text = appName
            textSize = 18f
            setTextColor(Color.parseColor(accentColor))
            gravity = Gravity.CENTER
            setTypeface(null, Typeface.BOLD)
        })
        root.addView(spacer(16))

        // Kropki sesji
        val dots = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        for (i in 0 until totalSessions.coerceAtMost(12)) {
            dots.addView(TextView(this).apply {
                text = "\u25CF"
                textSize = 14f
                setTextColor(Color.parseColor(
                    if (i < remainingSessions) accentColor
                    else if (isDark) "#333333" else "#E0E0E0"
                ))
                setPadding(dp(3), 0, dp(3), 0)
            })
        }
        root.addView(dots)
        root.addView(spacer(8))

        root.addView(TextView(this).apply {
            text = "$remainingSessions / $totalSessions sesji pozostało"
            textSize = 15f
            setTextColor(Color.parseColor(subColor))
            gravity = Gravity.CENTER
        })
        root.addView(spacer(24))

        // Odliczanie
        val countdownView = TextView(this).apply {
            text = if (limitReached) "Brak sesji" else "${waitSeconds}s"
            textSize = 40f
            setTextColor(Color.parseColor(txtColor))
            gravity = Gravity.CENTER
            setTypeface(null, Typeface.BOLD)
        }
        root.addView(countdownView)
        root.addView(spacer(32))

        // Przycisk "Otwórz"
        val openBtn = Button(this).apply {
            text = "Otwórz"
            textSize = 16f
            setTextColor(Color.parseColor(btnTxtColor))
            setBackgroundColor(Color.parseColor(btnBgColor))
            isEnabled = !limitReached && waitSeconds == 0
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).also { it.topMargin = dp(8); it.bottomMargin = dp(8) }
            setPadding(dp(24), dp(16), dp(24), dp(16))
            setOnClickListener {
                if (!limitReached) {
                    val session = JSONObject().apply {
                        put("packageName", pkg)
                        put("startTime", System.currentTimeMillis())
                        put("endTime",
                            System.currentTimeMillis() + sessionMinutes * 60L * 1000L)
                        put("durationMs", sessionMinutes * 60L * 1000L)
                    }
                    prefs.edit()
                        .putString("active_session", session.toString())
                        .apply()

                    val launch = packageManager.getLaunchIntentForPackage(pkg)
                    if (launch != null) {
                        launch.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        startActivity(launch)
                    }
                }
                finish()
            }
        }
        root.addView(openBtn)

        // Przycisk "Zamknij"
        root.addView(Button(this).apply {
            text = "Zamknij"
            textSize = 16f
            setTextColor(Color.parseColor(subColor))
            setBackgroundColor(Color.TRANSPARENT)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
            setPadding(dp(24), dp(16), dp(24), dp(16))
            setOnClickListener { finish() }
        })

        scroll.addView(root)
        setContentView(scroll)

        // Timer odliczania
        if (!limitReached && waitSeconds > 0) {
            timer = object : CountDownTimer(waitSeconds * 1000L, 1000L) {
                override fun onTick(millisUntilFinished: Long) {
                    countdownView.text = "${(millisUntilFinished / 1000).toInt()}s"
                }
                override fun onFinish() {
                    countdownView.text = "Gotowe!"
                    openBtn.isEnabled = true
                }
            }.start()
        }
    }

    private fun dp(v: Int): Int =
        (v * resources.displayMetrics.density).toInt()

    private fun spacer(h: Int): View =
        View(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, h
            )
        }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {}

    override fun onDestroy() {
        timer?.cancel()
        super.onDestroy()
    }
}