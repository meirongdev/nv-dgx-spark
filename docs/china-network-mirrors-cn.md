# 中国大陆网络下在 DGX 上拉取镜像 / 模型

两台 DGX Spark 位于中国大陆,**绝大多数境外镜像仓库不可达或极慢**。本文记录验证过的可用通道与避坑要点。

## TL;DR(直接照这个做)

| 要拉的东西 | 用什么 | 命令 |
|---|---|---|
| **Docker 镜像**(官方/热门) | **daocloud 显式前缀** | `docker pull docker.m.daocloud.io/<org>/<img>:<tag>` 然后 `docker tag` 回原名 |
| **模型权重** | **ModelScope** | `/home/admin/modelscope-venv/bin/modelscope download --model <id> --local_dir <dir>` |
| **Python 包** | **清华 PyPI** | `pip install <pkg> -i https://pypi.tuna.tsinghua.edu.cn/simple` |

每台 DGX 走**自己的国内下行**直接拉(实测 ModelScope/daocloud ~10MB/s+),**不需要**任何代理/VPN/中转。

## Docker 镜像:用 daocloud,拉官方镜像

```bash
# 例:官方 SGLang(daocloud 不挡热门官方组织)
docker pull docker.m.daocloud.io/lmsysorg/sglang:v0.5.12
docker tag  docker.m.daocloud.io/lmsysorg/sglang:v0.5.12  lmsysorg/sglang:v0.5.12
```

- daocloud(`docker.m.daocloud.io`)对**热门官方组织镜像**(如 `lmsysorg/*`)放行;对**冷门个人/组织镜像**(如 `scitrera/*`)走**白名单拒绝**(`this image is not in the allowlist`)。
- **两台各拉各的**(并行,都是国内快网),省去节点间传输;或一台拉好后经 200G 内网分发:
  ```bash
  docker save lmsysorg/sglang:v0.5.12 | ssh 192.168.200.<对端> 'docker load'
  ```
- 在 **非 DGX 机器**(如 x86 笔记本)上拉给 GB10 用时,必须 `--platform linux/arm64`(GB10 是 aarch64),否则拿到 x86 镜像跑不了。

## 模型权重:用 ModelScope

```bash
/home/admin/modelscope-venv/bin/modelscope download \
  --model deepseek-ai/DeepSeek-V4-Flash-0731 --local_dir /home/admin/.cache/huggingface/hub/DeepSeek-V4-Flash-0731
```
很多 HF 仓库(含 `unsloth/*`、`RedHatAI/*`)在 ModelScope 同名可下。**hf-mirror 对大 `*.safetensors` 会 `connection reset`,不要用它下大权重。** 长任务套 `tmux` 防 SSH 掉线。

## 节点间传输:走 200G 内网(`192.168.200.101/102`,CX7)

```bash
ssh-keyscan -H 192.168.200.102 >> ~/.ssh/known_hosts   # 先做,否则 rsync 的 ssh 卡在 host-key 确认
rsync -a --partial /src/ 192.168.200.102:/dst/          # 实测 ~390 MB/s
```

## 不要踩的坑(实测均失败)

- **S1 上 `docker build` 被 `~/.docker/config.json` 的 `proxies.default` 静默注入代理**(`HTTP(S)_PROXY=172.17.0.1:10809`),国内源被迫绕道国外:实测同一清华源 **18 KB/s(走代理) vs 1.6 MB/s(直连)**,表现和"镜像源慢"一模一样。`--build-arg http_proxy=` 只救 apt,救不了 HTTPS 的 uv/pip。**修法:构建期间把 `~/.docker/config.json` 挪开**(纯客户端配置,daemon 不重启,不影响在跑的 vLLM 容器;带 `trap ... EXIT` 恢复的脚本见 `benchmarks/aider-polyglot-deepseek-v4-flash-2026-08-01/build_noproxy.sh`)。registry *pull* 走 daemon,不受此文件影响。
- **`/etc/docker/daemon.json` 里的 registry-mirrors 经常不生效**(docker 仍回落到被墙的 `registry-1.docker.io`)→ 用 **显式前缀** `docker.m.daocloud.io/<image>` 绕过。
- **Cloudflare 托管的代拉域名**(`docker.agsv.top`、`hub.rat.dev`、`1ms.run` 的 blob 等)→ blob 走 Cloudflare(104.x),国内 `connection reset`。
- **NGC `nvcr.io`** → auth 端点(AWS)间歇性 reset,不稳。
- **拿 Mac 等机器经 Tailscale 中转** → Mac↔DGX 多为 **DERP 中继**(`relay "hkg"`,`direct connection not established`),实测 **~0.15 MB/s**,12GB 要 8 小时,基本不可用。只有当 `tailscale ping` 显示 direct 直连时才值得用。

## 排错速查

- 测镜像源是否活:`curl -sS -o /dev/null -w '%{http_code}' --max-time 8 https://<mirror>/v2/`(401/200=活)。
- Tailscale 是否直连:`tailscale ping <ip>`(出现 `via DERP` = 中继,慢)。
- daocloud 拒绝某镜像:换官方/热门组织的等价镜像;daocloud 只放行白名单内(热门)的。
