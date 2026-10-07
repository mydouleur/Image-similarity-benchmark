# Image Similarity Benchmark

一个简单、稳定、可解释的 Python 图片相似度 Benchmark。

输入一组 **reference** 图片和一组 **candidate** 图片，按**相同文件名（不区分大小写）**一一配对，
对每一对图片计算 SSIM、LPIPS、Silhouette IoU 和 Edge similarity，输出每张图片的 0–100 分数和所有图片的综合分数。

```text
reference/front.png <-> candidate/front.png
reference/side.png  <-> candidate/side.png
reference/top.png   <-> candidate/top.png
```

不同文件名的图片（例如不同视角）**永远不会**互相比较。

> 核心只比较二维图片，不训练模型。`compare-models` 子命令可以额外把两个三维模型（本地 glb/obj/stl 文件，
> 或 Sketchfab 上可下载的模型）用完全相同的正交相机渲染成六视图（前后左右上下），再交给同一套流程打分；
> 渲染用纯 numpy 实现，不需要 Blender 或 OpenGL。见[三维模型对比](docs/model-comparison.md)。

## 功能一览

* **图片对图片打分**：SSIM / LPIPS / Silhouette IoU / Edge 四个指标加权成 0–100 分；自动平移对齐，位置偏差不扣分。
* **多物体三视图**：按 `<物体>_<视角>.png` 命名自动分组，每个物体单独出报告和分数。
* **三维模型对比**：`compare-models` 渲染六视图打分，另算面数（mesh_complexity）和骨骼动画（rig），支持自动朝向对齐和 Sketchfab 下载。
* **AI 复刻打分**：`reproduce` 调 Meshy / Tripo 图生或文生 3D，自动对齐后按校准过的形状分数打分。
* **Agent 测评**：`python -m src.agentbench` 配置文件驱动，支持 Blender MCP / 内置工具 / 外部 agent 命令行（Claude Code、Codex CLI）三种运行环境。
* **Docker**：benchmark 镜像 + 无头 Blender MCP 容器，compose 一键编排。

## 文档索引

| 文档 | 内容 |
| --- | --- |
| [docs/cli-usage.md](docs/cli-usage.md) | CLI 用法、常用选项、物体三视图用法、一次比较多个物体、内置测试用例、输入要求、测试 |
| [docs/model-comparison.md](docs/model-comparison.md) | 三维模型对比（渲染方式、面数、骨骼与动画、Sketchfab）、AI 复刻模型并打分 |
| [docs/scoring.md](docs/scoring.md) | 预处理流程、指标说明、分数计算、shape.yaml 形状校准、输出文件、配置文件 |
| [docs/agentbench.md](docs/agentbench.md) | Agent 测评：配置文件格式、三种运行环境、场景隔离与留痕、Codex CLI agent |
| [docs/docker.md](docs/docker.md) | Docker：benchmark 镜像、无头 Blender 容器、compose 编排、Codex 一体化运行 |

---

## 安装

环境要求：Windows 11 / Linux / macOS，Python 3.10+（开发使用 3.11），可选 NVIDIA GPU（CUDA）。

### 1. 创建虚拟环境

conda：

```powershell
conda create -n imgsim python=3.11 -y
conda activate imgsim
```

或 venv：

```powershell
py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
```

### 2. 安装 PyTorch

有 NVIDIA 显卡时先安装 CUDA 版本（以 CUDA 12.4 为例，其它版本见 <https://pytorch.org/get-started/locally/>）：

```powershell
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu124
```

没有显卡时直接安装 CPU 版本：

```powershell
pip install torch torchvision
```

### 3. 安装其余依赖

```powershell
pip install -r requirements.txt
```

### 4. 验证

```powershell
python -c "import torch; print('cuda available:', torch.cuda.is_available())"
```

程序会自动选择设备：CUDA 可用时使用 GPU，否则使用 CPU（无需修改配置）。

> 首次运行 LPIPS 时，`lpips` 包会自动下载 AlexNet 预训练权重（约 230 MB）到 `~/.cache/torch`。

---

## 快速开始

```powershell
# 1) 生成示例数据到 data/reference 和 data/candidate（可选，用于试运行）
#    默认生成 6 个不同物体 x 三视图 = 18 对图片，见 docs/cli-usage.md 的「内置测试用例」
python scripts/make_sample_data.py

# 2) 运行 benchmark
python -m src.cli compare --reference data/reference --candidate data/candidate --output outputs --config configs/default.yaml
```

终端输出示例：

```text
name                        SSIM   LPIPS     IoU    Edge    Pair
----------------------------------------------------------------
bottle_front.png           0.977   0.039   0.920    85.9   94.74
bottle_side.png            0.977   0.039   0.920    85.9   94.74
bottle_top.png             0.994   0.006   1.000   100.0   99.56
house_front.png            0.954   0.103   0.957    94.1   93.27
...
table_top.png              1.000   0.000   1.000   100.0  100.00
----------------------------------------------------------------
[bottle] (3 views)                                         96.34
[house] (3 views)                                          92.50
[lamp] (3 views)                                           72.21
[mug] (3 views)                                            96.16
[robot] (3 views)                                         100.00
[table] (3 views)                                          86.51
----------------------------------------------------------------
overall_score                                              90.62

Outputs written to: outputs\run_20260912_135214
```

把你自己的图片放进 `data/reference/` 和 `data/candidate/`（文件名一一对应）后再次运行即可。
物体三视图的用法、一次比较多个物体、内置测试用例的细节见 [docs/cli-usage.md](docs/cli-usage.md)。

---

## 重要说明与局限性

请在解读分数时务必注意：

* **SSIM 和 LPIPS 衡量的是二维图片相似度。** 它们比较的是像素与神经网络特征层面的相似程度，**不能直接证明三维模型的几何是正确的**。
* **比较的两张图片必须具有相同或非常接近的视角。** 相机角度、焦距、距离不同，即使模型完全一致，分数也会很低。本项目不会尝试对齐视角。
* **图片中物体的大小、背景和光照都会影响分数。** 位置偏差默认会被对齐步骤消除（只平移，不缩放、不旋转）；大小不同可以用 `foreground_bbox` 裁剪；背景颜色或亮度不同会降低 SSIM 与 LPIPS，视角不同造成的透视差异无法用二维对齐弥补。请尽量在相同的渲染/拍摄设置下生成图片。
* **综合分数（pair_score / overall_score）是本项目自己定义的分数，不是行业统一标准。** 它只是四个指标的加权平均，方便横向对比同一套设置下的不同 candidate。
* **权重（0.40 / 0.30 / 0.20 / 0.10）是初始设定，需要通过人工评价数据进一步校准。** 建议收集一批人工打分的图片对，再调整权重使综合分数与人工判断相关性最高。
* 不同视角（不同文件名）的图片不会互相比较；overall_score 只是各对分数的平均，并不代表任何跨视角的一致性。
* **面数只是精细度的粗略代理。** 同一个物体可以用很少的面建得很准，也可以用很多面建得很糙；`mesh_score` 只惩罚数量级上的差异，
  而且完全不看拓扑质量。参考模型本身面数偏离常规时（例如扫描件），可以调低 `mesh_complexity.weight`。
* **骨骼分只看结构，不看动作内容和变形质量。** 关节数量和位置、权重覆盖、动画覆盖和运动幅度都对得上就是满分，
  蒙皮权重画得糟、动作难看都测不出来；骨骼命名也没有参与比较。
* Silhouette IoU 依赖可靠的前景 mask（alpha 通道或纯色背景）。没有可靠 mask 时该指标为 `null`，而不是伪造一个数值。
* **三维模型对比仍然是二维图片相似度。** 六视图能反映外形轮廓和大体结构，但看不到内部结构；
  两个模型的朝向、单位必须先统一（见[三维模型对比](docs/model-comparison.md)），否则分数没有意义。渲染没有贴图和材质，只比较几何。

---

## 项目结构

```text
image_similarity_benchmark/
├── README.md                 本文档（简介、安装、快速开始）；详细文档在 docs/
├── docs/                     详细文档：cli-usage / model-comparison / scoring / agentbench / docker（见上方文档索引）
├── requirements.txt
├── pyproject.toml
├── configs/
│   ├── default.yaml          图片比较的默认配置（含注释）
│   └── shape.yaml            形状优先配置：compare-models / reproduce 的默认
├── benchmarks/example/       agent 测评的示例配置（mcp / builtin / command，含 command_codex.json）和打分用的参考模型 answers/
├── workspaces/example/       agent 的工作区：参考图片 refs/，运行结果 runs/（git 忽略）
├── docker/                   blender/：无头 Blender + BlenderMCP 镜像；benchmark/：Codex entrypoint（按环境变量生成 ~/.codex/config.toml）
├── data/                     reference/ 和 candidate/ 放两组图片
├── models/                   下载的三维模型缓存（git 忽略）；generated/ 放 AI 生成的模型
├── outputs/                  每次运行生成 run_时间/
├── scripts/
│   ├── make_sample_data.py   生成合成示例数据（默认为物体三视图）
│   ├── make_agent_example.py 生成 agent 测评的示例题目（马克杯参考模型 + 参考图片）
│   ├── summarize_runs.py     汇总 outputs/run_* 为 results.md / results.csv
│   └── calibrate.py          用 85 组样本对校准 shape.yaml 的 floors / gamma / 权重 / view_power
├── src/
│   ├── __init__.py
│   ├── cli.py                命令行入口（compare / compare-pair / compare-models / render-views / fetch-sketchfab / generate-model / reproduce）
│   ├── config.py             YAML 加载与严格校验
│   ├── preprocessing.py      读取、EXIF、alpha 合成、mask、裁剪、画布
│   ├── alignment.py          打分前的平移对齐（相位相关 / 质心）
│   ├── metrics.py            SSIM / LPIPS / Silhouette IoU / Edge / 权重合并
│   ├── benchmark.py          扫描、配对、运行、汇总
│   ├── reporting.py          metrics.json / metrics.csv / comparison / report.png
│   ├── synthetic.py          合成测试图片生成器（抽象形状 + 单物体三视图）
│   ├── objects.py            多物体测试用例：基本体拼装 + 正交三视图渲染
│   ├── render.py             三维网格加载、姿态归一化、numpy 正交光栅化六视图（含 iso 视角）
│   ├── orient.py             枚举 24 种朝向、按剪影 IoU 自动对齐 candidate
│   ├── generate.py           Meshy / Tripo 图生 3D、文生 3D 客户端（创建任务、轮询、下载）
│   ├── sketchfab.py          Sketchfab Data / Download API 客户端（下载 + 缓存）
│   └── agentbench/           配置文件驱动的 agent 测评：config / llm（OpenAI 兼容、Claude）/ tools（本项目工具、MCP）/ runner
└── tests/
    ├── conftest.py
    ├── test_preprocessing.py / test_metrics.py / test_benchmark.py   预处理、四项指标、配对汇总与输出
    ├── test_alignment.py     平移估计、对齐应用、阈值拒绝
    ├── test_objects.py       七个物体用例的逐指标预期与分组分数
    ├── test_render.py        光栅化、视图朝向、up 轴、CLI render-views / compare-models
    ├── test_orient.py        旋转后的模型能被自动对齐回来、iso 视角
    ├── test_generate.py      Meshy / Tripo 客户端（模拟 HTTP）、CLI generate-model / reproduce
    ├── test_agentbench.py    agent 测评：配置校验、两种 API 适配、builtin / stdio MCP / command 三种运行环境（脚本化模型）
    └── test_sketchfab.py     URL 解析、下载 / 缓存 / 错误处理（模拟 HTTP）
```

---

## 项目结构
