# 普通任务执行监管与 APP 状态

## 当前候选

2026-11-28 已按 FLS、APP 顺序同步两个 develop。普通任务实现 `f84388aa0f4c6d7f5191b319f8fcddd767184b2a`，早期 Windows 修正 `4f47e9ef8889fc8f4a7414eddf5d4e6c313a1ccc`；日志后端基线 `e1c4083` 的 Native `46085389388` 完整双平台及三项打包成功。APP 最新 APK 为 `99d1c9b` / `0.1.75+89`，Android CI `46088657554` 格式/分析、286 项测试和 APK 成功，新增清理与首轮失败见 [日志规格](PANEL-LOG-CLEANUP-PLAN.md)。最新实例锁后端 `78c2632` / `20261128.17` 由新 CI 验证中，见备份规格。B3/B4 未完成。

最新修复：`da93db1` 的 Native `46064429360` 在 Windows 稳定复现持旧回执读取句柄期间另一个 worker 的 os.replace 报 WinError 5；该轮 Linux 1141 项/1031 subtests 通过，Windows 12 项任务/46 subtests 及其余独立步骤通过，不能忽略新增用例失败。`5e2c762` 改用允许 READ/WRITE/DELETE 共享并拒绝最终 reparse point 的读取句柄，但 Native `46066990491` 仍失败：Linux 1147 项/1031 subtests 通过，Windows 持句柄及手动替换重试失败（2 failed/13 passed/46 subtests），其余步骤及三项打包通过。现场重试计划明确被 os.replace/WinError 5 中断，读取共享不是完整修复。

`9aeff36` 将发布改为 FileRenameInfoEx 的替换/POSIX 语义：已同步的私有临时文件用 DELETE 权限打开、检查最终源句柄后一次替换，旧句柄继续读取旧对象；保留大小、常规文件、reparse 拒绝与 POSIX NOFOLLOW/NONBLOCK，错误关闭 FD 并清理临时文件。保留原红测试，新 Unicode（含双 UTF-16 码元）路径/旧对象读取和发布失败保留回归本机 5 项通过，相关 6 文件 97 项/72 subtests 通过。Windows 任务拆为独立 job，13 个原命令及 Linux 覆盖不变；Native `46071964294` 最终完整成功，Linux 1149 项/1031 subtests（1 跳过、2 既有 tar 警告），Windows 任务 17 项/46 subtests 及其余 12 步全部通过，三项打包成功。异步依赖 `f5aacbd` 与 Web 卸载 `5977c73` 的完整 CI 也成功。后续恢复夹具和真实启动失败/修正见 [日志清理规格](PANEL-LOG-CLEANUP-PLAN.md)：`f907e6c` 的真实启动/打包成功，完整 Native `46083027529` 因旧依赖结果读取 PermissionError 失败。`e1c4083` 抽取共同 receipt_io 修正结果交接，完整 Native `46085389388` 最终成功，包含原红回归。

## 后端执行与恢复

`task_execution_coordination.py` 在首次历史和日志之前取得共享恢复 lease 和真实运行身份，覆盖随机延迟、手动/调度启动、独立命令监管、重试等待、通知、日志关闭及 finally。不同 worker 只能受理同一任务的一次执行；定时入口使用真实 `scheduler_run_once` 路径验证。

每个任务的运行回执位于恢复范围之外 `BASE_DIR/.task_executions/<sha256(task_id)>.json`。回执只含任务/历史身份、阶段、停止意图、日志 basename 和重试前驱 ID，不保存环境值或命令正文；实际读取最多 16 KiB + 1，校验常规文件并拒绝链接。私有临时文件经 fsync、原子替换发布，POSIX 同步目录项；Windows 断电持久性仍属后续验证。

查询只读取回执和探测身份，不退役或修复现场。失去身份的活动回执显示 unknown；缺失或损坏的活跃回执不能当成空闲后重复启动。重试的 previous_history_id 处理旧 watcher 与新运行交接，不能误判前驱身份缺少回执。所有历史读改写通过跨进程事务保留其他 worker 的更新；startup reconciliation 在事务内重新核对身份，不覆盖另一 worker 的真实活动历史。

命令复用 `DirectoryProcess` 的独立监管及 Windows Job Object。面板 owner 强退后，监管仍持身份和恢复 lease，直到命令树退出及继承日志关闭。停止请求先持久化，由 owner 消费；另一 worker 不凭 PID 发信号。停止受理只表示已请求，清理期间仍 active。重试等待持身份/lease，前驱历史和日志不确定时取消自动重试；手动运行可取消远端待重试后重新受理。

线程构造/start 和 watcher 交接失败保留 fallback，已经启动的线程不能再重复 fallback；启动历史、终态历史或回执失败均保留 unknown 并释放可释放的资源。删除任务同时检查 active，不能仅凭命令进程已退出删除清理中的任务。

## API 与 APP

| 接口 | 本批行为 |
| --- | --- |
| `GET /api/task/<id>` | runtime 增加 history_id、active、stop_requested 和执行阶段，区分 retry_wait、stopping、unknown 与终态 |
| `GET /api/tasks` | 摘要增加 execution_status，APP 列表显示延迟、等待重试和正在停止，隐藏占位 PID |
| 既有任务停止 API | 返回已请求停止；未完成清理时保持活动状态，不能据 HTTP 200 推断进程树已退出 |
| 任务日志 Web/API | 远端 worker 按原运行回执绑定的日志 basename 读取；读取保持恢复门禁，不依赖本进程 RUNNING |
| 日志文件下载 | 实际最多读取 8 MiB + 1，超限拒绝且关闭句柄，不先全量 read_bytes |

APP DTO 对可选 active/stop_requested 严格校验 bool，兼容旧后端缺少字段。任务详情活跃时每 2 秒只读刷新详情和日志，终态清理结束后停止轮询；非当前路由不发轮询，离页取消 timer。manager/task 切换按 generation 丢弃旧响应；当前 401 隐藏内容、停止轮询并只通知一次，旧 401 不影响新面板。后台隐藏任务、变量及日志，恢复前台重新读取，迟到日志不显示。

## 验证证据

- 后端新增 9 项真实 worker 回归，覆盖同任务竞争、远端停止/原日志、owner 强退整树、重试等待/取消、实际定时回调、自动重试、初回执/坏回执/历史失败、延迟停止、不同任务历史并发和手动替换远端重试。
- 新增 3 项日志回归及 40 个子用例，覆盖四种恢复占用下全部任务/系统日志入口、增长文件的实际有界下载，以及最后日志关闭期间仍持身份/恢复门禁。
- 本机扩展 14 文件 207 项/138 子用例通过；最终 worker/日志/发布说明 14 项/46 子用例通过，另一扩展 5 文件 114 项/86 子用例通过。测试夹具等待真实任务清理再销毁临时目录；缓存断言改为验证读取缓存及实际写后计数，保留业务结果。
- 首轮 FLS [Native 46050302153](https://github.com/liyw0205/fls/actions/runs/46050302153) 总体失败：Linux 1113 项/1018 子用例通过、1 项 Windows 专用跳过及 2 条既有 tar 警告；Windows 新任务步骤 10 项/46 子用例通过、2 项失败，后续独立导入和任务源步骤 skipped，不能记为双平台成功。三项打包 [Module 46050302061](https://github.com/liyw0205/fls/actions/runs/46050302061)、[Desktop 46050302188](https://github.com/liyw0205/fls/actions/runs/46050302188)、[EXE 46050302046](https://github.com/liyw0205/fls/actions/runs/46050302046) 成功且正式 Release skipped，仅证明 `f84388a` 的构建。
- `4f47e9e` 修正 Windows 长短路径下增长文件夹具未命中的问题，保留实际 8 MiB + 1、超限及句柄关闭断言；手动替换重试改为先观察新的手动尝试已进入 retry_wait，再核对唯一自动重试和最终清理，仍要求三次真实执行及精确历史来源，失败保留阶段观测。
- 最终 [Native 46052747897](https://github.com/liyw0205/fls/actions/runs/46052747897) 双平台成功：Linux 配置的完整回归为 1113 项/1018 子用例通过、1 项 Windows 专用跳过及 2 条既有 tar 警告；Windows 新任务步骤 12 项/46 子用例通过，其余全部配置步骤通过，保留原有平台筛选/跳过项。两 job 分别为 `140687827237`、`140687826855`，均核对 `4f47e9ef8889fc8f4a7414eddf5d4e6c313a1ccc`。
- 同 SHA 的三项打包 [Module 46052747943](https://github.com/liyw0205/fls/actions/runs/46052747943)、[Desktop 46052747902](https://github.com/liyw0205/fls/actions/runs/46052747902)、[EXE 46052747891](https://github.com/liyw0205/fls/actions/runs/46052747891) 已成功，三个正式 Release job 均核对为 skipped。开发产物分别为 `15225640354`、`15224678606`、`15225236917`，不是正式发布。
- APP 新增 1 项 DTO 与 4 项 Widget，本机 format/analyze 通过。首轮 [46050330646](https://github.com/liyw0205/fls-for-android/actions/runs/46050330646) 为 267 项通过/1 项失败：新详情出现而日志 HTTP 流仍未结束时直接 pumpAndSettle 超时。`269c16c` 先确认旧请求已受理、等待新日志流结束，再等待旧 manager 真正捕获 401；保留新任务、旧内容隔离、401 和回调次数断言。
- 修正后 [Android CI 46051131340](https://github.com/liyw0205/fls-for-android/actions/runs/46051131340) 全部成功：格式、静态分析、268 项测试、arm64 APK 构建及 develop 上传，正式 Release skipped，核对 `269c16c`。[APK artifact 15224009353](https://github.com/liyw0205/fls-for-android/actions/runs/46051131340/artifacts/15224009353) 为 11,136,402 字节，到期于 2026-12-11 18:47:04 UTC。此大小为 artifact 归档大小，后续文档提交不改变 APK 构建 SHA。
- 已取回开发 APK：`build/develop-0.1.73+87-269c16c/app-release.apk`，本体 11,483,305 字节，SHA-256 为 `7834ac8bf65cdfc4bdc4fd87b6d994415e42c8fd40383e46ec363a00d03b90f7`。包名 `top.fls.fls_for_android`，versionName `0.1.73`、versionCode `87`；仅提供用户手动验收，不自动安装。
- 未执行 ADB/模拟器、稳定面板部署或用户手动验收，不将本机聚焦测试写成全量平台通过。

## 手动验收与接续

使用配对 develop APK 和隔离面板：启动带延迟和失败重试的任务，核对列表/详情状态和同次日志；另一 worker 请求停止，观察停止受理到最终清理；切面板、后台返回和重新登录时不显示旧任务/日志。真实强退与恢复冲突只在隔离测试数据上验证。

按 [日志原生清理规格](PANEL-LOG-CLEANUP-PLAN.md) 收取 `e1c4083` 的完整平台验证，再接 APP 单文件/多选/分组预检查、版本绑定确认和原请求恢复；后端 API 已实施，不重复开发。继续逐域 busy、Windows 实例锁/WAL/断电、多 worker 依赖清理、坏回执维护与 APP 备份完整流程，最后 B4 和 M4-M7。监管自身强退、逃离进程组、外部任意文件写入等未验证边界不扩大为已完成。两个 main 及正式更新渠道保持不动。
