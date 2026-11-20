package com.muisti.test

import android.content.Context
import com.muisti.privacy.PrivacySettingsRepo
import com.muisti.privacy.PrivacyText

/**
 * One instance per process of what the activity, background workers and tiles share. The memory store must be a
 * single object: two MemoryStore instances on the same files would overwrite each other's deletions.
 */
object AppGraph {
    private lateinit var app: Context
    fun init(ctx: Context) { if (!::app.isInitialized) app = ctx.applicationContext }

    val privacySettings by lazy {
        PrivacySettingsRepo(PrefsStore(app.getSharedPreferences("privacy", Context.MODE_PRIVATE)))
            .also { r -> PrivacyText.enabledProvider = { r.current.sensitiveOcr } }
    }
    /** Loads the on-phone scene model (~45 MB): first use off the main thread. */
    val privacy by lazy { PrivacyGuard(app) { privacySettings.current } }
    val engine by lazy { PhoneEngine(app) }
}
