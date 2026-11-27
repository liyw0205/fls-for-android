# 备份恢复原生迁移规格

## 范围与基线

M3 接续通知域 M2a/M2b。调研时以 FLS develop `1350cdf71752decaf28ffc0a204ee891354f209c` / `20261126.10` 和 APP `137e81398655726fdd24a2d1485a5e09eac046fe` / `0.1.53+66` 为基线；当前实际候选及验证以本节为准。已核对 `fls_manager/routes/backup/api.py`、`actions.py`、`_common.py`、`restore.py` 及 APP 的上传/下载和 Android 文档选择边界。

覆盖备份列表、创建/取消、原作业与历史、下载/导出、按版本删除，以及手机文件上传、归档预检查、范围/依赖确认、恢复提交、原请求查询、恢复历史、调度器重载与维护提示。远程和本机面板共用 Flutter 页面，数据操作由当前连接的 FLS 执行。APP 不读取远端文件系统，不在手机解压归档后猜测服务端恢复范围。

## 当前推进状态

2026-11-26 已拉取并核对 FLS `develop` 基线 `1350cdf`。B1 后端已提交并推送 FLS `develop` 为 `f72624b` / `20261126.11`；Module `45810989064`、Windows Desktop `45810988940`、Windows EXE installer `45810989001` 均通过，未发布正式 Release。FLS 契约包括能力、分页文件/作业、作业详情、只读原请求查询、创建/取消、按文件版本流式下载和按版本删除。原生 GET 返回 `no-store` 摘要，不复用会归一化/清理状态的旧查询 helper；未知删除回执不会删除同名替换文件。删除回执写在面板根目录 `.backup_native_delete_requests`，不随可恢复的 `data/` 目录回滚。APP `0.1.54+67` 已提交推送为 `e3b528d`；Actions `45811406407` 暴露紧凑屏幕测试的异步等待超时。修复测试并递增至 `0.1.55+68` 后，提交 `ddac555` 的 Android CI `45813098368` 格式、analyze、Flutter tests、arm64 APK 构建及 develop APK 上传均通过，artifact `15113503595`。

B2 历史已验证基线：FLS `ec318d8` / `20261126.12`（120）与 APP `394993b` / `0.1.56+70` 均已推送各自 `develop`。FLS Module/Desktop/EXE workflows 全绿。APP 首轮 CI `45830634366` 的一项紧凑屏幕测试因横向 Tab 未滚动可见而失败，修正后的 CI `45832261224` 已通过 format/analyze、214 项测试、arm64 APK 构建并上传 artifact `15122689366`，到期于 2026-12-10 13:50:56 UTC。B2 自动化候选通过；手动验收仍待用户。2026-11-27 先 fetch/fast-forward 核对两仓最新 develop，再继续下述 B3。

B2 后端已改为上传完成后启动单个后台检查作业，支持只读查询、协作取消和 1 小时暂存 TTL；TAR/ZIP 通过逐块解包到私有临时目录，验证路径/类型/声明展开量、范围、依赖文件和运行态警告。运行中的重复 request ID 校验归档 SHA-256，不同内容冲突；进程重启后未终结作业只读返回 `unknown`。取消逐块检查期间响应，临时展开目录和失败归档清理；成功快照留存到期。已验证的 B2 基线关闭恢复提交；B3 开发检查点中的 `restore_enabled=True` 仅用于隔离测试，不代表已发布或可部署到稳定面板。

### B3 原生恢复与后续处理（开发测试检查点）

历史检查点 FLS `bfe175b` / `20261127.4`（124）与 APP `4563e2e` / `0.1.59+73` 用于验证 Termux 无法运行的 Windows Job Object 和 Flutter tester。最新检查点见下方；这些检查点均不代表 B3 完成，也不满足 B4 配对交付门槛，不合并 main、不发布正式 Release。后端入口集中在 `native_api.py`，依赖监管在 `dependency_process.py`，持久目录事务在 `backup_commit.py`，跨进程锁在 `backup_lease.py`，短 I/O 门禁在 `data_access.py`，会话锁在 `native_sessions.py`；APP 复用备份页、DTO 和 manager。

2026-11-27 最新任务源同步候选：FLS `b2a0ef700695365d3980bca6bb3ec27dd24c0fcf` / `20261127.29`（149），实现 `05622bd`、`9b34573`，平台修正 `b2a0ef7`；APP `4f4dd2e248a026b00c1e602063cc803f759c4663` / `0.1.64+78`，实现 `c0feec4`。本批先 fetch/fast-forward 两仓 `develop`，均为最新且工作区干净，再继续开发。以下区分本批与历史检查点，文档提交不改变 APK 构建 SHA。

`task_link.py` 的直接同步、原刷新失败项同步、状态/历史、确认与归档全部 Web/API 接入 `directory_job_operation`；`source_json.py` 的 Web/API 读取与保存同时接入门禁。首次回执前取得真实身份，持有至 HTTP response.close、缓存发布、终态回执与 finally；保存/读取/关闭异常及 owner 强退均不留下假活跃。准备中/执行中可被另一 worker 正确查询；确认与归档先独立认领，再释放受理锁，其他 worker 的重复/交叉动作返回 409。缺失活跃回执仍占 200 条容量，原代理、元数据版本和原刷新身份不可重绑。

`source_coordination.py` 提供受理、身份/回执、缓存发布三种跨进程锁；事务顺序为 storage → 缓存 → 回执，发布回调不等受理锁，HTTP 等待不持这些事务。任务源同步只合并在线源 task_cron，不修改 tasks.json 或重载调度器。源编辑在缓存锁内比较 revision 后保存；任务同步重读最新缓存合并并在锁内取发布指纹；普通整源刷新和重试发现抓取期间缓存已变化即拒绝覆盖。原刷新失败项的冗余恢复回执读改写及查询修复统一串行，避免修复旧副本覆盖另一项刚完成的恢复。在线源 HTTP 响应使用 stream=True，每响应最多 4 MiB，错误同样关闭响应。

APP 两类任务操作详情页复用现有 manager：活跃、归档、prepared/running 和查询失败状态禁用恢复动作；动作受理前取消轮询并使旧查询失效。成功或 409/网络异常后只查询原 request ID，不重新发送动作；当前 401 退出嵌套页，过期查询的 401 不触发退出。新增 6 项 Widget 回归，本机 121 文件格式和静态分析通过。首轮 [Android 45940715444](https://github.com/liyw0205/fls-for-android/actions/runs/45940715444) 有 227 项通过/4 项失败：测试在转场结束前点击屏幕外刷新按钮，以及返回历史尚在真实 HTTP 异步中时 pumpAndSettle 超时；`4f4dd2e` 补等待时机，业务断言保留。

后端新增 `test_online_task_link_workers.py` 12 项：全部入口恢复拒绝、双 worker 活跃/冲突、owner 强退、确认认领、缺失活跃回执容量、40 条回执与缓存并发合并、初始保存写前/写后失败、HTTP 读取/大小/关闭异常、刷新期间源编辑、原刷新绑定、编辑 revision 冲突和冗余回执修复竞争。本机八文件 189 项/135 子用例通过（最后新增用例前）；最后三文件 73 项/42 子用例通过。平台修正并新增缓存字节/指纹回归后，最终九文件 195 项/135 子用例全部通过。保留旧 Web/CSRF、确认、刷新/日志和存储恢复回归；并发确认保留唯一写入与完成后 replay 断言，允许活跃期间立即 409。

APP 最终 [Android CI 45941247357](https://github.com/liyw0205/fls-for-android/actions/runs/45941247357) 成功，核对构建 SHA `4f4dd2e248a026b00c1e602063cc803f759c4663`：格式、静态分析、231 项测试及 arm64 release APK 构建通过，正式 Release skipped。[develop APK artifact 15172867318](https://github.com/liyw0205/fls-for-android/actions/runs/45941247357/artifacts/15172867318) 到期于 2026-12-11 04:46:48 UTC；artifact ZIP 为 11,111,140 字节，SHA-256 `8a29f6e647dca6706a229cae0c83ef1f783e53c00e9680aad5ce523ea3dd11c4`，该校验值不是 APK 本体的校验值。后续文档提交不生成新 APK。

后端首轮 `05622bd` 的 Native `45940713789` 被下一提交替代并取消，三项打包成功不作为 Native 通过。第二轮 [Native 45941181855](https://github.com/liyw0205/fls/actions/runs/45941181855) 核对 `9b34573`：Windows 既有步骤全部通过，新增任务源/刷新 step 为 177 项通过、27 个失败记录、123 子用例通过；其中包含子用例失败，不能当作 27 个独立方法。失败来自缓存的 Windows CRLF 转换造成发布指纹不符、旧测试默认 cp1252 解码中文、短/长路径导致故障注入未命中，以及并发确认旧断言固定要求两次 200。Linux 无已报测试失败，运行至 98% 后触及 15 分钟时限并取消，不计通过。该提交 Module `45941181932`、Desktop `45941181860`、EXE `45941181961` 成功，不代替回归。

`b2a0ef7` / `20261127.29` 固定缓存 UTF-8/LF 写入，并新增实际字节与预测指纹一致性回归；测试显式读取 UTF-8、路径比较双方 resolve，并验证活跃期间 409/结束后原请求幂等重放，保留权限、唯一发布和故障恢复断言。Linux 时限调为 25 分钟，全部测试保留。该 SHA 的 [Native 45943611298](https://github.com/liyw0205/fls/actions/runs/45943611298) 首次 Linux 全部 958 项、865 子用例通过，1 项 Windows 专用跳过；Windows 安装 step 为 180 项通过、5 项 sh 用例跳过、134 子用例通过，既有 Node 轮询测试因 5 秒子进程超时失败，后续两步未运行。该用例本机复核 1 项通过；只重跑 Windows 失败作业后，attempt 2 最终成功，未修改或跳过该测试。

最终 Native 核对完整 SHA `b2a0ef700695365d3980bca6bb3ec27dd24c0fcf`，Linux 保留 attempt 1 成功结果，Windows 为 attempt 2；跳过项不计通过：

| 回归范围 | 通过 | 跳过 | 子用例通过 |
| --- | --- | --- | --- |
| Linux 全部相关回归 | 958 | 1 项 Windows 短路径/junction | 865 |
| Windows Job Object | 3 | 1 项 POSIX 专用 | - |
| Windows 独立 lease/回执顺序 | 5 | - | 7 |
| Windows 共享备份/独占恢复 | 9 | - | 7 |
| Windows SQLite/认证 | 16 | - | 3 |
| Windows 脚本作业/监管 | 66 | 1 项 POSIX FD | 182 |
| Windows 目录提交/启动恢复 | 11 | - | 10 |
| Windows 在线安装/任务恢复/原生 API | 181 | 5 项使用 sh 的既有用例 | 134 |
| Windows 独立任务导入/确认/容量 | 66 | - | 76 |
| Windows 任务源同步/刷新/编辑/日志/恢复 | 193 | - | 135 |

Linux 与 Windows 脚本 step 各保留 2 条既有 tar 解包弃用警告。该检查点的自动化通过不等于 B3/B4 完整交付，也不代替真实面板手动验收。

[Module 45943611217](https://github.com/liyw0205/fls/actions/runs/45943611217)、[Desktop 45943611268](https://github.com/liyw0205/fls/actions/runs/45943611268)、[EXE 45943611294](https://github.com/liyw0205/fls/actions/runs/45943611294) 最终全部成功，均核对 `b2a0ef700695365d3980bca6bb3ec27dd24c0fcf`，正式 Release job 均 skipped。EXE 首次获取固定版本的中文资源时遇到 GitHub 匿名 API rate limit，重跑失败作业后 attempt 2 成功；没有手动 dispatch 或发布正式 Release。

该后端检查点的临时产物为 [Module artifact 15173940581](https://github.com/liyw0205/fls/actions/runs/45943611217/artifacts/15173940581)、[Windows Desktop artifact 15173936328](https://github.com/liyw0205/fls/actions/runs/45943611268/artifacts/15173936328) 和 [Windows EXE artifact 15173972470](https://github.com/liyw0205/fls/actions/runs/45943611294/artifacts/15173972470)，均核对同一 SHA；到期时间分别为 2027-02-25 05:04:39 UTC、05:04:39 UTC、05:10:54 UTC。仅用于隔离的 develop 配对验证，不替换稳定面板。

本批手动验收：以对应 develop APK 连接隔离 FLS 候选，分别从导入与外部同步历史进入同一 request ID；有 active 时恢复按钮禁用，409 后查询原状态，离页或刷新后的旧响应不能覆盖新结果。两个 worker 同步不同任务时缓存都保留，使用旧 revision 保存源编辑返回冲突并保留草稿。故障/强退仅在隔离数据中复核，未知结果先核对原请求，不以重新安装或新 ID 代替。记录 APP/FLS SHA、面板模式、步骤、实际/预期和脱敏错误；不做 ADB，用户手动反馈不阻塞下一域开发。

下一批优先整源刷新作业的受理/线程/日志与跨 worker 生命周期；共享缓存锁和失败项恢复回执锁不代表整个刷新域完成。随后继续调试、任务/日志、启动器、Windows 实例锁/WAL/断电、多 worker 依赖清理、损坏回执维护、APP 全流程及 B4，再推进 M4-M7。总 Goal 保持 active，不合并 main、不发布正式 Release。

上一独立在线任务导入检查点：FLS `55a007dbb64cfa6361ac01b3512fef64bcda270e` / `20261127.26`（146），实现为 `9f7e4df3154e327e20244486726c80f1be2097d9` / `20261127.25`（145）。该历史批次 APP 代码为 `79bbfab` / `0.1.62+76`，只更新方案，未新增版本或 APK。

`install_select.py` 的独立导入、状态/历史、确认、调度器恢复和归档 Web/API，以及 Web 安装选择和原生 `catalog_api.py` 的安装选项入口，从路由进入到清理完成持恢复共享 lease。旧/原生恢复、prepared/损坏现场及独占短 I/O 均先拒绝，不读脚本/代理或首次写导入回执。`task_import_coordination.py` 提供跨进程受理锁、回执身份事务和在线任务发布锁；回执使用 storage → 身份锁顺序，发布回调不反向等待受理锁。

首次回执前 claim 存活身份，成功或异常后由当前执行线程释放；prepared/running 的恢复按真实存活锁判断，不依赖 `ONLINE_TASK_IMPORT_ACTIVE`。其他 worker 查询活跃原请求不会误写未知；同 ID 与冲突选择均不重复导入。确认、重载和归档短时认领原身份，执行时释放受理锁，其他 worker 的同类/交叉恢复返回 `409 / active: true`；结束后原请求可重放。回执暂缺的活跃身份仍占历史容量，拒绝重认领；不同回执的读改写不丢更新。

任务发布在跨 worker 锁内合并两个在线导入，普通任务域全部写操作的跨 worker 协调仍属于后续范围。真实 worker 强退测试发现任务文件原本不存在时，空来源指纹使“确认未写入”被拒绝；现在只在有效发布/已捕获基线明确证明文件缺失时接受该确认，published 仍须发布证据。新增 `retry_source_captured` 区分“已绑定空来源”和“未绑定”，兼容旧非空回执；任务文件即使在重试 claim 后才创建，也拒绝发布并保留未知结果待核对。

新增 `test_online_task_import_workers.py` 10 项覆盖恢复门禁、prepared/running/发布中跨 worker 查询和拒绝、硬退出、恢复认领、缺失活跃回执容量、首次保存前身份及写前/写后失败释放、40 条历史并发合并、双导入合并/无关配置可写，以及缺失文件的确认和重试竞态。保留既有 import/replay/confirmation/retention 与 Web/CSRF 回归；并发确认现在验证第二个立即 409、首个完成后再请求为 replay，唯一发布断言不变。

本机全部 online/UI/release-note 扩展回归为 533 项、396 子用例通过，1 项 Windows 专用跳过，1 项旧 API 重试 mock 固定返回次数失败；改为按请求 ID 读取 parent/child 后保留原业务断言，并把该文件加入双平台工作流。最终八文件 168 项、132 子用例全部通过，线程异常按错误；`git diff --check` 和修改模块编译通过。

首轮实现 `9f7e4df` 的 [Native 45935061494](https://github.com/liyw0205/fls/actions/runs/45935061494) 失败：Linux 765 项、730 子用例通过，1 项 Windows 专用跳过；Windows 全部既有步骤通过，在线安装 step 181 项通过/5 项 sh 专用跳过/134 子用例通过，新增独立任务 step 65 项/76 子用例通过，1 项失败。该项在 200 条容量、原恢复重放、仅重载一次和零导入断言均通过后，默认 cp1252 读取含中文完成消息的回执时解码失败。[Module 45935061395](https://github.com/liyw0205/fls/actions/runs/45935061395)、[Desktop 45935061497](https://github.com/liyw0205/fls/actions/runs/45935061497)、[EXE 45935061472](https://github.com/liyw0205/fls/actions/runs/45935061472) 成功且正式 Release 均 skipped；它们不代替 Native。

修正 `55a007d` / `20261127.26` 为确认/容量旧测试的全部相关 JSON 读取显式指定 UTF-8，保留原断言。本机三文件 28 项、30 子用例通过；修改只影响测试与版本说明。

最终 [Native 45936531039](https://github.com/liyw0205/fls/actions/runs/45936531039) 成功，Linux/Windows 均核对 SHA `55a007dbb64cfa6361ac01b3512fef64bcda270e`：

| 回归范围 | 通过 | 跳过 | 子用例通过 |
| --- | --- | --- | --- |
| Linux 全部相关回归 | 765 | 1 项 Windows 短路径/junction | 730 |
| Windows Job Object | 3 | 1 项 POSIX 专用 | - |
| Windows 独立 lease/回执顺序 | 5 | - | 7 |
| Windows 共享备份/独占恢复 | 9 | - | 7 |
| Windows SQLite/认证 | 16 | - | 3 |
| Windows 脚本作业/监管 | 66 | 1 项 POSIX FD | 182 |
| Windows 目录提交/启动恢复 | 11 | - | 10 |
| Windows 在线安装/任务恢复/原生 API | 181 | 5 项使用 sh 的既有用例 | 134 |
| Windows 独立任务导入/确认/容量 | 66 | - | 76 |

Linux 与 Windows 脚本 step 各保留 2 条既有 tar 解包弃用警告；跳过项不计通过。[Module 45936531088](https://github.com/liyw0205/fls/actions/runs/45936531088)、[Desktop 45936531029](https://github.com/liyw0205/fls/actions/runs/45936531029)、[EXE 45936531087](https://github.com/liyw0205/fls/actions/runs/45936531087) 全部成功且核对同一 SHA，三个正式 Release job 均 skipped。开发检查点验证通过不代表 B3/B4 或全量 Goal 完成。

本批 APP manager 以 Map 保留新增字段，已有页面在 active 或 running 时轮询，无不兼容 DTO 变更。确认/重载按钮尚未按 active 禁用，并发操作由后端 409 拒绝；按钮状态优化后续补齐。实际 APK 仍是 `79bbfab` / `0.1.62+76`，CI `45883212390`、[artifact 15148047738](https://github.com/liyw0205/fls-for-android/actions/runs/45883212390/artifacts/15148047738)（2026-12-10 19:29:52 UTC 到期）。不做 ADB/模拟器，隔离面板手动验收待用户。

本批手动验收使用上述 APK 与隔离 FLS 候选：从在线脚本选择任务并导入，记录原 request ID，离页后由任务操作历史回到同一结果；重复查询或提交不能新增相同任务。使用两个面板 worker 时核对活跃状态与恢复冲突，恢复结束后刷新原请求；仅在隔离测试数据中复核 owner 中断、原任务文件缺失和调度器恢复，不能以重新安装或新请求替代原请求核对。记录 APP/FLS SHA、面板模式、步骤、实际/预期和脱敏错误；用户反馈不阻塞下一域开发。

下一入口批次为外部任务源同步 `task_link.py`，再接源刷新/编辑/日志 `refresh.py/source.py`；随后继续调试、任务/日志、启动器、Windows 实例锁/WAL/断电、多 worker 依赖清理、孤立身份/损坏回执维护及 APP 全流程。B3/B4、M4-M7 和总 Goal 未完成，不合并 main、不发布正式 Release。

上一在线安装跨 worker 检查点：FLS `9d4359c9c3c6c1776e9a619b2e2ed9c3b711b4a5` / `20261127.24`（144），实现提交为 `a9c1cc17f16004bae157678412690964e03641e0` / `20261127.23`（143）。以下保留历史实现和平台证据，不代替上方最新提交的验证。

`install_coordination.py` 复用 `DirectoryJobLock` 建立跨 worker 受理锁和独立短时回执事务锁。受理/同请求/同脚本检查、首次发布、停止和恢复认领由前者协调；所有安装 JSON 读改写在 storage → 回执锁顺序中回读最新记录，任务发布在已有任务/storage 锁内可写证据而不反向等待受理锁。网络等待、命令运行和调度器重载不长期持有安装历史事务。

首次回执前 claim 独立安装身份，保持到线程日志/finally 清理后；`DirectoryProcess` 也持同一 `job_lease_path`，owner 强退后只有整树退出才可判未知。历史 `[A-Za-z0-9_-]{1,80}` ID 通过带域 SHA-256 摘要映射到 32 hex 锁名，外部安装 ID 和日志身份不变。模拟重启测试同时释放真实身份，不再以仅清空内存冒充 owner 已退出。

查询保留本地 owner 的同一字典、process/stop_lock 和未落盘进度，并合入持久停止及重试关联；无 owner 的旧缓存按最新回执刷新，不以 `running` 字段代替存活锁。另一 worker 已恢复的终态优先于旧缓存的写入失败诊断。任意 worker 先保存停止请求/attempt，执行者在下载分块和命令轮询消费；停止失败可再请求，保存失败不发信号，旧进度不能撤销停止。停止日志失败的诊断也先读取新回执，避免覆盖已结束的安装。任务补导入、确认、调度器恢复和父子重试持独立认领，其他 worker 的同类/交叉恢复返回 409。

新增 `test_online_install_workers.py` 12 项真实双 worker/本地身份回归，覆盖活跃查询、同 ID 竞争和选项冲突、不同安装进度合并、远端停止及失败再试、真实命令树、owner 强退、历史 ID、父子重试、任务/确认/调度器认领、旧终态缓存、停止写入失败和终态后的日志诊断。原门禁用例另验证首次发布前/线程交接/失败释放的身份锁；既有停止、恢复、容量和 Web 回归保留。

本机扩展十文件 203 项通过、1 项 Windows 专用跳过、154 个子用例通过（最终缓存/日志诊断调整前）；缓存调整后的三文件 115 项、43 个子用例通过，最终新 worker/发布说明 14 项及停止日志/保存定向 3 项、4 个子用例通过。线程异常按错误，`git diff --check` 通过。Linux/Windows 工作流已加入新 worker 文件，保留全部既有回归。

首轮 `a9c1cc1` 的 [Native 45928421127](https://github.com/liyw0205/fls/actions/runs/45928421127) 失败：Linux 为 3 项失败、688 项通过、1 项 Windows 专用跳过、654 子用例通过；Windows 所有 step 成功，在线安装 step 为 173 项通过、5 项 sh 专用跳过、134 子用例通过。Linux 三项失败均是旧 `test_ui_route_components.py` 只设置内存运行标记，未持真实身份，因而被新实现正确归为未知；涉及重复安装拒绝、日志轮询字段和停止 API。Module `45928421108`、Desktop `45928421300`、EXE `45928421251` 成功且正式 Release 跳过，不据此把 Native 记为通过。

`9d4359c` 补齐三项测试的真实存活锁和持久回执，保留原有 302 拒绝提示、JSON 精确字段及停止成功等断言，不放宽业务身份核验。在线安装旧用例先通过 11 项；最终完整 UI、新 worker 与发布说明共 106 项、56 子用例通过，线程异常按错误。

最终 [Native backup regression 45930767097](https://github.com/liyw0205/fls/actions/runs/45930767097) 成功；Linux/Windows 均核对完整 SHA `9d4359c9c3c6c1776e9a619b2e2ed9c3b711b4a5`：

| 回归范围 | 通过 | 跳过 | 子用例通过 |
| --- | --- | --- | --- |
| Linux 全部相关回归 | 691 | 1 项 Windows 短路径/junction | 654 |
| Windows Job Object | 3 | 1 项 POSIX 专用 | - |
| Windows 独立 lease/回执顺序 | 5 | - | 7 |
| Windows 共享备份/独占恢复 | 9 | - | 7 |
| Windows SQLite/认证 | 16 | - | 3 |
| Windows 脚本作业/监管 | 66 | 1 项 POSIX FD | 182 |
| Windows 目录提交/启动恢复 | 11 | - | 10 |
| Windows 在线安装/任务恢复 | 173 | 5 项使用 sh 的既有用例 | 134 |

Linux 与 Windows 脚本 step 各保留 2 条既有 tar 解包弃用警告；跳过项不计通过。[Module 45930767144](https://github.com/liyw0205/fls/actions/runs/45930767144)、[Desktop 45930767231](https://github.com/liyw0205/fls/actions/runs/45930767231)、[EXE 45930767070](https://github.com/liyw0205/fls/actions/runs/45930767070) 全部成功且核对同一 SHA，三个正式 Release job 均 skipped。本批未生成 APP APK，实际 APP 构建仍为下方 `79bbfab`。

本批完成在线安装的跨 worker 候选实现，独立在线任务入口/安装选择、调试、任务/日志、启动器、Windows 实例锁/WAL/断电、多 worker 依赖清理、孤立身份/损坏回执维护和 APP 全流程仍待推进；不证明全域 GET 只读、监管自身被杀或命令逃离进程组。B3/B4、M4-M7 和总 Goal 未完成，手动验收待用户。

上一在线安装 lease/监管检查点：FLS `8156301` / `20261127.22`（142），实现提交为 `b8c8b60` / `20261127.20`（140）。以下保留实现、两轮 Windows 失败修复及最终 CI 证据。

`routes/online_scripts/install.py` 的安装、启动恢复、重试、停止、任务确认/补导入及调度器恢复，以及 `logs.py` 的安装日志/历史 API 与 Web 入口，从路由进入即持恢复共享锁。恢复占用、待处理目录现场或短 I/O 竞争先返回 503，不进行安装查询、首次回执、文件或命令副作用。`start_install_thread` 复用 `start_directory_job`，在 Thread 构造/start 之前预留独立 lease，覆盖 HTTP 等待/response.close、下载产物、任务导入、终态日志和 finally；网络等待不持配置事务锁。

`run_logged_command` 从直接 Popen 改为既有 `DirectoryProcess` 独立监管，覆盖在线 Git clone/pull 和安装命令；监管状态位于系统临时目录。POSIX 显式停止和 owner 断开先 TERM、1 秒后升级 KILL，Windows 由 Job Object 清理；整棵命令树退出前监管不释放恢复共享锁，停止调用不持生命周期锁等待。正常/非零/停止/超时保留实际退出码，停止失败仍保留活跃进程及回执；监管启动门或结果无法核实时显示 `结果未知 / unknown`，GET 查询不重新执行命令。

新增 `test_online_install_directory_jobs.py` 8 项、18 个子用例，覆盖 18 类路由在真实 Web/原生跨进程恢复、损坏 journal 与短 I/O 竞争下的零副作用拒绝，首次保存/线程交接与失败释放，六个 HTTP/发布/任务/终写阶段，真实正常/非零/shell 命令、整树停止/超时、owner 强制退出，以及结果回执不可读只查询且不重复执行。既有停止失败测试改在监管边界注入，保留活跃、禁止重复启动和恢复断言。

本机扩大回归十文件 200 项、166 个子用例通过（加入最终 unknown 用例前）；实现提交最终四文件（新门禁、生命周期、原请求恢复、发布说明）114 项、61 个子用例通过，线程异常按错误。独立新门禁 7 项、18 个子用例通过的记录在 unknown 用例之前；不将早期测试数冒作最终全量结果。Linux/Windows workflow 已加入新文件及五个在线安装/任务校验回归。

首轮 `b8c8b60` 的 [Native 45916127275](https://github.com/liyw0205/fls/actions/runs/45916127275) 失败：Linux 675 项、644 个子用例通过；Windows 既有全部 step 成功，新增在线安装 step 为 49 项失败、140 项通过、5 项跳过、99 个子用例通过。主要根因为 `_install_log_file` 以解析前后路径字符串不等判断重定向，Windows 临时目录的 8.3 短路径被误拒绝，连带阻断安装状态/任务恢复；另有新测试按系统默认编码读取 UTF-8 日志，以及 Node 管道解码警告。Module `45916127288`、Desktop `45916127243`、EXE `45916127284` 成功且正式 Release 跳过，不能代替 Native 通过。

修复 `bbde77e` / `20261127.21`（141）先检查父目录符号链接/junction、`..` 和文件链接，再核对实际日志目录与安装身份，允许合法短路径。新增普通链接/穿越和 Windows 短路径/junction 两项回归；测试日志和 Node 管道显式用 UTF-8。修复后本机六文件 164 项通过、1 项 Windows 专用跳过、134 个子用例通过；最终新门禁/发布说明 11 项通过、1 项 Windows 专用跳过、20 个子用例通过，线程异常按错误。

第二轮 `bbde77e` 的 [Native 45918589168](https://github.com/liyw0205/fls/actions/runs/45918589168) 仍失败：Linux 676 项通过、1 项 Windows 专用跳过、646 个子用例通过；Windows 所有既有 step 成功，新增在线 step 为 30 项失败、150 项通过、5 项跳过、112 个子用例通过。日志短路径/junction 和命令进程树已通过，剩余失败统一指向 `verify_install_outputs` 仍用未解析的字符串比较产物归属，将合法 8.3 短路径误报为 scripts 越界。Module `45918589161`、Desktop `45918589338`、EXE `45918589174` 成功且正式 Release 跳过，不能代替 Native。

最终修复 `8156301` / `20261127.22`（142）按解析后的父目录校验归属，叶链接仍指纹其自身，不跟随读取目录外内容；新增同名前缀邻目录、父链接逃逸和 Windows 短路径产物回归。该路径修复后的四文件先通过 147 项、1 项 Windows 专用跳过、97 个子用例。随后定向补跑暴露停止竞态：命令线程清理临时 workspace 后，停止请求再次读取结果文件，偶发 500。`DirectoryProcess` 现在在互斥区仅缓存首次验证成功的退出码，结果仍未验证时的缺失/损坏不变成成功；真实并发等待、移除结果后的正常/非零退出及坏回执均有新增回归。

最终本机六文件（监管、新门禁、生命周期、原请求恢复、调度器恢复、发布说明）165 项通过、1 项 Windows 专用跳过、103 个子用例通过，线程异常按错误，`git diff --check` 通过。第三轮 Linux/Windows workflow 沿用原范围并包含上述新增用例。

最终 [Native backup regression 45921202342](https://github.com/liyw0205/fls/actions/runs/45921202342) 成功，Linux/Windows 两个 job 均核对为 `8156301`：

| 回归范围 | 通过 | 跳过 | 子用例通过 |
| --- | --- | --- | --- |
| Linux 全部相关回归 | 679 | 1 项 Windows 短路径/junction | 654 |
| Windows Job Object | 3 | 1 项 POSIX 专用 | - |
| Windows 独立 lease/回执顺序 | 5 | - | 7 |
| Windows 共享备份/独占恢复 | 9 | - | 7 |
| Windows SQLite/认证 | 16 | - | 3 |
| Windows 脚本作业/监管 | 66 | 1 项 POSIX FD | 182 |
| Windows 目录提交/启动恢复 | 11 | - | 10 |
| Windows 在线安装/任务恢复 | 161 | 5 项使用 sh 的既有用例 | 134 |

Linux 和 Windows 脚本 step 各保留 2 条既有 tar 解包弃用警告；跳过项不计通过。[Module 45921202265](https://github.com/liyw0205/fls/actions/runs/45921202265)、[Desktop 45921202353](https://github.com/liyw0205/fls/actions/runs/45921202353)、[EXE 45921202314](https://github.com/liyw0205/fls/actions/runs/45921202314) 全部成功，四项 workflow 均核对完整 SHA，三个正式 Release job 均 skipped。

APP 实际代码/APK 仍为 `79bbfab` / `0.1.62+76`，Android CI `45883212390` 已通过 225 项测试和 arm64 APK，[artifact 15148047738](https://github.com/liyw0205/fls-for-android/actions/runs/45883212390/artifacts/15148047738) 到期于 2026-12-10 19:29:52 UTC。本批 APP 仅方案提交，不制造新 APK；不做 ADB/模拟器，用户手动验收待执行。上述证据只关闭本批在线安装恢复 lease/命令监管及路径/退出竞态验证，不关闭 B3/B4 或总 Goal。

该历史批次尚未实现的在线安装跨 worker 存活身份、回执事务、同请求去重与取消由上方 `a9c1cc1` 接续；不能仅据旧批整树恢复锁证明多 worker 安装契约完整。安装选择/独立任务导入入口、调试、任务/日志、启动器、Windows 实例锁/WAL/断电、多 worker 依赖清理、孤立身份/坏回执维护及 APP 全流程继续推进。监管自身被杀、逃离进程组不在本批证据范围内，B3/B4 和总 Goal 均未完成。

上一脚本文件检查点：FLS `70ad27fcfb307bbc225f3a435d307822f4b9f69a` / `20261127.19`（139），在实现提交 `5626ac9` 及换行修正 `da8a4b4` 上追加跨 worker 身份退役互斥，以下保留其实现和实际失败修复证据。

原生 `native_files.py` 的目录/文件读写、新建、删除、预览、重命名与恢复查询，以及 Web 脚本页、新建/编辑/删除/重命名/恢复、远程拉取和上传导入，均从进入路由到返回/异常清理持有 `directory_job()` 的共享恢复锁。恢复占用、待处理目录现场和短 I/O 冲突在读写前返回 `503 / panel_storage_busy`；沿用 I/O 在模型锁之前的受理顺序，网络/复制等待不持配置事务锁。补齐 Web 和原生重命名中被宽泛 except 吞掉的 busy；重载遇忙时保留 `tasks_saved` 原操作，可按同一 ID 查询和继续恢复。

Web 下载在受理时打开原文件，文件句柄与共享锁交给流式响应，读取结束/失败、提前关闭及尚未启动 generator 就关闭均释放，重复关闭无害。Web Git 从 `subprocess.check_call` 改用既有 `DirectoryProcess`；命令通过启动门后运行，面板 owner 强制退出时清理进程树，监管保留恢复锁至整树退出。正常/非零退出、启动失败继续旧 Web 页面语义；本批不新增 DTO 或改变原生 APP 请求。

新增 `test_script_directory_access.py` 6 项，覆盖 29 种请求在两种真实跨进程恢复、损坏 journal 和短 I/O 竞争下先拒绝后零业务文件变化，执行中的读/编辑/Web 拉取/导入阻止恢复但允许配置保存，busy 映射、重命名原 ID 恢复，以及下载完成/未开始/断连/开读异常。另增真实 Web owner 崩溃监管 1 项、本地 Git 克隆与非零退出 2 项，并更新旧克隆测试使其真实执行监管。

本机先执行五文件：57 项、173 个子用例通过；随后扩展八文件：167 项通过、272 个子用例通过，1 项旧在线日志断言遗漏基线已有 `download_progress` 字段而失败。补齐该字段精确期望后单项通过，最终三文件（新门禁、文件恢复、Web 组件）117 项、236 个子用例通过，线程异常按错误。发布说明 2 项及 `git diff --check` 通过。Linux 工作流加入完整文件恢复和 Web 组件回归，Windows 加入新门禁与旧导入回归。

第一轮 `5626ac9` 的 Native `45909324800` 失败：Linux 509 项/512 子用例通过；Windows 脚本 step 为 60 项通过、1 项跳过、176 子用例通过，仅真实 Git 克隆 README 的 `read_bytes()` 因 CRLF 失败，目录恢复 step 随之跳过。Module `45909324871`、Desktop `45909324856`、EXE `45909324816` 成功，正式 Release 跳过。`da8a4b4` / `20261127.18`（138）改用 UTF-8 文本断言，本机导入与发布说明 12 项/2 子用例通过。

第二轮 `da8a4b4` 的 Native `45910246493` 仍失败：Linux 509 项/512 子用例通过；Windows 脚本 step 为 60 项通过、1 项跳过、176 子用例通过。真实克隆已通过，新失败为上传接收交接后另一 worker 查询时 `backup_lease.py:os.open` 打开身份锁返回 PermissionError，接口 500；目录恢复 step 因此前失败跳过。Module `45910246551`、Desktop `45910246593`、EXE `45910246547` 成功且正式 Release 跳过，不能据打包成功将 Native 记为通过。

`70ad27f` / `20261127.19`（139）修正 owner 退役在本进程 mutex 下删除身份锁、未与其他 worker 的历史/探测事务互斥的问题：退役取得同一历史锁，完成失效标记、释放及探测删除；不读取回执，坏历史不阻止释放。门禁暂不可用时仅失效标记并释放 owner，不竞争删除，留待后续互斥探测清理。已有监管继续持身份锁至整树退出，迟到监管因失效标记不能启动命令。新增真实双进程阻塞/释放、损坏历史及 busy 退役 3 项；busy 后仅有孤立身份文件且无回执/暂存的维护回收仍属后续整理边界。

本机修复过程五文件 49 项/172 子用例通过（加入最终 busy 退役前）；最终三文件（跨 worker、进程监管、作业门禁）34 项/34 子用例及发布说明 2 项通过，线程异常按错误，`git diff --check` 通过。

最终平台终态：FLS `70ad27fcfb307bbc225f3a435d307822f4b9f69a` 的 [Native backup regression 45912573032](https://github.com/liyw0205/fls/actions/runs/45912573032) 成功。Linux 512 项、512 个子用例通过；Windows 脚本/监管 step 64 项通过、1 项 POSIX FD 用例跳过、176 个子用例通过。Windows 其余 step 分别为 Job Object 3 项通过/1 项 POSIX 用例跳过、独立 lease 5 项/7 子用例、共享备份/恢复 9 项/7 子用例、SQLite/认证 16 项/3 子用例、目录恢复 11 项/10 子用例；均成功。两平台原有 tar 解包弃用警告保留，跳过项不计作通过。

[Module 45912573010](https://github.com/liyw0205/fls/actions/runs/45912573010)、[Desktop 45912572949](https://github.com/liyw0205/fls/actions/runs/45912572949)、[EXE 45912573077](https://github.com/liyw0205/fls/actions/runs/45912573077) 全部成功，四个 workflow 均已核对上述 SHA，三个正式 Release job 均 skipped。本轮未生成 APP APK；此证据关闭本批文件/Web 传输和身份退役的自动化验证，B3/B4 仍按下列剩余范围推进。

本批完成同步文件入口和 Web 传输的恢复互斥；在线安装/调试、任务/日志、启动器、Windows 实例锁/WAL/断电、多 worker 依赖清理、损坏回执维护及 APP 全流程仍未完成。Web owner 崩溃可能留下不再被子进程写入的 staging，本批不证明已有跨 worker 回收或维护入口；目录恢复要求显式无活跃子进程后才取得独占权限。保留现有 Web 目录页/历史整理副作用，不作为全域 GET 只读证据。

上一 HEAD 监管检查点：FLS `bf8cb70fee621ea36fe5764108556d47ce4f5c06` / `20261127.16`（136），以下保留其实现及平台证据。

短 `_repo_head` 也改由 `DirectoryProcess` 独立监管，保留固定目录 FD 和共享恢复锁；监管和命令隔离面板 stdin，stdout 写入临时文件，命令整树退出后最多读取 256 字节并校验 HEAD。监管自身的工作目录及状态/输出文件位于系统临时目录，HEAD 命令仍在固定仓库目录执行，不改仓库或作业 DTO。启动/查询失败或超时返回无法确认；监管清理进程组/Windows Job Object 后才释放恢复锁。克隆的进度 stderr 仍走原有 reader，输出重定向的新参数沿用既有默认行为。

新增 3 项真实进程测试：命令成功但子进程继承 stdout、查询超时，以及 HEAD 查询期间面板 owner 强制退出；均断言命令/子进程退出后恢复锁才可取得。本机八文件 65 项、38 个子用例通过，线程异常作为错误；`git diff --check` 通过。

本提交四项工作流均已核对 SHA 与成功终态：

- [Native backup regression 45906763722](https://github.com/liyw0205/fls/actions/runs/45906763722)：Linux 29 文件 371 项、274 个子用例通过；Windows 脚本/监管 step 44 项通过、1 项 POSIX FD 用例跳过、38 个子用例通过，此前失败的两个 Git 双 worker 用例通过。Windows 既有依赖监管 3 项通过/1 项 POSIX 跳过，lease/归档/顺序 5 项、7 个子用例，共享备份/恢复 9 项、7 个子用例，I/O/认证 16 项、3 个子用例，目录恢复 11 项、10 个子用例均通过。
- [Module 45906763794](https://github.com/liyw0205/fls/actions/runs/45906763794)、[Desktop 45906763844](https://github.com/liyw0205/fls/actions/runs/45906763844)、[EXE 45906763773](https://github.com/liyw0205/fls/actions/runs/45906763773) 均成功，三个正式 Release job 均 skipped。
- APP 实际 APK 仍为 `79bbfab` / `0.1.62+76`，Android CI `45883212390`、[artifact 15148047738](https://github.com/liyw0205/fls-for-android/actions/runs/45883212390/artifacts/15148047738)（2026-12-10 19:29:52 UTC 到期）。本批 APP 只有方案提交，不制造新 APK；不做 ADB/模拟器，用户手动验收待执行。

前序跨 worker 实现为 `5b190299ef415a3b22af542d611c409f21bc02a5` / `20261127.13`（133），以下保留实现和三次实际失败诊断。

`directory_jobs.py` 增加三域独立的跨进程历史事务锁，每次使用内存记录前刷新磁盘快照，受理、重复请求、并发上限、取消及进度/终态保存共用事务。当前 owner 未落盘的进度保留在本进程，其他 worker 的取消状态会合入并触发本地事件；普通进度更新不能将 cancelling 改回执行中。历史锁有 5 秒等待上限，网络/解包等待不持有历史或配置事务锁，实际 JSON 写入仍经过短 I/O 门禁。

每个作业从首次保存前持有 `BASE_DIR/.script_job_locks/<domain>-<id>.lock` 的共享存活锁，持续到执行线程清理结束；Git 独立监管也持同一身份。只有独占探测确认无人持有，才允许将活动记录整理为 unknown 或清理其暂存；失效字节在清理前写入，迟到监管不能再启动命令。上传从打开 `.upload` 前就持身份，并将同一所有权交给 worker；未登记上传也必须确认接收者已退出才回收。身份/保存/线程构造/start 失败均释放资源，上传受理异常由 ExitStack 统一兜底。

新增 `test_script_job_workers.py` 6 项、12 个三域子用例：真实双面板进程预热缓存后查询/取消/重放、并发同 request ID 只启动一次、不同 owner 先后完成不丢回执、原 owner 被杀后保留另一作业暂存、接收中尚无回执的上传保护，以及失活上传回收。Git 使用真实本地临时仓库。另新增 2 项监管身份交接/迟到启动拒绝，并将身份保存失败加入三域异常回归；fixture 等待脚本线程收尾后才卸载模块和临时目录，不隐藏线程异常。

本机扩展 12 文件 91 项、58 个子用例通过（最终接收保护改动前）；最终六文件定向 56 项、38 个子用例通过，线程异常按错误处理；发布说明 2 项及 `git diff --check` 通过。

实现提交 `5b19029` 的 [Native backup regression 45904014337](https://github.com/liyw0205/fls/actions/runs/45904014337) 未通过：Linux 29 文件 368 项、274 个子用例通过；Windows 脚本 step 41 项通过、1 项 POSIX FD 用例跳过、36 个子用例通过，两个 Git 双 worker 用例等待 complete 超时，状态仍为 cloning，后续目录恢复 step 跳过。其他 Windows 监管/lease/I/O 定向回归通过。该提交 [Module 45904014335](https://github.com/liyw0205/fls/actions/runs/45904014335)、[Desktop 45904014474](https://github.com/liyw0205/fls/actions/runs/45904014474)、[EXE 45904014424](https://github.com/liyw0205/fls/actions/runs/45904014424) 成功，打包不代替失败回归。

诊断提交 `3570f74` / `20261127.14`（134）为测试 Git 命令加有界等待，保留命令释放/退出、监管结果及线程栈；本机双 worker 测试和发布说明共 8 项、12 个子用例通过。其 Native `45904784785` 未通过：Linux 368 项、274 个子用例通过，Windows 两个 Git 用例仍失败，另发现临时文件 RPC 回包的共享偏移问题；Module `45904784806`、Desktop `45904784716`、EXE `45904784729` 成功。

`08a1f93` / `20261127.15`（135）将测试 RPC 改成独立 stdout 管道和 reader 队列，修复共享临时文件偏移；本机 8 项、12 个子用例通过。Native `45905454154` 的 Linux 368 项、274 个子用例通过，Windows 两个 Git 用例仍失败，脚本 step 41 项通过、1 项跳过、36 个子用例通过，后续目录恢复 step 跳过。Module `45905454134`、Desktop `45905454039`、EXE `45905454061` 成功，正式 Release 均跳过。诊断已确认真实 Git 克隆及监管结果均为 0，阻塞位于随后 `_repo_head` 的 `subprocess.run`/Windows stdout reader，不能将测试 IPC 修正当成产品故障已经解决。

本批补齐上述三类原生脚本作业的跨 worker 活跃识别、回执协调、取消及接收交接，并接入短 Git HEAD 监管；其余文件/在线安装/调试、任务/日志、启动器、Windows 实例锁/WAL/断电、依赖清理句柄协调、损坏回执维护和 APP 全流程仍待收尾。脚本历史保留失活暂存整理语义，不作为全域 GET 只读的完成证据。B3/B4 尚未交付，总 Goal 继续 M4-M7。

上一 Git 克隆监管检查点：FLS `efc6a4d79ba050dbfcca2da656e19fda5e056b55` / `20261127.12`（132）。以下保留该批实现与平台证据。

新增 `fls_manager/directory_process.py` 独立监管 Git 克隆，POSIX 进程组和 Windows Job Object 能力共用 `fls_manager/process_tree.py`，既有依赖监管保持原生命周期。命令经 stdin 传入，不把 URL/命令写入现场；监管自行持共享恢复锁，面板 owner 被强制结束后通过控制管道 EOF 开始清理。只有命令及子进程全部退出、结果写入且继承目录 FD 关闭后才释放锁。Windows 先将启动门 wrapper 加入 Job Object，再发送命令；正常结束、主动停止及 spawn 失败也清理资源。停止等待超时不提前解锁，监管继续清理。

新增 `tests/test_directory_process.py` 8 项，覆盖启动门、未启动即停止、重复启停、命令父进程先退出、spawn 失败、清理超时仍持锁、POSIX pinned FD 继承、真实本地 Git 克隆，以及真实 Flask owner 受理克隆后被强制结束。最后一项在恢复取得独占锁时确认命令/孙进程已退出。本机扩展 11 文件 118 项、54 个子用例通过（加入真实克隆用例前）；最终监管文件 8 项及发布说明 2 项通过。Git 来源是本地临时仓库，不访问外网，不运行 pip。

该历史检查点工作流严格对应 `efc6a4d79ba050dbfcca2da656e19fda5e056b55`，均已核对终态：

- [Native backup regression 45901442241](https://github.com/liyw0205/fls/actions/runs/45901442241) 成功：Linux 28 文件 360 项、259 个子用例通过；Windows 脚本/监管 step 33 项通过、1 项仅 POSIX FD 用例跳过、23 个子用例通过，既有依赖监管 3 项通过/1 项 POSIX 跳过，lease/归档/顺序 5 项、7 个子用例，共享备份/恢复 9 项、7 个子用例，I/O/认证 16 项、3 个子用例，目录恢复 11 项、10 个子用例全部通过。
- [Module 45901442314](https://github.com/liyw0205/fls/actions/runs/45901442314)、[Desktop 45901442192](https://github.com/liyw0205/fls/actions/runs/45901442192)、[EXE 45901442205](https://github.com/liyw0205/fls/actions/runs/45901442205) 全部成功，三个正式 Release job 均为 skipped。
- APP 实际 APK 仍对应 `79bbfab` / `0.1.62+76`、CI `45883212390`、[artifact 15148047738](https://github.com/liyw0205/fls-for-android/actions/runs/45883212390/artifacts/15148047738)（2026-12-10 19:29:52 UTC 到期）。后续文档提交不代表新 APK；无 ADB/模拟器，手动验收待用户。

该历史批次只覆盖长 Git 克隆的 owner 崩溃清理；跨 worker 活跃回执/stage 识别由上方 `5b19029` 接续，短 `_repo_head` 的 `subprocess.run` 则由 `bf8cb70` 改为监管。监管自身被强制结束、子进程逃离进程组、Windows 断电、多 worker 依赖清理与损坏回执维护不在该批完成证据内。B3/B4 尚未交付，全量 Goal 继续推进。

上一脚本作业检查点：FLS `12185fd90a620ba6f67f183171f8330f63a4b514` / `20261127.11`（131），原实现为 `de51d4c` / `20261127.10`（130）。以下保留其实现与失败修复证据，不代替最新检查点验证。

`directory_jobs.py` 为原生单文件下载、Git 拉取、上传导入及其查询/取消/历史整理提供共享作业锁。请求在读取历史和暂存上传前拿 `.backup_native_restore.lock`，并在短 I/O 门禁下确认目录可写；恢复占用、prepared/损坏现场或短 I/O 竞争统一返回 `503 / panel_storage_busy`。线程在构造/start 前另拿共享句柄，请求与 worker 的所有权重叠，避免受理到启动空窗；请求及 worker 各自显式 finally 释放，不依赖 GC。保存、线程构造/start 失败清理上传、父目录句柄和租约，二次回执保存失败返回 unknown。网络等待不持有 storage/config 锁。

Git worker 异常先终止/等待进程，等待 stderr reader 完成，再清 stage、关闭目录句柄；Git/导入在清理后发布终态。单文件作业的 lease 也保留至 response.close 完成。新增 `test_script_directory_jobs.py` 9 项覆盖旧 Web/原生独占恢复对全部相关路由的拒绝、损坏现场/独立进程 I/O 竞争、排队交接、三域保存/构造/start/二次回执失败及 FD 关闭、worker 抛错、响应关闭期间配置仍可写、归档取消、Git reader 延迟清理，以及真实独立进程硬退出后的共享锁回收。Git 子进程和进程锁为真实执行；HTTP 使用响应替身，不访问外网。

原实现本机 9 文件扩展回归 105 项、54 个子用例通过，发布说明 2 项通过。首次运行分别暴露导入与 Git 的终态早于清理竞态，已修复并包含在扩展结果中；未弱化暂存清理断言。Linux 工作流增加该文件及三域完整回归，Windows 增加新文件、Git/导入回归；仅依赖 POSIX symlink 的旧单文件用例仍由 Linux 验证。

原实现 `de51d4c` 的 [Native backup regression 45898745538](https://github.com/liyw0205/fls/actions/runs/45898745538) 未通过：Linux 27 文件 350 项、259 个子用例通过；Windows 既有监管、lease、I/O/认证通过，新增脚本 step 为 23 项、23 个子用例通过，Git 取消暂存清理 1 项失败，后续目录恢复 step 跳过。Git 对象保留 Windows 只读属性，`rmtree` 拒绝删除而 `_remove_entry` 吞掉错误；并非 reader 尚未退出。该提交的 [Module 45898745625](https://github.com/liyw0205/fls/actions/runs/45898745625)、[Desktop 45898745694](https://github.com/liyw0205/fls/actions/runs/45898745694)、[EXE 45898745551](https://github.com/liyw0205/fls/actions/runs/45898745551) 成功，打包不代替失败回归。

修正 `12185fd` / `20261127.11` 只对 Windows 只读属性导致的 unlink/rmdir 拒绝清除属性并重试，拒绝重解析点及其他权限错误；stage 清理失败返回 `unknown / cleanup_failed`，不因已发布目标覆盖成 complete。新增只读对象/替换身份和清理失败 2 项，脚本作业文件合计 11 项。本机修正后四文件定向 28 项、23 个子用例通过。

该历史检查点的最终工作流严格对应 `12185fd90a620ba6f67f183171f8330f63a4b514`：

- [Native backup regression 45899434365](https://github.com/liyw0205/fls/actions/runs/45899434365) 成功：Linux 27 文件 352 项、259 个子用例通过；Windows 全部通过，新增脚本 step 26 项、23 个子用例，既有监管 3 项通过/1 项 POSIX 跳过，lease/归档/顺序 5 项、7 个子用例，共享备份/恢复 9 项、7 个子用例，I/O/认证 16 项、3 个子用例，目录恢复 11 项、10 个子用例。
- [Module 45899434274](https://github.com/liyw0205/fls/actions/runs/45899434274)、[Desktop 45899434425](https://github.com/liyw0205/fls/actions/runs/45899434425)、[EXE 45899434387](https://github.com/liyw0205/fls/actions/runs/45899434387) 全部成功，正式 Release job 均已核对为 skipped。
- APP 本批只有方案变更；实际 APK 仍对应 `79bbfab` / `0.1.62+76`、CI `45883212390`、artifact `15148047738`（2026-12-10 19:29:52 UTC 到期）。不做 ADB/模拟器，真实面板手动验收待用户。

该历史批次只完成三类原生文件作业与正常进程退出的恢复互斥；Git 克隆 owner 崩溃清理由上方 `efc6a4d` 接续，跨 worker 活跃作业由 `5b19029` 接续。其余脚本文件读写、Web 拉取/导入、在线安装/调试、任务配置及日志句柄继续推进；Windows 实例锁/WAL/断电、启动器、多 worker 依赖清理、损坏回执维护和 APP 全流程亦未完成。不计 B3/B4 交付，不合并 main、不发布正式 Release。

上一数据 I/O 检查点：FLS `7524b052e571ba6a715d70cffbff3766f6bcd1d1` / `20261127.9`（129）。以下保留该批实现、平台验证及失败修复；它们不替代最新检查点的工作流证据。

本批将短文件访问与长作业分开：`.backup_native_restore.lock` 继续协调完整备份/恢复/依赖作业；新增 `.backup_data_io.lock` 协调 JSON 事务、会话/历史 SQLite 连接与目录替换。普通数据访问持共享锁，目录提交/回滚/清单清理持独占锁；冲突立即拒绝，不在模型锁或 storage/session 锁之后等待前置锁。独占权限仅当前线程可重入，其他线程不能借用；会话持锁顺序为 I/O → storage → session，完整恢复为 I/O 独占 → 模型 → storage/session。data 之外的旧恢复回执事务显式使用 `live_data=False`，底层 data 文件读写仍自行检查门禁。

prepared 或损坏清单拒绝普通读写；核对目录及实例身份后的 committed/rolled_back/finalizing 清单只允许读，普通写入仍拒绝。正常会话查询采用 SQLite `mode=ro`，不建库/表，连接和事务退出后显式关闭；历史索引 probe 修复隐含未关闭的连接。有效 Cookie 在恢复占用时返回 `503 / panel_storage_busy`、`Retry-After: 1`，不清 Cookie、不误报会话失效。验证码读写/清除和实例锁初始化接入门禁，验证码占用不转成“验证码不存在”。Git 代理检测改用系统临时 cwd，检测期间不创建/占用 data；回执读取也持短共享锁。

Python 命令行入口先恢复目录，保留原请求确认入口，再延后任务/调试状态整理、配置初始化、调度器重载和日志清理。初始化失败时当前 worker 仍返回原请求的 `directory_recovery_required`，显式再次处理原请求可继续初始化；GET 不执行整理。本批验证真实 Python `main()`，替换 HTTP 监听和依赖引导以避免网络与 pip；没有据此验证 shell/PowerShell 启动器、所有 WSGI worker 或稳定面板。

新增 `test_backup_data_access.py` 的 10 项测试、3 个子用例覆盖独立进程持 JSON/会话/历史连接时拒绝搬运，恢复移走 data 后禁止后台/验证码/实例锁重建目录，线程隔离与共享锁升级拒绝，真实原生提交期间登录/退出 503 且会话保持，terminal 只读认证及原请求确认，历史 probe/最终连接关闭，凭据变更回改不复活已清除会话，以及真实 Python 命令行重启与初始化失败重试。Git 检测测试使用进程替身，不访问外网；目录恢复和其他跨进程部分使用真实子进程。

本机最终 8 文件定向为 152 项、84 个子用例通过（排除 1 个既有 shell 进程识别测试）；23 文件扩展为 308 项、225 个子用例通过，另有 12 个既有 Termux os.link 相关失败及该 shell 测试的 3 个 PID 子用例失败。后者涉及未修改的 `fls.sh` 进程匹配；Linux Actions 保留完整用例，不跳过平台失败后宣称全量通过。扩展后为原请求提示补了当前 worker 初始化失败状态，最终定向结果包含此补充。

实现提交为 `276fbcc` / `20261127.8`，其 [Native backup regression 45894829858](https://github.com/liyw0205/fls/actions/runs/45894829858) 未通过：Linux 311 项、236 个子用例通过，1 项 CSRF 页面测试结束时页面通知线程仍在写临时目录；Windows 新增 I/O/认证 step 为 14 项、3 个子用例通过，2 项失败，分别为空实例锁占位文件导致 Python main 拒绝启动，以及旧认证测试断言 Windows 不支持的 POSIX 0600 mode。该提交的 Module `45894829925`、Desktop `45894829990`、EXE `45894829905` 成功，正式 Release 均跳过；打包成功不能代替回归。

修正提交 `7524b05` / `20261127.9`（129）使用真实实例锁 acquire/release 建立重启现场；保留 Cookie/认证轮换/数据库凭据断言，仅 POSIX 平台比较权限位。认证/备份 fixture 隔离页面通知和远程日志刷新；相关行为另有独立前端事件测试，不依赖这批认证测试启动外网线程。修正后本机两文件 60 项、43 个子用例通过。

本批最终工作流严格对应 FLS `7524b052e571ba6a715d70cffbff3766f6bcd1d1`：

- [Native backup regression 45895862160](https://github.com/liyw0205/fls/actions/runs/45895862160) 成功：Linux 23 文件 312 项、236 个子用例通过；Windows 监管 3 项通过、1 项仅 POSIX 跳过，lease/归档/顺序 5 项、7 个子用例通过，共享备份/独占恢复 9 项、7 个子用例通过，新增 I/O/会话认证 16 项、3 个子用例通过，目录现场/启动/API 恢复 11 项、10 个子用例通过。
- [Module 45895861931](https://github.com/liyw0205/fls/actions/runs/45895861931)、[Desktop 45895861946](https://github.com/liyw0205/fls/actions/runs/45895861946)、[EXE 45895862386](https://github.com/liyw0205/fls/actions/runs/45895862386) 全部成功，三个正式 Release job 均核对为 skipped。
- APP 本批只更新方案，实际构建仍为下方 `79bbfab` / `0.1.62+76`，CI `45883212390`、artifact `15148047738`（到期 2026-12-10 19:29:52 UTC）。后续文档提交不代表新 APK；无 ADB、模拟器或稳定面板验证。

该 I/O 检查点当时的保护范围仍有限：脚本拉取/导入/安装/调试、任务配置文件、长期日志句柄、shell/PowerShell PID 写入须继续协调；原生单文件/Git/导入已由上方 `de51d4c` 接续。广泛 except 对 busy 的响应、Windows 长期实例锁句柄/目录移动、外部 WAL/SHM、断电以及多 worker 启动整理仍待验证。会话默认 SQLite 模式的测试不证明任意外部 WAL 状态。在线源缓存/失败明细主要写路径已在既有 `storage_transaction` 内；备份依赖清单写入的是临时文件，不能把这些代码搜索结果直接当成未保护的 data 写入。

上一跨进程门禁检查点：FLS `ef2db1b` / `20261127.7`（127），门禁实现为 `5f49679` / `20261127.6`。以下保留其完整平台回归、失败修复及三个打包工作流证据。

所有备份创建、旧 Web 恢复/重载、原生恢复/现场恢复/后续处理及启动恢复共用 `BASE_DIR/.backup_native_restore.lock`。备份受理前持共享锁，线程接手后最后一个本进程备份退出才释放；恢复与后续处理持独占锁。原生恢复将已有独占句柄借给本进程 activity 标记，仍由原生 worker 负责释放，不重复拿锁或双重关闭。POSIX 用 flock SH/EX，Windows 用 LockFileEx 的共享/独占单字节锁；owner 元数据从第二字节开始，状态探针只探测独占持有者，避免共享备份让旧 owner 复活。旧 Web 独占时清除旧原生 owner，依赖安装结束及响应整理前不提前释放恢复锁。

目录清单存在时，新备份、旧 Web 恢复与重载均拒绝；损坏记录也保留现场。旧 Web 原请求/历史查询可识别其他 worker 的独占恢复，不把活跃 committing 改为 unknown。新增 9 项测试、7 个子用例覆盖真实跨进程共享/竞争、受理到线程启动、保存/启动异常释放、进程硬退出、待恢复记录、后续处理拒绝及真实旧 Web 提交期间查询；不运行 pip、不访问网络。定向含既有 lease/归档测试共 14 项、14 个子用例通过；本机完整 15 文件为 192 项、188 个子用例通过，另有 12 项既有 Termux 失败（缺少 os.link）。Linux/Windows Actions 承担完整平台验证，未做 ADB 或稳定面板恢复。

该旧检查点的门禁仅协调上述备份/恢复入口；会话 SQLite、任务历史索引及后台 JSON 保护已由上方 `7524b05` 接续，仍不能据此把 B3 标记完成。

本批失败与修复：`5f49679` 的 [Native backup regression 45886140416](https://github.com/liyw0205/fls/actions/runs/45886140416) Linux 完整回归成功，Windows 新增 9 项中 8 项通过；真实旧 Web 子进程目录已恢复，调度器中文日志因默认 charmap 编码抛错，导致预期成功的测试失败。`ef2db1b` 仅将测试子进程 stdout/stderr 固定为 UTF-8，并递增版本；保留真实提交及恢复结果断言。本机修正后新增 9 项、7 个子用例通过。

本批最终证据严格对应 FLS `ef2db1b1abc8f7a1c1410023118c1f206b94f146`：

- [Native backup regression 45886913139](https://github.com/liyw0205/fls/actions/runs/45886913139) 成功：Linux 15 文件 196 项、196 个子用例通过；Windows 监管 3 项通过、1 项仅 POSIX 跳过，lease/归档/顺序 5 项、7 个子用例通过，新增共享备份/独占恢复 9 项、7 个子用例通过，目录现场/启动/API 恢复 11 项、10 个子用例通过。
- [Module 45886913501](https://github.com/liyw0205/fls/actions/runs/45886913501)、[Desktop 45886913175](https://github.com/liyw0205/fls/actions/runs/45886913175)、[EXE 45886913142](https://github.com/liyw0205/fls/actions/runs/45886913142) 均成功，三个正式 Release job 均已核对为 skipped。
- APP 本批仅更新方案，继续使用下方 `79bbfab` 的 CI `45883212390` 与 artifact `15148047738`；不能把后续文档提交视为 APK 构建 SHA。

2026-11-27 接续目录现场恢复检查点：FLS `c8dd0eb` / `20261127.5`（125），APP 修复候选 `79bbfab` / `0.1.62+76`（原实现 `8629fd3` / `0.1.60+74`）。本轮先 fetch/fast-forward 两仓 develop，均已是最新；FLS main 无额外未纳入 develop 的提交，保留原工作区改动继续推进。下面保留旧检查点的通过证据，新检查点工作流结果单独记录，不用旧 CI 证明新代码。

目录事务清单位于 `BASE_DIR/.backup_native_commits/<request_id>.json`，在首次移动业务目录前持久保存 base/workspace/原目录/替换目录及密钥、会话等运行态对象身份。启动在创建 data、读取密钥和打开会话库前拿独占进程锁；prepared 按实际对象位置回滚，committed 保留新业务目录，遇到替换/损坏停止并保留副本。启动恢复后仍保留清单，由显式 `recover-directories` 保存原请求终态再清理；清理中断可重试。POSIX 对文件树和目录执行 fsync，Windows 当前只保证清单文件 fsync，独立进程硬退出测试不等于 Windows 断电持久性验证。

APP 新增可选严格 bool `directory_recovery_required`（旧后端缺字段按 false）；有现场待处理时隐藏人工结果确认、禁用调度器/依赖启动，提供“恢复目录现场”确认。恢复响应丢失只 GET 原 request ID，不能重新提交归档。损坏清单时 GET 仍提供待恢复提示，POST 保留证据并报错；全部恢复回执损坏的独立维护入口仍待补。

本轮本地四文件定向回归 52 项、29 个子用例通过；包含 6 个搬运节点的独立进程硬退出、恢复过程中再次退出、启动竞争、目录替换、清理重试、损坏/scope 不匹配，以及目录已提交但终态回执写入失败。扩展回归 181 项、181 个子用例通过，另有与既有 Termux 记录相同的 12 个失败；最终新增两个测试也单独通过。APP 121 文件格式及静态分析通过，新增 manager/widget 测试由 Actions 执行；没有 ADB/模拟器或真实面板恢复。

目录现场检查点工作流证据（仅对应 FLS `c8dd0eb` / APP `79bbfab`，失败 run 单列）：

- FLS [Native backup regression 45881063376](https://github.com/liyw0205/fls/actions/runs/45881063376) 成功：Linux 14 文件 187 项、189 个子用例通过；Windows 监管 3 项通过、1 项仅 POSIX 跳过，lease/归档/顺序 5 项、7 个子用例通过，新增目录现场/启动/API 恢复 11 项、10 个子用例通过。
- FLS [Module 45881063347](https://github.com/liyw0205/fls/actions/runs/45881063347)、[Desktop 45881063419](https://github.com/liyw0205/fls/actions/runs/45881063419)、[EXE 45881063360](https://github.com/liyw0205/fls/actions/runs/45881063360) 全部成功；正式 Release 跳过。
- APP `79bbfab` 的 [Android CI 45883212390](https://github.com/liyw0205/fls-for-android/actions/runs/45883212390) 成功：格式、分析、225 项 Flutter 测试、arm64 APK 构建及 develop 上传均通过；[artifact 15148047738](https://github.com/liyw0205/fls-for-android/actions/runs/45883212390/artifacts/15148047738) 到期于 2026-12-10 19:29:52 UTC。正式 Release 跳过；文档后续提交不改变此 APK 的构建 SHA。
- APP 本轮失败修复保留：`8629fd3` 的 [45881498927](https://github.com/liyw0205/fls-for-android/actions/runs/45881498927) 格式/分析成功、223 项测试通过、2 项现场恢复 Widget 测试超时：恢复结果已返回，但后台历史刷新尚未结束，`pumpAndSettle` 无法推进真实 HTTP 异步。`48c256f` 加入等待刷新完成，但 [45882657477](https://github.com/liyw0205/fls-for-android/actions/runs/45882657477) 的 Tooltip 查找返回 RawTooltip，转为 IconButton 导致两项类型错误。`79bbfab` 按实际 IconButton 类型和 tooltip 属性查找，等待刷新完成后 settle，最终工作流已验证。

检查点增加摘要/范围绑定的 `POST /api/backup/native/restores`，以及恢复状态/历史、unknown 人工核对、维护状态/确认、独立调度器重载和依赖操作。状态为 accepted/extracting/staging/committing/restored/failed/unknown；恢复不可取消，GET 不写回，unknown 不自动重放；人工核对仅记账，不执行目录替换。现有测试证据和未完成边界分别记录如下。

按以下顺序收尾；任一项未满足都不把 B3 标成可交付：

| 收尾项 | 完成条件与证据 |
| --- | --- |
| 运行态身份与回滚 | 已剥离归档身份、持久保存搬运清单，启动先恢复目录；`7524b05` 延后 Python 入口写入至原请求确认，`5626ac9` 接入同步脚本文件与 Web 传输保护。硬退出及恢复再次中断已测试；仍需在线安装/调试、任务/日志作业、shell/PowerShell 启动器、Windows 实例锁句柄/断电与多 worker 启动边界 |
| 锁顺序与跨进程互斥 | `5f49679` 统一备份/恢复长作业锁；`7524b05` 接入 JSON、会话/历史 SQLite、验证码和实例锁初始化的短 I/O 门禁，验证连接关闭、线程隔离及真实提交中认证 503。继续其他文件作业、逐域 busy 映射与外部 WAL 状态；本批平台 CI 见上方 |
| 证据与原请求保留 | 已从持久恢复回执重建 TTL 保护，unknown/待处理依赖不被清理且计入双暂存容量；读取回执字节和历史扫描有上限。每次后续 operation ID 独立保留（最多 16 次），旧 ID 重放不重新执行；到期/内存引用丢失及旧操作重放测试通过，仍需完整容量/损坏/断电故障覆盖 |
| 依赖资源清理 | 已加带启动门的监管进程：持久保存执行/工作目录身份后才执行 pip；POSIX 不提前回收会话首进程、确认组内非僵尸进程退出后释放，面板进程死亡通过控制管道触发回收；Windows 使用带 KILL_ON_JOB_CLOSE 的命名 Job Object，真实 Actions 已验证启动门、命令父进程先退出和所有者崩溃回收。显式 cleanup 按原操作清理且 GET 零副作用；失败、写盘失败、重启恢复、目录替换、输出读取失败均有回归。仍需多 worker 中持有内存清理句柄的进程协调、全部回执损坏时的维护恢复 |
| APP 完整流程 | 已补严格恢复 DTO 类型/一致性及响应身份校验、历史分页/读取失败保留原页、原请求/后续处理轮询、未知结果禁止再次恢复、依赖确认文案及 401 退出嵌套备份页；返回任务页刷新。新增原操作清理按钮，清理期间禁用安装/调度器，清理响应丢失只查询原请求。manager/widget 测试已由 Actions 执行；继续验证跨会话/面板切换/旧回包、概览刷新和提交丢失全流程 |
| 配对验证 | 完成下述旧 Web/认证及故障回归，APP manager/widget 测试在 Actions 执行；再递增两仓实际版本、提交推送 develop，记录双方 CI 与对应 APK。隔离面板手动验收由用户执行，全量前不合并 main |

下一轮核对整源刷新受理/线程/日志入口，再继续调试、任务配置和日志句柄。`b8c8b60` 已补安装 lease/命令监管，`a9c1cc1` 接续在线安装跨 worker 协调，`9f7e4df` 补独立任务导入/安装选择，`05622bd` 与 `9b34573` 补任务源同步和共享缓存/恢复回执协调；不重复开发已验证保护，以实际平台 CI 为准。网络等待不能长期拿配置锁，提交与清理须与恢复互斥。核对 shell/PowerShell PID、Windows 常驻实例锁、外部 WAL 和多 worker 启动整理；保留 I/O → 模型 → storage/session 顺序，会话内部 storage → session，I/O 冲突不反向等待。逐域检查 except 吞 busy，未验证路径不计已接入。

入口批次的当前状态与退出条件如下；候选实现不代表 B3 全量完成：

| 入口 | 当前证据 | 下一批验收 |
| --- | --- | --- |
| 安装选择/独立任务导入 | `9f7e4df` 已补 Web/API 恢复 lease、跨 worker 身份与回执事务、独立恢复认领及在线任务发布合并；新增 10 项 worker/恢复测试 | 后端历史双平台终态见上方；APP `4f4dd2e` 已补 active 按钮禁用、原请求查询与旧回包隔离。用户手动验收待完成，不重复重做候选 |
| 外部任务源同步 | `05622bd` / `9b34573` 已补全部 Web/API 恢复门禁、真实身份/回执/独立恢复认领、缓存合并和原刷新恢复回执修复协调；APP 同批补活跃动作禁用和原请求查询 | 本批证据见本节顶部；只合并在线源 task_cron，不写 tasks.json 或重载调度器。手动验收待用户，不重复重做候选 |
| 在线源刷新/日志及源编辑 | 源编辑及刷新缓存发布已共享跨 worker 事务，抓取期间缓存变化拒绝覆盖；`refresh_worker/start_refresh_thread` 和 `refresh.py` 的受理/活跃状态仍基于进程内锁和缓存 | 首次回执/线程交接到日志与清理均持 lease；跨 worker 受理/活跃状态按真实身份与最新回执协调；坏历史/写入失败不重复联网或覆盖源缓存 |

实现时纳入现有 import/replay/confirmation/retention、task-link、source-refresh、refresh-log/storage-recovery 及旧 Web 回归，并新增真实独立 worker、HTTP/线程失败释放、恢复竞争和 busy 不被吞的测试。APP 既有入口继续复用；若契约有变化，同批更新 DTO、manager、原生错误与恢复操作，而不以 WebView 代替。完成该批后仍须接续下列 B3 其余范围及 M4-M7。

外部任务源同步以下边界已在 `05622bd` / `9b34573` 实现，保留为对照，平台结论以本节顶部为准：

1. 给直接同步、原刷新失败项恢复、状态/历史、确认和归档的全部 Web/API 入口加恢复 lease；首次回执前取得真实身份，持有到 HTTP response.close、缓存发布、回执与 finally 完成。保存或关闭失败不得留下假活跃或开放重复提交，网络等待不持 storage/配置事务。
2. 将 `source.py` 的 task-link 回执读改写、容量保护与活跃探测改为跨进程事务；确认/归档独立认领。已有 prepared/running 的中断恢复、原代理/源版本及 origin_refresh_request_id 绑定继续保留，旧内存测试改持真实身份而不放宽断言。
3. `merge_task_link_tasks` 已改在共享的跨 worker 缓存事务内重读/合并，并与源编辑、整源刷新发布协调，避免不同 worker 覆盖后来的任务或元数据。发布意图回调不反向等待受理锁；刷新失败项恢复回执和 task-link 终态分别可复核，结果未知不重新联网。tasks.json 的在线导入锁不代替缓存保护。
4. 新增双 worker 请求/选项冲突、HTTP 等待与关闭、owner 强退、确认/归档竞争、缺失活跃回执容量、并发缓存合并与原刷新绑定回归；检查响应读取有界及 busy 原样返回。APP 复用原生任务操作历史/状态，补 active 操作禁用与 409 后原请求查询，覆盖 401 和过期回包。递增实际变更仓库版本并通过双平台/APP 对应工作流后再接刷新批次。

在线安装跨 worker 的六步在 `a9c1cc1` 已有候选实现，实际平台证据见上方；以下记录对照，不作为 B3 全量完成证据：

1. 受理锁协调首次受理、同请求/脚本、停止及恢复认领；独立回执事务统一所有安装 JSON 读改写，任务发布沿用 storage → 回执锁，不反向等待受理锁。有界等待与短 I/O 门禁复用 `DirectoryJobLock`。
2. 首次回执前 claim 身份，交给线程并持续至日志/finally；命令监管共持身份，硬退出后等整树清理。历史 ID 稳定映射锁名，外部 ID 和日志不变。
3. owner 保留同一运行字典和句柄，合并持久停止/父子重试；非 owner 缓存从最新磁盘刷新。旧未知/诊断不覆盖新恢复，运行句柄不进 JSON。
4. 先保存停止请求/attempt，再由 owner 消费；写入失败不发信号，停止失败仍活跃、可再次停止。受理与实际退出分开，不承诺文件/任务回滚。
5. 同 ID/同选项复用原安装，选项变化冲突，同脚本和父子重试仲裁；任务补导入、确认和调度器恢复持独立认领。force、原请求恢复和历史容量既有规则保留。
6. 双真实 worker 覆盖活跃查询、同 ID/父子重试竞争、进度合并、远端停止/失败再试、owner 硬退出、三类恢复认领、旧 ID/缓存与坏历史；既有门禁/交接/失败释放测试保留，Linux/Windows 工作流验证。自动化不替代 APP 用户手动验收。

整源刷新下一批从以下具体入口推进；以下尚未实现，不能据共享缓存保护推断已支持：

1. `refresh.py` 的 options、首次提交、retry/recover/confirm、全局/按请求状态、历史与失败项分页，`logs.py` 的 Web/API refresh-log，以及 `pages.py` 的在线脚本页刷新状态/历史读取全部接恢复门禁。受理请求与后台线程分别持 lease，覆盖首次回执、线程交接、HTTP 关闭、缓存/失败明细发布、终态日志与 finally；构造/start 失败释放独立资源。`pages.py` 与日志入口现有 broad except 须保留 busy 状态，不能把恢复占用吞成空历史或普通错误页面。
2. `constants.py` 的 `reserve_online_refresh/get_online_refresh_submission/claim_online_refresh_retry` 以跨 worker 受理和真实存活身份协调，首次落盘前认领，沿原 ID 查询；owner 强退后保留 unknown，不靠另一 worker 的空内存判定失败或再次联网。同请求代理/源/缓存绑定、单活动刷新、父子重试、200 条历史链和 snapshot 分页全部保留。
3. 刷新 current/history/失败明细及双份恢复副本的所有读改写明确共享顺序；已经存在的 `source_cache_transaction` 与 `task_link_receipt_transaction` 继续复用，不能在身份锁内反向等待缓存或受理。网络等待不持 storage。另一 worker 的恢复/新终态优先于旧 owner 内存；查询修复不得覆盖更新后的代次或吞 busy。
4. recover/confirm/retry 独立认领原请求；状态/历史/日志查询不重新联网，保留旧 Web 回执修复语义和 APP 原 ID 恢复。APP 刷新页补 active/忙碌禁用、409 后只读查询、旧回包隔离、切页与 401；如增加字段，按可选严格类型兼容旧面板，不复用任务源同步状态冒充整源刷新状态。
5. 新增真实双 worker、首次回执/线程交接/HTTP 关闭/日志故障、写前写后失败、强退、同时首次提交与父子重试、确认/恢复竞争、容量/坏历史、缓存编辑竞争和旧回包回归。保留现有刷新/日志/存储恢复及 Web 测试，递增实际修改仓库版本并取得对应平台 CI/APK，手动验收单列。

已核对的下一批根因：`get_online_refresh_state()` 目前仅因从磁盘载入 running 回执便转成未知，`start_refresh_thread()` 直接启动 daemon 线程；这不能区分其他 worker 正在执行与 owner 已退出。下一批先以真实身份覆盖首次回执和线程交接，再迁移这些读取/恢复逻辑，不能仅给持久化函数加文件锁便认定完成。APP `_RefreshJobViewState` 也还没有查询代次或状态可信标记，查询失败会保留旧操作，动作失败只显示错误；按前述第 4 步同时修正。整源 retry 在发送前保留 child request ID，失联后查询 child；失败项同步查询原 task-link ID，均不得自动再发 POST。大于首屏的失败项使用现有分页 API，核对原刷新身份后继续加载。

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
| 目录现场恢复（B3 检查点） | `POST /restores/<request_id>/recover-directories`，仅接受 `confirm: true` | 绑定原 request ID 和恢复范围，拿独占进程锁后核对持久清单；先保存确定结果再清理副本。`directory_recovery_required` 只读，有未处理清单时禁止新备份/恢复/人工确认/后续处理；损坏与写盘失败保留现场 |
| 后续处理（B3 检查点） | `POST /restores/<request_id>/scheduler-reload`、`POST /restores/<request_id>/dependencies` | 独立 operation ID，用户显式启动；不重新上传或替换目录，调度器重载不顺带安装依赖 |
| 依赖清理（B3 检查点） | `POST /restores/<request_id>/dependencies/cleanup` | 仅接受原 dependency operation ID；状态里的 `dependencies.cleanup_required` 为只读提示。确认进程/reader 退出和工作目录身份后才清理、保存回执并释放 lease；失败保留占用，成功清理不等于原安装成功，不再次执行 pip |
| 维护（B3 检查点） | `GET /restore-maintenance`、`POST /restore-maintenance/<event_id>/ack` | 只读展示维护状态，确认绑定当前事件 ID；未修复问题不能仅确认后清除 |

GET 全部 `no-store`，不写回归一化状态、重建归档、清理 staging 或执行作业。读取冗余索引时只能返回可验证的快照及维护需要，不能调用带修复副作用的旧 helper。请求摘要不存正文、凭据、归档内容或服务器路径；日志按需读取、脱敏并限行/字节。JSON 写入拒绝重复键/未知字段和超限；multipart 拒绝重复关键字段并单独控制文件总量及请求开销。

## 状态、资源与恢复

预检查和恢复分别持有身份。预检查成功仅证明所存快照通过检查；用户确认前不安装依赖、不改业务目录。预检查提交需持久化上传意图并绑定 digest；丢失响应后先查询原 ID，不自动重新传输。若无法证明未接收或未提交，保持 unknown。原恢复 request ID 只绑定一次确定意图，相同 ID 查询不会隐式再次恢复。

恢复状态按 B3 检查点细化为 accepted/extracting/staging/committing/restored/failed/unknown，并独立表达目录提交、调度器重载、依赖与维护结果；最终字段以收尾后的 DTO 和测试固定。全部目录提交完成、部分目录提交后回滚失败、依赖失败和调度器失败不能压成一个失败按钮。目录恢复后仅提供当前缺失的后续处理，不能引导用户再次上传同一归档。

B1/B2 已验证的资源基线为：原生 staging 同时最多 2 个已受理快照、单次上传和展开沿服务端有效上限、预检查最多 1 个执行且无无限队列、成功预检查保留 1 小时。B3 已统一备份共享/恢复独占长作业 lease，并在 `7524b05` 保护 JSON/会话/历史连接的短 I/O 区间；其他文件长作业和全部后台写入协调仍待补齐。空间不足在受理前拒绝，拒绝容量不得清理未知恢复所需证据。依赖作业有 1800 秒等待期限、32 KiB 脱敏输出及独立进程监管，只有进程树和 reader 退出、工作目录清理与回执保存完成才释放；多 worker 清理和回执全部损坏的维护路径尚待补齐。

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
| B3 恢复及后续处理 | 最新任务源同步候选 FLS `b2a0ef7` / `20261127.29`、APP `4f4dd2e` / `0.1.64+78`，沿用安装/独立导入、文件/Web 传输、三域跨 worker、I/O 门禁和目录现场；本批补同步身份/回执/恢复与共享缓存发布、APP 活跃操作禁用及原请求查询，实际 CI/APK 见上方。继续整源刷新作业、调试、任务/日志、启动器、Windows 实例锁/WAL/断电、多 worker 清理、损坏回执维护及 APP 全流程 | 上述剩余项完成并通过故障/兼容回归；检查点和 B2 证据均不能代替 B3/B4 完整交付 |
| B4 配对验证 | 双方版本递增、提交推送 develop，聚焦新契约及旧备份恢复回归、双方 CI 和 APK | 记录确切 SHA/版本、工作流终态、测试边界及 artifact；手动验收待用户，不合并 main |

旧回归至少涵盖 `test_backup_request_recovery`、`test_backup_cancel_recovery`、`test_backup_file_recovery`、`test_backup_orphan_staging`、`test_backup_atomic_publication`、`test_backup_limits`、`test_backup_restore_idempotency`、`test_backup_restore_recovery` 和 `test_auth_backup` 中相关用例。平台不支持的测试单列，不跳过后宣称全量通过。新测试注入存储/线程/进程及目录提交故障，不修改真实面板数据。

APP manager/widget 覆盖子路径/session/CSRF、传输真实进度/未知总量、版本冲突、断网只查询、预检查与提交分离、部分恢复、401 和 320dp/大字号/横屏；Actions 运行 Flutter 测试及 arm64 构建。本地 format/analyze，不做 ADB。隔离面板真实备份和恢复由用户手动验收；M3 通过后继续 M4-M7，全部适用流程及用户验收前两仓均不合并 main。
