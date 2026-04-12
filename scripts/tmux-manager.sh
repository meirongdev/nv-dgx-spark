#!/bin/bash
# ========================================
# tmux Session Manager for DGX Spark
# ========================================
# Helper script for managing tmux sessions
# on remote DGX Spark servers.
#
# Usage:
#   ./scripts/tmux-manager.sh <host> <action> [session_name] [command]
#
# Actions:
#   new     - Create a new tmux session with a command
#   attach  - Attach to an existing session
#   list    - List all tmux sessions
#   kill    - Kill a tmux session
#   status  - Show session status
#
# Examples:
#   ./scripts/tmux-manager.sh 100.97.87.120 new vllm-deploy "docker logs -f vllm-server"
#   ./scripts/tmux-manager.sh 100.97.87.120 attach vllm-deploy
#   ./scripts/tmux-manager.sh 100.97.87.120 list
#   ./scripts/tmux-manager.sh 100.97.87.120 kill vllm-deploy
#
# References:
#   - W&B ML Practitioner Guide: https://wandb.ai/wandb_course/extras/reports/TMUX-Basic-Usage-for-ML-Practitioners--VmlldzoyMjgyMDIx
#   - DataMade Best Practices: https://github.com/datamade/how-to/blob/main/shell/tmux-best-practices.md
# ========================================

set -e

# Configuration
SSH_KEY="${SSH_KEY:-/Users/matthew/.ssh/vgio}"
SSH_USER="${SSH_USER:-admin}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

usage() {
    echo "Usage: $0 <host> <action> [session_name] [command]"
    echo ""
    echo "Actions:"
    echo "  new     - Create a new tmux session with a command"
    echo "  attach  - Attach to an existing session"
    echo "  list    - List all tmux sessions"
    echo "  kill    - Kill a tmux session"
    echo "  status  - Show session status"
    echo ""
    echo "Examples:"
    echo "  $0 100.97.87.120 new vllm-deploy 'docker logs -f vllm-server'"
    echo "  $0 100.97.87.120 attach vllm-deploy"
    echo "  $0 100.97.87.120 list"
    echo "  $0 100.97.87.120 kill vllm-deploy"
    exit 1
}

# Validate arguments
if [ $# -lt 2 ]; then
    usage
fi

HOST="$1"
ACTION="$2"
SESSION_NAME="$3"
COMMAND="$4"

SSH_CMD="ssh -i ${SSH_KEY} ${SSH_USER}@${HOST}"

case "$ACTION" in
    new)
        if [ -z "$SESSION_NAME" ] || [ -z "$COMMAND" ]; then
            print_error "Session name and command are required for 'new' action"
            usage
        fi
        
        print_header "Creating tmux session: $SESSION_NAME on $HOST"
        
        # Create tmux session (kill existing one with same name if exists)
        $SSH_CMD "tmux kill-session -t ${SESSION_NAME} 2>/dev/null || true"
        $SSH_CMD "tmux new-session -d -s ${SESSION_NAME} '${COMMAND}'"
        
        print_success "tmux session '${SESSION_NAME}' created on ${HOST}"
        echo ""
        echo "Reattach with:"
        echo "  $0 ${HOST} attach ${SESSION_NAME}"
        echo ""
        echo "Or via SSH:"
        echo "  ssh -i ${SSH_KEY} ${SSH_USER}@${HOST} tmux attach -t ${SESSION_NAME}"
        echo ""
        echo "Detach: Ctrl+B, then D"
        ;;
        
    attach)
        if [ -z "$SESSION_NAME" ]; then
            print_error "Session name is required for 'attach' action"
            usage
        fi
        
        print_header "Attaching to tmux session: $SESSION_NAME on $HOST"
        echo "Press Ctrl+B, then D to detach without stopping the session"
        echo ""
        
        $SSH_CMD "tmux attach -t ${SESSION_NAME}" || {
            print_error "Session '${SESSION_NAME}' not found on ${HOST}"
            echo "List available sessions:"
            echo "  $0 ${HOST} list"
            exit 1
        }
        ;;
        
    list)
        print_header "tmux sessions on $HOST"
        
        SESSIONS=$($SSH_CMD "tmux list-sessions -F '#S' 2>/dev/null") || true
        
        if [ -z "$SESSIONS" ]; then
            print_warning "No active tmux sessions on ${HOST}"
        else
            echo "$SESSIONS" | while read -r session; do
                echo "  • $session"
            done
            echo ""
            echo "Attach to a session:"
            echo "  $0 ${HOST} attach <session-name>"
        fi
        ;;
        
    kill)
        if [ -z "$SESSION_NAME" ]; then
            print_error "Session name is required for 'kill' action"
            usage
        fi
        
        print_header "Killing tmux session: $SESSION_NAME on $HOST"
        
        $SSH_CMD "tmux kill-session -t ${SESSION_NAME}" && {
            print_success "Session '${SESSION_NAME}' killed on ${HOST}"
        } || {
            print_error "Session '${SESSION_NAME}' not found on ${HOST}"
            exit 1
        }
        ;;
        
    status)
        if [ -z "$SESSION_NAME" ]; then
            print_error "Session name is required for 'status' action"
            usage
        fi
        
        print_header "Status of tmux session: $SESSION_NAME on $HOST"
        
        $SSH_CMD "tmux list-sessions -F '#S: #{session_windows} windows, #{session_panels} panes' 2>/dev/null | grep '^${SESSION_NAME}:' || echo 'Session not found'"
        ;;
        
    *)
        print_error "Unknown action: $ACTION"
        usage
        ;;
esac
