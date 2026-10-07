# 评分与配置

> 返回 [README](../README.md)。指标打出来的模型从哪来见 [三维模型对比与 AI 复刻打分](model-comparison.md)。

## 预处理流程

reference 与 candidate 使用**完全相同**的规则：

1. 修正 EXIF orientation。
2. 分离 alpha 通道，颜色统一转换为 RGB。
3. 生成前景 mask（见 `mask_mode`）。
4. 透明区域合成到纯白背景（`background_color` 可改）。
5. 裁剪（`crop_mode`）：
   * `none`：不裁剪；
   * `center_crop`：中心正方形裁剪；
   * `foreground_bbox`：按前景 mask 的包围盒裁剪，四周保留 `foreground_padding` 比例的 padding，并把物体居中。没有可靠 mask 时回退为不裁剪并给出警告。
6. **保持长宽比**缩放到 `canvas_size × canvas_size`（默认 512）的画布中并居中，空白处用背景色填充；**绝不拉伸**。
7. **对齐**（`alignment`，默认 `phase_correlation`）：把 candidate 平移到和 reference 重叠最好的位置，只平移、不缩放、不旋转，
   这样物体在画面里的位置差异不影响分数。估计出的偏移量写进 `metrics.json` 的 `alignment` 字段。
8. 预处理结果（对齐后的 candidate）保存到 `outputs/run_*/preprocessed/`，方便人工检查（包含 `*_mask.png`）。

对齐方式（`alignment`）：

| 值 | 行为 |
| --- | --- |
| `phase_correlation`（默认） | OpenCV 相位相关，按**内容**对齐：candidate 少个零件或多个零件时，主体依然对得准 |
| `centroid` | 对齐前景质心；简单，但局部形状变化会把质心拉偏 |
| `none` | 不对齐，位置偏差会被当成误差扣分 |

对齐用的前景信号：两张图都有可靠 mask 时用 mask，否则用「与背景色的距离」。两种情况下估计的偏移会被拒绝、图片保持不动：偏移超过 `alignment_max_shift`（默认画布的 50 %），或者移动后前景重叠反而变小（两个不相干的物体常常如此）。拒绝的偏移仍会记录在 `alignment` 字段里（`applied: false`）。
对齐只解决二维平移；相机角度不同造成的透视差异，二维对齐无法弥补。

前景 mask 来源（`mask_mode`）：

| 值 | 行为 |
| --- | --- |
| `alpha` | 只用 alpha 通道；没有 alpha 就没有 mask |
| `auto`（默认） | 有 alpha 用 alpha；否则用背景色阈值分割 |
| `background` | 总是用背景色阈值分割 |

阈值分割得到的 mask 只有在前景比例处于 `[mask_min_foreground_fraction, mask_max_foreground_fraction]` 之间时才视为可靠；例如一张没有纯色背景的照片会被判为**不可靠**，此时 Silhouette 指标标记为不可用，而不是给出虚假的分数。

---

## 指标说明

所有指标都在预处理后的 512×512 RGB 图上计算。

### 1. SSIM（`scikit-image`）

* `data_range=255`，`channel_axis=-1`（RGB 三通道平均），默认高斯窗（σ = 1.5）。
* 保存原始 `ssim`（理论范围 [-1, 1]）。
* `ssim_score = 100 × clip(ssim, 0, 1)`。

### 2. LPIPS（`lpips` 包）

* 默认 AlexNet backbone（可选 `vgg` / `squeeze`）。
* CUDA 可用时自动用 GPU，否则用 CPU。
* 图片转换为 `(1, 3, H, W)` float tensor 并归一化到 `[-1, 1]`。
* 保存原始 `lpips_distance`（越低越相似）。
* `lpips_score = 100 × exp(-lpips_distance)`（**不是** `1 - LPIPS`）。

### 3. Silhouette IoU

* 两张图都有可靠前景 mask 时：`silhouette_score = 100 × (交集 / 并集)`。
* 任一张没有可靠 mask，或两张 mask 都为空：`silhouette_iou` 与 `silhouette_score` 为 `null`，综合分数只用其余指标并重新归一化权重。

### 4. Edge similarity（OpenCV Canny + Chamfer 距离）

* 高斯模糊后用 Canny 提取边缘。
* 对两张边缘图分别做 distance transform，计算**对称截断 Chamfer 距离**：
  reference 每个边缘像素到 candidate 最近边缘的距离，反之亦然；距离在 `max_distance`（默认 20 px，按画布尺寸等比缩放）处截断并归一化到 [0, 1]。
* `edge_score = 100 × (1 − 0.5 × (mean_ref→cand + mean_cand→ref))`。
* 因此 1–2 像素的位置误差只会轻微扣分，而不是像直接求交集那样几乎全部失配。
* 两张图都几乎没有边缘时标记为 `null`；只有一张有边缘时为 0。

---

## 分数计算

默认权重（`configs/default.yaml`）：

```yaml
weights:
  lpips: 0.40
  ssim: 0.30
  silhouette: 0.20
  edge: 0.10
```

```text
pair_score = 0.40 × LPIPS_score + 0.30 × SSIM_score + 0.20 × Silhouette_score + 0.10 × Edge_score
```

某项指标不可用时，按剩余可用指标的权重重新归一化。例如 silhouette 不可用：

```text
available_weight = 0.40 + 0.30 + 0.10 = 0.80
pair_score = (0.40 × LPIPS_score + 0.30 × SSIM_score + 0.10 × Edge_score) / 0.80
```

实际使用的权重写在每一对的 `effective_weights` 里，不可用的指标列在 `unavailable_metrics`。

```text
overall_score = 所有有效 pair_score 的算术平均值
```

权重必须全部 ≥ 0、包含全部四个指标且总和为 1（容差 1e-6），否则程序报配置错误并退出。

所有分数为 0–100；终端和报告图片显示两位小数，`metrics.json` / `metrics.csv` 保留未四舍五入的原始浮点数。

---

## 只看形状：`configs/shape.yaml`（`compare-models` / `reproduce` 的默认配置）

`configs/default.yaml` 下 SSIM 和 LPIPS 对整张图计算，而画面大部分是共同的白色背景，所以毫不相关的两个物体也有 60 分左右，
AI 复刻和「换了个物体」之间拉不开。`configs/shape.yaml` 做两件事：每个视图各自按前景包围盒裁剪并铺满画布
（画面里物体的大小、各视图之间的比例不再计分，只剩每个视图的形状），把权重压到轮廓和边缘上，并用 `score_floors` 扣掉不相关物体也能拿到的底分（见下）。
`compare-models` 和 `reproduce` 不传 `--config` 时就用它；图片命令 `compare` / `compare-pair` 仍用 `default.yaml`。

```powershell
python -m src.cli compare-models --reference a.glb --candidate b.glb --auto-orient            # 默认已是 shape.yaml
python -m src.cli compare-models --reference a.glb --candidate b.glb --config configs/default.yaml
```

**为什么要有 `score_floors`。** 即使只看形状，两个毫不相关的物体（椅子 vs 龙）原先也有 40 多分，因为每个指标都有一个「白送」的底分：

| 指标 | 不相关物体也能拿到 | 原因 |
| --- | --- | --- |
| SSIM | 0.80–0.87 | 白背景 + 同样的灰色着色；椅子 vs 龙 0.86，椅子 vs 自己的 AI 复刻 0.85，没有区分度，所以权重设为 0 |
| LPIPS | 距离 0.30–0.55（= 58–74 分） | `100·exp(-d)` 的映射很宽松 |
| 轮廓 IoU | 0.15–0.45 | 两个都居中、都铺满画布的图形必然重叠 |
| Edge | 8–35 分 | 轮廓线总有一部分离得不远 |

`score_floors` 把每个指标的底分减掉再拉伸回 0–100，`score_gamma` 把中段抬高一些，`view_power` 决定六个视图怎么合成一个分：

```text
x        = clip((原始分 − floor) / (100 − floor), 0, 1)
校准分   = 100 × x ^ score_gamma                      # 每个指标
视图分   = 加权平均(校准分)
综合分   = ( mean(视图分 ^ view_power) ) ^ (1 / view_power)   # 幂平均
```

* 低于 floor 记 0，100 仍是 100（同一个模型仍然满分）。
* `score_gamma < 1` 时曲线上凸，「认得出是同一个东西、但比例姿态有出入」的复刻不会被线性刻度压得太低。
* `view_power < 1` 的幂平均偏向**最差的那个视图**：真正的复刻每个视图都对得上，而不相关的物体经常只在某一个视图上碰巧像
  （椅子和茶壶从正上方看都是一个圆饼，IoU 0.8）。普通平均下这一对有 24–29 分，幂平均后是 0.2 分。
* `metrics.json` 同时保留原始分（`*_score`）和校准后的分（`calibrated_scores`），report.png 里多一行 `after floors`。
  `configs/default.yaml` 三个参数都是中性值（无 floors、gamma 1、power 1），行为不变。

### 参数是怎么定的：`scripts/calibrate.py`

```powershell
python scripts/calibrate.py measure --workers 5    # 测 85 组样本对的原始指标，缓存到 outputs/calibration/raw.json（约 30 分钟）
python scripts/calibrate.py fit                    # 网格搜索 floors / gamma / 权重 / view_power，打印各类样本的分数分布
```

样本：Sketchfab 上 11 个类别的 27 个单体模型（椅子、角色、龙、杯子、剑、汽车、吉他、桌子、茶壶、运动鞋、战斗机），组成 85 对，不花任何生成积分：

| 类别 | 对数 | 说明 | shape.yaml 下的分数（最小 / 中位 / 最大） |
| --- | --- | --- | --- |
| identical | 4 | 模型和自己比 | 100 / 100 / 100 |
| mild | 9 | 轻微变形的副本（各轴缩放 ±4 %） | 87.9 / 93.2 / 96.2 |
| medium | 9 | 中等变形（缩放 ±12 %、弯曲、扭转 8°） | 68.3 / 76.4 / 84.6 |
| strong | 9 | 强变形（缩放 ±25 %、明显弯曲、扭转 25°） | 35.1 / 49.1 / 67.5 |
| ai_image | 2 | Tripo v3.1 图生复刻（椅子、Viking） | 86.6 / 87.5 / 88.4 |
| ai_text | 3 | Tripo v3.1 文生复刻（椅子、Viking、龙） | 29.9 / 52.3 / 54.1 |
| same | 19 | 同类别的另一个模型 | 1.1 / 45.5 / 79.4 |
| unrelated | 30 | 不同类别 | 0.1 / 3.9 / 49.1（90 % 的样本低于 36） |

选定的参数：floors silhouette 45 / edge 30 / lpips 70，`score_gamma` 0.4，`view_power` 0.25，权重 silhouette 0.45 / edge 0.25 / lpips 0.30 / ssim 0。

大致读法：85 以上是高质量复刻，50 左右是认得出的粗略复刻，10 以下是不同物体。需要知道的几点：

* 「同类别的另一个模型」分布很宽（0–79）：两把电吉他、两辆轿车本来就很像，能到 70 多分；两张造型不同的桌子只有十几分。
  文生复刻（约 52）落在这个区间里，说明它还原的是类别和大致造型，而不是这个具体模型。
* 不相关物体里仍有少数高分：剑 vs 电吉他 40 多分，因为两者在三个视图里都是一根细长条，从轮廓上确实像。
  自动对齐会给每一对都找"最像"的摆法，所以不相关物体的高分尾巴（8/30 高于 20）也是对齐之后的真实相似度；
  上表是改进自动对齐（见[渲染方式](model-comparison.md)）之后重测的，旧版对齐常把不相关物体摆歪，那时只有 4/30 高于 20。
* 参数是对这 85 对拟合的，真实 AI 复刻只有 5 个；换一批很不一样的物体（比如全是细长件）时建议重跑 `calibrate.py`。
* 模型本身的尺寸在所有配置下都不影响分数（渲染前统一归一化）。

## 汇总所有运行：`scripts/summarize_runs.py`

```powershell
python scripts/summarize_runs.py                 # 扫描 outputs/run_*，写出 outputs/results.md 和 results.csv
python scripts/summarize_runs.py --sort score
```

每行一次运行：比较的两个模型、生成方式（服务 / 图生或文生 / 版本 / 消耗点数）、配置、自动对齐结果、六个视图的分数和综合分。

## 怎么解读分数

* AI 生成的模型通常比例、细节和原模型都有差异；同一参考模型下不同服务、不同版本、不同提示词之间的**相对**分数更有意义。
  实测同一把维多利亚椅（Sketchfab `6479a190…`）：Tripo v2.5 图生 3D 91.8 分、v3.1 不带贴图 91.3 分、v1.4 87.9 分。
* 自动对齐解决轴对齐和绕向上轴的任意旋转。如果生成的模型绕其他轴倾斜，或左右镜像了，分数会偏低，需要自己在建模软件里转正后用 `--candidate` 传入。
* 六个正交视图看不到内部结构和被遮挡的凹陷，贴图和颜色也不参与打分。

---

## 输出文件

每次运行创建独立目录：

```text
outputs/run_YYYYMMDD_HHMMSS/
├── preprocessed/
│   ├── reference/      预处理后的 reference 图片（+ *_mask.png）
│   └── candidate/      预处理后的 candidate 图片（+ *_mask.png）
├── comparisons/        每对图片一张：reference | candidate | 差异图 | 指标
├── metrics.json        全部原始数值 + 分组分数 + 配置
├── metrics.csv         每行一对图片，然后是 __group__:<物体> 行，最后一行 __overall__
├── report_<物体>.png   每个物体一张：各视图逐行对比（多物体命名时）
└── report.png          多物体：一页汇总表；单物体：该物体的逐视图报告
                        （一张报告的行数超过 report_pairs_per_page 时才会分页为 *_page02.png）
```

`metrics.json` 结构：

```json
{
  "pairs": {
    "front.png": {
      "reference_path": "data/reference/front.png",
      "candidate_path": "data/candidate/front.png",
      "ssim": 0.91,
      "ssim_score": 91.0,
      "lpips_distance": 0.13,
      "lpips_score": 87.81,
      "silhouette_iou": 0.88,
      "silhouette_score": 88.0,
      "edge_score": 84.2,
      "edge_chamfer_ref_to_cand": 0.11,
      "edge_chamfer_cand_to_ref": 0.21,
      "pair_score": 88.17,
      "effective_weights": {"lpips": 0.4, "ssim": 0.3, "silhouette": 0.2, "edge": 0.1},
      "unavailable_metrics": [],
      "mask_source_reference": "alpha",
      "mask_source_candidate": "alpha",
      "error": null,
      "preprocessed_reference": "preprocessed/reference/front.png",
      "preprocessed_candidate": "preprocessed/candidate/front.png",
      "comparison_image": "comparisons/front.png"
    }
  },
  "overall_score": 88.17,
  "shape_score": null,        // compare-models / reproduce：图片分；mesh 为两边面数、face_ratio、score、weight
  "mesh": null,               // 纯图片的 compare 运行里两项都是 null
  "group_scores": { "mug": {"score": 96.16, "num_pairs": 3, "pairs": ["mug_front.png", "mug_side.png", "mug_top.png"]} },
  "num_pairs": 1,
  "num_valid_pairs": 1,
  "skipped_unmatched": {"reference_without_candidate": [], "candidate_without_reference": []},
  "run_dir": "outputs/run_20260912_132708",
  "configuration": { "...": "完整配置" }
}
```

`report.png` 每一行展示：reference、candidate、差异图（每像素绝对差的均值，magma 色图）、文件名、SSIM、LPIPS distance、LPIPS score、Silhouette IoU、Edge score、Pair score；标题展示 Overall score。

---

## 配置文件

完整默认配置见 [configs/default.yaml](../configs/default.yaml)，每个键都有注释。常用项：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `input.skip_unmatched` | `false` | 缺少配对时是否跳过（否则终止） |
| `preprocessing.canvas_size` | `512` | 画布尺寸 |
| `preprocessing.background_color` | `[255,255,255]` | 透明合成与填充颜色 |
| `preprocessing.crop_mode` | `none` | `none` / `center_crop` / `foreground_bbox` |
| `preprocessing.foreground_padding` | `0.10` | `foreground_bbox` 四周 padding 比例 |
| `preprocessing.mask_mode` | `auto` | 前景 mask 来源 |
| `preprocessing.alignment` | `phase_correlation` | 打分前把 candidate 平移对齐到 reference；`none` 关闭 |
| `preprocessing.alignment_max_shift` | `0.5` | 估计偏移超过画布这个比例时视为不可靠，不对齐 |
| `metrics.lpips.net` | `alex` | LPIPS backbone |
| `metrics.lpips.device` | `auto` | `auto` / `cuda` / `cpu` |
| `metrics.edge.max_distance` | `20.0` | Chamfer 截断距离（像素，按 512 画布缩放） |
| `weights.*` | 0.4/0.3/0.2/0.1 | 指标权重，总和必须为 1 |
| `mesh_complexity.weight` | 0（shape.yaml 0.15） | 面数多于参考时最多扣掉 shape 分数的比例；`free_log2` / `zero_log2` 定义免罚区间和归零点；`mode: fewer_is_better`（shape.yaml）下面数少于参考有最多 `bonus_weight`（0.05）的奖励（见[面数](model-comparison.md)） |
| `rig.weight` | 0（shape.yaml 0.20） | 参考模型有骨骼时，骨骼 / 动画差异最多扣掉的比例；其余键见 [configs/shape.yaml](../configs/shape.yaml) 注释（见[骨骼与动画](model-comparison.md)） |
| `output.report_pairs_per_page` | `6` | 报告每页配对数 |
| `output.group_separator` | `"_"` | 按文件名前缀分组（多物体），每个物体一张报告；空字符串关闭 |

复制 `configs/default.yaml` 改成自己的文件后用 `--config` 传入。未知键会直接报错，避免拼写错误被静默忽略。
