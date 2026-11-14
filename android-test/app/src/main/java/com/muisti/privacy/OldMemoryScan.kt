package com.muisti.privacy

/** The stored frames the scan walks over (MemoryStore on the phone, a map in tests). */
interface ScanTarget {
    /** Ids of all stored frames, ascending. */
    fun frameIds(): List<Int>
    /** The stored JPEG, or null if it is gone. */
    fun frameBytes(id: Int): ByteArray?
    /** Deletes frames (record + JPEG + derived data). Returns how many were removed. */
    fun deleteFrames(ids: Set<Int>): Int
}

/**
 * Checks memories stored before the privacy gate existed (or before a class was switched on) and deletes the private
 * ones on the phone. Resumable: the last checked id is saved in the privacy settings every [saveEvery] frames and on
 * every deletion, so a killed app continues where it stopped instead of starting from zero (defect D1).
 * Only frames that existed when the scan started (id <= total) are checked: newer ones already passed the live gate.
 */
class OldMemoryScan(private val repo: PrivacySettingsRepo, private val target: ScanTarget,
                    private val isPrivate: (ByteArray) -> Boolean, private val saveEvery: Int = 10) {

    /** Runs until done or [shouldStop] says so. Returns the status after this run. */
    fun run(shouldStop: () -> Boolean = { false }, onProgress: (ScanStatus) -> Unit = {}): ScanStatus {
        var st = repo.current.scan
        if (st.done) return st
        val ids = target.frameIds()
        if (st.total == 0) st = st.copy(total = ids.maxOrNull() ?: 0)
        if (st.total == 0) return save(st.copy(done = true))
        var sinceSave = 0
        for (id in ids) {
            if (id <= st.lastScannedId) continue
            if (id > st.total) break
            if (shouldStop()) return save(st)
            // fail-closed like the gate: an unreadable frame or a crashing check counts as private
            val bytes = target.frameBytes(id)
            val priv = bytes != null && runCatching { isPrivate(bytes) }.getOrDefault(true)
            st = if (priv) st.copy(lastScannedId = id, removed = st.removed + target.deleteFrames(setOf(id)))
                 else st.copy(lastScannedId = id)
            if (priv || ++sinceSave >= saveEvery) { save(st); sinceSave = 0; onProgress(st) }
        }
        return save(st.copy(lastScannedId = st.total, done = true)).also(onProgress)
    }

    private fun save(st: ScanStatus): ScanStatus { repo.update { it.copy(scan = st) }; return st }

    companion object {
        /** A newly switched-on class must also be applied to older memories: restart the scan. */
        fun restart(s: PrivacySettings): PrivacySettings = s.copy(scan = ScanStatus())
    }
}
