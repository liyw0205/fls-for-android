import 'package:flutter/material.dart';

import '../models/panel_proxy.dart';
import '../services/panel_api_client.dart';
import '../services/panel_proxy_manager.dart';
import 'panel_proxy_checks_view.dart';

class PanelProxyView extends StatefulWidget {
  const PanelProxyView({
    super.key,
    required this.manager,
    required this.onUnauthorized,
    this.recovery,
  });
  final PanelProxyManager manager;
  final Future<void> Function(PanelApiException) onUnauthorized;
  final PanelProxyRecovery? recovery;

  @override
  State<PanelProxyView> createState() => _PanelProxyViewState();
}

class _PanelProxyViewState extends State<PanelProxyView> {
  final _search = TextEditingController();
  late final _recovery = widget.recovery ?? PanelProxyRecovery();
  PanelProxyPage? _page;
  String _type = '', _enabled = '';
  String? _error, _notice;
  bool _loading = false, _busy = false, _expired = false;
  int _generation = 0;
  final Map<String, PanelProxy> _selected = {};

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
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    await widget.onUnauthorized(error);
    if (!mounted) return;
    navigator.popUntil((value) => value == route);
    if (navigator.canPop()) navigator.pop();
  }

  Future<void> _load([int page = 1]) async {
    if (_expired) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.manager.fetchPage(
        query: _search.text,
        type: _type,
        enabled: _enabled.isEmpty ? null : _enabled == '1',
        page: page,
      );
      if (mounted && generation == _generation) setState(() => _page = result);
    } on PanelApiException catch (error) {
      if (!mounted || generation != _generation) return;
      if (error.statusCode == 401) {
        await _unauthorized(error);
        return;
      }
      setState(() => _error = error.message);
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = '代理列表读取失败');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _open([PanelProxy? proxy]) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _ProxyEditView(
          manager: widget.manager,
          recovery: _recovery,
          proxyId: proxy?.id,
          onUnauthorized: _unauthorized,
        ),
      ),
    );
    if (mounted) {
      setState(() {});
      await _load(_page?.page ?? 1);
    }
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
              _notice = result.currentMatches ? '原代理操作已完成' : '原代理操作已完成，此后配置有变化',
        );
        await _load(_page?.page ?? 1);
      } else if (result.saved == false) {
        if (await _confirm(
          context,
          '原操作未保存',
          '已核对原提交尚未保存。结束此次恢复并重新读取代理？',
          '结束恢复',
        )) {
          _recovery.requestId = null;
          await _load(_page?.page ?? 1);
        }
      } else {
        setState(() => _notice = '原提交结果仍未知，暂不能发起新操作');
      }
    } on PanelApiException catch (error) {
      if (!mounted) return;
      if (error.statusCode == 401) {
        await _unauthorized(error);
        return;
      }
      setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '原代理提交查询失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _action(PanelProxy proxy, String action) async {
    if (action == 'check') {
      await _checkProxy(proxy);
      return;
    }
    if (action == 'history') {
      await _history(proxyId: proxy.id);
      return;
    }
    if (action == 'edit') {
      await _open(proxy);
      return;
    }
    final label = action == 'delete'
        ? '删除代理'
        : proxy.enabled
        ? '停用代理'
        : '启用代理';
    if (!await _confirm(
      context,
      '$label？',
      '${proxy.name}\n${proxy.address}\n关联任务：${proxy.referenceCount}',
      '确认',
    )) {
      return;
    }
    if (!mounted) return;
    final id = PanelProxyManager.newRequestId();
    _recovery.requestId = id;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final result = await widget.manager.submit({
        'action': action,
        'request_id': id,
        'proxy_id': proxy.id,
        'version': proxy.version,
        if (action == 'toggle') 'enabled': !proxy.enabled,
      });
      if (result.saved == true) _recovery.requestId = null;
      if (mounted) {
        setState(
          () => _notice = result.saved == true ? '$label已完成' : '结果未知，请查询原提交',
        );
        await _load(_page?.page ?? 1);
      }
    } on PanelApiException catch (error) {
      if (!mounted) return;
      if (error.statusCode == 401) {
        await _unauthorized(error);
        return;
      }
      if (error.data?['saved'] is bool) _recovery.requestId = null;
      if (error.data?['saved'] == true) {
        setState(() => _notice = '$label已完成，请核对当前状态');
        await _load(_page?.page ?? 1);
        return;
      }
      setState(() => _error = _operationError(error));
    } catch (_) {
      if (mounted) setState(() => _error = '代理操作结果未知，请查询原提交');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _history({String proxyId = ''}) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PanelProxyChecksView(
          manager: widget.manager,
          recovery: _recovery,
          proxyId: proxyId,
          onUnauthorized: _unauthorized,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _checkProxy(PanelProxy proxy) async {
    if (_recovery.checkIds.isNotEmpty || _busy) return;
    final options = await proxyCheckOptions(
      context,
      customTargets: proxy.type != 'github',
    );
    if (options == null || !mounted) return;
    final id = PanelProxyManager.newRequestId();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PanelProxyCheckView(
          manager: widget.manager,
          recovery: _recovery,
          id: id,
          onUnauthorized: _unauthorized,
          submission: {
            'request_id': id,
            'proxy_id': proxy.id,
            'version': proxy.version,
            'kind': options.kind,
            if (options.targets != null) 'targets': options.targets,
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _batch() async {
    if (_selected.isEmpty || _recovery.checkIds.isNotEmpty || _busy) return;
    final options = await proxyCheckOptions(
      context,
      customTargets: _selected.values.any((proxy) => proxy.type != 'github'),
    );
    if (options == null || !mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PanelProxyBatchCheckView(
          manager: widget.manager,
          recovery: _recovery,
          proxies: _selected.values.toList(),
          options: options,
          onUnauthorized: _unauthorized,
        ),
      ),
    );
    if (mounted) setState(() => _selected.clear());
  }

  @override
  Widget build(BuildContext context) {
    final blocked = _busy || _loading || _recovery.requestId != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('代理管理'),
        actions: [
          IconButton(
            tooltip: '检测历史',
            onPressed: _busy ? null : _history,
            icon: const Icon(Icons.history),
          ),
          IconButton(
            tooltip: '刷新代理',
            onPressed: _busy || _loading ? null : () => _load(_page?.page ?? 1),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _search,
                  maxLength: 200,
                  onSubmitted: (_) => _load(),
                  decoration: InputDecoration(
                    labelText: '搜索代理',
                    counterText: '',
                    suffixIcon: IconButton(
                      tooltip: '搜索代理',
                      onPressed: _loading ? null : () => _load(),
                      icon: const Icon(Icons.search),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _type,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '代理类型'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('全部类型')),
                    for (final type in panelProxyTypes)
                      DropdownMenuItem(
                        value: type,
                        child: Text(_typeLabel(type)),
                      ),
                  ],
                  onChanged: _loading
                      ? null
                      : (value) {
                          _type = value!;
                          _load();
                        },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _enabled,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '启用状态'),
                  items: const [
                    DropdownMenuItem(value: '', child: Text('全部状态')),
                    DropdownMenuItem(value: '1', child: Text('已启用')),
                    DropdownMenuItem(value: '0', child: Text('已停用')),
                  ],
                  onChanged: _loading
                      ? null
                      : (value) {
                          _enabled = value!;
                          _load();
                        },
                ),
                if (_loading) const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: SelectableText(_error!),
                  ),
                if (_notice != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(_notice!),
                  ),
                if (_recovery.requestId != null) ...[
                  const Text('有未确认的代理提交'),
                  TextButton.icon(
                    onPressed: _busy ? null : _recover,
                    icon: const Icon(Icons.restore),
                    label: const Text('查询原提交'),
                  ),
                ],
                if (_recovery.checkIds.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => _history(),
                    icon: const Icon(Icons.restore),
                    label: const Text('查看未确认检测'),
                  ),
                if (_selected.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('已选择 ${_selected.length} / 12'),
                      TextButton.icon(
                        onPressed: blocked || _recovery.checkIds.isNotEmpty
                            ? null
                            : _batch,
                        icon: const Icon(Icons.network_check),
                        label: const Text('批量检测'),
                      ),
                      IconButton(
                        tooltip: '清除检测选择',
                        onPressed: () => setState(() => _selected.clear()),
                        icon: const Icon(Icons.clear),
                      ),
                    ],
                  ),
                if (_page != null && _page!.items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('暂无匹配代理'),
                  ),
                for (final proxy in _page?.items ?? <PanelProxy>[]) ...[
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Checkbox(
                      value: _selected.containsKey(proxy.id),
                      semanticLabel: '选择 ${proxy.name} 检测',
                      onChanged:
                          blocked ||
                              !proxy.enabled ||
                              (_selected.length >= 12 &&
                                  !_selected.containsKey(proxy.id))
                          ? null
                          : (value) => setState(() {
                              if (value == true) {
                                _selected[proxy.id] = proxy;
                              } else {
                                _selected.remove(proxy.id);
                              }
                            }),
                    ),
                    title: Text(proxy.name),
                    subtitle: Text(
                      '${_typeLabel(proxy.type)} · ${proxy.enabled ? '已启用' : '已停用'}\n${proxy.address}\n关联任务：${proxy.referenceCount}',
                    ),
                    onTap: blocked ? null : () => _open(proxy),
                    trailing: PopupMenuButton<String>(
                      tooltip: '${proxy.name} 操作',
                      enabled: !blocked,
                      onSelected: (action) => _action(proxy, action),
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'edit', child: Text('编辑代理')),
                        PopupMenuItem(
                          value: 'check',
                          enabled: proxy.enabled && _recovery.checkIds.isEmpty,
                          child: const Text('检测代理'),
                        ),
                        const PopupMenuItem(
                          value: 'history',
                          child: Text('检测历史'),
                        ),
                        PopupMenuItem(
                          value: 'toggle',
                          child: Text(proxy.enabled ? '停用代理' : '启用代理'),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('删除代理'),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                children: [
                  IconButton(
                    tooltip: '上一页',
                    onPressed: !blocked && (_page?.page ?? 1) > 1
                        ? () => _load(_page!.page - 1)
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('${_page?.page ?? 1} / ${_page?.pages ?? 1}'),
                  IconButton(
                    tooltip: '下一页',
                    onPressed:
                        !blocked && _page != null && _page!.page < _page!.pages
                        ? () => _load(_page!.page + 1)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                  IconButton(
                    tooltip: '新增代理',
                    onPressed: blocked || _page == null ? null : () => _open(),
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProxyEditView extends StatefulWidget {
  const _ProxyEditView({
    required this.manager,
    required this.recovery,
    required this.onUnauthorized,
    this.proxyId,
  });
  final PanelProxyManager manager;
  final PanelProxyRecovery recovery;
  final String? proxyId;
  final Future<void> Function(PanelApiException) onUnauthorized;

  @override
  State<_ProxyEditView> createState() => _ProxyEditViewState();
}

class _ProxyEditViewState extends State<_ProxyEditView>
    with WidgetsBindingObserver {
  final _fields = {
    for (final key in ['name', 'host', 'port', 'url', 'username', 'password'])
      key: TextEditingController(),
  };
  final _credentials = {'username': 'keep', 'password': 'keep'};
  String _type = 'socks5';
  bool _enabled = true,
      _ready = false,
      _busy = false,
      _dirty = false,
      _leaving = false,
      _foreground = true;
  bool _conflict = false, _retryAllowed = false, _confirmRetry = false;
  PanelProxy? _baseline;
  Map<String, Object?>? _pending;
  String? _error, _notice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.proxyId == null) {
      _ready = true;
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final field in _fields.values) {
      field.dispose();
    }
    _pending = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _foreground = state == AppLifecycleState.resumed);
  }

  void _setFields(PanelProxy proxy, {Map<String, Object?> changes = const {}}) {
    final values = {...proxy.settings, ...changes};
    for (final key in ['name', 'host', 'port', 'url']) {
      _fields[key]!.text = values[key] as String;
    }
    _type = values['type'] as String;
    _enabled = values['enabled'] as bool;
    _baseline = proxy;
  }

  Map<String, Object?> _changes() {
    final values = <String, Object?>{
      for (final key in ['name', 'host', 'port', 'url'])
        key: _fields[key]!.text,
      'type': _type,
      'enabled': _enabled,
    };
    if (_baseline == null) return values;
    values.removeWhere((key, value) => _baseline!.settings[key] == value);
    return values;
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.manager.fetch(widget.proxyId!);
      if (mounted) {
        setState(() {
          _setFields(result);
          _ready = true;
          _dirty = false;
        });
      }
    } on PanelApiException catch (error) {
      await _handleError(error);
    } catch (_) {
      if (mounted) setState(() => _error = '代理详情读取失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkDraft() async {
    if (!_ready ||
        _busy ||
        _conflict ||
        widget.recovery.requestId != null ||
        widget.recovery.checkIds.isNotEmpty) {
      return;
    }
    final options = await proxyCheckOptions(
      context,
      customTargets: _type != 'github',
    );
    if (options == null || !mounted) return;
    final id = PanelProxyManager.newRequestId();
    final body = <String, Object?>{
      'request_id': id,
      'kind': options.kind,
      if (widget.proxyId != null) 'proxy_id': widget.proxyId,
      if (_baseline != null) 'version': _baseline!.version,
      if (options.targets != null) 'targets': options.targets,
      'draft': {
        'settings': _changes(),
        'credentials': {
          for (final entry in _credentials.entries) ...{
            '${entry.key}_action': entry.value,
            if (entry.value == 'replace') entry.key: _fields[entry.key]!.text,
          },
        },
      },
    };
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PanelProxyCheckView(
          manager: widget.manager,
          recovery: widget.recovery,
          id: id,
          submission: body,
          onUnauthorized: _handleError,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _handleError(PanelApiException error) async {
    if (!mounted) return;
    if (error.statusCode == 401) {
      for (final field in _fields.values) {
        field.clear();
      }
      _pending = null;
      _dirty = false;
      setState(() => _leaving = true);
      await widget.onUnauthorized(error);
      return;
    }
    setState(() => _error = _operationError(error));
  }

  Future<void> _leave() async {
    if (_busy) return;
    if ((_dirty || _pending != null) &&
        !await _confirm(
          context,
          '离开代理编辑？',
          '离开会丢弃此页草稿。未确认提交仍可在代理列表查询。',
          '离开',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => _leaving = true);
    Navigator.of(context).pop();
  }

  Future<void> _save() async {
    if (_busy || !_ready || widget.recovery.requestId != null) return;
    final settings = _changes();
    final credentials = <String, Object?>{};
    for (final key in _credentials.keys) {
      final action = _credentials[key]!;
      if (action == 'keep') continue;
      credentials['${key}_action'] = action;
      if (action == 'replace') credentials[key] = _fields[key]!.text;
    }
    if (_baseline != null && settings.isEmpty && credentials.isEmpty) {
      setState(() => _notice = '没有需要保存的变更');
      return;
    }
    if (!await _confirm(
      context,
      '保存代理？',
      '${_fields['name']!.text}\n${_typeLabel(_type)}\n${_enabled ? '启用' : '停用'}',
      '确认保存',
    )) {
      return;
    }
    if (!mounted) return;
    final id = PanelProxyManager.newRequestId();
    _pending = {
      'action': _baseline == null ? 'new' : 'edit',
      'request_id': id,
      if (_baseline != null) 'proxy_id': _baseline!.id,
      if (_baseline != null) 'version': _baseline!.version,
      'settings': settings,
      'credentials': credentials,
    };
    widget.recovery.requestId = id;
    await _send();
  }

  void _completed(String message) {
    widget.recovery.requestId = null;
    _pending = null;
    _dirty = false;
    setState(() => _leaving = true);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
    Navigator.of(context).pop();
  }

  Future<void> _send() async {
    if (_pending == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
      _retryAllowed = false;
    });
    try {
      final result = await widget.manager.submit(_pending!);
      if (!mounted) return;
      if (result.saved == true) {
        _completed('代理已保存');
        return;
      }
      await _query();
    } on PanelApiException catch (error) {
      if (!mounted) return;
      if (error.statusCode == 401) {
        await _handleError(error);
        return;
      }
      if (error.data?['saved'] == true) {
        _completed('代理已保存，请刷新核对');
        return;
      }
      if (error.statusCode != null &&
          error.statusCode! < 500 &&
          error.data?['saved'] == false) {
        widget.recovery.requestId = null;
        _pending = null;
        _conflict = error.data?['conflict'] == true;
        await _handleError(error);
      } else {
        await _handleError(error);
        await _query();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = '保存结果未知');
        await _query();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _query() async {
    final id = widget.recovery.requestId;
    if (id == null) return;
    setState(() => _busy = true);
    try {
      final result = await widget.manager.status(id);
      if (!mounted) return;
      if (result.saved == true) {
        _completed(result.currentMatches ? '代理已保存' : '原提交已保存，此后配置有变化');
        return;
      }
      setState(() {
        _retryAllowed = result.retryAllowed && _pending != null;
        _confirmRetry = result.confirmRequired;
        _notice = result.saved == false ? '原提交未保存，可确认后重试' : '原提交结果仍未知，暂不能再次保存';
      });
    } on PanelApiException catch (error) {
      await _handleError(error);
    } catch (_) {
      if (mounted) setState(() => _error = '原提交查询失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retry() async {
    if (!await _confirm(context, '重试原提交？', '使用原提交标识和原草稿再次保存。', '确认重试')) return;
    if (!mounted || _pending == null) return;
    if (_confirmRetry) _pending!['confirm_retry'] = true;
    await _send();
  }

  Future<void> _resolveConflict() async {
    final local = _changes();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final current = await widget.manager.fetch(widget.proxyId!);
      if (!mounted) return;
      final merge = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('核对当前代理'),
          scrollable: true,
          content: Text(
            '${current.name}\n${_typeLabel(current.type)}\n${current.address}\n${current.enabled ? '已启用' : '已停用'}\n关联任务：${current.referenceCount}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('保留草稿'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('采用当前配置'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('合并本地改动'),
            ),
          ],
        ),
      );
      if (merge == null || !mounted) return;
      setState(() {
        _setFields(current, changes: merge ? local : const {});
        if (!merge) {
          for (final key in _credentials.keys) {
            _credentials[key] = 'keep';
            _fields[key]!.clear();
          }
        }
        _dirty = merge;
        _conflict = false;
        _notice = merge ? '已核对，确认草稿后可保存' : '已采用当前配置';
      });
    } on PanelApiException catch (error) {
      await _handleError(error);
    } catch (_) {
      if (mounted) setState(() => _error = '当前代理读取失败，草稿已保留');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(
    String key,
    String label, {
    int limit = 200,
    bool secret = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      controller: _fields[key],
      enabled: !_busy && widget.recovery.requestId == null && !_conflict,
      maxLength: limit,
      obscureText: secret,
      autocorrect: !secret,
      enableSuggestions: !secret,
      keyboardType: key == 'port' ? TextInputType.number : TextInputType.text,
      onChanged: (_) => setState(() => _dirty = true),
      decoration: InputDecoration(labelText: label, counterText: ''),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final blocked = _busy || widget.recovery.requestId != null || _conflict;
    return PopScope(
      canPop: _leaving || (!_busy && !_dirty && _pending == null),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.proxyId == null ? '新增代理' : '编辑代理'),
          actions: [
            IconButton(
              tooltip: '检测草稿',
              onPressed:
                  !_ready || blocked || widget.recovery.checkIds.isNotEmpty
                  ? null
                  : _checkDraft,
              icon: const Icon(Icons.network_check),
            ),
          ],
          leading: IconButton(
            tooltip: '返回代理列表',
            onPressed: _busy ? null : _leave,
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        body: Column(
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_error != null ||
                _notice != null ||
                _conflict ||
                widget.recovery.requestId != null)
              Flexible(
                flex: 0,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_error != null) SelectableText(_error!),
                        if (_notice != null) Text(_notice!),
                        if (_conflict)
                          TextButton(
                            onPressed: _busy ? null : _resolveConflict,
                            child: const Text('核对当前代理'),
                          ),
                        if (widget.recovery.requestId != null)
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton.icon(
                                onPressed: _busy ? null : _query,
                                icon: const Icon(Icons.restore),
                                label: const Text('查询原提交'),
                              ),
                              if (_retryAllowed)
                                TextButton(
                                  onPressed: _busy ? null : _retry,
                                  child: const Text('重试原提交'),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            Expanded(
              child: !_ready
                  ? Center(
                      child: TextButton(
                        onPressed: _busy ? null : _load,
                        child: const Text('重新读取代理'),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _field('name', '代理名称'),
                        DropdownButtonFormField<String>(
                          key: ValueKey('type-$_type'),
                          initialValue: _type,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: '代理类型'),
                          items: [
                            for (final type in panelProxyTypes)
                              DropdownMenuItem(
                                value: type,
                                child: Text(_typeLabel(type)),
                              ),
                          ],
                          onChanged: blocked
                              ? null
                              : (value) => setState(() {
                                  _type = value!;
                                  _dirty = true;
                                }),
                        ),
                        const SizedBox(height: 16),
                        if (_type == 'github')
                          _field('url', 'GitHub 代理地址', limit: 4096)
                        else ...[
                          _field('host', '代理 Host', limit: 255),
                          _field('port', '代理端口', limit: 5),
                        ],
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('启用代理'),
                          value: _enabled,
                          onChanged: blocked
                              ? null
                              : (value) => setState(() {
                                  _enabled = value;
                                  _dirty = true;
                                }),
                        ),
                        if (_baseline != null)
                          Text('关联任务：${_baseline!.referenceCount}'),
                        for (final key in _credentials.keys) ...[
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                            key: ValueKey('$key-${_credentials[key]}'),
                            initialValue: _credentials[key],
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: key == 'username' ? '用户名' : '密码',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'keep',
                                child: Text('保持不变'),
                              ),
                              DropdownMenuItem(
                                value: 'replace',
                                child: Text('替换'),
                              ),
                              DropdownMenuItem(
                                value: 'clear',
                                child: Text('清空'),
                              ),
                            ],
                            onChanged: blocked
                                ? null
                                : (value) => setState(() {
                                    _credentials[key] = value!;
                                    _fields[key]!.clear();
                                    _dirty = true;
                                  }),
                          ),
                          if (_baseline != null)
                            Text(
                              (key == 'username'
                                      ? _baseline!.usernameConfigured
                                      : _baseline!.passwordConfigured)
                                  ? '已配置'
                                  : '未配置',
                            ),
                          if (_credentials[key] == 'replace') ...[
                            const SizedBox(height: 12),
                            if (_foreground)
                              _field(
                                key,
                                key == 'username' ? '新用户名' : '新密码',
                                limit: 4096,
                                secret: true,
                              )
                            else
                              const Text('内容已隐藏'),
                          ],
                        ],
                      ],
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: !_ready || blocked ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存代理'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _typeLabel(String type) => switch (type) {
  'github' => 'GitHub',
  'socks5h' => 'SOCKS5（远程 DNS）',
  _ => type.toUpperCase(),
};

String _operationError(PanelApiException error) {
  final references = error.data?['references'];
  return '${error.message}${references is List && references.isNotEmpty ? '\n${references.whereType<Map>().map((item) => item['name']).join('、')}' : ''}';
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
        scrollable: true,
        content: Text(message),
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
