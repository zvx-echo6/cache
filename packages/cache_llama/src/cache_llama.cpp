#include "cache_llama.h"

#include "chat.h"
#include "common.h"
#include "llama.h"
#include "sampling.h"

#include <atomic>
#include <cstdio>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <string>
#include <vector>

namespace {

struct Handle {
    llama_model *             model = nullptr;
    llama_context *           ctx   = nullptr;
    const llama_vocab *       vocab = nullptr;
    common_chat_templates_ptr tmpls;
    int                       n_ctx = 0;

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

void quiet_log(enum ggml_log_level level, const char * text, void *) {
    if (level >= GGML_LOG_LEVEL_WARN) {
        fputs(text, stderr);
    }
}

}  // namespace

extern "C" {

void * cl_load(const char * model_path, int n_ctx, int n_threads, char * err, int err_len) {
    try {
        if (n_ctx <= 0)     n_ctx = 8192;
        if (n_threads <= 0) n_threads = 4;
        llama_log_set(quiet_log, nullptr);
        llama_backend_init();

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

        h->tmpls = common_chat_templates_init(h->model, "");
        if (!h->tmpls) {
            set_err(err, err_len, "model has no usable chat template");
            llama_free(h->ctx);
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

        // Full re-decode every turn (prefix reuse is a later optimisation).
        llama_memory_clear(llama_get_memory(h->ctx), true);
        const int n_batch = 512;
        for (int i = 0; i < h->n_prompt; i += n_batch) {
            int n = std::min(n_batch, h->n_prompt - i);
            if (llama_decode(h->ctx, llama_batch_get_one(tokens.data() + i, n)) != 0) {
                set_err(err, err_len, "decode failed while reading the prompt");
                return -1;
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
            return -2;
        } else {
            h->n_past++;
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

void cl_stop(void * hp) { ((Handle *) hp)->stop.store(true); }

void cl_free(void * hp) {
    auto * h = (Handle *) hp;
    if (!h) return;
    h->smpl.reset();
    h->session.reset();
    h->tmpls.reset();
    if (h->ctx)   llama_free(h->ctx);
    if (h->model) llama_model_free(h->model);
    delete h;
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
