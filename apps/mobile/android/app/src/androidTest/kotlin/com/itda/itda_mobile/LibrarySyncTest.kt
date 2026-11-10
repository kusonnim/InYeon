package com.itda.itda_mobile

import android.database.sqlite.SQLiteDatabase
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.IOException
import java.time.Instant
import java.util.UUID
import java.util.concurrent.TimeUnit.SECONDS
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LibrarySyncTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val root = File(context.cacheDir, "library-sync-test-${UUID.randomUUID()}")
    private val cacheDir = File(root, "cache")
    private val cache = LibraryCache(cacheDir)
    private val server = MockWebServer()
    private lateinit var config: UploadConfig
    private lateinit var owner: UploadOwner
    private lateinit var sessions: SupabaseSessions
    private val first = UUID.randomUUID()
    private val second = UUID.randomUUID()
    private val inserted = UUID.randomUUID()

    @Before
    fun setup() {
        check(root.mkdir())
        server.start()
        val url = server.url("/").toString()
        config = checkNotNull(UploadConfig.create("mock", url, url, "sb_publishable_fixture", debug = true))
        owner = UploadOwner(UUID.randomUUID(), config.realm)
        val vault = SessionVault(File(root, "session"))
        val session = SupabaseSession(
            owner, "synthetic@example.test", "synthetic-token", "synthetic-refresh", System.currentTimeMillis() + 3600_000,
        )
        check(vault.replaceIfCurrent(vault.snapshot(), session))
        sessions = SupabaseSessions(config, vault)
    }

    @After
    fun cleanup() {
        server.close()
        root.deleteRecursively()
    }

    @Test
    fun bootstrapCatchesUpWithInsertAndEditDuringNewestFirstPagination() {
        val obsoleteReceipt = UUID.randomUUID()
        val anchorEvent = event(1, first)
        val anchor = "opaque +/=? cursor"
        enqueue(sync("barrier-page", true, anchorEvent))
        enqueue(sync(anchor, false, anchorEvent, event(2, second)))
        enqueue(catalog("catalog-page", content(first, "First page")))
        enqueue(catalog(null, content(second, "Second page")))
        enqueue(preferences())
        // An insert above the catalog cursor was absent from both scanned catalog pages.
        enqueue(sync("during-scan", true, event(2, second), event(3, inserted), event(3, inserted)))
        enqueue(content(inserted, "Concurrent insert"))
        enqueue(sync("ready", false, event(4, first)))
        enqueue(content(first, "Concurrent edit", version = 2))

        engine(acknowledged = setOf(obsoleteReceipt)).synchronize()

        take("/v1/sync")
        take("/v1/sync", "barrier-page")
        take("/v1/contents")
        take("/v1/contents", "catalog-page")
        take("/v1/preferences")
        take("/v1/sync", anchor)
        take("/v1/contents/$inserted")
        take("/v1/sync", "during-scan")
        take("/v1/contents/$first")
        assertEquals(9, server.requestCount)
        val reopened = LibraryCache(cacheDir)
        val snapshot = reopened.snapshot(owner, 10, setOf(obsoleteReceipt))
        assertTrue(snapshot.initialized)
        assertEquals(setOf("Concurrent edit", "Second page", "Concurrent insert"), titles(snapshot))
        assertEquals(setOf(obsoleteReceipt), snapshot.removed)
        assertEquals(position("ready", 4), reopened.position(owner))
        assertTrue(reopened.snapshot(owner, 1, emptySet()).hasMore)
        assertEquals(1, readPreferences().getInt("version"))
    }

    @Test
    fun restartsFromLastAppliedPageAndDeduplicatesRelatedEventsAndTombstones() {
        seed(position("previous", 1), content(first, "Old title"), content(second, "To delete"))
        val edit = event(2, first)
        enqueue(sync("first-commit", true, event(1, first), edit, edit))
        enqueue(content(first, "Edited", version = 2))
        enqueue(error("temporarily_unavailable"), 503)
        val failed = assertThrows(UploadProblem::class.java) { engine().synchronize() }
        assertEquals(UploadState.RETRY_WAITING, failed.state)
        take("/v1/sync", "previous")
        take("/v1/contents/$first")
        take("/v1/sync", "first-commit")
        assertEquals(position("first-commit", 2), LibraryCache(cacheDir).position(owner))
        assertEquals(setOf("Edited", "To delete"), titles(LibraryCache(cacheDir).snapshot(owner, 10, emptySet())))

        val suggestionId = UUID.randomUUID()
        enqueue(sync(
            "final", false, edit, event(3, second, operation = "delete"),
            event(4, suggestionId, entity = "recommendation", parent = first, operation = "delete"),
            event(5, first, entity = "notification"),
            event(6, owner.userId, entity = "preferences", parent = null),
        ))
        enqueue(content(first, "Edited", version = 3, dismissed = true))
        enqueue(preferences(version = 2))
        engine(cache = LibraryCache(cacheDir)).synchronize()
        take("/v1/sync", "first-commit")
        take("/v1/contents/$first")
        take("/v1/preferences")
        assertEquals(6, server.requestCount)
        val snapshot = cache.snapshot(owner, 10, setOf(second))
        assertEquals(setOf(second), snapshot.removed)
        assertEquals(setOf("Edited"), titles(snapshot))
        val record = snapshot.items.getJSONObject(0)
        assertEquals("pending", record.getString("workflow_status"))
        assertEquals("dismissed", record.getJSONObject("notification").getString("visibility"))
        assertEquals(2, readPreferences().getInt("version"))
        assertEquals(position("final", 6), cache.position(owner))
    }

    @Test
    fun rollsBackContentTombstoneAndCursorWhenTheTransactionIsInterrupted() {
        val before = position("unchanged", 1)
        val after = position("next", 3)
        seed(before, content(first, "Previous original"))
        val page = listOf(
            LibraryChange.Content(first, null),
            LibraryChange.Content(second, content(second, "Added in page")),
        )
        assertThrows(IOException::class.java) {
            cache.applyPage(owner, before, after, page) { throw IOException("Interrupted before SQLite commit") }
        }
        val reopened = LibraryCache(cacheDir)
        assertEquals(before, reopened.position(owner))
        assertEquals(setOf("Previous original"), titles(reopened.snapshot(owner, 10, setOf(first))))
        assertTrue(reopened.snapshot(owner, 10, setOf(first)).removed.isEmpty())

        reopened.applyPage(owner, before, after, page) { sessions.requireOwner(owner) }
        assertEquals(after, cache.position(owner))
        assertEquals(setOf("Added in page"), titles(cache.snapshot(owner, 10, setOf(first))))
        assertEquals(setOf(first), cache.snapshot(owner, 10, setOf(first)).removed)
    }

    @Test
    fun expiredCursorKeepsOldSnapshotUntilTheReplacementCommits() {
        seed(position("expired", 50), content(first, "Old snapshot"))
        enqueue(error("invalid_cursor"), 400)
        enqueue(sync("new-anchor", false))
        enqueue(catalog("partial-scan", content(second, "Unpublished replacement")))
        enqueue(error("temporarily_unavailable"), 503)
        assertThrows(UploadProblem::class.java) { engine().synchronize() }
        take("/v1/sync", "expired")
        take("/v1/sync")
        take("/v1/contents")
        take("/v1/contents", "partial-scan")
        assertEquals(position("expired", 50), LibraryCache(cacheDir).position(owner))
        assertEquals(setOf("Old snapshot"), titles(cache.snapshot(owner, 10, emptySet())))

        enqueue(error("invalid_cursor"), 400)
        enqueue(sync("new-anchor", false))
        enqueue(catalog(null, content(inserted, "Replacement")))
        enqueue(preferences())
        enqueue(sync("new-final", false))
        engine(acknowledged = setOf(first)).synchronize()
        assertEquals(SyncPosition("new-final", null), cache.position(owner))
        assertEquals(setOf("Replacement"), titles(cache.snapshot(owner, 10, setOf(first))))
        assertEquals(setOf(first), cache.snapshot(owner, 10, setOf(first)).removed)
    }

    @Test
    fun accountAndRealmUseSeparateSnapshotsAndMismatchedSessionCannotFetch() {
        seed(position("owner-a", 1), content(first, "Private A record"))
        val ownerB = owner.copy(userId = UUID.randomUUID())
        val otherRealm = owner.copy(realm = "another-realm")
        for (other in listOf(ownerB, otherRealm)) {
            assertFalse(LibraryCache(cacheDir).snapshot(other, 10, emptySet()).initialized)
            assertNull(cache.position(other))
            val error = assertThrows(UploadProblem::class.java) { engine(owner = other).synchronize() }
            assertEquals(UploadState.AUTH_REQUIRED, error.state)
        }
        assertEquals(0, server.requestCount)
        assertEquals(setOf("Private A record"), titles(cache.snapshot(owner, 10, emptySet())))
    }

    @Test
    fun rejectsUnorderedNewSequencesWithoutMovingTheCheckpoint() {
        val before = position("safe", 1)
        seed(before, content(first, "Unchanged"))
        enqueue(sync("bad", false, event(3, second), event(2, first)))
        val error = assertThrows(UploadProblem::class.java) { engine().synchronize() }
        assertEquals("invalid_server_response", error.code)
        assertEquals(before, cache.position(owner))
        assertEquals(1, server.requestCount)
    }

    private fun engine(
        owner: UploadOwner = this.owner,
        cache: LibraryCache = this.cache,
        acknowledged: Set<UUID> = emptySet(),
    ) = LibrarySyncEngine(
        owner, cache, LibrarySyncApi(AuthenticatedApi(config, sessions, UploadHttp())),
        verifyOwner = { sessions.requireOwner(owner) }, acknowledged = { acknowledged },
    )

    private fun seed(position: SyncPosition, vararg items: JSONObject) {
        val slot = cache.beginBootstrap(owner)
        cache.stage(owner, slot, items.map { LibraryChange.Content(it.uuid("id"), it) })
        cache.publishBootstrap(owner, slot, position, emptySet()) {}
    }

    private fun take(path: String, cursor: String? = null) {
        val request = checkNotNull(server.takeRequest(3, SECONDS))
        assertEquals("GET", request.method)
        assertEquals(path, request.url.encodedPath)
        assertEquals(cursor, request.url.queryParameter("cursor"))
        assertEquals("Bearer synthetic-token", request.headers["Authorization"])
    }

    private fun enqueue(body: JSONObject, status: Int = 200) {
        server.enqueue(MockResponse.Builder().code(status).body(body.toString()).build())
    }

    private fun readPreferences(): JSONObject {
        val file = File(cacheDir, sha256("${owner.realm}\n${owner.userId}".toByteArray()) + ".db")
        return SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
            db.rawQuery("SELECT payload FROM preferences JOIN checkpoint ON slot = active_slot", null).use {
                check(it.moveToFirst())
                JSONObject(it.getString(0))
            }
        }
    }

    private fun titles(snapshot: CachedLibrary): Set<String> =
        (0 until snapshot.items.length()).mapTo(mutableSetOf()) { snapshot.items.getJSONObject(it).getString("title") }

    private fun position(cursor: String, sequence: Int) = SyncPosition(cursor, (9007199254740992L + sequence).toBigInteger())

    private fun event(
        sequence: Int,
        id: UUID,
        entity: String = "content",
        parent: UUID? = id,
        operation: String = "upsert",
    ) = JSONObject().put("sequence", position("", sequence).sequence.toString())
        .put("entity_type", entity).put("entity_id", id.toString())
        .put("content_id", parent?.toString() ?: JSONObject.NULL)
        .put("operation", operation).put("occurred_at", Instant.EPOCH.toString())

    private fun sync(cursor: String, more: Boolean, vararg events: JSONObject) =
        JSONObject().put("events", JSONArray(events.toList())).put("next_cursor", cursor).put("has_more", more)

    private fun catalog(cursor: String?, vararg items: JSONObject) =
        JSONObject().put("items", JSONArray(items.toList())).put("next_cursor", cursor ?: JSONObject.NULL)

    private fun preferences(version: Int = 1) =
        JSONObject().put("user_id", owner.userId.toString()).put("version", version)
            .put("interests", JSONArray()).put("explicit_preferences", JSONArray()).put("mbti", JSONObject.NULL)
            .put("created_at", Instant.EPOCH.toString()).put("updated_at", Instant.EPOCH.toString())

    private fun content(id: UUID, title: String, version: Int = 1, dismissed: Boolean = false) =
        JSONObject().put("id", id.toString()).put("user_id", owner.userId.toString()).put("title", title)
            .put("created_at", Instant.EPOCH.toString()).put("updated_at", Instant.EPOCH.toString())
            .put("version", version).put("workflow_status", "pending")
            .put("notification", JSONObject().put("content_id", id.toString())
                .put("visibility", if (dismissed) "dismissed" else "active"))

    private fun error(code: String) = JSONObject().put("error", JSONObject().put("code", code))
}
