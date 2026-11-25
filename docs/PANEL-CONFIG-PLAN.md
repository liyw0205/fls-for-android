# 应用配置原生迁移规格

## 基线与范围

从全局变量批次后继续：FLS `fa5361c` / `20261126.5`，APP `37862c6` / `0.1.47+60`，仅使用各自 `develop`。本规格是下一批实施输入，以下新增接口均为拟议契约，不能当作已经实现。全量原生目标、手动验收和 main 合并门槛继续以 GOAL-ROADMAP 与功能矩阵为准。

已核对 FLS `routes/config/page.py` 的 `_config_snapshot`、`_apply_revision`、`_apply_saved_config` 和 `config_page`，以及 `config.py` 的 `DEFAULT_CONFIG`、`normalize_config_data`。现有 `/api/config/apply` 只有重新应用保存配置的动作；配置读取和保存仍由 HTML 表单承担。

## 必须覆盖的行为

| 分组 | 字段/能力 | 服务端边界 |
| --- | --- | --- |
| 显示 | `theme` | 选项来自 `THEME_OPTIONS`；说明这是面板 Web 主题，APP 主题由自己的设置控制 |
| 网络 | `port` | 整数 1–65535；保存不等于已重启或更换当前连接地址 |
| 在线脚本 | `online_script_source` | 保留现有空值恢复默认源语义；读取/错误不能泄露 URL 中的凭据 |
| 日志 | `log_cleanup_minutes`、`log_max_size_mb`、`log_keep_per_task` | 间隔 1–1440 分钟，大小/数量至少 1；应用配置会执行日志清理，确认界面必须体现实际副作用 |
| 任务 | `task_timeout_seconds`、`random_delay_seconds`、`task_types` | 超时至少 0，延迟 0–120 秒；类型覆盖 py/sh/js/ts/ps1/bat/php/rb/pl/lua/jar，不与运行器安装能力混淆 |
| 认证 | `admin_token`、`security_verify_enabled`、`security_verify_type`、`totp_secret`、`totp_code` | Token/密钥默认不读回、不写入 APP 普通存储；明确保持、修改、清空语义。切换或首次开启 TOTP 必须确认验证码；认证变化后清理旧会话并重新登录 |
| 关联状态 | 已保存 revision、应用状态、字段校验错误 | 区分未保存、已保存未应用、应用成功、应用失败、结果未知；不能用同一保存按钮重复覆盖配置 |

读取和保存保留未参与编辑的配置，包括 `timezone_offset_hours`、`panel_time_offset_seconds` 与未知扩展字段；时间校准属于后续维护域，不能因保存普通配置而被重置。

## 后端实施

1. 先为现有保存逻辑增加回归用例，再把表单校验、版本检查、保存及应用状态拆到可复用服务。Web 与新 JSON 接口调用同一服务；保留已有字段默认值、认证失效及应用恢复语义。
2. 拟新增 `GET /api/config/settings`：返回白名单 settings、字段类型/范围/枚举、revision 和脱敏应用状态；密钥仅返回是否已配置。敏感 URL 不直接显示明文，不因遮蔽而在保存时覆盖真实值。全响应 no-store。
3. 拟新增 `POST /api/config/settings`：要求 request_id、expected_revision 和字段修改集合。严格类型校验，不把无效字符串静默转为默认整数；未提交密钥保持原值，清空/替换必须显式。提交体和字段长度有上限，未知字段拒绝或明确只读。
4. 保存前持久化幂等回执，写配置后记录实际保存 revision；回执仅含白名单状态和指纹，不存 Token、TOTP 密钥或完整配置。保存冲突不得回传完整配置，APP 经显式读取后保留草稿并合并。
5. 拟新增 `GET /api/config/requests/<request_id>`：只查询原保存结果，不触发保存/应用。断网、磁盘异常及重启中断无法确认时显示 unknown，不自动重新应用；应用重试带独立 request_id 与期望 revision，防止把旧页面操作应用到新配置。
6. 复用并补强 `/api/config/apply` 的状态契约：saved 与 apply_status 分离，错误只返回稳定脱敏原因。日志清理或调度器重载失败时保存状态仍可为 true；用户显式恢复应用，不再次提交配置。
7. 认证变更后旧 cookie 失效，原提交必须能在使用新凭据重新登录后查询。响应丢失时禁止回退尝试旧 Token，也不得把 Token 放入 URL、日志或恢复记录。
8. TOTP enrollment 使用受限临时会话或明确的服务端预检查；生成/确认流程和密钥状态必须测试。APP 如需二维码，用成熟本地组件渲染，不把密钥送给远端图片服务。未完成安全配置全流程前，不把应用配置域标为原生覆盖完成。

## APP 实施

- 新增配置 DTO 与 manager，复用当前面板 session/CSRF，页面不直接拼 HTTP。读操作、保存请求、原提交查询和应用恢复各有独立状态，所有网络操作有超时。
- 管理入口打开分组原生表单：数字输入、开关、多选任务类型、枚举菜单；敏感字段采用只写修改流程，默认保持。系统字体、横屏和窄屏下按钮和错误可触达。
- 保存前展示具体变化和服务端副作用。返回 applied=false 时展示已保存状态与“重新应用已保存配置”，网络结果未知时先查询原请求，禁止自动重放。
- 冲突保留当前页面草稿并显式核对当前配置。切换面板、退出、401 与认证变更清理旧会话上下文；密钥不进入页面恢复持久化或崩溃信息。
- 端口变化仍保留当前服务连接，提供更新面板连接的明确操作，不能因仅保存端口就自动连接尚未启动的新地址。

## 验证与交付

后端覆盖原生 session/CSRF、白名单和字段边界、密钥保持/清空/修改、TOTP 初次启用与切换失败、并发 revision 冲突、同 request_id 重放/冲突、保存前后磁盘异常、应用部分失败、回执损坏、重启未知状态、认证变化后重新查询以及 Web 行为回归。

APP 覆盖 DTO/HTTP 契约、敏感值不读回、草稿冲突、未知结果查询、保存成功但应用失败仅重试应用、认证变化重新登录、窄屏/横屏/大字体。Termux 不运行 Flutter tester，依靠 develop CI 的格式、analyze、完整测试和 arm64 APK；真实面板和 Android 生命周期由用户手动验收，不做 ADB。

每批记录双方提交、候选版本、CI 与 APK artifact。下一批实施到此域完整可验证后，继续代理/通知、备份恢复和维护，以及矩阵其余缺口；仍不合并 main。
