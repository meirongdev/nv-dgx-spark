# 栈注册表 —— 加一个模型要做什么

> **一句话:新建 `stacks/<id>/`,填一份 `stack.env`。既有文件一个都不用改。**

这个目录是本仓库对同一个问题的第三次回答。前两次是「记得改这 8 个地方」
和「照着 `docs/stack-switch-cn.md` 逐行走」—— 两次都失败了,因为这一类改漏
**不报错**:工具照常返回一个看起来完全正常的结果,只是那个结果是错的
(三次事故的经过见 `docs/stack-switch-cn.md` §0)。

所以现在栈的身份不再散落在工具里,而是集中成数据:

```
stacks/
├── PRIMARY                 一行:当前主力栈的 id。**唯一**的"谁是主力"事实源
├── _lib/                   通用驱动(加模型时不看这里)
│   ├── stackctl.sh         make 的所有动词都走它
│   ├── common.sh           注册表读取 + 字段校验
│   ├── preflight.sh        遍历整个注册表做互斥 + 资产自检
│   └── adapter-{k3s,docker}.sh   运行时适配器
└── <id>/
    ├── stack.env           ← **唯一必填的文件**(机器可读的身份)
    ├── recipe.yaml           为什么是这些参数(人读的;强烈建议有)
    ├── test.sh               冒烟测试(强烈建议有)
    ├── launch.sh             启动包装(docker 栈按需)
    ├── preflight.sh          本栈专属的额外闸门(按需)
    ├── Makefile.mk           本栈专属的 make 目标(按需)
    ├── k8s/                  k3s 栈的 manifests(按需)
    └── runbook-cn.md         从零部署 + 踩过的坑(按需)
```

---

## 加一个模型:三步

### 1. 建目录,写 `stack.env`

抄一份形态最接近的:单节点 docker 看 `qwen38un/`,跑上游编排器的看 `glm53/`,
k3s TP=2 看 `qwen38fn/`。

必填六项(缺任何一项,所有工具都会**拒绝启动**而不是带着半个身份跑):

| 字段 | 含义 |
|---|---|
| `STACK_ID` | 必须等于目录名 |
| `STACK_NAME` | 人读的名字 |
| `STACK_RUNTIME` | `k3s` / `docker` / `external`(本地模型,只供客户端切换) |
| `STACK_MODEL` | **served-model-name —— 栈的真正身份**,全局唯一 |
| `STACK_PORT` | 端点端口(可以和别的栈重号,它们互斥) |
| `STACK_HEAD` | 暴露 OpenAI API 的那台 |

⚠️ **三个最危险的可选字段**,因为它们写错**不会报错**(gotcha #9):

| 字段 | 例 |
|---|---|
| `STACK_THINK_KWARG` | `enable_thinking` / `thinking` / `reasoning_effort` —— 五个栈五套 |
| `STACK_THINK_OFF` | `{"enable_thinking": false}`;本栈关不掉就填最低档并在注释里写明 |
| `STACK_COT_FIELD` | `reasoning_content` 还是 `reasoning` —— 读错的表现是"一个字都没有",与"思考没生效"完全同形 |

其余字段按运行时分工,见各栈 `stack.env` 里的注释。至少要让下面两件事成立:

- **看门狗停得掉它。** docker 栈要有 `STACK_STOP_CMD`(以及成对停 head+worker 的
  `STACK_MEMWATCH_STOP`),k3s 栈要有成对的 `STACK_DEPLOYS`。
  漏填会被 `make memwatch-test` 当场逮住 —— 它对**每一个**注册的栈都验一遍。
- **preflight 拦得住它。** 填 `STACK_WEIGHTS` / `STACK_WEIGHTS_SHARDS` /
  `STACK_IMAGE`,通用 preflight 就会替你数分片、查镜像。

### 2. (可选)放钩子

| 文件 | 什么时候需要 |
|---|---|
| `launch.sh` | 启动要定制环境变量。⚠️ 定制**必须固定在脚本里**,不要穿 make→ssh→tmux→bash 四层引号 —— 带空格的变量会在中途断掉,而失败信息完全不提这件事(2026-09-19 实测) |
| `test.sh` | 冒烟测试。身份由 stackctl 注入(`MODEL`/`URL`/`THINK_OFF`/`COT_FIELD`),**脚本里不要写死** |
| `preflight.sh` | 本栈专属闸门(如 glm53 的主机内存),非 0 退出即拦住起栈 |
| `Makefile.mk` | 本栈专属的 make 目标,主 Makefile 自动 `-include` |

### 3. 验收

```bash
make stacks                  # 新栈出现在注册表里
make stack-check             # 注册表自洽 + 文档表格没过期
make memwatch-test           # 新栈的看门狗动作可用(会自动覆盖它)
make preflight-test          # 新栈与其它每一个栈互斥(同样自动覆盖)
make preflight STACK=<id>    # 互斥 + 权重 + 镜像
make run       STACK=<id>
make test      STACK=<id>    # 含身份闸门:/v1/models 必须报出 STACK_MODEL
```

**要它成为主力栈:`make switch TO=<id>`**(停旧的 → 改 PRIMARY → 起新的 →
重生成文档表格 → 切客户端 → 打印机器做不了的那几条)。

---

## 不用改的东西(这就是重点)

加模型时以下文件**一行都不用动**,它们全部从注册表推导:

| 文件 | 它怎么知道 |
|---|---|
| `Makefile` | 动词是通用的,`STACK=` 决定对象;每栈专属目标走 `-include stacks/*/Makefile.mk` |
| `scripts/mem-watch.sh` | 读 `stacks/PRIMARY`(或参数指定的栈) |
| `scripts/gb10-clock-cap.sh` | 同上,verify 的 model/port/思考 kwarg 全从注册表取 |
| `scripts/qwen-model-switch.sh` | 目标列表 = 注册表,`--help` 现场列出来 |
| 各栈的 preflight | 互斥是**遍历注册表**得出的,不是手写名单 —— 新栈一落地,所有既有栈自动开始检查它 |
| `CLAUDE.md` / `README.md` / `docs/clients-cn.md` 的表格 | `make stack-table` 生成,`make stack-check` 校验 |

---

## 写跨栈工具时的规则

这几条是三次事故换来的,加任何**跨栈**工具时适用:

1. **不要在工具里写栈的默认值。** 从注册表读。想临时指向别的栈就收一个参数
   (`CAP_STACK=` / `make ... STACK=`),但**没有"默认是上一个主力栈"这种东西**。
2. **判据必须验证它真的跑了。** `curl` 的退出码**不算** —— model 名写错时
   vLLM 返回 400 而 `curl` 照样 rc=0;SGLang 更狠,它**接受任意 model 名**
   并原样回显(gotcha #10)。要认真实的产物:生成了多少 token、采到多少个点。
3. **没跑成就硬失败(非 0 退出)**,不要打印一个可能被读成"通过"的数字。
4. **负向用例和正向用例一样重要** —— 这类 bug 的全部危害就是「失败路径看起来
   像成功」。故意传一个错的栈标识,确认它**响**:

   ```bash
   CAP_MODEL=不存在的名字 bash scripts/gb10-clock-cap.sh verify; echo $?   # 必须非 0
   ```
5. **一个分不清"通过"和"根本没运行"的检查器,比没有检查器更糟** ——
   后者你知道自己没验,前者让你以为验过了。

正面样板:`stacks/_lib/stackctl.sh` 的 `stack_assert_served_name`(每个栈白拿
一道身份闸门)和 `scripts/mem-watch.sh` 的启动自检(停不掉就 `exit 3`,
宁可根本不启动,也不当一道静默失效的防线)。
