import 'package:flutter/material.dart';

import '../models/panel_config.dart';
import '../services/panel_api_client.dart';
import '../services/panel_config_manager.dart';

class PanelConfigView extends StatefulWidget {
  const PanelConfigView({
    super.key,
    required this.manager,
    required this.onUnauthorized,
    this.recovery,
  });

  final PanelConfigManager manager;
  final Future<void> Function(PanelApiException) onUnauthorized;
  final PanelConfigRecovery? recovery;

  @override
  State<PanelConfigView> createState() => _PanelConfigViewState();
}

class _PanelConfigViewState extends State<PanelConfigView> {
  static const _taskNames = <String, String>{
    'py': 'Python',
    'sh': 'Shell',
    'js': 'JavaScript',
    'ts': 'TypeScript',
    'ps1': 'PowerShell',
    'bat': 'Windows Batch',
    'php': 'PHP',
    'rb': 'Ruby',
    'pl': 'Perl',
    'lua': 'Lua',
    'jar': 'Java JAR',
  };

  final _source = TextEditingController();
  final _port = TextEditingController();
  final _cleanupMinutes = TextEditingController();
  final _logSize = TextEditingController();
  final _logsPerTask = TextEditingController();
  final _timeout = TextEditingController();
  final _delay = TextEditingController();
  final _token = TextEditingController();
  final _totpCode = TextEditingController();
  PanelConfigSettings? _config;
  PanelConfigSettings? _conflictConfig;
  Map<String, bool> _taskTypes = const {};
  String _theme = 'deepseek';
  String _securityType = 'code';
  bool _securityEnabled = false;
  bool _clearToken = false;
  bool _loading = false;
  bool _busy = false;
  bool _sourceRevealed = false;
  String? _error;
  String? _totpSecret;
  late final PanelConfigRecovery _recovery;
  bool get _writeBlocked => _busy || _loading || _recovery.requestId != null;

  @override
  void initState() {
    super.initState();
    _recovery = widget.recovery ?? PanelConfigRecovery();
    _load();
  }

  @override
  void dispose() {
    for (final controller in [
      _source,
      _port,
      _cleanupMinutes,
      _logSize,
      _logsPerTask,
      _timeout,
      _delay,
      _token,
      _totpCode,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _setDraft(PanelConfigSettings config) {
    _config = config;
    final values = config.settings;
    _theme = values['theme'] as String? ?? 'deepseek';
    _port.text = '${values['port'] ?? 5700}';
    _cleanupMinutes.text = '${values['log_cleanup_minutes'] ?? 30}';
    _logSize.text = '${values['log_max_size_mb'] ?? 10}';
    _logsPerTask.text = '${values['log_keep_per_task'] ?? 10}';
    _timeout.text = '${values['task_timeout_seconds'] ?? 1800}';
    _delay.text = '${values['random_delay_seconds'] ?? 0}';
    _source.text = values['online_script_source'] as String? ?? '';
    _sourceRevealed = values['online_script_source_requires_reveal'] != true;
    final types = values['task_types'];
    _taskTypes = types is Map<String, dynamic>
        ? {for (final entry in types.entries) entry.key: entry.value == true}
        : const {};
    _securityEnabled = config.securityEnabled;
    _securityType = config.securityType;
    _token.clear();
    _clearToken = false;
    _totpCode.clear();
    _totpSecret = null;
  }

  Future<void> _load({
    bool replaceDraft = true,
    bool revealSource = false,
  }) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final config = await widget.manager.fetch(revealSource: revealSource);
      if (!mounted) return;
      setState(() {
        final previous = _config;
        if (replaceDraft ||
            previous == null ||
            previous.revision == config.revision) {
          _config = config;
        } else {
          _conflictConfig = config;
        }
        if (replaceDraft) {
          _conflictConfig = null;
          _setDraft(config);
        }
        if (revealSource) {
          _source.text =
              config.settings['online_script_source'] as String? ?? '';
          _sourceRevealed = true;
        }
      });
    } on PanelApiException catch (error) {
      if (!mounted) return;
      if (error.statusCode == 401) {
        await _unauthorized(error);
        return;
      }
      setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '配置读取失败');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Map<String, Object?> _settingsChanges(PanelConfigSettings current) {
    final values = current.settings;
    final changes = <String, Object?>{};
    if (_theme != values['theme']) changes['theme'] = _theme;
    for (final entry in <String, TextEditingController>{
      'port': _port,
      'log_cleanup_minutes': _cleanupMinutes,
      'log_max_size_mb': _logSize,
      'log_keep_per_task': _logsPerTask,
      'task_timeout_seconds': _timeout,
      'random_delay_seconds': _delay,
    }.entries) {
      final next = int.tryParse(entry.value.text.trim());
      if (next == null) throw const FormatException('数字配置必须填写整数');
      final range = switch (entry.key) {
        'port' => (1, 65535),
        'log_cleanup_minutes' => (1, 1440),
        'log_max_size_mb' || 'log_keep_per_task' => (1, null),
        'task_timeout_seconds' => (0, null),
        'random_delay_seconds' => (0, 120),
        _ => (0, null),
      };
      if (next < range.$1 || (range.$2 != null && next > range.$2!)) {
        throw FormatException('${entry.key} 超出允许范围');
      }
      if (next != values[entry.key]) changes[entry.key] = next;
    }
    final oldSource = values['online_script_source'];
    if (_source.text.length > 4096) {
      throw const FormatException('在线脚本源长度不能超过 4096 字符');
    }
    if (_source.text != oldSource && (_sourceRevealed || oldSource != '')) {
      changes['online_script_source'] = _source.text;
    }
    final oldTypes = values['task_types'];
    if (oldTypes is Map) {
      final changedTypes = {
        for (final entry in _taskTypes.entries)
          if (oldTypes[entry.key] != entry.value) entry.key: entry.value,
      };
      if (changedTypes.isNotEmpty) changes['task_types'] = changedTypes;
    }
    return changes;
  }

  Map<String, Object?> _credentialChanges(PanelConfigSettings current) {
    final changes = <String, Object?>{};
    if (current.tokenManagedByEnvironment &&
        (_token.text.isNotEmpty || _clearToken)) {
      throw const FormatException('Token 由服务环境管理，不能在此修改');
    }
    if (_clearToken) {
      changes['token_action'] = 'clear';
    } else if (_token.text.isNotEmpty) {
      changes['token_action'] = 'replace';
      changes['admin_token'] = _token.text;
    }

    final securityChanged =
        _securityEnabled != current.securityEnabled ||
        _securityType != current.securityType ||
        _totpSecret != null;
    final requiresTotpConfirmation =
        _securityEnabled &&
        _securityType == 'totp' &&
        (!current.securityEnabled ||
            current.securityType != 'totp' ||
            _totpSecret != null);
    if (requiresTotpConfirmation && _totpSecret == null) {
      throw const FormatException('请先生成 TOTP 密钥并验证当前验证码');
    }
    if (requiresTotpConfirmation &&
        !RegExp(r'^\d{6,8}$').hasMatch(_totpCode.text.trim())) {
      throw const FormatException('请输入 6 到 8 位 TOTP 验证码');
    }
    if (securityChanged) {
      changes['enabled'] = _securityEnabled;
      changes['type'] = _securityType;
      if (_securityEnabled && _securityType == 'totp' && _totpSecret != null) {
        changes['totp_action'] = 'replace';
        changes['totp_secret'] = _totpSecret;
        changes['totp_code'] = _totpCode.text.trim();
      } else if (!_securityEnabled || _securityType == 'code') {
        changes['totp_action'] = 'clear';
      }
    }
    return changes;
  }

  Future<bool> _confirmSave(
    Map<String, Object?> settings,
    Map<String, Object?> credentials,
  ) async {
    if (settings.isEmpty && credentials.isEmpty) return false;
    final changes = <String>[
      if (settings.isNotEmpty) '更新 ${settings.length} 项面板设置',
      if (credentials['token_action'] == 'replace') '更改登录 Token 并退出当前会话',
      if (credentials['token_action'] == 'clear')
        '清除登录 Token，当前面板可能进入首次设置状态并清除会话',
      if (credentials.containsKey('enabled') || credentials.containsKey('type'))
        '更改登录安全验证并退出当前会话',
      '保存后立即执行一次日志清理并重载任务调度器',
      if (settings.containsKey('port')) '端口变更保存后需重启 FLS 才生效，当前连接不会自动切换',
    ];
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认保存配置'),
            content: Text(changes.join('\n')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认保存'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _save() async {
    final current = _config;
    if (current == null || _writeBlocked) return;
    late final Map<String, Object?> settings;
    late final Map<String, Object?> credentials;
    try {
      settings = _settingsChanges(current);
      credentials = _credentialChanges(current);
    } on FormatException catch (error) {
      _message(error.message);
      return;
    }
    if (settings.isEmpty && credentials.isEmpty) {
      _message('没有待保存的配置变更');
      return;
    }
    if (!await _confirmSave(settings, credentials)) return;
    if (!mounted || _writeBlocked) return;
    final requestId = PanelConfigManager.newRequestId();
    _recovery.requestId = requestId;
    _recovery.isApply = false;
    setState(() => _busy = true);
    try {
      final result = await widget.manager.save(
        requestId: requestId,
        revision: current.revision,
        settings: settings,
        credentials: credentials,
      );
      await _handleSaveResult(result);
    } on PanelApiException catch (error) {
      if (error.statusCode == 401) {
        await _unauthorized(error);
      } else if (error.statusCode == 409) {
        _recovery.requestId = null;
        if (error.data?['conflict'] == true) {
          await _loadConflict();
        } else {
          _message(error.message);
        }
      } else if (const {400, 413, 415, 422}.contains(error.statusCode)) {
        _recovery.requestId = null;
        _message(error.message);
      } else {
        await _recover(requestId, isApply: false);
      }
    } catch (_) {
      await _recover(requestId, isApply: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleSaveResult(PanelConfigResult result) async {
    if (result.reauthRequired && result.saved != false) {
      await _unauthorized(
        const PanelApiException('认证设置已变更，请重新登录', statusCode: 401),
      );
      return;
    }
    if (result.saved != true) {
      _message('保存结果尚未确认，请检查原提交状态；不会自动重复提交');
      return;
    }
    setState(() => _recovery.requestId = null);
    await _load();
    if (result.applyStatus == 'failed' || result.applyStatus == 'unknown') {
      _message('配置已保存，但应用结果未成功确认；可单独重新应用');
    } else {
      _message('配置已保存并应用');
    }
  }

  Future<void> _recover(String requestId, {required bool isApply}) async {
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final result = await widget.manager.status(requestId);
      if (!mounted) return;
      if (result.saved == true) {
        setState(() => _recovery.requestId = null);
        await _load(replaceDraft: !isApply);
        _message(result.applied ? '原提交已完成并应用' : '配置已保存，应用尚未成功确认；可单独重试应用');
      } else if (result.saved == false) {
        setState(() => _recovery.requestId = null);
        _message('原提交未保存；草稿仍保留，可再次确认后提交');
      } else {
        _recovery.requestId = requestId;
        _recovery.isApply = isApply;
        _message('提交状态未知或尚未到达服务器；未自动重放，请刷新状态后处理');
      }
    } on PanelApiException catch (error) {
      if (error.statusCode == 401) {
        await _unauthorized(error);
      } else if (mounted) {
        _message('无法查询原提交状态；请稍后手动检查');
      }
    } catch (_) {
      if (mounted) {
        _message('无法查询原提交状态；请稍后手动检查');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unauthorized(PanelApiException error) async {
    if (!mounted) return;
    _token.clear();
    _totpCode.clear();
    _totpSecret = null;
    await widget.onUnauthorized(error);
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  Future<void> _loadConflict() async {
    try {
      final latest = await widget.manager.fetch();
      if (!mounted) return;
      setState(() => _conflictConfig = latest);
      _message('配置已被其他操作修改；草稿仍保留，请核对冲突项后处理');
    } on PanelApiException catch (error) {
      if (error.statusCode == 401) {
        await _unauthorized(error);
      } else if (mounted) {
        _message('配置冲突；草稿仍保留，但无法读取当前版本');
      }
    } catch (_) {
      if (mounted) _message('配置冲突；草稿仍保留，但无法读取当前版本');
    }
  }

  Future<void> _showConflict() async {
    final baseline = _config;
    final latest = _conflictConfig;
    if (baseline == null || latest == null) return;
    const labels = <String, String>{
      'theme': '面板主题',
      'port': '面板端口',
      'online_script_source': '在线脚本源',
      'log_cleanup_minutes': '日志清理间隔',
      'log_max_size_mb': '日志最大大小',
      'log_keep_per_task': '日志保留数量',
      'task_timeout_seconds': '任务超时',
      'random_delay_seconds': '随机延迟',
      'task_types': '脚本类型',
    };
    final serverChanged = labels.keys
        .where((key) {
          final oldValue = baseline.settings[key];
          final newValue = latest.settings[key];
          if (key == 'task_types' && oldValue is Map && newValue is Map) {
            return oldValue.keys.any(
              (type) => oldValue[type] != newValue[type],
            );
          }
          return oldValue != newValue;
        })
        .map((key) => labels[key]!)
        .toList();
    if (baseline.securityEnabled != latest.securityEnabled ||
        baseline.securityType != latest.securityType) {
      serverChanged.add('登录安全验证');
    }
    final draftChanged = <String>[
      if (_theme != baseline.settings['theme']) '面板主题',
      if (_port.text != '${baseline.settings['port']}') '面板端口',
      if (_sourceRevealed &&
          _source.text != baseline.settings['online_script_source'])
        '在线脚本源',
      if (_cleanupMinutes.text != '${baseline.settings['log_cleanup_minutes']}')
        '日志清理间隔',
      if (_logSize.text != '${baseline.settings['log_max_size_mb']}') '日志最大大小',
      if (_logsPerTask.text != '${baseline.settings['log_keep_per_task']}')
        '日志保留数量',
      if (_timeout.text != '${baseline.settings['task_timeout_seconds']}')
        '任务超时',
      if (_delay.text != '${baseline.settings['random_delay_seconds']}') '随机延迟',
      if ((baseline.settings['task_types'] as Map).keys.any(
        (type) =>
            (baseline.settings['task_types'] as Map)[type] != _taskTypes[type],
      ))
        '脚本类型',
      if (_securityEnabled != baseline.securityEnabled ||
          _securityType != baseline.securityType)
        '登录安全验证',
      if (_token.text.isNotEmpty || _clearToken) '登录 Token',
    ];
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('配置冲突'),
        content: Text(
          '服务端版本：${latest.revision.substring(0, 12)}\n'
          '服务端已变化：${serverChanged.isEmpty ? '未发现可展示的字段变化' : serverChanged.join('、')}\n'
          '本地草稿修改：${draftChanged.isEmpty ? '无' : draftChanged.join('、')}\n\n'
          '保留修改并合并时，重复修改的字段以本地草稿为准，其余字段采用服务端值。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('继续保留草稿'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留修改并合并'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('读取服务器版本'),
          ),
        ],
      ),
    ).then((discard) {
      if (!mounted) return;
      if (discard == true) {
        _load();
      } else if (discard == false) {
        _mergeDraft(latest);
      }
    });
  }

  void _mergeDraft(PanelConfigSettings latest) {
    final baseline = _config!;
    try {
      final settings = _settingsChanges(baseline);
      final credentials = _credentialChanges(baseline);
      setState(() {
        _setDraft(latest);
        _conflictConfig = null;
        if (settings['theme'] is String) _theme = settings['theme'] as String;
        for (final entry in <String, TextEditingController>{
          'port': _port,
          'log_cleanup_minutes': _cleanupMinutes,
          'log_max_size_mb': _logSize,
          'log_keep_per_task': _logsPerTask,
          'task_timeout_seconds': _timeout,
          'random_delay_seconds': _delay,
        }.entries) {
          if (settings.containsKey(entry.key)) {
            entry.value.text = '${settings[entry.key]}';
          }
        }
        if (settings['online_script_source'] is String) {
          _source.text = settings['online_script_source'] as String;
          _sourceRevealed = true;
        }
        if (settings['task_types'] is Map<String, bool>) {
          _taskTypes.addAll(settings['task_types'] as Map<String, bool>);
        }
        if (credentials['admin_token'] is String) {
          _token.text = credentials['admin_token'] as String;
        }
        _clearToken = credentials['token_action'] == 'clear';
        if (credentials['enabled'] is bool) {
          _securityEnabled = credentials['enabled'] as bool;
        }
        if (credentials['type'] is String) {
          _securityType = credentials['type'] as String;
        }
        _totpSecret = credentials['totp_secret'] as String?;
        _totpCode.text = credentials['totp_code'] as String? ?? '';
      });
    } on FormatException catch (error) {
      _message(error.message);
    }
  }

  Future<void> _retryApply() async {
    final current = _config;
    if (current == null || _writeBlocked) return;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('重新应用已保存配置？'),
            content: const Text('不会再次保存。此操作会重新清理日志并重载任务调度器。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('重新应用'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted || _writeBlocked) return;
    final id = PanelConfigManager.newRequestId();
    _recovery.requestId = id;
    _recovery.isApply = true;
    setState(() => _busy = true);
    try {
      final result = await widget.manager.apply(
        requestId: id,
        revision: current.revision,
      );
      _recovery.requestId = null;
      await _load(replaceDraft: false);
      _message(
        result.applyStatus == 'succeeded' ? '配置已重新应用' : '配置仍未应用成功，可稍后再试',
      );
    } on PanelApiException catch (error) {
      if (error.statusCode == 401) {
        await _unauthorized(error);
      } else if (error.statusCode == 409) {
        _recovery.requestId = null;
        _message('配置版本已变化，请刷新后再应用');
      } else if (const {400, 413, 415}.contains(error.statusCode)) {
        _recovery.requestId = null;
        _message(error.message);
      } else {
        await _recover(id, isApply: true);
      }
    } catch (_) {
      await _recover(id, isApply: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enrollTotp() async {
    setState(() => _busy = true);
    try {
      final secret = await widget.manager.enrollTotp();
      if (mounted) setState(() => _totpSecret = secret);
    } on PanelApiException catch (error) {
      if (error.statusCode == 401) {
        await _unauthorized(error);
      } else if (mounted) {
        _message(error.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: AbsorbPointer(
      absorbing: _writeBlocked,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...children,
          const SizedBox(height: 16),
        ],
      ),
    ),
  );

  Widget _numberField(
    String label,
    TextEditingController controller, {
    String? helper,
  }) => TextField(
    controller: controller,
    keyboardType: TextInputType.number,
    decoration: InputDecoration(
      labelText: label,
      helperText: helper,
      helperMaxLines: 4,
    ),
  );

  Future<void> _refreshDraft() async {
    if (_writeBlocked) return;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新读取配置？'),
        content: const Text('当前未保存的修改将被舍弃。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('重新读取'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final current = _config;
    return Scaffold(
      appBar: AppBar(
        title: const Text('应用配置'),
        actions: [
          IconButton(
            tooltip: '刷新配置',
            onPressed: _writeBlocked ? null : _refreshDraft,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading && current == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null && current == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            )
          : current == null
          ? const SizedBox.shrink()
          : ListView(
              children: [
                if (_loading || _busy) const LinearProgressIndicator(),
                if (_recovery.requestId != null)
                  MaterialBanner(
                    content: const Text('存在尚未确认的配置提交'),
                    actions: [
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _recover(
                                _recovery.requestId!,
                                isApply: _recovery.isApply,
                              ),
                        child: const Text('查询原提交'),
                      ),
                    ],
                  ),
                if (_conflictConfig != null)
                  MaterialBanner(
                    content: const Text('服务端配置已更新，本地草稿仍保留'),
                    actions: [
                      TextButton(
                        onPressed: _showConflict,
                        child: const Text('查看冲突项'),
                      ),
                    ],
                  ),
                if (_error != null)
                  MaterialBanner(
                    content: Text(_error!),
                    actions: [
                      TextButton(
                        onPressed: () => _load(replaceDraft: false),
                        child: const Text('重试读取'),
                      ),
                    ],
                  ),
                if (current.applyStatus == 'failed' ||
                    current.applyStatus == 'unknown')
                  MaterialBanner(
                    content: Text(
                      current.apply['message'] as String? ?? '配置应用结果待确认',
                    ),
                    actions: [
                      TextButton(
                        onPressed: _writeBlocked ? null : _retryApply,
                        child: const Text('重新应用'),
                      ),
                    ],
                  ),
                _section('显示与网络', [
                  DropdownButtonFormField<String>(
                    key: ValueKey('theme-${current.revision}'),
                    initialValue: _theme,
                    decoration: const InputDecoration(labelText: '面板 Web 主题'),
                    items: const [
                      DropdownMenuItem(
                        value: 'deepseek',
                        child: Text('DeepSeek'),
                      ),
                      DropdownMenuItem(
                        value: 'neumorphism',
                        child: Text('新拟物派'),
                      ),
                      DropdownMenuItem(
                        value: 'editorial',
                        child: Text('编辑杂志风'),
                      ),
                      DropdownMenuItem(
                        value: 'glassmorphism',
                        child: Text('玻璃拟态'),
                      ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _theme = value ?? _theme),
                  ),
                  _numberField(
                    '面板端口',
                    _port,
                    helper: '保存后重启 FLS 生效；不会自动切换当前连接。',
                  ),
                  TextField(
                    controller: _source,
                    readOnly:
                        current.settings['online_script_source_requires_reveal'] ==
                            true &&
                        !_sourceRevealed,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: '在线脚本源',
                      suffixIcon:
                          current.settings['online_script_source_requires_reveal'] ==
                                  true &&
                              !_sourceRevealed
                          ? IconButton(
                              tooltip: '显式查看脚本源',
                              onPressed: () => _load(
                                replaceDraft: false,
                                revealSource: true,
                              ),
                              icon: const Icon(Icons.visibility),
                            )
                          : null,
                    ),
                  ),
                ]),
                _section('日志与任务', [
                  _numberField('日志清理间隔（分钟）', _cleanupMinutes),
                  _numberField('单个日志最大大小（MB）', _logSize),
                  _numberField('每个任务保留日志数', _logsPerTask),
                  _numberField('任务超时（秒，0 表示关闭）', _timeout),
                  _numberField('全局随机延迟（秒）', _delay),
                  const SizedBox(height: 8),
                  const Text('允许执行的脚本类型'),
                  for (final entry in _taskNames.entries)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(entry.value),
                      subtitle: Text('.${entry.key}'),
                      value: _taskTypes[entry.key] == true,
                      onChanged: _busy
                          ? null
                          : (value) =>
                                setState(() => _taskTypes[entry.key] = value),
                    ),
                ]),
                _section('登录与安全', [
                  if (current.tokenManagedByEnvironment)
                    const ListTile(
                      leading: Icon(Icons.lock_outline),
                      title: Text('登录 Token 由服务环境管理'),
                    )
                  else ...[
                    TextField(
                      controller: _token,
                      obscureText: true,
                      enabled: !_clearToken,
                      decoration: const InputDecoration(
                        labelText: '新登录 Token',
                        helperText: '不会读取或回显现有 Token；留空表示保持不变。',
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('清除登录 Token'),
                      value: _clearToken,
                      onChanged: _busy
                          ? null
                          : (value) => setState(() => _clearToken = value),
                    ),
                  ],
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用登录后安全验证'),
                    value: _securityEnabled,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _securityEnabled = value),
                  ),
                  DropdownButtonFormField<String>(
                    key: ValueKey('security-${current.revision}'),
                    initialValue: _securityType,
                    decoration: const InputDecoration(labelText: '安全验证方式'),
                    items: const [
                      DropdownMenuItem(value: 'code', child: Text('随机验证码')),
                      DropdownMenuItem(value: 'totp', child: Text('TOTP 认证器')),
                    ],
                    onChanged: !_securityEnabled || _busy
                        ? null
                        : (value) => setState(
                            () => _securityType = value ?? _securityType,
                          ),
                  ),
                  if (_securityEnabled && _securityType == 'totp') ...[
                    Text(
                      current.totpConfigured
                          ? 'TOTP 已配置；默认保持现有密钥。'
                          : '需要设置并确认 TOTP 密钥。',
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _enrollTotp,
                      icon: const Icon(Icons.qr_code_2),
                      label: Text(
                        _totpSecret == null ? '生成临时 TOTP 密钥' : '重新生成密钥',
                      ),
                    ),
                    if (_totpSecret != null) ...[
                      SelectableText(
                        _totpSecret!,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      TextField(
                        controller: _totpCode,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '认证器当前验证码',
                        ),
                      ),
                    ],
                  ],
                ]),
              ],
            ),
      bottomNavigationBar: current == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  onPressed: _writeBlocked ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存配置'),
                ),
              ),
            ),
    );
  }
}
