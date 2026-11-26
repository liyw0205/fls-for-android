import 'package:flutter/material.dart';

import '../models/panel_notify.dart';
import '../services/panel_api_client.dart';
import '../services/panel_notify_manager.dart';
import 'panel_notify_deliveries_view.dart';

class PanelNotifyView extends StatefulWidget {
  const PanelNotifyView({
    super.key,
    required this.manager,
    required this.onUnauthorized,
    this.recovery,
  });
  final PanelNotifyManager manager;
  final Future<void> Function(PanelApiException) onUnauthorized;
  final PanelNotifyRecovery? recovery;

  @override
  State<PanelNotifyView> createState() => _PanelNotifyViewState();
}

class _PanelNotifyViewState extends State<PanelNotifyView> {
  final _search = TextEditingController();
  late final _recovery = widget.recovery ?? PanelNotifyRecovery();
  List<NotifyChannel> _channels = const [];
  PanelNotifyPage? _page;
  String _channel = '', _enabled = '';
  String? _error, _notice;
  bool _loading = false, _busy = false, _expired = false;
  int _generation = 0;
  NotifyDefaults? _defaults;
  bool _defaultConflict = false;
  final Set<String> _selected = {};
  bool get _locked => _busy || _recovery.requestId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _unauthorized(PanelApiException error) async {
    if (_expired) return;
    _expired = true;
    final navigator = Navigator.of(context), route = ModalRoute.of(context);
    await widget.onUnauthorized(error);
    if (!mounted) return;
    navigator.popUntil((value) => value == route);
    if (navigator.canPop()) navigator.pop();
  }

  Future<void> _failure(Object error) async {
    if (!mounted) return;
    if (error is PanelApiException && error.statusCode == 401) {
      await _unauthorized(error);
      return;
    }
    setState(() => _error = _message(error));
  }

  Future<void> _load([int page = 1]) async {
    if (_expired) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final channels = _channels.isEmpty
          ? await widget.manager.schema()
          : _channels;
      final result = await widget.manager.fetchPage(
        query: _search.text,
        channel: _channel,
        enabled: _enabled,
        page: page,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _channels = channels;
        _page = result;
      });
    } catch (error) {
      if (generation == _generation) await _failure(error);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _open([PanelNotifyItem? item]) async {
    if (_locked || _channels.isEmpty) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _NotifyEditor(
          manager: widget.manager,
          channels: _channels,
          recovery: _recovery,
          itemId: item?.id,
          onUnauthorized: _unauthorized,
        ),
      ),
    );
    if (mounted && !_expired) await _load(_page?.page ?? 1);
  }

  Future<void> _recover() async {
    final id = _recovery.requestId;
    if (id == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.manager.status(id);
      if (!mounted) return;
      if (result.saved == true) {
        _recovery.requestId = null;
        setState(
          () =>
              _notice = result.currentMatches ? '原通知操作已完成' : '原通知操作已完成，此后配置有变化',
        );
        _defaults = null;
        await _load(_page?.page ?? 1);
      } else if (result.saved == false) {
        if (await _confirm(
          context,
          '原操作未保存',
          '已核对原提交未保存。结束恢复并重新读取当前通知？',
          '结束恢复',
        )) {
          _recovery.requestId = null;
          _defaults = null;
          await _load(_page?.page ?? 1);
        }
      } else {
        setState(() => _notice = '原提交结果仍未知，请稍后重新查询');
      }
    } catch (error) {
      await _failure(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(Map<String, Object?> body) async {
    final id = PanelNotifyManager.newRequestId();
    _recovery.requestId = id;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final result = await widget.manager.submit({...body, 'request_id': id});
      if (result.saved != null) _recovery.requestId = null;
      if (!mounted) return;
      setState(() {
        _notice = result.saved == true ? '通知设置已保存' : '结果尚未确认，请查询原提交';
        if (result.saved == true) _defaults = null;
      });
      await _load(_page?.page ?? 1);
    } on PanelApiException catch (error) {
      if (error.statusCode != 401 && error.data?['saved'] is bool) {
        _recovery.requestId = null;
      }
      if (error.data?['saved'] == true && mounted) {
        setState(() {
          _notice = '通知设置已保存，请核对当前状态';
          _defaults = null;
        });
        await _load(_page?.page ?? 1);
      } else {
        if (body['action'] == 'default' &&
            error.data?['conflict'] == true &&
            mounted) {
          setState(() => _defaultConflict = true);
        }
        await _failure(error);
      }
    } catch (error) {
      await _failure(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _action(PanelNotifyItem item, String action) async {
    if (action == 'test') {
      await _test(item);
      return;
    }
    if (action == 'edit') {
      await _open(item);
      return;
    }
    if (_locked) return;
    final label = action == 'delete'
        ? '删除通知'
        : item.enabled
        ? '停用通知'
        : '启用通知';
    if (!await _confirm(
      context,
      '$label？',
      '${item.name}\n单独引用的任务：${item.referenceCount}${item.isDefault ? '\n当前为默认渠道，删除或停用会移出默认选择。' : ''}',
      '确认',
    )) {
      return;
    }
    if (!mounted) return;
    await _submit({
      'action': action,
      'item_id': item.id,
      'version': item.version,
      if (action == 'toggle') 'enabled': !item.enabled,
    });
  }

  Future<void> _deliveries({String? requestId}) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => requestId == null
            ? PanelNotifyDeliveriesView(
                manager: widget.manager,
                recovery: _recovery,
                onUnauthorized: _unauthorized,
              )
            : PanelNotifyDeliveryView(
                manager: widget.manager,
                recovery: _recovery,
                onUnauthorized: _unauthorized,
                requestId: requestId,
              ),
      ),
    );
    if (mounted && !_expired) setState(() {});
  }

  Future<void> _test(PanelNotifyItem item) async {
    if (_locked || !item.enabled) return;
    if (!await _confirm(
      context,
      '发送测试通知？',
      '渠道：${item.name}\n将发送一条固定测试通知。保存配置本身不会发送通知。',
      '确认发送',
    )) {
      return;
    }
    if (!mounted) return;
    final id = PanelNotifyManager.newRequestId();
    _recovery.deliveryRequests.add(id);
    var rejected = false;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.manager.sendTest(item, id);
    } catch (error) {
      if (error is PanelApiException &&
          error.statusCode != 401 &&
          error.data?['accepted'] == false) {
        rejected = true;
        _recovery.deliveryRequests.remove(id);
      }
      await _failure(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && !_expired && !rejected) await _deliveries(requestId: id);
  }

  Future<void> _editDefaults() async {
    if (_locked) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.manager.defaults();
      if (!mounted) return;
      setState(() {
        _defaults = result;
        _defaultConflict = false;
        _selected
          ..clear()
          ..addAll(result.ids);
      });
    } catch (error) {
      await _failure(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveDefaults() async {
    if (_locked || _defaults == null || _defaultConflict) return;
    if (!await _confirm(
      context,
      '保存默认渠道？',
      '已选择 ${_selected.length} 个渠道。使用默认通知的任务将采用此选择。',
      '确认保存',
    )) {
      return;
    }
    if (!mounted) return;
    await _submit({
      'action': 'default',
      'version': _defaults!.version,
      'default_ids': _selected.toList()..sort(),
    });
  }

  Future<void> _reviewDefaults() async {
    setState(() => _busy = true);
    try {
      final current = await widget.manager.defaults();
      if (!mounted) return;
      if (await _confirm(
        context,
        '核对默认通知',
        '服务器当前选择 ${current.ids.length} 个渠道，本地选择 ${_selected.length} 个渠道。保留本地选择并基于当前版本重新确认保存？',
        '保留本地选择',
      )) {
        if (mounted) {
          setState(() {
            _defaults = current;
            _defaultConflict = false;
            _error = null;
            _notice = '已读取当前版本，请核对渠道状态后重新保存';
          });
        }
        await _load(_page?.page ?? 1);
      }
    } catch (error) {
      await _failure(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selecting = _defaults != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(selecting ? '默认通知 (${_selected.length})' : '通知渠道'),
        actions: [
          IconButton(
            tooltip: '通知投递历史',
            onPressed: _busy ? null : () => _deliveries(),
            icon: const Icon(Icons.history),
          ),
          IconButton(
            tooltip: '刷新通知',
            onPressed: _busy || _loading ? null : () => _load(_page?.page ?? 1),
            icon: const Icon(Icons.refresh),
          ),
          if (!selecting)
            IconButton(
              tooltip: '选择默认通知',
              onPressed: _locked ? null : _editDefaults,
              icon: const Icon(Icons.checklist),
            ),
          if (!selecting)
            IconButton(
              tooltip: '新增通知',
              onPressed: _locked || _channels.isEmpty ? null : () => _open(),
              icon: const Icon(Icons.add),
            ),
          if (selecting)
            IconButton(
              tooltip: '取消默认选择',
              onPressed: _busy ? null : () => setState(() => _defaults = null),
              icon: const Icon(Icons.close),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      labelText: '搜索通知',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onSubmitted: (_) => _load(),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _channel,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: '渠道类型'),
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text('全部渠道'),
                            ),
                            for (final item in _channels)
                              DropdownMenuItem(
                                value: item.id,
                                child: Text(
                                  item.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _loading
                              ? null
                              : (value) {
                                  setState(() => _channel = value!);
                                  _load();
                                },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _enabled,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: '状态'),
                          items: const [
                            DropdownMenuItem(value: '', child: Text('全部状态')),
                            DropdownMenuItem(value: '1', child: Text('已启用')),
                            DropdownMenuItem(value: '0', child: Text('已停用')),
                          ],
                          onChanged: _loading
                              ? null
                              : (value) {
                                  setState(() => _enabled = value!);
                                  _load();
                                },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_loading || _busy) const LinearProgressIndicator(),
            if (_error != null || _notice != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: SelectableText(_error ?? _notice!),
              ),
            if (_recovery.requestId != null)
              TextButton.icon(
                onPressed: _busy ? null : _recover,
                icon: const Icon(Icons.sync),
                label: const Text('查询原通知提交'),
              ),
            if (_recovery.deliveryRequests.isNotEmpty)
              TextButton.icon(
                onPressed: _busy ? null : () => _deliveries(),
                icon: const Icon(Icons.sync),
                label: Text('待核对投递 (${_recovery.deliveryRequests.length})'),
              ),
            Expanded(
              child: _page == null
                  ? const SizedBox()
                  : _page!.items.isEmpty
                  ? const Center(child: Text('暂无通知渠道'))
                  : ListView.separated(
                      itemCount: _page!.items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = _page!.items[index];
                        final label =
                            _channels
                                .where((c) => c.id == item.channel)
                                .firstOrNull
                                ?.name ??
                            item.channel;
                        final subtitle =
                            '$label · ${item.enabled ? '已启用' : '已停用'}${item.isDefault ? ' · 默认' : ''}\n${item.logMode == 'trimmed' ? '裁剪日志' : '完整日志'} · 引用 ${item.referenceCount}';
                        if (selecting) {
                          return CheckboxListTile(
                            title: Text(item.name),
                            subtitle: Text(subtitle),
                            value: _selected.contains(item.id),
                            onChanged:
                                _locked ||
                                    (!item.enabled &&
                                        !_selected.contains(item.id))
                                ? null
                                : (value) => setState(() {
                                    if (value == true) {
                                      _selected.add(item.id);
                                    } else {
                                      _selected.remove(item.id);
                                    }
                                  }),
                          );
                        }
                        return ListTile(
                          title: Text(item.name),
                          subtitle: Text(subtitle),
                          onTap: _locked ? null : () => _open(item),
                          trailing: PopupMenuButton<String>(
                            tooltip: '通知操作',
                            enabled: !_locked,
                            onSelected: (value) => _action(item, value),
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'edit',
                                child: Text('编辑'),
                              ),
                              PopupMenuItem(
                                value: 'test',
                                enabled: item.enabled,
                                child: const Text('发送测试通知'),
                              ),
                              PopupMenuItem(
                                value: 'toggle',
                                child: Text(item.enabled ? '停用' : '启用'),
                              ),
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text('删除'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            if (_page != null)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: '上一页',
                    onPressed: _loading || _page!.page <= 1
                        ? null
                        : () => _load(_page!.page - 1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Flexible(
                    child: Text(
                      '${_page!.page} / ${_page!.pages} · ${_page!.total} 项',
                    ),
                  ),
                  IconButton(
                    tooltip: '下一页',
                    onPressed: _loading || _page!.page >= _page!.pages
                        ? null
                        : () => _load(_page!.page + 1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            if (selecting)
              Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  onPressed: _locked
                      ? null
                      : _defaultConflict
                      ? _reviewDefaults
                      : _saveDefaults,
                  icon: Icon(
                    _defaultConflict ? Icons.compare_arrows : Icons.save,
                  ),
                  label: Text(_defaultConflict ? '核对默认选择' : '保存默认渠道'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NotifyEditor extends StatefulWidget {
  const _NotifyEditor({
    required this.manager,
    required this.channels,
    required this.recovery,
    required this.onUnauthorized,
    this.itemId,
  });
  final PanelNotifyManager manager;
  final List<NotifyChannel> channels;
  final PanelNotifyRecovery recovery;
  final String? itemId;
  final Future<void> Function(PanelApiException) onUnauthorized;
  @override
  State<_NotifyEditor> createState() => _NotifyEditorState();
}

class _NotifyEditorState extends State<_NotifyEditor>
    with WidgetsBindingObserver {
  final _name = TextEditingController();
  final Map<String, TextEditingController> _fields = {};
  final Map<String, String> _choices = {};
  final Set<String> _revealed = {};
  PanelNotifyItem? _baseline;
  late String _channel = widget.channels.first.id;
  String _logMode = 'full';
  bool _enabled = true,
      _loading = false,
      _busy = false,
      _dirty = false,
      _allowPop = false,
      _foreground = true;
  bool _conflict = false;
  int _channelRevision = 0;
  String? _error, _notice;
  Map<String, Object?>? _pending;
  NotifyChannel get _schema =>
      widget.channels.firstWhere((c) => c.id == _channel);
  bool get _locked => _busy || _loading || _pending != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    for (final channel in widget.channels) {
      for (final field in channel.fields) {
        _fields.putIfAbsent(field.key, TextEditingController.new);
      }
    }
    if (widget.itemId != null) _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) {
      setState(() {
        _foreground = state == AppLifecycleState.resumed;
        _revealed.clear();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _name.dispose();
    for (final field in _fields.values) {
      field.clear();
      field.dispose();
    }
    _pending?.clear();
    super.dispose();
  }

  Future<void> _failure(Object error) async {
    if (!mounted) return;
    if (error is PanelApiException && error.statusCode == 401) {
      for (final field in _fields.values) {
        field.clear();
      }
      _pending?.clear();
      await widget.onUnauthorized(error);
      return;
    }
    setState(() => _error = _message(error));
  }

  void _populate(PanelNotifyItem item) {
    _baseline = item;
    _channel = item.channel;
    _name.text = item.name;
    _logMode = item.logMode;
    _enabled = item.enabled;
    for (final entry in _fields.entries) {
      entry.value.text = item.values[entry.key] ?? '';
    }
    _choices.clear();
    _revealed.clear();
    _dirty = false;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final item = await widget.manager.fetch(widget.itemId!);
      if (!widget.channels.any((c) => c.id == item.channel)) {
        throw const FormatException('通知渠道不受支持');
      }
      if (mounted) setState(() => _populate(item));
    } catch (error) {
      await _failure(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _changeChannel(String channel) async {
    if (channel == _channel) return;
    final accepted = await _confirm(
      context,
      '更换通知渠道？',
      '将清除当前表单的渠道字段。保存时会清除服务器上原渠道的全部字段。',
      '更换渠道',
    );
    if (!mounted) return;
    setState(() {
      _channelRevision++;
      if (!accepted) return;
      _channel = channel;
      for (final field in _fields.values) {
        field.clear();
      }
      _choices.clear();
      _revealed.clear();
      _dirty = true;
    });
  }

  Map<String, Object?> _body() {
    final base = _baseline;
    final changedChannel = base != null && base.channel != _channel;
    final settings = <String, Object?>{
      if (base == null || base.name != _name.text) 'name': _name.text,
      if (base == null || changedChannel) 'channel': _channel,
      if (base == null || base.logMode != _logMode) 'log_mode': _logMode,
      if (base == null || base.enabled != _enabled) 'enabled': _enabled,
    };
    return {
      'action': base == null ? 'new' : 'edit',
      'request_id': PanelNotifyManager.newRequestId(),
      if (base != null) 'item_id': base.id,
      if (base != null) 'version': base.version,
      'settings': settings,
      if (changedChannel) 'reset_channel': true,
      'values': {
        for (final field in _schema.fields)
          if (!field.sensitive &&
              (base == null ||
                  changedChannel ||
                  _fields[field.key]!.text != (base.values[field.key] ?? '')))
            field.key: _fields[field.key]!.text,
      },
      'credentials': {
        for (final field in _schema.fields)
          if (field.sensitive && (_choices[field.key] ?? 'keep') != 'keep')
            field.key: {
              'action': _choices[field.key],
              if (_choices[field.key] == 'replace')
                'value': _fields[field.key]!.text,
            },
      },
    };
  }

  Future<void> _save() async {
    if (_locked || _conflict || (widget.itemId != null && _baseline == null)) {
      return;
    }
    for (final field in _schema.fields) {
      if (field.sensitive &&
          _choices[field.key] == 'replace' &&
          _fields[field.key]!.text.trim().isEmpty) {
        setState(() => _error = '${field.label}不能为空');
        return;
      }
    }
    if (!await _confirm(
      context,
      '保存通知设置？',
      '${_name.text.isEmpty ? _schema.name : _name.text}\n${_schema.name} · ${_enabled ? '已启用' : '已停用'}',
      '确认保存',
    )) {
      return;
    }
    if (!mounted) return;
    _pending = _body();
    widget.recovery.requestId = _pending!['request_id'] as String;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final result = await widget.manager.submit(_pending!);
      if (result.saved == true) {
        _saved();
        return;
      }
      if (result.saved == false) _clearPending();
      if (mounted) setState(() => _notice = '结果尚未确认，请查询原提交');
    } on PanelApiException catch (error) {
      if (error.statusCode != 401 && error.data?['saved'] == true) {
        _saved();
        return;
      }
      if (error.statusCode != 401 && error.data?['saved'] == false) {
        _clearPending();
      }
      if (mounted) setState(() => _conflict = error.data?['conflict'] == true);
      await _failure(error);
    } catch (error) {
      await _failure(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _clearPending() {
    _pending?.clear();
    _pending = null;
    widget.recovery.requestId = null;
  }

  void _saved() {
    _clearPending();
    if (!mounted) return;
    setState(() {
      _dirty = false;
      _allowPop = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _recover() async {
    final id = widget.recovery.requestId;
    if (id == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.manager.status(id);
      if (!mounted) return;
      if (result.saved == true) {
        _saved();
        return;
      }
      if (result.saved == false) {
        if (await _confirm(
          context,
          '原操作未保存',
          '保留表单并结束此次恢复？再次保存需要重新确认。',
          '结束恢复',
        )) {
          _clearPending();
          if (mounted) setState(() => _notice = '原操作未保存，表单已保留');
        }
      } else {
        setState(() => _notice = '原提交结果仍未知，暂不能再次保存');
      }
    } catch (error) {
      await _failure(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _merge() async {
    if (_busy || _pending != null || _baseline == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final current = await widget.manager.fetch(_baseline!.id);
      if (!mounted) return;
      final base = _baseline!;
      if (current.channel != base.channel) {
        if (await _confirm(
          context,
          '服务器渠道已更换',
          '当前为 ${current.channel}。载入服务器配置会丢弃本地表单。',
          '载入当前配置',
        )) {
          if (mounted) {
            setState(() {
              _populate(current);
              _conflict = false;
            });
          }
        }
        return;
      }
      if (!await _confirm(
        context,
        '核对当前通知',
        '${current.name}\n${current.enabled ? '已启用' : '已停用'} · ${current.logMode}\n'
            '${widget.channels.firstWhere((c) => c.id == current.channel).fields.map((field) => '${field.label}：${field.sensitive ? (current.configured[field.key] == true ? '已设置' : '未设置') : (current.values[field.key] ?? '')}').join('\n')}\n'
            '仅将本地改动合并到当前版本，保持的凭据使用服务器当前值。',
        '合并本地改动',
      )) {
        return;
      }
      if (!mounted) return;
      setState(() {
        if (_name.text == base.name) _name.text = current.name;
        if (_enabled == base.enabled) _enabled = current.enabled;
        if (_logMode == base.logMode) _logMode = current.logMode;
        if (_channel == base.channel) {
          for (final field in _schema.fields.where((f) => !f.sensitive)) {
            if (_fields[field.key]!.text == (base.values[field.key] ?? '')) {
              _fields[field.key]!.text = current.values[field.key] ?? '';
            }
          }
        }
        _baseline = current;
        _conflict = false;
        _notice = '已核对并合并，请重新确认保存';
      });
    } catch (error) {
      await _failure(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (_busy || _allowPop) return;
    if (await _confirm(
      context,
      '离开编辑？',
      _pending != null ? '将清除表单内容，原提交仍可在通知列表查询。' : '将丢弃尚未保存的表单。',
      '离开',
    )) {
      if (!mounted) return;
      setState(() => _allowPop = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    }
  }

  Widget _field(NotifyField field) {
    final controller = _fields[field.key]!;
    if (field.sensitive) {
      final choice = _choices[field.key] ?? 'keep';
      final configured =
          _channel == _baseline?.channel &&
          _baseline?.configured[field.key] == true;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(field.label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: ValueKey('intent-${field.key}-$choice'),
            initialValue: choice,
            isExpanded: true,
            decoration: InputDecoration(labelText: configured ? '已设置' : '未设置'),
            items: const [
              DropdownMenuItem(value: 'keep', child: Text('保持')),
              DropdownMenuItem(value: 'replace', child: Text('替换')),
              DropdownMenuItem(value: 'clear', child: Text('清空')),
            ],
            onChanged: _locked
                ? null
                : (value) => setState(() {
                    _choices[field.key] = value!;
                    controller.clear();
                    _revealed.remove(field.key);
                    _dirty = true;
                  }),
          ),
          if (choice == 'replace')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: controller,
                enabled: !_locked,
                maxLength: field.maxLength,
                obscureText: !_revealed.contains(field.key),
                maxLines: field.multiline && _revealed.contains(field.key)
                    ? 4
                    : 1,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: field.label,
                  suffixIcon: IconButton(
                    tooltip: _revealed.contains(field.key) ? '隐藏输入' : '显示输入',
                    icon: Icon(
                      _revealed.contains(field.key)
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    onPressed: () => setState(() {
                      if (!_revealed.add(field.key)) {
                        _revealed.remove(field.key);
                      }
                    }),
                  ),
                ),
                onChanged: (_) => setState(() => _dirty = true),
              ),
            ),
        ],
      );
    }
    if (field.kind == 'select' || field.kind == 'boolean') {
      final value = field.options.contains(controller.text)
          ? controller.text
          : '';
      return DropdownButtonFormField<String>(
        key: ValueKey('${field.key}-$value'),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: field.label),
        items: [
          const DropdownMenuItem(value: '', child: Text('默认')),
          for (final option in field.options)
            DropdownMenuItem(
              value: option,
              child: Text(
                field.kind == 'boolean'
                    ? (option == 'true' ? '是' : '否')
                    : option,
              ),
            ),
        ],
        onChanged: _locked
            ? null
            : (value) => setState(() {
                controller.text = value!;
                _dirty = true;
              }),
      );
    }
    return TextField(
      controller: controller,
      enabled: !_locked,
      maxLength: field.maxLength,
      keyboardType: field.kind == 'integer'
          ? const TextInputType.numberWithOptions(signed: true)
          : TextInputType.text,
      decoration: InputDecoration(labelText: field.label),
      onChanged: (_) => setState(() => _dirty = true),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowPop || (!_dirty && !_busy && _pending == null),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _leave();
    },
    child: Scaffold(
      appBar: AppBar(title: Text(widget.itemId == null ? '新增通知' : '编辑通知')),
      body: !_foreground
          ? const SizedBox.expand()
          : SafeArea(
              child: Column(
                children: [
                  if (_busy || _loading) const LinearProgressIndicator(),
                  Expanded(
                    child: _loading
                        ? const SizedBox()
                        : ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              if (_error != null || _notice != null)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: SelectableText(_error ?? _notice!),
                                ),
                              if (widget.itemId != null && _baseline == null)
                                TextButton.icon(
                                  onPressed: _busy ? null : _load,
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('重新读取通知'),
                                ),
                              if (_baseline?.invalidFields.isNotEmpty == true)
                                const Padding(
                                  padding: EdgeInsets.only(bottom: 16),
                                  child: Text('部分旧字段格式无法展示，未修改的字段会保留。'),
                                ),
                              TextField(
                                controller: _name,
                                enabled: !_locked,
                                maxLength: 200,
                                decoration: const InputDecoration(
                                  labelText: '通知名称',
                                ),
                                onChanged: (_) => setState(() => _dirty = true),
                              ),
                              const SizedBox(height: 12),
                              DropdownButtonFormField<String>(
                                key: ValueKey('$_channel-$_channelRevision'),
                                initialValue: _channel,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: '渠道类型',
                                ),
                                items: [
                                  for (final channel in widget.channels)
                                    DropdownMenuItem(
                                      value: channel.id,
                                      child: Text(channel.name),
                                    ),
                                ],
                                onChanged: _locked
                                    ? null
                                    : (value) => _changeChannel(value!),
                              ),
                              const SizedBox(height: 16),
                              DropdownButtonFormField<String>(
                                key: ValueKey('log-$_logMode'),
                                initialValue:
                                    const ['full', 'trimmed'].contains(_logMode)
                                    ? _logMode
                                    : null,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: '日志模式',
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: 'full',
                                    child: Text('完整日志'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'trimmed',
                                    child: Text('裁剪日志'),
                                  ),
                                ],
                                onChanged: _locked
                                    ? null
                                    : (value) => setState(() {
                                        _logMode = value!;
                                        _dirty = true;
                                      }),
                              ),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('启用通知'),
                                value: _enabled,
                                onChanged: _locked
                                    ? null
                                    : (value) => setState(() {
                                        _enabled = value;
                                        _dirty = true;
                                      }),
                              ),
                              const Divider(),
                              for (final field in _schema.fields)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                  child: _field(field),
                                ),
                            ],
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: _pending != null
                        ? FilledButton.icon(
                            onPressed: _busy ? null : _recover,
                            icon: const Icon(Icons.sync),
                            label: const Text('查询原通知提交'),
                          )
                        : _conflict
                        ? FilledButton.icon(
                            onPressed: _busy ? null : _merge,
                            icon: const Icon(Icons.compare_arrows),
                            label: const Text('核对并合并'),
                          )
                        : FilledButton.icon(
                            onPressed:
                                _locked ||
                                    (widget.itemId != null && _baseline == null)
                                ? null
                                : _save,
                            icon: const Icon(Icons.save),
                            label: const Text('保存通知'),
                          ),
                  ),
                ],
              ),
            ),
    ),
  );
}

String _message(Object error) {
  if (error is PanelApiException) {
    final count = error.data?['reference_count'];
    return '${error.message}${count is int && count > 0 ? '\n关联任务：$count，请先调整任务通知。' : ''}';
  }
  return '通知操作未完成，请刷新或查询原提交';
}

Future<bool> _confirm(
  BuildContext context,
  String title,
  String message,
  String action,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
