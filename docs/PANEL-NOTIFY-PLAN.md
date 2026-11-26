# 通知域原生迁移规格

## 范围与源码基线

M2 接续代理诊断。2026-11-26 静态核对 FLS develop `1344fa5` 的 `fls_manager/notify.py`、`notify_actions.py`、`notify_test_actions.py`、`notify_retry_actions.py`、`routes/notify/` 和 `routes/api.py` 后开发。渠道配置子批 M2a 已实现，候选及验证见下节；发送、投递历史和重试仍待 M2b，不能把配置交付标成通知域或全量 Goal 完成。

范围覆盖渠道列表/搜索/详情、新增/编辑、启停/删除、默认渠道、完整/裁剪日志模式、测试发送、投递历史/正文/状态和重试。远程/本机面板共享原生页面；FLS Web 继续兼容。保留全部 13 类渠道：Bark、Server 酱、PushPlus、Telegram、企业微信、钉钉、飞书、SMTP、Ntfy、WxPusher、Gotify、PushDeer、自定义 Webhook。

## M2a 渠道配置候选

FLS `115f42a5107cc74af164a0af9b34739618bb5c08` / `20261126.9` 已推送 develop；18 项新增测试与旧通知操作/保存/测试/重试恢复、存储回归共 101 项通过。[Module](https://github.com/liyw0205/fls/actions/runs/45788090767)、[Windows Desktop](https://github.com/liyw0205/fls/actions/runs/45788090909)、[Windows EXE](https://github.com/liyw0205/fls/actions/runs/45788090757) 打包工作流成功，Release job 均跳过。

APP `f76ac26` 及修正 `78c5e62`、`efc61f9` / `0.1.51+64` 已推送 develop，从面板选项的“通知渠道”进入原生列表、schema 表单及跨页默认渠道选择。支持搜索/渠道/启用筛选、分页、新增/局部编辑/明确启停/删除、配置冲突合并、默认选择冲突核对，以及原请求只读恢复。首轮 CI `45788527037` 格式/分析通过，194 项测试通过、4 项失败：一项暴露子路径部署时通知错误未脱敏，已修正；另三项为异步请求等待与生命周期模拟顺序。第二轮 `45791137092` 仅余生命周期测试缺少 hidden 状态，已补齐完整切后台/恢复顺序。第三轮 [45792447615](https://github.com/liyw0205/fls-for-android/actions/runs/45792447615) 已通过格式/分析/198 项测试和 arm64 APK 构建，[artifact 15104560000](https://github.com/liyw0205/fls-for-android/actions/runs/45792447615/artifacts/15104560000) 对应完整 SHA `efc61f95c8e673f31101b6d3aae71f929937b40f`，到期于 2026-12-10 09:36 UTC；正式 Release 步骤跳过。前两轮失败不记为验证通过。

| 已实现方法与路径 | 输入、输出及副作用 |
| --- | --- |
| `GET /api/notify/settings/schema` | 13 类渠道字段的 label/kind/options/sensitive/multiline/max_length，以及完整/裁剪日志模式；不抓 HTML |
| `GET /api/notify/settings` | q/channel/enabled/page/limit；limit 最多 100，默认 50；只按名称/渠道搜索，摘要不含渠道配置或接收目标 |
| `GET /api/notify/settings/<id>` | 白名单设置、单渠道 version、字段是否配置、公开值、旧格式异常标记、任务引用总数/最多 50 项 |
| `GET /api/notify/settings/defaults` | 最多 1000 个默认 ID 与覆盖全部渠道及默认选择的 version；选择可跨页保留 |
| `POST /api/notify/settings` | action=new/edit/toggle/delete/default、request_id、非新建 version，按操作附 item_id/settings/values/credentials/default_ids/enabled；保存不调用 sender |
| `GET /api/notify/requests/<request_id>` | 校验原生签名回执，只读返回 saved=true/false/null、historical/current_matches、retry_allowed/confirm_required；不重做保存或发送 |

请求上限 64 KiB，拒绝重复 JSON 键、未知字段和重复查询参数；request_id 为 32 位小写 hex，version 为 64 位 hex。普通公开字段限 500 字符，敏感字段限 4096，Webhook headers/body 限 16384 并支持换行。公开字段只有分组/声音、模板、SMTP SSL/发件人名称、优先级、Webhook method/content-type；其余一律只写，包括所有 URL、目标、Topic、邮箱及密钥。凭据格式为 `credentials: {field: {action: keep|replace|clear, value?: string}}`；values 仅含公开字段，settings 仅含 name/channel/log_mode/enabled。未知扩展字段在同渠道编辑时保留；跨渠道需 `reset_channel=true`，清除全部旧渠道字段，不携带旧凭据。

配置变更沿 TASKS_MUTATION_LOCK → storage transaction；任务自定义引用阻止停用/删除，默认引用在停用/删除后移除。原生回执绑定稳定请求意图、scope、版本及 HMAC 签名；旧 Web 请求不可重放原生回执。完成记录表示历史保存成功，current_matches 单独表示当前配置是否仍相同；缺失、损坏或无法证明的 prepared 结果继续未知。配置回执未自动清理，与旧通知保存回执共用目录，后续统一恢复/保留策略在 M5 核对。

APP 凭据与草稿只在编辑页内存，后台隐藏、回到前台仍遮挡；退出/401 清理编辑内容，未确认 ID 留在当前面板内存，跨 APP 进程恢复尚缺。真实隔离面板手动验收待用户，不做 ADB。发送/历史/重试仍通过显式 Web 入口备用，尚未原生迁移。

## 已有能力与缺口

| 源码 | 已有行为 | 原生迁移要求 |
| --- | --- | --- |
| `notify.py:NOTIFY_CHANNELS` | 各渠道字段、标签和默认说明 | 输出结构化 schema；控件类型/选项来自字段规则，禁止 APP 抓取 HTML |
| `routes/notify/_common.py` | 各渠道表单、完整/裁剪日志、默认渠道选择 | 密钥不读回；Webhook URL/headers/body、收件目标等不能仅靠字段名判断是否敏感 |
| `notify_actions.py` | new/edit/default/toggle/delete、版本、任务引用、保存回执、可选保存后测试 | 原生局部字段与 keep/replace/clear 在锁内解析；原生回执签名并绑定稳定意图；默认选择与单渠道版本均需核对 |
| `notify_test_actions.py` | request ID 推导固定 delivery ID，先落盘再发送，prepared/sending/completed，正文为固定测试通知 | 拆出只读原请求查询；不得通过重调提交函数来轮询；超时后禁止自动发送 |
| `notify_retry_actions.py` | 原投递版本/attempt 校验，显式渠道重选，claimed/completed 回执；重试会递增同一投递 attempt | APP 明确显示原尝试与本次尝试，按原 request ID 恢复；不能沿用代理检测“新历史行”假设 |
| `notify.py` 的 history | 最多 300 条，保留运行中/未知记录；正文最多 12000 字符并标截断；读取可能写回恢复状态 | 增加有界分页、安全摘要与显式正文读取；历史 GET 不投递，损坏记录不清空或误报成功 |

现有 `/api/notify/history` 直接返回正文和消息，可能包含任务日志、凭据或上游错误；原生不直接渲染整个响应。既有发送/重试仍同步等待网络，应先核对所有渠道的超时、消息分块和部分发送语义，再确定异步启动边界。测试服务已在网络 I/O 前释放历史和存储锁，不能在包装新 API 时重新把锁持有到网络结束。

## 待固定契约

下表前 3 项已按 M2a 固定并实现；后三项在 M2b 中固定，不能根据草案假定已有接口：

| 能力 | 输入与输出要求 |
| --- | --- |
| 渠道 schema/列表/详情 | 安全分页摘要、类型及字段选项、配置版本、默认选择、任务引用；敏感值仅返回是否设置 |
| 局部配置写入 | 显式 new/edit/toggle/delete/default，request_id、expected version、字段变更和逐字段 keep/replace/clear；禁用/删除仍保护任务引用并处理默认选择 |
| 原配置提交查询 | 只读校验回执与当前配置；历史已保存和当前匹配分开，未确认结果不自动重放 |
| 测试发送启动/查询 | 当前渠道版本、独立 request_id；先受理再查询结果，不能把保存成功等同于通知发送成功 |
| 历史/投递详情 | 有界分页和渠道/状态筛选；摘要不包含正文/收件秘密，正文显式读取且脱敏、标记截断；详情附当前 attempt/version |
| 显式重试/原请求查询 | 绑定 delivery ID、expected_attempt、version、新 request_id；渠道变化或重新选择渠道时先展示并确认当前配置 |

原生保存不附带隐式测试发送，保存与测试分别显示结果。测试发送/投递重试由用户在 APP 明确发起；开发测试使用注入 sender，不向真实通知接收人发送消息。

渠道字段按 schema 逐项设置：密码、Token、Key、Webhook headers/body、携带秘密的 URL/目标采用只写意图；普通文本、布尔和枚举按实际类型提供控件，未修改时保留服务器值和未知扩展字段。切换渠道不能将上个渠道凭据带入新配置；清理规则需明确确认并覆盖测试。

并发与恢复沿现有两套锁顺序分别设计：配置 mutation 使用 TASKS_MUTATION_LOCK 后 storage transaction；投递服务使用 NOTIFY_HISTORY_LOCK 后 storage transaction，网络不持锁。新共享 helper 不得形成反向获取锁。回执只存签名/指纹和状态，不存渠道秘密；查询不能调用 sender、claim 或 mutation。

failed、unknown、部分分块已发出和上游受理不能合并成一个可自动重试的失败态。若现有发送器无法证明未投递，APP 先要求核对接收端，再提供显式新尝试。详情被历史保留策略清理时，只读回执仍须能区分历史结论与明细缺失。

## M2b 已核对的发送边界

M2a 构建期间继续核对 `send_one`、`send_by_ids` 与既有测试/重试服务：13 类渠道的单次 HTTP timeout 为 15 秒或 20 秒，SMTP 为 20 秒；这些是网络阶段超时，不是整个作业的总时限。现有 HTTP 直接读取 JSON/正文，不能把单次 timeout 当成响应大小或总执行时间上限，原生异步实现仍需明确并发、队列、响应读取及工作线程生命周期。

`send_by_ids` 在调用发送器前按完整/裁剪日志模式分块，每个分块分别创建投递历史；`send_one` 自身只处理一次发送。固定测试通知不走任务分块，重试沿历史保存的单条正文重发，不能把一个分块的成功显示成整条任务通知全部发送成功。历史正文已有 12000 字符截断标记，重试截断后的正文前必须明确告知。

多数发送器仅返回 `(ok, message)`，message 可能包含上游原始响应、URL 或凭据；failed 也不能证明接收方未受理。原生 DTO 应输出稳定结果类别并明确上游受理语义，保留 unknown/可能已发送提示，不能仅凭 bool=false 自动再次发送。历史列表不返回正文或原始 message；正文按用户明确查看请求脱敏后返回。测试/重试与原请求查询应共享持久化身份及状态规则，但 GET 不能调用现有同步 submit 函数来补做投递。

## M2b 可执行任务与退出条件

以下是后续开发任务，不是现有 API；路由名称在对应后端提交中固定，再更新契约表。

| 子步 | 实施内容 | 退出证据 |
| --- | --- | --- |
| B1 发送器与受理边界 | 明确并实现 HTTP 响应读取上限、重定向/超时规则、SMTP 边界、作业并发/等待上限和线程退出处理；共享发送逻辑保留旧 Web 支持的 13 类渠道，不用无限线程包装同步接口 | 注入 HTTP/SMTP/时钟，验证慢响应、超限正文、阻塞作业、队列满和单渠道失败；不会因前端超时再启动 sender |
| B2 原生启动与持久回执 | 测试绑定当前渠道 version；重试绑定 delivery ID、expected_attempt、投递 version 和当前选中渠道 version。先持久化意图再占用投递，网络不持锁；回执隔离原生/旧 Web 作用域，不存凭据或正文 | 存储失败、线程启动失败、重复 ID/不同意图、并发重试、发送后落盘失败、重启未知；一次请求最多一次实际发送 |
| B3 只读查询与历史 | 原请求查询独立于提交函数；历史安全分页/筛选，详情附 attempt/version，正文显式读取/脱敏/标记截断。重试沿同一投递递增 attempt，历史回执结论与当前明细分开 | GET 不调用 sender/claim/mutation、不写恢复文件；损坏记录、已清理明细、后续 attempt、重启未完成均不误报当前成功 |
| B4 APP 生命周期 | 渠道列表增加明确测试确认，独立投递历史/详情/正文查看及显式新尝试；失联保留原 request ID，401 后重新登录只查询；离页只停轮询 | manager/widget 覆盖成功/失败/unknown、保存不发送、断网不重发、渠道冲突、截断正文确认、窄屏/大字和嵌套退出 |
| B5 配对候选 | 递增双方版本，提交/推送 develop，执行通知旧 Web 回归和双方完整工作流，回填矩阵及实际 APK SHA | 三个 FLS 打包工作流与 APP CI/arm64 artifact 终态成功；手动验收单列，M2 完整流程通过后才接续 M3 |

B1 的时限不得仅用 `join(timeout)` 将仍在发送的线程当作已停止；到期只能报告未知，执行槽仍由实际工作线程释放。原生界面不提供服务端尚未支持的“取消投递成功”。资源数值、工作线程模型和结果类别须在 B1/B2 实现前固定，并由测试验证；不得沿用代理检测的限制数值而假定通知已有同样保证。

B2 的落盘/网络故障必须区分“可证明未启动”和“可能已经投递”。只有前者可以在用户明确确认后继续原请求；后者仅查原 ID，核对接收端后才允许显式新尝试。failed、unknown 均不能自动变成“未发送”。历史 GET 在内存归一化旧 running 记录时不得调用会写回的 `load_notify_history`；读取损坏不能以空列表掩盖。

M2a/M2b 手动验收在同一对隔离 develop 候选执行：依次验证 13 类表单及凭据意图、并发保存/默认选择、被任务引用保护、固定测试发送、已受理后断网查询、历史正文/截断与显式重试、切后台和重新登录。发送项由用户选择专用测试接收端；自动化仅使用注入 sender。APP 重启后的统一恢复仍按 M5 实现，不把面板内存恢复当作跨进程保证。

## APP 与验证

从面板管理入口新增独立 DTO/manager、渠道列表、schema 表单、默认选择页、投递历史和详情；字段校验错误保留草稿，凭据后台隐藏、退出/认证失效清理。未知写入和投递记录只保留面板身份及操作 ID，接入 M5 统一恢复之前明确内存边界。

后端先覆盖 schema/分页/凭据只写、版本冲突、默认选择、任务引用、回执损坏和只读查询，再覆盖测试发送/重试的落盘异常、线程启动、网络结果未知、历史截断和部分发送。回归 `test_notify_action_recovery`、`test_notify_save_recovery`、`test_notify_test_recovery`、`test_notify_retry_recovery` 及配置相关用例。

APP 测试覆盖各类型 schema、字段意图、保存与发送分离、超时只查询、显式新尝试、401 嵌套退出及窄屏/大字号。实现后递增双方版本、提交/推送 develop，验证 FLS 打包与 APP 完整 CI/arm64 APK，再回填 SHA/产物及未覆盖项。用户手动验收，不做 ADB；通知单域交付不等于全量 Goal 完成，不合并 main。

## 接续实施顺序

1. **渠道管理。** 先固定 13 类字段 schema、敏感意图、默认选择版本和只读配置回执；实现后端契约及旧 Web 回归，再接 APP 列表/表单/默认选择与冲突恢复。保存不发送通知。
2. **投递生命周期。** 核对各发送器的超时、分块与部分完成行为，再固定显式启动、只读请求查询、历史/正文及重试契约。使用注入 sender 验证落盘后失联、重启未知和重复请求；APP 以原请求查询恢复，显式新尝试才发送。
3. **完整通知候选。** 配对验证两子批的全部读写与异常路径，记录双方版本/SHA、CI 和 APK artifact；单独列出待手动验收及跨进程恢复边界。只完成渠道配置时不得将 M2 或通知矩阵项标为全部完成。

原始接续基线为 FLS `1344fa5` / `20261126.8`、APP `6ad8279` / `0.1.50+63`；M2a 完成后继续投递生命周期，开发开始先重新同步两个 develop。M2b 与完整通知候选验证后才继续 M3 备份恢复，后续范围及合并条件以 [全量开发计划](DEVELOPMENT-GOALS.md) 为准。
