package xyz.chromedao.smartssi

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * GitHub sign-in with the OAuth device flow, as on iOS (GitHubLogin.swift): the app needs no client secret and
 * no redirect URL. The user approves on github.com (in a Custom Tab, which shares the browser's GitHub session,
 * password managers and autofill), the app polls until GitHub hands over a token. The token only lives in memory
 * for one proof.
 *
 * Scope is empty: the token can read public profile data only, which is all `GET /user` needs.
 */
class GitHubLogin(private val clientId: String = BuildConfig.GITHUB_CLIENT_ID) {
    class DeviceCode(val deviceCode: String, val userCode: String, val verificationUri: String, val interval: Int, val expiresIn: Int)

    class Failure(message: String) : Exception(message)

    suspend fun start(): DeviceCode {
        val reply = post("https://github.com/login/device/code", mapOf("client_id" to clientId, "scope" to ""))
        if (!reply.has("device_code")) throw Failure("GitHub: ${reply.optString("error_description", reply.optString("error", "unexpected answer"))}")
        return DeviceCode(
            reply.getString("device_code"), reply.getString("user_code"), reply.getString("verification_uri"),
            reply.optInt("interval", 5), reply.optInt("expires_in", 900),
        )
    }

    /** Polls until the user approves (returns the token), denies or lets the code expire. */
    suspend fun token(code: DeviceCode): String {
        var interval = code.interval
        val deadline = System.currentTimeMillis() + code.expiresIn * 1000L
        while (System.currentTimeMillis() < deadline) {
            delay(interval * 1000L)
            // A dropped connection while the user is on github.com is not a failure: ask again at the next tick.
            val reply = try {
                post("https://github.com/login/oauth/access_token", mapOf(
                    "client_id" to clientId,
                    "device_code" to code.deviceCode,
                    "grant_type" to "urn:ietf:params:oauth:grant-type:device_code",
                ))
            } catch (_: IOException) {
                continue
            }
            reply.optString("access_token").takeIf { it.isNotEmpty() }?.let { return it }
            when (reply.optString("error")) {
                "authorization_pending" -> continue
                "slow_down" -> interval += 5
                "access_denied" -> throw Failure("GitHub sign-in was cancelled")
                "expired_token" -> throw Failure("GitHub code expired, try again")
                else -> throw Failure("GitHub: ${reply.optString("error_description", reply.optString("error", "unexpected answer"))}")
            }
        }
        throw Failure("GitHub code expired, try again")
    }

    private suspend fun post(url: String, form: Map<String, String>): JSONObject = withContext(Dispatchers.IO) {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.setRequestProperty("Accept", "application/json")
        connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        val body = form.entries.joinToString("&") { "${it.key}=${URLEncoder.encode(it.value, "UTF-8")}" }
        connection.outputStream.use { it.write(body.toByteArray()) }
        val stream = if (connection.responseCode < 400) connection.inputStream else connection.errorStream
        runCatching { JSONObject(stream.bufferedReader().use { it.readText() }) }.getOrDefault(JSONObject())
    }
}
