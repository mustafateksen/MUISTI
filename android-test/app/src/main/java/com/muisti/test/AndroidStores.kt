package com.muisti.test

import android.content.SharedPreferences
import com.muisti.privacy.KeyValueStore

/** SharedPreferences as the settings store (commit(): the value is on disk before the call returns). */
class PrefsStore(private val prefs: SharedPreferences) : KeyValueStore {
    override fun get(key: String): String? = prefs.getString(key, null)
    override fun put(key: String, value: String) { prefs.edit().putString(key, value).commit() }
}
