package com.itda.itda_mobile

import java.net.URI
import java.security.MessageDigest
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

internal class UploadConfig private constructor(
    val mode: String,
    val apiBase: HttpUrl,
    val supabaseBase: HttpUrl,
    val publishableKey: String,
) {
    // Bind the receipt to the authentication project and destination API as well as the user.
    val realm = sha256("$mode\n$apiBase\n$supabaseBase".toByteArray())

    fun api(path: String): HttpUrl = checkNotNull(apiBase.resolve(path))

    fun tokenEndpoint(grant: String): HttpUrl = checkNotNull(supabaseBase.resolve("auth/v1/token"))
        .newBuilder().addQueryParameter("grant_type", grant).build()

    fun capability(value: String): HttpUrl {
        val url = value.toHttpUrlOrNull()
        if (url == null || !permits(url, mode) || url.fragment != null ||
            url.username.isNotEmpty() || url.password.isNotEmpty()
        ) {
            throw UploadProblem.permanent("invalid_upload_capability")
        }
        return url
    }

    companion object {
        fun installed(): UploadConfig? = create(
            BuildConfig.UPLOAD_MODE, BuildConfig.API_BASE_URL, BuildConfig.SUPABASE_URL,
            BuildConfig.SUPABASE_PUBLISHABLE_KEY, BuildConfig.DEBUG,
        )

        fun create(mode: String, api: String, supabase: String, key: String, debug: Boolean): UploadConfig? {
            if (mode != "live" && !(debug && mode in setOf("mock", "staging"))) return null
            if (!key.matches(Regex("sb_publishable_[A-Za-z0-9_-]+"))) return null
            val apiBase = baseUrl(api, mode) ?: return null
            val authBase = baseUrl(supabase, mode) ?: return null
            return UploadConfig(mode, apiBase, authBase, key)
        }

        private fun baseUrl(value: String, mode: String): HttpUrl? {
            val uri = runCatching { URI(value) }.getOrNull() ?: return null
            if (uri.host.isNullOrEmpty() || uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null) {
                return null
            }
            return (value.trimEnd('/') + "/").toHttpUrlOrNull()?.takeIf { permits(it, mode) }
        }

        private fun permits(url: HttpUrl, mode: String): Boolean =
            if (mode == "mock") url.host in setOf("127.0.0.1", "10.0.2.2", "localhost") else url.isHttps
    }
}

internal fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
    .digest(bytes).toHex()

internal fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
