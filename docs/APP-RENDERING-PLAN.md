# FLS APP 原生渲染方案

> 本文记录本机容器脚本、APP 版本更新及下一步 FLS 面板在线脚本的原生呈现方案，不代表 APP 最终只渲染这些功能。全量原生前端目标、双仓开发及合并门槛见 [GOAL-ROADMAP.md](GOAL-ROADMAP.md)。

## 目标

本机脚本目录、脚本详情、安装进度和版本更新信息由 Flutter 原生页面负责展示；FLS Web 面板仍用于用户明确打开面板时的完整管理能力。常见脚本浏览与安装不再跳转 WebView，也不依赖启动面板。

界面按 Android APP 的阅读和操作习惯设计：信息密度适中、操作明确、进度可见、失败可恢复。视觉沿用现有 FLS APP 的中性色和蓝绿语义色，不复刻桌面 Web 面板的导航、宽表格或悬浮工具栏。

## 页面结构

### 脚本目录

- 顶部提供搜索、刷新和来源筛选；搜索名称、脚本 ID、仓库名和路径。
- 列表以紧凑行呈现名称、脚本类型、来源仓库、安装状态和最后检查时间，不使用大图卡片。
- 状态区分“未安装”“已安装”“可更新”“检查失败”。当前目录没有可靠版本字段时，先比较已安装文件与远端文件摘要；仓库脚本按文件清单逐项比较。
- 目录离线时保留最后一次成功缓存，并在列表上方显示同步时间和重试操作。

### 脚本详情

- 首屏呈现脚本名称、类型、来源、安装状态和主操作“安装”或“更新”。
- 文档以 APP 原生 Markdown 排版：标题层级、段落、列表、引用、代码块和 HTTPS 链接；代码块可横向滚动并支持复制。
- 安装命令作为来源信息展示，但不把长命令挤进首屏；执行前弹出确认，说明命令来源、目标目录、覆盖范围以及任务不会自动导入或启用。
- 遇到凭据或配置步骤时只展示文档说明，不自动读取本机其他目錄或注入账号信息。

### 安装与更新

- 操作状态采用固定区域：准备、下载、校验、写入、安装依赖、完成/失败/取消。
- 下载阶段提供接收量、总量和百分比；服务端没有 Content-Length 时使用不定进度并显示已接收字节。
- 仓库更新以 staging 文件进行校验后写入；只覆盖上游同名文件，保留目录中未被上游覆盖的本地文件。失败时恢复被覆盖的文件。
- 长命令输出进入可展开的终端日志区；最近日志自动滚动，用户可暂停滚动和复制日志。
- 安装不启动 FLS 面板。需要容器运行环境；容器不存在或损坏时，操作入口转到“环境”页。

### FLS 面板在线脚本（下一纵切）

这是远程/本机 FLS 面板上的市场功能，与无需启动 FLS 的 APP 本机容器脚本安装分开，不复用 `OnlineScriptsView` 或 `OnlineScriptsManager`。FLS `develop` 已从 `bdbbbe9` 更新并推送至 `094c7c3`（`20261125.6`）；APP `develop` 已推送原生首批实现 `216c386`（`0.1.36+41`），Android CI `45549664068` 通过。本批不是全量迁移；剩余范围见第 5 项及 [全量路线图](GOAL-ROADMAP.md)。下表路径均相对于 `/api/online-scripts`，字段与边界以 FLS `fls_manager/routes/online_scripts/` 和 `tests/test_online_native_api.py` 为准。

| 接入顺序 | 现有接口 | APP 行为与验收 |
| --- | --- | --- |
| 1. 浏览 | `GET` `/catalog`、`/detail/<script_id>`、`/doc/<script_id>` | 服务端搜索/分页，详情保留来源和文档入口。文档有 1 MiB 上限且限制 HTTPS 重定向；Markdown 用 `NativeMarkdownView`，HTML 与纯文本不交给 WebView。 |
| 2. 安装/更新 | `GET` `/install-options/<script_id>`；`POST` `/install/<script_id>` | 代理与任务按服务端选项展示；支持分页选择，默认不导入或启用。覆盖文件须明确确认。区分 409 覆盖确认、已有作业运行和普通冲突；已有作业直接定位，不重复提交。 |
| 3. 状态/恢复 | `GET` `/log/<install_id>?state_only=1`、`/install-history`；`POST` `/install-stop/<install_id>`、`/install-retry/<install_id>`、`/install-start-retry/<install_id>`、`/install-task-confirm/<install_id>`、`/install-task-retry/<install_id>`、`/install-reload/<install_id>` | 状态轻量轮询，日志按需读取有限行数。可靠总量才显示 `xx MB / xx MB · xx%`；未知总量或 Git 操作使用不定进度。轮询不得把下载完成当作安装完成；任务导入和调度器恢复分别显示。历史以 `snapshot` 分页，409 后从第一页重读。 |
| 4. 源同步 | `POST` `/refresh`、`/refresh-recover/<request_id>`、`/refresh-confirm/<request_id>`、`/refresh-retry/<request_id>`；`GET` `/refresh-status/<request_id>`、`/refresh-history`、`/refresh-task-link-failures/<request_id>`、`/refresh-log/<request_id>` | 刷新在服务端运行，按请求 ID 恢复，成功后重新读取目录。复用源确认、重试和恢复契约；同步失败不清空现有目录。 |
| 5. 补齐该域 | 既有 `/import-tasks*`、`/task-link*`、`/refresh-task-link*`；手工编辑源缓存目前是 Web 表单 `/online-scripts/source` | 核对后再迁移独立导入、任务关联、同步失败明细/恢复及手工编辑源缓存。手工编辑需 FLS 补有界 JSON 读写、校验与 `cache_revision` 冲突保护。 |

APP 当前在 `PanelTasksView` 接入独立 DTO、`PanelOnlineScriptsManager` 和原生页面，复用 `PanelApiClient` 与现有 `_expireSession`。已覆盖目录/搜索/分页、详情/文档、安装选项、任务选择、覆盖确认、安装状态/日志/停止/恢复和历史；源刷新、源编辑、单独导入/任务关联仍未完成。提交前生成请求 ID，结果未知或返回 `accepted` 时先按原 ID 查状态；仅在服务端明确允许时重试。按面板隔离恢复标识，重进页面或重启后也能从历史找回作业。401 必须退出全部在线脚本嵌套页面并回到重新连接状态，不能停留在旧会话页面。

写操作接入前的两项 FLS `develop` 契约修整已在 `094c7c3` 完成并通过 61 项定向测试：`install-options` 搜索不再匹配任务环境变量值；覆盖冲突只返回 `target_exists` 和 `confirm_required`，不返回服务器目标路径。继续检查安装拒绝/重试、日志和历史序列化的敏感字段白名单。APP 的错误元数据扩展按在线脚本路由和字段类型白名单处理 `confirm_required`、`target_exists`、`request_id`、`install_id`、`running`、`accepted`、`retry_allowed` 等，不保留目标路径、任意返回 URL、代理凭据或变量值；原始错误不直接展示。

APP 具体落地次序：

1. 保持独立 `panel_online_script.dart`、`panel_online_scripts_manager.dart`、`panel_online_scripts_view.dart` 及相应测试；不改造本机容器 `OnlineScriptsManager`。
2. 当前已在 `PanelTasksView` 增加“脚本”入口，复用面板会话。修正 401 后嵌套路由退出行为；面板变化/离开页面时继续废弃旧请求和计时器。主导航之后按全站信息架构收敛分组，避免每个新 Web 菜单都占一个底栏项。
3. 完成在线脚本域剩余源刷新/历史、独立导入、任务关联/恢复和源缓存编辑；核对每个 Web 操作均有原生入口、失败恢复和权限/冲突处理。每个阶段可以交付在 `develop`，但不得标记未实现的 Web 操作为原生完成。
4. DTO/manager 测试固定 API 方法、路径、查询参数、JSON body、cookie/CSRF headers、分页/快照、进度不确定状态和错误元数据白名单。Widget 测试覆盖空目录、搜索结果、无文档/HTML 文档、窄屏/大字号、确认覆盖、安装受理后断网、轮询恢复、停止、任务导入确认和源刷新失败。
5. 随后按 [全量功能矩阵](FLS-FEATURE-MATRIX.md) 逐域迁移 FLS Web 中所有适用页面、表单、状态、导航和操作，不止版本/镜像/脚本；FLS 缺 JSON 契约时先在 FLS `develop` 补 API 与回归测试，再由 APP 接入。每批执行本地检查并推送两个 `develop`，由对应 GitHub Actions 验证；不合并 `main`，直到全量原生渲染通过矩阵、CI 与用户手动验收。不做 ADB。

### APP 更新

- 本机页工具栏提供 APP 更新入口，进入后显示当前版本、最新版本和变更提交。
- 最新版本与 arm64 APK 来自 GitHub Release；版本间提交通过 GitHub Compare API 获取，按 `pubspec.yaml` 的 `version` 对应 release tag 比较。
- Compare API 暂时不可用时仍显示 Release 自带日志；APK 下载交由 Android 外部下载/安装流程处理，不在 APP 内静默安装。

## 组件与数据边界

- 页面只依赖结构化模型，不直接拼 HTTP 或启动 WebView。
- `OnlineScriptsManager` 负责目录、文档、远端文件/仓库下载、路径与归档校验和可取消安装任务。
- 计划新增的 `PanelOnlineScriptsManager` 独立负责当前面板 session/CSRF 下的目录、文档、安装作业、日志、停止与恢复；不直接访问脚本文件系统。
- `LocalPanelHost` 负责通过 Android MethodChannel 在现有 rootfs 中运行一次性命令；该命令不启动 `LocalPanelService`。
- `AppUpdateManager` 负责 Release 元数据、版本比较、Compare commits 和 APK 地址校验。
- Markdown 使用成熟解析器输出 Flutter widget，不把不可信 HTML 直接交给 WebView 渲染。
- 页面通过明确的状态对象表达加载、无结果、离线、更新可用、安装中、取消和错误；网络状态与容器状态互不覆盖。

## 视觉与交互约束

- 单栏列表优先，手机端避免多列布局；宽窗口可升级为左侧目录、右侧详情的双栏视图。
- 主要操作固定在详情页明显位置；刷新、复制、外链和展开日志使用带 tooltip 的图标按钮。
- 下载/安装不使用全屏阻断式 loading；返回页面时明确提示仍在运行或提供取消。
- 代码、提交 SHA、文件路径使用等宽字；长文档和错误支持选择、复制与换行。
- 更新、失败、警告除颜色外还配图标和文字；按钮、进度区高度稳定，内容变化不造成布局跳动。

## 实施阶段

1. **已完成：APP 更新与本机安装基础**。APP 原生更新检查页展示当前/最新版本、Release APK 和版本间提交；在线脚本下载、写入和依赖命令由 APP 流程驱动，不要求启动 FLS 面板。
2. **已完成：目录、详情与版本检测**。目录有缓存、条件请求、来源筛选和离线恢复；raw 文件按 SHA-256、仓库按提交 SHA 检查更新。仓库安装记录 revision，更新只覆盖上游同名文件并保留本地文件。
3. **已完成：原生渲染与故障恢复**。脚本和 Release Markdown 在 Flutter 原生渲染；安装可取消，依赖命令走独立 PRoot 进程，失败/取消回滚已覆盖文件。归档路径和条目数经过校验，安装日志可查看、暂停自动滚动和复制。目录、详情、更新页有窄屏、横屏、大字号与主要交互组件测试。
4. **已完成：可重复的网络边界测试**。CI 已通过无 `Content-Length` 时只显示已接收字节和不定进度，以及分块慢速传输时进度随接收字节前进的 manager/UI 测试。
5. **设备手动验收：由用户执行，不阻塞代码推进**。无需配置 ADB 或模拟器。用户反馈真实设备上遇到的问题后，将可复现部分转成自动化回归测试。

6. **当前纵切：FLS 面板在线脚本（首批已推送，域内未完成）**。FLS `094c7c3`（`20261125.6`）的 61 项定向测试与 Module/Windows Desktop/Windows EXE 工作流 `45548937139`、`45548937276`、`45548937300` 均通过；APP `216c386`（`0.1.36+41`）Android CI `45549664068` 的格式、分析、全部测试及 arm64 构建通过。已补 401 嵌套页面退出。随后补齐在线脚本域剩余操作，再按 [FLS-FEATURE-MATRIX.md](FLS-FEATURE-MATRIX.md) 迁移其余所有适用 Web 页面。任何单域完成都不等于全 APP 原生化，两个 `main` 在全量验收前保持不动。

### 手动验收清单

1. 停止本机面板服务后，分别安装/更新 raw 脚本与仓库脚本；确认操作完成后面板仍为停止状态。
2. 在限速网络下下载，检查已接收/总量/百分比与网络面板或下载字节相符；传输期间取消，确认旧版本仍可用且没有暂存文件残留。
3. 更新已有仓库时保留一个本地新增文件；让依赖安装失败或取消，确认上游旧文件恢复、本地文件保留、提交版本未前移、面板未启动。
4. 在竖屏、横屏和系统大字体下检查目录、详情操作、安装进度和日志区域，无重叠且取消操作可触达。
5. 面板页面接入后，在隔离 `develop` 面板验收目录、安装/更新、停止、任务导入和源刷新；中途断网或重启 APP，从历史恢复原作业，确认没有再次安装或重复导入。

反馈时记录 APP 版本、Android 版本、容器档位、面板起始状态、网络类型/限速、执行步骤、实际进度与预期、失败日志或截图。未执行的手动项保持待验收状态，不影响继续开发和 CI 发布。

### 自动化验证

- 每次推送由 GitHub Actions 执行 Dart 格式检查、`flutter analyze`、`flutter test` 和 arm64 Release APK 构建。
- `test/online_scripts_manager_test.dart` 覆盖下载字节回调、未知总量、取消、暂存清理、覆盖回滚、归档安全和不启动面板。
- `test/online_scripts_view_test.dart` 与 `test/widget_test.dart` 覆盖目录/详情/环境控件在窄屏、横屏和大字号下的交互与视口边界。
- CI 只证明 Flutter 测试和构建通过，不替代上面的 Android 真机手动验收。

## 验收标准

- FLS 面板停止时仍可安装和更新本机脚本，且安装过程不启动面板服务。
- 下载进度与请求字节一致；取消后不留下半成品，失败后恢复已存在文件。
- 仓库包的绝对路径、越界路径、符号链接和超限归档均拒绝安装。
- APP 可检测高于当前版本的 Release，显示 APK 下载入口和当前到最新 tag 之间的提交摘要。
- 网络/API 受限时显示可理解的错误；Compare API 不可用时仍能显示 Release 自带日志。
- UI 在 360 dp 窄屏、横屏、大字号下没有重叠或被固定操作遮挡。
- 已测试本机容器命令取消、覆盖回滚和面板保持停止；网络未知总量时以不定进度显示已接收字节。
