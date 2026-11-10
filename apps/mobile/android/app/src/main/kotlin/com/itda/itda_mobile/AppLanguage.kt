package com.itda.itda_mobile

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import java.io.IOException
import java.util.Locale

internal object AppLanguage {
    private const val KEY = "language"

    fun get(context: Context): String = if (preferences(context).getString(KEY, null) == "en") "en" else "ko"

    @SuppressLint("UseKtx") // The KTX edit wrapper discards the commit result.
    fun set(context: Context, language: String) {
        require(language == "ko" || language == "en")
        if (!preferences(context).edit().putString(KEY, language).commit()) {
            throw IOException("Could not save app language")
        }
    }

    fun resources(context: Context, language: String = get(context)): Resources {
        val configuration = Configuration(context.resources.configuration)
        configuration.setLocale(Locale.forLanguageTag(language))
        return context.createConfigurationContext(configuration).resources
    }

    private fun preferences(context: Context) = context.getSharedPreferences("itda_display", Context.MODE_PRIVATE)
}
