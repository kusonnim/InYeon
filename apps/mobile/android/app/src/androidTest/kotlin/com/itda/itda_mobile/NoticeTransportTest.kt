package com.itda.itda_mobile

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.work.ListenableWorker.Result
import java.io.File
import java.time.Instant
import java.util.UUID
import java.util.concurrent.TimeUnit.SECONDS
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NoticeTransportTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val root = File(context.cacheDir, "notice-transport-${UUID.randomUUID()}")
    private val server = MockWebServer()
    private val shares = LocalShareStore(File(root, "shares"))
    private val records = NoticeStore(File(root, "records"))
    private val vault = SessionVault(File(root, "session"))
    private lateinit var config: UploadConfig
    private lateinit var sessions: SupabaseSessions
    private lateinit var ref: NoticeRef
    private lateinit var localId: UUID
    private var posted: Long? = null
    private val surface = object : NoticeSurface {
        override fun canPost() = true
        override fun activeGeneration(ref: NoticeRef) = posted
        override fun post(record: NoticeRecord, update: Boolean) {
            posted = record.state.generation
        }
        override fun cancel(ref: NoticeRef) {
            posted = null
        }
        override fun hideOtherOwners(owner: UploadOwner?) = Unit
    }

    @Before
    fun setup() {
        check(root.mkdir())
        server.start()
        val url = server.url("/").toString()
        config = checkNotNull(UploadConfig.create("mock", url, url, "sb_publishable_fixture", debug = true))
        sessions = SupabaseSessions(config, vault)
        ref = NoticeRef(UploadOwner(UUID.randomUUID(), config.realm), UUID.randomUUID())
        login(ref.owner)
        localId = UUID.randomUUID()
        shares.persist(localId, 1794268800000L, ref.owner) {
            JSONObject().put("input_type", "text").put("source_text", "Synthetic source")
        }
    }

    @After
    fun cleanup() {
        server.close()
        root.deleteRecursively()
    }

    @Test
    fun onlyAcknowledgedContentIsFetchedAndDismissalRetriesThePersistedKey() {
        assertEquals(Result.success(), run())
        assertEquals(0, server.requestCount)
        acknowledgeUpload()
        enqueue(200, content())
        assertEquals(Result.success(), run())
        take("GET", "/v1/contents/${ref.contentId}")
        assertEquals(1L, posted)
        assertTrue(lifecycle().dismiss(ref, 1))
        val event = checkNotNull(records.read(ref)?.event)

        enqueue(503, error("unavailable"))
        assertEquals(Result.retry(), run())
        val first = take("POST", "/v1/notification-events")
        assertEquals(event.key.toString(), first.headers["Idempotency-Key"])
        val body = JSONObject(first.body!!.utf8())
        assertEquals(setOf("content_id", "event_type", "generation", "expected_revision"), body.keys().asSequence().toSet())
        assertEquals(ref.contentId.toString(), body.getString("content_id"))
        assertEquals("dismissed", body.getString("event_type"))
        assertEquals(1L, body.getLong("generation"))
        assertEquals(1L, body.getLong("expected_revision"))
        assertNull(posted)

        enqueue(409, error("notification_conflict"))
        enqueue(200, content(revision = 2, analysis = "completed"))
        assertEquals(Result.retry(), run())
        val retry = take("POST", "/v1/notification-events")
        assertEquals(first.headers["Idempotency-Key"], retry.headers["Idempotency-Key"])
        assertEquals(first.body, retry.body)
        take("GET", "/v1/contents/${ref.contentId}")
        val rebased = checkNotNull(records.read(ref)?.event)
        assertNotEquals(event.key, rebased.key)
        assertEquals(2L, rebased.revision)
        assertNull(posted)

        enqueue(200, mutation(state(revision = 3, dismissed = true)))
        enqueue(200, content(revision = 3, dismissed = true, analysis = "completed"))
        assertEquals(Result.success(), run())
        assertEquals(rebased.key.toString(), take("POST", "/v1/notification-events").headers["Idempotency-Key"])
        take("GET", "/v1/contents/${ref.contentId}")
        assertNull(records.read(ref)?.event)
        assertTrue(checkNotNull(records.read(ref)).suppressed)
        assertNull(posted)
    }

    @Test
    fun lostRestoreAcknowledgmentCannotRepostAGenerationDismissedSinceTheCommit() {
        acknowledgeUpload()
        enqueue(200, content(dismissed = true, revision = 2))
        assertEquals(Result.success(), run())
        take("GET", "/v1/contents/${ref.contentId}")
        assertTrue(lifecycle().requestRestore(ref))
        val event = checkNotNull(records.read(ref)?.event)
        assertNull(posted)

        val path = "/v1/contents/${ref.contentId}/notification/restore"
        enqueue(200, mutation(state(generation = 2, revision = 3)))
        enqueue(503, error("unavailable"))
        assertEquals(Result.retry(), run())
        val first = take("POST", path)
        assertEquals(event.key.toString(), first.headers["Idempotency-Key"])
        val body = JSONObject(first.body!!.utf8())
        assertEquals(setOf("expected_generation", "expected_revision"), body.keys().asSequence().toSet())
        assertEquals(1L, body.getLong("expected_generation"))
        assertEquals(2L, body.getLong("expected_revision"))
        take("GET", "/v1/contents/${ref.contentId}")
        assertEquals(event, records.read(ref)?.event)
        assertNull(posted)

        enqueue(200, mutation(state(generation = 2, revision = 3)))
        enqueue(200, content(generation = 2, revision = 4, dismissed = true))
        assertEquals(Result.success(), run())
        assertEquals(event.key.toString(), take("POST", path).headers["Idempotency-Key"])
        take("GET", "/v1/contents/${ref.contentId}")
        assertNull(posted)
        assertNull(records.read(ref)?.event)
        assertEquals(2L, records.read(ref)?.state?.generation)
        assertTrue(checkNotNull(records.read(ref)).suppressed)
    }

    @Test
    fun signedOutOrOtherAccountCannotSubmitAnOwnersEventOrReadTheirContent() {
        acknowledgeUpload()
        enqueue(200, content())
        assertEquals(Result.success(), run())
        take("GET", "/v1/contents/${ref.contentId}")
        assertTrue(lifecycle().dismiss(ref, 1))
        val event = checkNotNull(records.read(ref)?.event)

        vault.clear()
        assertEquals(Result.success(), run())
        login(UploadOwner(UUID.randomUUID(), config.realm))
        assertEquals(Result.success(), run())
        assertThrows(UploadProblem::class.java) { controller().details(ref) }
        assertEquals(1, server.requestCount)
        assertEquals(event, records.read(ref)?.event)
        assertEquals(false, controller().ownsAcknowledgment(ref))

        login(ref.owner)
        enqueue(200, mutation(state(revision = 2, dismissed = true)))
        enqueue(200, content(revision = 2, dismissed = true))
        assertEquals(Result.success(), run())
        assertEquals(event.key.toString(), take("POST", "/v1/notification-events").headers["Idempotency-Key"])
        take("GET", "/v1/contents/${ref.contentId}")
        assertNull(records.read(ref)?.event)
        assertNull(posted)
    }

    @Test
    fun catalogEncodesOpaqueCursorAndRejectsAnotherOwnersContent() {
        val catalog = CatalogApi(AuthenticatedApi(config, sessions, UploadHttp()))
        val cursor = "opaque/+?&= page"
        enqueue(200, page(content(dismissed = true)))
        val response = catalog.list(ref.owner, cursor)
        assertEquals(1, response.getJSONArray("items").length())
        val request = take("GET", "/v1/contents")
        assertEquals(cursor, request.url.queryParameter("cursor"))
        assertEquals("10", request.url.queryParameter("limit"))
        assertEquals(setOf("limit", "cursor"), request.url.queryParameterNames)

        enqueue(200, page(content().put("user_id", UUID.randomUUID().toString())))
        val invalid = assertThrows(UploadProblem::class.java) { catalog.list(ref.owner, null) }
        assertEquals("invalid_server_response", invalid.code)
        take("GET", "/v1/contents")

        enqueue(400, error("invalid_cursor"))
        val expired = assertThrows(UploadProblem::class.java) { catalog.list(ref.owner, cursor) }
        assertEquals("invalid_cursor", expired.code)
        take("GET", "/v1/contents")
    }

    @Test
    fun ownedRemoteOnlyDetailsAndPartialEditDoNotIssueNotification() {
        val notices = controller()
        val path = "/v1/contents/${ref.contentId}"
        enqueue(200, content(dismissed = true))
        val item = notices.details(ref)
        take("GET", path)
        assertEquals(mapOf("dismissed" to true), item["notice"])
        assertNull(records.read(ref))
        assertNull(posted)

        val patch = JSONObject().put("expected_version", 1).put("title", "Edited title")
        enqueue(200, content(revision = 2).put("title", "Edited title"))
        val updated = notices.edit(ref, patch)
        val request = take("PATCH", path)
        assertEquals(patch.toString(), checkNotNull(request.body).utf8())
        assertEquals("Edited title", JSONObject(updated["content"] as String).getString("title"))
        assertNull(posted)
        assertThrows(UploadProblem::class.java) { notices.restore(ref) }
        assertEquals(2, server.requestCount)
    }

    private fun controller() = AndroidNotifications(context, config, sessions, shares, {}, surface, records)
    private fun lifecycle() = NoticeLifecycle(records, surface, { sessions.current()?.owner })
    private fun run() = controller().run(ref, UploadHttp())

    private fun login(owner: UploadOwner) {
        val session = SupabaseSession(owner, "synthetic@example.test", "synthetic-token", "synthetic-refresh",
            System.currentTimeMillis() + 3600_000)
        check(vault.replaceIfCurrent(vault.snapshot(), session))
    }

    private fun acknowledgeUpload() {
        shares.updateProgress(localId) {
            it.copy(state = UploadState.SYNCHRONIZED, serverContentId = ref.contentId)
        }
    }

    private fun enqueue(code: Int, body: JSONObject) {
        server.enqueue(MockResponse.Builder().code(code).body(body.toString()).build())
    }

    private fun take(method: String, path: String): RecordedRequest {
        val request = checkNotNull(server.takeRequest(3, SECONDS))
        assertEquals(method, request.method)
        assertEquals(path, request.url.encodedPath)
        assertEquals("Bearer synthetic-token", request.headers["Authorization"])
        return request
    }

    private fun state(generation: Long = 1, revision: Long = 1, dismissed: Boolean = false) = JSONObject()
        .put("content_id", ref.contentId.toString()).put("visibility", if (dismissed) "dismissed" else "active")
        .put("generation", generation).put("revision", revision).put("updated_at", Instant.EPOCH.toString())

    private fun content(generation: Long = 1, revision: Long = 1, dismissed: Boolean = false, analysis: String = "pending") =
        JSONObject().put("id", ref.contentId.toString()).put("user_id", ref.owner.userId.toString())
            .put("notification", state(generation, revision, dismissed)).put("version", revision)
            .put("updated_at", Instant.EPOCH.toString()).put("analysis_status", analysis)

    private fun mutation(state: JSONObject) = JSONObject().put("state", state).put("applied", true).put("reason", "applied")

    private fun page(item: JSONObject) = JSONObject()
        .put("items", JSONArray().put(item)).put("next_cursor", JSONObject.NULL)

    private fun error(code: String) = JSONObject().put("error", JSONObject().put("code", code))
}
