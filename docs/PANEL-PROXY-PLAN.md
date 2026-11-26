# 代理配置与诊断原生迁移规格

## 基线与范围

2026-11-26 已在 `$HOME/fls` 执行 fetch 和 `git pull --ff-only origin develop`：最新为 `418640f96d3239ac6d9fa9b8af945aab9f73ef91` / `20261126.6`，`origin/main` 无未包含提交。APP 对接基线为 `1af43571a8a5765a30695afa134a26d51cb31987` / `0.1.48+61`。两仓工作区干净；后续文档提交与实际 APK 构建 SHA 分别记录。

本文件是下一批实施规格，新增接口和 APP 页面均未实现。继续只使用双方 `develop`；保留旧 Web 行为，原生全量渲染和用户验收完成前不合并 main，不发正式 tag/Release，不替换稳定面板。

范围包括 FLS 面板代理列表、新增/编辑、明确启停、删除、未保存表单检测、已保存代理连接/质量检测、诊断历史/筛选及显式重试。本机容器镜像加速源选择与测速属于已有独立流程，不能用它代替本域；用户要求的批量检测应显示逐项结果。内置源的发现、实测与前五名只代表测试时间和所在网络，不承诺从 APP 手机测出的结果等于远程面板可达性。

## 已核对源码

以下路径相对于 FLS 仓库，属于静态核对证据，尚不代表真实测试面板验收：

| 源码 | 现有行为 | 原生接入前需处理 |
| --- | --- | --- |
| `routes/proxy/pages.py`、`_common.py` | 列表、新建/编辑、六种类型、用户名/密码、GitHub URL、启停、删除、表单检测、历史和重试 | 页面是 HTML，不能作为 APP DTO；表单包含敏感字段，原生采用只写意图 |
| `routes/api.py` 的 `/api/proxy/action` | JSON/form 共用 `mutate_proxy` | 冲突可能返回完整 `current`；原生错误必须白名单过滤，不能直接展示该响应 |
| `proxy_actions.py` | `proxy_values` 严格校验；`proxy_version`；请求 ID、版本、prepared/failed/completed 回执；任务引用保护 | 缺少只读原提交查询；凭据 keep/replace/clear 要在锁内解析，不能在路由外读旧配置后覆盖 |
| `models.py` 的 `normalize_proxy` | `http/https/socks4/socks5/socks5h/github`，保留额外字段 | 读取白名单字段，编辑保留未知扩展字段，不在 APP 重建完整服务器对象 |
| `routes/proxy/api.py` | 表单测试/质量为 POST；已保存测试/质量同时允许 GET/POST；历史 GET、重试 POST | 测试同步阻塞且新建诊断记录，GET 不能当状态查询；新增显式启动与只读查询 |
| `proxy.py` | 历史最多 200 条，单次读取最多 100 条、单条最多 20 项；running 重启后转 unknown；GitHub raw 和 Git 检测 | 异常可能包含 URL、代理凭据、Git 输出或服务器路径；原生响应/新历史落盘前统一脱敏 |

普通连接检测超时为 15 秒，普通质量项超时为 8 秒；GitHub 质量含 HTTP 检测及最长 25 秒的 `git ls-remote`。普通检测的 `ok` 当前表示请求完成，可能返回 HTTP 4xx/5xx；APP 必须显示状态码，并区分网络可达与目标响应成功。GitHub 质量检查仍使用现有固定 raw/仓库目标，不能把自定义目标显示成已经检测。

现有 `load_proxy_diagnostics` 可能规范化并写回历史，`create_proxy_diagnostic`/`retry_proxy_diagnostic` 会建立或重新执行探测。原生查询必须确保不启动、重试或重新 claim 检测；重启恢复及历史规范化属于后端恢复逻辑，不由客户端轮询触发新的网络行为。

## 必须保持的契约

- 新接口复用当前面板原生 session/CSRF 和 no-store。401 走统一过期处理；403、普通业务 404 与旧面板不支持 API 分别处理，不能统一降级成“版本过旧”。
- 列表、详情、冲突、引用、回执、诊断及错误采用白名单。密码从不读回；用户名默认只返回是否设置，修改时显式替换。旧数据中的 URL userinfo、查询串或 fragment 不进入摘要；需要修正的旧地址用标记表示，不把遮蔽文本写回配置。
- 写入要求 request_id 和 expected version。目标启停是 bool，不能 toggle 两次；禁用或删除被任务引用的代理继续拒绝，返回有界任务 ID/名称和总数，APP 引导修改任务。新增及编辑中的停用同样保护引用。
- 凭据分别采用 keep/replace/clear，未修改时保持旧值；切换类型不会隐式清空凭据。凭据解析、版本检查、任务引用、保存及回执维持 `TASKS_MUTATION_LOCK` 再 storage transaction 的锁顺序。原生请求指纹基于稳定的请求意图，不能因重放时重新解析 keep 而绑定到后来修改的密码。
- 回执不得保存原始凭据或完整代理对象。复用 `proxy_requests` 时共享校验 request_id、scope/action/target、state、before/after/intent 指纹及时间字段，拒绝损坏或不匹配记录；不能仅凭 state=completed 的任意 JSON 就宣称成功。
- 完成回执表示该请求历史上已保存，不保证代理此后未被更改。prepared 只能据目标 before/after 判断，变化后无法证明结果则 unknown/conflict；GET 查询不调用 mutation，不保存、不重试、不创建代理。
- 未知结果期间禁用新的同对象写入，先查询原请求。确认未保存后才显式重试，需恢复确认时展示确认；冲突保留草稿并核对当前非敏感配置。删除后不能自动将编辑草稿另建代理。
- 质量检测目标数量、URL 长度、协议及请求体大小有明确上限；拒绝带凭据的自定义目标。输出使用受限状态码、耗时及稳定错误类别，禁止将 requests/Git 原始异常直接落入新回执、日志或 APP。旧诊断记录读取也必须脱敏。

## 拟定 API

以下为待实现路径草案；编码前对照路由冲突，在 FLS 提交中固定最终契约，再接 APP。已有 Web URL 与 form 语义保持兼容。

| 方法与路径 | 输入/输出与副作用 |
| --- | --- |
| `GET /api/proxy/settings` | `q/type/enabled/page/limit`，稳定排序和有界分页；不按用户名或密码匹配搜索；返回安全摘要、版本和类型选项 |
| `GET /api/proxy/settings/<id>` | 白名单可编辑配置、版本、凭据是否存在、引用计数/有界预览；无网络探测 |
| `POST /api/proxy/settings` | 新建/编辑/明确启停/删除；凭据意图、request_id、expected version；复用 mutation 服务及任务引用保护 |
| `GET /api/proxy/requests/<request_id>` | 严格校验并只读解析原保存回执；saved 可为 true/false/null，返回 historical/current-match 等明确状态；不重做副作用 |
| `POST /api/proxy/checks` | request_id、kind=test/quality、已保存 id/version 或受限草稿、目标选项；先持久化再启动，返回 check_id/status；HTTP 请求不等待检测完成 |
| `GET /api/proxy/checks/<check_id>` | 当前状态、有限分项进度、终态、是否可重新检测；不触发网络；重启未确认则 unknown |
| `GET /api/proxy/checks` | 最近记录、有界分页、代理/状态/kind 筛选；兼容读取旧诊断历史并脱敏，标明已删除代理和草稿检测 |
| `POST /api/proxy/checks/<check_id>/retry` | 新 request_id 和已保存代理当前版本；显式发起新尝试并绑定 retry_of，历史不被覆盖；代理变化时先确认当前配置 |

检测复用现有 `test_proxy_object`、`quality_proxy_object` 及 GitHub 检测逻辑；在探测边界限制响应读取大小、耗时和并发，不能在每个轮询请求重新创建线程池。每代理限制同时运行检测数量，批量检测采用有上限队列并返回逐项 request/check ID，不以单条失败抹掉其他结果。百分比只来自真实完成项，不伪造网络字节下载进度。

已保存代理执行使用明确版本快照；提交后并发编辑不改变正在运行的检测参数，结果标记其测试版本。草稿密码只保留在服务端作业内存；回执/历史仅存 HMAC 意图指纹和安全分项，进程重启后不恢复草稿秘密。相同 request_id 只查询已建立的检测，不再次发起网络；没有证明启动完成时保持 unknown。草稿失败后重检要求用户再次明确提供草稿，不能从历史读回凭据。

现有探测函数没有可靠的中断协议：首批不展示虚假的“停止成功”按钮。页面退出仅停止轮询，后端继续至有限超时；若后续实现取消，必须能证明 HTTP/子进程停止及资源释放后再标 canceled。

## APP 结构与操作

新增独立 `panel_proxy` DTO、manager、原生代理列表/编辑页和诊断页，复用当前面板 API client/session，远程与本机共用。入口放在面板管理菜单，保留显式 Web 回退；页面不抓取 HTML，不直接读取 FLS 配置文件。

列表支持搜索/类型/启用状态/分页，显示名称、类型、脱敏地址、状态和引用数；行菜单提供编辑、明确启停、检测及删除，多选检测显示各代理进度和失败项。地址长文本可换行，工具用已有 Material 图标和 tooltip，删除/禁用确认注明任务引用约束。

编辑覆盖六种类型，使用类型菜单、地址/端口输入、启用开关、凭据保持/修改/清空控件；默认不显示已存凭据。草稿可在保存前检测，检测不隐式保存；返回需确认丢弃，后台隐藏敏感输入，切换面板/认证失效清理草稿。冲突时保留本地改动并显式核对，未经确认不借新版 version 自动覆盖。

诊断页显示 test/quality、开始/结束、尝试来源、真实分项状态码/耗时、全部/部分失败及 unknown；默认有界轮询，离开页面停止轮询但不停止探测。历史中只能显式重新检测，重复点击和丢失响应沿原 request_id 查询。管理上下文先保留未确认 ID；随后统一恢复入口仅持久化面板标识/操作 ID/类型，凭据和草稿不落盘，不跨面板恢复。

## 可执行批次

1. **后端配置与只读恢复。** 先补认证/CSRF、分页/摘要、credential 意图、版本冲突、任务引用和损坏回执测试；共享 mutation 校验后实现 settings 与 requests。验证 Web 表单/旧 action 回归，提交 FLS develop。
2. **后端异步诊断。** 固定启动/查询/历史/重试 DTO，再实现持久化后启动、幂等、并发/超时/结果脱敏、草稿内存边界和批量逐项语义；GET 测试中断言网络探测调用次数为零，保留旧 Web 接口兼容。
3. **APP 完整接入。** 根据上述已提交契约实现 DTO/manager/页面、列表及编辑/启停/删除、草稿/已保存检测、历史/重试、未知结果和多选检测。阶段中仍在矩阵保留未覆盖项，不因只接入 CRUD 就标整个代理域完成。
4. **配对候选验证。** 双方版本递增、提交/推送各自 develop；FLS 聚焦及既有代理恢复回归，APP 格式/analyze/完整测试/arm64 APK，跟踪工作流最终结论并记录双方 SHA/artifact。此批无需 ADB、无需正式 Release。

APP 测试覆盖 HTTP 方法/session/CSRF、凭据不出现在读取/错误、请求 ID 重放、丢失保存响应后只查询、冲突草稿、引用拒绝、检测后台继续/历史恢复、部分失败、旧面板能力及 320 dp 窄屏/大字体。Termux 不运行 Flutter tester，实际测试由 GitHub Actions 验证，未运行不得写成通过。

手动验收由用户在隔离 develop 面板执行：同一代理由 APP/Web 交替编辑并制造冲突；被任务引用时禁用/删除受阻；草稿检测不保存；检测中退出重进及中途断网不重复探测；重启面板显示 unknown；检查普通与 GitHub 代理语义及手机/远程网络差别。未验收继续标待用户，不阻塞通知域开发，也不满足 main 合并门槛。

代理后依次推进通知、备份恢复、首次设置/面板维护，再回到全量矩阵核对任务/合集/日志/统一恢复及导航视觉。全量原生渲染始终是最终目标，本域只是其中一批。
