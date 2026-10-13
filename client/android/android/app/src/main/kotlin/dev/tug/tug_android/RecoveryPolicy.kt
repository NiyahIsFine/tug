package dev.tug.tug_android

object RecoveryPolicy {
    fun isNewUserStop(userRequested: Boolean, timestamp: Long, checkedAt: Long): Boolean =
        userRequested && timestamp > checkedAt

    fun canResumeOnOpen(enabled: Boolean, revision: Long, expectedRevision: Long): Boolean =
        enabled && revision == expectedRevision

    fun canStart(
        enabled: Boolean,
        unlocked: Boolean,
        backgroundBlocked: Boolean = false,
        legacyRecovery: Boolean = false,
    ): Boolean = enabled && unlocked && !backgroundBlocked && !legacyRecovery
}
