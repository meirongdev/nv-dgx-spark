#!/usr/bin/env python3
"""vLLM Benchmark - Runs directly on the remote server to avoid SSH latency issues"""

import subprocess
import json
import time
import sys

HOST = "100.97.87.120"
PORT = 8030
MODEL = "nemotron-3-super-tp2"
SSH = f"ssh -i ~/.ssh/vgio -o StrictHostKeyChecking=no admin@{HOST}"

def run_remote(cmd):
    """Run command on remote server via SSH"""
    full_cmd = f'{SSH} "{cmd}"'
    result = subprocess.run(full_cmd, shell=True, capture_output=True, text=True, timeout=180)
    return result.stdout.strip()

def benchmark(name, prompt_text, max_tokens, runs=3):
    """Run benchmark tests"""
    print(f"\n--- {name} (max_tokens={max_tokens}) ---")
    
    results = []
    for i in range(1, runs + 1):
        # Use local curl on remote server (no SSH data transfer overhead)
        curl_cmd = f"curl -s -m 180 http://localhost:{PORT}/v1/completions -H 'Content-Type: application/json' -d '{{\"model\":\"{MODEL}\",\"prompt\":\"{prompt_text}\",\"max_tokens\":{max_tokens}}}'"
        
        start = time.time()
        resp = run_remote(curl_cmd)
        elapsed_ms = (time.time() - start) * 1000
        
        try:
            data = json.loads(resp)
            completion_tokens = data['usage']['completion_tokens']
            prompt_tokens = data['usage']['prompt_tokens']
            text = data['choices'][0]['text'][:60].replace('\n', '\\n')
            tok_per_sec = completion_tokens * 1000 / elapsed_ms if elapsed_ms > 0 else 0
            
            print(f"  Run {i}: {elapsed_ms:6.0f}ms | Prompt: {prompt_tokens:3d} tok | Output: {completion_tokens:3d} tok | {tok_per_sec:5.1f} tok/s | \"{text}\"")
            results.append({
                'elapsed_ms': elapsed_ms,
                'prompt_tokens': prompt_tokens,
                'completion_tokens': completion_tokens,
                'tok_per_sec': tok_per_sec
            })
        except (json.JSONDecodeError, KeyError) as e:
            print(f"  Run {i}: ERROR - {resp[:80]}")
            results.append(None)
    
    # Summary
    valid = [r for r in results if r is not None]
    if valid:
        avg_ms = sum(r['elapsed_ms'] for r in valid) / len(valid)
        avg_tok_s = sum(r['tok_per_sec'] for r in valid) / len(valid)
        print(f"  AVG:    {avg_ms:6.0f}ms | {avg_tok_s:5.1f} tok/s")
    
    return results

def main():
    print("=" * 60)
    print("  vLLM Benchmark: nemotron-3-super-tp2")
    print(f"  Target: {HOST}:{PORT}")
    print(f"  Time: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)
    
    # Health check
    print("\n[Health Check]")
    health = run_remote(f"curl -s http://localhost:{PORT}/v1/models")
    try:
        data = json.loads(health)
        model_id = data['data'][0]['id']
        max_len = data['data'][0]['max_model_len']
        print(f"  ✓ Model: {model_id} (max_len={max_len})")
    except:
        print(f"  ✗ Failed to connect: {health[:100]}")
        sys.exit(1)
    
    # Run benchmarks
    all_results = {}
    
    all_results['short_10'] = benchmark(
        "Short Generation",
        "Hello",
        max_tokens=10,
        runs=5
    )
    
    all_results['medium_50'] = benchmark(
        "Medium Generation",
        "Explain the concept of unified memory architecture in GPU computing.",
        max_tokens=50,
        runs=3
    )
    
    all_results['long_200'] = benchmark(
        "Long Generation",
        "Write a comprehensive technical article about NVIDIA Blackwell architecture, FP4 quantization, and MoE scaling.",
        max_tokens=200,
        runs=2
    )
    
    # Chat API test
    print(f"\n--- Chat Completions API ---")
    curl_cmd = f"curl -s -m 180 http://localhost:{PORT}/v1/chat/completions -H 'Content-Type: application/json' -d '{{\"model\":\"{MODEL}\",\"messages\":[{{\"role\":\"user\",\"content\":\"What are the advantages of FP4 quantization for AI inference?\"}}],\"max_tokens\":100}}'"
    
    start = time.time()
    resp = run_remote(curl_cmd)
    elapsed_ms = (time.time() - start) * 1000
    
    try:
        data = json.loads(resp)
        tok = data['usage']['completion_tokens']
        msg = data['choices'][0]['message']['content'][:100].replace('\n', '\\n')
        tok_s = tok * 1000 / elapsed_ms if elapsed_ms > 0 else 0
        print(f"  Time: {elapsed_ms:6.0f}ms | Output: {tok:3d} tok | {tok_s:5.1f} tok/s")
        print(f"  Preview: \"{msg}...\"")
    except:
        print(f"  ERROR: {resp[:100]}")
    
    # Summary
    print("\n" + "=" * 60)
    print("  SUMMARY")
    print("=" * 60)
    print(f"  Model:          nemotron-3-super-tp2 (FP4, Marlin)")
    print(f"  Architecture:   TP=2 cross-node")
    print(f"  GPU Memory:     75% utilization")
    print(f"  KV Cache:       FP8")
    print(f"  Max Context:    32,768 tokens")
    print()
    
    for name, results in all_results.items():
        valid = [r for r in results if r is not None]
        if valid:
            avg_tok_s = sum(r['tok_per_sec'] for r in valid) / len(valid)
            avg_ms = sum(r['elapsed_ms'] for r in valid) / len(valid)
            avg_tok = sum(r['completion_tokens'] for r in valid) / len(valid)
            print(f"  {name:20s} | {avg_ms:6.0f}ms avg | {avg_tok:5.1f} tok | {avg_tok_s:5.1f} tok/s")
    
    print("\n" + "=" * 60)

if __name__ == "__main__":
    main()
