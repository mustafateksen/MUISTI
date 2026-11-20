package com.muisti.privacy

/** The verdict on one image that wants to leave the phone. */
sealed class Decision {
    object Allow : Decision()
    data class Block(val reason: String) : Decision()
}

/**
 * THE single check every outgoing image passes (called by Llm.imagePart, the only place that builds an image request).
 * Implementations must be fail-closed; Llm also treats any exception as Block.
 */
fun interface PrivacyGate {
    fun check(jpeg: ByteArray): Decision

    companion object {
        /** Nothing leaves: the default until the on-phone model is loaded. */
        val CLOSED = PrivacyGate { Decision.Block("privacy check not ready") }
        /** JVM evaluation only (no phone model): everything may leave. Never used by the app. */
        val OPEN = PrivacyGate { Decision.Allow }
    }
}
