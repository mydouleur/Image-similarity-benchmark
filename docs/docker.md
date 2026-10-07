# Docker

> 返回 [README](../README.md)。Agent 测评本身的配置见 [Agent 测评](agentbench.md)。

## benchmark 镜像

```bash
docker build -t imgsim .                 # 只含 benchmark（CPU 版 torch，LPIPS 权重已内置）
docker run --rm imgsim                   # 跑测试
docker run --rm -v "$PWD/models:/app/models" -v "$PWD/outputs:/app/outputs" imgsim \
  python -m src.cli compare-models --reference models/a.glb --candidate models/b.glb --auto-orient
```

也可以用 compose：`docker compose build`，然后 `docker compose run --rm benchmark python -m src.cli ...`
（`data/`、`models/`、`outputs/` 已挂载到宿主机）。要给别的工具（Blender 插件、AI 建模 agent 等）搭出来的模型打分，
让它导出 glb 放进 `models/`，再用上面的 `compare-models` 命令和参考模型比较即可。

API token（Sketchfab 下载、`reproduce` / `generate-model` 需要）：把 `.env.example` 复制为 `.env` 填好，compose 会自动读取；
也可以在宿主机 `export` 后直接透传。`.env` 已被 git 和 Docker 镜像忽略。用 `docker run` 时加 `--env-file .env`。

benchmark 镜像还内置了 Codex CLI 的静态二进制（`ARG CODEX_VERSION=0.160.0`），ENTRYPOINT 会在
`~/.codex/config.toml` 不存在时按 `CODEX_*` / `MCP_URL` 环境变量生成一份——见
[Agent 测评的 Codex CLI 一节](agentbench.md)和下文「Codex 一体化运行」。

## compose 编排与依赖

`docker-compose.yml` 里有两个服务：`benchmark`（imgsim）和 `blender`（imgsim-blender）。需要注意的依赖关系：

* `blender` 服务配了 healthcheck：TCP 探测 8000 端口（`start_period: 60s`，Blender 启动较慢，之后每 5 s 探一次，12 次重试）。
  entrypoint 只在 Blender 的 socket server 起来之后才启动 MCP HTTP 端点，所以健康即代表 MCP 可用。
* `benchmark` 服务 `depends_on: blender: condition: service_healthy`：**`docker compose run benchmark ...` 现在会连带启动
  blender 容器并等它就绪**，跑 agent 测评不用再手动 `docker compose up -d blender`。
  只想跑测试、不需要 Blender 时用 `docker compose run --no-deps --rm benchmark`。

## 无头 Blender + BlenderMCP（给远程 agent 用）

`docker/blender/` 是第二个镜像：Debian 里的 Blender（4.3，amd64 / arm64 都有原生包）以 `blender -b` 无头方式常驻，
里面跑 [blender-mcp](https://github.com/ahujasid/blender-mcp) 的插件；同一容器里的 MCP 服务器改用 Streamable HTTP 传输，
远程 agent 直接连 `http://<主机>:8000/mcp` 就能建模，导出到 `/app/models` 的 glb 会出现在宿主机的 `models/`，再用 benchmark 打分。

```bash
docker compose build blender
docker compose up -d blender             # 端口可用 BLENDER_MCP_PORT=xxxx 改
docker compose logs -f blender           # 看到 "socket server listening" 和 "Uvicorn running" 即就绪

pip install "mcp>=1.9,<2"                   # 宿主机上装 MCP 客户端库（只为冒烟测试）
python scripts/blender_mcp_smoke.py      # 建一个杯子 -> models/mcp_smoke.glb + outputs/mcp_smoke.png
docker compose run --rm benchmark python -m src.cli compare-models \
  --reference models/ref.glb --candidate models/mcp_smoke.glb --auto-orient
```

MCP 客户端配置里只需要 URL，例如 Claude Code：`claude mcp add --transport http blender http://<主机>:8000/mcp`。

无头方式和桌面版插件的区别：

* 原插件在 `-b` 模式下拒绝启动（它靠 `bpy.app.timers` 在主线程执行命令，无窗口时 timer 不会触发）。
  `docker/blender/headless_server.py` 原样加载插件，自己在主线程循环里排空插件的命令队列，所以所有命令仍在主线程执行。
* `get_viewport_screenshot` 没有视口可截，改为从自动取景的相机渲染整个场景（Workbench，失败则退到 Cycles CPU）。
* 依赖 timer 做后续导入的集成（Hyper3D 的异步 glb 导入）不会生效；Poly Haven / Sketchfab / `execute_blender_code` 正常。
* Blender 启动时是默认场景（一个立方体、灯和相机）。agentbench 的 runner 默认每题前自动重置场景
  （`runtime.mcp.reset_scene`，见 [Agent 测评](agentbench.md)）；手动驱动时让 agent 先
  `bpy.ops.wm.read_factory_settings(use_empty=True)` 清空再建模。

环境变量（都在 compose 里透传，写进 `.env` 即可）：`BLENDERMCP_INTEGRATIONS`（默认 `polyhaven,sketchfab`）、
`BLENDERMCP_HYPER3D_API_KEY` / `BLENDERMCP_POLYPIZZA_API_KEY`（Sketchfab 复用 `SKETCHFAB_API_TOKEN`）、
`BLENDER_MCP_SAFE_MODE=1`（执行前校验脚本）、`MCP_ALLOWED_HOSTS`（限制 Host 头，例如 `myhost.example.com:*`）。

安全提示：MCP 端点没有鉴权，连上的人可以在 Blender 里执行任意 Python。只在内网或反向代理加了认证之后再暴露 8000 端口。

## Codex 一体化运行

用 Codex CLI 驱动 Blender 容器做 agent 测评，全程只需要 compose（配置细节见
[Agent 测评的 Codex CLI 一节](agentbench.md)）：

1. `Copy-Item .env.example .env`（或 `cp .env.example .env`），填 `OPENAI_API_KEY`；
   走 OpenRouter 则按 `.env.example` 里的注释改设 `CODEX_PROVIDER` / `CODEX_BASE_URL` / `CODEX_ENV_KEY` / `OPENROUTER_API_KEY`。
2. 构建并启动：

   ```bash
   docker compose build                 # benchmark 镜像内置 codex 二进制（CODEX_VERSION 可换版本）
   docker compose up -d blender         # 无头 Blender + MCP；下面的 run 有 depends_on，也会自动拉起
   docker compose run --rm benchmark python -m src.agentbench run benchmarks/example/command_codex.json
   ```

3. 结果在 `workspaces/example/runs/codex-blender_<时间>/`：每题有 `model.glb`、`scene.blend`、
   `transcript.jsonl`（含 Codex 的 JSON 事件流）、`conversation.md` 和评测目录，`summary.json` 给出各题分数。

`docker compose run benchmark` 会等 blender 健康检查后才开始；Codex 的模型、网关、key 全部由 `.env` 里的
`CODEX_*` 变量决定，entrypoint 负责生成 `~/.codex/config.toml`，不需要改镜像或配置文件。

## 在 Windows (x64) 上部署

两个镜像都是 Linux 镜像，架构跟着 build 的机器走：Mac (Apple Silicon) 上 build 出来的是 arm64，拷到 Windows 上不能用；
在 Windows 机器上重新 build 就得到 amd64 版本，Dockerfile 不用改。

1. 安装 Docker Desktop for Windows，用 WSL2 后端（Settings → General → Use the WSL 2 based engine）。
   Resources 里给 WSL 至少 4 GB 内存；两个镜像加起来约 3.5 GB 磁盘。
2. 在 PowerShell 里：

```powershell
git clone <仓库地址> Image-similarity-benchmark
cd Image-similarity-benchmark
Copy-Item .env.example .env         # 按需填 key
docker compose build                 # 同时构建 imgsim 和 imgsim-blender（第一次 10 到 20 分钟）
docker compose up -d blender         # MCP 端点: http://<这台机器的IP>:8000/mcp
docker compose logs -f blender
docker compose run --no-deps --rm benchmark    # 只跑 benchmark 测试，不拉起 blender
```

3. 远程 agent 从别的机器访问时，Windows 防火墙要放行 8000 端口（Docker Desktop 通常会自动加规则；没有的话
   `New-NetFirewallRule -DisplayName "blender-mcp" -Direction Inbound -LocalPort 8000 -Protocol TCP -Action Allow`）。

注意事项：

* `.gitattributes` 已强制 `docker/` 下的文件和 `*.sh` 用 LF 换行。如果是手动拷贝文件而不是 git clone，确认 `entrypoint.sh`
  不是 CRLF，否则容器会报 `no such file or directory` 启动失败。
* 镜像里跑的是 CPU 版 Blender 和 CPU 版 torch，Windows 主机的显卡不会被用到；无头建模和打分不需要显卡。
* 只想在 Windows 上跑 benchmark 而不用 Docker 的话，见 [README 的安装章节](../README.md)（Windows 可装 CUDA 版 torch 用 GPU 算 LPIPS）。
