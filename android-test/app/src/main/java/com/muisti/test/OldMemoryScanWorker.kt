package com.muisti.test

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.muisti.privacy.OldMemoryScan
import com.muisti.privacy.ScanTarget
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Runs the resumable scan of older memories (OldMemoryScan) in WorkManager: it survives the app being killed,
 * stops when the constraints stop holding, and continues from the saved id on the next run.
 */
class OldMemoryScanWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result = withContext(Dispatchers.Default) {
        AppGraph.init(applicationContext)
        val guard = AppGraph.privacy
        if (!guard.available) { Log.w(TAG, "privacy model missing: scan postponed"); return@withContext Result.retry() }
        val store = AppGraph.engine.store
        val target = object : ScanTarget {
            override fun frameIds() = store.frameIds()
            override fun frameBytes(id: Int) = store.frameBytes(id)
            override fun deleteFrames(ids: Set<Int>) = store.deleteFrames(ids)
        }
        val before = AppGraph.privacySettings.current.scan
        Log.i(TAG, "old memory scan: start after id ${before.lastScannedId} of ${before.total}")
        val st = OldMemoryScan(AppGraph.privacySettings, target, guard::isPrivateImage).run(shouldStop = { isStopped })
        Log.i(TAG, "old memory scan: at id ${st.lastScannedId}/${st.total}${if (st.done) " (done)" else ""}")
        if (st.done) Log.i(TAG, "old memory scan: removed ${st.removed}")
        if (st.done) Result.success() else Result.retry()
    }

    companion object {
        const val TAG = "MuistiPrivacy"
        private const val NAME = "old-memory-scan"

        /** In the background, only while the battery is not low and the phone is idle. */
        fun schedule(ctx: Context) = enqueue(ctx,
            Constraints.Builder().setRequiresBatteryNotLow(true).setRequiresDeviceIdle(true).build(), ExistingWorkPolicy.KEEP)

        /** "Check now" from the privacy screen: battery constraint only. */
        fun now(ctx: Context) = enqueue(ctx, Constraints.Builder().setRequiresBatteryNotLow(true).build(), ExistingWorkPolicy.REPLACE)

        private fun enqueue(ctx: Context, c: Constraints, policy: ExistingWorkPolicy) {
            if (AppGraph.privacySettings.current.scan.done) return
            WorkManager.getInstance(ctx).enqueueUniqueWork(NAME, policy,
                OneTimeWorkRequestBuilder<OldMemoryScanWorker>().setConstraints(c).build())
        }
    }
}
