"""Model test: a saved prompt start from an earlier day must not change what the model is given or says.

A prompt-start file saved on an earlier day shares only the text before the date line with today's prompt. Restoring such a file
for the part it shares and dropping the rest of it left the KV cache in a state where later tail drops did not fully take effect,
and a new chat answered the previous chat's question. The rule (cache_llama.cpp, best_prefix_file): a saved file is restored only
when ALL of its tokens are a prefix of the prompt; otherwise the prompt is read as usual.

This builds the steps of one conversation from fixtures/prefix-earlier-day.json (the requests the app's Ask loop sends, with
temperature 0 and a scripted assistant side, as prefix_turns.py does) and runs them twice with cl_prefix:

  earlier-day run  warm with the system prompt dated the day before (saves that start), reload (an app restart), then today:
                   warm, chat 1 Q1 (two rounds), its TITLE request, Q2 in the same chat, chat 2 Q3 (new chat, two rounds), its TITLE
  reference run    the same steps with an empty prefix folder and no earlier-day warm (nothing to restore: today's start is decoded
                   by the warm and saved, exactly the path the earlier-day run must take once it ignores the partial file)
  no-folder run    the same steps with no prefix folder at all (nothing is saved or restored; its start is read with the question, in
                   other batches, so only its prompt token counts are compared, not its text: the numbers differ in the last digits)

and checks that every generated text and every prompt token count are equal between the earlier-day and reference runs, that the
prompt token counts of all three runs are equal (the model is given the same tokens with and without the earlier-day file), and that
the earlier-day run's log shows no "Prompt prefix restored" (no partial file is restored). Exit status 0 when all hold, 1 when not.

How to run (on cortex the model is /mnt/mesh-train/export/cache-1.0-out-20261030/e2b-stock/e2b-stock-cache-1.0-Q4_K_M.gguf):
  build cl_prefix: cmake -S packages/cache_llama/src -B <build> -DCMAKE_BUILD_TYPE=Release -DCACHE_LLAMA_TEST_CLI=ON
                   cmake --build <build> --target cl_prefix -j 4
  python3 -I packages/cache_llama/test/prefix_earlier_day.py <build>/cl_prefix <model.gguf> [workdir]
  (the workdir, default a new temp folder, holds the step files, the prefix folder and the two logs; CL_THREADS sets the threads)
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GEN_ROUND, GEN_TITLE = 160, 12


def build_steps(fx, earlier_day):
    def system(date):
        return "\n".join(fx["instructions"] + [f"Current local date: {date} (UTC{fx['utc_offset']}).", fx["location_line"]])

    def req(msgs, date, extra=None):
        m = [{"role": "system", "content": system(date)}] + [dict(x) for x in msgs] + ([extra] if extra else [])
        return {"messages": m, "enable_thinking": False, "max_tokens": 2048, "temperature": 0, "tools": fx["schemas"]}

    steps = []
    if earlier_day:
        steps += [{"label": "warm earlier day", "warm": req([], fx["earlier_date"])}, {"reload": True}]
    today = fx["today_date"]
    steps.append({"label": "warm today", "warm": req([], today)})
    for chat in fx["chats"]:
        msgs, ncall = [], 1
        for t in chat["turns"]:
            msgs.append({"role": "user", "content": f"Local time: {t['time']}\n\n{t['question']}"})
            for k, rd in enumerate(t["rounds"] + [None]):
                steps.append({"label": f"chat {chat['chat']} {t['label']} round {k + 1}", "request": req(msgs, today), "generate": GEN_ROUND})
                if rd is None:
                    break
                cid = f"call_{ncall}"
                ncall += 1
                msgs.append({"role": "assistant", "content": rd["content"],
                             "tool_calls": [{"id": cid, "type": "function", "function": {"name": rd["name"], "arguments": rd["arguments"]}}]})
                msgs.append({"role": "tool", "tool_call_id": cid, "content": fx["results"][rd["result"]]})
            msgs.append({"role": "assistant", "content": t["answer"]})
            if t["title"]:
                steps.append({"label": f"chat {chat['chat']} {t['label']} TITLE",
                              "request": req(msgs, today, {"role": "user", "content": fx["title_prompt"]}), "generate": GEN_TITLE})
    return steps


def run(exe, model, steps, prefix_dir, work, name):
    sf = os.path.join(work, f"{name}-steps.json")
    json.dump(steps, open(sf, "w"), ensure_ascii=False)
    cmd = [exe, model, sf] + ([prefix_dir] if prefix_dir else [])
    p = subprocess.run(cmd, capture_output=True, text=True)
    open(os.path.join(work, f"{name}.stdout"), "w").write(p.stdout)
    open(os.path.join(work, f"{name}.log"), "w").write(p.stderr)
    if p.returncode != 0:
        sys.exit(f"{name}: cl_prefix failed ({p.returncode}):\n{p.stderr[-2000:]}")
    return [json.loads(l) for l in p.stdout.splitlines() if l.startswith("{")], p.stderr


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    exe, model = sys.argv[1], sys.argv[2]
    work = sys.argv[3] if len(sys.argv) > 3 else tempfile.mkdtemp(prefix="prefix-earlier-day-")
    os.makedirs(work, exist_ok=True)
    fx = json.load(open(os.path.join(HERE, "fixtures", "prefix-earlier-day.json")))
    pdir = os.path.join(work, "prefix")
    os.makedirs(pdir, exist_ok=True)
    for f in os.listdir(pdir):
        os.remove(os.path.join(pdir, f))
    got, got_log = run(exe, model, build_steps(fx, True), pdir, work, "earlier-day")
    rdir = os.path.join(work, "prefix-reference")
    os.makedirs(rdir, exist_ok=True)
    for f in os.listdir(rdir):
        os.remove(os.path.join(rdir, f))
    ref, _ = run(exe, model, build_steps(fx, False), rdir, work, "reference")
    nof, _ = run(exe, model, build_steps(fx, False), "", work, "no-folder")
    ok = True
    ga = {o["label"]: o for o in got if "text" in o}
    ra = {o["label"]: o for o in ref if "text" in o}
    for label, r in ra.items():
        g = ga.get(label)
        if g is None:
            print(f"FAIL {label}: missing in the earlier-day run"); ok = False; continue
        same_text, same_prompt = g["text"] == r["text"], g["prompt"] == r["prompt"]
        print(f"{'ok  ' if same_text and same_prompt else 'FAIL'} {label}: prompt {g['prompt']} vs {r['prompt']}, reused {g['reused']} vs {r['reused']}")
        if not same_prompt:
            ok = False
            print("     prompt tokens differ (the model was given other tokens)")
        if not same_text:
            ok = False
            print(f"     earlier-day: {g['text']!r}\n     reference:   {r['text']!r}")
    na = {o["label"]: o for o in nof if "text" in o}
    for label, r in na.items():
        if ga[label]["prompt"] != r["prompt"]:
            ok = False
            print(f"FAIL {label}: prompt tokens {ga[label]['prompt']} (earlier-day) vs {r['prompt']} (no prefix folder)")
    if ok:
        print("ok   prompt token counts equal in all three runs")
    if "Prompt prefix restored" in got_log:
        ok = False
        print("FAIL the earlier-day run restored a saved prompt start (the earlier day's file shares only part of today's prompt):")
        for l in got_log.splitlines():
            if "Prompt prefix restored" in l:
                print("     " + l)
    else:
        print("ok   no partial saved start was restored")
    if "Prompt prefix saved" not in got_log:
        ok = False
        print("FAIL today's prompt start was not saved")
    print("files in", work)
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


main()
