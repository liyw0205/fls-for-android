# 备份恢复原生迁移规格

## 范围与基线

M3 接续通知域 M2a/M2b。调研时以 FLS develop `1350cdf71752decaf28ffc0a204ee891354f209c` / `20261126.10` 和 APP `137e81398655726fdd24a2d1485a5e09eac046fe` / `0.1.53+66` 为基线；当前实际候选及验证以本节为准。已核对 `fls_manager/routes/backup/api.py`、`actions.py`、`_common.py`、`restore.py` 及 APP 的上传/下载和 Android 文档选择边界。

覆盖备份列表、创建/取消、原作业与历史、下载/导出、按版本删除，以及手机文件上传、归档预检查、范围/依赖确认、恢复提交、原请求查询、恢复历史、调度器重载与维护提示。远程和本机面板共用 Flutter 页面，数据操作由当前连接的 FLS 执行。APP 不读取远端文件系统，不在手机解压归档后猜测服务端恢复范围。

## 当前推进状态

2026-11-26 已拉取并核对 FLS `develop` 基线 `1350cdf`。B1 后端已提交并推送 FLS `develop` 为 `f72624b` / `20261126.11`；Module `45810989064`、Windows Desktop `45810988940`、Windows EXE installer `45810989001` 均通过，未发布正式 Release。FLS 契约包括能力、分页文件/作业、作业详情、只读原请求查询、创建/取消、按文件版本流式下载和按版本删除。原生 GET 返回 `no-store` 摘要，不复用会归一化/清理状态的旧查询 helper；未知删除回执不会删除同名替换文件。删除回执写在面板根目录 `.backup_native_delete_requests`，不随可恢复的 `data/` 目录回滚。APP `0.1.54+67` 已提交推送为 `e3b528d`；Actions `45811406407` 暴露紧凑屏幕测试的异步等待超时。修复测试并递增至 `0.1.55+68` 后，提交 `ddac555` 的 Android CI `45813098368` 格式、analyze、Flutter tests、arm64 APK 构建及 develop APK 上传均通过，artifact `15113503595`。

当前候选：两仓本轮重新 fetch，FLS `develop` 与 `origin/develop` 同步在 `f72624b`；APP 远端 `develop` 为 `ddac555`，本地保留方案提交 `2376e92`。B2 后端/API、APP 恢复页及测试目前在两个 `develop` 工作树，版本候选分别为 FLS `20261126.12`、APP `0.1.56+69`，尚未提交或推送。

B2 后端已改为上传完成后启动单个后台检查作业，支持只读查询、协作取消和 1 小时暂存 TTL；TAR/ZIP 通过逐块解包到私有临时目录，验证路径/类型/声明展开量、范围、依赖文件和运行态警告。运行中的重复 request ID 校验归档 SHA-256，不同内容冲突；进程重启后未终结作业只读返回 `unknown`。取消逐块检查期间响应，临时展开目录和失败归档清理；成功快照留存到期。恢复提交能力仍显式关闭。

当前本机验证：`python -m unittest tests.test_native_backup_api` 19 项通过；相关备份文件/恢复/认证回归有一轮 100 项通过，但需在当前改动最终版再完整重跑。APP `dart format` 和 `flutter analyze --no-pub` 通过；Flutter tester 在 Termux Android 宿主不支持运行，新增 manager/widget 测试待 GitHub Actions。FLS/APP B2 工作流、APK 与 artifact 尚未运行；不做 ADB/模拟器测试。此前 B1 的三个 FLS workflow 和 APP CI `45813098368` 仍是 B1 证据，不表示 B2 已验证。两开发分支不合并 `main`。

## 现有实现与缺口

下表路径均已存在，但并不等于可直接用于原生契约。

| 已有路由或服务 | 已核对行为 | 迁移工作 |
| --- | --- | --- |
| `POST /api/backup/create` | items 为 data/scripts，32 位 request_id；prepared/launching/submitted 回执，提交可能修复回执并启动 | 保留服务和 Web；原生补精确字段、受理类别和独立只读原请求查询，不能用重复 POST 轮询 |
| `GET /api/backup/job/<job_id>` | 返回原始作业；`get_backup_job` 会把丢失线程转未知、删除孤立 staging、写回记录 | 原生独立只读快照和安全 DTO；GET 不清理文件、不写回、不 claim |
| `POST /api/backup/cancel/<job_id>` | 已实现先保存取消意图、再通知工作线程；取消受理与实际终态分开 | 原生返回稳定状态/错误码，丢失响应后只查询；不能把 accepted 当作 cancelled |
| `GET /api/backup/list` | 目录扫描全部常规归档，返回 name/version/size/mtime；无分页 | 有界列表/分页与扫描、响应限制；损坏/权限错误不可伪装空列表 |
| `POST /api/backup/delete` | filename/version，目录 FD 与文件身份检查；deleted=true/false/null | 保留版本校验，增加原请求恢复；同名替换文件不得作为原删除对象再删除 |
| `GET /backup/download/<filename>` | 以已打开 FD 传输，Content-Length 为实际大小；无显式 expected version 参数 | 增加认证二进制下载契约、文件版本核对和 JSON 错误；流式写 APP 暂存文件 |
| `POST /api/backup/import` | 上传后同一请求同步校验、展开、替换目录、重载调度器及可选安装依赖 | 拆出无写入业务目录的预检查和用户确认后的提交作业；不以无限线程包装整个现有 handler |
| `GET /api/backup/restore/<id>`、`/restore-history` | 持久回执/冗余归档索引；GET 可标记 unknown、压缩回执、修复索引或记录维护事件 | 独立只读原生查询；修复/压缩显式维护，保留旧 Web 行为和历史结果 |
| `POST /api/backup/restore/<id>/reload`、`/restore-maintenance/<event_id>/ack` | 重载不再替换目录；确认维护事件需当前 ID，未修复时不能清提示 | 原生显示独立处理结果；未知恢复不可因重载成功就标为目录恢复成功 |

现有范围仅 data/scripts；支持 TAR/TGZ/TAR.GZ/ZIP。默认上传 512 MiB、展开 2048 MiB、最多 10000 条目，来自 `FLS_BACKUP_MAX_UPLOAD_MB`、`FLS_BACKUP_MAX_EXTRACTED_MB`、`FLS_BACKUP_MAX_ARCHIVE_ENTRIES`；原生必须读取服务端能力和有效限制。现有恢复提交与备份创建互斥，不能新建一套互不知情的锁。备份普通结束历史保留 100 项，活动/未知/待清理项保护；恢复明细默认 200 项，归档索引和维护状态另有保留语义。

备份过滤已排除原生 session SQLite 与 WAL/SHM/journal。M3 还须核对导入旧归档时的运行态保护，以及原生操作回执、签名密钥和实例身份是否进入归档/被替换；原请求查询依赖的记录不能因恢复 data 被覆盖。不能仅靠创建归档时过滤就宣称导入已有归档也受保护。

## 原生契约设计

拟在 `/api/backup/native/` 下隔离原生 DTO 与请求身份，避免悄然改变旧 Web 同步接口。实施时可按现有模块风格调整文件与路由，但必须回填最终契约。

| 能力 | 拟定接口 | 要求 |
| --- | --- | --- |
| 能力/限制 | `GET /capabilities` | 支持的范围、格式、有效上传/展开/条目限制、取消阶段与维护能力；不暴露服务器绝对路径 |
| 文件与作业 | `GET /files`、`GET /jobs`、`GET /jobs/<id>` | 默认 25、最大 100；安全摘要、稳定状态码、历史与当前执行句柄分开；扫描/存储读取有界 |
| 创建/取消 | `POST /jobs`、`POST /jobs/<id>/cancel` | 独立 request_id、固定意图；先持久化再启动；取消仅可证明仍有当前进程持有的句柄时受理 |
| 下载/删除 | `GET /files/<name>/download?version=`、`POST /files/delete` | name/version 绑定同一对象；删除带 request_id；下载从验证后的 FD 读取，不在 APP 内存装载整个归档 |
| 预检查 | `POST /preflights`、`GET /preflights/<id>` | 流式上传或引用列表中的精确文件版本；返回 digest、可用范围、展开量、条目数、依赖文件与警告；不替换目录、不执行依赖 |
| 恢复提交 | `POST /restores` | 绑定 preflight ID/version/digest、范围、restore_deps 和新 request_id；再次校验当前 staged 文件身份及互斥/空间条件 |
| 恢复与请求查询 | `GET /restores`、`GET /restores/<id>`、`GET /requests/<id>` | 只读状态/历史，区分目录恢复、调度器、依赖、归档维护及未知结果；明细清理不丢失历史结论 |
| 后续处理 | `POST /restores/<id>/reload`、`POST /maintenance/<event_id>/ack` | 明确用户动作；不重新上传或替换目录，不能顺带触发依赖重装 |

GET 全部 `no-store`，不写回归一化状态、重建归档、清理 staging 或执行作业。读取冗余索引时只能返回可验证的快照及维护需要，不能调用带修复副作用的旧 helper。请求摘要不存正文、凭据、归档内容或服务器路径；日志按需读取、脱敏并限行/字节。JSON 写入拒绝重复键/未知字段和超限；multipart 拒绝重复关键字段并单独控制文件总量及请求开销。

## 状态、资源与恢复

预检查和恢复分别持有身份。预检查成功仅证明所存快照通过检查；用户确认前不安装依赖、不改业务目录。预检查提交需持久化上传意图并绑定 digest；丢失响应后先查询原 ID，不自动重新传输。若无法证明未接收或未提交，保持 unknown。原恢复 request ID 只绑定一次确定意图，相同 ID 查询不会隐式再次恢复。

恢复状态至少分别表达 queued/running/restored/failed/unknown，以及 `directories_restored`、`scheduler_reload_required`、`dependencies_state` 和 `maintenance_required`。全部目录提交完成、部分目录提交后回滚失败、依赖失败和调度器失败不能压成一个失败按钮。目录恢复后仅提供当前缺失的后续处理，不能引导用户再次上传同一归档。

实施 B1 时先固定并测试资源数值：原生 staging 同时最多 2 个已受理快照、单次上传和展开沿服务端有效上限、预检查最多 1 个执行且无无限队列、恢复最多 1 个执行并复用全局互斥。拟定未引用预检查保留 1 小时；被已受理恢复引用的快照不得到期删除。空间不足在受理前拒绝，拒绝容量不得清理未知恢复所需证据。压缩/展开/依赖进程需真实退出才释放执行槽；依赖安装现有 1800 秒 timeout 不代表输出或整个恢复的资源上限，须补进程组、输出量和退出清理边界。

取消上传只代表 APP 停止传输；服务器是否已受理仍查原 ID。预检查可取消时以服务端状态为准。进入目录提交后不提供“取消恢复成功”；退出页面只停止轮询。预检查到期、缺失、损坏、同名归档替换或实例变化均禁止重用旧确认。回执/索引/运行态的保留与 data 替换必须在设计时一并验证。

锁顺序先按旧创建、归档索引、合集/任务 mutation 和 storage transaction 实际调用图核对；复用旧服务时不能产生反向获取。上传、解压、压缩和网络/子进程等待不持有配置锁。提交目录的短临界区及回滚沿既有服务，保留失败现场和原/新目录，不能用 unknown 触发自动再提交。

## APP 页面与文件传输

从管理入口进入备份页，分文件、作业、恢复历史；详情区分原请求结论和当前明细。创建用 data/scripts 复选项；下载显示接收字节，只有可信总量才显示百分比；删除确认名称/大小/版本。导入经 Android 文档选择器，上传后查看服务端预检查，用户选择可用范围与依赖选项、核对覆盖影响后明确提交。

复用会话/CSRF、DTO/manager、分页、生命周期和嵌套 401 退出模式。Android `pickScriptImport` 当前有 64 MiB 固定边界，`PanelApiClient.getBytes` 是有界内存读取；不能直接放大这些上限来承载默认 512 MiB 备份。新增受能力限制的文档暂存与流式 multipart/下载文件接口，保留脚本原限制；`ACTION_CREATE_DOCUMENT` 导出，取消/失败删除 APP 暂存副本，检查磁盘空间。后台与离页不持久化归档内容到恢复记录。

恢复导致认证改变或断连时，先重登再查询原 request ID；会话旧响应按面板身份/生命周期丢弃。M3 内完成当前面板会话的恢复入口；APP 跨进程统一恢复仍由 M5 接续，不能将内存 ID 说成重启可恢复。操作完成后刷新文件、任务及概览所需数据，避免把远程目录显示为手机本地位置。

## 开发顺序与退出证据

| 子批 | 后端与 APP 工作 | 退出条件 |
| --- | --- | --- |
| B1 文件与备份作业 | FLS `f72624b` 后端 API 已推 `develop`，三个 workflow 运行中；APP 文件/作业页和临时文件流式导出已在 `develop` 工作树实现，待推送 CI | 创建失联仅查询，GET 零写/清理，下载不占归档大小内存，取消与终态分开；配对测试与双方 CI 完成 |
| B2 预检查 | 已在 FLS `develop` 工作树实现安全流式暂存、后台检查、可取消状态、资源/过期规则及只读回执；等待最终回归与 CI | APP `0.1.56+69` 工作树实现本机暂存、上传字节进度、状态轮询、原 ID 查询、取消及范围/依赖/警告预览；测试待 Actions | 预检查绝不替换目录/安装依赖；坏包、超限、路径异常、取消、重启和重复 ID 均有配对证据 |
| B3 恢复及后续处理 | 确认提交、单作业互斥、保留回执及回滚、只读恢复历史、重载/维护；APP 完整确认/恢复界面 | 目录/依赖/调度器/维护结果独立，提交失联不重复恢复，跨 data 恢复不丢原生运行态 |
| B4 配对验证 | 双方版本递增、提交推送 develop，聚焦新契约及旧备份恢复回归、双方 CI 和 APK | 记录确切 SHA/版本、工作流终态、测试边界及 artifact；手动验收待用户，不合并 main |

旧回归至少涵盖 `test_backup_request_recovery`、`test_backup_cancel_recovery`、`test_backup_file_recovery`、`test_backup_orphan_staging`、`test_backup_atomic_publication`、`test_backup_limits`、`test_backup_restore_idempotency`、`test_backup_restore_recovery` 和 `test_auth_backup` 中相关用例。平台不支持的测试单列，不跳过后宣称全量通过。新测试注入存储/线程/进程及目录提交故障，不修改真实面板数据。

APP manager/widget 覆盖子路径/session/CSRF、传输真实进度/未知总量、版本冲突、断网只查询、预检查与提交分离、部分恢复、401 和 320dp/大字号/横屏；Actions 运行 Flutter 测试及 arm64 构建。本地 format/analyze，不做 ADB。隔离面板真实备份和恢复由用户手动验收；M3 通过后继续 M4-M7，全部适用流程及用户验收前两仓均不合并 main。
