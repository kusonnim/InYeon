package com.itda.itda_mobile

import java.util.UUID
import org.json.JSONObject

internal class CatalogApi(private val api: AuthenticatedApi) {
    fun list(owner: UploadOwner, cursor: String?): JSONObject {
        val query = mutableMapOf("limit" to "10")
        if (cursor != null) {
            if (cursor.length > 2048) throw UploadProblem.permanent("invalid_cursor")
            query["cursor"] = cursor
        }
        val reply = api.request(owner, "GET", "v1/contents", query = query)
        if (reply.status == 400 && reply.errorCode() == "invalid_cursor") {
            throw UploadProblem.permanent("invalid_cursor")
        }
        val page = reply.expectJson(200)
        return decodeServer {
            val items = page.getJSONArray("items")
            for (i in 0 until items.length()) {
                val item = items.getJSONObject(i)
                validate(item, owner, item.uuid("id"))
            }
            require(page.has("next_cursor"))
            page
        }
    }

    fun content(owner: UploadOwner, id: UUID): JSONObject? {
        val reply = api.request(owner, "GET", "v1/contents/$id")
        if (reply.status == 404) return null
        return reply.expectJson(200).also { item -> decodeServer { validate(item, owner, id) } }
    }

    private fun validate(item: JSONObject, owner: UploadOwner, id: UUID) {
        require(item.uuid("id") == id && item.uuid("user_id") == owner.userId)
        require(item.getJSONObject("notification").uuid("content_id") == id)
        item.optJSONObject("analysis")?.let { require(it.uuid("content_id") == id) }
        item.optJSONArray("recommendations")?.let { recommendations ->
            for (i in 0 until recommendations.length()) {
                require(recommendations.getJSONObject(i).uuid("content_id") == id)
            }
        }
    }
}
