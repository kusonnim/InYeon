package com.itda.itda_mobile

import android.content.ActivityNotFoundException
import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ExternalLinksTest {
    @Test
    fun handsOnlyBrowsableWebDataToAndroid() {
        val urls = listOf(
            "http://events.example.test/calendar?season=winter%2Fspring#dates",
            "https://www.instagram.com/p/example/",
            "https://www.youtube.com/watch?v=example",
        )
        for (url in urls) {
            var launched: Intent? = null
            assertTrue(launchExternalLink(url) { launched = it })
            val intent = checkNotNull(launched)
            assertEquals(Intent.ACTION_VIEW, intent.action)
            assertEquals(setOf(Intent.CATEGORY_BROWSABLE), intent.categories)
            assertEquals(url, intent.dataString)
            assertEquals(0, intent.flags)
            assertNull(intent.component)
            assertNull(intent.getPackage())
            assertNull(intent.extras)
            assertNull(intent.clipData)
        }
    }

    @Test
    fun rejectsMalformedNonWebAndProtectedLinksBeforeDispatch() {
        val rejected = listOf(
            null, "/calendar", "https:///calendar", "https://events.example.test:65536",
            "https://events.example.test/%ZZ", "file:///calendar",
            "intent://calendar#Intent;scheme=https;end",
            "https://demo@events.example.test/calendar",
            "https://objects.example.test/storage/v1/object/sign/content-assets/fixture",
            "https://events.example.test/#access%5Ftoken=placeholder",
        )
        for (url in rejected) {
            assertFalse(launchExternalLink(url) { error("Unexpected Android dispatch") })
        }
    }

    @Test
    fun reportsUnavailableOrDisallowedHandlers() {
        val url = "https://events.example.test/calendar"
        assertFalse(launchExternalLink(url) { throw ActivityNotFoundException() })
        assertFalse(launchExternalLink(url) { throw SecurityException() })
    }
}
