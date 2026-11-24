import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../models/panel_task_draft.dart';
import '../services/panel_api_client.dart';
import '../services/panel_tasks_manager.dart';

class PanelTaskEditorView extends StatefulWidget {
  const PanelTaskEditorView({
    super.key,
    required this.manager,
    required this.onUnauthorized,
    this.taskId,
    this.initial,
  });

  final PanelTasksManager manager;
  final Future<void> Function(Object error) onUnauthorized;
  final String? taskId;
  final PanelTaskDraft? initial;

  @override
  State<PanelTaskEditorView> createState() => _PanelTaskEditorViewState();
}

class _PanelTaskEditorViewState extends State<PanelTaskEditorView> {
  static const _hexDigits = '0123456789abcdef';
  static final _secureRandom = Random.secure();

  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _remark = TextEditingController();
  final _command = TextEditingController();
  final _cron = TextEditingController();
  final _configPath = TextEditingController();
  final _delaySeconds = TextEditingController();
  final _retryAttempts = TextEditingController();
  final _retryInterval = TextEditingController();
  final _environmentRows = <_TaskEnvironmentRow>[];
  final _requestId = List.generate(
    32,
    (_) => _hexDigits[_secureRandom.nextInt(_hexDigits.length)],
  ).join();

  late final PanelTaskDraft _initial;
  Set<String> _notifyIds = {};
  PanelTaskFormOptions? _options;
  String _collectionId = '';
  String _proxyId = '';
  String _notifyMode = 'default';
  String _delayMode = 'none';
  bool _enabled = true;
  bool _loadingOptions = true;
  bool _saving = false;
  bool _schedulerReloadRequired = false;
  String? _optionsError;
  String? _schedulerReloadMessage;

  bool get _isEditing => widget.taskId != null;

  @override
  void initState() {
    super.initState();
    _initial = widget.initial ?? PanelTaskDraft.empty();
    _name.text = _initial.name;
    _remark.text = _initial.remark;
    _command.text = _initial.command;
    _cron.text = _initial.cron;
    _configPath.text = _initial.configPath;
    _delaySeconds.text = '${_initial.randomDelaySeconds}';
    _retryAttempts.text = '${_initial.retryAttempts}';
    _retryInterval.text = '${_initial.retryIntervalSeconds}';
    _collectionId = _initial.collectionId;
    _proxyId = _initial.proxyId;
    _notifyMode = _initial.notifyMode;
    _notifyIds = _initial.notifyIds.toSet();
    _delayMode = _initial.randomDelayMode;
    _enabled = _initial.enabled;
    for (final entry in _initial.environment.entries) {
      _environmentRows.add(_TaskEnvironmentRow(entry.key, entry.value));
    }
    unawaited(_loadOptions());
  }

  @override
  void dispose() {
    _name.dispose();
    _remark.dispose();
    _command.dispose();
    _cron.dispose();
    _configPath.dispose();
    _delaySeconds.dispose();
    _retryAttempts.dispose();
    _retryInterval.dispose();
    for (final row in _environmentRows) {
      row.dispose();
    }
    super.dispose();
  }

  Future<void> _loadOptions() async {
    setState(() {
      _loadingOptions = true;
      _optionsError = null;
    });
    try {
      final options = await widget.manager.fetchTaskFormOptions();
      if (!mounted) return;
      setState(() {
        _options = options;
        _loadingOptions = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await widget.onUnauthorized(error);
        return;
      }
      setState(() {
        _optionsError = error.toString();
        _loadingOptions = false;
      });
    }
  }

  Future<void> _save() async {
    if (_saving ||
        _schedulerReloadRequired ||
        _options == null ||
        _formKey.currentState?.validate() != true) {
      return;
    }
    final options = _options!;
    if (_collectionId.isNotEmpty &&
        !options.collections.any((item) => item.id == _collectionId)) {
      _showSaveError('当前合集不存在，请选择其他合集或移出合集');
      return;
    }
    if (_proxyId.isNotEmpty &&
        !options.proxies.any((item) => item.id == _proxyId)) {
      _showSaveError('当前代理已停用或删除，请选择有效代理或不使用代理');
      return;
    }
    if (_notifyMode == 'custom' &&
        _notifyIds.any(
          (id) => !options.notifications.any((item) => item.id == id),
        )) {
      _showSaveError('请移除已停用的通知渠道后再保存');
      return;
    }
    final environment = <String, String>{};
    for (final row in _environmentRows) {
      final key = row.key.text.trim();
      final value = row.value.text;
      if (key.isEmpty && value.isEmpty) continue;
      if (key.isEmpty || environment.containsKey(key)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('任务变量名不能为空或重复')));
        return;
      }
      environment[key] = value;
    }

    final task = PanelTaskDraft(
      name: _name.text.trim(),
      remark: _remark.text.trim(),
      command: _command.text.trim(),
      cron: _cron.text.trim(),
      configPath: _configPath.text.trim(),
      collectionId: _collectionId,
      enabled: _enabled,
      environment: environment,
      proxyId: _proxyId,
      notifyMode: _notifyMode == 'custom' && _notifyIds.isEmpty
          ? 'none'
          : _notifyMode,
      notifyIds: _notifyMode == 'custom' ? _notifyIds.toList() : const [],
      randomDelayMode: _delayMode,
      randomDelaySeconds: int.tryParse(_delaySeconds.text) ?? 1,
      retryAttempts: int.tryParse(_retryAttempts.text) ?? 0,
      retryIntervalSeconds: int.tryParse(_retryInterval.text) ?? 60,
      updatedAt: _initial.updatedAt,
    );

    setState(() => _saving = true);
    try {
      if (_isEditing) {
        await widget.manager.updateTask(
          widget.taskId!,
          task,
          expectedUpdatedAt: _initial.updatedAt,
        );
      } else {
        await widget.manager.createTask(task, requestId: _requestId);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await widget.onUnauthorized(error);
        return;
      }
      if (error is PanelApiException &&
          error.data?['saved'] == true &&
          error.data?['reload_required'] == true) {
        setState(() {
          _schedulerReloadRequired = true;
          _schedulerReloadMessage = error.message;
        });
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reloadScheduler() async {
    if (_saving || !_schedulerReloadRequired) return;
    setState(() => _saving = true);
    try {
      await widget.manager.reloadScheduler();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await widget.onUnauthorized(error);
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showSaveError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final options = _options;
    return Scaffold(
      appBar: AppBar(title: Text(_isEditing ? '编辑任务' : '新建任务')),
      body: _loadingOptions
          ? const Center(child: CircularProgressIndicator())
          : options == null
          ? _optionsFailure()
          : _buildForm(context, options),
      bottomNavigationBar: options == null
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton.icon(
                onPressed: _saving
                    ? null
                    : _schedulerReloadRequired
                    ? _reloadScheduler
                    : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        _schedulerReloadRequired
                            ? Icons.refresh
                            : Icons.save_outlined,
                      ),
                label: Text(
                  _saving
                      ? (_schedulerReloadRequired ? '正在重载' : '保存中')
                      : _schedulerReloadRequired
                      ? '重新加载调度器'
                      : '保存任务',
                ),
              ),
            ),
    );
  }

  Widget _optionsFailure() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 34),
          const SizedBox(height: 12),
          Text(_optionsError ?? '无法读取任务选项', textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: _loadOptions,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    ),
  );

  Widget _buildForm(BuildContext context, PanelTaskFormOptions options) {
    final collectionItems = [
      const DropdownMenuItem(value: '', child: Text('不放入合集')),
      ...options.collections.map(
        (item) => DropdownMenuItem(value: item.id, child: Text(item.name)),
      ),
    ];
    final proxyItems = [
      const DropdownMenuItem(value: '', child: Text('不使用代理')),
      ...options.proxies.map(
        (item) => DropdownMenuItem(
          value: item.id,
          child: Text('${item.name} · ${item.detail}'),
        ),
      ),
    ];
    final collectionValue =
        options.collections.any((item) => item.id == _collectionId)
        ? _collectionId
        : '';
    final proxyValue = options.proxies.any((item) => item.id == _proxyId)
        ? _proxyId
        : '';

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (_schedulerReloadRequired) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '任务已保存，调度器尚未重载。不要重复保存。',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                  if (_schedulerReloadMessage case final message?) ...[
                    const SizedBox(height: 4),
                    Text(
                      message,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          _heading(context, '基本信息'),
          TextFormField(
            controller: _name,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: '任务名称'),
            validator: (value) =>
                value == null || value.trim().isEmpty ? '请输入任务名称' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _remark,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: '备注'),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _command,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(labelText: '运行命令'),
            validator: (value) =>
                value == null || value.trim().isEmpty ? '请输入运行命令' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _cron,
            decoration: const InputDecoration(
              labelText: 'Cron 表达式',
              hintText: '留空为手动任务',
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _configPath,
            decoration: const InputDecoration(
              labelText: '配置文件相对路径',
              hintText: '例如：folder/config.yml',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: collectionValue,
            decoration: const InputDecoration(labelText: '所属合集'),
            items: collectionItems,
            onChanged: (value) => setState(() => _collectionId = value ?? ''),
          ),
          if (_collectionId.isNotEmpty && collectionValue.isEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '当前合集已删除，请选择其他合集或移出合集。',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: proxyValue,
            decoration: const InputDecoration(labelText: '代理'),
            items: proxyItems,
            onChanged: (value) => setState(() => _proxyId = value ?? ''),
          ),
          if (_proxyId.isNotEmpty && proxyValue.isEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '当前代理已停用或删除，请选择有效代理或改为不使用代理。',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const Divider(height: 28),
          _heading(context, '结束通知'),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'none', label: Text('关闭')),
              ButtonSegment(value: 'default', label: Text('默认')),
              ButtonSegment(value: 'custom', label: Text('指定')),
            ],
            selected: {_notifyMode},
            onSelectionChanged: (selection) =>
                setState(() => _notifyMode = selection.first),
          ),
          if (_notifyMode == 'custom') ...[
            const SizedBox(height: 8),
            if (options.notifications.isEmpty)
              const Text('没有已启用的通知渠道')
            else
              Wrap(
                spacing: 6,
                runSpacing: 2,
                children: options.notifications
                    .map((item) {
                      return FilterChip(
                        label: Text(item.name),
                        selected: _notifyIds.contains(item.id),
                        onSelected: (selected) => setState(() {
                          if (selected) {
                            _notifyIds.add(item.id);
                          } else {
                            _notifyIds.remove(item.id);
                          }
                        }),
                      );
                    })
                    .toList(growable: false),
              ),
            ..._notifyIds
                .where(
                  (id) => !options.notifications.any((item) => item.id == id),
                )
                .map(
                  (id) => InputChip(
                    label: Text(
                      '不可用渠道 · ${id.substring(0, min(8, id.length))}',
                    ),
                    onDeleted: () => setState(() => _notifyIds.remove(id)),
                  ),
                ),
          ],
          const Divider(height: 28),
          _heading(context, '随机延迟'),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'none', label: Text('关闭')),
              ButtonSegment(value: 'default', label: Text('全局')),
              ButtonSegment(value: 'custom', label: Text('自定义')),
            ],
            selected: {_delayMode},
            onSelectionChanged: (selection) =>
                setState(() => _delayMode = selection.first),
          ),
          if (_delayMode == 'custom') ...[
            const SizedBox(height: 12),
            TextFormField(
              controller: _delaySeconds,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '随机延迟上限（秒）'),
              validator: (value) => _boundedInteger(value, 1, 120),
            ),
          ],
          const Divider(height: 28),
          _heading(context, '失败重试'),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _retryAttempts,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '次数（0-5）'),
                  validator: (value) => _boundedInteger(value, 0, 5),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _retryInterval,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '间隔秒数'),
                  validator: (value) => _boundedInteger(value, 5, 3600),
                ),
              ),
            ],
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('启用任务'),
            value: _enabled,
            onChanged: (value) => setState(() => _enabled = value),
          ),
          const Divider(height: 28),
          Row(
            children: [
              Expanded(child: _heading(context, '任务变量')),
              IconButton(
                tooltip: '新增变量',
                onPressed: () => setState(
                  () => _environmentRows.add(_TaskEnvironmentRow('', '')),
                ),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          if (_environmentRows.isEmpty)
            const Text('暂无任务变量')
          else
            ..._environmentRows.asMap().entries.map((entry) {
              final index = entry.key;
              final row = entry.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  children: [
                    TextFormField(
                      controller: row.key,
                      decoration: InputDecoration(
                        labelText: '变量名',
                        suffixIcon: IconButton(
                          tooltip: '删除变量',
                          onPressed: () => _removeEnvironmentRow(index),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ),
                      validator: (value) {
                        if (row.value.text.isNotEmpty &&
                            (value == null || value.trim().isEmpty)) {
                          return '请输入变量名';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: row.value,
                      obscureText: !row.revealed,
                      maxLines: row.revealed ? 3 : 1,
                      decoration: InputDecoration(
                        labelText: '变量值',
                        suffixIcon: IconButton(
                          tooltip: row.revealed ? '隐藏变量值' : '显示变量值',
                          onPressed: () => setState(() {
                            row.revealed = !row.revealed;
                          }),
                          icon: Icon(
                            row.revealed
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _heading(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(title, style: Theme.of(context).textTheme.titleSmall),
  );

  String? _boundedInteger(String? raw, int minimum, int maximum) {
    final value = int.tryParse(raw ?? '');
    if (value == null || value < minimum || value > maximum) {
      return '请输入 $minimum 到 $maximum 之间的整数';
    }
    return null;
  }

  void _removeEnvironmentRow(int index) {
    final row = _environmentRows.removeAt(index);
    row.dispose();
    setState(() {});
  }
}

class _TaskEnvironmentRow {
  _TaskEnvironmentRow(String key, String value)
    : key = TextEditingController(text: key),
      value = TextEditingController(text: value);

  final TextEditingController key;
  final TextEditingController value;
  bool revealed = false;

  void dispose() {
    key.dispose();
    value.dispose();
  }
}
