# FLS APP 原生前端实施方案

> 最终目标是 Flutter 原生覆盖 FLS Web 中所有适用页面、表单、状态和操作；本文件记录原生信息架构、本机保留能力和当前/下一批对接。业务域全量清单、推进顺序与双仓合并门槛见 [GOAL-ROADMAP.md](GOAL-ROADMAP.md) 和 [FLS-FEATURE-MATRIX.md](FLS-FEATURE-MATRIX.md)。WebView 只作显式兼容入口，不计入原生覆盖。

两仓继续使用各自 `develop`，最新候选见下段。历史 B2 配对基线为 FLS `ec318d8` / `20261126.12`、APP `394993b` / `0.1.56+70`，相关工作流与 214 项 APP 测试已通过，证据见 [备份规格](PANEL-BACKUP-PLAN.md#当前推进状态)。后续批次从 [DEVELOPMENT-GOALS.md](DEVELOPMENT-GOALS.md) 推进。全量目标仍是所有适用 FLS Web 业务原生渲染，不限版本或在线脚本；DeepSeek chat-demo 的主题方向也须统一覆盖所有已有和新迁移页面。

2026-11-28 继续在两个 `develop` 推进。实例锁、真实 WAL、多 worker 清理和下载异常回收已完整验证，FLS `872c44a` / `20261128.20` 的 Native `46094306921` 及三打包全部成功。最新 FLS `ef4e38f` / `20261128.21` 增提交前刷新及 Windows 写穿透，Native `46096518024` 和三打包全部成功，新增 Windows 持久性 5 项通过。APP `a6a3620` / `0.1.76+90` 补备份页后台确认作废、面板切换和旧回包隔离，Android CI `46093416464` 格式/分析、290 项测试及 arm64 APK 全部成功，artifact `15241534535` 已下载供手测。实际终态/产物及未复现的 Windows 下载测试失败见 [备份规格](PANEL-BACKUP-PLAN.md)，不能借用旧 CI；文件刷新/API/进程强退不证明物理断电。其余 B3/B4、M4-M7、全局导航与 DeepSeek 主题继续，单域通过不计全量交付。

## 目标

远程与本机 FLS 面板共用原生导航、页面和业务逻辑，同一页面使用当前面板的服务端数据。APP 单独设计交互，不拉取 Web HTML 重新排版。本机容器的镜像安装、APP 更新和不启动面板的脚本安装依然独立于面板业务。

本方案的迁移范围是 FLS Web 面板的全量适用业务，不是只做版本管理或在线脚本：包括认证/首次设置、概览、任务与合集、面板脚本和在线脚本、历史与日志、依赖/运行时、环境变量/应用配置、代理、通知、备份恢复及面板维护。逐项以 [FLS 功能矩阵](FLS-FEATURE-MATRIX.md) 为完成依据；本机容器脚本市场与镜像管理是独立能力，不能代替面板业务的原生覆盖。WebView 仅保留为显式回退，不计入完成度。

界面按 Android APP 的阅读和操作习惯设计：信息密度适中、操作明确、进度可见、失败可恢复。视觉沿用现有 FLS APP 的中性色和蓝绿语义色，不复刻桌面 Web 面板的导航、宽表格或悬浮工具栏。

## 原生面板导航

| 一级入口 | 二级页面与操作 |
| --- | --- |
| 概览 | 面板状态、调度器、运行时、近期执行；点击状态进入对应任务或记录 |
| 任务 | 任务列表、详情/编辑、批量动作、合集；任务详情可进入关联脚本和运行日志 |
| 脚本 | 面板文件、在线脚本；目录、编辑、导入、安装、调试及作业状态 |
| 记录 | 执行历史、系统/任务日志；过滤、详情、导出/下载与清理 |
| 管理 | 环境变量、配置、依赖/运行时、代理、通知、备份恢复、FLS 版本与面板控制；显式打开 Web 面板 |

这是全部 FLS 面板的 Flutter 渲染目标，不限本机容器管理、FLS 版本或在线脚本。每个适用 Web 路由、表单、状态、动作都要映射到此导航中的原生页面和后端契约；未迁移流程不能仅因 WebView 可达就算完成。开发顺序先纵切交付各域，再回到 M6 把所有既有/新增页面统一到 DeepSeek chat-demo 参考的主题系统；不能把主题刷新等同于迁移完成。

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

### FLS 面板在线脚本（已交付纵切）

这是远程/本机 FLS 面板上的市场功能，与无需启动 FLS 的 APP 本机容器脚本安装分开，不复用 `OnlineScriptsView` 或 `OnlineScriptsManager`。两仓 `develop` 的版本、提交和工作流结果统一见 [路线图基线](GOAL-ROADMAP.md#分支与合并策略)。下表路径均相对于 `/api/online-scripts`，字段与边界以 FLS `fls_manager/routes/online_scripts/` 及相应测试为准。

| 接入顺序 | 现有接口 | APP 行为与验收 |
| --- | --- | --- |
| 1. 浏览 | `GET` `/catalog`、`/detail/<script_id>`、`/doc/<script_id>` | 服务端搜索/分页，详情保留来源和文档入口。文档有 1 MiB 上限且限制 HTTPS 重定向；Markdown 用 `NativeMarkdownView`，HTML 与纯文本不交给 WebView。 |
| 2. 安装/更新 | `GET` `/install-options/<script_id>`；`POST` `/install/<script_id>` | 代理与任务按服务端选项展示；支持分页选择，默认不导入或启用。覆盖文件须明确确认。区分 409 覆盖确认、已有作业运行和普通冲突；已有作业直接定位，不重复提交。 |
| 3. 状态/恢复 | `GET` `/log/<install_id>?state_only=1`、`/install-history`；`POST` `/install-stop/<install_id>`、`/install-retry/<install_id>`、`/install-start-retry/<install_id>`、`/install-task-confirm/<install_id>`、`/install-task-retry/<install_id>`、`/install-reload/<install_id>` | 状态轻量轮询，日志按需读取有限行数。可靠总量才显示 `xx MB / xx MB · xx%`；未知总量或 Git 操作使用不定进度。轮询不得把下载完成当作安装完成；任务导入和调度器恢复分别显示。历史以 `snapshot` 分页，409 后从第一页重读。 |
| 4. 源同步 | `POST` `/refresh`、`/refresh-recover/<request_id>`、`/refresh-confirm/<request_id>`、`/refresh-retry/<request_id>`；`GET` `/refresh-options`、`/refresh-status/<request_id>`、`/refresh-history`、`/refresh-task-link-failures/<request_id>`、`/refresh-log/<request_id>` | Flutter 原生同步页可选代理、看最近 10 次刷新、轮询状态/日志及显式确认/恢复/重试。查询失败保留已知结果并禁用写入，409/失联只查原 ID；重试前保存 child ID，失败项同步保留 task-link ID。失败明细按 100 项分页，核对原请求/offset/digest/total；旧后端可缺 `ok/active`，已有字段严格校验。 |
| 5. 单独任务操作与源缓存 | 既有 `/import-tasks*`、`/task-link*`、`/refresh-task-link*`；新增 `/source` JSON GET/PUT，使用 `cache_revision` 做并发保护 | 详情页可选择并独立导入任务、同步 `task_link`；任务操作历史可确认未知回执、恢复调度器、重试允许的原请求和归档失败记录。源缓存编辑有 4 MiB 缓存/8 MiB 请求上限，校验 JSON、条目和重复 ID；冲突时保留草稿并允许查看/采用服务器版本。 |

APP `develop` 已在 `PanelTasksView` 接入独立 manager、DTO 和原生页面，远程与本机面板共用会话边界。写操作复用原 request ID 恢复，不把代理凭据或任务变量值放进列表 DTO。真实面板仍待手动验收；在线脚本只是一个业务域，其余适用页面继续按矩阵迁移。

写操作接入前的两项 FLS `develop` 契约修整已在 `094c7c3` 完成并通过 61 项定向测试：`install-options` 搜索不再匹配任务环境变量值；覆盖冲突只返回 `target_exists` 和 `confirm_required`，不返回服务器目标路径。继续检查安装拒绝/重试、日志和历史序列化的敏感字段白名单。APP 的错误元数据扩展按在线脚本路由和字段类型白名单处理 `confirm_required`、`target_exists`、`request_id`、`install_id`、`running`、`accepted`、`retry_allowed` 等，不保留目标路径、任意返回 URL、代理凭据或变量值；原始错误不直接展示。

APP 具体落地次序：

1. 保持独立 `panel_online_script.dart`、`panel_online_scripts_manager.dart`、`panel_online_scripts_view.dart` 及相应测试；不改造本机容器 `OnlineScriptsManager`。
2. `PanelTasksView` 现有“脚本”入口继续复用面板会话，与下一批的面板文件归到同一个脚本域。401 后退出嵌套业务路由，面板变化/离开页面时废弃旧请求和计时器。
3. 在隔离面板复核每个 Web 操作的原生入口、冲突草稿保留、request ID 恢复、刷新失败重试和凭据脱敏；CI 和手动状态分别记入矩阵。不得把未实现的 Web 操作标为原生完成。
4. DTO/manager 测试固定 API 方法、路径、查询参数、JSON body、cookie/CSRF headers、分页/快照、进度不确定状态和错误元数据白名单。Widget 测试覆盖空目录、搜索结果、无文档/HTML 文档、窄屏/大字号、确认覆盖、安装受理后断网、轮询恢复、停止、任务导入确认和源刷新失败。
5. 随后按 [全量功能矩阵](FLS-FEATURE-MATRIX.md) 逐域迁移 FLS Web 中所有适用页面、表单、状态、导航和操作，不止版本/镜像/脚本；FLS 缺 JSON 契约时先在 FLS `develop` 补 API 与回归测试，再由 APP 接入。每批执行本地检查并推送两个 `develop`，由对应 GitHub Actions 验证；不合并 `main`，直到全量原生渲染通过矩阵、CI 与用户手动验收。不做 ADB。

### 已交付子批：面板脚本文件目录、编辑与文件操作

本子批开始时，FLS `routes/scripts/files.py` 的 Web 编辑已使用 `script_file_snapshot`、`publish_script_file` 和文件 revision；改名已有任务引用预览与可继续/回滚的操作记录。`routes/scripts/pull.py` 有文件拉取与归档导入；当时调试仅已有 `/api/scripts/debug-log/<id>` 读接口，启动/停止仍由 Web 路由承载。后续已补 `native_debug.py` 原生作业契约，见下节。APP 不抓取这些路由的 HTML，也不直接用调试页面的 GET 请求启动进程。

当前 `develop` 纵切新增 `GET /api/scripts/tree`、`GET /api/scripts/file`、`PUT /api/scripts/file`、`POST /api/scripts/file`。目录分页上限 100，不跟随 symlink、不创建缺失目录、不回传绝对路径；文件仅接受 UTF-8 普通文件并限制 2 MiB。保存沿用 revision 并发保护与原子发布。Termux Python 缺少 `os.link` 时，新建走独占目标保留；改名在 hard-link 不可用的文件系统尝试 `renameat2(RENAME_NOREPLACE)`，避免拒绝支持该文件系统。

APP 在“脚本”入口的在线脚本页提供“面板文件”原生入口：目录搜索/分页/面包屑、UTF-8 编辑和新建；过期 revision 展示草稿与服务器内容，明确选择保留草稿或采用服务器内容后再保存。读写共享当前面板 session/CSRF。当前自动化覆盖在 manager/widget 和 FLS API 测试中；真实隔离面板手动验收仍由用户完成，不做 ADB。其他脚本操作仍按后续纵切推进，不能把本子批记为脚本域或全 APP 原生化完成。

1. **目录与编辑。** 已在当前 `develop` 纵切实现上述 API 与 APP 原生页面。继续验证已写入但回复失败时先重读核实，不盲目重提；若增加文件操作也必须沿用相同路径、安全大小与 revision 边界。
2. **文件操作。** FLS `develop` 提供改名预览/确认/恢复 JSON API：`GET /api/scripts/rename/preview`、`POST /api/scripts/rename`、`GET /api/scripts/rename/<operation_id>`、`POST /api/scripts/rename/<operation_id>/recovery`。预览 revision 覆盖文件身份及关联任务引用；确认使用客户端 operation_id 幂等提交，异常后可读状态并继续或回滚。APP `157d43c` 已加入原生改名确认和恢复 UI。当前批次在其上补齐删除影响预览和 revision 确认：FLS `GET /api/scripts/delete/preview?path=...` 只返回任务 ID/名称/引用字段，不暴露命令或配置值；`DELETE /api/scripts/file` 传入路径、预览 revision 和显式 `confirm_references`，过期预览、未确认引用、任务运行或调试运行均拒绝删除。APP 删除前显示任务影响；写入结果不确定时重新检查文件存在状态，不盲目重放。删除仅针对普通文件，目录递归删除仍留在 Web。此批测试/CI 结果记录在路线图基线；隔离面板手动验证待用户完成。不要在 APP 重新实现路径解析或任务引用识别。
3. **调试。** 已交付显式 POST 启动/停止、状态、历史与有界脱敏日志；APP 离开页面仅停止轮询，重开后按作业 ID 恢复，不把断网或轮询停止当作调试结束。

首个子批的验收：隔离面板上同一个文件可由 APP 与 Web 轮流读取和编辑；过期 revision 不覆盖远端，非法路径与非 UTF-8/超限文件不会进入编辑器；两仓有契约/回归测试和 CI，手动验收记录精确 APP/FLS SHA。缺功能时仅降级对应入口，不把权限错误或普通 404 当作旧面板。

### 当前纵切：其余面板业务的全量原生迁移

本批从已同步的 FLS `develop` 基线 `160a78a` / `20261126.1` 开始，已推送 FLS `5c5c0ae` / `20261126.2`、APP `bfa268c` / `0.1.45+58` 和测试修正 `9b73207`。FLS 34 项定向/相关恢复测试和三项打包 workflow 全绿；APP Android CI `45683315548` 通过 142 项 Flutter 测试、静态分析及 arm64 APK 构建，develop artifact `15055777025`。APP 首轮 CI 曾发现两项 Widget 测试问题，后续修正并由上述 CI run 验证。两仓仍只在各自 `develop`；全量适用业务覆盖和用户手动验收前不合并 `main`。本机容器的镜像/脚本安装和 APP 更新仍是独立业务，不替代面板业务。

FLS `fls_manager/routes/scripts/native_debug.py` 新增 `GET/POST /api/scripts/debug-runs`、`GET /api/scripts/debug-runs/<id>` 和 `POST /api/scripts/debug-runs/<id>/stop`。JSON 写入经原生 session/CSRF 保护，启动以 `request_id` 幂等、绑定脚本相对路径，并先持久化记录再启动进程；返回白名单字段和有界脱敏日志。Web GET `/scripts/debug/<path>` 的既有启动行为保持兼容，APP 不调用该路由；面板重启后无法确认的作业为 `unknown`，不允许强制停止。

APP 新增独立调试 DTO/manager、运行日志页及历史页，并从面板脚本文件编辑页提供显式启动入口。运行状态每 2 秒轮询，日志可选自动跟随、选择和复制；离开页面不停止服务端进程，历史恢复读取原作业，停止前二次确认。接口错误时启动复用原 `request_id`，避免网络结果未知后重复运行。后续按 [FLS 功能矩阵](FLS-FEATURE-MATRIX.md) 推进依赖/运行时、配置、代理/通知、备份维护和剩余任务/日志操作；任何单域或版本管理完成都不代表全量原生化完成。

**已交付子批：依赖与运行时管理。** 从 FLS `5c5c0ae` / `20261126.2`、APP `3a57f2e` / `0.1.45+58` 开发；仅推各自 `develop`，不合并 `main`。

- FLS 为依赖作业增加 `operation`，旧记录缺省为 `install`；补 `GET /api/deps/packages?q=&page=&limit=`、`POST /api/deps/refresh`、`POST /api/deps/uninstall` 和 `GET /api/runtime/status`。安装/卸载共用已存在的状态、日志、取消、重试和历史 API。卸载仅允许 pip 清单中确认存在的规范包名，使用参数数组而非 shell；请求 ID 幂等，同包并发安装/卸载、重试冲突和面板重启后未确认结果都会拒绝新包操作，用户先检查日志并明确确认后才可继续；运行器诊断不回传服务器命令路径。
- APP `0.1.46+59` 新增结构化依赖/运行器/作业模型、API manager 和 Flutter“运行环境”页；入口复用面板 session/CSRF。页面分段呈现依赖、运行器和作业历史，支持已装依赖搜索/分页、安装/卸载确认、核心依赖检测、运行器安装；作业详情轮询状态/日志，支持复制、取消和显式重试，离开页面不停止面板进程。
- 自动化：FLS `5da1491` / `20261126.3` 的依赖 API 12 项、安装恢复 44 项、运行时检测 7 项通过，Module/Desktop/EXE 工作流 `45701269659`、`45701269937`、`45701269593` 成功。APP `f9805db` / `0.1.46+59` 及测试修正 `29d90cd` 的 Android CI `45701974657` 已通过格式、分析、Flutter 测试和 arm64 APK 构建，artifact `15064197507`。Termux tester 不支持 Android 宿主；真实隔离面板手动验收待用户执行。

**已交付子批：全局环境变量。** 从上述已通过 CI 的两个 `develop` 提交继续。再次 fetch 核对；APP HTTPS fetch 超时后用同仓库 SSH fetch 完成核对。FLS 初始提交 `0fbffd2` / `20261126.4`、回执加固 `fa5361c` / `20261126.5`，APP `91edb88` 与恢复/测试修正 `37862c6` / `0.1.47+60`。

- Web 行为核对：列表、新建、编辑/改名、删除、查看/替换全部、从任务导入；任务变量优先于全局变量。原生写入复用 `mutate_global_env` 的版本、request_id、持久化回执、冲突与明确恢复确认。
- FLS 新增 `/api/env/variables`、`/variable/<key>`、`/snapshot`、`/task-sources`、`/requests/<request_id>` 和 `POST /api/env/mutate`；列表/来源分页且不返回值，详情显式 `reveal=1`，全接口 `no-store`。单值 64 KiB、全文 1 MiB、导入最多 200 项；写入要求全局/单值版本和任务来源版本，冲突不回传完整变量表。旧 Web/API 保持原入口。
- APP 面板选项增加全局变量入口：搜索/分页、变量编辑、全文替换、任务来源多选及覆盖开关。值默认隐藏，后台时隐藏内容，草稿仅存在当前页面内存；离开提示丢弃。冲突需先核对服务器当前内容再明确保存；网络结果未知保留不可修改的原提交，先查询再显式重试，不自动重放。
- 验证：FLS 环境 API/既有恢复/依赖 API/运行时状态 42 项通过，Module/Desktop/EXE `45710477900`、`45710477624`、`45710477863` 成功。APP Android CI `45709589161` 通过格式、分析、157 项测试和 arm64 构建，artifact `15067671072`；覆盖读取契约、全部写操作、冲突草稿、丢失响应恢复、任务导入和窄屏大字下读取失败禁止保存。首轮 `45708089842` 的一项异步加载测试超时已修正。真实面板由用户手动验收；跨页面/APP 重启后原提交查询入口仍需补齐，当前草稿和提交只在页面内存。
- 应用配置已按 [配置规格](PANEL-CONFIG-PLAN.md) 交付 FLS `418640f` / `20261126.6`、APP `1af4357` / `0.1.48+61`：原生表单、严格字段 API、TOTP 确认、冲突草稿合并、原请求查询及显式应用恢复；认证变更使旧原生会话失效。FLS 81 项相关回归及 Module/Desktop/EXE `45730070050`、`45730070074`、`45730070116` 通过；APP Android CI `45730187486` 通过格式、分析、166 项测试及 arm64 构建，artifact `15075239851`。真实面板仍待用户手动验收。
- [代理配置与诊断](PANEL-PROXY-PLAN.md) 已实现配对候选 FLS `1344fa5` / `20261126.8`、APP `6ad8279` / `0.1.50+63`。除配置/冲突/恢复外，现已有显式异步启动、只读状态/历史、新尝试重试，以及 APP 草稿/单项/批量检测、分项进度和历史页。FLS 17 项新增测试及相关回归合计 116 项通过，Module/Desktop/EXE `45739901517`、`45739901385`、`45739901439` 成功；Android CI [45741020922](https://github.com/liyw0205/fls-for-android/actions/runs/45741020922) 通过格式、分析、187 项测试及 arm64 APK，[artifact 15081412300](https://github.com/liyw0205/fls-for-android/actions/runs/45741020922/artifacts/15081412300) 到期时间 2026-12-10 02:19 UTC。跨 APP 进程恢复及真实面板手动验收仍待完成。
- [通知 M2a/M2b](PANEL-NOTIFY-PLAN.md) 已实现完整原生候选 FLS `1350cdf` / `20261126.10` 与 APP `137e813` / `0.1.53+66`：13 类配置表单、默认选择、冲突恢复、独立测试确认、投递历史/显式正文、当前渠道版本重试和原请求查询。原生最多 3 个并发、无等待队列；签名回执先落盘，GET 不发送/claim/写回，网络未知不自动重发。后端 117 项相关回归和三个打包工作流通过；APP CI [45800247716](https://github.com/liyw0205/fls-for-android/actions/runs/45800247716) 格式/分析/208 项测试、arm64 APK 通过，[artifact 15107625629](https://github.com/liyw0205/fls-for-android/actions/runs/45800247716/artifacts/15107625629) 到期于 2026-12-10 10:24:55 UTC。首次 CI 的 2 项失败已修复并由该轮验证，正式 Release 跳过。保存不发送通知，正文后台隐藏并拒收旧回包；原请求目前仍仅面板内存恢复，跨进程恢复和手动验收待完成。
- M3 B1/B2、日志清理、实例锁、真实 WAL、多 worker 清理及 APP 生命周期子批已通过 develop CI；B3 沿用目录现场、I/O 门禁、传输/安装/调试/任务配置及普通任务保护。新文件刷新/Windows 写穿透候选验证见备份规格；明确物理断电未验证边界，继续逐域 busy、坏回执维护和 APP 全流程，最后 B4。M4-M7 的维护、补缺/跨进程恢复、全域导航/主题和配对验收仍待推进；不做 ADB，WebView 只作明示回退。

**已交付单文件拉取子批：** FLS `4dd1b2e` / `20261125.11` 新增异步拉取/状态/历史/代理选项/取消接口。`c21c1f5` / `20261125.12` 加固目录 FD 发布和父目录身份检查；发布恢复需同时匹配 inode 与 SHA-256，取消只有在状态落盘后才设置取消事件。作业以 `request_id` 幂等，限制 64 MiB，流式报告下载字节和可信 Content-Length，使用同目录暂存及不覆盖发布；历史不保存原始 URL 或代理凭据，重启后中断状态为 `unknown`。相关定向测试 59 项、46 个 subtests 已通过；Module/Windows Desktop/Windows EXE workflows `45626660446`、`45626660450`、`45626660376` 全绿。Termux 本机全量 pytest 被已有备份测试对 `os.link` 的平台假设阻断，不将其记为全量通过。

APP `ca841b5` / `0.1.40+51` 新增独立 DTO/manager/页面，在面板文件页提供 URL 拉取入口、代理选项、下载字节进度、取消、作业轮询/恢复和成功后刷新目录；初次打开会自动选中活动作业。`aaf3992` / `0.1.41+52` 为 `path_changed` 错误增加明确的“目标目录已变化，未发布”状态。Android CI `45626774188` 全绿，含格式、分析、131 项 Flutter 测试、arm64 APK 构建和 develop artifact `15029326082`。Termux 宿主的 Flutter tester 不支持 Android，因此本地 `flutter test` 不可用，以 CI 测试为准。

Git 仓库拉取现已补齐 FLS JSON 作业 API，APP 原生复用拉取页并以模式切换区分单文件和 Git 仓库。已 fetch 核对 FLS `develop` 为 `1bce91e` / `20261125.13`，其 26 项相关测试、2 个 subtests 和三项打包 workflow 均通过；APP `3b5b3e0` / `0.1.42+55` 含对象阶段/不定进度与完成态满格显示。Android CI `45646405352` 已全绿：格式、静态分析、133 项 Flutter 测试、arm64 构建和 develop artifact `15039340837` 均通过。Termux Flutter tester 不支持 Android 宿主。两仓均只在各自 `develop` 推进；脚本域剩余功能、全 APP 矩阵/CI 和用户验收完成前不合并 `main`：

**归档导入后端子批：** FLS `develop` `160a78a` / `20261126.1` 新增 `POST /api/scripts/import` multipart 上传，以及 `GET /api/scripts/import/<job_id>`、`GET /api/scripts/import-history`、`POST /api/scripts/import/<job_id>/cancel`。支持普通文件、ZIP、TAR、TGZ；单文件上限 64 MiB、展开总量 256 MiB、最多 10,000 个条目；拒绝路径穿越、重复路径、链接/特殊文件及 Windows 不安全名称。作业以 `request_id` 幂等，限制并发、不覆盖既有目标，归档只发布到新目录，重启中断标记 `unknown`。脚本导入相关 API/文件操作定向测试 39 项及 4 个 subtests 通过；Module `45654317029`、Windows Desktop `45654316801`、Windows EXE `45654316897` workflow 全绿。APP `develop` 代码提交 `3b7b51c` / `0.1.44+57` 已新增原生文件选择、64 MiB 本地复制边界、multipart 上传字节进度、作业恢复/取消和成功后目录刷新；Android CI `45671935279` 全绿，137 项 Flutter 测试、arm64 APK 构建与 develop artifact `15051060616` 均通过。Termux 本机 Flutter tester 不可用；隔离面板手动验收仍待用户完成。

1. **本地上传/归档导入。** FLS API 和 APP 原生纵切已实现：APP 用 `ACTION_OPEN_DOCUMENT` 选择文件，并在受限临时目录副本后显示 multipart 实时字节进度；FLS 状态作业负责安全提取/写入、取消、历史和重启恢复。单文件上限 64 MiB、展开 256 MiB、最多 10,000 条目；拒绝链接、特殊文件、穿越、重复路径和 Windows 不安全名称。普通文件不能覆盖目标，归档必须发布到新目录，失败清理 staging。APP Android CI `45671935279` 已验证格式、分析、137 项 Flutter 测试、arm64 APK 和 artifact `15051060616`；真实面板手动验收待用户完成。
2. **FLS 调试作业 API。** 已新增显式 `POST` 启动/停止、有限历史列表、单作业状态/日志接口；写请求复用原生 session/CSRF。启动以 `request_id` 幂等且绑定脚本相对路径；路径校验、改名恢复检查和命令构造复用现有服务。响应只返回白名单字段，不返回服务器绝对路径或完整命令；日志有行数/字节上限并脱敏。面板重启后无法确认的作业为 `unknown`，APP 不可强制停止。
3. **APP 原生调试页。** 已在文件编辑页接入“调试运行”入口、最近调试记录、状态/日志页与明确停止确认。页面退出只停止轮询；重进按 `debug_id` 恢复状态和日志。日志有界、自动滚动可暂停并可复制；失败/未知/退出码清晰呈现。FLS API 和 APP 不持久化面板绝对路径或命令到 APP 本地。
4. **测试及全量面板覆盖。** FLS 定向测试覆盖 session/CSRF、路径越界/缺失、请求幂等与冲突、持久化失败、启动失败、停止与重启后未知状态、日志/错误脱敏和请求边界；APP manager/widget 测试覆盖请求契约、启动/恢复/显式停止、历史和窄屏。Termux Flutter tester 不支持 Android 宿主，APP 测试以推送后的 Android CI 为准。调试完成后继续按 [FLS 功能矩阵](FLS-FEATURE-MATRIX.md) 逐域迁移所有适用 Web 页面、表单、状态与操作；不能把脚本/版本单域交付视为 APP 全量原生化完成。

本批 FLS `develop` 推送触发 Module `45682749082`、Windows Desktop `45682748710`、Windows EXE `45682748871`，均成功；各 Release job 按分支策略跳过，未生成正式 Release。APP `develop` CI `45683315548` 格式、分析、142 项测试和 arm64 APK 构建通过，artifact `15055777025` 可供用户手动验收。真实隔离面板由用户手动验收，不做 ADB；只有全量原生渲染和用户验收完成后才讨论将两个 `develop` 合并到 `main`。

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

6. **已交付纵切：FLS 面板在线脚本**。源管理、独立任务操作、恢复管理与后端 API 已推送两仓 `develop`，仍待隔离面板手动验收。
7. **当前纵切：全量面板业务迁移**。目录/编辑/改名/删除/拉取/归档导入/调试、依赖/运行时、全局变量、应用配置、代理、M2a/M2b 通知及 M3 B1/B2 已有 `develop` 原生入口和自动化证据。B3 已补目录恢复、I/O 门禁、安装/导入/任务源/刷新/调试/任务配置及普通任务监管、日志有界下载；接续日志原生清理与并发协调、平台与多 worker 清理及 APP 全流程，再做 B4。继续 M4-M7 的首次设置/维护、既有域缺口/跨进程恢复、全域导航/主题与最终验收。主题覆盖全部原生页面；单域完成不等于全 APP 原生化，全量及用户验收前两仓保持 `main` 不动。

### 手动验收清单

1. 停止本机面板服务后，分别安装/更新 raw 脚本与仓库脚本；确认操作完成后面板仍为停止状态。
2. 在限速网络下下载，检查已接收/总量/百分比与网络面板或下载字节相符；传输期间取消，确认旧版本仍可用且没有暂存文件残留。
3. 更新已有仓库时保留一个本地新增文件；让依赖安装失败或取消，确认上游旧文件恢复、本地文件保留、提交版本未前移、面板未启动。
4. 在竖屏、横屏和系统大字体下检查目录、详情操作、安装进度和日志区域，无重叠且取消操作可触达。
5. 在隔离 `develop` 面板验收目录、安装/更新、停止、任务导入和源刷新；中途断网或重启 APP，从历史恢复原作业，确认没有再次安装或重复导入。同时用两端分别编辑同一份源缓存，确认过期编辑收到冲突且草稿保留。

反馈时记录 APP/FLS 版本和候选提交、Android 版本、容器档位、面板起始状态、网络类型/限速、执行步骤、实际进度与预期、失败日志或截图。未执行的手动项保持待验收状态，不影响继续开发和 CI，不满足正式发布门槛。

### 自动化验证

- 每次推送由 GitHub Actions 执行 Dart 格式检查、`flutter analyze`、`flutter test` 和 arm64 Release APK 构建；`develop` push 另上传保留 14 天的测试 APK artifact，不发布 GitHub Release。
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
