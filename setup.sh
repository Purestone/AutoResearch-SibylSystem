#!/bin/bash
# Sibyl Research System - Setup Script
# Installs Python environment, dependencies, and configures MCP servers

set -e
echo "=== Sibyl Research System Setup ==="

cd "$(dirname "$0")"
REPO_ROOT="$(pwd -P)"

detect_shell_rc() {
    case "${SHELL:-}" in
        */zsh)
            echo "${ZDOTDIR:-$HOME}/.zshrc"
            ;;
        */bash)
            echo "$HOME/.bashrc"
            ;;
        *)
            if [ -f "${ZDOTDIR:-$HOME}/.zshrc" ] || [ ! -f "$HOME/.bashrc" ]; then
                echo "${ZDOTDIR:-$HOME}/.zshrc"
            else
                echo "$HOME/.bashrc"
            fi
            ;;
    esac
}

configure_sibyl_root() {
    local shell_rc="$1"
    local action

    action=$("$PY" - "$shell_rc" "$REPO_ROOT" <<'PY'
from pathlib import Path
import re
import sys

rc_path = Path(sys.argv[1]).expanduser()
repo_root = sys.argv[2]
target_line = f'export SIBYL_ROOT="{repo_root}"'

if rc_path.exists():
    text = rc_path.read_text(encoding="utf-8")
else:
    text = ""

existing = re.search(r"(?m)^[ \t]*export[ \t]+SIBYL_ROOT=(.*)$", text)
if existing:
    current_line = existing.group(0).strip()
    if current_line == target_line:
        print("already_set")
    else:
        updated = re.sub(
            r"(?m)^[ \t]*export[ \t]+SIBYL_ROOT=.*$",
            target_line,
            text,
            count=1,
        )
        rc_path.parent.mkdir(parents=True, exist_ok=True)
        rc_path.write_text(updated, encoding="utf-8")
        print("updated")
else:
    suffix = "" if not text or text.endswith("\n") else "\n"
    block = f"{suffix}\n# Added by Sibyl setup\n{target_line}\n"
    rc_path.parent.mkdir(parents=True, exist_ok=True)
    rc_path.write_text(text + block, encoding="utf-8")
    print("added")
PY
)

    case "$action" in
        added)
            echo "  ✓ Added SIBYL_ROOT to $shell_rc"
            ;;
        updated)
            echo "  ✓ Updated SIBYL_ROOT in $shell_rc"
            ;;
        already_set)
            echo "  ✓ SIBYL_ROOT already configured in $shell_rc"
            ;;
    esac
}

# ---------- Python environment ----------
# Prefer python3.12; fall back to python3
PY=""
if command -v python3.12 &>/dev/null; then
    PY="python3.12"
elif command -v python3 &>/dev/null; then
    PY="python3"
else
    echo "ERROR: Python 3.12+ is required but not found."
    echo "Install via: brew install python@3.12  (macOS) or apt install python3.12 (Linux)"
    exit 1
fi

PY_VER=$($PY -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PY_MAJOR=$($PY -c "import sys; print(sys.version_info.major)")
PY_MINOR=$($PY -c "import sys; print(sys.version_info.minor)")

if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 12 ]; }; then
    echo "ERROR: Python 3.12+ is required, found $PY_VER"
    echo "Install via: brew install python@3.12  (macOS) or apt install python3.12 (Linux)"
    exit 1
fi

echo "Using $PY ($PY_VER)"

if [ ! -d ".venv" ]; then
    echo "Creating virtual environment..."
    $PY -m venv .venv
fi
source .venv/bin/activate
VENV_PY="$PWD/.venv/bin/python3"

echo "Installing core dependencies..."
pip install -e . 2>&1 | tail -3

# ---------- MCP servers (Python-based) ----------
echo ""
echo "Installing Python MCP servers..."
pip install arxiv-mcp-server 2>/dev/null && echo "  ✓ arxiv-mcp-server" || echo "  ✗ arxiv-mcp-server (install manually: .venv/bin/pip install arxiv-mcp-server)"

# ---------- tmux check ----------
echo ""
if command -v tmux &>/dev/null; then
    TMUX_VER=$(tmux -V 2>/dev/null || echo "unknown")
    echo "tmux detected ($TMUX_VER) — good for persistent sessions + Sentinel auto-recovery"
else
    echo "⚠  tmux not found. Strongly recommended for persistent sessions and Sentinel watchdog."
    echo "   Install: brew install tmux (macOS) / apt install tmux (Linux)"
fi

# ---------- Node.js check ----------
echo ""
HAS_NODE=false
if command -v node &>/dev/null; then
    NODE_VER=$(node -v | sed 's/v//')
    echo "Node.js $NODE_VER detected"
    HAS_NODE=true
else
    echo "⚠  Node.js not found. Required for SSH MCP and optional Lark/Codex MCP servers."
    echo "   Install via: brew install node  (macOS) or https://nodejs.org/"
fi

# ---------- MCP configuration ----------
echo ""
echo "Configuring MCP servers..."

# Check if opencode CLI is available
HAS_OPENCODE=false
if command -v opencode &>/dev/null; then
    HAS_OPENCODE=true
    echo "  opencode CLI detected — using project-level .mcp.json for MCP server config"
fi

# Warn about legacy ~/.mcp.json
if [ -f "$HOME/.mcp.json" ]; then
    echo ""
    echo "  ⚠ Legacy ~/.mcp.json detected."
    echo "    Consider migrating to a project-level .mcp.json for repo-scoped config."
    echo "    See docs/mcp-servers.md for details."
fi

# --- SSH MCP Server ---
SSH_HOST=""
SSH_PORT="22"
SSH_USER=""
SSH_KEY="$HOME/.ssh/id_ed25519"
COMPUTE_BACKEND="local"

echo ""
echo "SSH MCP Server (@fangjunjie/ssh-mcp-server) — required for remote GPU experiments"
echo "  GitHub: https://github.com/classfang/ssh-mcp-server"
echo "  (Leave empty to skip if using local GPUs only)"
echo ""
read -p "  GPU server hostname or IP: " SSH_HOST
if [ -n "$SSH_HOST" ]; then
    read -p "  SSH port [22]: " input_port
    SSH_PORT="${input_port:-22}"
    read -p "  SSH username: " SSH_USER
    read -p "  SSH private key path [$SSH_KEY]: " input_key
    SSH_KEY="${input_key:-$SSH_KEY}"
    COMPUTE_BACKEND="ssh"
fi

echo ""
if [ "$HAS_OPENCODE" = true ]; then
    # opencode uses project-level .mcp.json for MCP server config
    if [ -f ".mcp.json" ]; then
        echo "  .mcp.json already exists — skipping MCP auto-config."
        echo "  Verify it includes 'ssh-mcp-server' and 'arxiv-mcp-server'."
        echo "  See docs/mcp-servers.md for reference."
    else
        echo "  Creating project-level .mcp.json for opencode"
        if [ -n "$SSH_HOST" ] && [ -n "$SSH_USER" ]; then
            cat > .mcp.json << MCPEOF
{
  "mcpServers": {
    "ssh-mcp-server": {
      "command": "npx",
      "args": ["-y", "@fangjunjie/ssh-mcp-server",
               "--host", "$SSH_HOST",
               "--port", "$SSH_PORT",
               "--username", "$SSH_USER",
               "--privateKey", "$SSH_KEY"]
    },
    "arxiv-mcp-server": {
      "command": "$VENV_PY",
      "args": ["-m", "arxiv_mcp_server"],
      "env": {}
    }
  }
}
MCPEOF
            echo "  ✓ SSH + arXiv MCP configured in .mcp.json"
        else
            cat > .mcp.json << MCPEOF
{
  "mcpServers": {
    "arxiv-mcp-server": {
      "command": "$VENV_PY",
      "args": ["-m", "arxiv_mcp_server"],
      "env": {}
    }
  }
}
MCPEOF
            echo "  ✓ arXiv MCP configured in .mcp.json"
            echo "  ⚠ SSH MCP skipped — add manually if using remote GPUs"
        fi
    fi
else
    # Fallback: create project-level .mcp.json
    if [ -f ".mcp.json" ]; then
        echo "  .mcp.json already exists — skipping MCP auto-config."
        echo "  Verify it includes 'ssh-mcp-server' and 'arxiv-mcp-server'."
        echo "  See docs/mcp-servers.md for reference."
    else
        echo "  opencode CLI not found — creating project-level .mcp.json"
        if [ -n "$SSH_HOST" ] && [ -n "$SSH_USER" ]; then
            cat > .mcp.json << MCPEOF
{
  "mcpServers": {
    "ssh-mcp-server": {
      "command": "npx",
      "args": ["-y", "@fangjunjie/ssh-mcp-server",
               "--host", "$SSH_HOST",
               "--port", "$SSH_PORT",
               "--username", "$SSH_USER",
               "--privateKey", "$SSH_KEY"]
    },
    "arxiv-mcp-server": {
      "command": "$VENV_PY",
      "args": ["-m", "arxiv_mcp_server"],
      "env": {}
    }
  }
}
MCPEOF
            echo "  ✓ SSH + arXiv MCP configured in .mcp.json"
        else
            cat > .mcp.json << MCPEOF
{
  "mcpServers": {
    "arxiv-mcp-server": {
      "command": "$VENV_PY",
      "args": ["-m", "arxiv_mcp_server"],
      "env": {}
    }
  }
}
MCPEOF
            echo "  ✓ arXiv MCP configured in .mcp.json"
            echo "  ⚠ SSH MCP skipped — add manually if using remote GPUs"
        fi
    fi
fi

# ---------- config.yaml ----------
if [ ! -f "config.yaml" ]; then
    if [ "$COMPUTE_BACKEND" = "ssh" ] && [ -n "$SSH_USER" ]; then
        cat > config.yaml << CFGEOF
# Sibyl Research System - Machine-level config (git-ignored)
compute_backend: ssh
ssh_server: "default"
remote_base: "/home/$SSH_USER/sibyl_system"
max_gpus: 4
language: zh
codex_enabled: false  # Opt in only after Codex MCP + OPENAI_API_KEY are configured
CFGEOF
        echo "  ✓ Created config.yaml (compute_backend: ssh, edit remote_base/max_gpus as needed)"
    else
        cat > config.yaml << CFGEOF
# Sibyl Research System - Machine-level config (git-ignored)
compute_backend: local
max_gpus: 4
language: zh
codex_enabled: false  # Opt in only after Codex MCP + OPENAI_API_KEY are configured
# To use remote GPUs, set compute_backend: ssh and configure:
# ssh_server: "default"
# remote_base: "/home/user/sibyl_system"
CFGEOF
        echo "  ✓ Created config.yaml (compute_backend: local)"
    fi
fi

# ---------- Environment variables ----------
echo ""
echo "Checking environment variables..."
SHELL_RC="$(detect_shell_rc)"
echo "  Shell rc target: $SHELL_RC"
configure_sibyl_root "$SHELL_RC"
echo "    SIBYL_ROOT -> $REPO_ROOT"

if [ -n "$ANTHROPIC_API_KEY" ]; then
    echo "  ✓ ANTHROPIC_API_KEY is set"
else
    echo "  ✗ ANTHROPIC_API_KEY not set — add to $SHELL_RC:"
    echo "    export ANTHROPIC_API_KEY=\"sk-ant-...\""
fi

# ---------- Summary ----------
echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Set missing environment variables (see above), then:"
echo "       source $SHELL_RC"
echo "  2. Review config.yaml — adjust compute_backend/remote_base/max_gpus as needed"
echo "     Codex stays disabled by default; enable it only after installing Codex MCP and OPENAI_API_KEY"
echo "  3. (Recommended) Install Google Scholar MCP for better literature search:"
echo "       git clone https://github.com/JackKuo666/Google-Scholar-MCP-Server.git ~/.local/share/mcp-servers/Google-Scholar-MCP-Server"
echo "       .venv/bin/pip install -r ~/.local/share/mcp-servers/Google-Scholar-MCP-Server/requirements.txt"
echo "       # Add google-scholar entry to your .mcp.json"
echo "  4. Launch opencode with Sibyl (inside tmux):"
echo "       tmux new -s sibyl"
echo "       cd \"$REPO_ROOT\""
echo "       opencode"
echo "  5. Inside opencode:"
echo "       /sibyl-research:init              # Create a research project"
echo "       /sibyl-research:start <project>   # Start autonomous research"
echo ""
echo "Guides:"
echo "  Full setup:       docs/getting-started.md"
echo "  MCP servers:      docs/mcp-servers.md"
echo "  GPU config:       docs/ssh-gpu-setup.md"
echo "  All commands:     docs/plugin-commands.md"
echo "  Configuration:    docs/configuration.md"
