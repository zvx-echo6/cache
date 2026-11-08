// Prompt reuse timing for the Cache native layer: replays a scripted conversation (the requests the app's Ask loop sends, built
// by prefix_turns.py from fixtures/prefix-turns.json) through cl_start and
// prints, per request, the prompt tokens, how many were reused (KV cache or the saved prefix) and how many were read.
// Nothing is generated: each request's prompt is read and the next one starts from it, as the assistant message the script
// carries replaces what the model would have written.
// Usage: cl_prefix <model.gguf> <turns.json> [prefix_dir]
//   turns.json: [{"label": "...", "request": {...}, "generate": N} | {"reload": true}, ...]; "reload" frees the model and loads
//   it again (an app restart: only the saved prefix, if a prefix_dir is given, survives it); "generate" (optional) generates N
//   tokens and prints them (with "temperature": 0 in the request, a restored prefix must give the same text as a fresh read).
// Output: one JSON object per request on stdout.
#include "cache_llama.h"

#include <nlohmann/json.hpp>

#include <chrono>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

using json = nlohmann::ordered_json;
using clk  = std::chrono::steady_clock;

static void * load(const char * model, int n_threads) {
    char err[512] = "";
    void * h = cl_load(model, 8192, n_threads, err, sizeof(err));
    if (!h) fprintf(stderr, "cl_load failed: %s\n", err);
    return h;
}

int main(int argc, char ** argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <model.gguf> <turns.json> [prefix_dir]\n", argv[0]);
        return 2;
    }
    std::ifstream f(argv[2]);
    std::stringstream ss;
    ss << f.rdbuf();
    const json steps = json::parse(ss.str());
    const int  n_threads = getenv("CL_THREADS") ? atoi(getenv("CL_THREADS")) : 0;
    json opts = json::object();
    opts["prefix_dir"] = argc > 3 ? std::string(argv[3]) : std::string();
    if (cl_configure(opts.dump().c_str()) != 0) return 1;

    void * h = load(argv[1], n_threads);
    if (!h) return 1;
    std::vector<char> buf(1 << 16), note(1024);
    for (const auto & s : steps) {
        if (s.value("reload", false)) {
            cl_free(h);
            h = load(argv[1], n_threads);
            if (!h) return 1;
            printf("{\"reload\":true}\n");
            fflush(stdout);
            continue;
        }
        const std::string req = s.at("request").dump();
        char err[512] = "";
        const auto t0 = clk::now();
        if (cl_start(h, req.c_str(), err, sizeof(err)) != 0) {
            fprintf(stderr, "cl_start failed at %s: %s\n", s.value("label", "?").c_str(), err);
            return 1;
        }
        const double ms = std::chrono::duration<double, std::milli>(clk::now() - t0).count();
        // "generate": N tokens (with "temperature": 0 in the request, to compare a restored prefix with a fresh one); else none.
        std::string text;
        const int   gen = s.value("generate", 0);
        int         n   = 0;
        for (int k = 0; k < gen && (n = cl_next(h, buf.data(), (int) buf.size())) >= 0; k++) text.append(buf.data(), (size_t) n);
        cl_stop(h);
        cl_next(h, buf.data(), (int) buf.size());  // ends the generation
        json o;
        o["label"]     = s.value("label", "");
        o["prompt"]    = cl_prompt_tokens(h);
        o["reused"]    = cl_reused_tokens(h);
        o["evaluated"] = cl_prompt_tokens(h) - cl_reused_tokens(h);
        o["start_ms"]  = (long long) ms;
        if (cl_prefix_note(h, note.data(), (int) note.size()) > 0) o["note"] = std::string(note.data());
        if (gen > 0) o["text"] = text;
        printf("%s\n", o.dump().c_str());
        fflush(stdout);
    }
    cl_free(h);
    return 0;
}
