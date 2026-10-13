package dev.tug.tug_android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecoveryPolicyTest {
    @Test
    fun foregroundResumeRequiresEnabledAndUnchangedIntent() {
        assertTrue(RecoveryPolicy.canResumeOnOpen(true, 3L, 3L))
        assertFalse(RecoveryPolicy.canResumeOnOpen(false, 3L, 3L))
        assertFalse(RecoveryPolicy.canResumeOnOpen(true, 4L, 3L))
    }

    @Test
    fun systemStopBlocksBackgroundRecoveryButNotForegroundIntentCheck() {
        assertFalse(RecoveryPolicy.canStart(true, true, true))
        assertTrue(RecoveryPolicy.canResumeOnOpen(true, 3L, 3L))
        assertTrue(RecoveryPolicy.canStart(true, true, false))
    }

    @Test
    fun userStopIsReconciledOnlyOnceAndOtherExitsDoNotDisableReception() {
        assertTrue(RecoveryPolicy.isNewUserStop(true, 200L, 100L))
        assertFalse(RecoveryPolicy.isNewUserStop(true, 200L, 200L))
        assertFalse(RecoveryPolicy.isNewUserStop(true, 100L, 200L))
        assertFalse(RecoveryPolicy.isNewUserStop(false, 200L, 100L))
    }

    @Test
    fun legacyQueuedBootStartIsRejectedAfterRemoval() {
        assertFalse(RecoveryPolicy.canStart(true, true, legacyRecovery = true))
    }

    @Test
    fun manualAndStickyStartRequireEnabledIntent() {
        assertTrue(RecoveryPolicy.canStart(true, true))
        assertFalse(RecoveryPolicy.canStart(false, true))
    }

    @Test
    fun startIsDeniedWhileDeviceLocked() {
        assertFalse(RecoveryPolicy.canStart(enabled = true, unlocked = false))
    }
}
