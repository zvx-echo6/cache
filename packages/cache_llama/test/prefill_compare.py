"""Compare a native Cache engine against frozen synthetic requests and cold prefills.

Uses only Python's standard library. Model weights remain outside the repository.
Run once with the baseline library, then with the candidate and --compare baseline.json.
"""
import argparse
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import statistics
import time

class Engine:
    def __init__(self, library, model):
        self.library = Path(library).resolve()
        self.model = Path(model).resolve()
        self.directory = os.add_dll_directory(str(self.library.parent)) if os.name == "nt" else None
        self.b = C.CDLL(str(self.library))
        b = self.b
        b.cl_load.argtypes = [C.c_char_p, C.c_int, C.c_int, C.c_char_p, C.c_int]
        b.cl_load.restype = C.c_void_p
        b.cl_start.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p, C.c_int]
        b.cl_next.argtypes = [C.c_void_p, C.c_char_p, C.c_int]
        b.cl_finish.argtypes = [C.c_void_p, C.c_char_p, C.c_int]
        b.cl_info.argtypes = [C.c_void_p, C.c_char_p, C.c_int]
        b.cl_free.argtypes = [C.c_void_p]
        for name in ["cl_prompt_tokens", "cl_reused_tokens", "cl_generated_tokens"]:
            getattr(b, name).argtypes = [C.c_void_p]
        self.handle = None

    def load(self):
        self.close()
        err = C.create_string_buffer(1024)
        start = time.perf_counter()
        self.handle = self.b.cl_load(str(self.model).encode(), 8192, 4, err, len(err))
        if not self.handle:
            raise RuntimeError(err.value.decode(errors="replace"))
        load_ms = (time.perf_counter() - start) * 1000
        out = C.create_string_buffer(4096)
        assert self.b.cl_info(self.handle, out, len(out)) >= 0
        info = json.loads(out.value)
        return info, round(load_ms, 3)

    def close(self):
        if self.handle:
            self.b.cl_free(self.handle)
            self.handle = None

    def run(self, request, maximum=256):
        encoded = json.dumps(request, ensure_ascii=False, separators=(",", ":")).encode()
        err = C.create_string_buffer(1024)
        token = C.create_string_buffer(4096)
        out = C.create_string_buffer(1024 * 1024)
        start = time.perf_counter()
        rc = self.b.cl_start(self.handle, encoded, err, len(err))
        if rc:
            raise RuntimeError(err.value.decode(errors="replace"))
        prepared = time.perf_counter()
        first = None
        while True:
            rc = self.b.cl_next(self.handle, token, len(token))
            if rc == -2:
                raise RuntimeError("Native generation failed")
            if rc < 0:
                break
            if first is None:
                first = time.perf_counter()
            if self.b.cl_generated_tokens(self.handle) >= maximum:
                break
        assert first is not None, "No generated token"
        assert self.b.cl_finish(self.handle, out, len(out)) >= 0
        end = time.perf_counter()
        prompt = self.b.cl_prompt_tokens(self.handle)
        reused = self.b.cl_reused_tokens(self.handle)
        return {
            "request_sha256": hashlib.sha256(encoded).hexdigest(),
            "message": json.loads(out.value),
            "stats": {
                "prompt_tokens": prompt, "reused_tokens": reused,
                "generated_tokens": self.b.cl_generated_tokens(self.handle),
                "start_ms": round((prepared-start)*1000, 3),
                "first_token_ms": round((first-start)*1000, 3),
                "total_ms": round((end-start)*1000, 3),
                "effective_input_tokens_s": round((prompt-reused)/(first-start), 3),
            },
        }

def sha256_file(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        while block := f.read(8 * 1024 * 1024):
            h.update(block)
    return h.hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--expected-engine", required=True)
    parser.add_argument("--compare")
    parser.add_argument("--repeats", type=int, default=2)
    args = parser.parse_args()
    fixture = json.loads((Path(__file__).parent/"fixtures/gemma4-prefill.json").read_text(encoding="utf-8"))
    engine = Engine(args.library, args.model)
    report = {"library_sha256": sha256_file(args.library),
              "model_sha256": sha256_file(args.model), "cases": [], "prefills": []}
    try:
        info, load_ms = engine.load()
        report["info"] = info
        report["load_ms"] = load_ms
        assert info["engine_build"] == args.expected_engine, info
        print("ENGINE", info["engine_build"], "load_ms", load_ms, flush=True)
        for case in fixture["cases"]:
            request = {"messages": case["messages"], "tools": fixture["tools"],
                       "enable_thinking": False, "temperature": 0}
            record = engine.run(request)
            record["name"] = case["name"]
            calls = record["message"].get("tool_calls", [])
            if case.get("expected_tool"):
                assert calls and calls[0]["function"]["name"] == case["expected_tool"], record
            else:
                assert not calls, record
            if case.get("citation"):
                assert "[1]" in (record["message"].get("content") or ""), record
            report["cases"].append(record)
            Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
            print("CASE_PASS", case["name"], record["stats"], flush=True)
        # Fresh model contexts exclude KV-prefix reuse from the timing comparison.
        for repetitions in [32, 128]:
            for sample in range(args.repeats):
                engine.load()
                messages = json.loads(json.dumps(fixture["cases"][1]["messages"]))
                messages[1]["content"] = "Which locker contains the compass?"
                messages[2]["tool_calls"][0]["function"]["arguments"] = json.dumps({"query": "station supply register compass locker"})
                messages[-1]["content"] = (
                    "[1] Station supply register — " +
                    "The station register lists one compass in locker A and two spare batteries in locker B. " * repetitions
                )
                request = {"messages": messages, "tools": fixture["tools"],
                           "enable_thinking": False, "temperature": 0}
                record = engine.run(request, maximum=64)
                assert record["stats"]["reused_tokens"] == 0
                record.update({"repetitions": repetitions, "sample": sample})
                report["prefills"].append(record)
                Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
                print("PREFILL", repetitions, sample, record["stats"], flush=True)
        Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
        if args.compare:
            baseline = json.loads(Path(args.compare).read_text(encoding="utf-8"))
            assert baseline["model_sha256"] == report["model_sha256"], "Different model files"
            assert len(baseline["cases"]) == len(report["cases"])
            for before, after in zip(baseline["cases"], report["cases"]):
                assert before["request_sha256"] == after["request_sha256"], "Different request"
                assert before["message"] == after["message"], "Output changed in "+after["name"]
            assert len(baseline["prefills"]) == len(report["prefills"])
            for before, after in zip(baseline["prefills"], report["prefills"]):
                assert before["request_sha256"] == after["request_sha256"], "Different timing request"
                assert before["message"] == after["message"], "Long-prefill output changed"
            for repetitions in [32, 128]:
                before = statistics.median(x["stats"]["first_token_ms"] for x in baseline["prefills"] if x["repetitions"] == repetitions)
                after = statistics.median(x["stats"]["first_token_ms"] for x in report["prefills"] if x["repetitions"] == repetitions)
                print("PREFILL_SPEEDUP", repetitions, round(before/after, 3), "baseline_ms", before, "candidate_ms", after, flush=True)
            print("EXACT_GREEDY_PARITY_PASS", flush=True)
        print("ENGINE_COMPARISON_PASS", flush=True)
    finally:
        engine.close()

if __name__ == "__main__":
    main()
