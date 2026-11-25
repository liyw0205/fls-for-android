# FLS Web 到 APP 原生功能矩阵

## 基线与证据范围

- FLS `develop`：`0eb515c` / `20261125.9`。先同步 FLS `develop` 后新增面板文件/目录和任务引用改名 JSON API。脚本文件/改名定向测试 27 项通过；Module、Windows Desktop、Windows EXE 工作流均通过（run `45587243874`、`45587243688`、`45587243689`）。Termux 全量测试先前有 19 项环境或既有字段断言失败，不记录为全量通过。
- APP `develop`：候选版本 `0.1.39+50`；目录/编辑/新建和改名上一批通过 Android CI `45590632212`（124 项 Flutter 测试和 arm64 APK）。本批新增删除确认与引用影响展示；Termux Flutter tester 不可运行，Dart 分析通过，等待本批 `develop` CI。真实隔离面板验收仍待用户手动完成。
- 两仓均在 `develop`。以下能力和证据按这组提交记录；CI 通过不等于真实面板手动验收。真实隔离面板验收由用户完成，不做 ADB 测试。
- 本表是按 Flask route、内嵌页面实现与 `fls_manager/static/fls.js` 做的第一轮静态盘点。路由存在不等于 API 契约适合 APP；请求字段、错误语义、分页、认证和操作生命周期仍需逐项由实现及测试确认。
- `main` 仅作稳定基线。APP 与 FLS 的改造在各自 `develop` 上纵向交付；全量原生页面和配套接口完成前不合并到 `main`。

## 功能矩阵

| FLS 业务域/页面 | APP 当前覆盖 | FLS 可复用接口证据 | 原生迁移与后端工作 |
| --- | --- | --- | --- |
| 登录、Token 登录、验证、首次设置、退出 | 原生登录/session/二次验证/退出；首次设置仍为 WebView | FLS `develop` 增加 `/api/auth/session`、`/api/auth/verify`、`/api/auth/resend-code`、`/api/auth/logout`；业务 API 复用 Flask session cookie；写请求使用 `X-CSRF-Token` | APP 只在登录请求体短暂发送管理员 Token，完成二次验证后才把 session cookie/CSRF token 写入 Android 安全存储；401 清除过期会话。认证契约与回归测试已通过；首次 Token 设置 API 暂未迁移 |
| Dashboard、面板运行状态、调度器 | APP 原生概览读取运行时、调度器、最近计划任务与任务计数；本机和远程共用 | `/api/dashboard/runtime`、`/api/status`、`/api/scheduler/jobs`、`/api/scheduler/status`、`POST /api/scheduler/reload` | 首屏 API 已接入；CPU/调度数据来自服务端。历史异常列表、RAM/磁盘、面板维护操作及刷新策略仍需扩充 |
| 任务列表、创建/编辑、详情、启停、手动运行 | 远程与本机共用原生服务端分页任务页：搜索、运行/启用/停用筛选、Web 同款排序；单项运行/停止/启停/复制/删除/置顶；跨页选择与批量运行/停止/启停/删除 | 新增 `GET /api/tasks?q=&status=&sort=&order=&page=&limit=`，返回白名单 DTO、运行态、页数且禁用缓存；显式 `POST /api/task/action/pin/<id>` 使用 `pinned: bool` 和 `request_id`，旧 Web form toggle 保持兼容；批量写复用 `/api/task/bulk-action` 逐项恢复。既有 `/api/status` 继续为概览摘要，`GET /api/task/<id>` 提供详情/最近 10 条历史，创建/编辑 API 与之前一致 | FLS `e4a46e6` 任务列表/置顶/合集归属定向测试 42 项通过；APP `0.1.35+40` 已实现任务管理和 manager/widget 契约，Android CI `45519285447` 通过。操作确认、未知结果同 request_id 恢复、逐项结果、调度器重载及服务端刷新已接入；真实测试面板待用户验收 |
| 任务合集、任务分组、批量任务操作 | APP `develop` 原生合集搜索/分页/创建/编辑/删除、查看成员与候选任务、加入/移出；任务页选择任务后可批量加入指定合集/批量移出 | `GET /api/collections`、`GET /api/collection/<id>?view=members|available`；`/api/collection/save`、`/api/collection/add-task/<id>`、`/api/collection/delete/<id>`；bulk clear 接受 `expected_collections` 避免清掉过期选择，assign/clear 复用 request_id 逐项恢复 | FLS 本批定向测试含批量移出 expected membership 与恢复；APP 集合 manager 加入/移出与原生列表多选动作已接入。此前 FLS 37 项合集/恢复和 APP 88 项 CI 通过；任务管理扩展批次已由 `45509036217` 通过 94 项 CI 测试/分析/构建；真实面板验收待完成 |
| 任务运行日志、执行历史、历史导出 | APP 原生记录页支持历史筛选/分页、状态详情、CSV 导出；系统日志文件筛选/分页、尾部读取、内容搜索和受限下载；任务详情仍展示最近 10 条历史与任务日志 | `GET /api/history`、`/api/history/export` 提供有界白名单分页/导出；`GET /api/logs`、`/api/logfile/<filename>?format=json`、`/api/logfile/<filename>/download` 提供有界日志摘要/尾部/脱敏下载；所有接口复用 session/权限 | 历史与系统日志首个原生纵切已完成；8 MB 下载上限、5000 行尾部、路径限制和敏感信息脱敏已覆盖；真实面板验收待完成 |
| FLS 面板脚本文件、拉取、导入、改名、删除、调试 | APP `develop` 原生面板文件目录、搜索/分页、UTF-8 读取、编辑、新建；冲突可对照服务器版本并保留草稿；改名确认/恢复和普通文件删除确认已接入。拉取/导入/调试未迁移。APP 本机容器脚本安装不是远程面板脚本管理 | `/api/scripts/tree`、`/api/scripts/file` 提供有界目录、UTF-8 snapshot、revision 保存和新建；`/api/scripts/rename/*` 提供任务引用 revision 确认、幂等提交和恢复；`GET /api/scripts/delete/preview` 返回不含命令/配置内容的引用摘要，`DELETE /api/scripts/file` 使用 revision 和引用确认删除普通文件；Web 原路由仍可用 | FLS `0eb515c` 改名 API 已有 CI 证据；当前候选加入删除预览、并发校验、运行/调试保护和 session/CSRF 回归，37 项相关后端定向测试通过。APP `0.1.39+50` 候选增加删除确认、引用影响展示和未知回执后的状态检查；新 CI 待运行。文件拉取/导入及调试 API 仍为后续后端任务；不构成全量原生迁移完成 |
| FLS 面板在线脚本市场与安装/更新 | APP `develop` 已有目录/详情/文档/安装进度/历史、源同步及历史、源 JSON 编辑、独立任务导入、外部任务源同步与失败项恢复、任务操作历史/确认/调度器恢复/归档；区别于不启动面板的本机容器脚本市场 | `/catalog`、`/detail/<id>`、`/install-options/<id>`、`/doc/<id>`、安装日志/历史、`/refresh*`、`/import-tasks*`、`/task-link*`、`/source`、`/refresh-options` | FLS `5d54e68` 加入源缓存大小限制、`cache_revision` 冲突保护、代理白名单及 `has_task_source` DTO；409 项用例/305 个 subtests及三项打包 workflow 通过。APP `6afa14c` 的 Android CI #45568326814 已通过 116 项测试、静态分析和 arm64 APK 构建；真实隔离面板验收待用户完成。它不是全量原生迁移完成证明 |
| 依赖管理、Python/Node 运行时 | WebView；本机 Python/Full 容器镜像管理已原生 | `deps.py` 有安装、取消、重试、确认、日志、历史 API；`runtime.py` 有 `/api/install/runtime/<runtime>` 和安装页面 | 迁移依赖清单/状态/卸载及运行时管理；确认环境与架构、下载/执行权限、流式进度、恢复 Token、取消和不完整安装回滚 |
| 系统日志、日志文件与清理 | APP 原生日志列表/详情/搜索/下载；分组删除仍由 WebView | `/api/logs`、`/api/logfile/<filename>`、`/api/logfile/<filename>/download`；`/api/logs/groups/delete` 仍为 Web 操作 | 原生读取与下载已完成；分组清理需单独补结构化确认/写入契约 |
| 全局环境变量 | WebView | `/api/env/action` 有动作写 API；`/env`、`/env/view`、`/env/new`、`/env/edit/<key>`、`/env/delete/<key>`、`/env/import` 页面 | 补结构化变量列表/详情/验证契约；敏感值在 APP 响应、缓存、日志和复制中脱敏，更新需明确副作用 |
| 应用配置 | WebView | `POST /api/config/apply`；`/config` 页面承担读取/编辑表单 | 核对配置 schema、只读字段、应用/重启副作用及错误回滚；需要稳定 schema/配置读 API 后再迁移表单 |
| 代理配置、测速/质量、诊断 | WebView | `/api/proxy/test-form`、`/api/proxy/quality-form`、`/api/proxy/test/<id>`、`/api/proxy/quality/<id>`、`/api/proxy/diagnostics` 和重试；`/api/proxy/action` 写动作 | 补代理列表/详情/保存/删除结构化契约；对探测长任务支持可恢复状态、超时和有界日志；凭据不得回显/记录 |
| 通知渠道、测试发送、投递历史 | WebView | `/api/notify/action`、`/api/notify/test/<id>`、`/api/notify/history`、`/api/notify/retry/<delivery_id>`；渠道编辑页为 HTML 表单 | 补渠道列表/编辑 schema，密钥采用只写或遮蔽语义；明确默认渠道、删除、测试副作用和投递历史分页 |
| 备份、导入、恢复、删除 | WebView | `routes/backup/api.py` 有备份 list/create/job/cancel/delete；`restore.py` 有 restore history/status、import、reload、maintenance ack API | 逐项确认上传/下载、覆盖范围、备份格式/尺寸限制、恢复预检查、可中断阶段与恢复操作状态；所有覆盖操作需明确确认 |
| FLS 版本信息、更新、面板控制、时间同步、后台操作日志 | WebView；本机容器镜像和 FLS Release 更新管理已有原生页面 | `/api/about/update-info`、`/api/about/job-log/<id>`；更新执行、重启/停止、时间同步主要由 `/about/*` 表单/页面路由驱动 | 统一 Release/更新作业状态 API，确认进度、取消、重启后的恢复；区别更新 FLS 源代码、运行时镜像和 APP APK |

## 原生 API 基础契约

现有 API 仍兼容 Web/脚本使用的管理员 `X-Token`，但原生 APP 使用独立的服务端会话：`POST /api/auth/session` 以 JSON 提交 Token，返回随机不透明 HttpOnly cookie 和 CSRF token；FLS 服务端 SQLite 会话表只保存管理员 Token 的 HMAC 指纹、CSRF 值、验证状态和过期时间，不把 Token 放入客户端 cookie。开启二次验证时待验证 session 不能访问业务 API，通过 `/api/auth/verify` 后才可访问。验证码登录可调用 `/api/auth/resend-code`，退出用 `/api/auth/logout`。所有写请求要求 `X-CSRF-Token`。原生端不读取 WebView cookie，也不再持久化管理员 Token；会话按面板隔离保存在 Android 安全存储。

Goal 1 的会话提供器与原生认证纵切已在两个 `develop` 工作区实现，基础认证 API 有回归测试。会话提供器与原生认证验收覆盖 Token 失败/限流、验证码/TOTP、session cookie、CSRF、退出、过期和旧版 Token 存储迁移清理；不得回退到普通偏好设置或 `X-Token` 管理员凭据方案。

统一客户端至少需处理：请求超时/取消、JSON 与非 JSON 错误响应、401/403 与登录过期、CSRF/验证失败、服务端字段错误、重试安全边界、服务器切换时丢弃旧请求，以及所有日志的凭据脱敏。所有写 API 都需确认幂等性和真实副作用。

## 自动化与集成验收

- 后端每新增/变更 API：在 FLS `develop` 增加路由/服务契约测试，覆盖认证、CSRF、权限、参数校验、错误状态和副作用；长任务覆盖状态恢复、重复请求及取消/重试。
- APP 每迁移业务域：增加 manager/DTO 单测和 widget 工作流测试；使用注入 HTTP 客户端的契约 fixture 验证方法、路径、headers、请求体、响应解析和错误态。
- Mock/fixture 只证明协议处理，不证明真实面板兼容。对接真实测试面板的联调由用户选择隔离 FLS `develop` 实例及非生产数据后执行；不得对稳定主面板执行破坏性写操作。
- 保留 WebView 作为该业务域迁移验收期间的可用回退；功能矩阵中每项仅在关键读写流程和自动化测试完成后改为“原生已迁移”。
