#!/bin/bash
# Simple vLLM Benchmark - Python timing for macOS compatibility
HOST="100.97.87.120"
PORT="8030"
MODEL="nemotron-3-super-tp2"
API="http://${HOST}:${PORT}"
SSH="ssh -i ~/.ssh/vgio -o StrictHostKeyChecking=no admin@${HOST}"

echo "=== vLLM Simple Benchmark ==="
echo "Model: ${MODEL}"
echo "Target: ${HOST}:${PORT}"
echo "Time: $(date)"
echo ""

run_test() {
    local test_name="$1"
    local prompt="$2"
    local max_tokens="$3"
    local runs="$4"
    
    echo "--- ${test_name} ---"
    for i in $(seq 1 $runs); do
        RESULT=$(python3 -c "
import subprocess, json, time

start = time.time()
try:
    cmd = '''curl -s -m 120 ${API}/v1/completions -H 'Content-Type: application/json' -d '{\"model\":\"${MODEL}\",\"prompt\":\"${prompt}\",\"max_tokens\":${max_tokens}}' '''
    resp = subprocess.check_output('${SSH} \"' + cmd + '\"', shell=True, stderr=subprocess.DEVNULL).decode()
    end = time.time()
    elapsed_ms = (end - start) * 1000
    
    data = json.loads(resp)
    tok = data['usage']['completion_tokens']
    prompt_tok = data['usage']['prompt_tokens']
    text = data['choices'][0]['text'][:50]
    tok_s = tok * 1000 / elapsed_ms if elapsed_ms > 0 else 0
    print(f'{elapsed_ms:.0f}|{prompt_tok}|{tok}|{tok_s:.1f}|{text}')
except Exception as e:
    print(f'ERROR|0|0|0|{str(e)[:50]}')
" 2>&1)
        printf "  Run %d: %s\n" $i "$RESULT" | sed 's/|/ | /g'
    done
    echo ""
}

run_test "Short (10 tokens)" "Hello" 10 5
run_test "Medium (50 tokens)" "Explain unified memory in GPU computing." 50 3
run_test "Long (200 tokens)" "Write a technical article about NVIDIA Blackwell architecture and FP4 quantization." 200 2

echo "=== Chat API Test ==="
python3 -c "
import subprocess, json, time

start = time.time()
cmd = '''curl -s -m 120 ${API}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"What is FP4 quantization?\"}],\"max_tokens\":100}' '''
resp = subprocess.check_output('${SSH} \"' + cmd + '\"', shell=True, stderr=subprocess.DEVNULL).decode()
end = time.time()
elapsed_ms = (end - start) * 1000

data = json.loads(resp)
tok = data['usage']['completion_tokens']
msg = data['choices'][0]['message']['content'][:100]
tok_s = tok * 1000 / elapsed_ms if elapsed_ms > 0 else 0
print(f'  Time: {elapsed_ms:.0f}ms | Output: {tok} tok | {tok_s:.1f} tok/s')
print(f'  Preview: \"{msg}...\"')
" 2>&1
echo ""

echo "=== Complete ==="
