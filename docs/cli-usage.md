# CLI 用法

> 返回 [README](../README.md)。

## 比较两个文件夹

PowerShell 多行：

```powershell
python -m src.cli compare `
  --reference data/reference `
  --candidate data/candidate `
  --output outputs `
  --config configs/default.yaml
```

单行（PowerShell / cmd / bash 通用）：

```powershell
python -m src.cli compare --reference data/reference --candidate data/candidate --output outputs --config configs/default.yaml
```

## 比较单独一对图片

PowerShell 多行：

```powershell
python -m src.cli compare-pair `
  --reference data/reference/front.png `
  --candidate data/candidate/front.png `
  --output outputs
```

单行：

```powershell
python -m src.cli compare-pair --reference data/reference/front.png --candidate data/candidate/front.png --output outputs
```

## 常用选项

| 选项 | 说明 |
| --- | --- |
| `--config PATH` | YAML 配置文件。默认使用 `configs/default.yaml`（存在时），否则使用内置默认值 |
| `--output DIR` | 输出根目录，每次运行在其中创建 `run_时间/`。默认 `outputs/` |
| `--skip-unmatched` | 仅 `compare`：跳过没有配对的文件，而不是终止运行 |
| `--crop-mode {none,center_crop,foreground_bbox}` | 覆盖配置中的裁剪模式 |
| `--alignment {none,centroid,phase_correlation}` | 覆盖对齐方式（默认 `phase_correlation`，位置偏差不扣分） |
| `--canvas-size N` | 覆盖画布尺寸（默认 512） |
| `--device {auto,cuda,cpu}` | 覆盖 LPIPS 计算设备 |
| `--no-save` | 不写任何文件，仅在终端输出结果 |
| `--log-level LEVEL` | DEBUG / INFO / WARNING / ERROR |

退出码：`0` 成功；`1` 没有任何有效配对；`2` 配置错误；`3` 输入/配对错误。

---

## 物体三视图的用法

这是本项目的典型场景：reference 是原始物体的正交三视图（`front.png` / `side.png` / `top.png`），
candidate 是另一个版本（例如重建或重新建模后的物体）用**相同相机设置**渲染出的三视图。

```text
data/reference/front.png  <->  data/candidate/front.png   正视图只和正视图比
data/reference/side.png   <->  data/candidate/side.png    侧视图只和侧视图比
data/reference/top.png    <->  data/candidate/top.png     俯视图只和俯视图比
```

* 每个视角单独得到一个 `pair_score`，`overall_score` 是所有有效配对分数的平均值；不同视角之间**永远不会互相比较**。
* 视角数量不限：加上 `back.png`、`left.png`、`iso.png` 等同名文件即可自动配对。

## 一次比较多个物体

把多个物体放进同一对文件夹时，用 `<物体名>_<视角>.png` 命名：

```text
data/reference/mug_front.png   data/candidate/mug_front.png
data/reference/mug_side.png    data/candidate/mug_side.png
data/reference/mug_top.png     data/candidate/mug_top.png
data/reference/lamp_front.png  data/candidate/lamp_front.png
...
```

程序会按第一个 `_` 之前的前缀把配对分组，在 `metrics.json` 的 `group_scores`、`metrics.csv` 的 `__group__:<物体>` 行
以及终端表格里给出**每个物体的平均分**（该物体三个视角 `pair_score` 的平均）。分隔符可通过
`output.group_separator` 修改，设为空字符串则关闭分组；文件名里没有分隔符的配对不参与分组，只计入 `overall_score`。

## 内置测试用例

`python scripts/make_sample_data.py` 默认生成 6 个**互不相同**的物体，每个物体三视图，candidate 各带一种不同类型的偏差：

| 物体 | candidate 的偏差 | 预期表现 |
| --- | --- | --- |
| `robot` | 完全相同 | 三个视角都 ≈ 100（对照组） |
| `mug` | 少了把手 | front / top 的 IoU 与 Edge 下降；side 视角把手被杯身遮挡，几乎不变 |
| `table` | 桌面变厚、桌腿变短（比例变化） | front / side 明显下降；top 不变 |
| `bottle` | 瓶颈更细更高 | front / side 中等下降；top 只有瓶盖圆略有变化 |
| `house` | 屋顶换色 + 加了烟囱 | 三个视角 LPIPS / SSIM 都下降；轮廓只在 front / side 略降 |
| `lamp` | 同一物体，整体平移 (5 %, 3 %) | 默认对齐后 IoU 0.97、物体分 95.8，位置偏差不扣分；`--alignment none` 时降到 72，说明对齐的作用 |
| `mismatch` | reference 是椅子，candidate 是台灯（两个完全不同的物体） | front / side 的 IoU 只有 0.3 左右，Edge、LPIPS 都很差，是分数最低的一组（69）；但 top 视角两者都是居中的一团（椅面 vs 灯罩），IoU 仍有 0.75，说明单看俯视图分不清物体，多视角一起看才可靠 |

报告按物体组织：**每个物体一张 `report_<物体>.png`**，三行分别是 front / side / top 的 reference、candidate、差异图和指标，
标题是该物体的分数和各视角分数；`report.png` 是一页汇总表（物体 × 视角分数、物体分数、总分），不再重复堆放所有图片。
只有一个物体、文件名不带前缀（`front.png` / `side.png` / `top.png`）时，`report.png` 就是这个物体的三视图报告。

这组用例展示了每个指标分别对什么敏感，也说明了「同一视角、同一位置」这个前提有多重要。物体定义在
[src/objects.py](../src/objects.py)，用 box / cylinder / sphere / prism / cone 等基本体拼成并做正交投影，
可以照着添加自己的物体或偏差。其他两组示例：`--kind three-view`（单个长方体 + 圆柱）和 `--kind shapes`（抽象形状）。

生成三视图时的建议：

1. 两套图片使用**相同的相机类型（正交/透视）、相同的视角、相同的距离/缩放、相同的画幅**。
2. 尽量导出带 alpha 通道的 PNG（透明背景），这样 Silhouette IoU 可以直接用 alpha 得到可靠的轮廓；
   否则请用纯色背景，程序会用背景色阈值分割前景。
3. 物体在画面里的**位置**不一致没关系：默认的 `alignment: phase_correlation` 会先把 candidate 平移对齐再打分。
   如果**大小**也不一致（取景框远近不同），再加 `--crop-mode foreground_bbox`，按轮廓包围盒裁剪并居中；
   但注意 bbox 裁剪按轮廓外延对齐，candidate 少了或多了零件时会把整个物体带偏，只在轮廓范围可信时使用。
   如果位置本身就是你要评价的内容，用 `--alignment none`。
4. 光照、材质、颜色的差异会明显影响 SSIM 和 LPIPS；如果只关心几何，请适当提高 `silhouette` 和 `edge` 的权重。

---

## 输入要求

* 支持格式：PNG、JPG/JPEG（可在配置中扩展 `input.extensions`）。
* 支持模式：RGB、RGBA、灰度（L）、带透明度的调色板图（P）、16 位灰度。
* 配对规则：**文件名相同（不区分大小写）**。`Front.PNG` 与 `front.png` 视为一对。
* 任意数量的图片；文件名不限于 front / side / top。
* 某张图片没有对应图片时，程序打印清晰的列表并**默认终止**；设置 `input.skip_unmatched: true` 或传 `--skip-unmatched` 可跳过。
* 每张图片在读取时都会做完整性校验；损坏或无法解码的文件会被记录为该对的 `error`，该对不计入综合分数，其余配对正常处理。

---

## 测试

```powershell
python -m pytest tests -q
```

测试全部使用程序自动生成的合成图片（`src/synthetic.py`），无需手动准备文件。覆盖内容：

* 同一张图与自身比较：SSIM、LPIPS、Edge、IoU 均接近 100。
* 改变亮度、改变颜色、平移、改变形状后分数下降；形状改变时轮廓与边缘分数明显下降。
* RGB、RGBA、灰度、JPEG、16 位、带透明的调色板图。
* EXIF orientation、透明合成、三种裁剪模式、长宽比保持。
* 缺少配对时的明确错误信息与 `skip_unmatched`。
* 损坏 / 截断文件的错误处理。
* 没有 CUDA 时 LPIPS 自动使用 CPU（通过 monkeypatch 模拟）。
* 权重不合法（总和≠1、负数、缺项、多余项、非数字）时的配置错误。
* 指标不可用时权重的动态重新归一化。
* 完整运行的所有输出文件、JSON/CSV 内容、CLI 退出码。
