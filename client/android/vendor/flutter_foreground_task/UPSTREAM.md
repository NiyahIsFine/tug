# Foreground service compatibility patch

## Source

This directory contains an Android-only copy of `flutter_foreground_task` 11.0.3 from the official pub.dev archive, downloaded on 2026-10-11. The upstream MIT license is retained in `LICENSE`. Only Dart library files, Android runtime sources, and Android build files are included. iOS support, examples, and upstream tests are omitted.

## Plugin changes

- Disable alarm-based restarts. Upstream `onTaskRemoved` schedules a one-second alarm even when `allowAutoRestart` is false; `onDestroy` can schedule a five-second alarm. Both `RestartReceiver.setRestartAlarm` calls in `ForegroundService.kt` are replaced with cancellation.
- Add an optional `ForegroundService.startGuard` to check whether a service request is allowed before creating the Dart task. A rejected legacy request leaves an existing, otherwise allowed service running.
- Reuse an existing Dart task for duplicate `API_START`, `REBOOT`, and `RESTART` requests. `API_STOP` still stops the service; an allowed `API_RESTART` still recreates the task.

These changes do not alter Tug's shared Dart receiver, WebSocket protocol, or message notifications. The machine-wide Pub cache is not modified.

## Tug integration

- `TugApplication` installs the startup guard. It requires an unlocked device, receiving enabled, and no recorded background block. Requests carrying the legacy `dev.tug.recovery_revision` extra are rejected.
- The app records detected system user-stop events and blocks background restarts. Opening Tug can clear this block only if receiving is still enabled and the saved revision matches. Selecting Stop keeps receiving off.
- Boot and package-update recovery are disabled. The merged manifest removes `RebootReceiver`, `RestartReceiver`, and the boot permission. Tug does not register a replacement boot receiver.
- `autoRunOnBoot`, `autoRunOnMyPackageReplaced`, `allowAutoRestart`, `allowWakeLock`, and `allowWifiLock` are false.

Android's `START_STICKY` behavior remains subject to the startup guard and system restrictions. It does not guarantee continued receiving or service recovery.

## Upgrades and validation

When updating the upstream plugin, review these patches, the app manifest, and the startup guard together. Keep the upstream license and update the source version above. Run the Android Dart tests, native policy tests, and release build. Device lifecycle and background behavior still require device testing.
