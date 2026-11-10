package com.itda.itda_mobile

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import androidx.core.net.toUri
import java.net.URI
import java.net.URISyntaxException
import java.util.Locale

private val privateStorage = Regex(
    """/storage/v1/object/(?:upload/)?(?:sign|authenticated)(?:/|$)""",
    RegexOption.IGNORE_CASE,
)
private val credentialKeys = setOf(
    "access_token", "refresh_token", "id_token", "authorization",
    "api_key", "apikey", "password", "token", "signature", "sig",
    "x-amz-signature", "x-goog-signature",
)

internal fun launchExternalLink(value: String?, start: (Intent) -> Unit): Boolean {
    if (value == null) return false
    val parsed = try {
        URI(value)
    } catch (_: URISyntaxException) {
        return false
    }
    val scheme = parsed.scheme?.lowercase(Locale.ROOT)
    if (scheme != "http" && scheme != "https") return false
    if (parsed.host.isNullOrEmpty() || parsed.rawUserInfo != null ||
        (parsed.port != -1 && parsed.port !in 1..65535) ||
        privateStorage.containsMatchIn(parsed.path.orEmpty())
    ) return false
    val credentials = listOfNotNull(parsed.rawQuery, parsed.rawFragment).any { part ->
        part.split('&', ';', '?').any { parameter ->
            val name = parameter.substringBefore('=', missingDelimiterValue = "")
            Uri.decode(name).lowercase(Locale.ROOT) in credentialKeys
        }
    }
    if (credentials) return false

    // Pass web data alone so Android can choose a verified app link or a browser.
    val intent = Intent(Intent.ACTION_VIEW, value.toUri().normalizeScheme())
        .addCategory(Intent.CATEGORY_BROWSABLE)
    return try {
        start(intent)
        true
    } catch (_: ActivityNotFoundException) {
        false
    } catch (_: SecurityException) {
        false
    }
}
