package xyz.chromedao.smartssi

import android.content.Context
import android.os.Bundle
import android.util.Base64
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import uniffi.smart_ssi_mobile.GithubProof
import uniffi.smart_ssi_mobile.proveGithub
import uniffi.smart_ssi_mobile.walletAddress
import uniffi.smart_ssi_mobile.walletNewSeed
import uniffi.smart_ssi_mobile.walletSign
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

private val Green = Color(0xFF00FF41)
private val Mono = FontFamily.Monospace

/** Wallet seed, encrypted at rest with a key from the Android Keystore. It never leaves the phone. */
class Wallet(context: Context) {
    private val prefs = EncryptedSharedPreferences.create(
        context,
        "smart-ssi-wallet",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )
    private val seed: ByteArray = prefs.getString("seed", null)?.let { Base64.decode(it, Base64.NO_WRAP) }
        ?: walletNewSeed().also { prefs.edit().putString("seed", Base64.encodeToString(it, Base64.NO_WRAP)).apply() }

    val address: String = walletAddress(seed)

    fun sign(message: String): String = Base64.encodeToString(walletSign(seed, message), Base64.NO_WRAP)
}

/** Client for the Smart-SSI issuer API (issuer/src/server.ts). Issue and revoke are signed by the wallet. */
class IssuerClient(private val baseUrl: String, private val wallet: Wallet) {
    fun issue(presentation: ByteArray): JSONObject {
        val hash = MessageDigest.getInstance("SHA-256").digest(presentation).joinToString("") { "%02x".format(it) }
        return send("POST", "/v1/attestations", JSONObject()
            .put("wallet", wallet.address)
            .put("presentation", Base64.encodeToString(presentation, Base64.NO_WRAP))
            .put("signature", wallet.sign("smart-ssi:issue:$hash")))
    }

    fun check(): JSONObject = send("GET", "/v1/attestations/${wallet.address}", null)

    fun revoke(): JSONObject {
        val timestamp = System.currentTimeMillis() / 1000
        return send("DELETE", "/v1/attestations/${wallet.address}", JSONObject()
            .put("timestamp", timestamp)
            .put("signature", wallet.sign("smart-ssi:revoke:${wallet.address}:$timestamp")))
    }

    private fun send(method: String, path: String, body: JSONObject?): JSONObject {
        val connection = URL(baseUrl + path).openConnection() as HttpURLConnection
        connection.requestMethod = method
        if (body != null) {
            connection.doOutput = true
            connection.setRequestProperty("content-type", "application/json")
            connection.outputStream.use { it.write(body.toString().toByteArray()) }
        }
        val status = connection.responseCode
        val text = (if (status < 400) connection.inputStream else connection.errorStream).bufferedReader().use { it.readText() }
        val json = runCatching { JSONObject(text) }.getOrDefault(JSONObject())
        if (status !in 200..299) throw IllegalStateException("$status: ${json.optString("error", "request failed")}")
        return json
    }
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Development: `adb shell am start -n <app>/.MainActivity -e login <name>` prefills the login.
        val initialLogin = intent.getStringExtra("login") ?: ""
        // `-e notary host:port -e issuer url` override the development servers (real phones).
        val notary = intent.getStringExtra("notary") ?: "wss://smart-ssi-notary-ikgz5gajyq-ew.a.run.app"
        val issuer = intent.getStringExtra("issuer") ?: "https://smart-ssi-issuer-ikgz5gajyq-ew.a.run.app"
        val wallet = runCatching { Wallet(this) }
        setContent { ProofScreen(wallet, initialLogin, notary, issuer) }
    }
}

@Composable
fun ProofScreen(wallet: Result<Wallet>, initialLogin: String, initialNotary: String, initialIssuer: String) {
    var login by remember { mutableStateOf(initialLogin) }
    var notary by remember { mutableStateOf(initialNotary) }
    var issuerUrl by remember { mutableStateOf(initialIssuer) }
    var busy by remember { mutableStateOf(false) }
    var proof by remember { mutableStateOf<GithubProof?>(null) }
    val log = remember { mutableStateListOf<String>() }
    val scope = rememberCoroutineScope()
    fun note(line: String) = log.add(0, line)

    fun issuer(label: String, call: (IssuerClient) -> JSONObject) {
        val w = wallet.getOrNull() ?: return note("wallet unavailable")
        busy = true
        scope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { call(IssuerClient(issuerUrl, w)) } }
            busy = false
            result.fold(
                { json -> note("$label: " + listOf("claim", "valid", "reason", "revoked", "attestation").filter(json::has).joinToString(" ") { "$it=${json.get(it)}" }) },
                { note("$label failed: ${it.message}") },
            )
        }
    }

    Column(
        Modifier.fillMaxSize().background(Color.Black).systemBarsPadding().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text("CHROME DAO · SMART-SSI", color = Green, fontFamily = Mono, fontSize = 12.sp)
        Text("Prove what you did.\nReveal nothing else.", color = Color.White, fontFamily = Mono, fontWeight = FontWeight.Bold, fontSize = 22.sp)

        Section("WALLET") {
            SelectionContainer {
                Text(wallet.fold({ it.address }, { "error: ${it.message}" }), color = Color.White, fontFamily = Mono, fontSize = 12.sp)
            }
        }

        Section("GITHUB") {
            OutlinedTextField(login, { login = it }, label = { Text("login") }, singleLine = true, colors = fieldColors(), modifier = Modifier.fillMaxWidth())
            GreenButton(if (busy) "WORKING…" else "PROVE ON THIS PHONE", enabled = !busy) {
                if (login.isBlank()) return@GreenButton note("enter a GitHub login")
                busy = true
                proof = null
                note("proving $login through $notary…")
                scope.launch {
                    val result = withContext(Dispatchers.Default) { runCatching { proveGithub(login.trim(), notary) } }
                    busy = false
                    result.fold(
                        {
                            proof = it
                            note("proof done in %.1f s, %d bytes".format(it.seconds, it.presentation.size))
                            Log.i("SmartSSI", "proof done in %.1f s".format(it.seconds))
                        },
                        { note("proof failed: ${it.message}"); Log.e("SmartSSI", "proof failed: ${it.message}") },
                    )
                }
            }
        }

        proof?.let { p ->
            Section("ISSUER WILL SEE") { Text(p.revealedJson, color = Color.White, fontFamily = Mono, fontSize = 12.sp) }
            Section("CLAIM") {
                Text(p.claimJson, color = Green, fontFamily = Mono, fontSize = 12.sp)
                Text("%.1f s on device".format(p.seconds), color = Color.Gray, fontFamily = Mono, fontSize = 11.sp)
            }
            GreenButton("GET ATTESTATION", enabled = !busy) { issuer("attestation") { it.issue(p.presentation) } }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            GreenButton("CHECK", enabled = !busy, modifier = Modifier.weight(1f)) { issuer("check") { it.check() } }
            GreenButton("REVOKE", enabled = !busy, modifier = Modifier.weight(1f)) { issuer("revoke") { it.revoke() } }
        }

        Section("DEVELOPMENT SERVERS") {
            OutlinedTextField(notary, { notary = it }, label = { Text("notary host:port") }, singleLine = true, colors = fieldColors(), modifier = Modifier.fillMaxWidth())
            OutlinedTextField(issuerUrl, { issuerUrl = it }, label = { Text("issuer URL") }, singleLine = true, colors = fieldColors(), modifier = Modifier.fillMaxWidth())
        }

        Section("LOG") { log.forEach { Text(it, color = Color.Gray, fontFamily = Mono, fontSize = 11.sp) } }
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("[$title]", color = Green, fontFamily = Mono, fontSize = 12.sp)
        content()
    }
}

@Composable
private fun GreenButton(label: String, enabled: Boolean, modifier: Modifier = Modifier.fillMaxWidth(), onClick: () -> Unit) {
    OutlinedButton(onClick, enabled = enabled, modifier = modifier, border = BorderStroke(1.dp, Green), shape = androidx.compose.ui.graphics.RectangleShape) {
        Text(label, color = Green, fontFamily = Mono, fontWeight = FontWeight.Bold, fontSize = 12.sp)
    }
}

@Composable
private fun fieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Color.White,
    unfocusedTextColor = Color.White,
    focusedBorderColor = Green,
    unfocusedBorderColor = Color.Gray,
    focusedLabelColor = Green,
    unfocusedLabelColor = Color.Gray,
    cursorColor = Green,
)
