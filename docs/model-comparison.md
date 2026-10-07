# 三维模型对比与 AI 复刻打分

> 返回 [README](../README.md)。纯图片比较见 [CLI 用法](cli-usage.md)，shape.yaml 校准与分数解读见 [评分与配置](scoring.md)。

## 三维模型对比

`compare-models` 把「下载模型 → 渲染六视图 → 配对打分」串成一条命令：

```powershell
# 两个本地模型
python -m src.cli compare-models --reference models/a.glb --candidate models/b.glb

# 一个本地模型 vs 一个 Sketchfab 模型（需要 API token，见下文）
python -m src.cli compare-models --reference models/a.glb --candidate https://sketchfab.com/3d-models/coffee-mug-<uid>

# 只渲染六视图，不打分
python -m src.cli render-views --model models/a.glb --output renders/a            # 默认六视图
python -m src.cli render-views --model models/a.glb --output renders/a --views front,side,top

# 只下载 Sketchfab 模型（缓存到 models/<uid>.glb）
python -m src.cli fetch-sketchfab https://sketchfab.com/3d-models/coffee-mug-<uid>
```

输出目录名会带上比较对象，例如 `outputs/run_20260915_101010_victorian-chair_vs_tripo-text-v3.1/`
（Sketchfab 模型用其名称，AI 生成的模型用 `服务-方式-版本`，本地文件用文件名；`--label` 可自定义）。目录里会多出：

* `renders/reference/` 与 `renders/candidate/`：渲染出的 `front.png` / `back.png` / `side.png` / `left.png` / `top.png` / `bottom.png`（RGBA、透明背景）及 `views.json`（渲染参数与网格统计）；
* `models.json`：两个模型的来源（本地路径或 Sketchfab 元数据：名称、作者、许可证）。

其余文件（`metrics.json`、`report.png` 等）与 `compare` 完全相同，另外多出面数相关的三项（见下节）。

### 面数（mesh_complexity）

图片指标只看轮廓和明暗，200 个面的方块杯子和 20 万面的精细杯子只要外形一致分数就一样。所以 `compare-models` / `reproduce`
会额外比较两个网格的面数（trimesh 加载后的三角面数，多部件已合并；参考模型如果是四边面，同样按三角化后的数量算）：

```text
shape_score                                                92.86        # 纯图片分，和以前的 overall_score 含义相同
mesh_score               faces 2,304 vs 7,164 (x3.109)     84.08   weight 0.15
mesh_bonus               fewer faces: +0.0 % of 5 %
overall_score                                              90.64
```

面数越少越好（`configs/shape.yaml` 的 `mode: fewer_is_better`）：形状分已经说明像不像，同样像的模型里更省面的赢。

* 面数**多于**参考：`mesh_score`（0–100）由 `log2(候选面数 / 参考面数)` 决定，不到 2 倍得 100，之后线性下降，32 倍得 0；
  `overall = shape_score × (1 − weight × (1 − mesh_score / 100))`，最多扣 `weight`（默认 0.15，即 15%）。
* 面数**少于**参考：不扣分，反而有效率奖励 `bonus`（0–1，少到参考的四分之一时拉满，`bonus_log2: 2`），
  `overall` 再乘 `(1 + bonus_weight × bonus)`，最多加 `bonus_weight`（默认 0.05，即 5%），总分封顶 100。
  奖励也是乘法，所以形状很差的模型省面也救不回来（3 分变 3.15 分）。
* 例子：gpt-6 做的马克杯 2,298 面对参考 2,304 面，不加不减；文字版马克杯 7,164 面（3.1 倍），扣 2.2 分；
  一把 72 面的椅子对 96 面的参考，加 1%。
* `mode: symmetric` 是旧行为：面数太少（欠建模）和太多（AI 扫描式稠密网格）受同样的惩罚，没有奖励。
* 用乘法而不是加权平均，是为了不破坏已校准的 shape 分数尺度（相同 100、无关约 3）。
* `metrics.json` 多出 `shape_score` 和 `mesh`（两边的面数、顶点数、`face_ratio`、`mode`、`score`、`weight`、`bonus`、`bonus_weight`），
  `metrics.csv` 多出 `__shape__` 和 `__mesh__` 两行，`report.png` 标题多一行面数信息，`outputs/results.md` 多 `shape` / `faces` / `mesh` 三列。
* `--mesh-weight 0` 只报告面数不计分（老的 `overall_score` 行为）；也可以在 YAML 里改 `mesh_complexity.mode` / `weight` /
  `free_log2` / `zero_log2` / `bonus_weight` / `bonus_log2`。纯图片的 `compare` 命令不受影响。

### 骨骼与动画（rig）

人物、龙、机甲这类会动的参考模型通常带骨骼（glTF `skins`）、顶点权重和动画片段。渲染只看静止姿态，所以 `compare-models` /
`reproduce` 会直接解析两个 glb/gltf 的结构，在**参考模型有骨骼时**给候选模型打一个 `rig_score`（0–100）：

```text
rig_score                bone 53 skel 53 skin 100 anim 100 moti 83   77.99   weight 0.20
  reference              bones=58 clips=1 motion=0.067
  candidate              bones=11 clips=1 motion=0.024
```

| 分项 | 权重 | 含义 |
| --- | --- | --- |
| `bones` | 0.15 | 骨骼数量比（候选/参考）按 log2 打分：2 倍以内 100，16 倍归 0 |
| `skeleton` | 0.25 | 骨骼位置：两副骨架放进和渲染相同的坐标系（同样的 up/front/yaw、按包围盒归一化）后，关节点集的 Chamfer 距离；0 得 100，`skeleton_max_distance`（默认 0.25 个模型尺寸）归 0 |
| `skinning` | 0.15 | 候选模型蒙皮顶点里权重非零且归一化的比例 |
| `animation` | 0.25 | 候选模型动画覆盖的骨骼比例相对参考的比例（参考没有动画时此项和下一项不计） |
| `motion` | 0.20 | 用线性混合蒙皮把候选模型摆到最长片段的 8 个姿态，算平均顶点位移（除以模型尺寸），和参考的比值按 log2 打分；姿态爆炸或出现 NaN 时动画两项记 0 |

* 没有骨骼的候选模型 `rig_score` 为 0；参考模型本身没骨骼（杯子）时只报告候选的情况、不计分。
* 合成方式同面数：`overall = shape_score × (1 − weight × (1 − rig_score/100))`，`configs/shape.yaml` 默认 weight 0.20，最多扣 20%。
  `--rig-weight 0` 只报告不计分。
* `python -m src.cli rig-info --model x.glb` 单独打印一个模型的骨骼 / 蒙皮 / 动画信息（JSON）。
* `metrics.json` 的 `rig` 里有 `applicable`、`score`、各分项 `components`、`skeleton_chamfer` 和两边的完整信息；
  `metrics.csv` 多 `__rig__` 行；`results.md` 多 `rig` 列。
* 只支持 glTF / GLB（obj、stl 等没有骨骼信息）；不支持 sparse accessor 和 morph target（形态键动画不算动画）。
  动画只比"动了多少、动了多少骨头"，不比动作内容：参考是攻击动画、候选是走路，只要幅度和覆盖相近就得高分。

### 渲染方式

* 支持 trimesh 能读取的格式：glb / gltf / obj / stl / ply / off / 3mf / dae 等；**不支持 fbx**。
  场景中的多个部件会合并成一个网格（节点变换已应用）。
* 模型先按 `--up` / `--front` 旋转到标准姿态（+Y 向上、+Z 朝向正视图的观察者），
  再按包围盒居中并把**最大边长**缩放到 1。三个视图共用同一个比例，所以各视图的相对尺寸保持一致。
* 正交投影，无透视。视图遵循第三角投影法：`front` 从 +Z 看，`side` 从 +X 看（模型正面在图像左侧），
  `top` 从 +Y 看（模型正面在图像底部），`back` / `left` / `bottom` 是对面的三个。默认渲染全部六个；`--views front,side,top` 可退回三视图。
* 着色为平面 headlight：灰度 = 环境光 + 面法线与视线夹角，两个模型使用完全相同的光照。`--style silhouette` 输出纯黑剪影。
* 默认 2 倍超采样抗锯齿（`--supersample`），画布 512 px（`--size`），物体最大边占画布 85 %（`--fill`）。
* 渲染是纯 numpy 的 z-buffer 光栅化，8 万面的网格单个视图约 0.5 s；不需要显卡、OpenGL 或 Blender。

| 选项 | 默认 | 说明 |
| --- | --- | --- |
| `--views` | `all`（front, back, side, left, top, bottom） | 逗号分隔的视图名；`iso` 需显式指定 |
| `--up` | `+y` | 模型的向上轴。glTF 规范是 +Y；Blender / 很多 STL 是 +Z |
| `--front` | 随 `--up` | 模型正面朝向的轴（+Y 向上时默认 +Z，+Z 向上时默认 -Y） |
| `--size` | 512 | 渲染分辨率 |
| `--fill` | 0.85 | 最大边占画布的比例 |
| `--style` | shaded | `shaded` 或 `silhouette` |

**朝向是最容易出错的地方**：两个模型如果「正面」定义不一致（一个 +Z 朝前、一个 -Y 朝前），即使模型一样分数也会很低。
三种处理方式：

* `--auto-orient`：先枚举 candidate 的全部 24 种轴对齐朝向，渲染低分辨率剪影，选与 reference 各视图 IoU 平均值最高的那一种；
  再绕选出的向上轴每 10° 扫一圈、在最佳角度附近按 2° 细化（AI 生成的模型通常向上轴是对的，但朝向跟着输入图片的拍摄角度走）。
  选中的 `up` / `front` / `yaw` 和前几名的 IoU 写在 `models.json` 的 `candidate.auto_orient` 里。不处理绕其他轴的倾斜和镜像。
  比较剪影时每个视图各自缩放到铺满画布（和 `shape.yaml` 打分时按轮廓裁剪一致），否则搜索会"用旋转换尺寸"：
  模型按最长边归一化，候选的把手长一点整个杯子就显得小一圈，把把手转斜能缩小包围盒、把杯身放大回来——
  实测一个马克杯复刻因此被转了 26°，得 80.3 分，修正后选 0°、84.1 分。剪影不需要深度和着色，
  小三角形走向量化光栅、大三角形用 OpenCV 填充，超过 6 万面的网格先按体素网格合并顶点再搜索（只用于选角度），
  AI 生成的百万面模型对齐从约 2 分钟降到 20–30 秒。
  剪影搜索只负责提名：它选了非 0 的 yaw 时，会把 0° 的轴对齐朝向也完整打一遍分，取综合分高的那个
  （`models.json` 的 `auto_orient.scored` 记录两者的分数）。光看剪影分不清"把手粗了一点、没转"和"把手对、转了 20°"，
  但综合分（边缘、最弱视图）分得清：实测一个文生马克杯剪影搜索选 20° 得 82.8 分，按综合分改选 0° 得 90.6 分。
  代价是多一次打分（约 35 秒），只在选到非 0 角度时发生。
  实测：把一把椅子绕 X、Z 各转 90° 后直接比较只有 63.8 分，加 `--auto-orient` 后恢复到 100 分；
  Tripo v3.1 按 45° 视角图生成的椅子，只做 90° 对齐是 70.2 分，加上任意角度搜索（找到 -42°）后 91.3 分。
* `--candidate-up` / `--candidate-front` / `--candidate-yaw`：手动为 candidate 指定与 reference 不同的轴和绕向上轴的角度。
* 先用 `render-views` 分别看一眼各视图，再决定参数。

### 从 Sketchfab 读取模型

1. 登录 Sketchfab，在 **Settings → Password & API** 复制 **API token**。
2. 设置环境变量（或每次传 `--token`）：

   ```powershell
   $env:SKETCHFAB_API_TOKEN = "xxxxxxxx"        # PowerShell
   export SKETCHFAB_API_TOKEN=xxxxxxxx           # bash / zsh
   ```

3. 用模型页面的 URL、`sketchfab:<uid>` 或 32 位 uid 作为 `--reference` / `--candidate` / `--model` 的值。
   `skfb.ly` 短链接不支持，请用完整 URL。

说明与限制：

* 只有作者开启了 **Download** 的模型（通常是 CC 许可）才能通过 API 下载；未开启的模型会报错并给出原因。
  下载的模型会把名称、作者、许可证写进 `models/<uid>.json`，使用时请遵守相应许可证。
* 下载 API 返回 glb（优先）或 gltf 压缩包；压缩包会自动解压并定位到 `scene.gltf`。
* 模型缓存在 `--models-dir`（默认 `models/`），重复使用不再联网；`fetch-sketchfab --force` 可强制重新下载。
* 认证使用 API token（`Authorization: Token ...`）；也可通过 `SKETCHFAB_ACCESS_TOKEN` 传 OAuth access token。
  这部分由于需要真实账号，只在单元测试里用模拟的 HTTP 服务验证过。
* macOS 自带的 python.org 安装版可能缺少根证书，出现 `CERTIFICATE_VERIFY_FAILED` 时运行
  `/Applications/Python 3.x/Install Certificates.command`，或 `export SSL_CERT_FILE=$(python3 -m certifi)`。

---

## AI 复刻模型并打分

`reproduce` 命令完成整条链路：取一个参考模型（本地文件或 Sketchfab）→ 渲染一张图交给 AI 图生 3D 服务（或改用文字提示词）
→ 下载 AI 生成的模型 → 自动对齐朝向 → 六视图打分。

```powershell
# 用参考模型的 3/4 视角渲染图做图生 3D（Meshy）
$env:MESHY_API_KEY = "..."
python -m src.cli reproduce --reference https://sketchfab.com/3d-models/victorian-chair-6479a1900b614b59b26784c3a7922eb3

# 改用文字提示词（文生 3D）
python -m src.cli reproduce --reference models/chair.glb --prompt "a victorian wooden dining chair with carved back"

# 用 Tripo
python -m src.cli reproduce --reference models/chair.glb --provider tripo --api-key ...

# 已经用别的工具（网页版 Meshy / Tripo / Hunyuan3D / TRELLIS ...）生成好了模型：跳过生成，只做对齐 + 打分
python -m src.cli reproduce --reference models/chair.glb --candidate downloads/ai_chair.glb

# 只调用生成，不打分
python -m src.cli generate-model --provider meshy --image renders/chair/iso.png
python -m src.cli generate-model --provider tripo --prompt "a coffee mug"
```

输出目录 `outputs/run_*/` 除了常规文件还有：

* `generation/hero_iso.png`：发给 AI 的那张图（默认 `iso` 三/四视角、1024 px、白底；`--hero-view` / `--hero-size` 可改）；
* `models.json` 里的 `generation`（服务、任务 id、耗时、生成模型路径）和 `candidate.auto_orient`（自动选出的朝向）。

生成的模型保存在 `models/generated/<provider>_<task_id>.glb`，旁边的同名 json 记录任务信息。

### 支持的服务

| `--provider` | 环境变量 | 图生 3D | 文生 3D | 接口 |
| --- | --- | --- | --- | --- |
| `meshy`（默认） | `MESHY_API_KEY` | `POST /openapi/v1/image-to-3d`（图片以 base64 data URI 发送） | `POST /openapi/v2/text-to-3d`（`preview` 阶段） | 轮询到 `SUCCEEDED` 后下载 `model_urls.glb` |
| `tripo` | `TRIPO_API_KEY` | `POST /v2/openapi/upload` + `POST /task`（`image_to_model`） | `POST /task`（`text_to_model`） | 轮询到 `success` 后下载 `output.pbr_model` |

两者都是付费 / 按额度计费的服务，只有显式执行 `generate-model` 或 `reproduce` 时才会调用。默认不生成贴图（`--texture` 开启），
因为打分只看几何。`--model-version` 选服务的模型版本，`--param key=value` 透传任意任务参数（可重复），
`--poll-interval`（默认 10 s）和 `--timeout`（默认 30 min）控制等待。

Tripo 的实测计费（`models.json` 的 `generation.meta.consumed_credit` 会记录每次实际扣除的点数，日志也会打印剩余额度）：

| 方式 | 点数 |
| --- | --- |
| 图生 3D，`--model-version v3.1-20260211`，不带贴图（推荐） | 20 |
| 图生 3D，v2.5（不指定版本时的默认）或 v1.4，即使关闭贴图 | 30 |
| 文生 3D，不带贴图（官方价目表） | 10 |

注意：Tripo v3.x 会保留输入图片的视角，用 3/4 视角图生成的模型会整体旋转约 45°；`reproduce` 默认开启的自动对齐会把它转回来。

这两个客户端按官方文档 / 官方 SDK 的接口实现，并用模拟的 HTTP 服务做了单元测试；没有用真实账号跑过，
第一次使用时如果接口有变动请把报错贴出来。

> 复刻出来像不像、能打多少分，取决于 `configs/shape.yaml` 的形状校准——见 [评分与配置](scoring.md) 的
> 「只看形状：`configs/shape.yaml`」和「怎么解读分数」。
