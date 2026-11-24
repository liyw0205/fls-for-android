# FLS Web 到 APP 原生功能矩阵

## 基线与证据范围

- FLS 源码：`$HOME/fls` 的 `develop` 本轮起点为 `df46c03` / FLS 版本 `20261125.1`。
- APP 源码：`fls-for-android` 的 `develop` 本轮起点为 `0a1ca9a`；Android CI 当时通过 84 项测试、静态分析和 arm64 Release APK 构建。
- 本表是按 Flask route、内嵌页面实现与 `fls_manager/static/fls.js` 做的第一轮静态盘点。路由存在不等于 API 契约适合 APP；请求字段、错误语义、分页、认证和操作生命周期仍需逐项由实现及测试确认。
- `main` 仅作稳定基线。APP 与 FLS 的改造在各自 `develop` 上纵向交付；全量原生页面和配套接口完成前不合并到 `main`。

## 功能矩阵

| FLS 业务域/页面 | APP 当前覆盖 | FLS 可复用接口证据 | 原生迁移与后端工作 |
| --- | --- | --- | --- |
| 登录、Token 登录、验证、首次设置、退出 | 原生登录/session/二次验证/退出；首次设置仍为 WebView | FLS `develop` 增加 `/api/auth/session`、`/api/auth/verify`、`/api/auth/resend-code`、`/api/auth/logout`；业务 API 复用 Flask session cookie；写请求使用 `X-CSRF-Token` | APP 只在登录请求体短暂发送管理员 Token，完成二次验证后才把 session cookie/CSRF token 写入 Android 安全存储；401 清除过期会话。认证契约与回归测试已通过；首次 Token 设置 API 暂未迁移 |
| Dashboard、面板运行状态、调度器 | APP 原生概览读取运行时、调度器、最近计划任务与任务计数；本机和远程共用 | `/api/dashboard/runtime`、`/api/status`、`/api/scheduler/jobs`、`/api/scheduler/status`、`POST /api/scheduler/reload` | 首屏 API 已接入；CPU/调度数据来自服务端。历史异常列表、RAM/磁盘、面板维护操作及刷新策略仍需扩充 |
| 任务列表、创建/编辑、详情、启停、手动运行 | 本机和远程共用原生任务列表、详情、创建/编辑与运行/停止/启用操作；Web 表单保留作回退 | `/api/status` 提供运行摘要；`GET /api/task/<task_id>` 返回白名单配置、运行状态和最近 10 条历史；FLS `develop` 新增 `/api/tasks/form-options`、`POST /api/tasks`、`PUT /api/tasks/<task_id>`；新建用 request_id 幂等，更新用 expected_updated_at 防并发覆盖；`/api/task/action/<action>/<task_id>` 提供现有操作；`POST /api/scheduler/reload` 提供恢复入口 | 原生任务基础工作流已接入；后端覆盖 Cron/配置路径/变量/代理/通知/延迟/重试校验，重复创建与并发编辑有冲突语义；保存成功但调度器失败时 APP 提供仅重载调度器入口。manager/widget 工作流已通过 Android CI；真实测试面板联调待用户验收 |
| 任务合集、任务分组、批量任务操作 | APP `develop` 原生合集首版：合集搜索/分页/创建/编辑/删除，查看成员与候选任务，添加/移出任务；WebView 保留回退 | 新增 `GET /api/collections` 与 `GET /api/collection/<id>?view=members|available`；复用 `/api/collection/save`、`/api/collection/add-task/<id>`、`/api/collection/delete/<id>` 和 `/api/task/action/clear_collection/<task_id>`；读响应白名单化、禁缓存，写请求携带 request_id、集合 revision 和 expected member/collection 状态 | 已有 FLS `develop` API 单测及 APP manager/widget 契约测试；本轮需由 Android CI 执行 APP widget 测试与 APK 构建，并由用户在隔离测试面板手动验收。复制/批量移出及 Web 的全部批量操作仍未迁移 |
| 任务运行日志、执行历史、历史导出 | 原生任务详情展示最近 10 条运行历史和最近 200 行任务日志，可手动刷新；历史筛选/导出仍由 WebView 承接 | `GET /api/task/<task_id>` 返回最近 10 条历史摘要；FLS `develop` 新增 `GET /api/task/<task_id>/log?lines=...` JSON API，限制 1-1000 行并复用日志脱敏；`/history`、`/history/export` 页面路由 | 任务日志基础读取已接入；仍需历史筛选分页 API 与导出下载契约，不在 APP 一次性加载无限日志 |
| 本机脚本文件、拉取、导入、改名、删除、调试 | WebView；APP 已有的是 Android 本机容器内脚本安装/更新，不是远程面板完整脚本管理 | `/scripts/view`、`/pull`、`/pull/fetch`、`/pull/import`、`/scripts/rename`、`/scripts/delete`、`/scripts/debug/*`；调试日志有 `/api/scripts/debug-log/<id>` | 需要明确远程服务器脚本文件 API、编辑冲突/原子替换、上传/下载大小限制、调试启动停止和日志状态 API；现有 APP 本机安装能力保留为容器专属功能 |
| FLS 面板在线脚本市场与安装/更新 | 当前 APP 原生市场读取外部 FLS Scripts CDN，主要安装本机容器；FLS 面板 Web 市场仍由 WebView 展示 | `routes/online_scripts/` 提供源、文档、安装/刷新、导入任务、任务关联、历史、日志、状态、重试/取消/恢复等多组 `/api/online-scripts/*` | 必须区分“面板远程市场安装到 FLS 服务器”和“APP 本机容器脚本安装”两种对象与权限；逐项对照 Web 生命周期，支持长任务状态重载和失败恢复 |
| 依赖管理、Python/Node 运行时 | WebView；本机 Python/Full 容器镜像管理已原生 | `deps.py` 有安装、取消、重试、确认、日志、历史 API；`runtime.py` 有 `/api/install/runtime/<runtime>` 和安装页面 | 迁移依赖清单/状态/卸载及运行时管理；确认环境与架构、下载/执行权限、流式进度、恢复 Token、取消和不完整安装回滚 |
| 系统日志、日志文件与清理 | WebView | `/logs`、`/logfile/<filename>` 页面；`/api/logfile/<filename>`、`/api/logs/groups/delete`；任务日志另见 `/api/log/<id>` | 增加或复用有界日志索引/过滤 API，限制路径由服务端决定；确认下载、分组删除和清理确认语义 |
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
