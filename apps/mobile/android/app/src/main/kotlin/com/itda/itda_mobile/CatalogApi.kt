package com.itda.itda_mobile

internal class CatalogApi(private val api: AuthenticatedApi) {
    fun list(owner: UploadOwner, cursor: String?): String {
        val query = mutableMapOf("limit" to "10")
        if (cursor != null) {
            if (cursor.isEmpty() || cursor.length > 2048) throw UploadProblem.permanent("invalid_cursor")
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
                require(item.uuid("user_id") == owner.userId)
                require(item.getJSONObject("notification").uuid("content_id") == item.uuid("id"))
            }
            require(page.has("next_cursor"))
            page.toString()
        }
    }
}
