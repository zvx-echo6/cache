"""Builds the requests of the prompt reuse timing test from fixtures/prefix-turns.json (a scripted Ask conversation: two
three-round questions in one chat, an app restart, then the second question again in a new chat; location known, text mode).

  baseline   what the app's Ask loop sends (rel-1.1): the time and location lines at the end of the system prompt, and the
             final round without tools.
  candidate  a layout measured in the ask-perf-tier1 eval (not in the app): a fixed system prompt, the question's time and
             location context at the start of its user message, and after the third tool round the same tools with
             "tool_choice": "none" and the answer-now nudge.

  python3 -I prefix_turns.py steps <fixture> <arm> > s.json   the input of cl_prefix (a reload before the new chat)
Then: cl_prefix <model.gguf> s.json [prefix_dir]
"""
import hashlib, json, sys
from datetime import datetime

VOICE_LINE = ("The user is talking to you by voice and will hear your answer read aloud: keep it short, two to four plain "
              "spoken sentences, with no tables, lists, headings or links. Keep the citation numbers; they are not read aloud.")
INSTRUCTIONS = [
    "You are Cache, an offline survival and preparedness assistant on this phone.",
    "For facts, places, routes, weather and practical instructions, use tools and answer only from their results. "
    "Search offline first. Use available web search if offline sources are insufficient or current information is needed; "
    "say plainly when web search is unavailable.",
    "Cite every sourced fact with its number, like [1]. If results are insufficient, say it is not in the user's sources. "
    "If data expired or was not downloaded, say online access is needed.",
    "Use results already available. Read a source only when its snippet is insufficient. "
    "Once evidence is sufficient, answer directly without describing tool plans.",
    "For small talk or feelings, talk without tools. Be calm, warm and supportive, especially under stress; give complete, practical answers.",
]
LOC_KNOWN = "The phone's current location is known; the tools use it when you leave the place out, so don't ask the person where they are."
ANSWER_NOW = {"role": "user", "content": "Answer now from the tool results above. No more tools are available."}
MAX_TOOL_ROUNDS = 3


def clock_line(now_iso):
    dt = datetime.fromisoformat(now_iso)
    secs = dt.utcoffset().total_seconds()
    m = abs(int(secs)) // 60
    off = f"{'-' if secs < 0 else '+'}{m // 60:02d}:{m % 60:02d}"
    return f"Current local date and time: {dt.strftime('%A')}, {dt.year:04d}-{dt.month:02d}-{dt.day:02d} {dt.hour:02d}:{dt.minute:02d} (UTC{off})."


def requests(fx, arm):
    """One list of requests per scripted turn, as tool_loop.dart builds them."""
    reqs, chats = [], {}
    for t in fx["script"]:
        msgs, ncall = chats.setdefault(t["chat"], ([], [1]))
        if arm == "baseline":
            system, user = "\n".join(INSTRUCTIONS + [clock_line(t["now"]), LOC_KNOWN]), t["question"]
        else:
            system, user = "\n".join(INSTRUCTIONS), clock_line(t["now"]) + "\n" + LOC_KNOWN + "\n\n" + t["question"]
        msgs.append({"role": "user", "content": user})
        turn = []
        for k in range(MAX_TOOL_ROUNDS + 1):
            capped = k >= MAX_TOOL_ROUNDS
            req = {"messages": [{"role": "system", "content": system}] + [dict(x) for x in msgs], "enable_thinking": False, "max_tokens": 2048}
            if arm == "baseline":
                if not capped:
                    req["tools"] = fx["schemas"]
            else:
                req["tools"] = fx["schemas"]
                if capped:
                    req["messages"].append(dict(ANSWER_NOW))
                    req["tool_choice"] = "none"
            turn.append(req)
            if capped:
                msgs.append({"role": "assistant", "content": t["answer"]})
                break
            rd = t["rounds"][k]
            cid = f"call_{ncall[0]}"
            ncall[0] += 1
            msgs.append({"role": "assistant", "content": rd["content"],
                         "tool_calls": [{"id": cid, "type": "function", "function": {"name": rd["name"], "arguments": rd["arguments"]}}]})
            msgs.append({"role": "tool", "tool_call_id": cid, "content": rd["result"]})
        reqs.append(turn)
    return reqs


def canonical_sha256(reqs):
    """sha256 of the requests as compact JSON with sorted keys (for comparing with another builder of the same requests)."""
    return hashlib.sha256(json.dumps(reqs, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def main():
    cmd, fx = sys.argv[1], json.load(open(sys.argv[2]))
    if cmd == "sha256":
        for arm in ("candidate", "baseline"):
            print(arm, canonical_sha256(requests(fx, arm)))
        return
    arm = sys.argv[3]
    steps, script = [], fx["script"]
    for ti, (t, turn) in enumerate(zip(script, requests(fx, arm))):
        if ti and t["chat"] != script[ti - 1]["chat"]:
            steps.append({"reload": True})
        for k, req in enumerate(turn):
            steps.append({"label": f"chat {t['chat']} question {ti + 1} round {k + 1}" + (" (final)" if k == MAX_TOOL_ROUNDS else ""), "request": req})
    json.dump(steps, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
