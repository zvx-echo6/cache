// Command line test for the Cache native layer. Uses only the C API in cache_llama.h.
// Usage: cl_test <model.gguf> [n_threads]
#include "cache_llama.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

using clk = std::chrono::steady_clock;
static double secs(clk::time_point a, clk::time_point b) { return std::chrono::duration<double>(b - a).count(); }

struct Result {
    std::string text;      // streamed text
    std::string message;   // cl_finish JSON
    bool        ok = false;
};

static Result run(void * h, const std::string & request, bool stream) {
    Result r;
    char err[512] = "";
    auto t0 = clk::now();
    if (cl_start(h, request.c_str(), err, sizeof(err)) != 0) {
        printf("cl_start failed: %s\n", err);
        return r;
    }
    auto t1 = clk::now();
    int n_prompt = cl_prompt_tokens(h);
    std::vector<char> buf(256), out(1 << 16);
    int n;
    while ((n = cl_next(h, buf.data(), (int) buf.size())) >= 0) {
        r.text.append(buf.data(), (size_t) n);
        if (stream) { fwrite(buf.data(), 1, (size_t) n, stdout); fflush(stdout); }
    }
    auto t2 = clk::now();
    if (n == -2) { printf("\ncl_next error\n"); return r; }
    int n_gen = cl_generated_tokens(h);
    if (cl_finish(h, out.data(), (int) out.size()) < 0) { printf("cl_finish: buffer too small\n"); return r; }
    r.message = out.data();
    r.ok = true;
    printf("\n[prompt: %d tok in %.2fs = %.1f tok/s | generation: %d tok in %.2fs = %.1f tok/s | total %.2fs]\n",
           n_prompt, secs(t0, t1), n_prompt / secs(t0, t1), n_gen, secs(t1, t2), n_gen / secs(t1, t2), secs(t0, t2));
    return r;
}

static const char * TOOLS =
    R"([{"type":"function","function":{"name":"search","description":"Search the user's offline library and reference articles",)"
    R"("parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}}])";
static const char * SYSTEM =
    "You are Cache, an offline survival assistant. Use the search tool to look things up before answering. "
    "Cite sources with their [id] numbers.";

// Minimal JSON string escaper for building requests by hand.
static std::string js(const std::string & s) {
    std::string o = "\"";
    for (char c : s) {
        if (c == '"' || c == '\\') { o += '\\'; o += c; }
        else if (c == '\n') o += "\\n";
        else o += c;
    }
    return o + "\"";
}

static std::string between(const std::string & s, const std::string & a, const std::string & b, size_t from = 0) {
    size_t i = s.find(a, from);
    if (i == std::string::npos) return "";
    i += a.size();
    size_t j = s.find(b, i);
    return j == std::string::npos ? "" : s.substr(i, j - i);
}

int main(int argc, char ** argv) {
    if (argc < 2) { fprintf(stderr, "usage: cl_test <model.gguf> [n_threads]\n"); return 2; }
    int threads = argc > 2 ? atoi(argv[2]) : 4;
    char err[512] = "";
    void * h = cl_load(argv[1], 8192, threads, err, sizeof(err));
    if (!h) { printf("cl_load failed: %s\n", err); return 1; }
    int fails = 0;

    // (1) info
    char info[2048];
    cl_info(h, info, sizeof(info));
    printf("=== (1) info ===\n%s\n", info);
    bool p1 = std::string(info).find("\"supports_tools\":true") != std::string::npos;
    printf("TEST 1 info (supports_tools): %s\n\n", p1 ? "PASS" : "FAIL");
    fails += !p1;

    // (2) plain chat
    printf("=== (2) plain chat ===\n");
    std::string user1 = "Name three ways to purify water. One line each.";
    Result r2 = run(h, "{\"messages\":[{\"role\":\"user\",\"content\":" + js(user1) + "}]}", true);
    bool p2 = r2.ok && r2.text.size() > 20;
    printf("TEST 2 plain chat: %s\n\n", p2 ? "PASS" : "FAIL");
    fails += !p2;

    // (3) tool call
    printf("=== (3) tool call ===\n");
    std::string sys = "{\"role\":\"system\",\"content\":" + js(SYSTEM) + "}";
    std::string usr = "{\"role\":\"user\",\"content\":" + js("How do I treat a burn on my hand?") + "}";
    Result r3 = run(h, "{\"messages\":[" + sys + "," + usr + "],\"tools\":" + TOOLS + "}", true);
    printf("raw: %s\nfinish JSON: %s\n", r3.text.c_str(), r3.message.c_str());
    bool p3 = r3.ok && r3.message.find("\"name\":\"search\"") != std::string::npos &&
              r3.message.find("query") != std::string::npos;
    printf("TEST 3 tool call: %s\n\n", p3 ? "PASS" : "FAIL");
    fails += !p3;

    // (4) tool result round
    printf("=== (4) tool result round ===\n");
    if (!p3) {
        printf("TEST 4 tool result round: FAIL (no tool call from test 3)\n");
        fails++;
    } else {
        std::string call_id = between(r3.message, "\"id\":\"", "\"");
        // Reuse the assistant message exactly as cl_finish returned it.
        std::string tool_content =
            "[1] WikiMed: Burn \xE2\x80\x94 Cool the burn under cool running water for 20 minutes. Remove rings. Cover loosely with cling film.\n"
            "[2] First aid manual p.142 \xE2\x80\x94 Seek medical help if the burn is larger than the palm or on the face, hands, feet or groin.";
        std::string tool_msg = "{\"role\":\"tool\",\"tool_call_id\":" + js(call_id) + ",\"content\":" + js(tool_content) + "}";
        Result r4 = run(h, "{\"messages\":[" + sys + "," + usr + "," + r3.message + "," + tool_msg + "],\"tools\":" + TOOLS + "}", true);
        printf("finish JSON: %s\n", r4.message.c_str());
        bool cites = r4.message.find("[1]") != std::string::npos || r4.message.find("[2]") != std::string::npos;
        bool no_call = r4.message.find("\"tool_calls\"") == std::string::npos;
        bool p4 = r4.ok && cites && no_call;
        printf("TEST 4 tool result round (cites=%d, no new tool call=%d): %s\n", cites, no_call, p4 ? "PASS" : "FAIL");
        fails += !p4;
    }

    printf("\n%s (%d failed)\n", fails ? "SOME TESTS FAILED" : "ALL TESTS PASSED", fails);
    cl_free(h);
    return fails ? 1 : 0;
}
