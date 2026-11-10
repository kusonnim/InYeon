package com.itda.itda_mobile

import android.content.ContentValues
import android.database.sqlite.SQLiteDatabase
import java.io.File
import java.time.Instant
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

internal sealed interface LibraryChange {
    data class Content(val id: UUID, val value: JSONObject?) : LibraryChange
    data class Preferences(val value: String?) : LibraryChange
}

internal data class CachedLibrary(
    val initialized: Boolean,
    val items: JSONArray,
    val hasMore: Boolean,
    val removed: Set<UUID>,
)

/** Only derived server data lives here. A1/A2 receipts and A3 notice records have separate stores. */
internal class LibraryCache(private val root: File) {
    private val lock = Any()

    fun position(owner: UploadOwner): SyncPosition? = database(owner) { state(it).position }

    fun snapshot(owner: UploadOwner, limit: Int, acknowledged: Set<UUID>): CachedLibrary =
        database(owner) { db ->
            require(limit in 1 until Int.MAX_VALUE)
            val active = state(db)
            val items = JSONArray()
            var more = false
            db.rawQuery(
                "SELECT payload FROM content WHERE slot = ? ORDER BY created_seconds DESC, created_nanos DESC, id DESC LIMIT ?",
                arrayOf(active.slot.toString(), (limit + 1).toString()),
            ).use { rows ->
                while (rows.moveToNext()) {
                    if (items.length() == limit) {
                        more = true
                        break
                    }
                    items.put(JSONObject(rows.getString(0)))
                }
            }
            CachedLibrary(active.position != null, items, more, removedIds(db, active.slot, acknowledged))
        }

    fun applyPage(
        owner: UploadOwner,
        before: SyncPosition,
        after: SyncPosition,
        changes: List<LibraryChange>,
        verifyOwner: () -> Unit,
    ) = transaction(owner) { db ->
        val active = state(db)
        check(active.position == before)
        apply(db, active.slot, changes)
        savePosition(db, active.slot, after)
        verifyOwner()
    }

    fun beginBootstrap(owner: UploadOwner): Int = transaction(owner) { db ->
        val staging = 1 - state(db).slot
        clear(db, staging)
        staging
    }

    fun stage(owner: UploadOwner, slot: Int, changes: List<LibraryChange>) = transaction(owner) { db ->
        check(state(db).slot != slot)
        apply(db, slot, changes)
    }

    fun publishBootstrap(
        owner: UploadOwner,
        slot: Int,
        position: SyncPosition,
        acknowledgedBeforeBootstrap: Set<UUID>,
        verifyOwner: () -> Unit,
    ) = transaction(owner) { db ->
        val previous = state(db).slot
        check(previous != slot)
        // Retain known deletions that are still absent from the authoritative replacement.
        db.execSQL(
            """
            INSERT OR IGNORE INTO tombstone(slot, id)
            SELECT ?, old.id FROM tombstone old WHERE old.slot = ?
                AND NOT EXISTS (SELECT 1 FROM content WHERE slot = ? AND id = old.id)
            """.trimIndent(),
            arrayOf(slot, previous, slot),
        )
        for (id in acknowledgedBeforeBootstrap) {
            db.execSQL(
                """
                INSERT OR IGNORE INTO tombstone(slot, id)
                SELECT ?, ? WHERE NOT EXISTS (SELECT 1 FROM content WHERE slot = ? AND id = ?)
                """.trimIndent(),
                arrayOf<Any>(slot, id.toString(), slot, id.toString()),
            )
        }
        savePosition(db, slot, position)
        clear(db, previous)
        verifyOwner()
    }

    private fun apply(db: SQLiteDatabase, slot: Int, changes: List<LibraryChange>) {
        val partition = slot.toString()
        for (change in changes) {
            when (change) {
                is LibraryChange.Content -> {
                    val id = change.id.toString()
                    val item = change.value
                    if (item == null) {
                        db.delete("content", "slot = ? AND id = ?", arrayOf(partition, id))
                        db.execSQL("INSERT OR IGNORE INTO tombstone(slot, id) VALUES(?, ?)", arrayOf<Any>(slot, id))
                    } else {
                        val created = decodeServer { Instant.parse(item.getString("created_at")) }
                        db.execSQL(
                            "INSERT OR REPLACE INTO content(slot, id, created_seconds, created_nanos, payload) VALUES(?, ?, ?, ?, ?)",
                            arrayOf<Any>(slot, id, created.epochSecond, created.nano, item.toString()),
                        )
                        db.delete("tombstone", "slot = ? AND id = ?", arrayOf(partition, id))
                    }
                }
                is LibraryChange.Preferences -> {
                    val value = change.value
                    if (value == null) db.delete("preferences", "slot = ?", arrayOf(partition))
                    else db.execSQL(
                        "INSERT OR REPLACE INTO preferences(slot, payload) VALUES(?, ?)", arrayOf<Any>(slot, value),
                    )
                }
            }
        }
    }

    private fun removedIds(db: SQLiteDatabase, slot: Int, acknowledged: Set<UUID>): Set<UUID> = buildSet {
        for (batch in acknowledged.chunked(400)) {
            val placeholders = batch.joinToString(",") { "?" }
            val arguments = (listOf(slot.toString()) + batch.map(UUID::toString)).toTypedArray()
            db.rawQuery("SELECT id FROM tombstone WHERE slot = ? AND id IN ($placeholders)", arguments).use { rows ->
                while (rows.moveToNext()) add(parseUuid(rows.getString(0)))
            }
        }
    }

    private data class State(val slot: Int, val position: SyncPosition?)

    private fun state(db: SQLiteDatabase): State =
        db.rawQuery("SELECT active_slot, cursor, sequence FROM checkpoint WHERE id = 1", null).use {
            check(it.moveToFirst())
            State(it.getInt(0), it.getString(1)?.let { cursor -> SyncPosition(cursor, it.getString(2)?.toBigInteger()) })
        }

    private fun savePosition(db: SQLiteDatabase, slot: Int, position: SyncPosition) {
        db.update("checkpoint", ContentValues().apply {
            put("active_slot", slot)
            put("cursor", position.cursor)
            put("sequence", position.sequence?.toString())
        }, "id = 1", null)
    }

    private fun clear(db: SQLiteDatabase, slot: Int) {
        for (table in listOf("content", "tombstone", "preferences")) {
            db.delete(table, "slot = ?", arrayOf(slot.toString()))
        }
    }

    private fun <T> transaction(owner: UploadOwner, block: (SQLiteDatabase) -> T): T =
        database(owner) { db -> db.transaction { block(db) } }

    private fun <T> database(owner: UploadOwner, block: (SQLiteDatabase) -> T): T = synchronized(lock) {
        if (!root.isDirectory) {
            check(root.mkdir())
            syncDirectory(checkNotNull(root.parentFile))
        }
        val scope = sha256("${owner.realm}\n${owner.userId}".toByteArray())
        val file = File(root, "$scope.db")
        SQLiteDatabase.openOrCreateDatabase(file, null).use { db ->
            db.execSQL("PRAGMA synchronous = FULL")
            if (db.version == 0) {
                db.transaction { createSchema(db) }
                syncDirectory(root)
            }
            check(db.version == 1) { "Unsupported library cache schema" }
            block(db)
        }
    }

    private fun createSchema(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE checkpoint(id INTEGER PRIMARY KEY, active_slot INTEGER NOT NULL, cursor TEXT, sequence TEXT)")
        db.execSQL("INSERT INTO checkpoint(id, active_slot) VALUES(1, 0)")
        db.execSQL(
            """
            CREATE TABLE content(slot INTEGER NOT NULL, id TEXT NOT NULL, created_seconds INTEGER NOT NULL,
                created_nanos INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(slot, id))
            """.trimIndent(),
        )
        db.execSQL("CREATE INDEX content_order ON content(slot, created_seconds DESC, created_nanos DESC, id DESC)")
        db.execSQL("CREATE TABLE tombstone(slot INTEGER NOT NULL, id TEXT NOT NULL, PRIMARY KEY(slot, id))")
        db.execSQL("CREATE TABLE preferences(slot INTEGER PRIMARY KEY, payload TEXT NOT NULL)")
        db.version = 1
    }

    private inline fun <T> SQLiteDatabase.transaction(block: () -> T): T {
        beginTransaction()
        try {
            val result = block()
            setTransactionSuccessful()
            return result
        } finally {
            endTransaction()
        }
    }
}
