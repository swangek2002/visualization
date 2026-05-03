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

### 静态文件服务

`serve.sh` 启动一个 Python 内置 HTTP 服务器：

```bash
#!/bin/bash
cd /home/swangek/visualization
python3 -m http.server 8080
```

- 访问地址：`http://localhost:8080`
- 仅提供 `/home/swangek/visualization/` 目录下的静态文件
- 要加载服务器上其他位置的文件，需先将文件复制或软链接到此目录下

### VNC 代理（3D Slicer）

通过 SSH 隧道 + websockify + noVNC 将 Longleaf 上的 3D Slicer VNC 会话嵌入到浏览器中。用户可以在同一网页内直接操作运行在远程 HPC 集群上的 3D Slicer。

**架构**：
```
[浏览器 iframe]                     [frontier 服务器]                          [Longleaf HPC]
noVNC JS 客户端  ←WebSocket:6080→  websockify 代理  ←SSH隧道:5901→  TurboVNC :1 + 3D Slicer
                                                                     (计算节点, 如 c0407)
```

**数据流详解**：
1. 浏览器中的 noVNC（JavaScript VNC 客户端）通过 WebSocket 连接 frontier:6080
2. websockify 将 WebSocket 协议转换为原生 VNC（RFB）协议，转发到 localhost:5901
3. SSH 隧道将 localhost:5901 转发到 Longleaf 计算节点的 VNC 端口 5901
4. TurboVNC 服务器接收连接，将 3D Slicer 的图形界面编码为像素流返回

**组件**：

| 组件 | 版本 | 位置 | 说明 |
|------|------|------|------|
| TurboVNC | 3.1.90 | `/opt/TurboVNC/bin/` (Longleaf 计算节点) | 高性能 VNC 服务器，仅在计算节点上可用（登录节点无） |
| websockify | 0.13.0 | conda env `survivehr` (frontier) | WebSocket ↔ TCP 协议桥接代理 |
| noVNC | latest | `novnc/` (git clone) | 纯 JavaScript VNC 客户端，在浏览器中渲染 VNC 像素流 |
| maximize_slicer.py | — | `~/.vnc/` (Longleaf NFS) | Python 脚本，使用 X11 ctypes 调用自动将 Slicer 窗口最大化 |
| slicer_xstartup.sh | — | `~/.vnc/` (Longleaf NFS) | VNC 启动脚本，仅启动 Slicer（无桌面环境） |
| start_vnc_proxy.sh | — | 项目根目录 (frontier) | 一键部署脚本 + 启动 VNC + SSH 隧道 + websockify |
| stop_vnc_proxy.sh | — | 项目根目录 (frontier) | 停止代理，清理端口 |

**Slicer 全屏模式实现**：

默认情况下 TurboVNC 启动 GNOME 桌面环境（Red Hat），Slicer 只是其中一个窗口。为了让 Slicer 占满整个 VNC 画面：

1. **自定义 xstartup**（`~/.vnc/slicer_xstartup.sh`）：跳过桌面环境，直接启动 Slicer 作为唯一应用
2. **自动最大化**（`~/.vnc/maximize_slicer.py`）：后台运行的 Python 脚本，轮询等待 Slicer 窗口出现后，通过 X11 `XMoveResizeWindow` 将其调整为 VNC 分辨率（1920×1080）

```python
# maximize_slicer.py 核心逻辑
x11 = ctypes.cdll.LoadLibrary("libX11.so.6")
# 等待 Slicer 窗口出现（通过 xwininfo 检测）
# 调用 XMoveResizeWindow(display, window_id, 0, 0, 1920, 1080) 全屏
```

TurboVNC 使用 `-xstartup` 参数指定启动脚本（不修改用户默认 VNC 配置）：
```bash
vncserver :1 -geometry 1920x1080 -depth 24 -xstartup ~/.vnc/slicer_xstartup.sh
```

**网页端集成**：

3D Slicer Tab 使用 `<iframe>` 嵌入 noVNC 客户端页面 `novnc/vnc_lite.html`：

```html
<iframe id="vncFrame" src="novnc/vnc_lite.html?host=...&port=6080
    &autoconnect=true&resize=scale&password=...">
</iframe>
```

- `resize=scale`：noVNC 自动将 VNC 画面缩放到 iframe 大小
- `autoconnect=true`：加载后自动连接 VNC
- `password`：VNC 密码通过 URL 参数传递（默认 `123456`）

CSS 确保 iframe 填满容器：
```css
#vncFrame { position: absolute; inset: 0; width: 100%; height: 100%; }
.vnc-container { flex: 1; position: relative; overflow: hidden; }
```

**VNC 密码设置**（一次性）：
```bash
# 在 Longleaf 计算节点上设置 VNC 密码
echo -e "123456\n123456\nn" | /opt/TurboVNC/bin/vncpasswd
# 密码保存在 ~/.vnc/passwd（NFS 共享，所有计算节点可用）
```

**SSH 密钥配置**（一次性）：
```bash
# 在 frontier 上生成密钥
ssh-keygen -t ed25519 -f ~/.ssh/id_longleaf -N ""
ssh-copy-id -i ~/.ssh/id_longleaf.pub swangek@longleaf.unc.edu

# ~/.ssh/config
Host longleaf
    HostName longleaf.unc.edu
    User swangek
    IdentityFile ~/.ssh/id_longleaf
    ServerAliveInterval 60
```

**使用流程（每次启动会话）**：
1. SSH 到 Longleaf → `srun --pty --time=4:00:00 --mem=8G bash` → 记录计算节点名（如 `c0407`）
2. 在 frontier 运行 `./start_vnc_proxy.sh c0407`（脚本自动完成以下所有步骤）：
   - 部署 Slicer 启动脚本到 `~/.vnc/`
   - 在计算节点上启动 TurboVNC + Slicer（全屏，无桌面）
   - 建立 SSH 隧道
   - 启动 websockify
3. 打开网页 `http://localhost:8080` → 3D Slicer Tab → 点击 Connect
4. 用完后：Ctrl+C 停止 websockify，或运行 `./stop_vnc_proxy.sh`

**端口分配**：
| 端口 | 用途 | 运行位置 |
|------|------|----------|
| 8080 | Python http.server（网页） | frontier |
| 5901 | SSH 隧道本地端（VNC 转发） | frontier → Longleaf |
| 6080 | websockify WebSocket 端口 | frontier |

**VS Code 端口转发**：
使用 VS Code Remote SSH 时，需要在 Ports 面板中转发 8080 和 6080 两个端口，浏览器才能访问。

## 目录结构（更新）

```
/home/swangek/visualization/                    # frontier 服务器
├── index.html                                  # 主页面（3 个 Tab：NiiVue / CIVET / Slicer）
├── serve.sh                                    # 启动 HTTP 服务器（python3 -m http.server 8080）
├── start_vnc_proxy.sh                          # 一键启动 VNC 代理（部署脚本 + VNC + SSH + websockify）
├── stop_vnc_proxy.sh                           # 停止 VNC 代理，清理端口
├── ARCHITECTURE.md                             # 本文件
├── novnc/                                      # noVNC JavaScript VNC 客户端（git clone）
├── verify/                                     # CIVET QC 输出数据（被试 941S6471）
│   ├── volume_slices.png
│   ├── surface_renders.png
│   ├── thickness_map.png
│   ├── qc_stats.png
│   ├── civet_summary_941S6471.png
│   ├── sub_941S6471_surface_qc.txt
│   └── sub_941S6471_classify_qc.txt
└── .gitignore

~/.vnc/                                         # Longleaf NFS 共享目录
├── slicer_xstartup.sh                          # VNC 启动脚本（Slicer-only，无桌面）
├── maximize_slicer.py                          # 自动最大化 Slicer 窗口（X11 ctypes）
└── passwd                                      # TurboVNC 密码文件
```

## CSS 设计

- **暗色主题**：医学影像软件标准配色
  - 背景：`#0d1117`
  - 卡片/工具栏：`#161b22`
  - 边框：`#30363d`
  - 文字：`#e6edf3`（主要），`#8b949e`（次要）
  - 强调色：`#1f6feb`（蓝色按钮/选中态）
- **Flexbox 布局**：NiiVue tab 和 Slicer tab 使用 flex column，主内容区域 `flex: 1` 填满剩余空间
- **响应式**：`@media (max-width: 700px)` 下工具栏和 QC 卡片自适应

## 页面结构（更新）

页面通过 **Tab 切换** 分为三个视图：

1. **3D Viewer (NiiVue)** — 交互式 3D 医学影像查看器（WebGL2 本地渲染）
2. **CIVET QC Report** — CIVET 流水线 QC 结果 PNG 画廊
3. **3D Slicer (VNC)** — 通过 VNC 远程使用 Longleaf 上的 3D Slicer

## 已知限制

1. **Server Path 只支持相对路径**：输入的路径相对于 `http.server` 工作目录。要加载服务器上其他位置的文件，需先软链接或复制到项目目录。
2. **Open Local File 打开客户端文件管理器**：浏览器 `<input type="file">` 的固有行为，文件通过 blob URL 在浏览器端加载，不上传到服务器。
3. **依赖网络加载 NiiVue**：UMD 包从 unpkg.com CDN 加载（~2.3 MB）。
4. **CIVET QC 数据硬编码**：更换被试需要修改 HTML 中的文件路径和 QC 数据。
5. **SLURM 节点需手动获取**：每次使用 3D Slicer 需先 `srun` 获取计算节点名，手动传给 `start_vnc_proxy.sh`。
6. **SSH 密钥需一次性配置**：frontier → Longleaf 的 SSH 密钥认证需要初始设置。
7. **Slicer 窗口自动最大化依赖 X11**：`maximize_slicer.py` 使用 ctypes 调用 libX11，如果 Longleaf 系统升级移除 libX11 可能失效。
8. **VNC 密码明文传输**：noVNC 通过 URL 参数传递 VNC 密码，仅适用于受信任的内部网络环境。

## 后续扩展方向

- 支持加载服务器任意路径文件（需升级为自定义 Python 服务器）
- 动态生成 CIVET QC 页面（Python 脚本读取 verify/ 目录，自动生成 HTML）
- 3D 表面可视化（NiiVue 支持加载 mesh 文件，可展示 CIVET 生成的脑表面）
- 多被试对比视图
- 自动化 SLURM 提交 + VNC 启动（无需手动 `srun`，脚本自动提交作业并获取节点名）
- Slicer 插件预加载（通过 VNC xstartup 脚本自动安装/启用常用 Slicer 扩展）
