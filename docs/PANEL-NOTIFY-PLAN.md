# 通知域原生迁移规格

## 范围与源码基线

M2 接续代理诊断。2026-11-26 静态核对 FLS develop `1344fa5` 的 `fls_manager/notify.py`、`notify_actions.py`、`notify_test_actions.py`、`notify_retry_actions.py`、`routes/notify/` 和 `routes/api.py`。本文件描述待开发契约，不表示通知原生 API 或 APP 页面已经实现。

范围覆盖渠道列表/搜索/详情、新增/编辑、启停/删除、默认渠道、完整/裁剪日志模式、测试发送、投递历史/正文/状态和重试。远程/本机面板共享原生页面；FLS Web 继续兼容。保留全部 13 类渠道：Bark、Server 酱、PushPlus、Telegram、企业微信、钉钉、飞书、SMTP、Ntfy、WxPusher、Gotify、PushDeer、自定义 Webhook。

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

建议在原生专用路由提供以下能力，路径在实现及测试中最终固定：

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

## APP 与验证

从面板管理入口新增独立 DTO/manager、渠道列表、schema 表单、默认选择页、投递历史和详情；字段校验错误保留草稿，凭据后台隐藏、退出/认证失效清理。未知写入和投递记录只保留面板身份及操作 ID，接入 M5 统一恢复之前明确内存边界。

后端先覆盖 schema/分页/凭据只写、版本冲突、默认选择、任务引用、回执损坏和只读查询，再覆盖测试发送/重试的落盘异常、线程启动、网络结果未知、历史截断和部分发送。回归 `test_notify_action_recovery`、`test_notify_save_recovery`、`test_notify_test_recovery`、`test_notify_retry_recovery` 及配置相关用例。

APP 测试覆盖各类型 schema、字段意图、保存与发送分离、超时只查询、显式新尝试、401 嵌套退出及窄屏/大字号。实现后递增双方版本、提交/推送 develop，验证 FLS 打包与 APP 完整 CI/arm64 APK，再回填 SHA/产物及未覆盖项。用户手动验收，不做 ADB；通知单域交付不等于全量 Goal 完成，不合并 main。

## 接续实施顺序

1. **渠道管理。** 先固定 13 类字段 schema、敏感意图、默认选择版本和只读配置回执；实现后端契约及旧 Web 回归，再接 APP 列表/表单/默认选择与冲突恢复。保存不发送通知。
2. **投递生命周期。** 核对各发送器的超时、分块与部分完成行为，再固定显式启动、只读请求查询、历史/正文及重试契约。使用注入 sender 验证落盘后失联、重启未知和重复请求；APP 以原请求查询恢复，显式新尝试才发送。
3. **完整通知候选。** 配对验证两子批的全部读写与异常路径，记录双方版本/SHA、CI 和 APK artifact；单独列出待手动验收及跨进程恢复边界。只完成渠道配置时不得将 M2 或通知矩阵项标为全部完成。

接续基线为 FLS `1344fa5` / `20261126.8`、APP `6ad8279` / `0.1.50+63`；开发开始先重新同步两个 develop。完成后继续 M3 备份恢复，后续范围及合并条件以 [全量开发计划](DEVELOPMENT-GOALS.md) 为准。
