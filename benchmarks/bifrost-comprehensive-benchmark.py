#!/usr/bin/env python3
"""Comprehensive Bifrost + vLLM Benchmark for DGX Spark Cluster"""

import requests
import json
import time
import sys
import statistics

BASE_URL = "http://100.97.87.120:8080/v1"
SERVER1 = "vllm-server1/nemotron-3-super"
SERVER2 = "vllm-server2/nemotron-3-super"
HEADERS = {"Content-Type": "application/json"}

def chat_completion(model, prompt, max_tokens=100, timeout=180):
    """Send chat completion request through Bifrost"""
    start = time.time()
    resp = requests.post(
        f"{BASE_URL}/chat/completions",
        headers=HEADERS,
        json={
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "temperature": 0.7
        },
        timeout=timeout
    )
    elapsed_ms = (time.time() - start) * 1000
    data = resp.json()
    
    if "error" in data:
        return None, None, None, data["error"]
    
    choice = data["choices"][0]["message"]
    text = choice.get("content") or choice.get("reasoning", "")
    completion_tokens = data["usage"]["completion_tokens"]
    prompt_tokens = data["usage"]["prompt_tokens"]
    tok_per_sec = completion_tokens * 1000 / elapsed_ms if elapsed_ms > 0 else 0
    
    return elapsed_ms, completion_tokens, tok_per_sec, text[:80]

def run_benchmark(name, model, prompt, max_tokens, runs=3, warmup=True):
    """Run benchmark with multiple iterations"""
    print(f"\n{'='*60}")
    print(f"  {name}")
    print(f"  Model: {model.split('/')[-1]} | Target: {max_tokens} tokens")
    print(f"{'='*60}")
    
    results = []
    
    # Warmup
    if warmup:
        print("  Warming up...")
        chat_completion(model, "Hello", max_tokens=10, timeout=60)
        time.sleep(1)
    
    for i in range(1, runs + 1):
        elapsed_ms, tok, tok_s, text_or_err = chat_completion(model, prompt, max_tokens)
        
        if tok is None:
            print(f"  Run {i}: ERROR - {text_or_err.get('message', 'Unknown')}")
            results.append(None)
        else:
            print(f"  Run {i}: {elapsed_ms:6.0f}ms | {tok:3d} tok | {tok_s:5.1f} tok/s | \"{text_or_err}...\"")
            results.append({
                "elapsed_ms": elapsed_ms,
                "tokens": tok,
                "tok_per_sec": tok_s
            })
        
        time.sleep(1)  # Avoid overwhelming the server
    
    # Summary
    valid = [r for r in results if r is not None]
    if valid:
        avg_ms = statistics.mean(r["elapsed_ms"] for r in valid)
        avg_tok_s = statistics.mean(r["tok_per_sec"] for r in valid)
        median_ms = statistics.median(r["elapsed_ms"] for r in valid)
        p95_ms = sorted(r["elapsed_ms"] for r in valid)[int(len(valid)*0.95)] if len(valid) > 1 else valid[0]["elapsed_ms"]
        
        print(f"\n  SUMMARY:")
        print(f"    Avg:    {avg_ms:6.0f}ms | {avg_tok_s:5.1f} tok/s")
        print(f"    Median: {median_ms:6.0f}ms")
        print(f"    P95:    {p95_ms:6.0f}ms")
    
    return results

def main():
    print("=" * 60)
    print("  DGX Spark Cluster Benchmark")
    print(f"  Time: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  Gateway: {BASE_URL}")
    print("=" * 60)
    
    # Check services
    print("\n[Service Health Check]")
    try:
        resp = requests.get(f"{BASE_URL.replace('/v1', '')}/api/health", timeout=5)
        print(f"  ✓ Bifrost Gateway: healthy")
    except:
        print(f"  ✗ Bifrost Gateway: unreachable")
        sys.exit(1)
    
    for i, srv in enumerate([SERVER1, SERVER2], 1):
        try:
            resp = requests.post(f"{BASE_URL}/chat/completions",
                headers=HEADERS,
                json={"model": srv, "messages": [{"role": "user", "content": "test"}], "max_tokens": 5},
                timeout=30)
            if resp.status_code == 200:
                print(f"  ✓ Server {i} ({srv.split('/')[0]}): healthy")
            else:
                print(f"  ✗ Server {i}: status {resp.status_code}")
        except Exception as e:
            print(f"  ✗ Server {i}: {e}")
    
    all_results = {}
    
    # Test 1: Short generation (20 tokens)
    all_results["short_20_s1"] = run_benchmark(
        "Short Generation - Server 1",
        SERVER1,
        "Say hello in one sentence.",
        max_tokens=20,
        runs=5
    )
    
    all_results["short_20_s2"] = run_benchmark(
        "Short Generation - Server 2",
        SERVER2,
        "Say hello in one sentence.",
        max_tokens=20,
        runs=5
    )
    
    # Test 2: Medium generation (100 tokens)
    all_results["medium_100_s1"] = run_benchmark(
        "Medium Generation - Server 1",
        SERVER1,
        "Explain the concept of unified memory architecture in GPU computing. How does it differ from traditional discrete memory systems?",
        max_tokens=100,
        runs=3
    )
    
    all_results["medium_100_s2"] = run_benchmark(
        "Medium Generation - Server 2",
        SERVER2,
        "Explain the concept of unified memory architecture in GPU computing. How does it differ from traditional discrete memory systems?",
        max_tokens=100,
        runs=3
    )
    
    # Test 3: Long generation (300 tokens)
    all_results["long_300_s1"] = run_benchmark(
        "Long Generation - Server 1",
        SERVER1,
        "Write a comprehensive technical article about NVIDIA's Blackwell architecture, including details about the GB10 chip, unified memory, FP4 quantization, MoE (Mixture of Experts) scaling, and how these technologies work together to enable efficient AI inference at scale.",
        max_tokens=300,
        runs=2
    )
    
    # Test 4: Concurrent requests (throughput)
    print(f"\n{'='*60}")
    print(f"  Concurrent Throughput Test")
    print(f"  5 parallel requests to each server")
    print(f"{'='*60}")
    
    for srv, name in [(SERVER1, "Server 1"), (SERVER2, "Server 2")]:
        import concurrent.futures
        
        def make_request(idx):
            return chat_completion(srv, f"Request {idx}: Count to 10.", max_tokens=20, timeout=60)
        
        start = time.time()
        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:
            futures = [executor.submit(make_request, i) for i in range(5)]
            concurrent_results = [f.result() for f in concurrent.futures.as_completed(futures)]
        total_elapsed_ms = (time.time() - start) * 1000
        
        valid = [r for r in concurrent_results if r[1] is not None]
        if valid:
            avg_tok_s = statistics.mean(r[2] for r in valid)
            print(f"\n  {name} (5 concurrent):")
            print(f"    Total time: {total_elapsed_ms:.0f}ms")
            print(f"    Successful: {len(valid)}/5")
            print(f"    Avg throughput: {avg_tok_s:.1f} tok/s")
            print(f"    Effective throughput: {sum(r[1] for r in valid) * 1000 / total_elapsed_ms:.1f} tok/s")
    
    # Final Summary
    print(f"\n{'='*60}")
    print(f"  FINAL SUMMARY")
    print(f"{'='*60}")
    print(f"  {'Test':<35} {'Avg ms':>8} {'Avg tok/s':>10} {'Success':>8}")
    print(f"  {'-'*35} {'-'*8} {'-'*10} {'-'*8}")
    
    for name, results in all_results.items():
        valid = [r for r in results if r is not None]
        if valid:
            avg_ms = statistics.mean(r["elapsed_ms"] for r in valid)
            avg_tok_s = statistics.mean(r["tok_per_sec"] for r in valid)
            success = f"{len(valid)}/{len(results)}"
            print(f"  {name:<35} {avg_ms:>7.0f} {avg_tok_s:>9.1f} {success:>8}")
    
    print(f"\n{'='*60}")
    print(f"  Model: NVIDIA Nemotron-3-Super-120B-A12B-NVFP4")
    print(f"  Quantization: FP4 (Marlin)")
    print(f"  GPU: GB10 Blackwell (128GB unified memory)")
    print(f"  GPU Memory: 75% utilization")
    print(f"{'='*60}")

if __name__ == "__main__":
    main()
