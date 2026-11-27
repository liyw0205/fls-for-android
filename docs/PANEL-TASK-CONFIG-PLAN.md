# 任务配置文件原生编辑

## 当前候选

2026-11-28 先同步 FLS、再同步 APP 的 `develop`。FLS `5ce38a1` / `20261128.1`（156）；APP 实现 `f9597d7`，修正 `77902df` / `0.1.71+85`。本批只关闭任务配置内容编辑缺口，不代表普通任务运行监管、日志清理、M3 B3/B4 或全量原生前端完成。

## 契约与恢复

| 操作 | 接口与行为 |
| --- | --- |
| 读取 | `GET /api/tasks/<task_id>/config-file` 返回 task_id、任务绑定的相对 path、content、revision、exists、max_bytes；缺文件返回空内容及独立缺失版本，不创建文件 |
| 保存 | 同一路径显式 `POST`，仅接受 request_id、path、expected_revision、content；以任务当前路径和文件版本重新核对，保存只修改配置文件，不运行任务或重载调度器 |
| 查询原提交 | `GET /api/tasks/<task_id>/config-file/requests/<request_id>` 返回 saved/not_saved/unknown/missing；核对任务和原请求身份，无配置明文，不发布、不修复回执 |
| 冲突 | revision 或任务路径变化返回 409/saved=false；APP 保留草稿，重新 GET 当前配置，明确对照采用当前内容或保留草稿合并后才开放新保存 |
| 结果未知 | prepared、进程强退及最终回执丢失不推断成功。相同 ID/内容只返回原结果，不重复发布；不同任务或内容复用 ID 返回冲突 |

认证沿用面板 session/CSRF，响应为 no-store。UTF-8 内容最多 1 MiB，实际文件读取同样有界；请求 JSON 最大约 6 MiB，允许 JSON 转义开销但不放宽内容字节上限。保留 CRLF、权限/owner、原子替换及临时清理语义；任务/路径和重命名现场须先核对，目录恢复占用或坏现场返回可识别 busy。

回执为 `BASE_DIR/.task_config_requests/<request_id>.json`，不随 data/scripts 恢复回滚。保存前私有 0600 临时回执经 fsync/原子替换发布；HMAC 校验状态、请求/任务/path 与请求指纹，明文配置、草稿和明文内容摘要不落回执。POSIX 同步目录项；Windows 当前不声明已验证断电持久性。终态回执成功意味着原提交曾保存，不意味着当前文件未被后续操作修改。坏回执不能当作缺失或覆盖重建。

`TASK_FILES_LOCK` 将任务规范化写回、任务修改、Web/原生配置保存及交互式脚本文件操作串行化，防止不同 worker 改变任务路径后旧编辑器继续发布。顺序是 TASKS_MUTATION_LOCK → TASK_FILES_LOCK → storage；已规范化的任务只读路径继续读取上一份完整原子发布，不等文件保存。此锁不代表普通任务进程、自动重试、Git/归档异步作业及所有外部文件写入均已完成协调；这些仍按 B3 后续方案推进。

## APP 行为

任务详情的“编辑配置内容”打开 `PanelTaskConfigView`；使用服务端绑定路径，不解析 Web HTML。原生编辑器支持缺文件创建、重读、草稿对照/合并、保存和原提交查询。未确认保存时不自动 POST，保存按钮禁用；查询得到 unknown/missing 后，可显式对照当前文件结束核对，随后基于当前 revision 另行保存。采用当前内容会明确替换草稿，保留草稿合并不会保存文件。

待查询 ID 按 task_id 保存在当前 `PanelTasksManager` 会话内；重新进入同一任务先查询原请求，不保存敏感草稿。APP 进程退出、重新创建面板 manager 或实例替换后的统一恢复仍归 M5，不能把本批会话内恢复称为跨进程恢复。当前 401 隐藏内容、保留原 ID；旧面板/旧任务回包按代次丢弃。后台隐藏正文并关闭内容对话框。窄屏/大字采用可滚动布局，离开未保存草稿需要明确确认。

## 验证记录

- FLS 新增 10 项测试：session/CSRF、缺文件、精确内容和权限、无明文签名回执、只读查询/重放、任务路径冲突与待恢复重命名、并发保存、失联/坏回执/超限/UTF-8、恢复锁覆盖终态，以及独立 worker 在发布前后真实强退及路径修改互斥。
- 本机修正后配置/脚本/worker/目录恢复等八文件 79 项/107 子用例通过；任务/合集/存储与发布说明等十文件 107 项/84 子用例通过。首轮扩展的 1 项失败是正常任务读取误等发布锁，已改为只读不等待、写回重读后加锁，保留原断言。
- FLS [Native 46035359025](https://github.com/liyw0205/fls/actions/runs/46035359025) 双平台成功，核对 SHA `5ce38a1c7f9f8b67dcdb4de93b5b6b72d1ee0c2a`。Linux 1027 项/937 子用例通过、1 项 Windows 专用跳过、2 条既有 tar 警告；Windows 配置步骤 15 项/29 子用例通过，其他全部步骤成功（调试 42 项/23 子用例、在线安装 181 项/134 子用例、独立导入 66 项/76 子用例、任务源/刷新 204 项/152 子用例，平台专用跳过不计通过）。
- FLS 三项打包 [Module 46035359023](https://github.com/liyw0205/fls/actions/runs/46035359023)、[Desktop 46035359016](https://github.com/liyw0205/fls/actions/runs/46035359016)、[EXE 46035359031](https://github.com/liyw0205/fls/actions/runs/46035359031) 全部成功，正式发布 skipped，均核对 `5ce38a1`。隔离产物为 [Module 15215334420](https://github.com/liyw0205/fls/actions/runs/46035359023/artifacts/15215334420)、[Desktop 15215474305](https://github.com/liyw0205/fls/actions/runs/46035359016/artifacts/15215474305)、[EXE 15216556772](https://github.com/liyw0205/fls/actions/runs/46035359031/artifacts/15216556772)，到期均为 2027-02-25 16:38:48 UTC。
- APP 新增 3 项 manager/API 校验与 7 项 Widget，加已有任务详情入口验证；本地 format/analyze 通过，Flutter tester 由 Actions 执行。首轮 [46034525366](https://github.com/liyw0205/fls-for-android/actions/runs/46034525366) 259 项通过/3 项失败，RawTooltip finder 转换错误已修正，保留禁写断言；API 客户端另补白名单冲突码，重新 GET 当前内容，不保留错误中的配置明文。
- 最终 [Android CI 46036472144](https://github.com/liyw0205/fls-for-android/actions/runs/46036472144) 成功，核对 SHA `77902dfdc6bff592c20c3ef3063035e599ab3c2b`：格式、分析、263 项测试、arm64 APK 及 develop 上传通过，正式发布 skipped。[APK artifact 15219670638](https://github.com/liyw0205/fls-for-android/actions/runs/46036472144/artifacts/15219670638) 为 11,131,462 字节，到期于 2026-12-11 16:54:15 UTC；版本 `0.1.71+85`。
- 未执行 ADB/模拟器、稳定面板部署或真实面板手动验收。

## 手动验收与接续

用配对 develop APK/FLS 隔离实例核对：任务详情进入配置；缺文件保存创建；Unicode/CRLF；另一页面改同文件或任务路径后保留草稿合并；保存失联只查询原 ID；关闭页面重进同会话恢复；当前 401、切面板和后台隐藏。故障注入不在稳定面板执行，测试结果反馈不阻塞普通任务运行/日志等下一批开发。

接续记录：普通任务首次历史/日志、延迟/定时、独立监管、retry/持久停止及日志关闭已在 FLS `f84388a` 实现；Windows 修正 `4f47e9e` 与 APP `269c16c` 的实际 CI/APK 见 [任务执行规格](PANEL-TASK-EXECUTION-PLAN.md)。实际有界下载也已补，下一批按 [日志清理规格](PANEL-LOG-CLEANUP-PLAN.md) 实现原生清理及全 writer/reader/自动清理协调，随后收尾 B3 其余并推进 B4、M4-M7。两仓维持 develop，全量原生与用户验收完成前不合并 main、不正式发布。
