#!/bin/bash
# vLLM Benchmark Script for DGX Spark (TP=2 cross-node)
# Tests: latency, throughput, long context performance

set -e

# Configuration
HOST="100.97.87.120"
PORT="8030"
MODEL="nemotron-3-super-tp2"
API="http://${HOST}:${PORT}"
SSH_KEY="~/.ssh/vgio"
SSH_CMD="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no admin@${HOST}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  vLLM Benchmark: nemotron-3-super-tp2${NC}"
echo -e "${BLUE}  Target: ${HOST}:${PORT}${NC}"
echo -e "${BLUE}  Date: $(date)${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# ========================================
# 0. Health Check
# ========================================
echo -e "${YELLOW}[0/5] Health Check...${NC}"
MODELS=$(${SSH_CMD} "curl -s ${API}/v1/models" 2>/dev/null)
MODEL_ID=$(echo "${MODELS}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null)
if [ -n "${MODEL_ID}" ]; then
    echo -e "  ${GREEN}✓ Service is healthy (Model: ${MODEL_ID})${NC}"
else
    echo -e "  ${RED}✗ Service not responding${NC}"
    exit 1
fi
echo ""

# ========================================
# 1. Short Prompt Latency (10 tokens)
# ========================================
echo -e "${YELLOW}[1/5] Short Prompt Latency (10 tokens)...${NC}"
for i in $(seq 1 5); do
    START=$(date +%s%N)
    RESULT=$(${SSH_CMD} "curl -s -w '\n%{time_total}' ${API}/v1/completions \
        -H 'Content-Type: application/json' \
        -d '{\"model\":\"${MODEL}\",\"prompt\":\"Hello\",\"max_tokens\":10}'" 2>/dev/null)
    END=$(date +%s%N)
    
    HTTP_TIME=$(echo "${RESULT}" | tail -1)
    RESPONSE=$(echo "${RESULT}" | head -1)
    ELAPSED=$(( (END - START) / 1000000 ))
    
    TEXT=$(echo "${RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['text'], end='')" 2>/dev/null || echo "N/A")
    TOTAL_TOKENS=$(echo "${RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['total_tokens'], end='')" 2>/dev/null || echo "0")
    COMPLETION_TOKENS=$(echo "${RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['completion_tokens'], end='')" 2>/dev/null || echo "0")
    
    echo -e "  Run ${i}: ${ELAPSED}ms (HTTP: ${HTTP_TIME}s) | Output: \"${TEXT}\" | Tokens: ${COMPLETION_TOKENS}"
done
echo ""

# ========================================
# 2. Medium Prompt (100 tokens generation)
# ========================================
echo -e "${YELLOW}[2/5] Medium Generation (100 tokens)...${NC}"
PROMPT="Explain the concept of unified memory architecture in GPU computing and how it differs from traditional discrete memory systems."

for i in $(seq 1 3); do
    START=$(date +%s%N)
    RESULT=$(${SSH_CMD} "curl -s -w '\n%{time_total}' ${API}/v1/completions \
        -H 'Content-Type: application/json' \
        -d '{\"model\":\"${MODEL}\",\"prompt\":\"${PROMPT}\",\"max_tokens\":100}'" 2>/dev/null)
    END=$(date +%s%N)
    
    HTTP_TIME=$(echo "${RESULT}" | tail -1)
    RESPONSE=$(echo "${RESULT}" | head -1)
    ELAPSED=$(( (END - START) / 1000000 ))
    
    COMPLETION_TOKENS=$(echo "${RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['completion_tokens'], end='')" 2>/dev/null || echo "0")
    PROMPT_TOKENS=$(echo "${RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['prompt_tokens'], end='')" 2>/dev/null || echo "0")
    
    # Calculate tokens per second
    if [ "${ELAPSED}" -gt 0 ]; then
        TOK_PER_SEC=$(echo "scale=1; ${COMPLETION_TOKENS} * 1000 / ${ELAPSED}" | bc 2>/dev/null || echo "N/A")
    else
        TOK_PER_SEC="N/A"
    fi
    
    echo -e "  Run ${i}: ${ELAPSED}ms (${TOK_PER_SEC} tok/s) | Prompt: ${PROMPT_TOKENS} tok, Output: ${COMPLETION_TOKENS} tok"
done
echo ""

# ========================================
# 3. Long Context (512 tokens generation)
# ========================================
echo -e "${YELLOW}[3/5] Long Generation (512 tokens)...${NC}"
PROMPT_LONG="Write a comprehensive technical article about NVIDIA's Blackwell architecture, including details about the GB10 chip, unified memory, FP4 quantization, MoE (Mixture of Experts) scaling, and how these technologies work together to enable efficient AI inference at scale."

START=$(date +%s%N)
RESULT=$(${SSH_CMD} "curl -s -w '\n%{time_total}' ${API}/v1/completions \
    -H 'Content-Type: application/json' \
    -d '{\"model\":\"${MODEL}\",\"prompt\":\"${PROMPT_LONG}\",\"max_tokens\":512}'" 2>/dev/null)
END=$(date +%s%N)

HTTP_TIME=$(echo "${RESULT}" | tail -1)
RESPONSE=$(echo "${RESULT}" | head -1)
ELAPSED=$(( (END - START) / 1000000 ))

COMPLETION_TOKENS=$(echo "${RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['completion_tokens'], end='')" 2>/dev/null || echo "0")
PROMPT_TOKENS=$(echo "${RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['prompt_tokens'], end='')" 2>/dev/null || echo "0")
TOTAL_TOKENS=$(echo "${RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['total_tokens'], end='')" 2>/dev/null || echo "0")

if [ "${ELAPSED}" -gt 0 ]; then
    TOK_PER_SEC=$(echo "scale=1; ${COMPLETION_TOKENS} * 1000 / ${ELAPSED}" | bc 2>/dev/null || echo "N/A")
else
    TOK_PER_SEC="N/A"
fi

echo -e "  Time: ${ELAPSED}ms (${TOK_PER_SEC} tok/s)"
echo -e "  Tokens: Prompt=${PROMPT_TOKENS}, Output=${COMPLETION_TOKENS}, Total=${TOTAL_TOKENS}"
echo -e "  HTTP Transfer: ${HTTP_TIME}s"
echo ""

# ========================================
# 4. Chat Completions API Test
# ========================================
echo -e "${YELLOW}[4/5] Chat Completions API (multi-turn)...${NC}"

# Single turn
START=$(date +%s%N)
RESULT=$(${SSH_CMD} "curl -s ${API}/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"What are the advantages of FP4 quantization?\"}],\"max_tokens\":150}'" 2>/dev/null)
END=$(date +%s%N)
ELAPSED=$(( (END - START) / 1000000 ))

RESPONSE=$(echo "${RESULT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'][:100], end=''); print('...'); print(f\"Tokens: {d['usage']['completion_tokens']}\")" 2>/dev/null || echo "N/A")
echo -e "  Single turn (${ELAPSED}ms):"
echo -e "  ${RESPONSE}"
echo ""

# ========================================
# 5. Concurrent Requests (Throughput)
# ========================================
echo -e "${YELLOW}[5/5] Concurrent Throughput (3 parallel requests)...${NC}"
START=$(date +%s%N)

${SSH_CMD} "curl -s ${API}/v1/completions -H 'Content-Type: application/json' -d '{\"model\":\"${MODEL}\",\"prompt\":\"Test 1:\",\"max_tokens\":50}' > /dev/null 2>&1 &"
${SSH_CMD} "curl -s ${API}/v1/completions -H 'Content-Type: application/json' -d '{\"model\":\"${MODEL}\",\"prompt\":\"Test 2:\",\"max_tokens\":50}' > /dev/null 2>&1 &"
${SSH_CMD} "curl -s ${API}/v1/completions -H 'Content-Type: application/json' -d '{\"model\":\"${MODEL}\",\"prompt\":\"Test 3:\",\"max_tokens\":50}' > /dev/null 2>&1 &"

wait
END=$(date +%s%N)
ELAPSED=$(( (END - START) / 1000000 ))

echo -e "  3 requests completed in: ${ELAPSED}ms"
echo -e "  Effective throughput: $(echo "scale=1; 3 * 1000 / ${ELAPSED}" | bc 2>/dev/null || echo "N/A") req/s"
echo ""

# ========================================
# Summary
# ========================================
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Benchmark Complete${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "  ${GREEN}Model:${NC} nemotron-3-super-tp2 (FP4, Marlin)"
echo -e "  ${GREEN}Architecture:${NC} TP=2 cross-node (100.97.87.120 + 100.67.164.92)"
echo -e "  ${GREEN}GPU Memory:${NC} 75% utilization"
echo -e "  ${GREEN}KV Cache:${NC} FP8"
echo -e "  ${GREEN}Max Context:${NC} 32,768 tokens"
echo ""
