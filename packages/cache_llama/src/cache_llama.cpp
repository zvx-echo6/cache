#include "cache_llama.h"

#include "chat.h"
#include "common.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "llama.h"
#include "sampling.h"

#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <utility>
#include <vector>

#if defined(__ANDROID__)
#include <android/log.h>
#include <dlfcn.h>
#include <sys/stat.h>
#endif

namespace {

struct Handle {
    llama_model *             model = nullptr;
    llama_context *           ctx   = nullptr;
    const llama_vocab *       vocab = nullptr;
    common_chat_templates_ptr tmpls;
    int                       n_ctx = 0;
    ggml_threadpool_t         pool  = nullptr;  // pinned threadpool (Android with several CPU clusters), else null
    void                   (* pool_free)(ggml_threadpool_t) = nullptr;

    // Tokens whose keys/values are in the KV cache, in order (the prompt of the last cl_start plus
    // everything generated and decoded since). The next cl_start reuses the common prefix.
    std::vector<llama_token>  cached;
    int                       n_reused = 0;  // prompt tokens of the last cl_start taken from the cache

    // state of the current generation
    std::unique_ptr<common_chat_session> session;
    common_sampler_ptr                   smpl;
    std::string                          generated;  // full generated text (parsed by cl_finish)
    std::string                          pending;    // bytes not yet returned (incomplete UTF-8)
    size_t                               fed         = 0;        // bytes of `generated` already given to the parser
    int                                  n_past      = 0;
    int                                  n_prompt    = 0;
    int                                  n_generated = 0;
    bool                                 finished    = true;
    std::atomic<bool>                    stop{false};
};

void set_err(char * err, int len, const std::string & msg) {
    if (err && len > 0) {
        snprintf(err, (size_t) len, "%s", msg.c_str());
    }
}

// Copies s into out; returns the length or -1 if it does not fit.
int put(const std::string & s, char * out, int len) {
    if (!out || (int) s.size() + 1 > len) {
        return -1;
    }
    memcpy(out, s.c_str(), s.size() + 1);
    return (int) s.size();
}

// Number of leading bytes of s that form complete UTF-8 characters.
size_t utf8_complete_prefix(const std::string & s) {
    size_t n = s.size();
    for (size_t back = 1; back <= 3 && back <= n; back++) {
        unsigned char c = (unsigned char) s[n - back];
        if ((c & 0xC0) == 0x80) {
            continue;  // continuation byte, keep looking for the lead byte
        }
        size_t need = c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 1;
        return need > back ? n - back : n;
    }
    return n;
}

void cl_logi(const char * fmt, ...) {
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
#if defined(__ANDROID__)
    __android_log_print(ANDROID_LOG_INFO, "cache_llama", "%s", line);
#else
    (void) line;
#endif
}

void quiet_log(enum ggml_log_level level, const char * text, void *) {
    if (level >= GGML_LOG_LEVEL_WARN) {
        fputs(text, stderr);
    }
}

#if defined(__ANDROID__)
// Used while the CPU backend variants are loaded: lets the "loaded CPU backend from ..." line through.
void backend_load_log(enum ggml_log_level level, const char * text, void *) {
    if (level >= GGML_LOG_LEVEL_INFO) {
        __android_log_print(level >= GGML_LOG_LEVEL_WARN ? ANDROID_LOG_WARN : ANDROID_LOG_INFO, "cache_llama", "%s", text);
    }
}
#endif

#if defined(CL_BACKEND_DL)
// With GGML_BACKEND_DL the CPU backend is a set of libggml-cpu-*.so variants next to this library.
// ggml scores each one against the running CPU and loads the best. Returns an error text, or "" if ok.
std::string load_cpu_backend() {
    static std::once_flag once;
    static std::string    result;
    std::call_once(once, [] {
        Dl_info info;
        if (!dladdr((void *) &load_cpu_backend, &info) || !info.dli_fname) {
            result = "cannot find the folder of the native libraries";
            return;
        }
        std::string dir = info.dli_fname;
        dir = dir.substr(0, dir.rfind('/'));
        llama_log_set(backend_load_log, nullptr);
        ggml_backend_load_all_from_path(dir.c_str());
        llama_log_set(quiet_log, nullptr);
        ggml_backend_dev_t dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
        if (!dev) {
            result = "no CPU backend variant could be loaded from " + dir;
            return;
        }
        cl_logi("native library folder: %s", dir.c_str());
        ggml_backend_reg_t reg = ggml_backend_dev_backend_reg(dev);
        auto * features_fn = (ggml_backend_get_features_t) ggml_backend_reg_get_proc_address(reg, "ggml_backend_get_features");
        if (features_fn) {
            std::string f;
            for (auto * ft = features_fn(reg); ft && ft->name; ft++) {
                if (std::string(ft->value) != "0") f += std::string(f.empty() ? "" : " ") + ft->name;
            }
            cl_logi("CPU features used by the loaded variant: %s", f.c_str());
        }
    });
    return result;
}
#endif

// Which CPU cores to compute on. cpus is empty when no pinning is wanted.
struct CpuPlan {
    int              n_threads = 4;
    std::vector<int> cpus;
};

// Android phones mix fast and slow ("little") cores; threads on the slow ones hold every step back.
// Read each core's max frequency, leave out the slowest cluster when there is more than one, and use
// at most 5 of the rest. If the files cannot be read: 4 threads, no pinning.
CpuPlan plan_cpus() {
    CpuPlan plan;
#if defined(__ANDROID__)
    std::vector<std::pair<int, long>> cores;  // (cpu, max kHz)
    bool ok = true;
    for (int i = 0; i < 64; i++) {
        char dir[96], path[128];
        snprintf(dir, sizeof(dir), "/sys/devices/system/cpu/cpu%d", i);
        struct stat st;
        if (stat(dir, &st) != 0) break;  // no more cores
        snprintf(path, sizeof(path), "%s/cpufreq/cpuinfo_max_freq", dir);
        long khz = 0;
        if (FILE * f = fopen(path, "r")) {
            if (fscanf(f, "%ld", &khz) != 1) khz = 0;
            fclose(f);
        }
        if (khz <= 0) { ok = false; break; }
        cores.emplace_back(i, khz);
    }
    if (!ok || cores.empty()) {
        cl_logi("cannot read the CPU frequencies: %d threads, not pinned", plan.n_threads);
        return plan;
    }
    std::set<long> clusters;
    for (auto & c : cores) clusters.insert(c.second);
    if (clusters.size() > 1) {
        const long slowest = *clusters.begin();
        cores.erase(std::remove_if(cores.begin(), cores.end(), [&](const std::pair<int, long> & c) { return c.second == slowest; }),
                    cores.end());
    }
    // keep the fastest 5, then order by core number
    std::stable_sort(cores.begin(), cores.end(), [](const std::pair<int, long> & a, const std::pair<int, long> & b) { return a.second > b.second; });
    if (cores.size() > 5) cores.resize(5);
    std::sort(cores.begin(), cores.end());
    plan.n_threads = (int) cores.size();
    std::string list;
    for (auto & c : cores) {
        plan.cpus.push_back(c.first);
        list += (list.empty() ? "" : ",") + std::to_string(c.first);
    }
    cl_logi("%d CPU clusters; using %d threads pinned to cores %s", (int) clusters.size(), plan.n_threads, list.c_str());
#endif
    return plan;
}

}  // namespace

extern "C" {

void * cl_load(const char * model_path, int n_ctx, int n_threads, char * err, int err_len) {
    try {
        if (n_ctx <= 0)     n_ctx = 8192;
        llama_log_set(quiet_log, nullptr);
#if defined(CL_BACKEND_DL)
        if (std::string why = load_cpu_backend(); !why.empty()) {
            set_err(err, err_len, why);
            return nullptr;
        }
#endif
        llama_backend_init();
        CpuPlan plan;  // automatic choice, only used when the caller gives no thread count
        if (n_threads <= 0) {
            plan      = plan_cpus();
            n_threads = plan.n_threads;
        }

        auto h = std::make_unique<Handle>();
        llama_model_params mp = llama_model_default_params();
        h->model = llama_model_load_from_file(model_path, mp);
        if (!h->model) {
            set_err(err, err_len, std::string("cannot load model: ") + model_path);
            return nullptr;
        }
        h->vocab = llama_model_get_vocab(h->model);

        llama_context_params cp = llama_context_default_params();
        cp.n_ctx           = (uint32_t) n_ctx;
        cp.n_batch         = 512;
        cp.n_threads       = n_threads;
        cp.n_threads_batch = n_threads;
        h->ctx = llama_init_from_model(h->model, cp);
        if (!h->ctx) {
            set_err(err, err_len, "cannot create context (out of memory?)");
            llama_model_free(h->model);
            return nullptr;
        }
        h->n_ctx = (int) llama_n_ctx(h->ctx);

        if (!plan.cpus.empty()) {
            // A threadpool whose threads are each pinned to one of the chosen cores.
            ggml_backend_dev_t dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
            ggml_backend_reg_t reg = dev ? ggml_backend_dev_backend_reg(dev) : nullptr;
            auto * pool_new  = reg ? (decltype(ggml_threadpool_new) *) ggml_backend_reg_get_proc_address(reg, "ggml_threadpool_new") : nullptr;
            auto * pool_free = reg ? (decltype(ggml_threadpool_free) *) ggml_backend_reg_get_proc_address(reg, "ggml_threadpool_free") : nullptr;
            if (pool_new && pool_free) {
                ggml_threadpool_params tpp = ggml_threadpool_params_default(n_threads);
                for (int c : plan.cpus) tpp.cpumask[c] = true;
                tpp.strict_cpu = true;
                h->pool = pool_new(&tpp);
                if (h->pool) {
                    h->pool_free = pool_free;
                    llama_attach_threadpool(h->ctx, h->pool, nullptr);
                } else {
                    cl_logi("cannot create the pinned threadpool: threads not pinned");
                }
            } else {
                cl_logi("no threadpool support in the CPU backend: threads not pinned");
            }
        }

        h->tmpls = common_chat_templates_init(h->model, "");
        if (!h->tmpls) {
            set_err(err, err_len, "model has no usable chat template");
            llama_free(h->ctx);
            if (h->pool) h->pool_free(h->pool);
            llama_model_free(h->model);
            return nullptr;
        }
        return h.release();
    } catch (const std::exception & e) {
        set_err(err, err_len, e.what());
        return nullptr;
    }
}

int cl_info(void * hp, char * out_json, int len) {
    auto * h = (Handle *) hp;
    try {
        char desc[256] = "";
        llama_model_desc(h->model, desc, sizeof(desc));

        // Probe: does the template produce a tool-call format for a dummy tool?
        common_chat_templates_inputs in;
        common_chat_msg u;
        u.role = "user";
        u.content = "hi";
        in.messages = { u };
        common_chat_tool t;
        t.name = "probe";
        t.description = "probe";
        t.parameters = R"({"type":"object","properties":{"q":{"type":"string"}},"required":["q"]})";
        in.tools = { t };
        in.reasoning_format = COMMON_REASONING_FORMAT_AUTO;
        auto probe = common_chat_templates_apply(h->tmpls.get(), in);

        auto j = common_json::object();
        j["description"]    = std::string(desc);
        j["n_ctx"]          = h->n_ctx;
        j["chat_format"]    = std::string(common_chat_format_name(probe.format));
        j["supports_tools"] = probe.format != COMMON_CHAT_FORMAT_CONTENT_ONLY;
        return put(j.dump(), out_json, len);
    } catch (const std::exception &) {
        return -1;
    }
}

int cl_start(void * hp, const char * request_json, char * err, int err_len) {
    auto * h = (Handle *) hp;
    try {
        h->finished = true;
        h->session.reset();
        h->smpl.reset();
        h->generated.clear();
        h->pending.clear();
        h->fed = 0;
        h->n_generated = 0;
        h->n_reused = 0;
        h->stop = false;

        auto req = common_json::parse(request_json);
        common_chat_templates_inputs in;
        in.messages         = common_chat_msgs_parse_oaicompat(req.at("messages"));
        in.reasoning_format = COMMON_REASONING_FORMAT_AUTO;
        // Optional top-level "enable_thinking": true|false. Passed to the template as the
        // enable_thinking variable (Gemma 4 emits its thinking switch from it). Default: true.
        if (req.contains("enable_thinking") && req.at("enable_thinking").is_boolean()) {
            in.enable_thinking = req.at("enable_thinking").get<bool>();
        }
        if (req.contains("tools") && req.at("tools").is_array() && req.at("tools").size() > 0) {
            in.tools = common_chat_tools_parse_oaicompat(req.at("tools"));
        }

        // The session wraps common_chat_templates_apply and keeps the parser for cl_finish.
        h->session = std::make_unique<common_chat_session>(h->tmpls.get(), h->vocab, in);

        common_params_sampling sp;
        sp.temp  = 0.7f;
        sp.top_p = 0.95f;
        // Optional top-level "temperature" (0 = greedy, used by tests that compare outputs).
        if (req.contains("temperature") && req.at("temperature").is_number()) {
            sp.temp = req.at("temperature").get<float>();
        }
        h->session->apply_sampling(sp);  // tool-call grammar (lazy) and its triggers
        h->smpl.reset(common_sampler_init(h->model, sp));
        if (!h->smpl) {
            set_err(err, err_len, "cannot create sampler");
            return -1;
        }

        if (const char * dbg = getenv("CL_LOG_PROMPT_TAIL")) {  // debugging aid: show the end of the rendered prompt
            const std::string & ps = h->session->prompt().str();
            int n = atoi(dbg) > 0 ? atoi(dbg) : 400;
            fprintf(stderr, "[cl] enable_thinking=%d prompt tail:\n%s\n[cl] end tail\n", (int) in.enable_thinking,
                    ps.substr(ps.size() > (size_t) n ? ps.size() - (size_t) n : 0).c_str());
        }

        auto tokens = common_tokenize(h->vocab, h->session->prompt().str(), /*add_special*/ false, /*parse_special*/ true);
        h->n_prompt = (int) tokens.size();
        if (h->n_prompt == 0 || h->n_prompt >= h->n_ctx) {
            set_err(err, err_len, "prompt does not fit the context (" + std::to_string(h->n_prompt) + " tokens)");
            return -1;
        }

        // Keep what the KV cache already holds for the start of this prompt: find the longest common
        // token prefix, drop the cache after it and decode only the rest. At least the last prompt
        // token is always decoded, because the first generated token needs its logits.
        llama_memory_t mem = llama_get_memory(h->ctx);
        size_t keep = 0;
        {
            const size_t limit = std::min(h->cached.size(), tokens.size() - 1);
            while (keep < limit && h->cached[keep] == tokens[keep]) keep++;
        }
        if (keep == 0) {
            llama_memory_clear(mem, true);
        } else if (keep < h->cached.size() && !llama_memory_seq_rm(mem, 0, (llama_pos) keep, -1)) {
            // Some caches (sliding-window attention) cannot drop just a tail: start over, correct but slower.
            llama_memory_clear(mem, true);
            keep = 0;
        }
        h->cached.resize(keep);
        h->n_reused = (int) keep;

        const int n_batch = 512;
        for (int i = (int) keep; i < h->n_prompt; i += n_batch) {
            int n = std::min(n_batch, h->n_prompt - i);
            if (llama_decode(h->ctx, llama_batch_get_one(tokens.data() + i, n)) != 0) {
                llama_memory_clear(mem, true);
                h->cached.clear();
                h->n_reused = 0;
                set_err(err, err_len, "decode failed while reading the prompt");
                return -1;
            }
            h->cached.insert(h->cached.end(), tokens.begin() + i, tokens.begin() + i + n);
        }
        h->n_past   = h->n_prompt;
        h->finished = false;
        return 0;
    } catch (const std::exception & e) {
        set_err(err, err_len, e.what());
        return -1;
    }
}

int cl_next(void * hp, char * buf, int buf_len) {
    auto * h = (Handle *) hp;
    try {
        if (h->finished || h->stop.load()) {
            h->finished = true;
            return -1;
        }
        llama_token tok = common_sampler_sample(h->smpl.get(), h->ctx, -1);
        common_sampler_accept(h->smpl.get(), tok, /*is_generated*/ true);
        if (llama_vocab_is_eog(h->vocab, tok)) {
            h->finished = true;
            return -1;
        }
        h->n_generated++;
        // Special tokens are kept: the tool-call parser needs their markup.
        std::string piece = common_token_to_piece(h->vocab, tok, true);
        h->generated += piece;
        h->pending   += piece;

        if (h->n_past + 1 >= h->n_ctx) {
            h->finished = true;  // context full: this is the last token
        } else if (llama_decode(h->ctx, llama_batch_get_one(&tok, 1)) != 0) {
            llama_memory_clear(llama_get_memory(h->ctx), true);  // the cache no longer matches `cached`
            h->cached.clear();
            return -2;
        } else {
            h->n_past++;
            h->cached.push_back(tok);
        }

        size_t n = utf8_complete_prefix(h->pending);
        if ((int) n > buf_len - 1) {
            n = utf8_complete_prefix(h->pending.substr(0, (size_t) std::max(buf_len - 1, 0)));
        }
        memcpy(buf, h->pending.data(), n);
        buf[n] = 0;
        h->pending.erase(0, n);
        return (int) n;
    } catch (const std::exception &) {
        return -2;
    }
}

static void msg_to_json(const common_chat_msg & msg, common_json & j) {
    j["content"] = msg.content;
    if (!msg.reasoning_content.empty()) {
        j["reasoning_content"] = msg.reasoning_content;
    }
    if (!msg.tool_calls.empty()) {
        auto calls = common_json::array();
        int  n     = 0;
        for (const auto & tc : msg.tool_calls) {
            auto c = common_json::object();
            c["id"]   = tc.id.empty() ? "call_" + std::to_string(n) : tc.id;
            c["type"] = std::string("function");
            auto f = common_json::object();
            f["name"]      = tc.name;
            f["arguments"] = tc.arguments;  // JSON string, as in the OpenAI API
            c["function"]  = f;
            calls.push_back(c);
            n++;
        }
        j["tool_calls"] = calls;
    }
}

int cl_partial(void * hp, char * out_json, int len) {
    auto * h = (Handle *) hp;
    auto j = common_json::object();
    j["role"] = std::string("assistant");
    try {
        if (!h->session) {
            return -1;
        }
        // only whole UTF-8 characters go to the parser (a held-back partial character stays for later)
        std::string chunk = h->generated.substr(h->fed);
        chunk.resize(utf8_complete_prefix(chunk));
        const common_chat_msg & msg = h->session->feed(common_chat_input(chunk));
        h->fed += chunk.size();
        msg_to_json(msg, j);
    } catch (const std::exception & e) {
        j["content"]     = std::string();
        j["parse_error"] = std::string(e.what());
    }
    return put(j.dump(), out_json, len);
}

int cl_finish(void * hp, char * out_json, int len) {
    auto * h = (Handle *) hp;
    auto j = common_json::object();
    j["role"] = std::string("assistant");
    try {
        const common_chat_msg & msg = h->session->finish(common_chat_input(h->generated.substr(h->fed)));
        h->fed = h->generated.size();
        msg_to_json(msg, j);
    } catch (const std::exception & e) {
        j["content"]     = h->generated;
        j["parse_error"] = std::string(e.what());
    }
    return put(j.dump(), out_json, len);
}

int cl_prompt_tokens(void * hp)    { return ((Handle *) hp)->n_prompt; }
int cl_generated_tokens(void * hp) { return ((Handle *) hp)->n_generated; }
int cl_reused_tokens(void * hp)    { return ((Handle *) hp)->n_reused; }

void cl_stop(void * hp) { ((Handle *) hp)->stop.store(true); }

void cl_free(void * hp) {
    auto * h = (Handle *) hp;
    if (!h) return;
    h->smpl.reset();
    h->session.reset();
    h->tmpls.reset();
    if (h->ctx)   llama_free(h->ctx);
    if (h->pool)  h->pool_free(h->pool);
    if (h->model) llama_model_free(h->model);
    delete h;
}

}  // extern "C"
