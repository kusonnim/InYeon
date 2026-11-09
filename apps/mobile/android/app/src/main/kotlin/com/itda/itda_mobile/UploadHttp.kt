package com.itda.itda_mobile

import android.net.Network
import android.util.Log
import java.io.File
import java.io.IOException
import java.time.DateTimeException
import java.util.concurrent.TimeUnit.SECONDS
import java.util.concurrent.atomic.AtomicReference
import okhttp3.Call
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONException
import org.json.JSONObject

internal class UploadProblem(val state: UploadState, val code: String) : Exception(code) {
    companion object {
        fun auth(code: String = "authentication_required") = UploadProblem(UploadState.AUTH_REQUIRED, code)
        fun retry(code: String) = UploadProblem(UploadState.RETRY_WAITING, code)
        fun permanent(code: String) = UploadProblem(UploadState.PERMANENT_FAILURE, code)
    }
}

internal class HttpReply(val status: Int, private val body: String) {
    fun json(): JSONObject = decodeServer { JSONObject(body) }
    fun errorCode(): String? = optionalJson()?.optJSONObject("error")?.stringOrNull("code")
    fun optionalJson(): JSONObject? = try {
        JSONObject(body)
    } catch (_: JSONException) {
        null
    }

    val retryable: Boolean
        get() = status in setOf(408, 429, 500, 502, 503, 504)
}

internal inline fun <T> decodeServer(decode: () -> T): T = try {
    decode()
} catch (_: JSONException) {
    throw UploadProblem.permanent("invalid_server_response")
} catch (_: IllegalArgumentException) {
    throw UploadProblem.permanent("invalid_server_response")
} catch (_: DateTimeException) {
    throw UploadProblem.permanent("invalid_server_response")
}

// One cancellable exchange sequence per worker. The shared client keeps no session state.
internal class UploadHttp(network: Network? = null) {
    private val current = AtomicReference<Call>()
    @Volatile private var stopped = false
    private val transport = if (network == null) client else client.newBuilder()
        .socketFactory(network.socketFactory)
        .dns { hostname -> network.getAllByName(hostname).toList() }
        .build()
    private val replayableTransport = transport.newBuilder().retryOnConnectionFailure(true).build()

    fun post(url: HttpUrl, headers: Map<String, String>, json: JSONObject?): HttpReply =
        json("POST", url, headers, json)

    fun json(method: String, url: HttpUrl, headers: Map<String, String>, body: JSONObject?): HttpReply =
        execute(
            Request.Builder().url(url).apply {
                headers.forEach { (name, value) -> header(name, value) }
                val requestBody = if (method == "GET") null
                else (body?.toString() ?: "").toRequestBody(if (body == null) null else JSON_TYPE)
                method(method, requestBody)
            }.build(),
            replayable = method == "GET" || "Idempotency-Key" in headers,
        )

    fun put(url: HttpUrl, headers: Map<String, String>, source: File): HttpReply {
        val request = decodeServer {
            Request.Builder().url(url).apply {
                headers.forEach { (name, value) -> header(name, value) }
                put(source.asRequestBody())
            }.build()
        }
        return execute(request, replayable = true)
    }

    fun stop() {
        stopped = true
        current.get()?.cancel()
    }

    private fun execute(request: Request, replayable: Boolean): HttpReply {
        // Auth exchanges can rotate credentials. Only idempotent API requests and
        // non-upserting capability PUTs can retry a broken pooled connection.
        val call = (if (replayable) replayableTransport else transport).newCall(request)
        current.set(call)
        if (stopped) call.cancel()
        try {
            call.execute().use { response ->
                val body = response.body.source()
                if (body.request(MAX_RESPONSE_BYTES + 1)) {
                    throw UploadProblem.permanent("invalid_server_response")
                }
                return HttpReply(response.code, body.readUtf8())
            }
        } catch (error: IOException) {
            if (BuildConfig.DEBUG) {
                Log.d("ITDAOutbox", "HTTP ${request.method} interrupted (${error.javaClass.simpleName})")
            }
            throw UploadProblem.retry("network_unavailable")
        } finally {
            current.compareAndSet(call, null)
        }
    }

    private companion object {
        val JSON_TYPE = "application/json; charset=utf-8".toMediaType()
        const val MAX_RESPONSE_BYTES = 1024L * 1024
        val client = OkHttpClient.Builder()
            .followRedirects(false)
            .followSslRedirects(false)
            .retryOnConnectionFailure(false)
            .connectTimeout(15, SECONDS)
            .readTimeout(30, SECONDS)
            .writeTimeout(30, SECONDS)
            .callTimeout(90, SECONDS)
            .build()
    }
}
