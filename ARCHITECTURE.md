# Medical Image Viewer — 项目架构文档

## 项目概述

本项目是一个基于浏览器的医学影像可视化平台，承担团队工作流中 **HTML 转换层** 的角色——将上游 skill 生成的可视化结果（CIVET 流水线输出、NIfTI 体数据等）转换为可在浏览器中交互查看的 HTML 页面。

**团队工作流**：skill 生成可视化 → **HTML 转换层（本项目）** → 显示在前端

## 技术栈

| 组件 | 技术 | 说明 |
|------|------|------|
| 3D 渲染引擎 | [NiiVue](https://github.com/niivue/niivue) v0.44.0 | WebGL2 神经影像可视化库，通过 CDN 加载 UMD 包 |
| 前端 | 纯 HTML + CSS + vanilla JS | 单文件，零构建步骤，零框架依赖 |
| 服务器 | Python 3 `http.server` | 静态文件服务，通过 `serve.sh` 启动 |
| 样式 | 内嵌 CSS，暗色主题 | GitHub Dark 风格配色（#0d1117 / #161b22 / #30363d） |

## 目录结构

```
/home/swangek/visualization/
├── index.html                                  # 主页面（HTML + CSS + JS 全部内嵌）
├── serve.sh                                    # 启动 HTTP 服务器（python3 -m http.server 8080）
├── ARCHITECTURE.md                             # 本文件
├── verify/                                     # CIVET QC 输出数据（被试 941S6471）
│   ├── volume_slices.png                       #   T1 MRI 切片 + 组织分类图
│   ├── surface_renders.png                     #   白质表面 6 角度渲染
│   ├── thickness_map.png                       #   皮层厚度图（左右半球）
│   ├── qc_stats.png                            #   QC 统计数据
│   ├── civet_summary_941S6471.png              #   综合总结图
│   ├── sub_941S6471_surface_qc.txt             #   表面 QC 数值
│   └── sub_941S6471_classify_qc.txt            #   组织分类 QC 数值
├── sub-611881_run-001_desc-preproc_T1w.nii.gz  # 测试用 NIfTI 体数据
└── verify.zip                                  # CIVET 数据原始压缩包
```

## 页面结构

页面通过 **Tab 切换** 分为两个视图：

### Tab 1: 3D Viewer (NiiVue)

交互式 3D 医学影像查看器，占满整个视口高度。

```
┌─────────────────────────────────────────────────────────┐
│  Header: "Medical Image Viewer"    [3D Viewer] [CIVET]  │ ← Tab 切换
├─────────────────────────────────────────────────────────┤
│  Toolbar:                                               │
│  [Open Local File] [Load Sample] | Server Path [Load]   │ ← 文件加载
│  View | Colormap | Opacity | Drag | Crosshair | Radio   │ ← 视图控制
│  [Screenshot] [Reset]                                   │ ← 工具按钮
├─────────────────────────────────────────────────────────┤
│                                                         │
│                   <canvas id="gl1">                     │ ← WebGL2 渲染区
│              NiiVue 在此 canvas 中渲染                    │
│              支持鼠标拖拽/旋转/缩放                        │
│                                                         │
├─────────────────────────────────────────────────────────┤
│  Status Bar: 体素坐标 + 强度值                            │ ← 实时更新
└─────────────────────────────────────────────────────────┘
```

**功能列表**：

| 功能 | 实现方式 | NiiVue API |
|------|----------|------------|
| 打开本地文件 | `<input type="file">` → `URL.createObjectURL()` → `nv.loadVolumes()` | `loadVolumes([{url, name}])` |
| 加载示例数据 | 从 CDN 加载 MNI152 T1 1mm 模板 | `loadVolumes([{url: 'https://niivue.github.io/...'}])` |
| 加载服务器文件 | 文本输入框，输入相对路径 | `loadVolumes([{url: relativePath}])` |
| 视图切换 | 下拉菜单：Multiplanar / Axial / Coronal / Sagittal / 3D Render | `setSliceType()` |
| Colormap | 下拉菜单，动态填充（常用在前，全部在后） | `setColormap(id, name)` |
| 不透明度 | 滑块 0–1 | `setOpacity(0, value)` |
| 拖拽模式 | 下拉菜单：None / Contrast / Measurement / Pan-Zoom / Slicer3D | `opts.dragMode` |
| 十字线 | 复选框 | `setCrosshairWidth()` |
| 放射学惯例 | 复选框（R-L 翻转） | `setRadiologicalConvention()` |
| 截图导出 | 按钮 → 保存 canvas 为 PNG | `saveScene('screenshot.png')` |
| 重置视图 | 按钮 → 恢复所有参数到默认值 | 组合调用 |
| 拖放文件 | NiiVue 内置 `dragAndDropEnabled` + 自定义视觉反馈 overlay | 内置 |
| 体素信息 | 底部状态栏，通过 `onLocationChange` 回调实时更新 | 回调 |

### Tab 2: CIVET QC Report

CIVET 脑影像流水线的 QC 结果画廊，用于质控审查。

**分区展示**（每个区域为一个 `.card` 卡片）：
1. **Volume Slices & Tissue Classification** — T1 MRI 三平面切片 + 组织分类着色图
2. **White Matter Surface** — 白质表面 6 角度渲染
3. **Cortical Thickness** — 皮层厚度图（色标 1.0–5.0 mm）
4. **QC Statistics** — 统计图 + 格式化数据卡片（带颜色编码进度条）
   - Tissue Classification: CSF 12.80%, GM 39.22%, WM 45.71%, SC 2.27%
   - Surface QC: White 14.18%, Gray 13.48%
5. **Full CIVET Summary** — 可展开/收起的综合总结图

**交互功能**：
- 点击图像 → Lightbox 全屏放大查看
- ESC 键或点击背景 → 关闭 Lightbox
- Summary 默认折叠，点击按钮展开

## NiiVue 集成细节

### 加载方式

通过 CDN 加载 UMD 包（~2.3 MB），无需 npm/node：

```html
<script src="https://unpkg.com/@niivue/niivue@0.44.0/dist/niivue.umd.js"></script>
```

UMD 包在全局暴露 `window.niivue` 对象，其中包含 `Niivue` 类。

### 初始化流程

```javascript
const nv = new Niivue({
  backColor: [0.09, 0.09, 0.14, 1],  // 暗色背景
  show3Dcrosshair: true,
  dragAndDropEnabled: true,
  onLocationChange: updateStatus       // 体素坐标回调
});
await nv.attachToCanvas(document.getElementById('gl1'));
nv.setSliceType(nv.sliceTypeMultiplanar);
```

### 文件加载机制

**本地文件**：浏览器 File API → `URL.createObjectURL()` 生成 blob URL → `nv.loadVolumes([{url, name}])`。文件不离开浏览器，不上传到服务器。

**服务器文件**：用户输入相对路径（相对于 `serve.sh` 启动的工作目录），NiiVue 通过 HTTP GET 请求获取文件。文件必须在 `/home/swangek/visualization/` 目录下才能被 Python http.server 提供服务。

**示例数据**：从 `https://niivue.github.io/niivue-demo-images/mni152.nii.gz` 加载 MNI152 标准脑模板。

### 支持的文件格式

NiiVue 支持的格式（均可通过 Open Local File 加载）：
- 体数据：`.nii`, `.nii.gz` (NIfTI), `.dcm` (DICOM), `.nrrd`, `.mgh`, `.mgz`, `.mif`
- 表面/Mesh：`.stl`, `.obj`, `.gii` (GIFTI), `.vtk`
- 纤维束：`.trk`, `.tck`

## 服务器

`serve.sh` 启动一个 Python 内置 HTTP 服务器：

```bash
#!/bin/bash
cd /home/swangek/visualization
python3 -m http.server 8080
```

- 访问地址：`http://localhost:8080`
- 仅提供 `/home/swangek/visualization/` 目录下的静态文件
- 无后端逻辑，无 API 端点
- 要加载服务器上其他位置的文件，需先将文件复制或软链接到此目录下

## CSS 设计

- **暗色主题**：医学影像软件标准配色
  - 背景：`#0d1117`
  - 卡片/工具栏：`#161b22`
  - 边框：`#30363d`
  - 文字：`#e6edf3`（主要），`#8b949e`（次要）
  - 强调色：`#1f6feb`（蓝色按钮/选中态）
- **Flexbox 布局**：NiiVue tab 使用 flex column，canvas 区域 `flex: 1` 填满剩余空间
- **响应式**：`@media (max-width: 700px)` 下工具栏和 QC 卡片自适应

## 已知限制

1. **Server Path 只支持相对路径**：输入的路径相对于 `http.server` 工作目录。不支持服务器上的绝对路径（如 `/home/swangek/data/brain.nii.gz`），需要先把文件复制或 symlink 到项目目录下。
2. **Open Local File 打开的是客户端文件管理器**：这是浏览器 `<input type="file">` 的固有行为，无法浏览服务器文件系统。
3. **依赖网络加载 NiiVue**：UMD 包从 unpkg.com CDN 加载，离线环境无法使用（除非将 JS 文件下载到本地）。
4. **CIVET QC 数据硬编码**：当前 CIVET tab 中的 QC 数值和文件路径直接写在 HTML 中，更换被试需要修改 HTML。

## 后续扩展方向

- 支持加载服务器任意路径文件（需升级为自定义 Python 服务器）
- 动态生成 CIVET QC 页面（Python 脚本读取 verify/ 目录，自动生成 HTML）
- 3D 表面可视化（NiiVue 支持加载 mesh 文件，可展示 CIVET 生成的脑表面）
- 多被试对比视图
