# Agent 测评（配置文件驱动，无头运行）

> 返回 [README](../README.md)。Docker 环境和 Codex 一体化运行步骤见 [Docker](docker.md)。

`python -m src.agentbench` 按一个 JSON（或 YAML）配置文件跑完整个测评：让大模型 agent 在指定的运行环境里
（Blender MCP、本项目自带的工具，或者任意别的 agent 命令行）根据提示词和参考图片建模，把它每一步的思考过程、
工具调用和结果、看到的截图都记下来，最后用 `compare-models` 流程给它导出的模型打分，还可以把分数反馈给它再改一轮。
命令本身不带任何题目相关的参数：题目、模型 API、工作区全部写在配置文件里，同学们改好配置文件直接启动即可。

```bash
python scripts/make_agent_example.py                                    # （可选）重新生成示例题目：马克杯
python -m src.agentbench check benchmarks/example/mcp_blender.json      # 检查配置、参考图片、MCP 工具列表，不调用模型
python -m src.agentbench run   benchmarks/example/mcp_blender.json      # 正式运行
python -m src.agentbench run   benchmarks/example/mcp_blender.json --task mug --set llm.model=qwen3-vl-max   # 只跑一题 / 临时覆盖配置
```

Docker 里运行（Blender MCP 和 benchmark 两个容器，`workspaces/` 在两边都挂载在 `/app/workspaces`）：

```bash
docker compose up -d blender            # 已经在跑的话也要重新执行一次，让新的 workspaces 挂载生效
docker compose run --rm benchmark python -m src.agentbench run benchmarks/example/mcp_blender.json
```

## 配置文件格式

示例见 [benchmarks/example/](../benchmarks/example/)：`mcp_blender.json`（Blender MCP + OpenAI 兼容接口）、
`builtin_python.json`（本项目工具 + Claude）、`command_claude_code.json`（调用外部 agent 命令行）、
`command_codex.json`（Codex CLI 驱动 Blender MCP，见下文「Codex CLI agent」）。

```jsonc
{
  "name": "mug-blender-mcp",                 // 运行名，输出目录叫 <name>_<时间>
  "description": "",

  // 1. 运行环境类型
  "runtime": {
    "type": "mcp",                           // mcp | builtin | command
    "mcp": {
      "transport": "streamable_http",        // streamable_http | sse | stdio
      "url": "${MCP_URL:-http://localhost:8000/mcp}",
      "workspace_path": "/app/workspaces/example",   // MCP 服务器看到的工作区路径（Docker 挂载点）；本机服务器可省略
      "exclude_tools": ["*sketchfab*", "*tripo*"]    // 屏蔽的 MCP 工具（通配符），也有 include_tools
    },
    "tools": ["list_files", "read_image", "render_views"]   // 额外提供的本项目工具，见下表
  },

  // 2. 大模型 API：格式 + URL + key + 模型名
  "llm": {
    "api_format": "openai",                  // openai（/chat/completions 兼容接口）| openai_responses（OpenAI /responses）| anthropic（Claude）
    "base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1",
    "api_key": "${LLM_API_KEY}",             // 从环境变量或 .env 读，不要把 key 写进文件
    "model": "qwen3-vl-plus",
    "max_tokens": 16000
  },

  // 3. 工作区：agent 在哪个文件夹下工作，输出放在哪里
  "workspace": {
    "root": "../../workspaces/example",      // 相对配置文件所在目录
    "output_dir": "runs"                     // 相对 root；每次运行建 runs/<name>_<时间>/<题目 id>/
  },

  "limits": {"max_turns": 40, "timeout_seconds": 1800, "tool_timeout_seconds": 300},
  "evaluation": {"enabled": true, "auto_orient": true, "feedback_rounds": 1},

  // 4. 题目列表：每题一个提示词 + 参考图片位置（相对工作区，可用通配符），模型自己用 read_image 去读
  "tasks": [
    {
      "id": "mug",
      "prompt": "做一个马克杯的三维模型……",
      "reference_images": ["refs/mug/*.png"],
      "reference_model": "answers/mug.glb"   // 打分用的参考模型，相对配置文件；不给 agent 看
    }
  ]
}
```

系统提示词是内置的（[src/agentbench/runner.py](../src/agentbench/runner.py) 的 `SYSTEM_PROMPT`，会根据运行环境自动加上
工作区、输出路径、Blender 用法等说明；MCP 服务器自带的 instructions 也会附上），配置里只写每道题的提示词。

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `runtime.type` | `mcp` | `mcp`：工具来自 MCP 服务器；`builtin`：只用本项目工具；`command`：运行别的 agent 命令行 |
| `runtime.tools` | 按类型 | 本项目工具：`list_files` `read_file` `write_file` `read_image` `run_python` `render_views` `generate_3d` |
| `runtime.mcp.transport` / `url` / `command` / `args` / `env` / `headers` | `streamable_http` | stdio 方式用 `command` + `args` 由 runner 启动服务器 |
| `runtime.mcp.workspace_path` | 无 | 工作区在 MCP 服务器那边的路径；设置后 `output_dir` 必须在 `root` 里面 |
| `runtime.mcp.include_tools` / `exclude_tools` | 全部 | 按名字通配符筛选 MCP 工具，例如屏蔽资产库下载，逼 agent 自己建模 |
| `runtime.mcp.reset_scene` | `true` | 每题开始前把 Blender 场景重置为空（见「场景隔离与留痕」） |
| `runtime.mcp.save_scene` | `"scene.blend"` | 每题结束后把 Blender 场景保存为该题目录下的这个文件；设为 `null` 关闭 |
| `runtime.command` | 无 | 字符串（走 shell）或参数列表；占位符 `{prompt}` `{prompt_file}` `{workspace}` `{output_dir}` `{output_model}` `{images}` `{task_id}` `{model}` `{base_url}` |
| `runtime.env` | `{}` | 给 `run_python` / `command` 子进程加的环境变量 |
| `runtime.generate` | Tripo v3.1，无贴图，最多 1 次 | `generate_3d` 工具的设置（`provider` `model_version` `max_calls` `allow_image` …），会消耗点数 |
| `llm.api_format` | `openai` | `openai`（`/chat/completions`，各家兼容接口）/ `openai_responses`（OpenAI 的 `/responses`；gpt-6 这类推理模型在 chat 接口上不能同时思考和调用工具，要用它）/ `anthropic` |
| `llm.base_url` / `api_key` / `model` | — | `anthropic` 格式可以不写 `base_url` |
| `llm.thinking` | Claude：`{"type":"adaptive","display":"summarized"}` | 原样传给 Claude 的 `thinking` 参数，`null` 表示不传 |
| `llm.supports_images` | `true` | 纯文本模型设为 `false`，图片就不发给它 |
| `llm.echo_reasoning` | `false` | OpenAI 兼容接口：把 `reasoning_content` 回传（DeepSeek / Kimi 的思考模式调用工具时需要） |
| `llm.extra_body` | `{}` | 原样合并进请求体，例如 `{"output_config": {"effort": "high"}}`、`{"enable_thinking": true}` |
| `limits.max_turns` | 40 | 每题最多调用模型的次数（含反馈轮） |
| `limits.timeout_seconds` | 1800 | 每题总时长 |
| `evaluation.feedback_rounds` | 0 | agent 说做完之后，把分数、各视图分数和 report.png 发回给它再改几轮 |
| `evaluation.*` | shape.yaml、auto_orient、六视图 | `benchmark_config` `views` `up` `size` `mesh_weight` `rig_weight` `feedback_images` |
| `tasks[].reference_images` | `[]` | 相对工作区的路径或通配符 |
| `tasks[].reference_model` / `reference_views` | 无 | 打分依据：参考模型，或者一个装着 `front.png` `side.png` … 的文件夹；都不给则只记录不打分 |
| `tasks[].attach_images` | `false` | 把参考图片直接放进第一条消息（没有 `read_image` 工具时自动这样做） |
| `tasks[].output_model` | `model.glb` | agent 必须把模型存到 `<题目输出目录>/<这个文件名>` |

字符串里的 `${变量}` / `${变量:-默认值}` 用环境变量替换，配置文件旁边或项目根目录的 `.env` 会先被读入；未知的键直接报错。
相对路径以配置文件所在目录为准（`output_dir` 和 `reference_images` 以工作区为准）。

## 三种运行环境

* **`mcp`**：连接 MCP 服务器（默认是 `docker compose up -d blender` 起的无头 Blender，`http://localhost:8000/mcp`），
  服务器的工具和 `runtime.tools` 里的本项目工具一起交给模型。模型用 `execute_blender_code` 建模、用 `get_viewport_screenshot`
  看效果、按系统提示词里给的**容器内路径**导出 glb；runner 在宿主机上读到同一个文件并打分。
* **`builtin`**：不需要 Blender。模型用 `run_python` 写 trimesh 脚本生成网格（`os.environ["OUTPUT_MODEL"]` 就是输出路径），
  用 `render_views` 按打分器同样的方式渲染自己的模型检查。可选 `generate_3d`（Tripo / Meshy 文生 3D，付费，受 `max_calls` 限制）。
* **`command`**：运行任意外部 agent（Claude Code、Codex CLI、同学自己写的脚本……）。runner 负责拼好提示词（含参考图片路径和输出路径）、
  通过占位符和环境变量（`OUTPUT_MODEL` `WORKSPACE` `LLM_BASE_URL` `LLM_API_KEY` `LLM_MODEL`，以及 `OPENAI_*` / `ANTHROPIC_*`）传进去，
  逐行记录 stdout / stderr（JSON 行会解析成结构化事件，例如 `--output-format stream-json`），结束后给它留下的模型打分。
  command 运行环境也可以带 `runtime.mcp` 块：不会给 agent 注入工具，仅供 runner 做场景管理（见「场景隔离与留痕」）；
  设了 `runtime.mcp.workspace_path` 时，提示词里还会说明 MCP 服务器侧的路径映射（workspace 在服务器那边是哪个路径、
  该把 glb 导出到哪里），`output_dir` 同样要求在 workspace root 里面。

## 场景隔离与留痕

多道题共用同一个 Blender（同一个 MCP 服务器）时，上一题留下的物体会污染下一题的模型和分数。`runtime.mcp` 的两个开关控制 runner 的场景管理：

* **`reset_scene`（默认 `true`）**：每题开始前，runner 通过 `execute_blender_code` 强制执行
  `bpy.ops.wm.read_factory_settings(use_empty=True)`，再跑三遍 `bpy.data.orphans_purge(do_recursive=True)` 清掉残留数据块。
  重置失败（MCP 返回错误）时**该题直接判 error**——宁可失败也不在被污染的场景里跑。服务器不提供 `execute_blender_code` 时跳过重置并记一条事件。
* **`save_scene`（默认 `"scene.blend"`）**：每题结束后，把 Blender 场景用 `bpy.ops.wm.save_as_mainfile` 保存为该题目录下的
  `scene.blend`，事后可以直接打开复查 agent 到底建了什么。保存失败只记警告，不影响题目状态。

连接复用：`mcp` 运行环境本来就连着同一个 MCP 服务器，重置 / 保存复用任务的连接；`command` 运行环境如果配了 `runtime.mcp`，
runner 会在命令运行前连上服务器做重置、命令结束后保存场景，但**不会**把任何 MCP 工具注入给 agent（工具从哪来由外部 agent 自己决定，
例如 Codex CLI 通过它自己的 `~/.codex/config.toml` 连同一个 Blender）。

留痕新增字段：

* `summary.json` 新增 `versions`：本次运行的包版本（`image-similarity-benchmark`）和 git 短 hash，方便追溯分数是哪个代码版本打出来的。
* `task.json` 的 outcome 新增 `scene_blend`（保存的 .blend 相对路径）和 `mcp_server`（MCP 服务器的名称和版本）。
* `transcript.jsonl` 新增 `scene_reset` / `scene_saved` 事件；command 模式的 transcript 会先记一条 `command_start`，
  内容是占位符展开后的完整命令（提示词本体用 `<prompt>` 代替，全文仍在 `prompt.md`）。

## Codex CLI agent（`benchmarks/example/command_codex.json`）

示例配置 `command_codex.json` 演示 command 运行环境 + 场景管理的组合：benchmark 镜像内置的 Codex CLI 以无头方式

```bash
codex exec --json --skip-git-repo-check --sandbox workspace-write "{prompt}"
```

运行，`{prompt}` 是 runner 拼好的题目提示词（含参考图片路径和输出路径）。Codex 通过它自己配置里的
`[mcp_servers.blender]` 连 compose 里的无头 Blender 容器建模，runner 则通过 `runtime.mcp` 块连同一个服务器做场景重置和保存
（不给 Codex 注入工具）。示例包含 mug / table / chair 三道题。

镜像与配置：

* benchmark 镜像（根目录 `Dockerfile`）内置 codex 静态二进制（musl 版，不需要 Node.js），
  `ARG CODEX_VERSION=0.160.0` pin 在稳定版——alpha 版有一个 `codex exec` 不注册 streamable-HTTP MCP 工具的 bug（openai/codex#38689）。
  换版本：`docker compose build --build-arg CODEX_VERSION=<版本> benchmark`。
* 镜像的 ENTRYPOINT [docker/benchmark/codex-entrypoint.sh](../docker/benchmark/codex-entrypoint.sh) 在
  `~/.codex/config.toml` 不存在时按环境变量生成一份：

  | 环境变量 | 默认 | 写入 |
  | --- | --- | --- |
  | `CODEX_MODEL` | `gpt-5-codex` | `model` |
  | `CODEX_PROVIDER` | `openai` | `model_provider` |
  | `CODEX_BASE_URL` | `https://api.openai.com/v1` | `[model_providers.<provider>] base_url`（provider 为 openai 且未显式设置时不写这段，用内置 provider） |
  | `CODEX_ENV_KEY` | `OPENAI_API_KEY` | `[model_providers.<provider>] env_key` |
  | `CODEX_WIRE_API` | openai 为 `responses`，其他为 `chat` | `[model_providers.<provider>] wire_api` |
  | `MCP_URL` | `http://blender:8000/mcp` | `[mcp_servers.blender] url` |

  想完全接管配置（自己的 provider 段、审批策略等），把自己的文件挂载到 `/root/.codex/config.toml` 即可，entrypoint 不会覆盖。
* **OpenRouter**（或任何 OpenAI 兼容网关）：`.env` 里设 `CODEX_PROVIDER=openrouter`、`CODEX_BASE_URL=https://openrouter.ai/api/v1`、
  `CODEX_ENV_KEY=OPENROUTER_API_KEY`、`CODEX_MODEL=<厂商/型号>`、`OPENROUTER_API_KEY=sk-or-...`，无需改镜像。
  `.env.example` 已有对应条目。

运行（详见 [Docker 的 Codex 一体化步骤](docker.md)）：

```bash
docker compose up -d blender
docker compose run --rm benchmark python -m src.agentbench run benchmarks/example/command_codex.json
```

## 记录下来的东西

```text
workspaces/example/runs/mug-blender-mcp_20260928_212902/
├── config.json          实际生效的配置（API key 已打码）
├── summary.json / .md   每题一行：状态、分数、轮数、工具调用次数、token、耗时；外加 versions（包版本 + git 短 hash）
└── mug/
    ├── model.glb        agent 的最终模型
    ├── scene.blend      题目结束时的 Blender 场景（配了 runtime.mcp 且 save_scene 开启时）
    ├── prompt.md        发给模型的系统提示词和第一条消息
    ├── transcript.jsonl 全部事件：每轮模型输出（正文、思考过程 reasoning、工具调用、token、耗时）、工具结果、评测、反馈、错误，
    │                    以及 scene_reset / scene_saved / command_start（command 模式展开后的命令）
    ├── conversation.md  同样的内容，可直接阅读：思考过程、代码、工具结果、截图
    ├── images/          模型看到的每一张图（参考图、Blender 截图、渲染图）
    ├── scripts/         run_python 执行过的脚本
    ├── eval/ eval_2/ …  每次评测的 metrics.json / report.png / renders
    └── task.json        该题的 outcome：状态、分数、token、scene_blend、mcp_server 等
```

思考过程：OpenAI 兼容接口记录返回的 `reasoning_content` / `reasoning`（DeepSeek、Qwen、Kimi、OpenRouter 等），
`openai_responses` 记录推理摘要（reasoning summary，模型觉得不需要思考时可能为空），
Claude 记录 thinking 块（默认 `display: "summarized"`，即模型思考的摘要）；不返回思考内容的模型只有正文。
任务状态：`completed`、`no_model`（结束了但没存模型）、`max_turns`、`timeout`、`llm_error`、`refused`、`command_failed`、`error`。
中途 Ctrl-C 也会保留已经记录的内容。全部题目 `completed` 时退出码为 0，否则为 1，配置错误为 2。

## 注意

* 参考模型（答案）放在工作区外面（示例里是 `benchmarks/example/answers/`，只挂载进 benchmark 容器，不挂进 Blender 容器）。
  本项目的文件工具会拒绝读工作区以外和答案所在的路径，但 `run_python` 和 `command` 是在本机直接执行代码，**不是沙箱**：
  正式测评请在 Docker 里跑，或者至少不要把答案放在 agent 能访问的位置。
* 示例的 `mcp_blender.json` 屏蔽了 Blender MCP 的资产库和 AI 生成工具（Sketchfab、Poly Haven、Tripo、Hyper3D……），
  否则 agent 可以直接下载一个现成的杯子。要测"会不会用资产库"时把 `exclude_tools` 删掉即可。
* 一道题里模型保存了新的 `model.glb` 才会重新打分；`feedback_rounds` 会把参考模型的渲染图（report.png）发给 agent，
  这等于给了它更多参考信息，比较不同模型时要保持这一项一致。
