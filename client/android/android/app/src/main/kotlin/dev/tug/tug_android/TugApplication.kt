package dev.tug.tug_android

import android.app.Application
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import com.pravera.flutter_foreground_task.service.ForegroundService
import io.flutter.embedding.engine.FlutterEngine

class TugApplication : Application(), FlutterForegroundTaskLifecycleListener {
    override fun onCreate() {
        super.onCreate()
        synchronized(ReceiveIntentChannel.lock) {
            val preferences = getSharedPreferences("tug_receive_intent", MODE_PRIVATE)
            if (preferences.contains("boot_recovery") || preferences.contains("auto_connect")) {
                preferences.edit().remove("boot_recovery").remove("auto_connect").commit()
            }
        }
        ReceiveRecovery.reconcileUserStop(applicationContext)
        ForegroundService.startGuard = ReceiveRecovery::allowServiceStart
        ForegroundService.addTaskLifecycleListener(this)
    }

    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
        flutterEngine?.let { ReceiveIntentChannel.install(applicationContext, it) }
    }

    override fun onTaskStart(starter: FlutterForegroundTaskStarter) {}
    override fun onTaskRepeatEvent() {}
    override fun onTaskDestroy() {}
    override fun onEngineWillDestroy() {}
}
