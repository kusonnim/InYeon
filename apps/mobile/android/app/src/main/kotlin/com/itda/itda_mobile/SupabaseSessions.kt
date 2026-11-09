package com.itda.itda_mobile

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.File
import java.security.KeyStore
import java.util.concurrent.locks.ReentrantLock
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.concurrent.withLock
import org.json.JSONObject

internal class SupabaseSession(
    val owner: UploadOwner,
    val email: String,
    val accessToken: String,
    val refreshToken: String,
    val expiresAtMs: Long,
)

internal class SessionSnapshot(val session: SupabaseSession?)

internal class SessionVault(private val file: File) {
    private var cached: SessionSnapshot? = null

    @Synchronized
    fun snapshot(): SessionSnapshot = cached ?: SessionSnapshot(load()).also { cached = it }

    @Synchronized
    fun replaceIfCurrent(expected: SessionSnapshot, session: SupabaseSession?): Boolean {
        if (snapshot() !== expected) return false
        replace(session)
        return true
    }

    @Synchronized
    fun clear() = replace(null)

    private fun replace(session: SupabaseSession?) {
        if (session == null) {
            replaceDurably(file, byteArrayOf(SIGNED_OUT))
        } else {
            val json = JSONObject()
                .put("user_id", session.owner.userId.toString())
                .put("realm", session.owner.realm)
                .put("email", session.email)
                .put("access_token", session.accessToken)
                .put("refresh_token", session.refreshToken)
                .put("expires_at_ms", session.expiresAtMs)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, key())
            check(cipher.iv.size == IV_SIZE)
            val encrypted = cipher.doFinal(json.toString().toByteArray())
            replaceDurably(file, byteArrayOf(ENCRYPTED) + cipher.iv + encrypted)
        }
        cached = SessionSnapshot(session)
    }

    private fun load(): SupabaseSession? {
        if (!file.isFile) return null
        return try {
            val bytes = file.readBytes()
            if (bytes.size <= IV_SIZE + 1 || bytes[0] != ENCRYPTED) return null
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE, key(),
                GCMParameterSpec(128, bytes.copyOfRange(1, IV_SIZE + 1)),
            )
            val json = JSONObject(cipher.doFinal(bytes, IV_SIZE + 1, bytes.size - IV_SIZE - 1).decodeToString())
            SupabaseSession(
                UploadOwner(json.uuid("user_id"), json.getString("realm")),
                json.getString("email"), json.getString("access_token"),
                json.getString("refresh_token"), json.getLong("expires_at_ms"),
            )
        } catch (_: Exception) {
            // A missing key or unreadable vault requires a fresh sign-in.
            null
        }
    }

    private fun key(): SecretKey = synchronized(keyLock) {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        val existing = store.getKey(KEY_ALIAS, null) as? SecretKey
        existing ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build(),
            )
            generateKey()
        }
    }

    private companion object {
        val keyLock = Any()
        const val KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "itda_supabase_session_v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_SIZE = 12
        const val ENCRYPTED: Byte = 1
        const val SIGNED_OUT: Byte = 0
    }
}

internal class SupabaseSessions(
    private val config: UploadConfig,
    private val vault: SessionVault,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val refreshLock = ReentrantLock()

    fun current(): SupabaseSession? = vault.snapshot().session?.takeIf { it.owner.realm == config.realm }

    fun signIn(email: String, password: String): SupabaseSession = exchange(
        UploadHttp(),
        "password",
        JSONObject().put("email", email).put("password", password),
        email,
    )

    fun requireOwner(owner: UploadOwner): SupabaseSession =
        current()?.takeIf { it.owner == owner } ?: throw UploadProblem.auth()

    fun accessToken(owner: UploadOwner, http: UploadHttp, rejectedToken: String? = null): String {
        val current = requireOwner(owner)
        if (current.isUsable(rejectedToken)) return current.accessToken

        return refreshLock.withLock {
            val snapshot = vault.snapshot()
            val session = snapshot.session?.takeIf { it.owner == owner } ?: throw UploadProblem.auth()
            if (session.isUsable(rejectedToken)) return@withLock session.accessToken
            val refreshed = try {
                exchange(http, "refresh_token", JSONObject().put("refresh_token", session.refreshToken), session.email)
            } catch (problem: UploadProblem) {
                if (problem.state == UploadState.AUTH_REQUIRED) vault.replaceIfCurrent(snapshot, null)
                throw problem
            }
            if (refreshed.owner != owner || !refreshed.isUsable(rejectedToken)) {
                vault.replaceIfCurrent(snapshot, null)
                throw UploadProblem.auth()
            }
            if (!vault.replaceIfCurrent(snapshot, refreshed)) throw UploadProblem.auth()
            refreshed.accessToken
        }
    }

    fun rejectToken(owner: UploadOwner, token: String) {
        val snapshot = vault.snapshot()
        val session = snapshot.session
        if (session?.owner == owner && session.accessToken == token) vault.replaceIfCurrent(snapshot, null)
    }

    private fun SupabaseSession.isUsable(rejectedToken: String?) =
        expiresAtMs > now() + EXPIRY_MARGIN_MS && accessToken != rejectedToken

    private fun exchange(http: UploadHttp, grant: String, body: JSONObject, email: String): SupabaseSession {
        val reply = http.post(config.tokenEndpoint(grant), mapOf("apikey" to config.publishableKey), body)
        if (reply.retryable) throw UploadProblem.retry("auth_unavailable")
        if (reply.status in setOf(400, 401, 403, 422)) throw UploadProblem.auth()
        if (reply.status != 200) throw UploadProblem.permanent("auth_configuration_error")

        return decodeServer {
            val json = reply.json()
            require(json.getString("token_type").equals("bearer", ignoreCase = true))
            val user = json.getJSONObject("user")
            val owner = UploadOwner(user.uuid("id"), config.realm)
            val accessToken = json.getString("access_token")
            require(JWT.matches(accessToken))
            val payload = Base64.decode(accessToken.split('.')[1], Base64.URL_SAFE or Base64.NO_WRAP)
            val claims = JSONObject(payload.decodeToString())
            // The server verifies the JWT signature. Check the subject locally before using the token.
            if (claims.uuid("sub") != owner.userId || claims.optString("role") != "authenticated") {
                throw UploadProblem.auth("invalid_session")
            }
            val expiration = claims.getLong("exp")
            require(expiration in 1..(Long.MAX_VALUE / 1000))
            val refreshToken = json.getString("refresh_token").also { require(it.isNotBlank()) }
            SupabaseSession(owner, user.stringOrNull("email") ?: email, accessToken, refreshToken, expiration * 1000)
        }
    }

    private companion object {
        const val EXPIRY_MARGIN_MS = 30_000L
        val JWT = Regex("[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+")
    }
}
