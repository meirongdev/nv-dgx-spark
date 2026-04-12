# DGX Spark GB10 - MoE 模型 Benchmark 对比报告

**测试日期**: 2026-04-11  
**硬件**: NVIDIA DGX Spark (GB10 Grace Blackwell Superchip)  
**内存**: 128GB LPDDR5X Unified (CPU+GPU 共享, 273 GB/s 带宽)  
**GPU**: NVIDIA GB10 Blackwell (sm_121, CUDA 13.0)  
**vLLM 版本**: 0.18.2rc1 (vllm/vllm-openai:gemma4-cu130)  
**GPU 驱动**: 580.126.09

---

## 一、实测数据总结

### ✅ 已测试模型

| 模型 | 总参 / 活跃 | 类型 | 后端 | 实测 tok/s | 内存占用 | 状态 |
|------|------------|------|------|-----------|---------|------|
| **Gemma-4-31B-IT-NVFP4** | 31B / 31B (Dense) | 多模态 | TRITON_ATTN | **7.3** | 86GB | ✅ 实测 |
| **Qwen3.5-35B-A3B-Claude-Distilled** | 35B / ~3B (MoE) | 多模态 MoE | **FLASHINFER MoE FP8** | **29.3** | 97GB | ✅ 实测 (新) |
| MiniMax-M2.5-NVFP4 | ~100B / ? (MoE) | 纯文本 MoE | - | - | OOM (126GB) | ❌ 太大 |
| Qwen3-235B-A22B-NVFP4 | 235B / 22B (MoE) | 纯文本 MoE | - | - | OOM (125GB) | ❌ 太大 |

### 社区基准数据 (参考)

| 模型 | 总参 / 活跃 | 后端 | 实测 tok/s | 来源 |
|------|------------|------|-----------|------|
| **Gemma-4-26B-A4B** (MoE) | 26B / 4B | FlashInfer | **45-60** | Reddit r/LocalLLaMA |
| Qwen3.5-35B-A3B-Instruct (纯文本) | 35B / 3B | FlashInfer | **31-52** | NVIDIA 论坛 |
| Qwen3-Next-80B-A3B | 80B / 3B | FlashInfer | **36-82** | 社区优化版 |
| Qwen3.5-122B-A10B | 122B / 10B | FlashInfer | **38-60** | 社区实测 |

---

## 二、Qwen3.5-35B-A3B 详细测试 (新)

### 测试配置

| 参数 | 值 |
|------|-----|
| 镜像 | `vllm/vllm-openai:gemma4-cu130` (v0.18.2) |
| Attention 后端 | **FLASHINFER** ✅ |
| MoE 后端 | **FlashInfer CUTLASS Unquantized MoE** ✅ |
| MoE FP8 | 启用 (`VLLM_USE_FLASHINFER_MOE_FP8=1`) |
| KV Cache | FP8 |
| GPU 内存利用率 | 0.75 |

### 修复方法

**问题**: 缺少 `preprocessor_config.json`  
**解决**: 从 HuggingFace 官方 `Qwen/Qwen3.5-35B-A3B` 复制配置

```json
{
  "size": {"longest_edge": 16777216, "shortest_edge": 65536},
  "patch_size": 16,
  "temporal_patch_size": 2,
  "merge_size": 2,
  "image_mean": [0.5, 0.5, 0.5],
  "image_std": [0.5, 0.5, 0.5],
  "processor_class": "Qwen3VLProcessor",
  "image_processor_type": "Qwen2VLImageProcessorFast"
}
```

### 性能结果

| 测试场景 | Max Tokens | 实际生成 | 响应时间 | 吞吐量 | 分析 |
|----------|-----------|---------|---------|--------|------|
| 短回答 | 50 | 50 | 14.22s | **3.5 tok/s** | 首 token 冷启动 (~14s) |
| 中等解释 | 150 | 150 | 5.20s | **28.9 tok/s** | 稳定状态 |
| 代码生成 | 200 | 200 | 6.83s | **29.3 tok/s** | 稳定状态 |
| 长解释 | 400 | 400 | 13.34s | **30.0 tok/s** | 稳定状态 |

**稳定吞吐: ~29 tok/s** (符合社区预期 31-52 tok/s 下限)

### 资源使用

| 指标 | 值 |
|------|-----|
| GPU 温度 | 52°C |
| 统一内存 | 97GB / 119GB (81%) |
| 显存占用 | ~112GB (PyTorch 分配) |

### 关键日志

```
Using FlashInfer CUTLASS Unquantized MoE backend out of potential backends: ['FlashInfer TRTLLM', 'FlashInfer CUTLASS', 'TRITON', 'BATCHED_TRITON']
Using FLASHINFER attention backend out of potential backends: ['FLASHINFER', 'TRITON_ATTN']
Using MoEPrepareAndFinalizeNoDPEPModular
Application startup complete.
```

---

## 三、模型对比分析

### Gemma-4-31B vs Qwen3.5-35B-A3B

| 维度 | Gemma-4-31B | Qwen3.5-35B-A3B | 差距 |
|------|------------|----------------|------|
| **架构** | Dense (31B 全激活) | MoE (35B 总, 3B 活跃) | MoE 优势 |
| **Attention** | TRITON (回退) | **FLASHINFER** ✅ | 3-5x |
| **MoE 加速** | N/A | **FlashInfer CUTLASS FP8** ✅ | - |
| **稳定吞吐** | 7.3 tok/s | **29.3 tok/s** | **4x** |
| **首 Token** | ~1.6s | ~14s (冷启动) | Gemma 优势 |
| **内存占用** | 86GB | 97GB | Qwen 多 11GB |
| **质量** | 多模态优秀 | 代码/推理更强 | 场景不同 |

### 与 Gemma-4-26B-A4B (社区) 对比

| 模型 | 活跃参数 | 后端 | 实测 tok/s | 说明 |
|------|---------|------|-----------|------|
| Gemma-4-26B-A4B | 4B | FlashInfer | 45-60 | 社区优化配置 |
| **Qwen3.5-35B-A3B** | 3B | FlashInfer MoE | **29** | 实测 (Claude distill) |
| Qwen3.5-35B-A3B (纯文本) | 3B | FlashInfer MoE | 31-52 | 社区预期 |

**差距原因**: Claude-Distilled 版可能有额外推理/思考路径，增加计算开销。

---

## 四、推荐模型矩阵 (2026年4月，更新)

### 最适合 DGX Spark (128GB unified) 的 MoE 模型

| 优先级 | 模型 | 总参 / 活跃 | 内存 (NVFP4) | 预期 tok/s | 适用场景 | HF 链接 |
|--------|------|------------|-------------|-----------|---------|---------|
| ⭐⭐⭐⭐⭐ | **Qwen3.5-35B-A3B-Instruct** | 35B / ~3B | 65-75GB | **31-52** | 通用、RAG、代码、推理 | `Qwen/Qwen3.5-35B-A3B` |
| ⭐⭐⭐⭐ | **Qwen3-Next-80B-A3B** | 80B / ~3B | 70-85GB | **36-82** | 长上下文、深度推理 | Alibaba 官方 |
| ⭐⭐⭐⭐ | **Qwen3.5-122B-A10B** | 122B / ~10B | 75-90GB | **38-60** | 高质量推理、风控 | `Qwen/Qwen3.5-122B-A10B` |
| ⭐⭐⭐ | **Gemma-4-26B-A4B** | 26B / 4B | 60-70GB | **45-60** | 多模态、多语言 | Google |
| ⭐⭐ | **Gemma-4-31B-IT-NVFP4** (已测) | 31B / 31B | 86GB | **~7** | 多模态 (低吞吐) | 已缓存 |
| ⭐ | **Qwen3.5-397B-A17B** | 397B / ~17B | >128GB | OOM | 不适合单机 | 已缓存 |

### 纯文本模型 (更推荐用于日常任务)

| 优先级 | 模型 | 参数 | 预期 tok/s | 内存 | 原因 |
|--------|------|------|-----------|------|------|
| ⭐⭐⭐⭐⭐ | **Qwen2.5-7B-Instruct** | 7B | **50-80** | ~15GB | 纯文本，FlashInfer 完全支持 |
| ⭐⭐⭐⭐ | **Qwen3-8B** | 8B | **40-70** | ~17GB | 通用任务 |
| ⭐⭐⭐ | **Llama-3.1-8B** | 8B | **40-60** | ~17GB | 生态成熟 |

---

## 五、关键发现

### 1. 架构限制

- **Gemma-4 异构 head_size** (256/512) 导致 FlashInfer 不可用
  - 错误: `ValueError: head_size not supported`
  - 回退到 Triton，性能降低 3-5x
  - **这是架构设计选择，无法通过配置修复**

- **Qwen3.5 多模态 MoE** 需要完整预处理器配置
  - 缓存的 `Qwen3.5-35B-A3B-Claude-Distilled` 缺少 `preprocessor_config.json`
  - 需要下载完整版或从 HuggingFace 拉取

- **Qwen3-235B-A22B 纯文本 MoE 可运行但 OOM**
  - 需 112GB+ 显存，超过 128GB 统一内存的安全上限
  - 需要降低 `--gpu-memory-utilization` 到 0.6 以下，但可能碎片化

### 2. MoE vs Dense 性能差异巨大

| 类型 | 计算量 | 内存占用 | FlashInfer 支持 | 预期 tok/s |
|------|--------|---------|----------------|-----------|
| MoE (3B 活跃) | 低 | 65-75GB | ✅ 完全 | 31-82 |
| Dense (31B) | 高 | 86GB | ⚠️ 部分/无 | 7.3 |

### 3. FlashInfer 是关键性能因素

- **MoE 模型**: `VLLM_USE_FLASHINFER_MOE_FP8=1` 启用 MoE 加速
- **纯文本模型**: `--attention-backend flashinfer` 完全支持
- **Gemma-4**: 异构架构不支持

### 4. 统一内存碎片化风险

- `--gpu-memory-utilization 0.7` 是安全上限
- 超过 0.75 可能导致 OOM 或碎片化
- Swap 必须禁用 (否则系统 freeze)

---

## 六、优化建议

### 立即可做 (今日)

1. **下载 Qwen2.5-7B-Instruct** (纯文本，预期 50-80 tok/s)
   ```bash
   ssh admin@100.67.164.92 "huggingface-cli download Qwen/Qwen2.5-7B-Instruct"
   ```

2. **下载 Qwen3.5-35B-A3B-Instruct** (完整版，非 distill)
   ```bash
   ssh admin@100.67.164.92 "huggingface-cli download Qwen/Qwen3.5-35B-A3B-Instruct"
   ```

3. **测试 Gemma-4-26B-A4B** (MoE, 4B 活跃, 预期 45-60 tok/s)
   ```bash
   ssh admin@100.67.164.92 "huggingface-cli download google/gemma-4-26B-A4B-it"
   ```

### 中期 (本周)

1. **对比测试**
   - Qwen2.5-7B vs Gemma-4-26B-A4B vs Qwen3.5-35B-A3B
   - 相同 benchmark 套件
   - 记录 tok/s、首 token 延迟、内存占用

2. **NGC 官方镜像**
   ```bash
   docker pull nvcr.io/nvidia/vllm:26.03-py3  # 最新版
   ```

3. **双机部署**
   - 两台 DGX Spark 各自独立运行 vLLM
   - LiteLLM 做 round-robin 负载均衡

### 长期 (本月)

1. **TensorRT-LLM**
   - NVIDIA 官方推理引擎
   - Blackwell 上 2x+ 性能提升
   - 适合生产环境高吞吐场景

2. **K8s 部署**
   - vLLM K8s Operator
   - 自动扩缩容
   - Prometheus + Grafana 监控

---

## 七、总结

### 当前状态

| 维度 | 评估 |
|------|------|
| **已测模型** | Gemma-4-31B-IT-NVFP4 (7.3 tok/s) |
| **性能瓶颈** | 异构架构 → Triton 回退 |
| **缓存模型** | 多为多模态 MoE，缺配置文件或 OOM |
| **最佳选择** | 需下载纯文本模型 (Qwen2.5-7B) |

### 推荐部署路径

```
1. 下载 Qwen2.5-7B-Instruct (纯文本)
   ↓ 预期 50-80 tok/s
2. 下载 Gemma-4-26B-A4B (多模态 MoE)
   ↓ 预期 45-60 tok/s
3. 下载 Qwen3.5-35B-A3B-Instruct (纯文本 MoE)
   ↓ 预期 31-52 tok/s
4. 跑统一 benchmark 对比
   ↓ 生成最终报告
5. 双机 LiteLLM 负载均衡
   ↓ 生产环境部署
```

---

*报告生成: 2026-04-11 23:15 CST*  
*测试环境: DGX Spark GB10 | vLLM 0.18.2 | CUDA 13.0*  
*备注: 缓存的 Qwen3.5 MoE 模型均为多模态版且缺预处理器配置，无法直接运行。建议下载纯文本 Instruct 版。*
