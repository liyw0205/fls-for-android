# 日志原生清理与写入协调

## 实现状态与范围

日志域已验证后端基线 `e1c4083711d21c637b81032b6be3396cba1e8bc2` / `20261128.14`（169）的 [Native `46085389388`](https://github.com/liyw0205/fls/actions/runs/46085389388) 完整成功，三项打包成功；这不表示运行中的面板已经升级。APP 原生清理修正 `99d1c9b7ee8c8edf0af2f774557df5581a374b69` / `0.1.75+89` 的 [Android CI `46088657554`](https://github.com/liyw0205/fls-for-android/actions/runs/46088657554) 已通过格式/分析、286 项测试及 arm64 APK/artifact `15240013111`，正式发布 skipped。后续后端实例锁 `78c2632` / `20261128.17` 的新 CI 验证中，见备份规格；两个 main 不变。

`cc1493e` 新增 `fls_manager/log_access.py`，在恢复范围外按日志文件名协调跨进程共享读取/写入与独占删除，锁保持至实际句柄关闭；校验目录/文件身份，拒绝链接和特殊文件。已接普通任务、调试、在线安装、依赖/运行时、备份依赖、面板控制及前端事件的 Python 日志入口和读取/下载。普通任务/调试/在线安装的独立命令监管在 owner 强退后继续持日志 lease。Web 单文件、分组及自动清理共用版本核对删除 helper，替代进程内 `LOG_FILES_MUTATION_LOCK`；占用读取返回 503 `log_file_busy`。

`5e2c762` 补自动清理的 deleted/missing/busy/conflict/failed/unknown 计数。先扫描一次并固定全部文件版本与时间，再处理大小和保留数量；每个过大文件只尝试一次，分组头不可读时保留文件并计失败，避免误分到其他日志。删除前变化返回 conflict，清理期间新建日志留到下一轮。计数目前仅由内部函数返回，尚无原生展示。

`f5aacbd` 新增 `InstallProcess`，在依赖安装、原生卸载、运行时安装和两类重试的五处异步创建点复用 `DirectoryProcess`。启动门之前监管接管恢复/日志 lease；terminate/kill 只关闭 owner 控制通道，不向监管 PID 直接发信号。wait/poll 在整树和继承日志退出、临时目录清理成功后才返回退出码，并发等待共用结果/清理锁。父日志关闭失败不再被轮询/取消终态吞掉：原 process/log_fp 和状态保留，后续查询确认关闭后再完成；不新增取消或重试协议。

`5977c73` 将旧 Web 卸载复用已有卸载受理、包名/库存校验、冲突、回执和监管：每个表单生成请求 ID，重复 Web/原生提交共用同一作业，受理及回执待保存跳转原日志页。错误保留原状态及纯文本，不另建取消/重试模型。新增回放、校验、CSRF、回执故障及真实无害命令测试；本机相关 82 项/36 subtests、旧 Web 页 2 项通过。

`f574248` 将旧恢复依赖接入 `InstallProcess`，保留原命令、日志及 1800 秒等待上限。原主恢复锁保持独占，监管先取得独立 `.backup_restore_command.lock`，面板重新核对原锁文件和独占占用后发送第二次启动确认；确认前断连不执行命令。公共主恢复锁先持有 primary，再探测 guard；占用或故障释放 primary，create=False 不新建文件，避免首次 guard 缺失的竞争。owner 强退/原锁释放后，独立 guard 保留至整树及继承日志关闭；不依赖 Windows 父句柄继承。超时先确认整树停止，再释放归档/日志。该路径不改原生备份 `DependencyProcess` 的清理协议。

`f85b87b` 将控制命令和 shell/PowerShell 常驻输出交给独立管道收集进程。只有收集进程打开 `fls-manager-daemon.log`，最后一个继承输出端关闭后才释放日志 lease；owner 退出不取消控制命令。固定守护日志位于 data/scripts 恢复集之外，只长期持有日志锁，不阻塞恢复；其他日志保留原恢复门禁。启动确认前失败不执行命令，描述符交接失败恢复原输出；Windows 同步 CRT 与系统标准句柄，PowerShell 直接启动 Python。systemd transient unit 的服务端输出仍使用原 journal，客户端输出进入收集管道，未运行真实 systemctl。

覆盖边界：`e1c4083` 已通过新清理及全部配置的 Linux/Windows 回归，上一 Windows 旧依赖结果读取红用例修复通过；失败历史保留于后文。APP `99d1c9b` 的完整 CI/APK 成功，真实面板手动验收待用户，跨 APP 进程恢复仍归 M5。实例锁新候选、WAL/断电、多 worker 依赖清理等仍属 B3 剩余，不能由本批日志测试代替。

2026-11-28 03:51（UTC+8）验证快照：本机最终日志/删除/任务日志/发布说明 29 项、54 子用例通过；扩展调试/在线安装等 113 项、55 子用例通过、1 项跳过。绑定 `cc1493e` 的 Module `46059064241`、Desktop `46059064327`、EXE `46059064382` 打包成功；[Native `46059064312`](https://github.com/liyw0205/fls/actions/runs/46059064312) 尚在运行，Windows 新增日志步骤已通过，不能提前记录双平台全绿。APP `269c16c` 的 Android CI `46051131340` 已通过 268 项测试与 APK 构建，本批未改 APP 代码。

后续失败与修复证据按实际 SHA 保留：

- `cc1493e` 的 Native `46059064312` 最终双平台失败：Linux 11 failed/1130 passed/1 skipped/1024 subtests，Windows 在线安装 6 failed（含 2 个子用例）/177 passed/5 skipped/132 subtests。旧安装路由自 `761da4c` 接受 BASE_DIR 根目录日志，新共享层只接受 LOG_DIR，导致旧记录读写失败；本机同样复现，未通过改夹具掩盖兼容回归。
- `f1fe652` / `20261128.5`（160）以显式 legacy_root 恢复旧根目录 `.log` 读写和安装监管，根目录与 LOG_DIR 同名文件分开选锁，默认删除仍只接受 LOG_DIR，链接/越界拒绝保持。可读性探测也接共享锁。原安装生命周期断言保留，本机 8 文件 176 passed/1 skipped/97 subtests。Native `46062169439` 的 Linux 1140 passed/1 skipped/1031 subtests；Windows 两项任务等待失败，后续安装步骤当时全部 skipped，不能记为已验证。
- `da93db1` / `20261128.6`（161）加入任务失败现场及持旧回执句柄的确定性双进程回归；Windows 独立步骤失败后继续收集证据，但任一失败仍使 job 失败。Native `46064429360` 最终 Linux 1141 passed/1 skipped/1031 subtests（2 条既有 tar 警告），Windows 仅新增持句柄用例失败：另一个 worker 的 os.replace 报 PermissionError/WinError 5，12 项任务/46 subtests 及后续 12 个独立步骤通过。在线安装本轮 181 passed/5 skipped/134 subtests，补齐了旧日志修复在 Windows 的证据；三个打包工作流成功。

- `5e2c762` 的读取共享修正不足以完成 Windows 原子发布。Native `46066990491` 最终 Linux 1147 passed/1 skipped/1031 subtests（2 条既有 tar 警告），Windows 原持句柄回归与手动替换重试失败（2 failed/13 passed/46 subtests）；后者日志明确重试计划被 os.replace/WinError 5 中断。其余 12 个独立步骤成功，自动清理/日志 31 项/13 subtests 通过，三个打包工作流成功。本机此前日志扩展 124 项/64 subtests、任务/历史/日志 107 项/77 subtests、发布说明/轮询 6 项/3 subtests 均通过，不能代替 Windows 失败结论。

`9aeff36` 修正发布端：CPython 3.12 的 os.replace 使用 MoveFileExW；仅加 FILE_SHARE_DELETE 仍不允许旧接口替换已打开目标。按微软 FILE_RENAME_INFORMATION 契约使用 FileRenameInfoEx 的 REPLACE_IF_EXISTS | POSIX_SEMANTICS，旧句柄继续读取旧对象，新打开读取完整新版本。发布前同步私有临时文件，以 DELETE 权限打开最终源句柄并校验 reparse/常规文件，单次原子发布后关闭 FD；失败仍清理临时文件，不增加任意重试或超时。保留原红测试及 16 KiB/链接边界，并补 Unicode 含双 UTF-16 码元路径和发布失败保留/清理测试。本机 6 文件 97 项/72 subtests、新发布/读取定向 5 项通过。[Native 46071964294](https://github.com/liyw0205/fls/actions/runs/46071964294) 最终完整成功：Linux 1149 passed/1 skipped/1031 subtests（2 条既有 tar 警告），Windows 任务 17 项/46 subtests 及其余 12 步全部通过，在线安装 181 项/134 subtests、5 skipped；三项打包也成功。APP 构建与手动验收状态不变。

`f5aacbd` 本机依赖相关 75 项/30 subtests、日志/监管/旧删除/发布说明相关 58 项/26 subtests 通过。新回归覆盖真实父子进程、owner 强退后的独立 lease、启动失败、并发等待、workspace/父日志关闭失败，以及安装/卸载/运行时与重试原 ID 回放；没有真实 pip/系统安装。父日志关闭红测试在修复前的 poll/cancel 两个子用例均失败，修复后留仓。扩展整个 `test_high_side_effect_workflows.py` 时有 4 项 BackupIsolation 失败，已在未修改 `9aeff36` 的独立 git archive 副本重现相同四项，不能记为本批全 suite 通过。Native `46075102248` 最终完整成功：Linux 1149 passed/1 skipped/2 既有 tar warnings/1031 subtests，Windows 原有全部作业通过；新增 Linux 监管 10 项/10 subtests、旧依赖 65 项/20 subtests，Windows 监管 10 项/7 subtests。三项打包 `46075102329`、`46075102342`、`46075102353` 成功，正式发布全部 skipped。

Web 卸载 `5977c73` 的 Native `46077499732` 完整双平台成功：Linux 1149 项/1031 subtests、1 跳过、2 既有 tar warnings；Windows 任务、日志/备份/在线脚本及双平台依赖监管均通过。三项打包 `46077499922`、`46077499781`、`46077499832` 成功，正式发布全部 skipped。

恢复安装 `f574248` 新测试实施前 4 failed/1 passed，实施后监管/日志/活动等 6 文件 63 项/33 subtests、目录/日志 5 文件 24 项/16 subtests 通过。最终锁顺序修正及新增缺失 guard/拒绝释放/原锁内探测回归后，活动/安装 24 项/20 subtests、扩展 9 文件 213 项/140 subtests 通过，compileall/diff 检查通过。Native `46079372062` 最终 failure：Linux 1150 passed/1 skipped/2 既有 tar warnings/1031 subtests，双平台恢复安装监管和 Windows 任务成功；Windows 在线安装步骤 1 failed/180 passed/5 skipped/134 subtests，其他步骤通过。唯一失败为页面确认用例的临时目录清理，持有的锁名与 `frontend-events.log` 的 SHA-256 完全一致；隔离夹具漏等 `fls-frontend-open` 通知线程。三项打包 `46079371964`、`46079372100`、`46079372093` 成功，正式 Publish 全部 skipped。不能将新增监管成功记为完整回归通过。

常驻日志 `f85b87b` 同时补齐夹具等待上述线程，不忽略异常或删减业务断言。新测试实现前 9 failed（含 2 个子用例）/1 passed；真实控制函数返回后，旧实现会删除仍在输出的日志。实现后最终新文件 11 项/4 subtests、日志/控制/旧删除相关 65 项/31 subtests、实例锁 3 项，以及依赖监管/恢复活动/在线安装恢复/发布说明 59 项/52 subtests 通过。覆盖大于单块输出、owner 正常退出/强退、子进程继承输出、恢复锁持有期间继续写入、启动超时、命令 spawn/描述符故障及真实平台启动脚本。整 `test_fls_startup.py` 的 3 个既有 Termux 进程扫描子用例失败保留，本机无 PowerShell；双平台工作流最终结论见下段。只运行临时目录内无害 Python，不执行真实安装、重启/停止、稳定面板恢复或 ADB。

`f85b87b` 的 Native `46081466141` 最终 failure，新增 Windows daemon 步骤为 1 failed/9 passed/1 skipped/4 subtests，仅真实 PowerShell 启动失败。原安装监管 14 项/10 subtests 成功，Linux 新增监管 job 与 Windows 任务成功；完整 Linux 1150 passed/1 skipped/2 既有 tar warnings/1031 subtests，Windows 原有长回归全部成功，在线安装 181 passed/5 skipped/134 subtests，确认前述夹具等待修正已通过。已捕获管道的 owner 测试通过，但控制台启动的 Python 保留 WindowsConsoleIO，dup2 后仍调用控制台写入，实际报 OSError22/WinError1 `Incorrect function`、`lost sys.stderr`。Module `46081466142` 成功；Desktop `46081466146` 安装后启动复现同错误，EXE `46081466246` 安装后健康检查失败。

`f907e6c` 保留真实平台启动红用例，在 Windows 描述符和系统标准句柄交接后创建普通 UTF-8 文本流；使用独立 duplicate FD，两流均构造成功后再替换 stdout/stderr，失败走原回滚。平台用例同时断言文本、stderr、os.write 和继承子进程输出。本机新测试及发布说明最终 13 项/4 subtests 通过，compileall/diff 检查通过。已在上一完整 Native 终态后推送此提交至 `develop`，没有取消旧证据；新 [Native `46083027529`](https://github.com/liyw0205/fls/actions/runs/46083027529)、Module `46083027619`、Desktop `46083027534` 和 EXE `46083027519` 已启动，尚未取得完整终态。新 SHA 的 Windows 及真实打包验证仍须收取，不以本机成功记为修复闭环。

`f907e6c` 的 Native `46083027529` 最终 failure：Windows 真实平台启动及安装监管、Linux 新增监管、Windows 任务和完整 Linux job 成功，Windows 原长回归的 `test_cleanup_kills_descendant_after_command_parent_exits` 失败，`DependencyProcess.wait()` 读取 `process-result.json` 报 PermissionError（该步骤 1 failed/2 passed/1 skipped）。Module `46083027619`、Desktop `46083027534`、EXE `46083027519` 成功，正式发布跳过。旧 run 终态后才推送新候选，保留失败证据。

`e1c4083` 将已验证的 Windows 共享读取和 FileRenameInfoEx 原子发布抽至 `receipt_io.py`，任务协调保留原导入别名，旧依赖监管结果读取/发布也复用此实现；不改 `directory_process.py`，不增加忽略错误或重试。新增真实监管进程在旧读取句柄持有期间发布结果的回归。Windows 修正须以本次新 SHA 验证，不能用 Termux 结果闭环。

本批原生清理先写后端契约测试，初次新接口确实返回 404；实现后的最终十文件回归为 90 passed/47 subtests，compileall/diff 检查通过。包括固定分组、同名替换/父目录变化、活跃 writer、逐项结果、200 文件和容量/TTL/实际 body 上限、签名损坏、初/意图/终回执失败、GET 零写入、只观察核对和真实 worker 在持久删除意图后强退。新 workflow 增加 Linux/Windows 独立清理 job，保留全部旧完整回归。

实现回执位于恢复范围外的 `BASE_DIR/.log_cleanup`，预检查最多 32 份、原请求最多 512 份，每份实际读取最多 512 KiB + 1；只退役已过期且签名有效的预检查，未知临时现场/损坏/容量满均拒绝新写。POST 实际 JSON 限制 384 KiB，固定最多 200 文件或 20 组、600 秒 TTL；逐项保存 deleting 后才删除，保存后再次核对原对象，持久化失败停止后续项。GET 对 pending/deleting 返回 unknown，相同 ID 永不再删除；reconcile 仅观察原未知目标。

截至 08:05（UTC+8），新 Native `46085389388` 的 Linux/Windows 清理 job 均成功，各 44 passed/28 subtests；双平台依赖监管和 Windows 任务 job 成功。Windows 长回归中原失败的 Job Object/旧依赖结果步骤已成功，但完整 Linux/Windows 长回归仍运行，不提前记整体全绿。Module `46085389329`、Desktop `46085389356`、EXE `46085389364` 均成功，三个正式发布 job 均 skipped。全量原生业务、主题和用户验收仍未完成，不能据此合并发布。

最终 `46085389388` 完整 success：Linux 1151 passed/1 skipped/1031 subtests（2 条既有 tar warnings）；Windows 旧依赖步骤 4 passed/1 skipped，包括原失败用例和新持旧句柄发布测试，任务 job 17 passed/46 subtests。全部其余 Windows 步骤成功：脚本 66 项/182 subtests、1 skipped/2 tar warnings，在线安装 181 项/134 subtests、5 skipped，任务源 204 项/152 subtests；双平台清理各 44 项/28 subtests、监管和真实启动均成功。三项打包和正式发布 skipped 状态保持。

APP `bc1a4c4` 新增严格 DTO/manager 和清理原生页，日志列表跨页选择文件/分组，详情单文件入口；只有独立能力 GET 的明确 404 才判不支持。预检查核对所选目标，结果核对原 request/preview/digest、固定文件版本/分组/字节及逐项计数。POST 前保留身份，每个 operation 最多提交一次，未知/missing/失败均不自动重发；清理记录在当前面板壳中按 URL 保留，重新认证可查原请求，最多 32 份，仅清除已完成记录。后台遮蔽和关闭确认框，旧 manager/401 隔离，同一 operation 的旧结果不能覆盖新查询；跨进程恢复未实施。本机全仓格式、静态分析与 diff 检查通过，新增 manager/Widget 测试正在 Android CI 验证，不做 ADB。

首轮 Android CI `46088032710` 最终 failure：格式和分析成功，282 项测试通过/2 项 Widget 失败，APK 和上传 skipped。第一项直接进入 paused 后停止出帧，原 post-frame 关闭确认仍留在视图；第二项详情正文带行号的 SelectableText.rich 与精确文本 finder 不匹配。`99d1c9b` 改为持有具体 DialogRoute，后台同步作废确认身份并以微任务移除该路由，不依赖出帧，也不会误 pop 其他页；异步确认返回须仍绑定同一路由。补 inactive 遮蔽、无帧快速暂停/恢复、已排队同意作废两项回归；详情使用包含正文的 finder。路由 builder 同时捕获原 manager/回调/文件，避免延后读取替换后的面板上下文。本机全仓格式/分析、diff 检查通过，新 SHA CI 仍待最终核验，保留原失败。

最终 Android CI `46088657554` 已完整 success，新增生命周期及全部既有测试共 286 项通过，APK 构建和 develop 上传成功，三个正式发布步骤 skipped。[artifact `15240013111`](https://github.com/liyw0205/fls-for-android/actions/runs/46088657554/artifacts/15240013111) 归档 11,164,300 字节，到期于 2026-12-12 00:42:07 UTC。已取回 `build/develop-0.1.75+89-99d1c9b/app-release.apk`，本体 11,513,021 字节，SHA-256 `ebd7cf4cb527799bb314c48f8013e0dc974e4391d98921b1094ba04e9500a578`；aapt 核对包名 `top.fls.fls_for_android`、versionName `0.1.75`、versionCode `89`。安装包未自动安装，未做 ADB/模拟器。

手动验收使用隔离 FLS 开发实例及可丢弃日志：从记录页选择单文件/多文件/分组，先核对预检查固定清单，再确认清理并逐项查看结果；从详情页进入单文件清理；确认框打开时切后台再返回，旧确认应取消且不提交；失联后从清理记录查询原请求，unknown/missing 不出现重新删除入口。旧后端只有独立能力 404 才显示不支持，401 仍要求重新连接。手动验收结果尚未收到，不阻塞其他域继续开发，也不满足全量合并门槛。

计划覆盖原生单文件、多文件和分组预检查/删除/查询，旧 Web 单文件/分组删除及自动清理共用同一协调层。所有业务页仍复用面板 session/CSRF 和恢复门禁；不删除任务、脚本、历史或备份。

## 后端实施顺序

1. **先收口文件协调。** 在恢复范围外按日志 basename 的哈希建立跨进程共享写入/读取和独占删除 lease。所有内部写入从打开前至最后 flush/close 持共享 lease，短追加和长作业复用同一实现；不同 worker 删除只能在独占成功后核对版本。先取得恢复访问权限，再按文件名排序取得日志 lease；不持历史/storage 锁等待日志锁。等待和失败保持有界，读取 GET 只探测已有锁，不创建/退役业务回执。
2. **监管延续至句柄关闭。** 普通任务/脚本调试/在线安装的独立监管必须在 owner 强退后继续持对应日志 lease，不能只锁 Python 文件对象。监管构造/启动门/继承失败有回归；命令结束、writer/reader/finally 结束前不释放。外部不遵守该协议的程序不视为受协调的内部 writer。
3. **逐入口接入。** 普通任务首次打开及 `_append_log`、调试运行及补写、`online_scripts/logs.py` 的短追加和安装、`routes/deps.py`、`routes/runtime.py`、备份后续依赖、`routes/about/helpers.py`、`frontend_events.py` 都要追踪实际打开/关闭与后台交接。日志读取/下载关闭前持共享 lease；Web 与自动清理使用同一独占删除 helper。自动清理遇活跃文件跳过并计数，不能因文件过大截断正在写入的日志。
4. **实现固定目标快照和持久回执。** 预检查固定文件清单、各版本、分组版本和大小；删除只处理该快照，不在提交时重新扩展分组。回执保存在 data/log 恢复范围之外，先持久化准备/逐项删除意图，再执行 unlink 和保存结果。坏回执/超限/持久化失败保留原文件和未知结果，不能静默覆盖或重建。
5. **再接 APP。** 服务端契约与 worker/故障测试通过后，新增严格 DTO/manager 和原生预检查/结果页；完成单文件、多选、分组以及原请求恢复，再推送配对版本验证。

### 入口监管与剩余交接

已核对实际创建和关闭路径，下一批沿用现有 `DirectoryProcess` 能力，不重复改造已接入的普通任务、调试和在线安装。

| 入口 | 当前行为与接续要求 |
| --- | --- |
| `routes/deps.py` 的异步安装、原生卸载及重试；`routes/runtime.py` 的安装 | `f5aacbd` 已接统一监管适配，在启动门前接管日志/恢复 lease，整树和继承输出退出且临时目录清理成功后返回终态；原请求、取消与重试链语义保留，实际平台证据见上段 |
| `routes/deps.py` 的取消与结果轮询 | `f5aacbd` 保留原子取消认领，适配器将 terminate/kill 转为关闭 owner 通道；父日志关闭失败保留原状态/句柄。旧自然完成、超时、重试和终态回执失败断言保留 |
| `routes/deps.py::deps_uninstall` 的 Web 卸载 | `5977c73` 已复用现有卸载作业，完整双平台 CI 通过；表单原 ID、库存/冲突/回执及日志页共用，不再同步 pip_cmd，无平行取消/重试协议 |
| `routes/backup/_common.py::install_dependencies` | `f574248` 已接监管独立守卫和二次确认，原主锁持有期间交接，所有主锁受理探测 guard；owner 强退后先停整树/关日志再退 guard。该 SHA 双平台新增监管通过，但完整 Native 有上述 Windows 夹具失败；后续新 SHA 重新验证，不用局部成功代替整体 |
| `routes/about/helpers.py::run_fls_control_later` 与 shell/PowerShell 启动器 | `f85b87b` 已实施独立管道收集，实际 file writer 只在最后一个输出端 EOF 后释放 lease；固定 daemon 文件不持长期恢复锁，systemd transient builder 保留。Windows 真实启动红用例由 `f907e6c` 补普通文本流交接并经平台/打包验证；其他实例锁/WAL/断电边界仍未完成 |

`9aeff36` 已将 Windows 普通任务回归拆成独立短作业，与其余 12 个 Windows 检查及完整 Linux 回归并列，13 个原测试命令逐字保持，没有 continue-on-error。这样可在任务 job 终态后立即读取失败现场，不必等待在线安装/任务源全部结束；未通过的候选继续保留原工作流终态，不中途取消后改写证据。

## 后端 API 与 APP 接续

| 操作 | `e1c4083` 已实现契约 |
| --- | --- |
| 能力/列表 | `GET /api/logs/cleanup/capabilities` 返回 supported、max_files、max_groups、preview_ttl_seconds；日志列表增加文件 version/busy。APP 仅在独立能力端点明确不支持时降级，不把普通 401/403/业务 404 当成版本不兼容 |
| `POST /api/logs/cleanup/preview` | 只预检查，不删除。最多 20 个分组或 200 个显式文件，每次快照最多 200 文件；超限必须缩小选择，不静默截断。返回 preview_id、固定清单/版本、数量/字节、busy/冲突、10 分钟有效期 |
| `POST /api/logs/cleanup` | request_id、preview_id 和快照摘要绑定；确认后重新核对原目标版本/独占 lease，逐项返回 deleted/missing/busy/conflict/failed/unknown。预检查期间新建的同组文件不纳入删除；不同参数复用 ID 拒绝 |
| `GET /api/logs/cleanup/requests/<request_id>` | 真正只读，返回原请求及逐项状态，不重扫扩展目标、不清理、不写回、不重试。GET 未找到与结果未知分开，不能据此自动再 POST |
| `POST /api/logs/cleanup/requests/<request_id>/reconcile` | 显式核对原目标，不执行 unlink；缺失只证明当前不存在，同名替换返回 conflict，仍为原对象而无法证明结果时保留 unknown。需要再次删除时重新预检查并确认新请求 |

请求字段严格解析并限制实际 JSON 字节，拒绝重复字段、未知字段、路径分隔符、NUL、目录/符号链接/junction 和非 `.log` 对象。打开目录/文件后核对父目录及对象身份，不能仅用 resolve 后的路径重开。预检查、提交与最终回执保存全过程和目录恢复互斥；部分完成不回滚已删除的日志，也不误报整组成功。

逐文件删除意图必须先落盘。若 unlink 后进程强退或终态保存失败，重复提交相同 ID 只返回原不确定状态，不再删除；GET 不退役现场。锁只证明内部协作期间没有并发 writer，版本及父目录身份仍须在真正删除前检查。同名新文件不能被当作原文件重试删除。

## APP 流程

在现有记录/日志列表增加多选和分组选取，文件详情提供删除命令。预检查页展示当前面板、固定文件/分组、数量/字节和活跃/冲突项，确认后再提交；结果逐文件展示，部分失败可返回列表核对。分组和多文件结果分页/有界渲染，保留原有日志搜索与下载。

提交前保留面板身份和原 request_id；响应丢失后只查询原 ID，unknown/missing 不开放自动重发。当前会话允许关闭页面后重新查询；跨 APP 进程持久恢复由 M5 统一实现，不把会话内恢复写成完成。切面板、旧回包、当前/旧 401、后台隐藏和离页取消轮询沿用既有 generation 模式；离页不取消已受理的服务端操作。

## 验证与退出条件

- API/session/CSRF/权限、字段/容量/过期、GET 零写入、坏回执、初/终回执保存失败及同 request_id 并发竞争。
- 真实双 worker 写入与删除互斥、不同文件可并行、停止后的最后日志关闭、owner 强退的监管 lease、自动清理跳过活动文件、Web/原生竞争。
- 预检查后增长/替换/同组新增、同名同大小同 mtime 的不同对象、目录替换、链接/特殊文件、unlink 前/后失败、逐项部分成功和进程强退。任何恢复只作用于原目标。
- APP 单文件/分组/多选、真实预检查确认、逐项结果、超限/旧后端、失联只查原 ID、401/面板切换/后台与窄屏大字 Widget；保留现有读取/下载回归。
- 两仓递增实际变更版本、仅提交推送 develop；记录一对 SHA、Linux/Windows 最终回归及 Android 全测试/APK。用户手动验收单列，不做 ADB/模拟器。

本批通过只关闭日志域缺口，随后继续 B3 其余要求、B4、M4-M7 全量导航/主题与最终验收；不得据日志或打包单批通过合并发布。
