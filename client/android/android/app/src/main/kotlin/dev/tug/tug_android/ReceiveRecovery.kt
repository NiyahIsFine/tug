package dev.tug.tug_android

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.Intent
import android.os.UserManager
import android.os.Build

object ReceiveRecovery {
    fun reconcileUserStop(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R ||
            !context.getSystemService(UserManager::class.java).isUserUnlocked) return
        synchronized(ReceiveIntentChannel.lock) {
            val preferences = context.getSharedPreferences("tug_receive_intent", Context.MODE_PRIVATE)
            try {
                val exit = context.getSystemService(ActivityManager::class.java)
                    .getHistoricalProcessExitReasons(context.packageName, 0, 1).firstOrNull() ?: return
                val checkedAt = preferences.getLong("exit_checked_at", 0L)
                if (exit.timestamp <= checkedAt) return
                val editor = preferences.edit().putLong("exit_checked_at", exit.timestamp)
                if (RecoveryPolicy.isNewUserStop(
                        exit.reason == ApplicationExitInfo.REASON_USER_REQUESTED,
                        exit.timestamp,
                        checkedAt,
                    ) && preferences.getBoolean("enabled", false)) {
                    editor.putBoolean("background_blocked", true)
                        .putLong("revision", preferences.getLong("revision", 0L) + 1L)
                        .putString("recovery_error",
                            "Background service paused. Open Tug to resume."
                        )
                }
                editor.commit()
            } catch (_: Exception) {
                preferences.edit().putBoolean("background_blocked", true)
                    .putLong("revision", preferences.getLong("revision", 0L) + 1L)
                    .putString("recovery_error",
                        "Background service unavailable. Open Tug to resume."
                    ).commit()
            }
        }
    }

    fun allowServiceStart(context: Context, intent: Intent?): Boolean =
        synchronized(ReceiveIntentChannel.lock) {
            if (!context.getSystemService(UserManager::class.java).isUserUnlocked) {
                return@synchronized false
            }
            val preferences = context.getSharedPreferences("tug_receive_intent", Context.MODE_PRIVATE)
            val allowed = RecoveryPolicy.canStart(
                enabled = preferences.getBoolean("enabled", false),
                unlocked = true,
                backgroundBlocked = preferences.getBoolean("background_blocked", false),
                legacyRecovery = intent?.hasExtra("dev.tug.recovery_revision") == true,
            )
            if (allowed) {
                preferences.edit().remove("recovery_error").commit()
            }
            allowed
        }
}
