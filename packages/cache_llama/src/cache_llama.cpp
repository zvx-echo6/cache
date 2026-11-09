#include "cache_llama.h"

#include "chat.h"
#include "common.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "gguf.h"
#include "llama.h"
#include "sampling.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <memory>
#include <mutex>
#include <regex>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include <sys/stat.h>
#if !defined(_WIN32)
#include <sys/mman.h>
#include <unistd.h>
#endif

#if defined(__ANDROID__)
#include <android/log.h>
#endif
#if defined(__ANDROID__) || defined(CL_BACKEND_DL)
#include <dlfcn.h>
#endif

namespace {

// One tensor of the model file, for the memmap diagnostic: where its data lies in the file, and its group.
struct MemTensor {
    std::string name;
    int         group    = 7;
    uint64_t    off      = 0;      // absolute file offset of the data
    uint64_t    size     = 0;
    bool        repacked = false;  // loaded into the CPU_REPACK buffer (repack_tensors): not backed by the file mapping
};

struct Handle {
    llama_model *             model = nullptr;
    llama_context *           ctx   = nullptr;
    const llama_vocab *       vocab = nullptr;
    common_chat_templates_ptr tmpls;
    int                       n_ctx = 0;
    ggml_threadpool_t         pool  = nullptr;  // pinned threadpool (Android with several CPU clusters), else null
    ggml_threadpool_t         pool_batch = nullptr;  // second pinned pool for prompt reading, only when its thread count differs
    void                   (* pool_free)(ggml_threadpool_t) = nullptr;

    // Tokens whose keys/values are in the KV cache, in order (the prompt of the last cl_start plus
    // everything generated and decoded since). The next cl_start reuses the common prefix.
    std::vector<llama_token>  cached;
    int                       n_reused = 0;  // prompt tokens of the last cl_start taken from the cache
    int                       first_token = -1;  // first token of the last cl_start's prompt

    // Sampling defaults: llama.cpp's own, replaced by what the GGUF recommends (general.sampling.*) at load.
    common_params_sampling    sampling;

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
    std::vector<llama_token>             stop_tokens;  // tool_choice "none": tool-call openings end the generation

    // How the weights were loaded (cl_info): "repacked", "mmap" or "default", and why.
    std::string engine_line;  // the "engine: ..." line of this load (cl_info)
    // repack_tensors: the override list handed to llama.cpp (NULL-terminated) and the pattern it points to; both must outlive the load.
    std::string                      repack_pat;
    llama_model_tensor_buft_override repack_override[2] = {{nullptr, nullptr}, {nullptr, nullptr}};
    // memmap diagnostic (engine "memmap": true)
    bool                   memmap = false;
    std::string            model_path;
    std::vector<MemTensor> mem_tensors;
    bool                   mem_reported = true;  // the answer's report is made once, by cl_finish
    // ple_advise: the page-aligned range of per_layer_token_embd inside the mapping (0 length: none), and the mode
    std::string            ple_mode;
    uint64_t               ple_addr = 0, ple_len = 0;
    std::string weights        = "default";
    std::string weights_reason;

    // The saved prompt prefix (cl_configure prefix_dir): the folder, the model file's identity, and the last cl_start's note.
    std::string prefix_dir;
    std::string model_id;
    std::string engine_key;  // "" with the default KV types and flash attention, else them: part of the saved prefix's identity
    std::string prefix_note;
    // The prompt start of the last request shape (system prompt + tools + thinking switch): its key and tokens, and how much
    // of it is stable (the part it shares with the shape before it; all of it once the same shape comes again).
    std::string              probe_key;
    std::vector<llama_token> probe_tokens;
    size_t                   stable = 0;
    bool                     stable_known = false;
};

void cl_logi(const char * fmt, ...);

// The model's own recommended sampling, embedded in the GGUF as general.sampling.* (the same keys and
// effect as llama.cpp's common_init_from_params, whose helper is private). Keys the GGUF lacks keep llama.cpp's
// defaults. Logs the effective settings once.
void load_model_sampling(const llama_model * model, common_params_sampling & sp) {
    auto val = [&](llama_model_meta_key k, std::string & out) {
        char buf[512] = {0};
        if (llama_model_meta_val_str(model, llama_model_meta_key_str(k), buf, sizeof(buf)) > 0) { out = buf; return true; }
        return false;
    };
    auto f = [&](llama_model_meta_key k, float & dst, bool & from_model) {
        std::string v;
        if (!val(k, v)) return;
        char * end = nullptr;
        float x = strtof(v.c_str(), &end);
        if (end && end != v.c_str()) { dst = x; from_model = true; }
    };
    auto i = [&](llama_model_meta_key k, int32_t & dst, bool & from_model) {
        std::string v;
        if (!val(k, v)) return;
        char * end = nullptr;
        long x = strtol(v.c_str(), &end, 10);
        if (end && end != v.c_str()) { dst = (int32_t) x; from_model = true; }
    };
    bool any = false;
    std::string seq;
    if (val(LLAMA_MODEL_META_KEY_SAMPLING_SEQUENCE, seq)) {
        std::vector<std::string> names;
        size_t a = 0;
        while (a <= seq.size()) {
            size_t b = seq.find(';', a);
            if (b == std::string::npos) b = seq.size();
            if (b > a) names.push_back(seq.substr(a, b - a));
            a = b + 1;
        }
        if (!names.empty()) { sp.samplers = common_sampler_types_from_names(names); any = true; }
    }
    i(LLAMA_MODEL_META_KEY_SAMPLING_TOP_K, sp.top_k, any);
    f(LLAMA_MODEL_META_KEY_SAMPLING_TOP_P, sp.top_p, any);
    f(LLAMA_MODEL_META_KEY_SAMPLING_MIN_P, sp.min_p, any);
    f(LLAMA_MODEL_META_KEY_SAMPLING_XTC_PROBABILITY, sp.xtc_probability, any);
    f(LLAMA_MODEL_META_KEY_SAMPLING_XTC_THRESHOLD, sp.xtc_threshold, any);
    f(LLAMA_MODEL_META_KEY_SAMPLING_TEMP, sp.temp, any);
    i(LLAMA_MODEL_META_KEY_SAMPLING_PENALTY_LAST_N, sp.penalty_last_n, any);
    f(LLAMA_MODEL_META_KEY_SAMPLING_PENALTY_REPEAT, sp.penalty_repeat, any);
    i(LLAMA_MODEL_META_KEY_SAMPLING_MIROSTAT, sp.mirostat, any);
    f(LLAMA_MODEL_META_KEY_SAMPLING_MIROSTAT_TAU, sp.mirostat_tau, any);
    f(LLAMA_MODEL_META_KEY_SAMPLING_MIROSTAT_ETA, sp.mirostat_eta, any);
    cl_logi("sampling (%s): temp=%.2f top_k=%d top_p=%.2f min_p=%.2f repeat_penalty=%.2f penalty_last_n=%d mirostat=%d",
            any ? "from the GGUF, llama.cpp defaults for the rest" : "llama.cpp defaults, the GGUF has none", sp.temp, sp.top_k,
            sp.top_p, sp.min_p, sp.penalty_repeat, sp.penalty_last_n, sp.mirostat);
}

struct EmbedHandle {
    llama_model *       model = nullptr;
    llama_context *     ctx   = nullptr;
    const llama_vocab * vocab = nullptr;
    int                 n_ctx  = 0;
    int                 n_embd = 0;
    bool                encoder = false;
};

const char * pooling_name(enum llama_pooling_type t) {
    switch (t) {
        case LLAMA_POOLING_TYPE_NONE: return "none";
        case LLAMA_POOLING_TYPE_MEAN: return "mean";
        case LLAMA_POOLING_TYPE_CLS:  return "cls";
        case LLAMA_POOLING_TYPE_LAST: return "last";
        case LLAMA_POOLING_TYPE_RANK: return "rank";
        default:                      return "unspecified";
    }
}

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
    fprintf(stderr, "[cl] %s\n", line);
#endif
}

// ---------------- options (cl_configure) ----------------
std::mutex  g_opt_mu;
std::string g_prefix_dir;
bool        g_repack_weights = false;  // Android, measurement only (cl_configure "repack_weights")

// Test-build tuning (cl_configure "engine"). Every field left unset means the behaviour the app always had.
struct EngineOpts {
    bool             set             = false;  // an engine object was given (the log line says "intent" instead of "default")
    int              n_threads       = 0;      // 0: as before (the caller's count or the automatic plan)
    int              n_threads_batch = 0;      // 0: the same as the generation threads
    std::vector<int> cpus;                     // empty: the automatic plan's cores
    std::string      flash_attn      = "auto";
    std::string      type_k          = "f16";
    std::string      type_v          = "f16";
    int              n_ubatch        = 0;      // 0: llama.cpp's default
    int              repack_weights  = -1;     // -1: the process-wide repack_weights option
    std::string      repack_tensors;           // "": none. A regex over tensor names (only the safe subset is repacked)
    bool             memmap          = false;  // log where the weights live and how much of them is resident
    std::string      ple_advise;               // "": nothing; "random" | "normal" | "dontneed_after": madvise on per_layer_token_embd
    int              use_mmap        = -1;     // -1: load_mode stays as llama_model_default_params sets it (AUTO); 1: MMAP; 0: NONE
};
EngineOpts g_engine;

std::string engine_build() {
#if defined(CACHE_GEMMA4_PREFILL_OPT)
    return "cache-gemma4-prefill-31356";
#else
    return "cache-llama-620d222";
#endif
}

// The repacked copy's size: the 2-D matrix weights (not the embedding tables, which are read by row) of the types the CPU
// backend can repack (ggml-cpu/repack.cpp), the ones whose row count suits the repacked layouts. An upper bound: a CPU may
// repack fewer types. -1 when the file cannot be read.
long long estimate_repack_bytes(const char * path) {
    ggml_context * meta = nullptr;
    gguf_init_params gp;
    gp.no_alloc = true;
    gp.ctx      = &meta;
    gguf_context * g = gguf_init_from_file(path, gp);
    if (!g) return -1;
    long long sum = 0;
    for (int64_t i = 0; i < gguf_get_n_tensors(g); i++) {
        const char * name = gguf_get_tensor_name(g, i);
        ggml_tensor * t = meta ? ggml_get_tensor(meta, name) : nullptr;
        if (!t || ggml_n_dims(t) != 2) continue;
        if (strstr(name, "token_embd") != nullptr) continue;  // token_embd, per_layer_token_embd: GET_ROWS, never repacked
        switch (t->type) {
            case GGML_TYPE_Q4_0: case GGML_TYPE_Q4_K: case GGML_TYPE_Q5_K: case GGML_TYPE_Q6_K: case GGML_TYPE_Q2_K:
            case GGML_TYPE_IQ4_NL: case GGML_TYPE_Q8_0: case GGML_TYPE_MXFP4:
                break;
            default:
                continue;
        }
        if (t->ne[1] % 4 != 0) continue;
        sum += (long long) ggml_nbytes(t);
    }
    gguf_free(g);
    if (meta) ggml_free(meta);
    return sum;
}

uint64_t fnv1a(uint64_t h, const void * data, size_t n) {
    const unsigned char * b = (const unsigned char *) data;
    for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ull; }
    return h;
}

// "name|size|mtime" of the model file: a different file (or the same name rewritten) gives a different saved prefix.
std::string file_identity(const char * path) {
    namespace fs = std::filesystem;
    std::error_code ec;
    fs::path p(path ? path : "");
    std::string id = p.filename().string();
    auto size = fs::file_size(p, ec);
    if (ec) return id;
    auto mtime = fs::last_write_time(p, ec);
    if (ec) return id + "|" + std::to_string((unsigned long long) size);
    return id + "|" + std::to_string((unsigned long long) size) + "|" + std::to_string((long long) mtime.time_since_epoch().count());
}

// ---------------- the saved prompt prefix ----------------
// The KV state of a prompt start, saved by llama_state_seq_save_file (its magic and version, the tokens, then seq 0's KV state)
// to a .part file and renamed, so a file under its final name is complete. The name is
// prefix-<model key>-<tokens hash>.kv: the model key (FNV-1a 64 of the model file's identity, the engine build and n_ctx) makes a
// file of another model, engine or context size invisible (it goes when the folder is pruned). A file is used for as many of
// its tokens as the prompt shares (the cache after that is dropped), so a file saved with a part that later changed still
// gives the part before it. At most kPrefixFiles stay (the least recently used go). A file that does not load is deleted.
constexpr size_t kPrefixFiles  = 2;
constexpr size_t kPrefixMinLen = 32;  // shorter prefixes are not worth a file

std::string hex64(uint64_t v) {
    char b[17];
    snprintf(b, sizeof(b), "%016llx", (unsigned long long) v);
    return b;
}

std::string prefix_model_key(const Handle * h) {
    // Non-default KV types or flash attention add to the identity (the default adds nothing, so today's files stay valid).
    const std::string head = h->model_id + "\n" + engine_build() + "\n" + std::to_string(h->n_ctx) + "\n" +
                             (h->engine_key.empty() ? std::string() : h->engine_key + "\n");
    return hex64(fnv1a(1469598103934665603ull, head.data(), head.size()));
}

std::string prefix_path(const Handle * h, const llama_token * toks, size_t n) {
    const std::string name = "prefix-" + prefix_model_key(h) + "-" + hex64(fnv1a(1469598103934665603ull, toks, n * sizeof(llama_token))) + ".kv";
    return (std::filesystem::path(h->prefix_dir) / name).string();
}

// This model's saved prefix files and their tokens (read from the file header). A file whose header does not read is deleted.
std::vector<std::pair<std::string, std::vector<llama_token>>> prefix_files(const Handle * h) {
    namespace fs = std::filesystem;
    std::vector<std::pair<std::string, std::vector<llama_token>>> out;
    const std::string start = "prefix-" + prefix_model_key(h) + "-";
    std::error_code ec;
    for (auto it = fs::directory_iterator(h->prefix_dir, ec); !ec && it != fs::directory_iterator(); it.increment(ec)) {
        const std::string name = it->path().filename().string();
        if (name.rfind(start, 0) != 0 || name.size() < 3 || name.compare(name.size() - 3, 3, ".kv") != 0) continue;
        std::vector<llama_token> toks;
        bool ok = false;
        if (FILE * f = fopen(it->path().string().c_str(), "rb")) {
            uint32_t hdr[3];
            if (fread(hdr, sizeof(uint32_t), 3, f) == 3 && hdr[0] == LLAMA_STATE_SEQ_MAGIC && hdr[1] == LLAMA_STATE_SEQ_VERSION && hdr[2] > 0 && hdr[2] < (1u << 20)) {
                toks.resize(hdr[2]);
                ok = fread(toks.data(), sizeof(llama_token), toks.size(), f) == toks.size();
            }
            fclose(f);
        }
        if (ok) {
            out.emplace_back(it->path().string(), std::move(toks));
        } else {
            std::error_code e2;
            fs::remove(it->path(), e2);
        }
    }
    return out;
}

size_t common_prefix(const std::vector<llama_token> & a, const std::vector<llama_token> & b, size_t limit) {
    size_t n = 0;
    limit = std::min({ limit, a.size(), b.size() });
    while (n < limit && a[n] == b[n]) n++;
    return n;
}

// Keeps the kPrefixFiles most recently used prefix files of the folder (and removes stale .part files).
void prune_prefix_files(const std::string & dir) {
    namespace fs = std::filesystem;
    std::error_code ec;
    std::vector<std::pair<fs::file_time_type, fs::path>> files;
    for (auto it = fs::directory_iterator(dir, ec); !ec && it != fs::directory_iterator(); it.increment(ec)) {
        const auto name = it->path().filename().string();
        if (name.rfind("prefix-", 0) != 0) continue;
        if (name.size() > 5 && name.compare(name.size() - 5, 5, ".part") == 0) {
            fs::remove(it->path(), ec);
            continue;
        }
        if (name.size() < 3 || name.compare(name.size() - 3, 3, ".kv") != 0) continue;
        std::error_code e2;
        files.emplace_back(fs::last_write_time(it->path(), e2), it->path());
    }
    if (files.size() <= kPrefixFiles) return;
    std::sort(files.begin(), files.end(), [](const auto & a, const auto & b) { return a.first > b.first; });
    for (size_t i = kPrefixFiles; i < files.size(); i++) fs::remove(files[i].second, ec);
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
#elif defined(CL_BACKEND_DL)
// The same off Android (only the CI test build of the CL_BACKEND_DL path): to stderr.
void backend_load_log(enum ggml_log_level level, const char * text, void *) {
    if (level >= GGML_LOG_LEVEL_INFO) {
        fputs(text, stderr);
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

// ---------------- engine test helpers: partial repack, the memory diagnostic, madvise on the per-layer table ----------------

// Long log lists go out in lines of at most ~900 bytes (logcat cuts a line near 4 KB).
void log_list(const std::string & head, const std::vector<std::string> & items) {
    std::string line;
    int part = 0;
    for (const auto & it : items) {
        if (!line.empty() && line.size() + it.size() > 900) { cl_logi("%s [%d]: %s", head.c_str(), ++part, line.c_str()); line.clear(); }
        line += (line.empty() ? "" : ",") + it;
    }
    if (!line.empty() || items.empty()) cl_logi("%s%s: %s", head.c_str(), part ? (" [" + std::to_string(part + 1) + "]").c_str() : "", line.empty() ? "(none)" : line.c_str());
}

// The names the CPU backend variant that is loaded reports ("NEON", "DOTPROD", "AVX2" ...), or none when it cannot say.
std::set<std::string> cpu_feature_names() {
    std::set<std::string> out;
    ggml_backend_dev_t dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    ggml_backend_reg_t reg = dev ? ggml_backend_dev_backend_reg(dev) : nullptr;
    auto * fn = reg ? (ggml_backend_get_features_t) ggml_backend_reg_get_proc_address(reg, "ggml_backend_get_features") : nullptr;
    if (fn) {
        for (auto * ft = fn(reg); ft && ft->name; ft++) {
            if (std::string(ft->value) != "0") out.insert(ft->name);
        }
    }
    return out;
}

// The CPU backend's repack buffer type (the one named "CPU_REPACK" among the CPU device's extra buffer types), or null.
ggml_backend_buffer_type_t find_repack_buft() {
    ggml_backend_dev_t dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    ggml_backend_reg_t reg = dev ? ggml_backend_dev_backend_reg(dev) : nullptr;
    auto * fn = reg ? (ggml_backend_dev_get_extra_bufts_t) ggml_backend_reg_get_proc_address(reg, "ggml_backend_dev_get_extra_bufts") : nullptr;
    if (!fn) return nullptr;
    for (ggml_backend_buffer_type_t * b = fn(dev); b && *b; b++) {
        if (strcmp(ggml_backend_buft_name(*b), "CPU_REPACK") == 0) return *b;
    }
    return nullptr;
}

// Whether the CPU backend's repack code (ggml-cpu/repack.cpp, ggml_repack_get_optimal_repack_type) has a layout for a 2-D tensor of
// this type with ne[1] a multiple of 8 on the CPU features reported. That code is private, so this mirrors it; where unsure it says no
// (a tensor sent to the repack buffer that has no layout crashes the load). ne[1] % 8 is stricter than its 4 and 8.
bool repack_has_layout(ggml_type t, const std::set<std::string> & f) {
    auto has = [&](const char * n) { return f.count(n) > 0; };
    const bool neon_mm = has("NEON") && (has("MATMUL_INT8") || has("DOTPROD"));
    switch (t) {
        case GGML_TYPE_Q4_0:   return has("AVX2") || neon_mm;
        case GGML_TYPE_Q4_K:   return has("AVX2") || neon_mm;
        case GGML_TYPE_Q5_K:   return neon_mm;
        case GGML_TYPE_Q6_K:   return neon_mm;
        case GGML_TYPE_Q8_0:   return neon_mm;
        case GGML_TYPE_Q2_K:   return has("AVX512");
        case GGML_TYPE_IQ4_NL: return has("AVX2") || (has("NEON") && has("DOTPROD"));
        case GGML_TYPE_MXFP4:  return has("AVX2") || (has("NEON") && has("DOTPROD"));
        default:               return false;
    }
}

std::string regex_escape(const std::string & s) {
    std::string o;
    for (char c : s) {
        if (!(isalnum((unsigned char) c) || c == '_')) o += '\\';
        o += c;
    }
    return o;
}

int tensor_group(const std::string & n) {
    auto at0 = [&](const char * p) { return n.rfind(p, 0) == 0; };
    if (at0("per_layer_token_embd")) return 0;
    if (at0("token_embd")) return 1;
    if (n.find("norm") != std::string::npos) return 3;
    // Gemma 4 per-layer inputs: per_layer_model_proj, blk.N.inp_gate, blk.N.proj (per_layer_proj_norm and blk.N.post_norm are norms)
    if (at0("per_layer_model_proj") || n.find(".inp_gate.") != std::string::npos || (at0("blk.") && n.find(".proj.") != std::string::npos)) return 2;
    if (n.find("attn_") != std::string::npos) return 4;
    if (n.find("ffn_") != std::string::npos) return 5;
    if (at0("output")) return 6;
    return 7;
}
constexpr const char * kMemGroups[] = {"per_layer_token_embd", "token_embd", "per_layer_proj", "norms", "attn", "ffn", "output", "other"};

// The model file's tensors (name, group, data offset, size). Empty when the file cannot be read.
std::vector<MemTensor> read_tensor_table(const char * path) {
    std::vector<MemTensor> out;
    gguf_init_params gp;
    gp.no_alloc = true;
    gp.ctx      = nullptr;
    gguf_context * g = gguf_init_from_file(path, gp);
    if (!g) return out;
    const uint64_t base = gguf_get_data_offset(g);
    for (int64_t i = 0; i < gguf_get_n_tensors(g); i++) {
        MemTensor t;
        t.name  = gguf_get_tensor_name(g, i);
        t.group = tensor_group(t.name);
        t.off   = base + gguf_get_tensor_offset(g, i);
        t.size  = gguf_get_tensor_size(g, i);
        out.push_back(std::move(t));
    }
    gguf_free(g);
    return out;
}

// repack_tensors: of the tensors the regex matches, the ones that are safe to send to the repack buffer: 2-D, a type with a layout on
// this CPU, ne[1] % 8 == 0, and not an embedding table (token_embd, per_layer_token_embd: GET_ROWS reads them by row, which repacked
// data breaks). Fills h->repack_pat/override and returns the chosen names; logs the counts, bytes and the matched-but-skipped names.
bool plan_repack_tensors(Handle * h, const char * path, const std::string & regex_text, std::set<std::string> & chosen) {
    ggml_backend_buffer_type_t buft = find_repack_buft();
    if (!buft) { cl_logi("repack_tensors ignored: the CPU backend has no CPU_REPACK buffer type"); return false; }
    const auto feats = cpu_feature_names();
    if (feats.empty()) { cl_logi("repack_tensors ignored: the CPU backend does not report its features"); return false; }
    gguf_init_params gp;
    gp.no_alloc = true;
    gp.ctx      = nullptr;
    gguf_context * g = gguf_init_from_file(path, gp);
    if (!g) { cl_logi("repack_tensors ignored: cannot read the model file's tensor list"); return false; }
    std::regex re(regex_text);
    std::vector<std::string> skipped;
    uint64_t bytes = 0;
    for (int64_t i = 0; i < gguf_get_n_tensors(g); i++) {
        const std::string name = gguf_get_tensor_name(g, i);
        if (!std::regex_search(name, re)) continue;
        const int64_t * ne = gguf_get_tensor_ne(g, i);
        const ggml_type ty = gguf_get_tensor_type(g, i);
        const char * why = nullptr;
        if (name.find("token_embd") != std::string::npos) why = "embedding table";
        else if (ne[2] != 1 || ne[3] != 1 || ne[1] <= 1) why = "not 2-D";
        else if (ne[1] % 8 != 0) why = "ne1 not a multiple of 8";
        else if (!repack_has_layout(ty, feats)) why = "type without a layout here";
        if (why) { skipped.push_back(name + "(" + why + ", " + ggml_type_name(ty) + ")"); continue; }
        chosen.insert(name);
        bytes += gguf_get_tensor_size(g, i);
    }
    gguf_free(g);
    cl_logi("repack_tensors: pattern %s matched %d safe tensors (%llu MB) and %d skipped", regex_text.c_str(), (int) chosen.size(),
            (unsigned long long) (bytes >> 20), (int) skipped.size());
    log_list("repack_tensors skipped", skipped);
    if (chosen.empty()) return false;
    std::string pat = "^(?:";
    bool first = true;
    for (const auto & n : chosen) { pat += (first ? "" : "|") + regex_escape(n); first = false; }
    pat += ")$";
    h->repack_pat         = pat;
    h->repack_override[0] = { h->repack_pat.c_str(), buft };
    return true;
}

#if !defined(_WIN32)
// A line of /proc/self/status ("VmRSS:  1234 kB") in bytes, or -1.
long long proc_status_bytes(const char * key) {
    FILE * f = fopen("/proc/self/status", "r");
    if (!f) return -1;
    char line[256];
    long long v = -1;
    const size_t kl = strlen(key);
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, key, kl) == 0) { long long kb = 0; if (sscanf(line + kl, " %lld", &kb) == 1) v = kb * 1024; break; }
    }
    fclose(f);
    return v;
}

struct Vma { uint64_t start, end, off; };

// Bytes of [addr, addr+len) whose pages are in memory (mincore).
uint64_t resident_bytes(uint64_t addr, uint64_t len, long ps) {
    const uint64_t lo = addr & ~(uint64_t) (ps - 1);
    const uint64_t hi = (addr + len + ps - 1) & ~(uint64_t) (ps - 1);
    std::vector<unsigned char> vec((hi - lo) / ps);
#if defined(__APPLE__)
    if (mincore((void *) lo, hi - lo, (char *) vec.data()) != 0) return 0;
#else
    if (mincore((void *) lo, hi - lo, vec.data()) != 0) return 0;
#endif
    uint64_t sum = 0;
    for (size_t i = 0; i < vec.size(); i++) {
        if (!(vec[i] & 1)) continue;
        const uint64_t ps0 = lo + i * (uint64_t) ps, pe0 = ps0 + ps;
        sum += std::min(pe0, addr + len) - std::max(ps0, addr);
    }
    return sum;
}

// The mappings of the model file in this process (llama.cpp's mmap of the weights), from /proc/self/maps.
std::vector<Vma> read_vmas(const std::string & model_path) {
    std::vector<Vma> vmas;
    std::error_code ec;
    const std::string real = std::filesystem::weakly_canonical(model_path, ec).string();
    if (FILE * f = fopen("/proc/self/maps", "r")) {
        char line[1024];
        while (fgets(line, sizeof(line), f)) {
            unsigned long long st, en, off;
            int n = 0;
            if (sscanf(line, "%llx-%llx %*4s %llx %*s %*s %n", &st, &en, &off, &n) < 3 || n <= 0) continue;
            std::string path = line + n;
            while (!path.empty() && (path.back() == '\n' || path.back() == ' ')) path.pop_back();
            if (path == model_path || (!real.empty() && path == real)) vmas.push_back({st, en, off});
        }
        fclose(f);
    }
    return vmas;
}

// Where a tensor's data is in memory when the weights are mapped (false when it is not inside a mapping of the model file).
bool tensor_in_mapping(const std::vector<Vma> & vmas, const MemTensor & t, uint64_t & addr) {
    for (const auto & v : vmas) {
        if (t.off >= v.off && t.off + t.size <= v.off + (v.end - v.start)) { addr = v.start + (t.off - v.off); return true; }
    }
    return false;
}

const MemTensor * find_mem_tensor(const std::vector<MemTensor> & ts, const char * prefix) {
    for (const auto & t : ts) { if (t.name.rfind(prefix, 0) == 0) return &t; }
    return nullptr;
}

// ple_advise: madvise on the per-layer embedding table's pages (page-aligned inside the tensor, so no neighbouring tensor is touched).
// "random" and "dontneed_after" apply MADV_RANDOM now, "normal" MADV_NORMAL; "dontneed_after" also drops the pages after each answer.
// Logs the range sizes (the plain token_embd's too, for comparison), the result, and the table's resident bytes before and after.
void ple_setup(Handle * h, const std::vector<MemTensor> & ts) {
    const long ps = sysconf(_SC_PAGESIZE);
    const auto vmas = read_vmas(h->model_path);
    const MemTensor * ple = find_mem_tensor(ts, "per_layer_token_embd");
    const MemTensor * tok = find_mem_tensor(ts, "token_embd");
    uint64_t addr = 0;
    if (tok && tensor_in_mapping(vmas, *tok, addr)) cl_logi("ple_advise: token_embd range %llu MB in the mapping (not advised)", (unsigned long long) (tok->size >> 20));
    if (!ple) { cl_logi("ple_advise: no per_layer_token_embd tensor in this model: nothing done"); return; }
    if (ple->repacked || !tensor_in_mapping(vmas, *ple, addr)) {
        cl_logi("ple_advise: per_layer_token_embd is not in an mmapped buffer (%s): nothing done", vmas.empty() ? "the weights are not mapped" : "not in the mapping");
        return;
    }
    const uint64_t lo = (addr + ps - 1) & ~(uint64_t) (ps - 1);
    const uint64_t hi = (addr + ple->size) & ~(uint64_t) (ps - 1);
    if (hi <= lo) { cl_logi("ple_advise: the table's page range is empty: nothing done"); return; }
    const uint64_t before = resident_bytes(lo, hi - lo, ps);
    const bool normal = h->ple_mode == "normal";
    const int rc  = madvise((void *) lo, hi - lo, normal ? MADV_NORMAL : MADV_RANDOM);
    const int err = rc != 0 ? errno : 0;
    const uint64_t after = resident_bytes(lo, hi - lo, ps);
    cl_logi("ple_advise: per_layer_token_embd range %llu MB, mode=%s -> madvise(%s) result=%d%s; resident before=%llu MB after=%llu MB",
            (unsigned long long) ((hi - lo) >> 20), h->ple_mode.c_str(), normal ? "MADV_NORMAL" : "MADV_RANDOM", rc,
            rc != 0 ? (" errno " + std::to_string(err)).c_str() : "", (unsigned long long) (before >> 20), (unsigned long long) (after >> 20));
    if (rc == 0) { h->ple_addr = lo; h->ple_len = hi - lo; }
}

// dontneed_after: drop the table's (clean, file-backed) pages at the end of an answer. Logged with the resident bytes around it.
void ple_drop(Handle * h) {
    if (h->ple_mode != "dontneed_after" || h->ple_len == 0) return;
    const long ps = sysconf(_SC_PAGESIZE);
    const uint64_t before = resident_bytes(h->ple_addr, h->ple_len, ps);
    const int rc = madvise((void *) h->ple_addr, h->ple_len, MADV_DONTNEED);
    const uint64_t after = resident_bytes(h->ple_addr, h->ple_len, ps);
    cl_logi("ple_advise: answer done, madvise(MADV_DONTNEED) result=%d on %llu MB; per_layer_token_embd resident before=%llu MB after=%llu MB",
            rc, (unsigned long long) (h->ple_len >> 20), (unsigned long long) (before >> 20), (unsigned long long) (after >> 20));
}
#endif

// The memmap diagnostic: per tensor group, the bytes in the file and the bytes resident now. Tensors in the mapping of the model file
// are counted with mincore on their pages; tensors the loader put in other buffers (CPU_REPACK from repack_tensors, or anonymous
// memory when the weights were not mapped) count as resident in full. The loader's own buffer lines ("model buffer size", "KV buffer
// size", "compute buffer size") are forwarded to the same log (forward_log), so they appear beside these.
void memmap_report(Handle * h, const char * stage) {
#if !defined(_WIN32)
    if (!h->memmap || h->mem_tensors.empty()) return;
    const long ps = sysconf(_SC_PAGESIZE);
    const std::vector<Vma> vmas = read_vmas(h->model_path);
    struct Acc { int n = 0; uint64_t file = 0, res = 0; std::set<std::string> bufs; };
    Acc acc[8];
    uint64_t t_file = 0, t_res = 0;
    for (const auto & t : h->mem_tensors) {
        Acc & a = acc[t.group];
        a.n++;
        a.file += t.size;
        uint64_t res = 0;
        if (t.repacked) {
            res = t.size;
            a.bufs.insert("CPU_REPACK");
        } else if (vmas.empty()) {
            res = t.size;
            a.bufs.insert("CPU(anon)");
        } else {
            a.bufs.insert("mmap");
            for (const auto & v : vmas) {
                const uint64_t vlen = v.end - v.start;
                const uint64_t lo = std::max<uint64_t>(t.off, v.off), hi = std::min<uint64_t>(t.off + t.size, v.off + vlen);
                if (hi > lo) res += resident_bytes(v.start + (lo - v.off), hi - lo, ps);
            }
        }
        a.res += res;
        t_file += t.size;
        t_res += res;
    }
    for (int g = 0; g < 8; g++) {
        if (acc[g].n == 0) continue;
        std::string bufs;
        for (const auto & b : acc[g].bufs) bufs += (bufs.empty() ? "" : "+") + b;
        cl_logi("memmap: %s %s tensors=%d file=%llu MB resident=%llu MB (%d%%) buffer=%s", stage, kMemGroups[g], acc[g].n,
                (unsigned long long) (acc[g].file >> 20), (unsigned long long) (acc[g].res >> 20),
                acc[g].file ? (int) (acc[g].res * 100 / acc[g].file) : 0, bufs.c_str());
    }
    cl_logi("memmap: %s total tensors=%d file=%llu MB resident=%llu MB mapped_regions=%d process rss=%lld MB (anon %lld, file %lld) swap=%lld MB",
            stage, (int) h->mem_tensors.size(), (unsigned long long) (t_file >> 20), (unsigned long long) (t_res >> 20), (int) vmas.size(),
            proc_status_bytes("VmRSS:") >> 20, proc_status_bytes("RssAnon:") >> 20, proc_status_bytes("RssFile:") >> 20,
            proc_status_bytes("VmSwap:") >> 20);
#else
    (void) h; (void) stage;
#endif
}

// With the memmap diagnostic on, llama.cpp's own INFO lines about buffers, the load mode and mmap go to the log too (a handful per
// load); everything else at INFO stays quiet. Warnings and errors always show, as with quiet_log.
void forward_log(enum ggml_log_level level, const char * text, void *) {
    if (level >= GGML_LOG_LEVEL_WARN) { fputs(text, stderr); return; }
    if (level != GGML_LOG_LEVEL_INFO) return;
    if (strstr(text, "buffer size") || strstr(text, "load_mode") || strstr(text, "mmap") || strstr(text, "KV self size") ||
        strstr(text, "model size")) {
        std::string s = text;
        while (!s.empty() && (s.back() == '\n' || s.back() == ' ')) s.pop_back();
        const size_t b = s.find_first_not_of(' ');
        cl_logi("llama: %s", b == std::string::npos ? "" : s.c_str() + b);
    }
}

}  // namespace

// Every chat handle not freed yet, for cl_free_all: the process outlives the app's Dart side when Android destroys the
// window and makes a new one (a new Flutter engine in the same process). The old engine's handle is never freed by it,
// and its model would stay in memory beside the one the new engine loads.
static std::mutex          g_live_mu;
static std::set<Handle *>  g_live;

static void free_handle(Handle * h) {
    h->smpl.reset();
    h->session.reset();
    h->tmpls.reset();
    if (h->ctx)   llama_free(h->ctx);
    if (h->pool_batch) h->pool_free(h->pool_batch);
    if (h->pool)  h->pool_free(h->pool);
    if (h->model) llama_model_free(h->model);
    delete h;
}

extern "C" {

// Reads the "engine" object. A key with a value that cannot be used is ignored (and logged); the others still apply.
static EngineOpts parse_engine(const common_json & e) {
    EngineOpts o;
    o.set = true;
    auto bad = [](const char * key) { cl_logi("engine option ignored (bad value): %s", key); };
    auto pos_int = [&](const char * key, int max, int & dst) {
        if (!e.contains(key)) return;
        const auto & v = e.at(key);
        if (v.is_number_integer() && v.get<long long>() >= 1 && v.get<long long>() <= max) dst = (int) v.get<long long>();
        else bad(key);
    };
    pos_int("n_threads", GGML_MAX_N_THREADS, o.n_threads);
    pos_int("n_threads_batch", GGML_MAX_N_THREADS, o.n_threads_batch);
    pos_int("n_ubatch", 65536, o.n_ubatch);
    if (e.contains("cpus")) {
        const auto & v = e.at("cpus");
        std::vector<int> cpus;
        bool ok = v.is_array() && !v.empty();
        if (ok) {
            for (const auto & c : v) {
                if (c.is_number_integer() && c.get<long long>() >= 0 && c.get<long long>() < GGML_MAX_N_THREADS) cpus.push_back((int) c.get<long long>());
                else { ok = false; break; }
            }
        }
        if (ok) o.cpus = cpus; else bad("cpus");
    }
    auto choice = [&](const char * key, std::initializer_list<const char *> allowed, std::string & dst) {
        if (!e.contains(key)) return;
        const auto & v = e.at(key);
        if (v.is_string()) {
            for (const char * a : allowed) {
                if (v.get<std::string>() == a) { dst = a; return; }
            }
        }
        bad(key);
    };
    choice("flash_attn", {"auto", "on", "off"}, o.flash_attn);
    choice("type_k", {"f16", "q8_0", "q4_0"}, o.type_k);
    choice("type_v", {"f16", "q8_0", "q4_0"}, o.type_v);
    if (e.contains("repack_weights")) {
        if (e.at("repack_weights").is_boolean()) o.repack_weights = e.at("repack_weights").get<bool>() ? 1 : 0;
        else bad("repack_weights");
    }
    if (e.contains("repack_tensors")) {
        const auto & v = e.at("repack_tensors");
        bool ok = v.is_string() && !v.get<std::string>().empty();
        if (ok) {
            try { std::regex re(v.get<std::string>()); } catch (const std::exception &) { ok = false; }
        }
        if (ok) o.repack_tensors = v.get<std::string>(); else bad("repack_tensors");
    }
    if (e.contains("memmap")) {
        if (e.at("memmap").is_boolean()) o.memmap = e.at("memmap").get<bool>();
        else bad("memmap");
    }
    choice("ple_advise", {"random", "normal", "dontneed_after"}, o.ple_advise);
    if (e.contains("use_mmap")) {
        if (e.at("use_mmap").is_boolean()) o.use_mmap = e.at("use_mmap").get<bool>() ? 1 : 0;
        else bad("use_mmap");
    }
    return o;
}

static ggml_type kv_type(const std::string & n) { return n == "q8_0" ? GGML_TYPE_Q8_0 : n == "q4_0" ? GGML_TYPE_Q4_0 : GGML_TYPE_F16; }

int cl_configure(const char * options_json) {
    try {
        auto j = common_json::parse(options_json ? options_json : "{}");
        std::lock_guard<std::mutex> lock(g_opt_mu);
        // "engine" (test builds only, see cache_llama.h): an object replaces the whole engine setting, null clears it; left out keeps it.
        if (j.contains("engine")) {
            if (j.at("engine").is_object()) g_engine = parse_engine(j.at("engine"));
            else if (j.at("engine").is_null()) g_engine = EngineOpts();
            else cl_logi("engine option ignored (not an object)");
        }
        if (j.contains("prefix_dir") && j.at("prefix_dir").is_string()) g_prefix_dir = j.at("prefix_dir").get<std::string>();
        if (j.contains("repack_weights") && j.at("repack_weights").is_boolean()) g_repack_weights = j.at("repack_weights").get<bool>();
        return 0;
    } catch (const std::exception &) {
        return -1;
    }
}

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
        bool repack_opt_in = false;
        EngineOpts eng;
        std::set<std::string> repack_chosen;
        {
            std::lock_guard<std::mutex> lock(g_opt_mu);
            repack_opt_in = g_repack_weights;
            h->prefix_dir = g_prefix_dir;
            eng           = g_engine;
        }
        if (eng.repack_weights >= 0) repack_opt_in = eng.repack_weights == 1;
        // llama.cpp's own buffer lines go to the log only with the memmap diagnostic (test APK).
        llama_log_set(eng.memmap ? forward_log : quiet_log, nullptr);
        // repack_tensors: only the safe subset of the matching tensors goes to the repack buffer; it wins over repack_weights.
        bool partial = false;
        if (!eng.repack_tensors.empty()) {
            if (repack_opt_in) cl_logi("repack_tensors wins over repack_weights: only the matching tensors are repacked");
            repack_opt_in = false;
            partial = plan_repack_tensors(h.get(), model_path, eng.repack_tensors, repack_chosen);
        }
        // The effective thread counts: the engine's, else the caller's or the automatic plan's (batch follows generation).
        const int n_gen   = eng.n_threads > 0 ? eng.n_threads : n_threads;
        const int n_batch_threads = eng.n_threads_batch > 0 ? eng.n_threads_batch : n_gen;
        const std::vector<int> & pin = !eng.cpus.empty() ? eng.cpus : plan.cpus;
        {
            std::string kk = eng.type_k + "/" + eng.type_v;
            if (eng.type_k != "f16" || eng.type_v != "f16" || eng.flash_attn != "auto") h->engine_key = kk + " fa=" + eng.flash_attn;
        }
        (void) repack_opt_in;
#if defined(__ANDROID__)
        // Android always keeps the CPU weights in the file-backed mmap (use_extra_bufts=false). Repacking makes an anonymous copy
        // of the matrix weights that Android swaps out when memory is short, and every later prompt then waits on swap. On a
        // Galaxy S22 (build 46, repack off) the mmap load took 6.2 s against 9-16 s, swap fell from 1.7-1.9 GB to 0.3 GB, and
        // prompt reading stayed at about 42 tok/s (30-50 repacked): the copy cost about a GB and gave no speed. Repacking stays
        // available for measurement only (cl_configure "repack_weights"); it is never chosen automatically.
        if (repack_opt_in) {
            const long long est = estimate_repack_bytes(model_path);
            mp.use_extra_bufts = true;
            h->weights         = "repacked";
            h->weights_reason  = std::string("opt-in for measurement, repacked copy ") +
                                (est >= 0 ? "about " + std::to_string(est >> 20) + " MB" : "size not known");
        } else {
            mp.use_extra_bufts = false;
            h->weights         = "mmap";
            h->weights_reason  = "default on Android";
        }
        cl_logi("weights: %s (%s)", h->weights.c_str(), h->weights_reason.c_str());
#endif
        if (partial) {
            // only the chosen tensors go to the CPU_REPACK buffer, through the override list; everything else stays as loaded
            mp.use_extra_bufts       = false;
            mp.tensor_buft_overrides = h->repack_override;
            h->weights        = "partly repacked (" + eng.repack_tensors + ")";
            h->weights_reason = "repack_tensors: " + std::to_string(repack_chosen.size()) + " tensors";
        }
        if (eng.use_mmap >= 0) {
            mp.load_mode = eng.use_mmap == 1 ? LLAMA_LOAD_MODE_MMAP : LLAMA_LOAD_MODE_NONE;
            // the label says what happened, e.g. "repacked, load_mode none"
            h->weights += std::string(", load_mode ") + (eng.use_mmap == 1 ? "mmap" : "none");
        }
        h->model_path = model_path;
        h->model_id = file_identity(model_path);
        h->model = llama_model_load_from_file(model_path, mp);
        if (!h->model) {
            set_err(err, err_len, std::string("cannot load model: ") + model_path);
            return nullptr;
        }
        h->vocab = llama_model_get_vocab(h->model);
        load_model_sampling(h->model, h->sampling);

        llama_context_params cp = llama_context_default_params();
        cp.n_ctx           = (uint32_t) n_ctx;
        cp.n_batch         = 512;
        cp.n_threads       = n_gen;
        cp.n_threads_batch = n_batch_threads;
        cp.flash_attn_type = eng.flash_attn == "on" ? LLAMA_FLASH_ATTN_TYPE_ENABLED : eng.flash_attn == "off" ? LLAMA_FLASH_ATTN_TYPE_DISABLED : LLAMA_FLASH_ATTN_TYPE_AUTO;
        cp.type_k          = kv_type(eng.type_k);
        cp.type_v          = kv_type(eng.type_v);
        if (eng.n_ubatch > 0) cp.n_ubatch = (uint32_t) eng.n_ubatch;
        h->ctx = llama_init_from_model(h->model, cp);
        if (!h->ctx) {
            set_err(err, err_len, "cannot create context (out of memory?)");
            llama_model_free(h->model);
            return nullptr;
        }
        h->n_ctx = (int) llama_n_ctx(h->ctx);

        if (!pin.empty()) {
            // A threadpool whose threads are each pinned to one of the chosen cores.
            ggml_backend_dev_t dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
            ggml_backend_reg_t reg = dev ? ggml_backend_dev_backend_reg(dev) : nullptr;
            auto * pool_new  = reg ? (decltype(ggml_threadpool_new) *) ggml_backend_reg_get_proc_address(reg, "ggml_threadpool_new") : nullptr;
            auto * pool_free = reg ? (decltype(ggml_threadpool_free) *) ggml_backend_reg_get_proc_address(reg, "ggml_threadpool_free") : nullptr;
            if (pool_new && pool_free) {
                ggml_threadpool_params tpp = ggml_threadpool_params_default(n_gen);
                for (int c : pin) tpp.cpumask[c] = true;
                tpp.strict_cpu = true;
                h->pool = pool_new(&tpp);
                if (h->pool) {
                    h->pool_free = pool_free;
                    if (n_batch_threads != n_gen) {
                        // prompt reading uses its own pinned pool when its thread count differs
                        ggml_threadpool_params tpb = ggml_threadpool_params_default(n_batch_threads);
                        for (int c : pin) tpb.cpumask[c] = true;
                        tpb.strict_cpu = true;
                        h->pool_batch = pool_new(&tpb);
                        if (!h->pool_batch) cl_logi("cannot create the pinned batch threadpool: prompt reading uses the generation pool");
                    }
                    llama_attach_threadpool(h->ctx, h->pool, h->pool_batch);
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
            if (h->pool_batch) h->pool_free(h->pool_batch);
            if (h->pool) h->pool_free(h->pool);
            llama_model_free(h->model);
            return nullptr;
        }
        {
            std::string cpu_list;
            for (int c : pin) cpu_list += (cpu_list.empty() ? "" : ",") + std::to_string(c);
            char line[384];
            snprintf(line, sizeof(line), "engine: threads gen=%d batch=%d cpus=%s flash_attn=%s kv=%s/%s n_batch=%u n_ubatch=%u load_mode=%s repack_tensors=%s weights=%s (source: %s)",
                     n_gen, n_batch_threads, cpu_list.empty() ? "none" : cpu_list.c_str(), eng.flash_attn.c_str(), eng.type_k.c_str(),
                     eng.type_v.c_str(), (unsigned) cp.n_batch, (unsigned) llama_n_ubatch(h->ctx),
                     eng.use_mmap < 0 ? "default:auto" : eng.use_mmap == 1 ? "mmap" : "none",
                     partial ? eng.repack_tensors.c_str() : "none", h->weights.c_str(),
                     eng.set ? "intent" : "default");
            h->engine_line = line;
            cl_logi("%s", line);
            if (eng.memmap || !eng.ple_advise.empty()) {
                h->mem_tensors = read_tensor_table(model_path);
                for (auto & t : h->mem_tensors) t.repacked = repack_chosen.count(t.name) > 0;
            }
            if (eng.memmap) {
                h->memmap = true;
                memmap_report(h.get(), "load");
            }
#if !defined(_WIN32)
            if (!eng.ple_advise.empty()) {
                h->ple_mode = eng.ple_advise;
                ple_setup(h.get(), h->mem_tensors);
                if (h->memmap) memmap_report(h.get(), "after-advise");
            }
#endif
        }
        Handle * out = h.release();
        {
            std::lock_guard<std::mutex> lock(g_live_mu);
            g_live.insert(out);
        }
        return out;
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
        j["engine_build"]   = engine_build();
        j["weights"]        = h->weights;
        j["weights_reason"] = h->weights_reason;
        j["engine"]         = h->engine_line;
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
        h->stop_tokens.clear();
        h->prefix_note.clear();

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
        // Optional "tool_choice": "none" keeps the tools in the prompt (the same prompt start as the rounds before) but turns the
        // tool-call grammar off; the tool-call opening tokens then end the generation (below).
        if (req.contains("tool_choice") && req.at("tool_choice").is_string()) {
            in.tool_choice = common_chat_tool_choice_parse_oaicompat(req.at("tool_choice").get<std::string>());
        }
        if (in.tool_choice == COMMON_CHAT_TOOL_CHOICE_NONE && !in.tools.empty()) {
            for (const char * open : { "<|tool_call>", "<tool_call>" }) {
                auto t = common_tokenize(h->vocab, open, /*add_special*/ false, /*parse_special*/ true);
                if (t.size() == 1 && (llama_vocab_get_attr(h->vocab, t[0]) & (LLAMA_TOKEN_ATTR_CONTROL | LLAMA_TOKEN_ATTR_USER_DEFINED))) {
                    h->stop_tokens.push_back(t[0]);
                }
            }
        }

        // The session wraps common_chat_templates_apply and keeps the parser for cl_finish.
        h->session = std::make_unique<common_chat_session>(h->tmpls.get(), h->vocab, in);

        common_params_sampling sp = h->sampling;  // the GGUF's recommended sampling (load_model_sampling)
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

        auto tokens = common_tokenize(h->vocab, h->session->prompt().str(), /*add_special*/ true, /*parse_special*/ true);
        // add_special follows the vocab's own add_bos/add_eos settings, so a model that wants BOS gets it first
        // on every turn (the template's text leaves it out); the token prefix reuse below still matches.
        h->first_token = tokens.empty() ? -1 : (int) tokens[0];
        h->n_prompt = (int) tokens.size();
        if (h->n_prompt == 0 || h->n_prompt >= h->n_ctx) {
            set_err(err, err_len, "prompt does not fit the context (" + std::to_string(h->n_prompt) + " tokens)");
            return -1;
        }

        // The stable prompt start. The prompt start of this request shape is the system prompt and the tool schemas the template
        // renders after it, up to where the first user message begins: found by rendering the request's system message and tools
        // with two different one-word questions (the tokens both share), once per shape. Its stable part is what it shares with
        // the shape before it (a clock in the system prompt makes that the text before the clock), or all of it once the same
        // shape comes again. Only with a prefix folder, tools and a system message.
        size_t want = 0;  // the stable start of this prompt, in tokens
        if (!h->prefix_dir.empty() && !in.tools.empty() && !in.messages.empty() && in.messages[0].role == "system") {
            const std::string key = in.messages[0].content + '\x1f' + req.at("tools").dump() + '\x1f' + (in.enable_thinking ? "1" : "0");
            if (key != h->probe_key) {
                common_chat_templates_inputs pa = in;
                pa.tool_choice = COMMON_CHAT_TOOL_CHOICE_AUTO;
                common_chat_msg u;
                u.role    = "user";
                u.content = "a";
                pa.messages = { in.messages[0], u };
                auto ta = common_tokenize(h->vocab, common_chat_templates_apply(h->tmpls.get(), pa).prompt.str(), true, true);
                pa.messages[1].content = "b";
                auto tb = common_tokenize(h->vocab, common_chat_templates_apply(h->tmpls.get(), pa).prompt.str(), true, true);
                ta.resize(common_prefix(ta, tb, ta.size()));
                if (!h->probe_tokens.empty()) {
                    h->stable       = common_prefix(h->probe_tokens, ta, ta.size());
                    h->stable_known = true;
                } else {
                    h->stable_known = false;  // the first shape since the load: see the saved files below
                }
                h->probe_key    = key;
                h->probe_tokens = std::move(ta);
            } else {
                h->stable       = h->probe_tokens.size();
                h->stable_known = true;
            }
            // The request's own tokens must agree (a merge across the boundary could differ), and the last prompt token is
            // always decoded.
            want = common_prefix(h->probe_tokens, tokens, tokens.size() - 1);
            if (h->stable_known) want = std::min(want, h->stable);
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

        // The cache does not hold the stable start (the first question after a load, or a different start before): take what a
        // saved file shares with this prompt.
        using sclock = std::chrono::steady_clock;
        auto ms_since = [](sclock::time_point t0) { return (long long) std::chrono::duration_cast<std::chrono::milliseconds>(sclock::now() - t0).count(); };
        std::error_code fec;
        bool covered = true;  // a saved file already holds the stable start
        if (want >= kPrefixMinLen && keep < want) {
            auto files = prefix_files(h);
            size_t best = 0, best_file_len = 0;
            std::string best_path;
            for (auto & f : files) {
                const size_t l = common_prefix(f.second, tokens, tokens.size() - 1);
                if (l > best) { best = l; best_path = f.first; best_file_len = f.second.size(); }
            }
            if (!h->stable_known) {
                // The first shape since the load: a saved file of this model tells how much of it stayed the same before. With
                // none, all of it is taken as stable (and saved once).
                if (!best_path.empty()) want = std::min(want, best);
                h->stable       = want;
                h->stable_known = true;
            }
            covered = best >= want;
            if (best > keep && best >= kPrefixMinLen) {
                const auto t0 = sclock::now();
                llama_memory_clear(mem, true);
                h->cached.clear();
                keep = 0;
                std::vector<llama_token> got(best_file_len);
                size_t n_got = 0;
                const size_t rd = llama_state_seq_load_file(h->ctx, best_path.c_str(), 0, got.data(), got.size(), &n_got);
                const bool loaded = rd > 0 && n_got == best_file_len && std::equal(got.begin(), got.begin() + (long) best, tokens.begin());
                if (loaded && (n_got == best || llama_memory_seq_rm(mem, 0, (llama_pos) best, -1))) {
                    h->cached.assign(tokens.begin(), tokens.begin() + (long) best);
                    keep = best;
                    std::filesystem::last_write_time(best_path, std::filesystem::file_time_type::clock::now(), fec);
                    h->prefix_note = "Prompt prefix restored (" + std::to_string(best) + " tokens, " + std::to_string(ms_since(t0)) + " ms)";
                } else {
                    llama_memory_clear(mem, true);
                    if (!loaded) std::filesystem::remove(best_path, fec);
                    covered = false;
                    h->prefix_note = loaded ? "Prompt prefix file could not be trimmed; the prompt is read as usual"
                                            : "Prompt prefix file did not load and was removed; the prompt is read as usual";
                }
                cl_logi("%s", h->prefix_note.c_str());
            }
        }
        h->n_reused = (int) keep;
        // Saved when no file holds the stable start yet and this start decodes it itself.
        const size_t prefix = want;
        const bool   save   = want >= kPrefixMinLen && keep < want && !covered;
        const std::string prefix_file = save ? prefix_path(h, tokens.data(), prefix) : std::string();

        const int n_batch = 512;
        for (int i = (int) keep; i < h->n_prompt;) {
            int n = std::min(n_batch, h->n_prompt - i);
            if (save && i < (int) prefix && i + n > (int) prefix) n = (int) prefix - i;  // a batch ends exactly at the prefix
            if (llama_decode(h->ctx, llama_batch_get_one(tokens.data() + i, n)) != 0) {
                llama_memory_clear(mem, true);
                h->cached.clear();
                h->n_reused = 0;
                set_err(err, err_len, "decode failed while reading the prompt");
                return -1;
            }
            h->cached.insert(h->cached.end(), tokens.begin() + i, tokens.begin() + i + n);
            i += n;
            if (save && (size_t) i == prefix) {
                const auto t0 = sclock::now();
                std::filesystem::create_directories(h->prefix_dir, fec);
                const std::string part = prefix_file + ".part";
                const size_t wr = llama_state_seq_save_file(h->ctx, part.c_str(), 0, tokens.data(), prefix);
                std::error_code rec;
                if (wr > 0) std::filesystem::rename(part, prefix_file, rec);
                if (wr > 0 && !rec) {
                    prune_prefix_files(h->prefix_dir);
                    h->prefix_note += (h->prefix_note.empty() ? "" : "; ") + std::string("Prompt prefix saved (") + std::to_string(prefix) +
                                      " tokens, " + std::to_string(ms_since(t0)) + " ms)";
                } else {
                    std::filesystem::remove(part, fec);
                    h->prefix_note += (h->prefix_note.empty() ? "" : "; ") + std::string("Prompt prefix could not be saved");
                }
                cl_logi("%s", h->prefix_note.c_str());
            }
        }
        h->n_past   = h->n_prompt;
        h->finished = false;
        h->mem_reported = false;
        memmap_report(h, "prompt");
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
        // tool_choice "none": a tool-call opening ends the answer (the text before it is the answer).
        if (llama_vocab_is_eog(h->vocab, tok) ||
            std::find(h->stop_tokens.begin(), h->stop_tokens.end(), tok) != h->stop_tokens.end()) {
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
    if (!h->mem_reported) {
        // end of an answer (once): the memory report, then the per-layer table's pages are dropped when ple_advise says so
        h->mem_reported = true;
        try {
            memmap_report(h, "answer");
#if !defined(_WIN32)
            ple_drop(h);
#endif
            if (h->memmap && h->ple_len > 0 && h->ple_mode == "dontneed_after") memmap_report(h, "after-drop");
        } catch (const std::exception &) {}
    }
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
int cl_prefix_note(void * hp, char * out, int len) { return put(((Handle *) hp)->prefix_note, out, len); }
int cl_generated_tokens(void * hp) { return ((Handle *) hp)->n_generated; }
int cl_reused_tokens(void * hp)    { return ((Handle *) hp)->n_reused; }
int cl_first_prompt_token(void * hp) { return ((Handle *) hp)->first_token; }
int cl_bos_token(void * hp) {
    auto * h = (Handle *) hp;
    return llama_vocab_get_add_bos(h->vocab) ? (int) llama_vocab_bos(h->vocab) : -1;
}

void cl_stop(void * hp) { ((Handle *) hp)->stop.store(true); }

void cl_free(void * hp) {
    auto * h = (Handle *) hp;
    if (!h) return;
    {
        std::lock_guard<std::mutex> lock(g_live_mu);
        // already freed (by cl_free_all): nothing to do
        if (g_live.erase(h) == 0) return;
    }
    free_handle(h);
}

int cl_free_all(void) {
    std::set<Handle *> all;
    {
        std::lock_guard<std::mutex> lock(g_live_mu);
        all.swap(g_live);
    }
    for (Handle * h : all) free_handle(h);
    return (int) all.size();
}

// ---------------- embeddings ----------------

static llama_context * embed_context(llama_model * model, int n_ctx, int n_threads, enum llama_pooling_type pooling) {
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx           = (uint32_t) n_ctx;
    cp.n_batch         = (uint32_t) n_ctx;  // the whole text must fit one (non-causal) batch
    cp.n_ubatch        = (uint32_t) n_ctx;
    cp.n_seq_max       = 1;
    cp.n_threads       = n_threads;
    cp.n_threads_batch = n_threads;
    cp.embeddings      = true;
    cp.pooling_type    = pooling;  // UNSPECIFIED = take it from the model
    return llama_init_from_model(model, cp);
}

void * cl_embed_load(const char * model_path, int n_ctx, int n_threads, char * err, int err_len) {
    try {
        if (n_ctx <= 0)     n_ctx = 512;
        if (n_threads <= 0) n_threads = 4;
        llama_log_set(quiet_log, nullptr);
#if defined(CL_BACKEND_DL)
        // The CPU backend is loaded here too, not only in cl_load: an embedder is often the first model in its process
        // (the app's query embedder before any chat, Add PDF's own embedder in the core), and with no backend registered
        // llama_model_load_from_file fails.
        if (std::string why = load_cpu_backend(); !why.empty()) {
            set_err(err, err_len, why);
            return nullptr;
        }
#endif
        llama_backend_init();

        auto h = std::make_unique<EmbedHandle>();
        h->model = llama_model_load_from_file(model_path, llama_model_default_params());
        if (!h->model) {
            set_err(err, err_len, std::string("cannot load model: ") + model_path);
            return nullptr;
        }
        h->vocab = llama_model_get_vocab(h->model);
        int n_train = llama_model_n_ctx_train(h->model);
        if (n_train > 0 && n_ctx > n_train) {
            n_ctx = n_train;
        }

        h->ctx = embed_context(h->model, n_ctx, n_threads, LLAMA_POOLING_TYPE_UNSPECIFIED);
        if (h->ctx && llama_pooling_type(h->ctx) == LLAMA_POOLING_TYPE_NONE) {
            // the model declares no pooling: use mean pooling
            llama_free(h->ctx);
            h->ctx = embed_context(h->model, n_ctx, n_threads, LLAMA_POOLING_TYPE_MEAN);
        }
        if (!h->ctx) {
            set_err(err, err_len, "cannot create context (out of memory?)");
            llama_model_free(h->model);
            return nullptr;
        }
        h->n_ctx   = (int) llama_n_ctx(h->ctx);
        h->n_embd  = llama_model_n_embd_out(h->model);
        if (h->n_embd <= 0) {
            h->n_embd = llama_model_n_embd(h->model);
        }
        h->encoder = llama_model_has_encoder(h->model);
        return h.release();
    } catch (const std::exception & e) {
        set_err(err, err_len, e.what());
        return nullptr;
    }
}

int cl_embed_info(void * hp, char * out_json, int len) {
    auto * h = (EmbedHandle *) hp;
    if (!h) return -1;
    try {
        char desc[256] = "";
        llama_model_desc(h->model, desc, sizeof(desc));
        auto j = common_json::object();
        j["description"] = std::string(desc);
        j["n_embd"]      = h->n_embd;
        j["pooling"]     = std::string(pooling_name(llama_pooling_type(h->ctx)));
        j["n_ctx"]       = h->n_ctx;
        return put(j.dump(), out_json, len);
    } catch (const std::exception &) {
        return -1;
    }
}

int cl_embed(void * hp, const char * text, float * out, int out_len, int normalize) {
    auto * h = (EmbedHandle *) hp;
    if (!h || !text || !out) return -1;
    try {
        if (out_len < h->n_embd) return -2;

        auto tokens = common_tokenize(h->vocab, text, /*add_special*/ true, /*parse_special*/ false);
        if (tokens.empty()) return -3;
        if ((int) tokens.size() > h->n_ctx) {
            // keep the closing special token (SEP/EOS) if the vocab adds one
            llama_token last = tokens.back();
            bool keep_last = llama_vocab_get_add_sep(h->vocab) || llama_vocab_get_add_eos(h->vocab);
            tokens.resize((size_t) h->n_ctx);
            if (keep_last) tokens.back() = last;
        }

        if (llama_memory_t mem = llama_get_memory(h->ctx)) {
            llama_memory_clear(mem, true);
        }
        llama_batch batch = llama_batch_get_one(tokens.data(), (int32_t) tokens.size());
        std::vector<int8_t> want_out(tokens.size(), 1);  // pooling needs every token as an output
        batch.logits = want_out.data();
        int rc = h->encoder ? llama_encode(h->ctx, batch) : llama_decode(h->ctx, batch);
        if (rc != 0) return -4;

        const float * e = llama_get_embeddings_seq(h->ctx, 0);
        if (!e) return -5;
        double norm = 0.0;
        for (int i = 0; i < h->n_embd; i++) norm += (double) e[i] * e[i];
        float scale = (normalize && norm > 0.0) ? (float) (1.0 / std::sqrt(norm)) : 1.0f;
        for (int i = 0; i < h->n_embd; i++) out[i] = e[i] * scale;
        return h->n_embd;
    } catch (const std::exception &) {
        return -1;
    }
}

void cl_embed_free(void * hp) {
    auto * h = (EmbedHandle *) hp;
    if (!h) return;
    if (h->ctx)   llama_free(h->ctx);
    if (h->model) llama_model_free(h->model);
    delete h;
}

}  // extern "C"
