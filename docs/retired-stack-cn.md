# 退役栈(可复活):Qwen/Gemma 分节点 vLLM + Bifrost 网关

> 从 `CLAUDE.md` 拆出(2026-08-15)。**这套已停用**,拆掉是为了把两块 GPU 让给
> DeepSeek-V4-Flash。但 playbook / Makefile 目标 / 配置**全都还能用**,随时可复活。
>
> ⚠️ **两台机器上的模型权重已全部删除** —— Gemma-4/Qwen3.5 在最初拆栈时删的,
> Qwen3.6-35B-A3B-FP8(每节点 35GB)是 **2026-08-13** 删的
> (此前本文一直声称它已被删,实际它活到了那天)。**复活前要先从 ModelScope 重新下载。**

组成:Qwen3.6-35B-A3B / Gemma-4-31B / Qwen3.5-122B 分节点 vLLM + Bifrost 网关。
和当前主栈的区别是:这套由 **Ansible** 驱动(当前的 V4-Flash 是 k3s,
降级栈 qwen38 是裸 docker)。

## 命令

```bash
make all                           # bootstrap:venv + inventory + SSH 测试
make stack-deploy                  # 两台起 vLLM + 网关;primary = qwen36
make stack-deploy STACK_MODEL=gemma4
make stack-status | stack-stop

make vllm-qwen36-deploy            # Qwen3.6-35B-A3B-FP8(原默认 primary)
make vllm-gemma4-deploy            # Gemma-4-31B-IT-NVFP4
make vllm-qwen-deploy              # Qwen3.5-122B-A10B-NVFP4
make vllm-qwen36-{status,stop,logs}    # logs 用 HOST=... 指定机器
make vllm-status VLLM_CONTAINER=vllm-xyz VLLM_PORT=30000   # 通用变体
make bifrost-deploy | bifrost-status | bifrost-test | bifrost-stop
```

## 加一个新模型(Ansible 栈)

1. 在 Makefile 顶部附近加一组 `VLLM_<NAME>_*` 变量(照抄 Qwen3.6 那块:
   模型路径、served name、端口等)。
2. 在 "Per-model vLLM Deployments" 段末尾加
   `vllm-<name>-{deploy,status,stop,logs}` 目标(照抄 Qwen3.6 的,
   改 `-e` 变量和容器名)。**记得把名字加进 `.PHONY`。**
3. `make vllm-<name>-deploy` 部署;用 `make stack-deploy STACK_MODEL=<name>`
   让它成为默认。

所有模型共用同一个 playbook `playbooks/vllm-model-deploy.yml`。
可选的按模型开关都是 `-e` 变量:`vllm_chat_template_src`、`vllm_patch_script_src`、
`ms_cache_dir`、`vllm_model_validate_path`、`vllm_cleanup_containers`。

## Bifrost 路由(`config/bifrost-config.json`)

Bifrost 兼容 OpenAI 接口,但要求 `model` 字段写成 `<provider>/<model>`。

| Provider | 上游 | `/v1/responses*` | `/v1/chat/completions` |
|---|---|---|---|
| `vllm-server1` | `http://192.168.200.101:30000` | ✅ 启用 | ✅ 启用 |
| `vllm-server2` | `http://192.168.200.102:30000` | ❌ 禁用 | ✅ 启用 |

**有状态的 Responses API 必须钉在 `vllm-server1`** —— `previous_response_id`
是单节点上的内存态存储。

`:8080` 上的 `/v1/models` 返回 `{"data": []}` —— Bifrost 不代理上游的模型列表;
要看 vLLM 实际加载了什么就 `curl …:30000/v1/models`。

## Bifrost 鉴权(virtual keys)

配置里的 `governance.virtual_keys[]`,客户端把 VK 当 Bearer token 发。

- VK 值:`sk-bf-dgx-spark-cluster-2026`(id `dgx-spark-cluster`)
- 允许的模型:**要显式列举**(测试中 `["*"]` 通配符不生效)。
- ⚠️ **注意**:Bifrost 只在 Bearer 匹配到某个已定义 VK 时才执行 VK 限制;
  **未知/缺失的 Bearer 会直接放行且不受限**。所以 `:8080` 只能算
  "在 Tailscale 上就算已鉴权",**不是一个可以公网暴露的 API**。

## 旧模型的踩坑

- **Qwen3 系列** —— tool parser 用 `qwen3_coder`,reasoning parser 用 `qwen3`
  (CoT 在 `.choices[0].message.reasoning`,答案在 `.content`)。
  `max_tokens=10` 的冒烟测试会看到 content 为空 —— **是 reasoning 把预算吃光了**,
  用 ≥256。
- **Qwen3.5 chat_utils** —— 多轮 tool-call 历史配 `qwen3_coder` 时,可能吐出一个
  尾随字节,导致 `chat_utils._postprocess_messages` 里的 `json.loads()` 挂掉。
  修法:`scripts/patch-vllm-chat-utils.py`(改用 `JSONDecoder.raw_decode()`),
  由 entrypoint wrapper 应用。
- **Gemma-4 `skip_special_tokens`** —— `ResponsesRequest` 默认
  `skip_special_tokens=True`,会把 Gemma-4 吐出的 `<|tool_call>` 分隔符剥掉。
  修法:`scripts/patch-vllm-gemma4-parser.py`,容器启动时应用。

## 相关文件

- `playbooks/vllm-model-deploy.yml`、`playbooks/bifrost-deploy.yml`
- `config/bifrost-config.json`
- `scripts/run-vllm-qwen.sh`、`scripts/vllm-entrypoint.sh`、`scripts/patch-vllm-*.py`
- `docs/bifrost-deployment-guide-cn.md` —— Bifrost 详细部署指南
