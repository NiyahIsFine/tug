package dev.tug.tug_android

import android.content.Context
import android.app.ActivityManager
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object ReceiveIntentChannel {
    val lock = Any()

    fun install(context: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "dev.tug/receive_intent")
            .setMethodCallHandler { call, result ->
                synchronized(lock) {
                    val preferences = context.getSharedPreferences("tug_receive_intent", Context.MODE_PRIVATE)
                    val revision = preferences.getLong("revision", 0L)
                    when (call.method) {
                        "read_preferences" -> result.success(mapOf(
                            "recovery_error" to preferences.getString("recovery_error", null),
                        ))
                        "claim_notification_prompt" -> {
                            val handled = preferences.getBoolean("notification_prompt_handled", false)
                            if (handled) {
                                result.success(false)
                            } else if (!preferences.edit().putBoolean("notification_prompt_handled", true).commit()) {
                                result.error("storage", "Preferences could not be saved.", null)
                            } else {
                                result.success(true)
                            }
                        }
                        "background_restricted" -> result.success(
                            try {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
                                    context.getSystemService(ActivityManager::class.java).isBackgroundRestricted
                                else null
                            } catch (_: Exception) {
                                null
                            }
                        )
                        "recovery_error" -> {
                            val error = call.argument<String>("error")
                            if (error == null || error.length > 512) {
                                result.error("invalid", "Invalid recovery error.", null)
                            } else if (!preferences.edit().putString("recovery_error", error).commit()) {
                                result.error("storage", "Recovery error could not be saved.", null)
                            } else {
                                result.success(null)
                            }
                        }
                        "read" -> result.success(mapOf(
                            "enabled" to preferences.getBoolean("enabled", false),
                            "revision" to revision,
                        ))
                        "resume_foreground" -> {
                            val expected = call.argument<Number>("expected_revision")?.toLong()
                            if (expected == null || !RecoveryPolicy.canResumeOnOpen(
                                    enabled = preferences.getBoolean("enabled", false),
                                    revision = revision,
                                    expectedRevision = expected,
                                )) {
                                result.error("conflict", "Receive intent has changed.", null)
                            } else if (!preferences.edit().remove("background_blocked")
                                    .remove("recovery_error").commit()) {
                                result.error("storage", "Foreground resume could not be saved.", null)
                            } else {
                                result.success(null)
                            }
                        }
                        "set" -> {
                            val enabled = call.argument<Boolean>("enabled")
                            val expected = call.argument<Number>("expected_revision")?.toLong()
                            if (enabled == null || (enabled && expected == null)) {
                                result.error("invalid", "Starting requires an expected revision.", null)
                            } else if (expected != null && expected != revision) {
                                result.error("conflict", "Receive intent has changed.", null)
                            } else if (!preferences.edit().putBoolean("enabled", enabled)
                                    .putLong("revision", revision + 1)
                                    .remove("background_blocked").remove("recovery_error").commit()) {
                                result.error("storage", "Receive intent could not be saved.", null)
                            } else {
                                result.success(mapOf("enabled" to enabled, "revision" to revision + 1))
                            }
                        }
                        else -> result.notImplemented()
                    }
                }
            }
    }
}
