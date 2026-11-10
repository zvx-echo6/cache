import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.InputData
import com.google.ai.edge.litertlm.ResponseCallback
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.ai.edge.litertlm.Session
import com.google.ai.edge.litertlm.SessionConfig
import java.io.File
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

// Raw text goes in as given: the stock gemma-4-E2B-it.litertlm has no prompt templates, so a Session adds only BOS to the first
// prefill of a fresh session. Everything runs greedy (temperature 0, top-k 1).

private const val MAX_CHUNKS = 160

private fun esc(s: String): String = buildString {
    for (c in s) when {
        c == '\n' -> append("\\n")
        c == '\t' -> append("\\t")
        c == '\r' -> append("\\r")
        c.code < 32 || c.code == 127 -> append("\\u%04x".format(c.code))
        else -> append(c)
    }
}

private fun rssKb(): Long =
    File("/proc/self/status").readLines().first { it.startsWith("VmRSS:") }.split(Regex("\\s+"))[1].toLong()

private val greedy = SamplerConfig(topK = 1, topP = 1.0, temperature = 0.0)

private lateinit var engine: Engine

private fun fresh(): Session = engine.createSession(SessionConfig(samplerConfig = greedy))

private fun prefill(s: Session, text: String) = s.runPrefill(listOf(InputData.Text(text)))

// Decodes what the session has prefilled; the text of the chunks joined. Stops after MAX_CHUNKS chunks.
private fun decode(s: Session): String {
    val sb = StringBuilder()
    var n = 0
    var err: Throwable? = null
    val done = CountDownLatch(1)
    s.generateContentStream(emptyList(), object : ResponseCallback {
        override fun onNext(response: String) {
            sb.append(response)
            if (++n >= MAX_CHUNKS) s.cancelProcess()
        }

        override fun onDone() = done.countDown()

        override fun onError(throwable: Throwable) {
            if (throwable !is CancellationException) err = throwable
            done.countDown()
        }
    })
    if (!done.await(20, TimeUnit.MINUTES)) error("decode timed out")
    err?.let { throw it }
    return sb.toString()
}

private fun show(tag: String, text: String) = println("$tag ${esc(text)}")

private fun <T> attempt(tag: String, f: () -> T): T? =
    try {
        f()
    } catch (t: Throwable) {
        println("$tag FAILED: $t")
        null
    }

private const val PROMPT_A = "<|turn>user\nWhat is 2+2? Answer in one word.<turn|>\n<|turn>model\n"

// The Gemma 4 tool format as the stock template renders one declared tool (system turn, a blank line, <|tool>declaration:...<tool|>).
private const val SYSTEM_B =
    "<|turn>system\nYou are a helpful assistant. Use the search tool for any factual question.\n\n" +
        "<|tool>declaration:search{description:<|\"|>Search the library.<|\"|>,parameters:{properties:{query:{description:<|\"|>What to search for.<|\"|>,type:<|\"|>STRING<|\"|>}},required:[<|\"|>query<|\"|>],type:<|\"|>OBJECT<|\"|>}}<tool|><turn|>\n"
private const val USER_B = "<|turn>user\nHow do I purify water when camping?<turn|>\n<|turn>model\n"
private const val FOLLOW_UP = "<|turn>user\nAnd what is 3+3? Answer in one word.<turn|>\n<|turn>model\n"

fun main(args: Array<String>) {
    val model = args[0]
    val cache = File(System.getProperty("java.io.tmpdir"), "litert-smoke-cache").apply { mkdirs() }
    println("model: $model (${File(model).length()} bytes)")
    val t0 = System.nanoTime()
    engine = Engine(EngineConfig(modelPath = model, backend = Backend.CPU(), maxNumTokens = 4096, cacheDir = cache.path))
    engine.initialize()
    println("engine initialized in ${(System.nanoTime() - t0) / 1_000_000} ms")

    // (a) raw prefill, then decode
    println("== (a) raw prefill of a user turn, then decode")
    val sa = fresh()
    prefill(sa, PROMPT_A)
    val outA = decode(sa)
    show("(a) output:", outA)

    // (b) a tool declared in the system turn
    println("== (b) tool declared in the system turn")
    val promptB = SYSTEM_B + USER_B
    val sb = fresh()
    prefill(sb, promptB)
    val outB = decode(sb)
    show("(b) output:", outB)
    println("(b) has <|tool_call> as text: ${outB.contains("<|tool_call>")}")
    println("(b) has <|\"|> as text: ${outB.contains("<|\"|>")}")
    println("(b) has <tool_call|> as text: ${outB.contains("<tool_call|>")}")
    sb.close()

    // (c) prefix reuse: clone a checkpoint, prefill the rest; against a fresh full prefill
    println("== (c) clone of a checkpoint + remainder vs a fresh full prefill")
    val full = fresh()
    prefill(full, promptB)
    val outFull = decode(full)
    full.close()
    show("(c) fresh full prefill:", outFull)
    for ((name, cut) in listOf("system turn" to SYSTEM_B.length, "inside the user turn" to SYSTEM_B.length + "<|turn>user\n".length)) {
        val ckpt = fresh()
        prefill(ckpt, promptB.substring(0, cut))
        val work = ckpt.clone()
        prefill(work, promptB.substring(cut))
        val outClone = decode(work)
        show("(c) checkpoint at $name, clone + rest:", outClone)
        println("(c) identical to the fresh full prefill ($name): ${outClone == outFull}")
        // the checkpoint itself is still usable after a clone was decoded
        val work2 = ckpt.clone()
        prefill(work2, promptB.substring(cut))
        println("(c) second clone of the same checkpoint ($name) identical: ${decode(work2) == outFull}")
        work.close()
        work2.close()
        ckpt.close()
    }

    // (d) the KV after a decode: is the stop token (and its newline) in it?
    println("== (d) follow-up on the same session after decoding (a), against a fresh session with the full text")
    val freshText = PROMPT_A + outA + "<turn|>\n" + FOLLOW_UP
    val sf = fresh()
    prefill(sf, freshText)
    val outFresh = decode(sf)
    sf.close()
    show("(d) fresh session, prompt + output + <turn|>\\n + follow-up:", outFresh)
    for ((name, text) in listOf("follow-up only" to FOLLOW_UP, "\\n + follow-up" to "\n$FOLLOW_UP", "<turn|>\\n + follow-up" to "<turn|>\n$FOLLOW_UP")) {
        attempt("(d) $name") {
            val c = sa.clone()
            prefill(c, text)
            val o = decode(c)
            c.close()
            show("(d) same session, prefill $name:", o)
            println("(d) same session, prefill $name, matches the fresh session: ${o == outFresh}")
        }
    }
    sa.close()

    // (e) clone cost
    println("== (e) clone() time and process RSS")
    val big = fresh()
    prefill(big, promptB)
    val rssBefore = rssKb()
    val times = ArrayList<Long>()
    val clones = ArrayList<Session>()
    var rssAfterOne = -1L
    for (i in 0 until 3) {
        val a = System.nanoTime()
        clones.add(big.clone())
        times.add((System.nanoTime() - a) / 1000)
        if (i == 0) rssAfterOne = rssKb()
    }
    println("(e) prompt of ${promptB.length} chars prefilled; clone times (microseconds): $times")
    println("(e) RSS before the first clone: $rssBefore kB, after one clone: $rssAfterOne kB (+${rssAfterOne - rssBefore} kB), after three: ${rssKb()} kB")
    clones.forEach { it.close() }
    big.close()
    engine.close()
    println("done")
}
