package com.itda.itda_mobile

import android.security.NetworkSecurityPolicy
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class StagingConfigurationTest {
    @Test
    fun stagingUsesSeparateRealmAndHttpsForApiAuthAndCapabilities() {
        val staging = checkNotNull(UploadConfig.create("staging", API, AUTH, KEY, debug = true))
        val live = checkNotNull(UploadConfig.create("live", API, AUTH, KEY, debug = false))
        assertNotEquals(staging.realm, live.realm)
        assertEquals("https://api.staging.example.test/itda/v1/contents", staging.api("v1/contents").toString())
        assertEquals("https://auth.staging.example.test/auth/v1/token?grant_type=password",
            staging.tokenEndpoint("password").toString())
        assertTrue(staging.capability("https://storage.staging.example.test/upload?token=synthetic").isHttps)
        assertThrows(UploadProblem::class.java) {
            staging.capability("http://storage.staging.example.test/upload?token=synthetic")
        }
        assertNull(UploadConfig.create("staging", API, AUTH, KEY, debug = false))
    }

    @Test
    fun rejectsUnsafeSettingsAndRestrictsMockToDebugLoopback() {
        for (endpoint in listOf(
            "http://api.staging.example.test", "https:api.staging.example.test",
            "https://name:secret@api.staging.example.test", "https://@api.staging.example.test",
            "https://api.staging.example.test?access_token=synthetic", "https://api.staging.example.test#fragment",
        )) {
            assertNull(UploadConfig.create("staging", endpoint, AUTH, KEY, debug = true))
            assertNull(UploadConfig.create("staging", API, endpoint, KEY, debug = true))
            assertNull(UploadConfig.create("live", endpoint, AUTH, KEY, debug = false))
        }
        assertNull(UploadConfig.create("staging", API, AUTH, "sb_secret_synthetic", debug = true))
        assertNull(UploadConfig.create("staging", API, AUTH, "legacy.synthetic.jwt", debug = true))
        assertNull(UploadConfig.create("mock", API, AUTH, KEY, debug = true))
        assertNull(UploadConfig.create("mock", LOOPBACK, LOOPBACK, KEY, debug = false))
        assertTrue(checkNotNull(UploadConfig.create("mock", LOOPBACK, LOOPBACK, KEY, debug = true))
            .api("v1/contents").host == "127.0.0.1")
    }

    @Test
    fun installedBuildUsesExpectedPackageAndNetworkPolicy() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val policy = NetworkSecurityPolicy.getInstance()
        val staging = BuildConfig.UPLOAD_MODE == "staging"
        val expectedPackage = "com.itda.itda_mobile" + if (staging) ".staging" else ""
        assertEquals(expectedPackage, context.packageName)
        assertFalse(policy.isCleartextTrafficPermitted("api.staging.example.test"))
        if (staging) {
            assertEquals("ITDA Staging", context.applicationInfo.loadLabel(context.packageManager).toString())
            assertEquals("staging", UploadConfig.installed()?.mode)
        }
        val localDebug = BuildConfig.DEBUG && BuildConfig.UPLOAD_MODE in setOf("disabled", "mock")
        assertEquals(localDebug, policy.isCleartextTrafficPermitted("127.0.0.1"))
        assertEquals(localDebug, policy.isCleartextTrafficPermitted("10.0.2.2"))
    }

    @Test
    fun transportDoesNotForwardCredentialsOnRedirect() {
        MockWebServer().use { destination ->
            MockWebServer().use { origin ->
                destination.start()
                origin.start()
                origin.enqueue(MockResponse.Builder().code(307)
                    .addHeader("Location", destination.url("/other").toString()).build())
                val response = UploadHttp().post(origin.url("/auth/v1/token"),
                    mapOf("apikey" to KEY), JSONObject().put("password", "synthetic-password"))
                assertEquals(307, response.status)
                assertEquals(1, origin.requestCount)
                assertEquals(0, destination.requestCount)
            }
        }
    }

    private companion object {
        const val API = "https://api.staging.example.test/itda"
        const val AUTH = "https://auth.staging.example.test"
        const val KEY = "sb_publishable_synthetic"
        const val LOOPBACK = "http://127.0.0.1:8782"
    }
}
