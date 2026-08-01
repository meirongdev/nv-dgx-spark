checks = [
 ("A1 arch autodetect (get_test_specs)", "swebench/harness/test_spec/test_spec.py", "host_machine = platform.machine().lower()"),
 ("A2 make_test_spec arch=None",         "swebench/harness/test_spec/test_spec.py", "arch: Optional[str] = None"),
 ("B  model context limit",              "swebench/inference/run_api.py",           '"deepseek-v4-flash": 200_000'),
 ("B  zero cost tables",                 "swebench/inference/run_api.py",           '"deepseek-v4-flash": 0.0'),
 ("C  skip x86 env yml on ARM",          "swebench/harness/utils.py",               'if platform.machine().lower() in ("aarch64", "arm64"):'),
 ("D  resilient clone",                  "swebench/harness/test_spec/python.py",    "cd / && rm -rf"),
 ("D  base commit fetch guard",          "swebench/harness/test_spec/python.py",    "git cat-file -e"),
 ("E  utils timeout",                    "swebench/harness/utils.py",               "timeout=(10, 30)"),
 ("E2 cached retry fetch",               "swebench/harness/test_spec/python.py",    "def _get_url_cached"),
]
for name, path, needle in checks:
    ok = needle in open(path).read()
    print(("OK      " if ok else "MISSING ") + name)
