# 备份恢复原生迁移规格

## 范围与基线

M3 接续通知域 M2a/M2b。调研时以 FLS develop `1350cdf71752decaf28ffc0a204ee891354f209c` / `20261126.10` 和 APP `137e81398655726fdd24a2d1485a5e09eac046fe` / `0.1.53+66` 为基线；当前实际候选及验证以本节为准。已核对 `fls_manager/routes/backup/api.py`、`actions.py`、`_common.py`、`restore.py` 及 APP 的上传/下载和 Android 文档选择边界。

覆盖备份列表、创建/取消、原作业与历史、下载/导出、按版本删除，以及手机文件上传、归档预检查、范围/依赖确认、恢复提交、原请求查询、恢复历史、调度器重载与维护提示。远程和本机面板共用 Flutter 页面，数据操作由当前连接的 FLS 执行。APP 不读取远端文件系统，不在手机解压归档后猜测服务端恢复范围。

## 当前推进状态

2026-11-26 已拉取并核对 FLS `develop` 基线 `1350cdf`。B1 后端已提交并推送 FLS `develop` 为 `f72624b` / `20261126.11`；Module `45810989064`、Windows Desktop `45810988940`、Windows EXE installer `45810989001` 均通过，未发布正式 Release。FLS 契约包括能力、分页文件/作业、作业详情、只读原请求查询、创建/取消、按文件版本流式下载和按版本删除。原生 GET 返回 `no-store` 摘要，不复用会归一化/清理状态的旧查询 helper；未知删除回执不会删除同名替换文件。删除回执写在面板根目录 `.backup_native_delete_requests`，不随可恢复的 `data/` 目录回滚。APP `0.1.54+67` 已提交推送为 `e3b528d`；Actions `45811406407` 暴露紧凑屏幕测试的异步等待超时。修复测试并递增至 `0.1.55+68` 后，提交 `ddac555` 的 Android CI `45813098368` 格式、analyze、Flutter tests、arm64 APK 构建及 develop APK 上传均通过，artifact `15113503595`。

B2 历史已验证基线：FLS `ec318d8` / `20261126.12`（120）与 APP `394993b` / `0.1.56+70` 均已推送各自 `develop`。FLS Module/Desktop/EXE workflows 全绿。APP 首轮 CI `45830634366` 的一项紧凑屏幕测试因横向 Tab 未滚动可见而失败，修正后的 CI `45832261224` 已通过 format/analyze、214 项测试、arm64 APK 构建并上传 artifact `15122689366`，到期于 2026-12-10 13:50:56 UTC。B2 自动化候选通过；手动验收仍待用户。2026-11-27 先 fetch/fast-forward 核对两仓最新 develop，再继续下述 B3。

B2 后端已改为上传完成后启动单个后台检查作业，支持只读查询、协作取消和 1 小时暂存 TTL；TAR/ZIP 通过逐块解包到私有临时目录，验证路径/类型/声明展开量、范围、依赖文件和运行态警告。运行中的重复 request ID 校验归档 SHA-256，不同内容冲突；进程重启后未终结作业只读返回 `unknown`。取消逐块检查期间响应，临时展开目录和失败归档清理；成功快照留存到期。已验证的 B2 基线关闭恢复提交；B3 开发检查点中的 `restore_enabled=True` 仅用于隔离测试，不代表已发布或可部署到稳定面板。

### B3 原生恢复与后续处理（开发测试检查点）

上一历史检查点为 FLS `bfe175b` / `20261127.4`（124）与 APP `4563e2e` / `0.1.59+73`，用于验证 Termux 无法运行的 Windows Job Object 和 Flutter tester。最新检查点见下方；这些检查点均不代表 B3 完成，也不满足 B4 配对交付门槛，不合并 main、不发布正式 Release。后端入口集中在 `native_api.py`，依赖监管在 `dependency_process.py`，持久目录事务在 `backup_commit.py`，会话锁在 `native_sessions.py`；APP 复用备份页、DTO 和 manager。

2026-11-27 接续目录现场恢复检查点：FLS `c8dd0eb` / `20261127.5`（125），APP 修复候选 `79bbfab` / `0.1.62+76`（原实现 `8629fd3` / `0.1.60+74`）。本轮先 fetch/fast-forward 两仓 develop，均已是最新；FLS main 无额外未纳入 develop 的提交，保留原工作区改动继续推进。下面保留旧检查点的通过证据，新检查点工作流结果单独记录，不用旧 CI 证明新代码。

目录事务清单位于 `BASE_DIR/.backup_native_commits/<request_id>.json`，在首次移动业务目录前持久保存 base/workspace/原目录/替换目录及密钥、会话等运行态对象身份。启动在创建 data、读取密钥和打开会话库前拿共享进程锁；prepared 按实际对象位置回滚，committed 保留新业务目录，遇到替换/损坏停止并保留副本。启动恢复后仍保留清单，由显式 `recover-directories` 保存原请求终态再清理；清理中断可重试。POSIX 对文件树和目录执行 fsync，Windows 当前只保证清单文件 fsync，独立进程硬退出测试不等于 Windows 断电持久性验证。

APP 新增可选严格 bool `directory_recovery_required`（旧后端缺字段按 false）；有现场待处理时隐藏人工结果确认、禁用调度器/依赖启动，提供“恢复目录现场”确认。恢复响应丢失只 GET 原 request ID，不能重新提交归档。损坏清单时 GET 仍提供待恢复提示，POST 保留证据并报错；全部恢复回执损坏的独立维护入口仍待补。

本轮本地四文件定向回归 52 项、29 个子用例通过；包含 6 个搬运节点的独立进程硬退出、恢复过程中再次退出、启动竞争、目录替换、清理重试、损坏/scope 不匹配，以及目录已提交但终态回执写入失败。扩展回归 181 项、181 个子用例通过，另有与既有 Termux 记录相同的 12 个失败；最终新增两个测试也单独通过。APP 121 文件格式及静态分析通过，新增 manager/widget 测试由 Actions 执行；没有 ADB/模拟器或真实面板恢复。

新检查点工作流证据（仅对应 FLS `c8dd0eb` / APP `79bbfab`，失败 run 单列）：

- FLS [Native backup regression 45881063376](https://github.com/liyw0205/fls/actions/runs/45881063376) 成功：Linux 14 文件 187 项、189 个子用例通过；Windows 监管 3 项通过、1 项仅 POSIX 跳过，lease/归档/顺序 5 项、7 个子用例通过，新增目录现场/启动/API 恢复 11 项、10 个子用例通过。
- FLS [Module 45881063347](https://github.com/liyw0205/fls/actions/runs/45881063347)、[Desktop 45881063419](https://github.com/liyw0205/fls/actions/runs/45881063419)、[EXE 45881063360](https://github.com/liyw0205/fls/actions/runs/45881063360) 全部成功；正式 Release 跳过。
- APP `79bbfab` 的 [Android CI 45883212390](https://github.com/liyw0205/fls-for-android/actions/runs/45883212390) 成功：格式、分析、225 项 Flutter 测试、arm64 APK 构建及 develop 上传均通过；[artifact 15148047738](https://github.com/liyw0205/fls-for-android/actions/runs/45883212390/artifacts/15148047738) 到期于 2026-12-10 19:29:52 UTC。正式 Release 跳过；文档后续提交不改变此 APK 的构建 SHA。
- APP 本轮失败修复保留：`8629fd3` 的 [45881498927](https://github.com/liyw0205/fls-for-android/actions/runs/45881498927) 格式/分析成功、223 项测试通过、2 项现场恢复 Widget 测试超时：恢复结果已返回，但后台历史刷新尚未结束，`pumpAndSettle` 无法推进真实 HTTP 异步。`48c256f` 加入等待刷新完成，但 [45882657477](https://github.com/liyw0205/fls-for-android/actions/runs/45882657477) 的 Tooltip 查找返回 RawTooltip，转为 IconButton 导致两项类型错误。`79bbfab` 按实际 IconButton 类型和 tooltip 属性查找，等待刷新完成后 settle，最终工作流已验证。

检查点增加摘要/范围绑定的 `POST /api/backup/native/restores`，以及恢复状态/历史、unknown 人工核对、维护状态/确认、独立调度器重载和依赖操作。状态为 accepted/extracting/staging/committing/restored/failed/unknown；恢复不可取消，GET 不写回，unknown 不自动重放；人工核对仅记账，不执行目录替换。现有测试证据和未完成边界分别记录如下。

按以下顺序收尾；任一项未满足都不把 B3 标成可交付：

| 收尾项 | 完成条件与证据 |
| --- | --- |
| 运行态身份与回滚 | 已剥离归档身份、持久保存完整搬运清单并在启动创建 data/密钥/会话前核对恢复；新增原请求现场恢复、终态回执落盘后清理和清理重试。硬退出及恢复再次中断已测试；仍需 Windows 断电持久性、后台写入者锁和多进程会话边界 |
| 锁顺序与跨进程互斥 | 已移除原生恢复对 storage 的反向获取及 hash/目录遍历期间的配置锁，恢复/调度器/依赖共用带请求/操作身份的进程 lease。后续操作拿锁后重读回执，Linux/Windows 独立 Python 进程验证了持锁查询/重放、竞争拒绝与旧快照不覆盖新记录；构造/启动及失败回执故障也有覆盖。仍需旧 Web 与原生操作竞争和后台写入者的边界 |
| 证据与原请求保留 | 已从持久恢复回执重建 TTL 保护，unknown/待处理依赖不被清理且计入双暂存容量；读取回执字节和历史扫描有上限。每次后续 operation ID 独立保留（最多 16 次），旧 ID 重放不重新执行；到期/内存引用丢失及旧操作重放测试通过，仍需完整容量/损坏/断电故障覆盖 |
| 依赖资源清理 | 已加带启动门的监管进程：持久保存执行/工作目录身份后才执行 pip；POSIX 不提前回收会话首进程、确认组内非僵尸进程退出后释放，面板进程死亡通过控制管道触发回收；Windows 使用带 KILL_ON_JOB_CLOSE 的命名 Job Object，真实 Actions 已验证启动门、命令父进程先退出和所有者崩溃回收。显式 cleanup 按原操作清理且 GET 零副作用；失败、写盘失败、重启恢复、目录替换、输出读取失败均有回归。仍需多 worker 中持有内存清理句柄的进程协调、全部回执损坏时的维护恢复 |
| APP 完整流程 | 已补严格恢复 DTO 类型/一致性及响应身份校验、历史分页/读取失败保留原页、原请求/后续处理轮询、未知结果禁止再次恢复、依赖确认文案及 401 退出嵌套备份页；返回任务页刷新。新增原操作清理按钮，清理期间禁用安装/调度器，清理响应丢失只查询原请求。manager/widget 测试已由 Actions 执行；继续验证跨会话/面板切换/旧回包、概览刷新和提交丢失全流程 |
| 配对验证 | 完成下述旧 Web/认证及故障回归，APP manager/widget 测试在 Actions 执行；再递增两仓实际版本、提交推送 develop，记录双方 CI 与对应 APK。隔离面板手动验收由用户执行，全量前不合并 main |

下一轮实现按依赖顺序推进：先沿 `_common.py` 的备份/恢复 activity 与 `restore.py` 的旧 Web 导入路径统一跨进程门禁，pending 目录清单期间任何新写入恢复都不得绕过；再沿 `native_sessions._database`、`storage_transaction` 和 `models` 历史索引核对实际写入区间，确定统一锁顺序。会话数据库连接应在搬运前关闭，不能只保护 JSON 保存就视为 SQLite 已协调。旧 Web 与原生恢复、备份创建及后台历史写入的独立进程竞争作为退出证据。

随后处理 `RESTORE_DEPENDENCY_CLEANUP` 仅在所属 worker 内存中的句柄：其他 worker 不能因只看到持久身份就提前释放原 owner 的 lease，也不能跳过仍在读输出的线程。全部恢复回执损坏时须保留可核验维护入口，查询不执行修复。APP 再覆盖原生备份页嵌套 401/重登、切换面板、旧回包及任务/概览刷新；这些是后续实现任务，当前检查点不证明已支持。

B3 本地验证边界（2026-11-27）：`test_backup_dependency_process.py`、`test_native_backup_api.py`、`test_native_restore_identity.py`、旧恢复 recovery/idempotency 及认证备份六个测试文件，共 131 项、110 个子用例通过；真实子进程测试不运行 pip，不访问网络。包含启动门、父命令先退出、面板监管所有者崩溃、清理重试不重复发送进程组信号、独立进程竞争、规范化归档根目录，以及清理写盘失败/重启/替换目录保护。APP 全量 Dart 格式及分析通过；Flutter tester 以 Actions 为准（Termux 不支持 Android 宿主）。未做 ADB/模拟器或真实面板恢复。

历史检查点工作流均成功，严格对应 FLS `bfe175b` 与 APP `4563e2e`，不证明后续代码：

- FLS [Native backup regression 45876313543](https://github.com/liyw0205/fls/actions/runs/45876313543)：Linux 12 个原生/旧备份测试文件共 175 项、179 个子用例通过；Windows 监管模块 3 项通过、1 项仅适用 POSIX 而跳过，预检查/进程 lease/回执顺序 5 项、7 个子用例通过。
- FLS [Module 45876313411](https://github.com/liyw0205/fls/actions/runs/45876313411)、[Desktop 45876313556](https://github.com/liyw0205/fls/actions/runs/45876313556)、[EXE 45876313417](https://github.com/liyw0205/fls/actions/runs/45876313417)：实际打包成功，正式 Release 跳过。
- APP [Android CI 45875783380](https://github.com/liyw0205/fls-for-android/actions/runs/45875783380)：格式、分析、222 项 Flutter 测试及 arm64 APK 构建成功；[artifact 15144054566](https://github.com/liyw0205/fls-for-android/actions/runs/45875783380/artifacts/15144054566) 到期于 2026-12-10 18:32:29 UTC。正式 Release 跳过；该 APK 是开发检查点，不能据此在稳定面板执行 B3 恢复。

本轮失败与修复保留：后端 `f69b520` 的 Windows 临时目录占用已在 `17be582` 修复为等待监管进程退出；随后 `be7a006` 的明确前置断言定位到 Windows 正常归档预检查被误拒，`bfe175b` 统一规范化根目录并以路径组件验证归属，同时兼容测试 CRLF。APP `36bfde4` 的 3 个异步等待失败已在 `a1cf6b9` 修正；剩余分页点击屏幕外 Tooltip 的失败在 `4563e2e` 改为滚动到实际图标并断言可点击。旧失败 run 不作为当前提交的通过证据。

扩展的旧创建/取消/文件/归档发布/容量回归曾为 159 项、165 个子用例通过，另有 12 个失败或子用例失败。将当时未修改的 `origin/develop` 导出到独立临时目录后，创建/取消/原子发布三个测试文件复现了完全相同的 12 个失败（20 项及 37 个子用例通过），包含 `os.link` 在 Termux 不存在的直接错误。记录为既有平台限制，不能声称本机完整备份回归全绿；本轮 Linux Actions 的上述 12 文件回归已全绿，真实隔离实例仍待手动验收。

B2 历史验证：FLS 原生备份 19 项及相关备份文件/恢复/认证回归合计 119 项通过；Module/Desktop/EXE `45830575814`、`45830575861`、`45830575979` 全部成功。APP `394993b` 的 CI `45832261224` 通过格式、分析、214 项 Flutter 测试及 arm64 APK 构建，artifact `15122689366` 可供用户手动安装。这些结果只证明 B2 提交，不能用于证明 B3。

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

接口位于 `/api/backup/native/` 下，隔离原生 DTO 与请求身份，保持旧 Web 同步接口。能力、文件/作业、下载/删除和预检查已在 B1/B2 验证；恢复及后续处理为 B3 开发检查点，尚待完整收尾。

| 能力 | 接口与状态 | 要求 |
| --- | --- | --- |
| 能力/限制 | `GET /capabilities` | 支持的范围、格式、有效上传/展开/条目限制、取消阶段与维护能力；不暴露服务器绝对路径 |
| 文件与作业 | `GET /files`、`GET /jobs`、`GET /jobs/<id>` | 默认 25、最大 100；安全摘要、稳定状态码、历史与当前执行句柄分开；扫描/存储读取有界 |
| 创建/取消 | `POST /jobs`、`POST /jobs/<id>/cancel` | 独立 request_id、固定意图；先持久化再启动；取消仅可证明仍有当前进程持有的句柄时受理 |
| 下载/删除 | `GET /files/<name>/download?version=`、`POST /files/delete` | name/version 绑定同一对象；删除带 request_id；下载从验证后的 FD 读取，不在 APP 内存装载整个归档 |
| 预检查 | `POST /preflights`、`GET /preflights/<id>` | 流式上传或引用列表中的精确文件版本；返回 digest、可用范围、展开量、条目数、依赖文件与警告；不替换目录、不执行依赖 |
| 恢复提交（B3 检查点） | `POST /restores` | 绑定 `preflight_id`、`archive_sha256`、`restore_items`、`restore_dependencies`、`confirm_data_impact` 和新 `request_id`；再次校验当前 staged 文件身份及互斥/空间条件 |
| 恢复查询/核对（B3 检查点） | `GET /restores`、`GET /restores/<request_id>`、`POST /restores/<request_id>/resolve` | 恢复按原 request ID 查询；通用 `/requests/<id>` 不代替恢复详情。区分目录恢复、调度器、依赖、维护及未知结果；人工核对只记账 |
| 目录现场恢复（B3 检查点） | `POST /restores/<request_id>/recover-directories`，仅接受 `confirm: true` | 绑定原 request ID 和恢复范围，拿共享进程锁后核对持久清单；先保存确定结果再清理副本。`directory_recovery_required` 只读，有未处理清单时禁止新恢复/人工确认/后续处理；损坏与写盘失败保留现场 |
| 后续处理（B3 检查点） | `POST /restores/<request_id>/scheduler-reload`、`POST /restores/<request_id>/dependencies` | 独立 operation ID，用户显式启动；不重新上传或替换目录，调度器重载不顺带安装依赖 |
| 依赖清理（B3 检查点） | `POST /restores/<request_id>/dependencies/cleanup` | 仅接受原 dependency operation ID；状态里的 `dependencies.cleanup_required` 为只读提示。确认进程/reader 退出和工作目录身份后才清理、保存回执并释放 lease；失败保留占用，成功清理不等于原安装成功，不再次执行 pip |
| 维护（B3 检查点） | `GET /restore-maintenance`、`POST /restore-maintenance/<event_id>/ack` | 只读展示维护状态，确认绑定当前事件 ID；未修复问题不能仅确认后清除 |

GET 全部 `no-store`，不写回归一化状态、重建归档、清理 staging 或执行作业。读取冗余索引时只能返回可验证的快照及维护需要，不能调用带修复副作用的旧 helper。请求摘要不存正文、凭据、归档内容或服务器路径；日志按需读取、脱敏并限行/字节。JSON 写入拒绝重复键/未知字段和超限；multipart 拒绝重复关键字段并单独控制文件总量及请求开销。

## 状态、资源与恢复

预检查和恢复分别持有身份。预检查成功仅证明所存快照通过检查；用户确认前不安装依赖、不改业务目录。预检查提交需持久化上传意图并绑定 digest；丢失响应后先查询原 ID，不自动重新传输。若无法证明未接收或未提交，保持 unknown。原恢复 request ID 只绑定一次确定意图，相同 ID 查询不会隐式再次恢复。

恢复状态按 B3 检查点细化为 accepted/extracting/staging/committing/restored/failed/unknown，并独立表达目录提交、调度器重载、依赖与维护结果；最终字段以收尾后的 DTO 和测试固定。全部目录提交完成、部分目录提交后回滚失败、依赖失败和调度器失败不能压成一个失败按钮。目录恢复后仅提供当前缺失的后续处理，不能引导用户再次上传同一归档。

B1/B2 已验证的资源基线为：原生 staging 同时最多 2 个已受理快照、单次上传和展开沿服务端有效上限、预检查最多 1 个执行且无无限队列、成功预检查保留 1 小时。B3 检查点已为原生恢复/后续处理加入单个跨进程 lease，并保护未完成恢复引用的快照；旧 Web/后台写入的全局互斥仍待统一。空间不足在受理前拒绝，拒绝容量不得清理未知恢复所需证据。依赖作业有 1800 秒等待期限、32 KiB 脱敏输出及独立进程监管，只有进程树和 reader 退出、工作目录清理与回执保存完成才释放；多 worker 清理和回执全部损坏的维护路径尚待补齐。

取消上传只代表 APP 停止传输；服务器是否已受理仍查原 ID。预检查可取消时以服务端状态为准。进入目录提交后不提供“取消恢复成功”；退出页面只停止轮询。预检查到期、缺失、损坏、同名归档替换或实例变化均禁止重用旧确认。回执/索引/运行态的保留与 data 替换必须在设计时一并验证。

锁顺序先按旧创建、归档索引、合集/任务 mutation 和 storage transaction 实际调用图核对；复用旧服务时不能产生反向获取。上传、解压、压缩和网络/子进程等待不持有配置锁。提交目录的短临界区及回滚沿既有服务，保留失败现场和原/新目录，不能用 unknown 触发自动再提交。

## APP 页面与文件传输

从管理入口进入备份页，分文件、作业、恢复历史；详情区分原请求结论和当前明细。创建用 data/scripts 复选项；下载显示接收字节，只有可信总量才显示百分比；删除确认名称/大小/版本。导入经 Android 文档选择器，上传后查看服务端预检查，用户选择可用范围与依赖选项、核对覆盖影响后明确提交。

复用会话/CSRF、DTO/manager、分页、生命周期和嵌套 401 退出模式。Android `pickScriptImport` 当前有 64 MiB 固定边界，`PanelApiClient.getBytes` 是有界内存读取；不能直接放大这些上限来承载默认 512 MiB 备份。新增受能力限制的文档暂存与流式 multipart/下载文件接口，保留脚本原限制；`ACTION_CREATE_DOCUMENT` 导出，取消/失败删除 APP 暂存副本，检查磁盘空间。后台与离页不持久化归档内容到恢复记录。

恢复导致认证改变或断连时，先重登再查询原 request ID；会话旧响应按面板身份/生命周期丢弃。M3 内完成当前面板会话的恢复入口；APP 跨进程统一恢复仍由 M5 接续，不能将内存 ID 说成重启可恢复。操作完成后刷新文件、任务及概览所需数据，避免把远程目录显示为手机本地位置。

## 开发顺序与退出证据

| 子批 | 后端与 APP 工作 | 退出条件 |
| --- | --- | --- |
| B1 文件与备份作业 | FLS `f72624b` 三项打包 workflow 成功；APP `ddac555` / `0.1.55+68` 的 CI `45813098368`、arm64 APK/artifact `15113503595` 通过 | 自动化候选通过：创建失联只查询、GET 零写/清理、流式下载、取消与终态分开；真实面板手动验收待用户 |
| B2 预检查 | FLS `ec318d8` / `20261126.12` 的 19 项定向及 119 项相关回归、三项打包 workflow 通过；APP `394993b` / `0.1.56+70` 的 CI `45832261224`、214 项测试及 arm64 APK/artifact 通过 | 自动化候选通过：预检查不替换目录/安装依赖，覆盖坏包、超限、路径异常、取消、重启和重复 ID；真实面板手动验收待用户 |
| B3 恢复及后续处理 | 最新检查点 FLS `c8dd0eb`、APP `79bbfab` 增加持久目录现场、启动回滚和原请求确认；实际 CI/APK 见上方，继续 Windows 断电边界、旧 Web/后台写入、多 worker 清理、损坏回执维护与 APP 全流程 | 上述剩余项完成并通过故障/兼容回归；检查点和 B2 证据均不能代替 B3/B4 完整交付 |
| B4 配对验证 | 双方版本递增、提交推送 develop，聚焦新契约及旧备份恢复回归、双方 CI 和 APK | 记录确切 SHA/版本、工作流终态、测试边界及 artifact；手动验收待用户，不合并 main |

旧回归至少涵盖 `test_backup_request_recovery`、`test_backup_cancel_recovery`、`test_backup_file_recovery`、`test_backup_orphan_staging`、`test_backup_atomic_publication`、`test_backup_limits`、`test_backup_restore_idempotency`、`test_backup_restore_recovery` 和 `test_auth_backup` 中相关用例。平台不支持的测试单列，不跳过后宣称全量通过。新测试注入存储/线程/进程及目录提交故障，不修改真实面板数据。

APP manager/widget 覆盖子路径/session/CSRF、传输真实进度/未知总量、版本冲突、断网只查询、预检查与提交分离、部分恢复、401 和 320dp/大字号/横屏；Actions 运行 Flutter 测试及 arm64 构建。本地 format/analyze，不做 ADB。隔离面板真实备份和恢复由用户手动验收；M3 通过后继续 M4-M7，全部适用流程及用户验收前两仓均不合并 main。
