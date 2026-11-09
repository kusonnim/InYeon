package com.itda.itda_mobile

import java.util.UUID
import org.json.JSONObject

internal class AuthenticatedApi(
    private val config: UploadConfig,
    private val sessions: SupabaseSessions,
    private val http: UploadHttp,
) {
    fun request(
        owner: UploadOwner,
        method: String,
        path: String,
        body: JSONObject? = null,
        key: UUID? = null,
    ): HttpReply {
        val url = config.api(path)
        fun send(token: String): HttpReply {
            sessions.requireOwner(owner)
            val headers = mutableMapOf("Authorization" to "Bearer $token")
            if (key != null) headers["Idempotency-Key"] = key.toString()
            return http.json(method, url, headers, body)
        }

        var token = sessions.accessToken(owner, http)
        var reply = send(token)
        if (reply.status == 401) {
            token = sessions.accessToken(owner, http, rejectedToken = token)
            reply = send(token)
            if (reply.status == 401) {
                sessions.rejectToken(owner, token)
                throw UploadProblem.auth()
            }
        }
        sessions.requireOwner(owner)
        return reply
    }
}
