#!/usr/bin/env python3
"""Apply local patches to SWE-bench for DeepSeek-V4-Flash eval on aarch64.

Patch A: harness auto-detects arm64 host -> builds linux/arm64/v8 images.
Patch B: run_api.py accepts the custom model name deepseek-v4-flash
         (context limit, zero-cost table, tiktoken encoding, dispatch).
Idempotent: re-running is a no-op.
"""

import sys
from pathlib import Path

ROOT = Path("/home/admin/swebench-eval")
MODEL = "deepseek-v4-flash"


def sub(text, old, new, label):
    if new in text:
        print(f"  [skip] {label} (already applied)")
        return text
    if old not in text:
        sys.exit(f"  [FAIL] {label}: anchor not found")
    if text.count(old) != 1:
        sys.exit(f"  [FAIL] {label}: anchor matched {text.count(old)} times, want 1")
    print(f"  [ok]   {label}")
    return text.replace(old, new)


# ---------------- Patch A: test_spec.py ----------------
p = ROOT / "swebench/harness/test_spec/test_spec.py"
t = p.read_text()
print("Patch A:", p)

t = sub(t, "import hashlib\nimport json\n", "import hashlib\nimport json\nimport platform\n",
        "import platform")

t = sub(
    t,
    """    if isinstance(dataset[0], TestSpec):
        return cast(list[TestSpec], dataset)
    return list(
        map(
            lambda x: make_test_spec(x, namespace, instance_image_tag, env_image_tag),
            cast(list[SWEbenchInstance], dataset),
        )
    )""",
    """    if isinstance(dataset[0], TestSpec):
        return cast(list[TestSpec], dataset)
    # local patch (2026-08-01): build native arm64 images on ARM hosts (GB10 / DGX Spark).
    # Upstream hardcodes the x86_64 default; no prebuilt arm64 images exist on Docker Hub.
    host_machine = platform.machine().lower()
    arch = "arm64" if host_machine in ("aarch64", "arm64") else "x86_64"
    return list(
        map(
            lambda x: make_test_spec(
                x, namespace, instance_image_tag, env_image_tag, arch=arch
            ),
            cast(list[SWEbenchInstance], dataset),
        )
    )""",
    "arm64 auto-detect (get_test_specs_from_dataset)",
)

# run_evaluation.py / reporting.py / prepare_images.py call make_test_spec()
# directly, bypassing get_test_specs_from_dataset, so the default must also
# detect the host arch or those paths silently fall back to x86_64.
t = sub(
    t,
    """    instance_image_tag: str = LATEST,
    arch: str = "x86_64",
) -> TestSpec:
    if isinstance(instance, TestSpec):
        return instance""",
    """    instance_image_tag: str = LATEST,
    arch: Optional[str] = None,
) -> TestSpec:
    if isinstance(instance, TestSpec):
        return instance
    if arch is None:
        # local patch (2026-08-01): default to the host arch instead of x86_64.
        host_machine = platform.machine().lower()
        arch = "arm64" if host_machine in ("aarch64", "arm64") else "x86_64\"""",
    "arm64 auto-detect (make_test_spec default)",
)
p.write_text(t)

# ---------------- Patch B: run_api.py ----------------
p = ROOT / "swebench/inference/run_api.py"
t = p.read_text()
print("Patch B:", p)

t = sub(t, '    "gpt-4-0125-preview": 128_000,\n}',
        f'    "gpt-4-0125-preview": 128_000,\n    "{MODEL}": 200_000,\n}}',
        "MODEL_LIMITS entry")

# zero-cost entries: calc_cost() does a bare dict lookup and lives inside a
# @retry, so a KeyError here burns 3 retries with long backoff then crashes.
for table in ("MODEL_COST_PER_INPUT", "MODEL_COST_PER_OUTPUT"):
    start = t.index(f"{table} = {{")
    end = t.index("\n}", start)
    block = t[start:end]
    if f'"{MODEL}"' in block:
        print(f"  [skip] {table} entry (already applied)")
        continue
    t = t[:end] + f'\n    "{MODEL}": 0.0,  # local: self-hosted vLLM, no per-token cost' + t[end:]
    print(f"  [ok]   {table} entry")

t = sub(t,
        "    encoding = tiktoken.encoding_for_model(model_name_or_path)",
        '    # local patch: tiktoken has no mapping for self-hosted model names; cl100k_base\n'
        '    # is only used to approximate length for the MODEL_LIMITS filter.\n'
        '    try:\n'
        '        encoding = tiktoken.encoding_for_model(model_name_or_path)\n'
        '    except KeyError:\n'
        '        encoding = tiktoken.get_encoding("cl100k_base")',
        "tiktoken fallback encoding")

t = sub(t,
        '    elif model_name_or_path.startswith("gpt"):',
        f'    elif model_name_or_path.startswith("gpt") or model_name_or_path == "{MODEL}":',
        "dispatch to openai_inference")

p.write_text(t)

# ---------------- Patch C: utils.py (cached env yml is x86_64-only) ----------------
# The bundled swebench-og/*/environment.yml files are full `conda env export`
# snapshots taken on x86_64: every dep carries an x86_64 build string
# (py39h06a4308_0, h5eee18b_0, ld_impl_linux-64...) that does not exist for
# linux-aarch64, so `conda env create` fails with PackagesNotFoundError.
# Ignoring the cache on ARM falls through to the spec-driven path
# (MAP_REPO_VERSION_TO_SPECS: python=X + packages + pip_packages), which is
# arch-portable. Verified against gold patches before trusting any results.
p = ROOT / "swebench/harness/utils.py"
t = p.read_text()
print("Patch C:", p)

if "import platform" not in t.split("def ")[0]:
    t = sub(t, "import json\n", "import json\nimport platform\n", "import platform")
else:
    print("  [skip] import platform (already present)")

t = sub(
    t,
    '''    """
    Load environment.yml from cache
    """
    try:
        repo, number = instance_id.rsplit("-", 1)''',
    '''    """
    Load environment.yml from cache
    """
    # local patch (2026-08-01): the cached ymls are x86_64 `conda env export`
    # snapshots with arch-specific build strings; unusable on aarch64.
    if platform.machine().lower() in ("aarch64", "arm64"):
        return None
    try:
        repo, number = instance_id.rsplit("-", 1)''',
    "skip x86_64 cached env yml on ARM",
)
p.write_text(t)

# ---------------- Patch D: python.py (stale pinned clone branches) ----------------
# REPO_BASE_COMMIT_BRANCH pins a release branch per base commit, but some upstreams
# have since deleted those branches (sympy 1.7 -> "Remote branch 1.7 not found"),
# which fails the instance image build. Fall back to a full clone and, if needed,
# fetch all refs so the base commit is present.
#
# This does NOT weaken the "no future commits" guard further down that script:
# `git remote remove origin` drops the remote-tracking refs, and a clone only ever
# creates one local branch, which `git reset --hard <base_commit>` pins to the base
# commit -- so `git log --all` still ends at the base commit.
p = ROOT / "swebench/harness/test_spec/python.py"
t = p.read_text()
print("Patch D:", p)

t = sub(
    t,
    '''        f"git clone -o origin {branch} --single-branch https://github.com/{repo} {repo_directory}",
        f"chmod -R 777 {repo_directory}",  # So nonroot user can run tests
        f"cd {repo_directory}",
        f"git reset --hard {base_commit}",''',
    '''        # local patch (2026-08-01): pinned release branches are gone from some upstreams.
        f"git clone -o origin {branch} --single-branch https://github.com/{repo} {repo_directory}"
        f" || {{ cd / && rm -rf {repo_directory}; git clone -o origin https://github.com/{repo} {repo_directory}; }}",
        f"chmod -R 777 {repo_directory}",  # So nonroot user can run tests
        f"cd {repo_directory}",
        # local patch: make sure the base commit exists even if it was not on the cloned branch.
        f"git cat-file -e {base_commit}^{{commit}} 2>/dev/null"
        f" || {{ git remote set-branches origin '*'; git fetch -q --all --tags; }}",
        f"git reset --hard {base_commit}",''',
    "resilient repo clone",
)
p.write_text(t)

# ---------------- Patch E: utils.py network timeout ----------------
# get_repo_file() fetches requirements.txt / environment.yml from
# raw.githubusercontent.com with no timeout, so a single stalled connection
# (common from CN) hangs the whole evaluation forever with no log output.
# Patch C makes this path much hotter, since specs are now resolved from the
# repo instead of the bundled x86_64 conda snapshot.
p = ROOT / "swebench/harness/utils.py"
t = p.read_text()
print("Patch E:", p)

t = sub(
    t,
    """    url = f"https://raw.githubusercontent.com/{repo}/{commit}/{filepath}"
    try:
        response = requests.get(url)
        if response.status_code == 200:
            return response.text
        return None
    except:
        return None""",
    """    url = f"https://raw.githubusercontent.com/{repo}/{commit}/{filepath}"
    # local patch (2026-08-01): bounded timeout + retries. Upstream has neither,
    # and a stalled fetch blocks the entire run with no output.
    for attempt in range(3):
        try:
            response = requests.get(url, timeout=(10, 30))
            if response.status_code == 200:
                return response.text
            return None
        except Exception:
            if attempt == 2:
                return None
            time.sleep(2 * (attempt + 1))
    return None""",
    "bounded timeout + retry on repo file fetch",
)

if "\nimport time" not in t and not t.startswith("import time"):
    t = sub(t, "import json\nimport platform\n", "import json\nimport platform\nimport time\n",
            "import time")
else:
    print("  [skip] import time (already present)")
p.write_text(t)

# ---------------- Patch E2: python.py network timeouts ----------------
# Three more unbounded requests.get(reqs_url, headers=HEADERS) calls fetch
# requirements files from raw.githubusercontent.com while building the env
# scripts. Same failure mode as Patch E: one stalled connection hangs the whole
# run in build_env_images with zero log output. Patched at the call sites.
p = ROOT / "swebench/harness/test_spec/python.py"
t = p.read_text()
print("Patch E2:", p)

HELPER = '''

# --- local patch (2026-08-01): resilient requirements fetch -------------------
# Upstream calls requests.get(reqs_url, headers=HEADERS) with no timeout. From
# CN, raw.githubusercontent.com stalls intermittently, which hung the whole
# evaluation with no log output. A bare timeout is not enough either: these
# fetches run inside get_test_specs_from_dataset for every instance up front,
# so a single ReadTimeout aborts the entire run. Retry with backoff and cache
# responses on disk so reruns are fast and do not depend on the network.
_REQS_CACHE_DIR = os.environ.get(
    "SWEBENCH_REQS_CACHE", os.path.expanduser("~/.cache/swebench-reqs")
)


def _get_url_cached(url, headers=None, attempts=8):
    import hashlib as _hashlib
    import time as _time

    key = _hashlib.sha256(url.encode()).hexdigest()
    path = os.path.join(_REQS_CACHE_DIR, key)
    if os.path.exists(path):
        with open(path, "r") as fh:
            body = fh.read()
        return _CachedResponse(200 if body != "\\0__404__" else 404, body)

    last = None
    for i in range(attempts):
        try:
            r = requests.get(url, headers=headers, timeout=(10, 30))
            if r.status_code in (200, 404):
                os.makedirs(_REQS_CACHE_DIR, exist_ok=True)
                with open(path, "w") as fh:
                    fh.write(r.text if r.status_code == 200 else "\\0__404__")
                return r
            last = Exception(f"HTTP {r.status_code}")
        except Exception as e:  # network stall / reset
            last = e
        _time.sleep(min(2 ** i, 30))
    raise RuntimeError(f"failed to fetch {url} after {attempts} attempts: {last}")


class _CachedResponse:
    def __init__(self, status_code, text):
        self.status_code = status_code
        self.text = "" if text == "\\0__404__" else text
# -----------------------------------------------------------------------------
'''

old_call = "reqs = requests.get(reqs_url, headers=HEADERS)"
new_call = "reqs = _get_url_cached(reqs_url, headers=HEADERS)"
# also normalise the earlier bounded-timeout variant if this script ran before
t = t.replace(
    "reqs = requests.get(reqs_url, headers=HEADERS, timeout=(10, 30))  # local patch: bounded",
    old_call,
)
n = t.count(old_call)
if n:
    t = t.replace(old_call, new_call)
    print(f"  [ok]   retrying cached fetch at {n} call sites")
elif new_call in t:
    print(f"  [skip] requirements fetch ({t.count(new_call)} sites already patched)")
else:
    sys.exit("  [FAIL] Patch E2: anchor not found")

if "_get_url_cached" not in t.split("def make_repo_script_list_py")[0][:4000]:
    pass
if "def _get_url_cached" not in t:
    anchor = "from functools import cache\n"
    if anchor not in t:
        sys.exit("  [FAIL] Patch E2: helper anchor not found")
    t = t.replace(anchor, anchor + HELPER, 1)
    print("  [ok]   inserted _get_url_cached helper")
else:
    print("  [skip] _get_url_cached helper (already present)")
p.write_text(t)

print("\nAll patches applied.")
