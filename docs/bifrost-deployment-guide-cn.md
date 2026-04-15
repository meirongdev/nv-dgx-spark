# Bifrost + vLLM 部署指南

## 架构概览

```
┌────────────────────────────────────────────────────────────┐
│                    DGX Spark 集群                            │
│                                                            │
│  ┌──────────────────┐    200Gbps 内部网络    ┌──────────────┐ │
│  │  Server 1        │  ◄──────────────────►  │  Server 2    │ │
│  │  192.168.200.101 │  (enp1s0f0np0, 0.2ms)  │192.168.200.102│ │
│  │  vLLM :30000     │                        │ vLLM :30000  │ │
│  │  Qwen3.5-122B   │                        │ Qwen3.5-122B │ │
│  │  + Bifrost :8080 │                        │              │ │
│  └────────┬─────────┘                        └──────┬───────┘ │
│           │                                         │         │
│           └─────────────────┬───────────────────────┘         │
│                             │                                 │
│                    ┌────────▼────────┐                        │
│                    │  Bifrost Gateway │                        │
│                    │  100.97.87.120   │                        │
│                    │  :8080           │                        │
│                    │  负载均衡 + 故障转移  │                        │
│                    └─────────────────┘                        │
└─────────────────────────────┬───────────────────────────────┘
                              │
                    Tailscale VPN (100.x)
                              │
                    ┌─────────▼─────────┐
                    │   本地机器 (macOS)   │
                    │   Codex / OpenClaw │
                    └───────────────────┘
```

## 技术栈

| 组件 | 版本/镜像 | 说明 |
|------|----------|------|
| **vLLM** | `vllm-node-tf5:latest` (0.19.1rc1) | 推理引擎，支持工具调用和推理链 |
| **Bifrost** | `maximhq/bifrost:latest` | 负载均衡网关，<11μs 延迟 |
| **模型** | `bjk110/Qwen3.5-122B-A10B-abliterated-NVFP4` (~72GB) | NVFP4 量化 |
| **GPU** | NVIDIA GB10 (128GB 统一内存, sm_121 Blackwell) | 每节点一块 |

## 快速部署

```bash
# 一键部署全栈（vLLM + Bifrost）
make stack-deploy

# 检查状态
make stack-status

# 测试（包括工具调用验证）
make vllm-qwen-test
make bifrost-test
```

## 分步部署

### Step 1: 部署 vLLM

```bash
# 在两台服务器上部署 vLLM
make vllm-qwen-deploy

# 验证 vLLM 运行状态
make vllm-qwen-status

# 测试 vLLM（健康检查 + 聊天 + 工具调用）
make vllm-qwen-test
```

### Step 2: 部署 Bifrost 网关

```bash
# 在 Server 1 上部署 Bifrost
make bifrost-deploy

# 测试 Bifrost 路由
make bifrost-test
```

### Step 3: 从本地使用

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://100.97.87.120:8080/v1",
    api_key="vk-dgx-cluster"
)

response = client.chat.completions.create(
    model="Qwen3.5-122B-A10B",
    messages=[{"role": "user", "content": "你好"}],
    max_tokens=100
)
print(response.choices[0].message.content)
```

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

- **后端**: `192.168.200.101:30000` + `192.168.200.102:30000`（使用 200-subnet）
- **超时**: 300 秒（122B 模型首 token 延迟较长）
- **负载均衡**: Round-robin 50/50，自动故障转移
- **虚拟 Key**: `vk-dgx-cluster`

## 运维命令

```bash
# 全栈操作
make stack-deploy       # 部署全栈
make stack-status       # 检查状态
make stack-stop         # 停止全栈

# vLLM 操作
make vllm-qwen-deploy   # 部署 vLLM
make vllm-qwen-test     # 测试
make vllm-qwen-status   # 状态
make vllm-qwen-stop     # 停止
make vllm-qwen-logs HOST=100.97.87.120  # 日志

# Bifrost 操作
make bifrost-deploy     # 部署
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

| 项目 | 配置 | 状态 |
|------|------|------|
| vLLM Server 1 | 192.168.200.101:30000 | ✅ |
| vLLM Server 2 | 192.168.200.102:30000 | ✅ |
| Bifrost Gateway | 100.97.87.120:8080 | ✅ |
| 模型 | Qwen3.5-122B-A10B (NVFP4) | ✅ |
| 工具调用 | qwen3_coder parser | ✅ |
| 负载均衡 | Round-robin 50/50 + 故障转移 | ✅ |
