import re, sys

def load(p):
    d = {}
    for line in open(p):
        m = re.match(r'(vllm:\S+?)\{(.*?)\}\s+(\S+)', line)
        if not m:
            continue
        pos = re.search(r'position="(\d+)"', m.group(2))
        d[(m.group(1), pos.group(1) if pos else None)] = float(m.group(3))
    return d

a = load(sys.argv[1]); b = load(sys.argv[2])
g = lambda k, p=None: b.get((k, p), 0) - a.get((k, p), 0)
drafts = g("vllm:spec_decode_num_drafts_total")
dt = g("vllm:spec_decode_num_draft_tokens_total")
at = g("vllm:spec_decode_num_accepted_tokens_total")
print("drafts=%.0f draft_tokens=%.0f accepted=%.0f" % (drafts, dt, at))
print("acceptance rate = %.1f%%   accepted/step = %.2f   tok/step = %.2f" % (100*at/dt, at/drafts, 1+at/drafts))
key = "vllm:spec_decode_num_accepted_tokens_per_pos_total"
print("per-position: " + "  ".join("p%d=%.3f" % (i, g(key, str(i))/drafts) for i in range(5)))
