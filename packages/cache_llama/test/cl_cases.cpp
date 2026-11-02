// Baseline case runner for the Cache native layer. Uses only the C API in cache_llama.h and the
// JSON library vendored in llama.cpp.
// Usage: cl_cases <model.gguf> <cases.json> <out.jsonl> <thinking on|off>
// The "expect_notes" field of a case is never sent to the model.
#include "cache_llama.h"

#include <nlohmann/json.hpp>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

using json = nlohmann::ordered_json;
using clk  = std::chrono::steady_clock;

static double ms(clk::time_point a, clk::time_point b) { return std::chrono::duration<double, std::milli>(b - a).count(); }

static const int MAX_GENERATIONS      = 5;     // 4 tool rounds, then the final answer
static const int MAX_TOKENS_PER_ROUND = 3000;  // safety cap against runaway generations

static std::string fixture_for(const json & results, std::map<std::string, int> & counts, const std::string & tool) {
    int n = ++counts[tool];
    std::string key = n == 1 ? tool : tool + "#" + std::to_string(n);
    const json * v = nullptr;
    if (results.is_object()) {
        if (results.contains(key))            v = &results.at(key);
        else if (results.contains("default")) v = &results.at("default");
    }
    if (!v) return "No results found.";
    return v->is_string() ? v->get<std::string>() : v->dump();
}

int main(int argc, char ** argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s <model.gguf> <cases.json> <out.jsonl> <thinking on|off>\n", argv[0]);
        return 2;
    }
    const std::string mode = argv[4];
    if (mode != "on" && mode != "off") { fprintf(stderr, "thinking must be on or off\n"); return 2; }
    const bool thinking = mode == "on";

    json cases;
    try {
        std::ifstream f(argv[2]);
        cases = json::parse(f);
    } catch (const std::exception & e) {
        fprintf(stderr, "cannot read cases: %s\n", e.what());
        return 2;
    }

    char err[1024] = "";
    void * h = cl_load(argv[1], 8192, 4, err, sizeof(err));
    if (!h) { fprintf(stderr, "cl_load failed: %s\n", err); return 1; }

    std::ofstream out(argv[3], std::ios::trunc);
    int idx = 0;
    for (const auto & c : cases) {
        idx++;
        std::string id = c.value("id", "");
        json rec = json::object();
        rec["id"]       = id;
        rec["kind"]     = c.value("kind", "");
        rec["thinking"] = thinking;

        json messages = json::array();
        messages.push_back({{"role", "system"}, {"content", c.value("system", "")}});
        messages.push_back({{"role", "user"}, {"content", c.value("user", "")}});
        const json tools   = c.contains("tools") ? c.at("tools") : json::array();
        const json results = c.contains("tool_results") ? c.at("tool_results") : json::object();

        json calls_out = json::array();
        std::map<std::string, int> counts;
        std::string final_text, reasoning_all, error;
        int rounds = 0, prompt_tokens = 0, gen_tokens = 0, call_seq = 0;
        double ttft = -1;
        bool truncated = false;
        auto case_start = clk::now();

        for (int round = 0; round < MAX_GENERATIONS; round++) {
            json req = {{"messages", messages}, {"enable_thinking", thinking}};
            if (!tools.empty()) req["tools"] = tools;

            auto t0 = clk::now();
            if (cl_start(h, req.dump().c_str(), err, sizeof(err)) != 0) {
                error = std::string("cl_start: ") + err;
                break;
            }
            rounds++;
            prompt_tokens += cl_prompt_tokens(h);

            std::vector<char> buf(512);
            int n;
            bool first = true;
            while ((n = cl_next(h, buf.data(), (int) buf.size())) >= 0) {
                if (first && n > 0) {
                    if (ttft < 0) ttft = ms(t0, clk::now());
                    first = false;
                }
                if (cl_generated_tokens(h) >= MAX_TOKENS_PER_ROUND) {
                    truncated = true;
                    cl_stop(h);
                }
            }
            int gen = cl_generated_tokens(h);
            gen_tokens += gen;
            if (n == -2) { error = "cl_next error"; break; }

            std::vector<char> fin(1 << 18);
            int len = cl_finish(h, fin.data(), (int) fin.size());
            if (len < 0) { error = "cl_finish output too large"; break; }
            json msg = json::parse(fin.data(), nullptr, false);
            if (msg.is_discarded()) { error = "cl_finish returned invalid JSON"; break; }
            if (msg.contains("parse_error")) error += (error.empty() ? "" : "; ") + std::string("parse_error: ") + msg.at("parse_error").get<std::string>();

            if (msg.contains("reasoning_content") && msg.at("reasoning_content").is_string()) {
                std::string r = msg.at("reasoning_content").get<std::string>();
                if (!r.empty()) reasoning_all += (reasoning_all.empty() ? "" : "\n---\n") + r;
            }
            final_text = msg.contains("content") && msg.at("content").is_string() ? msg.at("content").get<std::string>() : "";

            if (!msg.contains("tool_calls") || !msg.at("tool_calls").is_array() || msg.at("tool_calls").empty()) break;

            if (round == MAX_GENERATIONS - 1) { error += (error.empty() ? "" : "; ") + std::string("tool round limit reached"); break; }

            // keep the assistant message (with its tool calls), then answer every call in order
            json am = {{"role", "assistant"}, {"content", final_text}, {"tool_calls", msg.at("tool_calls")}};
            messages.push_back(am);
            for (auto & tc : am.at("tool_calls")) {
                const json & fn = tc.at("function");
                std::string name = fn.value("name", "");
                std::string args_s = fn.contains("arguments") && fn.at("arguments").is_string() ? fn.at("arguments").get<std::string>() : "";
                json args = json::parse(args_s, nullptr, false);
                if (args.is_discarded()) args = args_s;
                calls_out.push_back({{"name", name}, {"arguments", args}});
                std::string id_s = tc.value("id", "call_" + std::to_string(call_seq));
                call_seq++;
                messages.push_back({{"role", "tool"}, {"tool_call_id", id_s}, {"name", name},
                                    {"content", fixture_for(results, counts, name)}});
            }
        }
        double total = ms(case_start, clk::now());

        rec["tool_calls"]       = calls_out;
        rec["final_text"]       = final_text;
        rec["reasoning_text"]   = reasoning_all;
        rec["rounds"]           = rounds;
        rec["ttft_ms"]          = ttft < 0 ? json(nullptr) : json(ttft);
        rec["total_ms"]         = total;
        rec["prompt_tokens"]    = prompt_tokens;
        rec["generated_tokens"] = gen_tokens;
        if (truncated) rec["truncated"] = true;
        if (!error.empty()) rec["error"] = error;
        out << rec.dump() << "\n";
        out.flush();
        printf("[%d/%zu] %s thinking=%s calls=%zu rounds=%d total=%.0fms ttft=%.0fms gen=%d%s%s\n", idx, cases.size(), id.c_str(),
               mode.c_str(), calls_out.size(), rounds, total, ttft, gen_tokens, truncated ? " TRUNCATED" : "",
               error.empty() ? "" : (" ERROR " + error).c_str());
        fflush(stdout);
    }
    cl_free(h);
    printf("done\n");
    return 0;
}
