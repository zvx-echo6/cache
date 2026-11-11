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
#include <cstdarg>
#include <cstdio>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <sys/stat.h>
#if defined(__APPLE__)
#include <cerrno>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#endif
#if defined(__linux__) || defined(__ANDROID__)
#include <cerrno>
#include <fcntl.h>
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
    bool                                 context_cut = false;  // the last generation ended because the context was full
    std::atomic<bool>                    stop{false};
    std::vector<llama_token>             stop_tokens;  // tool_choice "none": tool-call openings end the generation

    // Gentle pre-read of the model file into the page cache (cl_configure preread_mbps): one thread, stopped and joined in free_handle.
    std::thread       preread;
    std::atomic<bool> preread_stop{false};

    // How the weights were loaded (cl_info): "repacked", "mmap" or "default", and why.
    std::string weights        = "default";
    std::string weights_reason;

    // The saved prompt prefix (cl_configure prefix_dir): the folder, the model file's identity, and the last cl_start's note.
    std::string prefix_dir;
    std::string model_id;
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
int         g_preread_mbps   = 0;      // target rate of the gentle pre-read in MB/s, 0 = off (cl_configure "preread_mbps")

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
    const std::string head = h->model_id + "\n" + engine_build() + "\n" + std::to_string(h->n_ctx) + "\n";
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

// ---------------- lookup-only tensors stay on flash ----------------
// The embedding tables a token only looks one row up in (GET_ROWS): per_layer_token_embd (Gemma 4's per-layer table, 56% of the E2B
// file) and token_embd when the model has a separate output.weight (tied to the output head, token_embd is read in full every token,
// so it is not lookup-only). Their pages are advised MADV_RANDOM so the kernel does not read ahead around each row and fill memory
// with pages that are used once. kPleAdvice is the one switch the bench compares (none = no advice).
enum class PleAdvice { kRandom, kNone };
constexpr PleAdvice kPleAdvice = PleAdvice::kRandom;

#if defined(__linux__) || defined(__ANDROID__)
// madvise(MADV_RANDOM) on the lookup-only tensors of the model file, inside its mmap (found from /proc/self/maps by file offset;
// a tensor that is not inside a mapping of the model file, e.g. weights not file-mapped, is skipped). Logs once.
void advise_lookup_tensors(const char * model_path) {
    if (kPleAdvice == PleAdvice::kNone) {
        cl_logi("PLE advice: none");
        return;
    }
    struct Range { uint64_t off, size; };
    std::vector<Range> ranges;
    {
        gguf_init_params gp;
        gp.no_alloc = true;
        gp.ctx      = nullptr;
        gguf_context * g = gguf_init_from_file(model_path, gp);
        if (!g) {
            cl_logi("PLE advice: model header not read, nothing advised");
            return;
        }
        const uint64_t base = gguf_get_data_offset(g);
        const int64_t  n    = gguf_get_n_tensors(g);
        bool has_output = false;
        for (int64_t i = 0; i < n; i++) {
            if (strcmp(gguf_get_tensor_name(g, i), "output.weight") == 0) has_output = true;
        }
        for (int64_t i = 0; i < n; i++) {
            const char * name = gguf_get_tensor_name(g, i);
            const bool lookup = strncmp(name, "per_layer_token_embd", 20) == 0 || (has_output && strncmp(name, "token_embd", 10) == 0);
            if (lookup) ranges.push_back({ base + gguf_get_tensor_offset(g, i), (uint64_t) gguf_get_tensor_size(g, i) });
        }
        gguf_free(g);
    }
    if (ranges.empty()) {
        cl_logi("PLE advice: no lookup-only tensors in this model");
        return;
    }
    struct Vma { uint64_t start, end, off; };
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
            if (path == model_path || (!real.empty() && path == real)) vmas.push_back({ st, en, off });
        }
        fclose(f);
    }
    const uint64_t ps = (uint64_t) sysconf(_SC_PAGESIZE);
    uint64_t bytes = 0;
    int      err   = 0;
    for (const auto & r : ranges) {
        for (const auto & v : vmas) {
            if (r.off < v.off || r.off + r.size > v.off + (v.end - v.start)) continue;
            const uint64_t addr = v.start + (r.off - v.off);
            const uint64_t lo   = (addr + ps - 1) & ~(ps - 1);          // rounded in: no neighbouring tensor's page is advised
            const uint64_t hi   = (addr + r.size) & ~(ps - 1);
            if (hi <= lo) break;
            if (madvise((void *) lo, hi - lo, MADV_RANDOM) == 0) bytes += hi - lo; else err = errno;
            break;
        }
    }
    if (err != 0) {
        cl_logi("PLE advice: random on %llu MB (errno %d)", (unsigned long long) (bytes >> 20), err);
    } else {
        cl_logi("PLE advice: random on %llu MB (ok)", (unsigned long long) (bytes >> 20));
    }
}
#else
void advise_lookup_tensors(const char *) {}
#endif

// ---------------- gentle pre-read ----------------
// The first prompt of a chat faults in about 1.5 GB of the mmapped model within seconds, which pushes free pages under Android's
// low-memory watermark and kills cached apps. Reading the file ahead at a low, steady rate spreads that out. It uses its own file
// descriptor and never touches the mapping or the model. per_layer_token_embd is left alone: llama.cpp reads those rows lazily.
[[maybe_unused]] constexpr uint64_t kPrereadStep = 1u << 20;  // 1 MiB

// Milliseconds to sleep so that `bytes` read after `elapsed_us` microseconds never exceeds `mbps` MB/s (1 MB = 1 MiB). 0 if on pace.
[[maybe_unused]] long long preread_sleep_ms(uint64_t bytes, long long elapsed_us, int mbps) {
    if (mbps <= 0) return 0;
    const long long due_us = (long long) ((double) bytes * 1e6 / ((double) mbps * 1048576.0));
    const long long wait   = due_us - elapsed_us;
    return wait > 0 ? (wait + 999) / 1000 : 0;
}

// File ranges to read: every tensor except per_layer_token_embd*, sorted by offset, adjacent or overlapping ranges merged.
[[maybe_unused]] std::vector<std::pair<uint64_t, uint64_t>> preread_ranges(const char * model_path) {
    std::vector<std::pair<uint64_t, uint64_t>> r;  // (offset, size)
    gguf_init_params gp;
    gp.no_alloc = true;
    gp.ctx      = nullptr;
    gguf_context * g = gguf_init_from_file(model_path, gp);
    if (!g) return r;
    const uint64_t base = gguf_get_data_offset(g);
    const int64_t  n    = gguf_get_n_tensors(g);
    for (int64_t i = 0; i < n; i++) {
        if (strncmp(gguf_get_tensor_name(g, i), "per_layer_token_embd", 20) == 0) continue;
        r.push_back({ base + gguf_get_tensor_offset(g, i), (uint64_t) gguf_get_tensor_size(g, i) });
    }
    gguf_free(g);
    std::sort(r.begin(), r.end());
    std::vector<std::pair<uint64_t, uint64_t>> m;
    for (const auto & x : r) {
        if (x.second == 0) continue;
        if (!m.empty() && x.first <= m.back().first + m.back().second) {
            const uint64_t end = std::max(m.back().first + m.back().second, x.first + x.second);
            m.back().second = end - m.back().first;
        } else {
            m.push_back(x);
        }
    }
    return m;
}

#if defined(__linux__) || defined(__ANDROID__) || defined(__APPLE__)
#if defined(__APPLE__)
typedef char mincore_vec_t;
#else
typedef unsigned char mincore_vec_t;
#endif
// Reads the model's tensor ranges into the page cache, paced to `mbps` MB/s. Steps whose pages are all resident already (found with
// mincore() on this thread's own read-only mapping, never read through) are skipped and do not count toward the pace.
void preread_run(std::string path, int mbps, std::atomic<bool> * stop) {
    using clock = std::chrono::steady_clock;
    const auto ranges = preread_ranges(path.c_str());
    uint64_t total = 0;
    for (const auto & r : ranges) total += r.second;
    cl_logi("preread: start, %llu MB in %zu ranges at %d MB/s", (unsigned long long) (total >> 20), ranges.size(), mbps);
    const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        cl_logi("preread: stopped at 0 MB read (0 MB resident) after 0 ms (cannot open the file)");
        return;
    }
    // Own mapping, only for mincore(); if it cannot be made, every step is read as before.
    const uint64_t ps = (uint64_t) sysconf(_SC_PAGESIZE);
    uint64_t fsize = 0;
    {
        struct stat st;
        if (fstat(fd, &st) == 0) fsize = (uint64_t) st.st_size;
    }
    void * map = (fsize > 0) ? mmap(nullptr, (size_t) fsize, PROT_READ, MAP_SHARED, fd, 0) : MAP_FAILED;
    bool resident_check = map != MAP_FAILED;
    if (!resident_check) cl_logi("preread: residency check off (mmap failed, errno %d), reading every step", errno);
    const uint64_t map_end = (fsize + ps - 1) & ~(ps - 1);
    std::vector<mincore_vec_t> vec;
    std::vector<char> buf(kPrereadStep);
    const auto t0 = clock::now();
    auto since_us = [&]() { return (long long) std::chrono::duration_cast<std::chrono::microseconds>(clock::now() - t0).count(); };
    uint64_t done = 0;      // bytes passed (read or already resident)
    uint64_t read_b = 0;    // bytes read: these count toward the pace
    uint64_t resident_b = 0;
    bool halted = false;
    for (const auto & r : ranges) {
        for (uint64_t pos = 0; pos < r.second && !halted; ) {
            if (stop->load()) { halted = true; break; }
            const uint64_t off  = r.first + pos;
            const uint64_t want = std::min<uint64_t>(kPrereadStep, r.second - pos);
            bool all_resident = false;
            if (resident_check) {
                const uint64_t lo = off & ~(ps - 1);
                const uint64_t hi = std::min<uint64_t>((off + want + ps - 1) & ~(ps - 1), map_end);
                if (hi > lo) {
                    vec.assign((size_t) ((hi - lo) / ps), 0);
                    if (mincore((char *) map + lo, (size_t) (hi - lo), vec.data()) == 0) {
                        all_resident = true;
                        for (mincore_vec_t v : vec) {
                            if (!(v & 1)) { all_resident = false; break; }
                        }
                    } else {
                        cl_logi("preread: residency check off (mincore failed, errno %d), reading every step", errno);
                        resident_check = false;
                    }
                }
            }
            if (all_resident) {
                pos        += want;
                done       += want;
                resident_b += want;
                continue;
            }
            const ssize_t got = pread(fd, buf.data(), (size_t) want, (off_t) off);
            if (got <= 0) { halted = true; break; }
            pos    += (uint64_t) got;
            done   += (uint64_t) got;
            read_b += (uint64_t) got;
            long long ms = preread_sleep_ms(read_b, since_us(), mbps);
            while (ms > 0 && !stop->load()) {  // sleep in slices so a free is noticed within one step
                const long long slice = std::min<long long>(ms, 20);
                std::this_thread::sleep_for(std::chrono::milliseconds(slice));
                ms -= slice;
            }
        }
        if (halted) break;
    }
    if (map != MAP_FAILED) munmap(map, (size_t) fsize);
    close(fd);
    const long long ms = since_us() / 1000;
    if (!halted && done >= total) {
        cl_logi("preread: done, read %llu MB, already resident %llu MB, in %lld ms", (unsigned long long) (read_b >> 20),
                (unsigned long long) (resident_b >> 20), ms);
    } else {
        cl_logi("preread: stopped at %llu MB read (%llu MB resident) after %lld ms", (unsigned long long) (read_b >> 20),
                (unsigned long long) (resident_b >> 20), ms);
    }
}
#else
void preread_run(std::string, int, std::atomic<bool> *) {
    cl_logi("preread: off");  // no pread() on this platform
}
#endif

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

}  // namespace

// Every chat handle not freed yet, for cl_free_all: the process outlives the app's Dart side when Android destroys the
// window and makes a new one (a new Flutter engine in the same process). The old engine's handle is never freed by it,
// and its model would stay in memory beside the one the new engine loads.
static std::mutex          g_live_mu;
static std::set<Handle *>  g_live;

static void free_handle(Handle * h) {
    // Stop the pre-read first: it must be gone before the model is.
    h->preread_stop.store(true);
    if (h->preread.joinable()) h->preread.join();
    h->smpl.reset();
    h->session.reset();
    h->tmpls.reset();
    if (h->ctx)   llama_free(h->ctx);
    if (h->pool)  h->pool_free(h->pool);
    if (h->model) llama_model_free(h->model);
    delete h;
}

extern "C" {

int cl_configure(const char * options_json) {
    try {
        auto j = common_json::parse(options_json ? options_json : "{}");
        std::lock_guard<std::mutex> lock(g_opt_mu);
        if (j.contains("prefix_dir") && j.at("prefix_dir").is_string()) g_prefix_dir = j.at("prefix_dir").get<std::string>();
        if (j.contains("repack_weights") && j.at("repack_weights").is_boolean()) g_repack_weights = j.at("repack_weights").get<bool>();
        if (j.contains("preread_mbps") && j.at("preread_mbps").is_number()) g_preread_mbps = std::max(0, j.at("preread_mbps").get<int>());
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
        int  preread_mbps  = 0;
        {
            std::lock_guard<std::mutex> lock(g_opt_mu);
            repack_opt_in = g_repack_weights;
            preread_mbps  = g_preread_mbps;
            h->prefix_dir = g_prefix_dir;
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
        // llama.cpp's own on-demand reading of the tensors the architecture marks (Gemma 4's per-layer table): no read of the whole
        // file up front, the rows a batch needs are prefetched. Needs mmap.
        mp.lazy_mode = LLAMA_LAZY_MODE_ON;
        cl_logi("engine: lazy=on");
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
        cp.n_threads       = n_threads;
        cp.n_threads_batch = n_threads;
        h->ctx = llama_init_from_model(h->model, cp);
        if (!h->ctx) {
            set_err(err, err_len, "cannot create context (out of memory?)");
            llama_model_free(h->model);
            return nullptr;
        }
        h->n_ctx = (int) llama_n_ctx(h->ctx);
        advise_lookup_tensors(model_path);

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
        Handle * out = h.release();
        {
            std::lock_guard<std::mutex> lock(g_live_mu);
            g_live.insert(out);
        }
        if (preread_mbps > 0) {
            try {
                out->preread = std::thread(preread_run, std::string(model_path), preread_mbps, &out->preread_stop);
            } catch (const std::exception &) {
                cl_logi("preread: off (thread not started)");
            }
        } else {
            cl_logi("preread: off");
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
        h->context_cut = false;
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
            return -3;  // context full: distinct from the other failures (-1)
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
            h->context_cut = true;
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
        if (h->context_cut) j["stop"] = std::string("context");
    } catch (const std::exception & e) {
        j["content"]     = h->generated;
        j["parse_error"] = std::string(e.what());
        if (h->context_cut) j["stop"] = std::string("context");
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
        // The weights stay memory-mapped from the file: no repacked anonymous copy of them.
        llama_model_params mp = llama_model_default_params();
        mp.use_extra_bufts    = false;
        h->model = llama_model_load_from_file(model_path, mp);
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
