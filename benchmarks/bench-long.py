import json, time, statistics, urllib.request, concurrent.futures as cf, uuid

URL = "http://localhost:18080/v1/chat/completions"
PARA = ("Kubernetes schedules containers onto nodes based on resource requests, taints, tolerations, "
        "and affinity rules. The kubelet on each node reports allocatable capacity, which subtracts "
        "system reservations and daemonset overhead from raw machine capacity. When a pod requests "
        "a GPU, the device plugin must have registered the resource with the kubelet, otherwise the "
        "pod remains pending even though the hardware is physically present on the machine. ")
PROMPT = ("Read the following operations manual excerpt carefully.\n\n" + PARA * 16 +
          "\n\nIn exactly three sentences, summarise what determines whether a GPU pod can be scheduled.")
def body():
    # Unique head per request: prefix caching matches from token 0, so an
    # identical repeated prompt turns prefill into a cache hit and the
    # benchmark measures nothing. A unique first line forces real prefill.
    return json.dumps({
        "model": "Qwen/Qwen2.5-7B-Instruct-AWQ",
        "messages": [{"role": "user", "content": f"Ticket {uuid.uuid4()}\n" + PROMPT}],
        "max_tokens": 100, "temperature": 0,
    }).encode()

def one():
    t = time.time()
    r = urllib.request.Request(URL, body(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=300) as resp:
        d = json.load(resp)
    return time.time() - t, d["usage"]["prompt_tokens"]

def pct(xs, p):
    xs = sorted(xs); return xs[min(len(xs)-1, int(round(p/100*len(xs)+0.5))-1)]

def run(label, conc, total):
    t0 = time.time(); lats, errs = [], 0
    with cf.ThreadPoolExecutor(max_workers=conc) as ex:
        for f in cf.as_completed([ex.submit(one) for _ in range(total)]):
            try: lats.append(f.result()[0])
            except Exception: errs += 1
    wall = time.time() - t0
    print(f"{label:>5} | n={len(lats):3d} err={errs} | p50={statistics.median(lats):.2f}s p95={pct(lats,95):.2f}s max={max(lats):.2f}s | {len(lats)/wall:.1f} req/s")

_, ptok = one()
print(f"prompt_tokens={ptok}")
run("c10", 10, 30)
run("c30", 30, 60)
run("c60", 60, 120)
