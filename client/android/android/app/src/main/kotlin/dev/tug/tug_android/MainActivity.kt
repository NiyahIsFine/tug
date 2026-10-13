package dev.tug.tug_android

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var permissionResult: MethodChannel.Result? = null
    private val permissionRequestCode = 7411
    private val settingsRequestCode = 7412

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ReceiveIntentChannel.install(applicationContext, flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.tug/notification_permission")
            .setMethodCallHandler { call, result ->
                if (call.method != "request") {
                    result.notImplemented()
                } else if (permissionResult != null) {
                    result.error("busy", "Notification permission request is pending.", null)
                } else if (getSystemService(NotificationManager::class.java).areNotificationsEnabled()) {
                    result.success(null)
                } else {
                    permissionResult = result
                    val preferences = getSharedPreferences("tug_receive_intent", MODE_PRIVATE)
                    val attempted = preferences.getBoolean("notification_permission_attempted", false)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
                        (!attempted || shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS))) {
                        if (!preferences.edit().putBoolean("notification_permission_attempted", true).commit()) {
                            permissionResult = null
                            result.error("storage", "Permission state could not be saved.", null)
                        } else {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), permissionRequestCode)
                        }
                    } else {
                        val notificationSettings = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                        } else {
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
                        }
                        try {
                            startActivityForResult(notificationSettings, settingsRequestCode)
                        } catch (_: Exception) {
                            try {
                                startActivityForResult(
                                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")),
                                    settingsRequestCode,
                                )
                            } catch (_: Exception) {
                                permissionResult = null
                                result.error("unavailable", "Notification settings could not be opened.", null)
                            }
                        }
                    }
                }
            }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == permissionRequestCode) finishPermissionRequest()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == settingsRequestCode) finishPermissionRequest()
    }

    private fun finishPermissionRequest() {
        val result = permissionResult
        permissionResult = null
        result?.success(null)
    }

    override fun onDestroy() {
        permissionResult?.error("cancelled", "Activity was closed.", null)
        permissionResult = null
        super.onDestroy()
    }
}
