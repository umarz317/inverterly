package com.loopbreak.inverterly.core

import org.junit.Assert.assertEquals
import org.junit.Test

/** Vectors worked out by hand in docs/API.md: the same numbers the iOS tests check. */
class SigningTest {
    @Test fun passwordHash() {
        assertEquals("2f9e53523b62abc141a2b4d6019d23cba835dbd0", DessSigning.sha1Hex("correct horse"))
    }

    @Test fun loginSign() {
        assertEquals("832395bce094bf03c6f743e3b44cfb97ea6ab8fb",
            DessSigning.loginSign(CloudProfile.Dessmonitor, "me@example.com", "correct horse", "1700000000000"))
    }

    @Test fun requestSign() {
        assertEquals("cbf318592d267ff81894df2b0a15f381ee44b400",
            DessSigning.requestSign("0123456789abcdef", "feedfacefeedface", "queryPlants&page=0&pagesize=20&i18n=en_US", "1700000000000"))
    }

    @Test fun usernameIsEncodedLikeJavaScript() {
        assertEquals("me%40example.com", DessSigning.encodeURIComponent("me@example.com"))
        assertEquals("a%20b%C3%A9", DessSigning.encodeURIComponent("a bé"))
        assertEquals("A-z_0.9!~*'()", DessSigning.encodeURIComponent("A-z_0.9!~*'()"))
    }

    @Test fun aSpaceIsSignedEscapedAndSentEncoded() {
        val a = DessSigning.loginSign(CloudProfile.Watchpower, "my name", "pw", "1")
        val b = DessSigning.loginSign(CloudProfile.Watchpower, "my%20name", "pw", "1")
        assertEquals(a, b)
        val url = DessSigning.loginURL(CloudProfile.Watchpower, "my name", "pw", "1")
        assert("usr=my%20name&" in url) { url }
    }
}
