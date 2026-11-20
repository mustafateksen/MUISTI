package com.muisti.engine

import com.muisti.privacy.KeyValueStore
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TokenClientTest {
    private class MapStore : KeyValueStore {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun put(key: String, value: String) { m[key] = value }
    }

    @Test
    fun pairsOnceThenUsesShortLivedTokens() {
        var issued = 0
        CountingServer { path, body ->
            when (path) {
                "/proxy/pair" -> { assertEquals("482913", JSONObject(body).getString("code")); """{"device_secret":"S1"}""" }
                "/proxy/token" -> { assertEquals("S1", JSONObject(body).getString("device_secret")); issued++; """{"token":"T$issued","expires_in":3600}""" }
                else -> "{}"
            }
        }.use { srv ->
            var clock = 1_000_000L
            val store = MapStore()
            val c = TokenClient(store) { clock }
            assertFalse(c.paired)
            assertEquals("not paired: no token, no request", "", c.token())
            assertEquals(0, srv.hits.get())
            c.pair(srv.url, " 482913 ")
            assertTrue(c.paired)
            assertEquals("T1", c.token())
            assertEquals("T1", c.token())                       // cached
            clock += 3600_000 - 30_000                           // less than a minute left: refreshed
            assertEquals("T2", c.token())
            // survives a restart: the device secret is stored, the token is not
            assertEquals("T3", TokenClient(store) { clock }.token())
            assertFalse("no key is ever stored", store.m.values.any { it.startsWith("dc_") })
        }
    }
}
