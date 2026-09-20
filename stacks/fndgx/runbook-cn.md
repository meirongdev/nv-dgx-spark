# fndgx 部署手册 —— Qwen3.8-Flash-Next 单机版(S2)

上游:<https://github.com/blazux/qwen3.8-Flash-DGX>
「为什么是这些参数」在 `recipe.yaml`,机器可读的身份在 `stack.env`。
这里是**从零重做一遍**要敲什么,以及 2026-09-20 首次部署时真正卡住的四件事。

日常操作不看这份文档,看 `make`:

```bash
make run     STACK=fndgx      # preflight(按节点互斥)→ tmux 里启动 → 等就绪
make status  STACK=fndgx
make test    STACK=fndgx      # 冒烟:身份 / 思考语义 / EFFORT_ALIAS / PLE mmap / 视觉
make logs    STACK=fndgx
make stop    STACK=fndgx
make memwatch STACK=fndgx     # ⚠️ 本栈不是主力栈,看门狗**必须显式起**,见下
```

---

## 0. 它和 qwen38fn 是什么关系

**同一个模型,不同的装法。** 别把两者混为一谈,它们的 served-model-name 只差一个
字符(`qwen3.8-flash-next` vs `qwen38-flash-next`)。

| | qwen38fn | fndgx |
|---|---|---|
| 机器 | S1+S2,TP=2 | 只有 S2 |
| 运行时 | k3s | 裸 docker |
| 48 GiB PLE 表 | 放显存(另有 FP8 补丁) | **mmap 从 NVMe 读** ← 单机能装下的全部原因 |
| 端点 | `:8000` `qwen38-flash-next` | `:18300` `qwen3.8-flash-next` |
| 单流代码 | 62.1 tok/s(旧记录) | 46.5 tok/s(2026-09-20 实测) |
| CoT 字段 | `reasoning_content` | **`reasoning`** |

⚠️ **两者互斥**:qwen38fn 的 rank1 在 S2 上,和本栈抢同一块 GPU。
`make run STACK=qwen38fn` 会被 preflight 拦住并点名 fndgx。

---

## 1. 从零部署

前提:S2 空闲,`~/.ssh/vgio` 能登 `admin@100.67.164.92`,磁盘 ≥ 150 GiB 空余。

### 1.1 取上游代码并打本地补丁

节点上 **github.com / raw.githubusercontent.com 都不通**,所以在 Mac 上克隆、
改完再 rsync 过去。

```bash
git clone --depth 1 https://github.com/blazux/qwen3.8-Flash-DGX.git
cd qwen3.8-Flash-DGX
cp Dockerfile Dockerfile.upstream-orig
cp Dockerfile.v0.29 Dockerfile.v0.29.upstream-orig
# 7 个 ADD 的来源换成 jsDelivr(同一个 commit,--checksum 一个字不动)
sed -i '' -e 's|https://raw.githubusercontent.com/jschmied/qwen38-flash-next-gb10/\${KDET_SHA}|https://cdn.jsdelivr.net/gh/jschmied/qwen38-flash-next-gb10@${KDET_SHA}|g' \
          -e 's|https://raw.githubusercontent.com/jschmied/qwen38-flash-next-gb10/\${KM4_SHA}|https://cdn.jsdelivr.net/gh/jschmied/qwen38-flash-next-gb10@${KM4_SHA}|g' \
          Dockerfile Dockerfile.v0.29
# 校验行必须原封不动
diff <(grep -o 'checksum=sha256:[0-9a-f]*' Dockerfile.upstream-orig) \
     <(grep -o 'checksum=sha256:[0-9a-f]*' Dockerfile)

rsync -a --delete --exclude .git -e "ssh -i ~/.ssh/vgio" ./ admin@100.67.164.92:/home/admin/qwen38-flash-dgx/
ssh -i ~/.ssh/vgio admin@100.67.164.92 'cd qwen38-flash-dgx && chmod +x flash scripts/*.sh'
```

> 换路之后安全性没有降低:BuildKit 仍按上游 pin 的 sha256 校验每个文件。
> 换之前**先验**一遍 jsDelivr 返回的字节和 pin 一致(七个文件全部比过)。

### 1.2 把已有权重呈现成 HF cache 布局

S2 上早就有这份 checkpoint(2026-09-02 为 qwen38fn 下的),是个**扁平目录**;
`serve.sh` 要的是 HF cache 形状。用相对符号链接做一层视图,不复制。

```bash
HUB=~/.cache/huggingface/hub
REV=7b719225242aacd3dbd3f9407468c2ee9a9d2594     # 从 .cache/huggingface/download/*.metadata 第一行读到
REPO=$HUB/models--RadixArk--Qwen3.8-Flash-Next-NVFP4
mkdir -p $REPO/refs $REPO/snapshots/$REV
printf '%s' $REV > $REPO/refs/main
for p in $HUB/Qwen3.8-Flash-Next-NVFP4/*; do
  ln -sfn "../../../Qwen3.8-Flash-Next-NVFP4/$(basename "$p")" "$REPO/snapshots/$REV/$(basename "$p")"
done
```

⚠️ **必须是相对链接**。容器里这份缓存挂在 `/hf`,绝对路径一律解析不到 ——
这是 gotcha #6 的同一个坑,而失败会发生在加载到一半的时候。

验一下:`./flash doctor` 应当报 `✔ checkpoint present: …/snapshots/<rev>`。

### 1.3 构建镜像

```bash
ssh -i ~/.ssh/vgio admin@100.67.164.92 \
  'tmux new-session -d -s flash-build "cd ~/qwen38-flash-dgx && docker build -t qwen38-flash-dgx . 2>&1 | tee ~/flash-build.log"'
```

约 18 分钟,大头是第 8 层用镜像自带 nvcc 编确定性 top-k 内核。
基底镜像的 digest 与 S2 上那份 `docker.m.daocloud.io/vllm/vllm-openai` **完全相同**,
所以不会有 20 GB 下载。

### 1.4 准备 hybrid 布局(一次性,约 10 分钟,+13 GiB)

```bash
ssh -i ~/.ssh/vgio admin@100.67.164.92 \
  'cd ~/qwen38-flash-dgx && MODEL=RadixArk/Qwen3.8-Flash-Next-NVFP4 ./scripts/prepare-hybrid.sh'
```

应当以 `>> done: 300 fp8 side-layer tensors` 结束,并在目录里留下 `.prepared`。

### 1.5 起栈 + 验收

```bash
make run  STACK=fndgx      # launch.sh 里已固定 MODEL / profile / COMPILE_CACHE
make test STACK=fndgx      # 五项必须全过
make memwatch STACK=fndgx  # ⚠️ 单独一个 tmux 会话,见 §3
```

---

## 2. 首次部署真正卡住的四件事

### 2.1 `raw.githubusercontent.com` 20 秒超时,镜像根本构建不出来

Dockerfile 有 7 个 `ADD` 从 raw.githubusercontent.com 取 jschmied 的确定性内核源码
和 M%4 补丁。节点上那个域名不通(github.com 也不通,huggingface.co 直接 refused)。

试过并否决:`ghfast.top`(15 秒超时)、`raw.gitmirror.com`(1 秒 000)。
**可用的是 jsDelivr**:`https://cdn.jsdelivr.net/gh/<owner>/<repo>@<commit>/<path>`,
0.63 秒 200,而且按 commit 取,和上游 pin 的是同一份字节。

### 2.2 上游默认 checkpoint 下不下来,而本地已有的那份是另一个

上游 2026-09-14 起默认 `nvidia/Qwen3.8-Flash-Next-NVFP4`。S2 上有的是
`RadixArk/…`(418 个文件,上游同样支持)。huggingface.co 从节点上连不通,
换不了 —— 所以 **`MODEL=RadixArk/Qwen3.8-Flash-Next-NVFP4` 必须显式传**,
`launch.sh` 里已经固定住了。

`prepare-hybrid.sh` 会先判 checkpoint 类型:RadixArk 的 `config.json` 里
`quant_method=modelopt`(不是 compressed-tensors),所以 hybrid 转换走得通 ——
这一条在动手前专门验过,因为判错的话脚本会直接拒绝并让你用 `MODE=nvfp4`。

### 2.3 看门狗起不来:`'/home/admin/qwen38-flash-dgx/docker' 不存在`

`mem-watch.sh` 的启动自检把 `STACK_MEMWATCH_STOP` 的第一个词当成 `$STACK_DIR`
下的可执行文件。写成裸 `docker rm -f qwen38-flash` 就会被拼成
`$STACK_DIR/docker`,于是 **exit 3,看门狗根本不启动**。

本栈的解法是用上游自己的动词 `./flash rm`(= `docker rm -f`,立刻释放内存;
`./flash stop` 是 `docker stop -t 30`,抢 OOM 时等不起)。

> 顺带查出来:`qwen38` 那栈写的正是裸命令形态,所以它**一直没有过能启动的
> 看门狗**,而 `make memwatch-test` 一直报它 PASS(那边只验字段非空)。
> 2026-09-20 一并修了:自检改成两种形态各做一次真检查(路径 → `test -x`,
> 裸命令 → `command -v`),回归测试也改成验形态而不是验非空。

### 2.4 preflight 拦住了一个根本不冲突的栈

旧的互斥是**全表**的:任何一个栈在跑就拦住所有别的栈。S1 上的主力栈
qwen38un 在跑,于是 S2 整台空着也起不了任何栈。

2026-09-20 改成**按节点集合相交**判(`stacks/_lib/common.sh` 的 `stack_gpu_nodes`,
新字段 `STACK_GPU_NODES`)。关键是**不能只看 `STACK_HEAD`** —— TP=2 栈的 rank1
也吃 GPU 内存,只看 head 会把 qwen38fn(head=S1)判成与本栈无关,然后两者在 S2
上相遇,OOM 掉一台没有 BMC 的机器。`scripts/test-preflight.sh` 里那两条
带 ★ 的用例守的就是这一格。

---

## 3. 常驻运维

### 看门狗必须自己起一份

`make memwatch` 不带 `STACK=` 守的是 `stacks/PRIMARY`(现在是 S1 的 qwen38un)。
**本栈不是主力栈,不显式起就没人守它**:

```bash
tmux new-session -d -s memwatch-fndgx -c ~/projects/meirongdev/nv-dgx-spark \
  'make memwatch STACK=fndgx'
tmux capture-pane -p -t memwatch-fndgx | head -3   # 读启动横幅,确认它守的是 fndgx/S2
```

两个实例互不干扰:状态文件和日志都带栈名(`/tmp/.fndgx-memwatch-fired`)。

⚠️ 起完**一定要读启动横幅**。「`git log` 说 bug 修了」不代表你在修之前
启动的那个守护进程也修了 —— 横幅才是它**实际**在守的东西。

### 内存余量不宽裕

服务中稳态 available **10.7%**,warn=8%、crit=5%。只高出 warn 2.7 个点。
而本仓库刚在 qwen38un 上学过:**启动时的余量不等于稳态余量**(那边 0.85 时
9.4% 两小时后掉到 5.0%,看门狗动手把栈停了)。

本栈的稳态目前只观察了几十分钟。真掉到 crit 以下,看门狗会停掉它并**保持停止**
(反抖动,不自动恢复),用 `make memwatch-reset STACK=fndgx` 解除后 `make run` 拉回来。

要买回余量就降 `GPU_MEM`(改 `profiles/default.env` 里加一行 `GPU_MEM=0.75`)。
⚠️ **不要往上调**:上游报 0.85 跑一天后开始吃 swap,0.875 在 300k prefill 上被 OOM kill,
而这两台机器 swap 是关的、没有 BMC。

### 主机重启后它会自己回来

容器带 `--restart unless-stopped`(上游 serve.sh 给的),这一点和本仓库别的
docker 栈都不同。k3s 的四个 deployment 都是 0 副本,所以重启后不会有人跟它抢。

---

## 4. 升级上游

```bash
cd <mac 上的克隆> && git pull
# 重打 §1.1 的 7 行 URL 补丁(上游一动这两个 Dockerfile 就要重做)
# rsync 过去 → 重新 docker build → make restart STACK=fndgx → make test STACK=fndgx
```

⚠️ 升级后**必须重跑 `make test STACK=fndgx`**:CoT 字段(`reasoning`)和
EFFORT_ALIAS 都是引擎构建层面的性质,上游换基底镜像就可能变,而两者变了
都**不报错**。
