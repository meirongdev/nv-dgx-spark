#!/bin/bash
# Unified Memory Monitor for DGX Spark (GB10)
# Monitors memory fragmentation, utilization, and OOM risks
#
# Usage: ./scripts/monitor-unified-memory.sh [interval_seconds]
# Example: ./scripts/monitor-unified-memory.sh 5

set -e

INTERVAL=${1:-5}
LOG_FILE="${HOME}/vllm-memory-$(date +%Y%m%d-%H%M%S).log"
WARNING_THRESHOLD=85
CRITICAL_THRESHOLD=95

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}DGX Spark Unified Memory Monitor${NC}"
echo -e "${BLUE}Interval: ${INTERVAL}s | Log: ${LOG_FILE}${NC}"
echo -e "${BLUE}Press Ctrl+C to stop${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

# Log header
echo "Timestamp | Mem Total | Mem Used | Mem Available | Mem % | GPU % | GPU Mem | Status" | tee "$LOG_FILE"
echo "----------|-----------|----------|---------------|-------|-------|---------|-------" | tee -a "$LOG_FILE"

monitor_memory() {
    while true; do
        # Get memory info
        mem_info=$(free -m | grep Mem)
        mem_total=$(echo "$mem_info" | awk '{print $2}')
        mem_used=$(echo "$mem_info" | awk '{print $3}')
        mem_available=$(echo "$mem_info" | awk '{print $7}')
        mem_percent=$((mem_used * 100 / mem_total))

        # Get GPU info
        gpu_info=$(nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader 2>/dev/null || echo "0, N/A")
        gpu_util=$(echo "$gpu_info" | cut -d',' -f1 | tr -d ' ')
        gpu_mem=$(echo "$gpu_info" | cut -d',' -f2 | tr -d ' ')

        # Determine status
        if [ "$mem_percent" -ge "$CRITICAL_THRESHOLD" ]; then
            status="${RED}CRITICAL${NC}"
            status_text="CRITICAL"
        elif [ "$mem_percent" -ge "$WARNING_THRESHOLD" ]; then
            status="${YELLOW}WARNING${NC}"
            status_text="WARNING"
        else
            status="${GREEN}OK${NC}"
            status_text="OK"
        fi

        # Get timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')

        # Display
        printf "%s | %6dM | %6dM | %6dM | %3d%% | %3s%% | %6s | %b\n" \
            "$timestamp" "$mem_total" "$mem_used" "$mem_available" \
            "$mem_percent" "$gpu_util" "$gpu_mem" "$status" | tee -a "$LOG_FILE"

        # Check for vLLM container
        if docker ps --filter name=vllm-server --format '{{.Names}}' 2>/dev/null | grep -q vllm-server; then
            # Get container memory usage
            container_mem=$(docker stats vllm-server --no-stream --format '{{.MemUsage}}' 2>/dev/null || echo "N/A")
            echo "  └─ vLLM Container: $container_mem" | tee -a "$LOG_FILE"
        fi

        # Check swap usage
        swap_used=$(free -m | grep Swap | awk '{print $3}')
        if [ "$swap_used" -gt 0 ]; then
            echo -e "  ${RED}⚠ WARNING: Swap is enabled and in use! This will cause performance issues.${NC}" | tee -a "$LOG_FILE"
        fi

        # Alert on critical
        if [ "$mem_percent" -ge "$CRITICAL_THRESHOLD" ]; then
            echo -e "  ${RED}🚨 CRITICAL: Memory usage above ${CRITICAL_THRESHOLD}%! Consider reducing batch size or stopping vLLM.${NC}" | tee -a "$LOG_FILE"
        fi

        sleep "$INTERVAL"
    done
}

# Cleanup on exit
trap 'echo -e "\n${BLUE}Monitor stopped. Log saved to: ${LOG_FILE}${NC}"; exit 0' INT TERM

# Start monitoring
monitor_memory
