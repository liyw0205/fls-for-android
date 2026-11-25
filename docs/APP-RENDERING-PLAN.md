# FLS APP 原生前端实施方案

> 最终目标是 Flutter 原生覆盖 FLS Web 中所有适用页面、表单、状态和操作；本文件记录原生信息架构、本机保留能力和当前/下一批对接。业务域全量清单、推进顺序与双仓合并门槛见 [GOAL-ROADMAP.md](GOAL-ROADMAP.md) 和 [FLS-FEATURE-MATRIX.md](FLS-FEATURE-MATRIX.md)。WebView 只作显式兼容入口，不计入原生覆盖。

## 目标

远程与本机 FLS 面板共用原生导航、页面和业务逻辑，同一页面使用当前面板的服务端数据。APP 单独设计交互，不拉取 Web HTML 重新排版。本机容器的镜像安装、APP 更新和不启动面板的脚本安装依然独立于面板业务。

界面按 Android APP 的阅读和操作习惯设计：信息密度适中、操作明确、进度可见、失败可恢复。视觉沿用现有 FLS APP 的中性色和蓝绿语义色，不复刻桌面 Web 面板的导航、宽表格或悬浮工具栏。

## 原生面板导航

| 一级入口 | 二级页面与操作 |
| --- | --- |
| 概览 | 面板状态、调度器、运行时、近期执行；点击状态进入对应任务或记录 |
| 任务 | 任务列表、详情/编辑、批量动作、合集；任务详情可进入关联脚本和运行日志 |
| 脚本 | 面板文件、在线脚本；目录、编辑、导入、安装、调试及作业状态 |
| 记录 | 执行历史、系统/任务日志；过滤、详情、导出/下载与清理 |
| 管理 | 环境变量、配置、依赖/运行时、代理、通知、备份恢复、FLS 版本与面板控制；显式打开 Web 面板 |

面板级路由始终带当前实例上下文，切换面板时退出旧详情、取消轮询并丢弃旧响应。列表返回恢复筛选、分页和滚动位置；编辑遇冲突保留草稿；长任务区分“已受理”“执行中”“失败”“结果未知”，回到页面按服务端作业 ID 恢复。未迁移的功能标注 Web 回退，不静默跳转。不与 APP 外层的“本机环境/远程面板”入口重复。

## 本机容器与版本管理

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

### FLS 面板在线脚本（当前纵切）

这是远程/本机 FLS 面板上的市场功能，与无需启动 FLS 的 APP 本机容器脚本安装分开，不复用 `OnlineScriptsView` 或 `OnlineScriptsManager`。两仓 `develop` 的版本、提交和工作流结果统一见 [路线图基线](GOAL-ROADMAP.md#分支与合并策略)。下表路径均相对于 `/api/online-scripts`，字段与边界以 FLS `fls_manager/routes/online_scripts/` 及相应测试为准。

| 接入顺序 | 现有接口 | APP 行为与验收 |
| --- | --- | --- |
| 1. 浏览 | `GET` `/catalog`、`/detail/<script_id>`、`/doc/<script_id>` | 服务端搜索/分页，详情保留来源和文档入口。文档有 1 MiB 上限且限制 HTTPS 重定向；Markdown 用 `NativeMarkdownView`，HTML 与纯文本不交给 WebView。 |
| 2. 安装/更新 | `GET` `/install-options/<script_id>`；`POST` `/install/<script_id>` | 代理与任务按服务端选项展示；支持分页选择，默认不导入或启用。覆盖文件须明确确认。区分 409 覆盖确认、已有作业运行和普通冲突；已有作业直接定位，不重复提交。 |
| 3. 状态/恢复 | `GET` `/log/<install_id>?state_only=1`、`/install-history`；`POST` `/install-stop/<install_id>`、`/install-retry/<install_id>`、`/install-start-retry/<install_id>`、`/install-task-confirm/<install_id>`、`/install-task-retry/<install_id>`、`/install-reload/<install_id>` | 状态轻量轮询，日志按需读取有限行数。可靠总量才显示 `xx MB / xx MB · xx%`；未知总量或 Git 操作使用不定进度。轮询不得把下载完成当作安装完成；任务导入和调度器恢复分别显示。历史以 `snapshot` 分页，409 后从第一页重读。 |
| 4. 源同步 | `POST` `/refresh`、`/refresh-recover/<request_id>`、`/refresh-confirm/<request_id>`、`/refresh-retry/<request_id>`；`GET` `/refresh-options`、`/refresh-status/<request_id>`、`/refresh-history`、`/refresh-task-link-failures/<request_id>`、`/refresh-log/<request_id>` | Flutter 原生同步页可选启用代理、查看最近 10 次刷新、轮询状态和日志、确认/恢复未知结果、重试失败项，并按原请求绑定重试单个外部任务源。 |
| 5. 单独任务操作与源缓存 | 既有 `/import-tasks*`、`/task-link*`、`/refresh-task-link*`；新增 `/source` JSON GET/PUT，使用 `cache_revision` 做并发保护 | 详情页可选择并独立导入任务、同步 `task_link`；任务操作历史可确认未知回执、恢复调度器、重试允许的原请求和归档失败记录。源缓存编辑有 4 MiB 缓存/8 MiB 请求上限，校验 JSON、条目和重复 ID；冲突时保留草稿并允许查看/采用服务器版本。 |

APP `develop` 已在 `PanelTasksView` 接入独立 manager、DTO 和原生页面，远程与本机面板共用会话边界。写操作复用原 request ID 恢复，不把代理凭据或任务变量值放进列表 DTO。真实面板仍待手动验收；在线脚本只是一个业务域，其余适用页面继续按矩阵迁移。

写操作接入前的两项 FLS `develop` 契约修整已在 `094c7c3` 完成并通过 61 项定向测试：`install-options` 搜索不再匹配任务环境变量值；覆盖冲突只返回 `target_exists` 和 `confirm_required`，不返回服务器目标路径。继续检查安装拒绝/重试、日志和历史序列化的敏感字段白名单。APP 的错误元数据扩展按在线脚本路由和字段类型白名单处理 `confirm_required`、`target_exists`、`request_id`、`install_id`、`running`、`accepted`、`retry_allowed` 等，不保留目标路径、任意返回 URL、代理凭据或变量值；原始错误不直接展示。

APP 具体落地次序：

1. 保持独立 `panel_online_script.dart`、`panel_online_scripts_manager.dart`、`panel_online_scripts_view.dart` 及相应测试；不改造本机容器 `OnlineScriptsManager`。
2. `PanelTasksView` 现有“脚本”入口继续复用面板会话，与下一批的面板文件归到同一个脚本域。401 后退出嵌套业务路由，面板变化/离开页面时废弃旧请求和计时器。
3. 在隔离面板复核每个 Web 操作的原生入口、冲突草稿保留、request ID 恢复、刷新失败重试和凭据脱敏；CI 和手动状态分别记入矩阵。不得把未实现的 Web 操作标为原生完成。
4. DTO/manager 测试固定 API 方法、路径、查询参数、JSON body、cookie/CSRF headers、分页/快照、进度不确定状态和错误元数据白名单。Widget 测试覆盖空目录、搜索结果、无文档/HTML 文档、窄屏/大字号、确认覆盖、安装受理后断网、轮询恢复、停止、任务导入确认和源刷新失败。
5. 随后按 [全量功能矩阵](FLS-FEATURE-MATRIX.md) 逐域迁移 FLS Web 中所有适用页面、表单、状态、导航和操作，不止版本/镜像/脚本；FLS 缺 JSON 契约时先在 FLS `develop` 补 API 与回归测试，再由 APP 接入。每批执行本地检查并推送两个 `develop`，由对应 GitHub Actions 验证；不合并 `main`，直到全量原生渲染通过矩阵、CI 与用户手动验收。不做 ADB。

### 当前纵切：面板脚本文件目录与编辑

FLS `routes/scripts/files.py` 的 Web 编辑已使用 `script_file_snapshot`、`publish_script_file` 和文件 revision；改名已有任务引用预览与可继续/回滚的操作记录。`routes/scripts/pull.py` 有文件拉取与归档导入；调试仅已有 `/api/scripts/debug-log/<id>` 读接口，启动/停止仍由 Web 路由承载。APP 不抓取这些路由的 HTML，也不直接用调试页面的 GET 请求启动进程。

当前 `develop` 纵切新增 `GET /api/scripts/tree`、`GET /api/scripts/file`、`PUT /api/scripts/file`、`POST /api/scripts/file`。目录分页上限 100，不跟随 symlink、不创建缺失目录、不回传绝对路径；文件仅接受 UTF-8 普通文件并限制 2 MiB。保存沿用 revision 并发保护与原子发布。Termux Python 缺少 `os.link` 时，新建走独占目标保留；改名在 hard-link 不可用的文件系统尝试 `renameat2(RENAME_NOREPLACE)`，避免拒绝支持该文件系统。

APP 在“脚本”入口的在线脚本页提供“面板文件”原生入口：目录搜索/分页/面包屑、UTF-8 编辑和新建；过期 revision 展示草稿与服务器内容，明确选择保留草稿或采用服务器内容后再保存。读写共享当前面板 session/CSRF。当前自动化覆盖在 manager/widget 和 FLS API 测试中；真实隔离面板手动验收仍由用户完成，不做 ADB。其他脚本操作仍按后续纵切推进，不能把本子批记为脚本域或全 APP 原生化完成。

1. **目录与编辑。** 已在当前 `develop` 纵切实现上述 API 与 APP 原生页面。继续验证已写入但回复失败时先重读核实，不盲目重提；若增加文件操作也必须沿用相同路径、安全大小与 revision 边界。
2. **文件操作。** FLS `develop` `0eb515c` (`20261125.9`) 已提供改名预览/确认/恢复 JSON API：`GET /api/scripts/rename/preview`、`POST /api/scripts/rename`、`GET /api/scripts/rename/<operation_id>`、`POST /api/scripts/rename/<operation_id>/recovery`。预览 revision 覆盖文件身份及关联任务引用；确认使用客户端 operation_id 幂等提交，异常后可读状态并继续或回滚。APP 正在加入原生确认表单，展示并允许修订任务命令/配置路径，未知回执使用同一 operation_id 查询或重放；改名后的目录和任务状态重新从后端刷新。带影响范围的删除、受限下载、拉取和归档导入仍由后续 FLS/APP 批次实现。不要在 APP 重新实现路径解析或任务引用改写。
3. **调试。** FLS 补显式 POST 启停、状态、历史与受限脱敏日志契约，复用已有调试服务。APP 离开或重开页面后按原作业 ID 恢复，不以断网或轮询停止当作调试结束。

首个子批的验收：隔离面板上同一个文件可由 APP 与 Web 轮流读取和编辑；过期 revision 不覆盖远端，非法路径与非 UTF-8/超限文件不会进入编辑器；两仓有契约/回归测试和 CI，手动验收记录精确 APP/FLS SHA。缺功能时仅降级对应入口，不把权限错误或普通 404 当作旧面板。

### APP 更新

- 本机页工具栏提供 APP 更新入口，进入后显示当前版本、最新版本和变更提交。
- 最新版本与 arm64 APK 来自 GitHub Release；版本间提交通过 GitHub Compare API 获取，按 `pubspec.yaml` 的 `version` 对应 release tag 比较。
- Compare API 暂时不可用时仍显示 Release 自带日志；APK 下载交由 Android 外部下载/安装流程处理，不在 APP 内静默安装。

## 组件与数据边界

- 页面只依赖结构化模型，不直接拼 HTTP 或启动 WebView。
- `OnlineScriptsManager` 负责目录、文档、远端文件/仓库下载、路径与归档校验和可取消安装任务。
- `PanelOnlineScriptsManager` 独立负责当前面板 session/CSRF 下的目录、文档、安装作业、日志、源管理和失败恢复；不直接访问脚本文件系统。
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

6. **当前纵切：FLS 面板在线脚本**。源管理、独立任务操作、恢复管理与后端 API 已推送两仓 `develop`。继续做隔离面板手动验收，同时按 [功能矩阵](FLS-FEATURE-MATRIX.md) 推进面板脚本文件和其余适用 Web 页面。任何单域完成都不等于全 APP 原生化；全量验收前两仓保持 `main` 不动。

### 手动验收清单

1. 停止本机面板服务后，分别安装/更新 raw 脚本与仓库脚本；确认操作完成后面板仍为停止状态。
2. 在限速网络下下载，检查已接收/总量/百分比与网络面板或下载字节相符；传输期间取消，确认旧版本仍可用且没有暂存文件残留。
3. 更新已有仓库时保留一个本地新增文件；让依赖安装失败或取消，确认上游旧文件恢复、本地文件保留、提交版本未前移、面板未启动。
4. 在竖屏、横屏和系统大字体下检查目录、详情操作、安装进度和日志区域，无重叠且取消操作可触达。
5. 在隔离 `develop` 面板验收目录、安装/更新、停止、任务导入和源刷新；中途断网或重启 APP，从历史恢复原作业，确认没有再次安装或重复导入。同时用两端分别编辑同一份源缓存，确认过期编辑收到冲突且草稿保留。

反馈时记录 APP/FLS 版本和候选提交、Android 版本、容器档位、面板起始状态、网络类型/限速、执行步骤、实际进度与预期、失败日志或截图。未执行的手动项保持待验收状态，不影响继续开发和 CI，不满足正式发布门槛。

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
