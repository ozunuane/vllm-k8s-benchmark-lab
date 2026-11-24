import json, time, statistics, urllib.request, concurrent.futures as cf

URL = "http://localhost:18080/v1/chat/completions"
BODY = json.dumps({
    "model": "Qwen/Qwen2.5-7B-Instruct-AWQ",
    "messages": [{"role": "user", "content": "Explain in about three sentences why the sky appears blue during the day and red at sunset."}],
    "max_tokens": 100, "temperature": 0,
}).encode()

def one():
    t = time.time()
    r = urllib.request.Request(URL, BODY, {"Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=300) as resp:
        json.load(resp)
    return time.time() - t

def pct(xs, p):
    xs = sorted(xs); return xs[min(len(xs)-1, int(round(p/100*len(xs)+0.5))-1)]

def run(label, conc, total):
    t0 = time.time()
    lats, errs = [], 0
    with cf.ThreadPoolExecutor(max_workers=conc) as ex:
        for f in cf.as_completed([ex.submit(one) for _ in range(total)]):
            try: lats.append(f.result())
            except Exception: errs += 1
    wall = time.time() - t0
    print(f"{label:>5} | n={len(lats):3d} err={errs} | p50={statistics.median(lats):.2f}s p95={pct(lats,95):.2f}s max={max(lats):.2f}s | {len(lats)/wall:.1f} req/s")

one()  # warm
run("c30", 30, 60)
run("c60", 60, 120)
run("c100", 100, 200)
