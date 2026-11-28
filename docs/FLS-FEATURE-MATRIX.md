# FLS Web 到 APP 原生功能矩阵

## 基线与证据范围

- 历史 B2 配对基线：FLS `ec318d8` / `20261126.12` 已推 `develop`，三个打包 workflow 全绿；APP 修正提交 `394993b` / `0.1.56+70` 的 Android CI `45832261224` 通过 214 项测试及 arm64 APK/artifact `15122689366`。M2a/M2b、M3 B1/B2 自动化候选已通过；M3 B3-B4、M4-M7 与真实面板手动验收仍待推进。最新候选见下段。

- 2026-11-28 两仓继续使用 `develop`。独立目录恢复、保留证据的结束流程及旧客户端兼容 `.26` / `.81` 已完整配对通过。最新 FLS `89047f1` / `20261128.27` 补结束意图的 Windows 写穿透；13:41 CST 核对 Native `46113041435` 仍在运行，三打包成功。APP `6b8f882` / `0.1.81+95` 的 Android `46111748278` 完整成功，314 项测试/APK 通过，artifact `15250530548` 已下载。首轮失败、修正和实际产物均保留于 [备份规格](PANEL-BACKUP-PLAN.md)。不借旧绿证明新 SHA；依赖孤立现场、其余域 busy、APP 全流程及 B4/M4-M7 仍未完成，物理断电未验证。

- 最新通知完整候选：FLS `1350cdf` 已通过 117 项通知相关回归及 Module/Desktop/EXE `45798747950`、`45798748017`、`45798747894`。APP `137e813` 的 Android CI [45800247716](https://github.com/liyw0205/fls-for-android/actions/runs/45800247716) 通过格式/分析/208 项测试、arm64 APK 和 [artifact 15107625629](https://github.com/liyw0205/fls-for-android/actions/runs/45800247716/artifacts/15107625629)，到期于 2026-12-10 10:24:55 UTC；配置保存、测试发送和重试分离，详见 [通知规格](PANEL-NOTIFY-PLAN.md)。正式 Release 均跳过；跨 APP 进程恢复与真实面板手动验收仍待完成。

- 最新代理诊断候选：FLS `1344fa5` / `20261126.8` 已通过 116 项相关回归和三个打包工作流；APP `6ad8279` / `0.1.50+63` 在原生配置基础上接入草稿/单项/批量检测、历史/重试。Android CI [45741020922](https://github.com/liyw0205/fls-for-android/actions/runs/45741020922) 通过格式、分析、187 项测试、arm64 APK 及 [artifact 15081412300](https://github.com/liyw0205/fls-for-android/actions/runs/45741020922/artifacts/15081412300)，到期时间 2026-12-10 02:19 UTC。跨 APP 进程恢复仍待补齐；真实面板待用户手动验收。
- 前批应用配置候选：FLS `418640f` / `20261126.6`、APP `1af4357` / `0.1.48+61`；新增配置 JSON API、原生分组表单、认证变更和保存/应用恢复。FLS 定向及相关回归 81 项通过，Module/Desktop/EXE 工作流 `45730070050`、`45730070074`、`45730070116` 成功。APP Android CI `45730187486` 通过格式、静态分析、166 项测试和 arm64 构建，[artifact 15075239851](https://github.com/liyw0205/fls-for-android/actions/runs/45730187486/artifacts/15075239851) 对应 APP 代码 SHA。此候选仍待用户手动验收。

- 前批全局变量候选：FLS `fa5361c` / `20261126.5`，APP `37862c6` / `0.1.47+60`。FLS 环境 API/恢复及依赖/运行时回归 42 项通过，Module/Desktop/EXE 工作流 `45710477900`、`45710477624`、`45710477863` 成功。APP Android CI `45709589161` 通过格式、分析、157 项测试和 arm64 构建，artifact `15067671072`。
- 前批依赖/运行时基线：FLS `5da1491` / `20261126.3`，APP `29d90cd` / `0.1.46+59`；Module/Desktop/EXE 工作流 `45701269659`、`45701269937`、`45701269593` 和 APP Android CI `45701974657` 均成功，artifact `15064197507`。更早调试子批 FLS `5c5c0ae`、APP `9b73207` 的证据保留在对应矩阵项。
- 两仓均在 `develop`。以下历史子批证据按各自提交记录；CI 通过不等于真实面板手动验收。真实隔离面板验收由用户完成，不做 ADB 测试。
- 本表是按 Flask route、内嵌页面实现与 `fls_manager/static/fls.js` 做的第一轮静态盘点。路由存在不等于 API 契约适合 APP；请求字段、错误语义、分页、认证和操作生命周期仍需逐项由实现及测试确认。
- `main` 仅作稳定基线。APP 与 FLS 的改造在各自 `develop` 上纵向交付；全量原生页面和配套接口完成前不合并到 `main`。

## 功能矩阵

脚本拉取在首次交付后已继续加固：FLS `160a78a` / `20261126.1` 新增本地上传/归档导入作业；本批 `5c5c0ae` 再新增面板调试运行 JSON 契约，APP `0.1.45+58` 增加原生运行/日志和历史页。下方较早的提交/workflow 是各子批历史记录；真实面板手动验收仍待用户。

| FLS 业务域/页面 | APP 当前覆盖 | FLS 可复用接口证据 | 原生迁移与后端工作 |
| --- | --- | --- | --- |
| 登录、Token 登录、验证、首次设置、退出 | 原生登录/session/二次验证/退出；首次设置仍为 WebView | FLS `develop` 增加 `/api/auth/session`、`/api/auth/verify`、`/api/auth/resend-code`、`/api/auth/logout`；业务 API 复用 Flask session cookie；写请求使用 `X-CSRF-Token` | APP 只在登录请求体短暂发送管理员 Token，完成二次验证后才把 session cookie/CSRF token 写入 Android 安全存储；401 清除过期会话。认证契约与回归测试已通过；首次 Token 设置 API 暂未迁移 |
| Dashboard、面板运行状态、调度器 | APP 原生概览读取运行时、调度器、最近计划任务与任务计数；本机和远程共用 | `/api/dashboard/runtime`、`/api/status`、`/api/scheduler/jobs`、`/api/scheduler/status`、`POST /api/scheduler/reload` | 首屏 API 已接入；CPU/调度数据来自服务端。历史异常列表、RAM/磁盘、面板维护操作及刷新策略仍需扩充 |
| 任务列表、创建/编辑、详情、启停、手动运行 | 远程与本机共用原生服务端分页任务页：搜索、运行/启用/停用筛选、Web 同款排序；单项运行/停止/启停/复制/删除/置顶；跨页选择与批量运行/停止/启停/删除 | 新增 `GET /api/tasks?q=&status=&sort=&order=&page=&limit=`，返回白名单 DTO、运行态、页数且禁用缓存；显式 `POST /api/task/action/pin/<id>` 使用 `pinned: bool` 和 `request_id`，旧 Web form toggle 保持兼容；批量写复用 `/api/task/bulk-action` 逐项恢复。既有 `/api/status` 继续为概览摘要，`GET /api/task/<id>` 提供详情/最近 10 条历史，创建/编辑 API 与之前一致 | FLS `e4a46e6` 任务列表/置顶/合集归属定向测试 42 项通过；APP `0.1.35+40` 已实现任务管理和 manager/widget 契约，Android CI `45519285447` 通过。操作确认、未知结果同 request_id 恢复、逐项结果、调度器重载及服务端刷新已接入；真实测试面板待用户验收 |
| 任务配置文件内容 | 任务详情进入原生内容编辑，缺文件创建、重读、冲突草稿对照/合并、保存失联原 ID 查询和显式核对后另行保存；后台隐藏内容、切面板/401 隔离 | `GET/POST /api/tasks/<id>/config-file` 与只读 `GET /requests/<request_id>`；任务/path/revision 绑定、1 MiB 实际有界 UTF-8、外置签名无明文回执、Web/原生交互式发布跨 worker 协调，保留旧 Web | FLS `5ce38a1` / APP `77902df`；新增后端 10 项及 APP manager/Widget，平台 CI/APK 以 [任务配置规格](PANEL-TASK-CONFIG-PLAN.md) 为准。原 ID 当前保留于 manager 会话，跨 APP 进程恢复归 M5，真实面板待用户验收 |
| 普通任务跨 worker 执行与清理 | 列表/详情显示启动、延迟、重试等待、正在停止和终态；详情每 2 秒只读刷新至 active 清理结束；后台隐藏正文/变量/日志，切面板与当前/旧 401 隔离 | 任务详情 runtime 增 history_id/active/stop_requested，列表增 execution_status；首次历史/日志前真实身份、独立命令监管、定时/手动/延迟/重试共享受理、持久停止及历史事务，日志按运行回执读取 | FLS 实现 `f84388a`、Windows 测试修正 `4f47e9e`；APP `269c16c` 的 CI 268 项测试和 APK 成功，后端实际终态见 [任务执行规格](PANEL-TASK-EXECUTION-PLAN.md)。该身份不替代全日志写删协调，日志清理、B3/B4 及用户验收未完成 |
| 任务合集、任务分组、批量任务操作 | APP `develop` 原生合集搜索/分页/创建/编辑/删除、查看成员与候选任务、加入/移出；任务页选择任务后可批量加入指定合集/批量移出 | `GET /api/collections`、`GET /api/collection/<id>?view=members|available`；`/api/collection/save`、`/api/collection/add-task/<id>`、`/api/collection/delete/<id>`；bulk clear 接受 `expected_collections` 避免清掉过期选择，assign/clear 复用 request_id 逐项恢复 | FLS 本批定向测试含批量移出 expected membership 与恢复；APP 集合 manager 加入/移出与原生列表多选动作已接入。此前 FLS 37 项合集/恢复和 APP 88 项 CI 通过；任务管理扩展批次已由 `45509036217` 通过 94 项 CI 测试/分析/构建；真实面板验收待完成 |
| 任务运行日志、执行历史、历史导出 | APP 原生记录页支持历史筛选/分页、状态详情、CSV 导出；系统日志文件筛选/分页、尾部读取、内容搜索和受限下载；任务详情仍展示最近 10 条历史与任务日志 | `GET /api/history`、`/api/history/export` 提供有界白名单分页/导出；`GET /api/logs`、`/api/logfile/<filename>?format=json`、`/api/logfile/<filename>/download` 提供有界日志摘要/尾部/脱敏下载；所有接口复用 session/权限 | 历史与系统日志首个原生纵切已完成；8 MB 下载上限、5000 行尾部、路径限制和敏感信息脱敏已覆盖；真实面板验收待完成 |
| FLS 面板脚本文件、拉取、导入、改名、删除、调试 | APP `develop` 原生面板文件目录、搜索/分页、UTF-8 读取、编辑/新建与冲突草稿；改名确认/恢复、普通文件删除确认、单文件/Git 拉取、代理选择、作业进度/取消/恢复、文件及归档上传已接入。`0.1.45+58` 再新增文件编辑页调试启动、运行/日志页和历史恢复；停止需用户确认，离开页面不会停止脚本。APP 本机容器脚本安装不是远程面板脚本管理 | `/api/scripts/tree`、`/file`、`/rename/*`、`/delete/preview`、`/pull*`、`/repo-pull*`、`/import*` 提供相应文件/作业契约。调试使用 `GET/POST /api/scripts/debug-runs`、`GET /api/scripts/debug-runs/<id>`、`POST /api/scripts/debug-runs/<id>/stop`；写入依赖原生 session/CSRF，启动以 `request_id` 幂等且先持久化，有限历史和状态/日志仅返回白名单字段。日志有行数/字节上限并清理服务器路径和敏感文本；面板重启后无法确认的作业标为 `unknown`，APP 不调用有副作用 Web GET `/scripts/debug/<path>` | FLS 调试 API 本地定向及相关脚本恢复/改名回归共 34 项通过，Module/Desktop/EXE workflow `45682749082`、`45682748710`、`45682748871` 全绿；Release job 按 develop 分支策略跳过。APP manager/widget 与文件入口的调试测试由 Android CI `45683315548` 验证，全 suite 142 项通过，arm64 artifact `15055777025`；Termux Flutter tester 不支持 Android 宿主。真实隔离面板验收仍待用户；脚本域和全量原生迁移均未验收完成 |
| FLS 面板在线脚本市场与安装/更新 | APP `develop` 已有目录/详情/文档/安装进度/历史、源同步及历史、源 JSON 编辑、独立任务导入、外部任务源同步与失败项恢复、任务操作历史/确认/调度器恢复/归档；区别于不启动面板的本机容器脚本市场 | `/catalog`、`/detail/<id>`、`/install-options/<id>`、`/doc/<id>`、安装日志/历史、`/refresh*`、`/import-tasks*`、`/task-link*`、`/source`、`/refresh-options` | FLS `5d54e68` 加入源缓存大小限制、`cache_revision` 冲突保护、代理白名单及 `has_task_source` DTO；409 项用例/305 个 subtests及三项打包 workflow 通过。APP `6afa14c` 的 Android CI #45568326814 已通过 116 项测试、静态分析和 arm64 APK 构建；真实隔离面板验收待用户完成。它不是全量原生迁移完成证明 |
| 依赖管理、Python/Node 运行时 | 原生运行环境页：依赖搜索/分页、核心依赖刷新、依赖安装/卸载确认、运行器检测/安装、作业日志/取消/重试/历史；本机 Python/Full 容器镜像管理仍为独立能力 | `GET /api/deps/packages`、`POST /api/deps/refresh`、`POST /api/deps/uninstall`、`GET /api/runtime/status`；安装/取消/重试/日志/历史复用既有作业 API，operation 兼容旧记录 | FLS `5da1491` / `20261126.3` 的依赖 API 12 项、安装恢复 44 项、运行时状态 7 项及三个打包 workflow 通过。APP `29d90cd` / `0.1.46+59` Android CI `45701974657` 通过 147 项测试、分析和 arm64 构建，artifact `15064197507`。真实面板手动验收待用户；仍需核对安装需求语法、Web 状态展示和部署平台能力，此域不代表全量原生完成 |
| 系统日志、日志文件与清理 | 原生列表/详情/搜索/下载及单文件/多选/分组清理；固定预检查、确认、逐项结果、清理记录及会话内原 ID 恢复已接入，跨进程恢复归 M5 | `e1c4083` 的 capabilities、preview、提交、只读原请求与显式 reconcile；最多 200 文件/20 组、600 秒 TTL、版本与目录绑定、逐项持久删除意图，相同 ID 永不再删除；旧 Web/自动清理和有界下载保持 | 日志后端完整 Native `46085389388` 成功；APP `99d1c9b` 的 CI `46088657554` 286 项测试和 APK 成功，首轮失败保留；真实面板验收待用户 |
| 全局环境变量 | 原生搜索/分页、新建、编辑/改名、删除、查看/替换全文、从任务导入及覆盖开关；冲突保留草稿并核对当前值，未知结果先查询原提交 | `/api/env/variables`、`/variable/<key>?reveal=1`、`/snapshot?reveal=1`、`/task-sources`、`/requests/<request_id>`、`POST /api/env/mutate`；复用全局变量幂等/回执服务，单值/全文/来源版本保护，损坏回执拒绝确认成功 | FLS `fa5361c` / `20261126.5` 相关回归 42 项及三个打包 workflow 通过；APP `37862c6` / `0.1.47+60` Android CI `45709589161` 通过 157 项测试、分析和 arm64 构建，artifact `15067671072`。列表/来源不返回值，内容显式读取、no-store，草稿不落盘。单值 64 KiB、全文 1 MiB、导入最多 200 项；离开页面后无原生提交查询入口，恢复记录/敏感草稿不持久化，跨页面恢复仍需补齐。真实面板手动验收待用户 |
| 应用配置 | 原生分组设置页：主题/端口/脚本源、日志/任务类型、Token 与安全验证；冲突核对/合并、原提交查询和独立应用恢复 | `GET/POST /api/config/settings`、`POST /api/config/totp/enrollment`、`GET /api/config/requests/<request_id>`、JSON `POST /api/config/apply`；旧 Web 表单兼容 | FLS `418640f` / `20261126.6`、APP `1af4357` / `0.1.48+61`，81 项后端回归、三个打包工作流和 APP CI `45730187486` 全绿，166 项 Flutter 测试及 arm64 artifact `15075239851`。原生 session/CSRF、revision、独立 request ID、凭据只写、TOTP 确认和回执恢复已接入。配置请求 ID 在当前面板上下文内存保留，可在重新登录后查询；APP 进程退出后的统一恢复入口仍待补齐。手动验收待用户；详见 [PANEL-CONFIG-PLAN.md](PANEL-CONFIG-PLAN.md) |
| 代理配置、测速/质量、诊断 | APP `6ad8279` / `0.1.50+63`：搜索/筛选/分页、新增/局部编辑/明确启停/删除、冲突合并及原提交恢复；已保存/草稿检测、最多 12 项批量检测、分项进度、历史/详情/重试均有原生入口 | FLS `1344fa5`：`GET/POST /api/proxy/settings`、详情与原配置请求查询；`POST /api/proxy/checks`、`GET /api/proxy/checks[/<id>]`、`POST /api/proxy/checks/<id>/retry`。先持久化再启动、最多 3 并发/12 活动或等待，草稿凭据只留内存；GET 不探测、不重试、不写回 | 后端 116 项回归与 Module/Desktop/EXE `45739901517`、`45739901385`、`45739901439` 全绿；APP CI `45741020922` 187 项测试、分析和 arm64 artifact `15081412300` 全绿。详见 [PANEL-PROXY-PLAN.md](PANEL-PROXY-PLAN.md)。原请求 ID 仅在当前面板内存保留，跨进程恢复仍缺；真实面板手动验收待用户 |
| 通知渠道、测试发送、投递历史 | APP `137e813` / `0.1.53+66` 原生配置/schema/默认选择、冲突恢复、测试发送确认、历史筛选/详情/显式正文、重选渠道后的新 attempt；失联/401 保留原 ID 只查询，后台隐藏正文 | FLS `1350cdf` 保留 settings/requests；新增 `GET /api/notify/deliveries[/<id>]`、`GET /api/notify/delivery-requests/<request_id>`、`POST /api/notify/deliveries/test` 与 `/<id>/retry`。最多 3 并发/无队列、先落签名回执再发送；GET 不发送/claim/写回，旧 Web 行为保留 | 后端 117 项相关回归和三项打包成功；APP CI `45800247716` 208 项测试及 arm64 artifact `15107625629` 成功。上游受理与最终送达分开，网络未知不自动重发、截断重试需确认；跨进程恢复与手动验收待完成。实际资源/恢复边界见 [通知规格](PANEL-NOTIFY-PLAN.md) |
| 备份、导入、恢复、删除 | B1/B2 自动化已通过；B3 有原请求现场恢复、后续处理/历史、有界清理查询及生命周期隔离。独立维护 Tab 不依赖其他列表成功；`.81` 增结束确认/原结果恢复 | 日志/依赖/任务监管、实例锁、WAL、持久性、四域 busy、Windows 指纹及目录恢复/结束配对 CI 成功；`.27` 补结束意图写穿透，保留原字节/目录副本 | `.26` / `.81` 完整通过，APP 314 项测试/APK 成功；最新 `.27` Native 仍在运行，三打包成功，准确证据见备份规格。依赖孤立现场、其余域 busy 及完整流程继续；不计 B3/B4 已交付，手动验收待用户，物理断电未验证 |
| FLS 版本信息、更新、面板控制、时间同步、后台操作日志 | WebView；本机容器镜像和 FLS Release 更新管理已有原生页面 | `/api/about/update-info`、`/api/about/job-log/<id>`；更新执行、重启/停止、时间同步主要由 `/about/*` 表单/页面路由驱动 | 统一 Release/更新作业状态 API，确认进度、取消、重启后的恢复；区别更新 FLS 源代码、运行时镜像和 APP APK |

脚本调试的 `c5bcb2e`、`722c61b` / APP `d6a54e3` 证据保留于备份规格，本表调试行较早的 CI 仍是历史证据。普通任务首次历史/日志、延迟/定时、独立监管/watch/retry 到日志关闭已在 `f84388a` 接入，Windows 修正与平台终态见任务执行规格；不能继续列为未实现，也不能据此认为自动清理和全日志写删协调已完成。

面板脚本调试、依赖/运行时、全局变量、应用配置、代理及 M2a/M2b 通知已有上述 JSON API、APP 原生入口和验证记录。FLS 有副作用的 Web GET 启动路由仅为 Web 兼容保留，APP 不调用；长任务结果未知时显示未知，不自动重放或停止。接下来迁移备份和维护，同时补齐任务/集合/日志及跨 APP 进程恢复缺口，再统一全量导航和主题。任何子批或单域交付都不代表全量原生渲染完成。

## 原生 API 基础契约

现有 API 仍兼容 Web/脚本使用的管理员 `X-Token`，但原生 APP 使用独立的服务端会话：`POST /api/auth/session` 以 JSON 提交 Token，返回随机不透明 HttpOnly cookie 和 CSRF token；FLS 服务端 SQLite 会话表只保存管理员 Token 的 HMAC 指纹、CSRF 值、验证状态和过期时间，不把 Token 放入客户端 cookie。开启二次验证时待验证 session 不能访问业务 API，通过 `/api/auth/verify` 后才可访问。验证码登录可调用 `/api/auth/resend-code`，退出用 `/api/auth/logout`。所有写请求要求 `X-CSRF-Token`。原生端不读取 WebView cookie，也不再持久化管理员 Token；会话按面板隔离保存在 Android 安全存储。

Goal 1 的会话提供器与原生认证纵切已在两个 `develop` 工作区实现，基础认证 API 有回归测试。会话提供器与原生认证验收覆盖 Token 失败/限流、验证码/TOTP、session cookie、CSRF、退出、过期和旧版 Token 存储迁移清理；不得回退到普通偏好设置或 `X-Token` 管理员凭据方案。

统一客户端至少需处理：请求超时/取消、JSON 与非 JSON 错误响应、401/403 与登录过期、CSRF/验证失败、服务端字段错误、重试安全边界、服务器切换时丢弃旧请求，以及所有日志的凭据脱敏。所有写 API 都需确认幂等性和真实副作用。

## 自动化与集成验收

- 后端每新增/变更 API：在 FLS `develop` 增加路由/服务契约测试，覆盖认证、CSRF、权限、参数校验、错误状态和副作用；长任务覆盖状态恢复、重复请求及取消/重试。
- APP 每迁移业务域：增加 manager/DTO 单测和 widget 工作流测试；使用注入 HTTP 客户端的契约 fixture 验证方法、路径、headers、请求体、响应解析和错误态。
- Mock/fixture 只证明协议处理，不证明真实面板兼容。对接真实测试面板的联调由用户选择隔离 FLS `develop` 实例及非生产数据后执行；不得对稳定主面板执行破坏性写操作。
- 保留 WebView 作为该业务域迁移验收期间的可用回退；功能矩阵中每项仅在关键读写流程和自动化测试完成后改为“原生已迁移”。
