# Bifrost + vLLM 部署指南

## 架构概览

```
┌────────────────────────────────────────────────────────────┐
│                    DGX Spark 集群                           │
│                                                            │
│  ┌──────────────────┐    200Gbps 内部网络    ┌──────────────┐ │
│  │  Server 1        │  ◄──────────────────►  │  Server 2   │ │
│  │  192.168.200.101 │  (enp1s0f0np0, 0.2ms) │192.168.200.102│ │
│  │  vLLM :30000     │                       │ vLLM :30000  │ │
│  │  Qwen3.6-35B-A3B │                       │Qwen3.6-35B-A3B│ │
│  │  + Bifrost :8080 │                       │              │ │
│  └────────┬─────────┘                        └──────┬──────┘ │
│           │                                         │        │
│           └─────────────────┬───────────────────────┘        │
│                             │                                │
│                    ┌────────▼────────┐                       │
│                    │  Bifrost Gateway │                      │
│                    │  100.97.87.120   │                      │
│                    │  :8080           │                      │
│                    │  provider 路由 + VK 鉴权 │                │
│                    └─────────────────┘                       │
└─────────────────────────────┬──────────────────────────────┘
                              │
                    Tailscale VPN (100.x)
                              │
                    ┌─────────▼─────────┐
                    │   本地机器 (macOS)   │
                    │   Codex / Qwen CLI │
                    └───────────────────┘
```

## 技术栈

| 组件 | 版本/镜像 | 说明 |
|------|----------|------|
| **vLLM** | `vllm-node-tf5:latest` | 推理引擎，支持工具调用和推理链 |
| **Bifrost** | `maximhq/bifrost:latest` | OpenAI 兼容网关，provider 路由 + 虚拟 key 鉴权 |
| **主模型** | Qwen3.6-35B-A3B-FP8（ModelScope 缓存，256K context） | FP8 量化 |
| **备选模型** | Qwen3.5-122B-A10B-NVFP4、Gemma-4-31B-IT-NVFP4 | 见 `Makefile` 对应目标 |
| **GPU** | NVIDIA GB10 (128GB 统一内存, sm_121 Blackwell) | 每节点一块 |

## 快速部署

```bash
# 一键部署（默认主模型 qwen36；切模型用 STACK_MODEL=qwen|gemma4）
make stack-deploy

# 或者分步跑
make vllm-qwen36-deploy     # 主模型（默认：Qwen3.6-35B-A3B-FP8）
make bifrost-deploy         # Bifrost 网关

# 检查状态
make stack-status
make bifrost-test
```

## 分步部署

### Step 1: 部署 vLLM

```bash
# 在两台服务器上部署 vLLM（主模型）
make vllm-qwen36-deploy

# 验证
make vllm-qwen36-status
```

需要切换模型（122B / Gemma-4）时改用 `make vllm-qwen-deploy` / `make vllm-gemma4-deploy`。

### Step 2: 部署 Bifrost 网关

```bash
# 在 Server 1 上部署 Bifrost
make bifrost-deploy

# 测试 Bifrost 路由
make bifrost-test
```

### Step 3: 从本地使用

**关键点：**
- `api_key` 必须是 `governance.virtual_keys[]` 里定义的 VK value（见下文配置）
- `model` 必须是 `<provider>/<model>` 格式，例如 `vllm-server1/Qwen3.6-35B-A3B`
- bare model 名（不带 provider 前缀）会被 Bifrost 以 400 拒绝

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://100.97.87.120:8080/v1",
    api_key="sk-bf-dgx-spark-cluster-2026"    # governance.virtual_keys[0].value
)

response = client.chat.completions.create(
    model="vllm-server1/Qwen3.6-35B-A3B",
    messages=[{"role": "user", "content": "你好"}],
    max_tokens=256
)
print(response.choices[0].message.content)
```

直连 vLLM 调试（跳过 Bifrost）：`base_url="http://100.97.87.120:30000/v1"`，`model="Qwen3.6-35B-A3B"`（bare 名），api_key 任意。

## Docker 镜像

`vllm-node-tf5:latest` 已预装在两台服务器上（兼容 NVIDIA 驱动 580.142）。

如需 Bifrost 镜像：

```bash
docker pull maximhq/bifrost:latest

# 网络不通时，通过 200-subnet 高速内网传输
ssh admin@100.97.87.120 \
  "docker save maximhq/bifrost:latest | ssh admin@192.168.200.102 'docker load'"
```

### 模型下载

模型已缓存在 `~/.cache/huggingface/hub/`。如需新模型：

```bash
# 使用 HF 镜像站
export HF_ENDPOINT=https://hf-mirror.com
huggingface-cli download bjk110/Qwen3.5-122B-A10B-abliterated-NVFP4

# 使用 ModelScope
pip install modelscope
modelscope download --model bjk110/Qwen3.5-122B-A10B-abliterated-NVFP4
```

## vLLM 配置说明

### 关键参数

| 参数 | 值 | 说明 |
|------|---|------|
| `--gpu-memory-utilization` | `0.70` | GPU 内存占比（128GB × 0.70 ≈ 89.6GB） |
| `--kv-cache-dtype` | `fp8_e4m3` | KV 缓存数据类型（GB10 推荐） |
| `--tool-call-parser` | `qwen3_coder` | Qwen3.5 工具调用解析器 |
| `--reasoning-parser` | `qwen3` | 推理链解析器 |
| `--enable-auto-tool-choice` | - | 启用自动工具调用 |
| `--enable-prefix-caching` | - | 启用前缀缓存（提升多轮对话性能） |

### 统一内存注意事项

- **必须禁用 swap**: `swapoff -a`（部署 playbook 会自动处理）
- **内存分配**: 模型 ~72GB + KV 缓存 ~17GB = ~89GB（128GB 的 70%）
- **不要设置 `gpu-memory-utilization > 0.75`**，否则系统可能 OOM

## Bifrost 配置

配置文件: `config/bifrost-config.json`

- **Providers**:
  - `vllm-server1` → `http://192.168.200.101:30000`（responses + chat_completion 都开）
  - `vllm-server2` → `http://192.168.200.102:30000`（只开 chat_completion，responses 关闭）
- **超时**: 300 秒（大模型首 token 延迟较长）
- **路由**: 客户端通过 `model` 字段的 `<provider>/<model>` 前缀显式选择后端；当前配置里**没有**跨 provider 的自动负载均衡（需要写 CEL `routing_rules`）
- **虚拟 Key**（`governance.virtual_keys[]`）:
  - id: `dgx-spark-cluster`
  - value: `sk-bf-dgx-spark-cluster-2026`
  - 允许的 providers: `vllm-server1`、`vllm-server2`
  - 允许的模型: 显式列出（`["*"]` schema 声称支持但实测不生效）

### 鉴权注意事项

Bifrost 只在请求的 Bearer 命中某个 VK 时才执行该 VK 的 allowed_models / allowed_providers 限制；未知或缺失 Bearer 会**放行**而不是 401。这意味着 `:8080` 目前是"Tailscale 内网可达即可用"，不是严格鉴权的公网入口。

## 运维命令

```bash
# 全栈操作（STACK_MODEL 控制主模型：qwen36 默认 / qwen / gemma4）
make stack-deploy
make stack-status
make stack-stop

# vLLM 操作（主模型 qwen36；其他模型把 qwen36 换成 qwen / gemma4）
make vllm-qwen36-deploy                  # 部署
make vllm-qwen36-status                  # 状态
make vllm-qwen36-stop                    # 停止
make vllm-qwen36-logs HOST=100.97.87.120 # 日志

# Bifrost 操作
make bifrost-deploy     # 部署/更新（同时 push config/bifrost-config.json）
make bifrost-test       # 测试
make bifrost-status     # 状态
make bifrost-stop       # 停止
```

## 故障排查

### vLLM 容器崩溃

```bash
# 查看日志
make vllm-qwen-logs HOST=100.97.87.120
# 检查 GPU 内存
ssh admin@100.97.87.120 "nvidia-smi"
```

### Bifrost 无法连接后端

```bash
# 测试 200-subnet 连通性
ssh admin@100.97.87.120 "curl -s http://192.168.200.101:30000/health"
ssh admin@100.97.87.120 "curl -s http://192.168.200.102:30000/health"
```

### 内存不足 OOM

```bash
make vllm-qwen-stop
make vllm-qwen-deploy VLLM_QWEN_GPU_MEM=0.65
```

## 总结

| 项目 | 配置 |
|------|------|
| vLLM Server 1 | 192.168.200.101:30000 (provider `vllm-server1` — 支持 responses + chat) |
| vLLM Server 2 | 192.168.200.102:30000 (provider `vllm-server2` — 只支持 chat) |
| Bifrost Gateway | 100.97.87.120:8080 |
| 当前主模型 | Qwen3.6-35B-A3B-FP8 |
| 工具调用 | qwen3_coder parser |
| 鉴权 | governance virtual key `sk-bf-dgx-spark-cluster-2026` |
| 负载均衡 | 客户端显式 provider 前缀（无自动跨 provider LB） |
