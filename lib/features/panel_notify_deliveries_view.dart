import 'dart:async';

import 'package:flutter/material.dart';

import '../models/panel_notify.dart';
import '../models/panel_notify_delivery.dart';
import '../services/panel_api_client.dart';
import '../services/panel_notify_manager.dart';

class PanelNotifyDeliveriesView extends StatefulWidget {
  const PanelNotifyDeliveriesView({
    super.key,
    required this.manager,
    required this.recovery,
    required this.onUnauthorized,
  });
  final PanelNotifyManager manager;
  final PanelNotifyRecovery recovery;
  final Future<void> Function(PanelApiException) onUnauthorized;
  @override
  State<PanelNotifyDeliveriesView> createState() =>
      _PanelNotifyDeliveriesViewState();
}

class _PanelNotifyDeliveriesViewState extends State<PanelNotifyDeliveriesView> {
  NotifyDeliveryPage? _page;
  List<NotifyChannel> _channels = const [];
  String _status = '', _channel = '';
  String? _error;
  bool _loading = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _failure(Object error) async {
    if (!mounted) return;
    if (error is PanelApiException && error.statusCode == 401) {
      await widget.onUnauthorized(error);
      return;
    }
    setState(
      () => _error = error is PanelApiException ? error.message : '通知历史读取失败',
    );
  }

  Future<void> _load([int page = 1]) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final channels = _channels.isEmpty
          ? await widget.manager.schema()
          : _channels;
      final result = await widget.manager.deliveryHistory(
        page: page,
        status: _status,
        channel: _channel,
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

  Future<void> _open({String? deliveryId, String? requestId}) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PanelNotifyDeliveryView(
          manager: widget.manager,
          recovery: widget.recovery,
          onUnauthorized: widget.onUnauthorized,
          deliveryId: deliveryId,
          requestId: requestId,
        ),
      ),
    );
    if (mounted) await _load(_page?.page ?? 1);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('通知投递'),
      actions: [
        IconButton(
          tooltip: '刷新投递历史',
          onPressed: _loading ? null : () => _load(_page?.page ?? 1),
          icon: const Icon(Icons.refresh),
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
                DropdownButtonFormField<String>(
                  initialValue: _status,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '投递状态'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('全部状态')),
                    for (final status in notifyDeliveryStates)
                      DropdownMenuItem(
                        value: status,
                        child: Text(notifyDeliveryLabel(status)),
                      ),
                  ],
                  onChanged: _loading
                      ? null
                      : (value) {
                          setState(() => _status = value!);
                          _load();
                        },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _channel,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '渠道类型'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('全部渠道')),
                    for (final channel in _channels)
                      DropdownMenuItem(
                        value: channel.id,
                        child: Text(
                          channel.name,
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
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(_error!),
            ),
          Expanded(
            child: ListView(
              children: [
                if (widget.recovery.deliveryRequests.isNotEmpty)
                  ExpansionTile(
                    title: Text(
                      '原投递请求 (${widget.recovery.deliveryRequests.length})',
                    ),
                    initiallyExpanded: true,
                    children: [
                      for (final id in widget.recovery.deliveryRequests)
                        ListTile(
                          title: const Text('查询原投递'),
                          subtitle: Text(id, overflow: TextOverflow.ellipsis),
                          trailing: const Icon(Icons.sync),
                          onTap: () => _open(requestId: id),
                        ),
                    ],
                  ),
                if (_page?.items.isEmpty == true)
                  const ListTile(title: Text('暂无投递记录')),
                for (final item in _page?.items ?? <NotifyDelivery>[]) ...[
                  ListTile(
                    title: Text(item.name.isEmpty ? item.channel : item.name),
                    subtitle: Text(
                      '${notifyDeliveryLabel(item.status)} · 第 ${item.attempt} 次\n${item.updatedAt}${item.truncated ? '\n正文已截断' : ''}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(deliveryId: item.id),
                  ),
                  const Divider(height: 1),
                ],
              ],
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
                Expanded(
                  child: Text(
                    '${_page!.page} / ${_page!.pages} · ${_page!.total} 条',
                    textAlign: TextAlign.center,
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
        ],
      ),
    ),
  );
}

class PanelNotifyDeliveryView extends StatefulWidget {
  const PanelNotifyDeliveryView({
    super.key,
    required this.manager,
    required this.recovery,
    required this.onUnauthorized,
    this.deliveryId,
    this.requestId,
  });
  final PanelNotifyManager manager;
  final PanelNotifyRecovery recovery;
  final Future<void> Function(PanelApiException) onUnauthorized;
  final String? deliveryId, requestId;
  @override
  State<PanelNotifyDeliveryView> createState() =>
      _PanelNotifyDeliveryViewState();
}

class _PanelNotifyDeliveryViewState extends State<PanelNotifyDeliveryView>
    with WidgetsBindingObserver {
  late String? _requestId = widget.requestId;
  late String? _deliveryId = widget.deliveryId;
  NotifyDeliveryRequest? _request;
  NotifyDelivery? _item;
  Timer? _timer;
  bool _busy = false, _foreground = true, _expired = false;
  int _generation = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _item = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _timer?.cancel();
    _generation++;
    if (!mounted) return;
    setState(() {
      _foreground = state == AppLifecycleState.resumed;
      _item = null;
    });
    if (_foreground && !_busy && !_expired) _load();
  }

  Future<void> _failure(Object error) async {
    if (!mounted) return;
    if (error is PanelApiException && error.statusCode == 401) {
      _expired = true;
      _timer?.cancel();
      setState(() => _item = null);
      await widget.onUnauthorized(error);
      return;
    }
    setState(
      () => _error = error is PanelApiException
          ? error.message
          : '投递结果无法读取，请查询原请求',
    );
  }

  Future<void> _load({bool reveal = false}) async {
    if (_busy || _expired || !_foreground) return;
    final generation = ++_generation;
    _timer?.cancel();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      NotifyDeliveryRequest? receipt;
      if (_requestId != null) {
        receipt = await widget.manager.deliveryStatus(_requestId!);
      }
      if (!mounted || !_foreground || _expired || generation != _generation) {
        return;
      }
      if (receipt != null) {
        _request = receipt;
        if (receipt.deliveryId.isNotEmpty) _deliveryId = receipt.deliveryId;
        if (receipt.status == 'succeeded' || receipt.status == 'failed') {
          widget.recovery.deliveryRequests.remove(receipt.id);
        }
      }
      final item = _deliveryId == null || receipt?.historyAvailable == false
          ? null
          : await widget.manager.delivery(_deliveryId!, reveal: reveal);
      if (!mounted || !_foreground || _expired || generation != _generation) {
        return;
      }
      setState(() => _item = item);
    } catch (error) {
      await _failure(error);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (generation != _generation && _foreground && !_expired) {
          unawaited(_load());
        } else if (_foreground &&
            !_expired &&
            _error == null &&
            (_request?.active == true || _item?.status == 'running')) {
          _timer = Timer(const Duration(seconds: 2), _load);
        }
      }
    }
  }

  Future<void> _retry() async {
    final original = _item;
    String? submittedId;
    if (_busy || original == null || !original.retryAllowed) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final current = await widget.manager.delivery(original.id);
      if (!mounted || !_foreground) return;
      if (!current.retryAllowed) {
        setState(() {
          _item = current;
          _error = '当前投递已成功或正在发送，请核对状态';
        });
        return;
      }
      final channel = await showDialog<PanelNotifyItem>(
        context: context,
        builder: (_) => _ChannelPicker(
          manager: widget.manager,
          onUnauthorized: widget.onUnauthorized,
        ),
      );
      if (!mounted || !_foreground || channel == null) return;
      final confirmed = await _confirm(
        context,
        '重新投递？',
        '原记录第 ${current.attempt} 次：${notifyDeliveryLabel(current.status)}\n本次渠道：${channel.name}\n${current.truncated ? '保存的正文已截断，将只发送截断后的内容。\n' : ''}原通知可能已经送达。请先核对接收端，本次会增加一次投递尝试。',
        '确认重新投递',
      );
      if (!confirmed || !mounted || !_foreground) return;
      final id = PanelNotifyManager.newRequestId();
      submittedId = id;
      widget.recovery.deliveryRequests.add(id);
      _requestId = id;
      _request = null;
      _item = null;
      final receipt = await widget.manager.retryDelivery(
        current,
        channel,
        id,
        confirmTruncated: current.truncated,
      );
      if (!mounted) return;
      setState(() => _request = receipt);
    } catch (error) {
      if (error is PanelApiException &&
          error.statusCode != 401 &&
          error.data?['accepted'] == false &&
          submittedId != null) {
        widget.recovery.deliveryRequests.remove(submittedId);
        _requestId = null;
        _request = null;
        _item = original;
      }
      await _failure(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && !_expired && _error == null) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    return Scaffold(
      appBar: AppBar(
        title: const Text('投递详情'),
        actions: [
          IconButton(
            tooltip: '查询投递结果',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: !_foreground
            ? const SizedBox()
            : Column(
                children: [
                  if (_busy) const LinearProgressIndicator(),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (_error != null) SelectableText(_error!),
                        if (_requestId != null) ...[
                          SelectableText('请求：$_requestId'),
                          Text(
                            '原请求：${notifyDeliveryLabel(_request?.status ?? 'unknown')}',
                          ),
                          if (_request != null)
                            Text(notifyDeliveryMessage(_request!.code)),
                          if (_request?.historyAvailable == false &&
                              _request?.historical == true)
                            const Text('原请求已结束，投递明细已清理。'),
                          if (_request != null &&
                              _request!.currentAttempt != null &&
                              !_request!.currentMatches)
                            Text(
                              '记录现为第 ${_request!.currentAttempt} 次，原请求为第 ${_request!.attempt} 次。',
                            ),
                          const SizedBox(height: 16),
                        ],
                        if (item != null) ...[
                          Text(
                            item.name,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            '${notifyDeliveryLabel(item.status)} · 第 ${item.attempt} 次',
                          ),
                          Text(item.updatedAt),
                          if (item.status == 'unknown' ||
                              item.status == 'failed')
                            const Text('投递可能已经送达，请先核对接收端再决定是否重试。'),
                          if (item.truncated) const Text('保存的正文已截断。'),
                          const SizedBox(height: 16),
                          if (item.content == null)
                            OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _load(reveal: true),
                              icon: const Icon(Icons.visibility_outlined),
                              label: const Text('查看投递正文'),
                            ),
                          if (item.content != null) ...[
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '投递正文',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                  ),
                                ),
                                IconButton(
                                  tooltip: '隐藏正文',
                                  onPressed: _busy ? null : _load,
                                  icon: const Icon(
                                    Icons.visibility_off_outlined,
                                  ),
                                ),
                              ],
                            ),
                            SelectableText(item.title ?? ''),
                            SelectableText(item.content!),
                          ],
                          if (item.retryAllowed)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: FilledButton.icon(
                                onPressed: _busy ? null : _retry,
                                icon: const Icon(Icons.send_outlined),
                                label: const Text('重新选择渠道并投递'),
                              ),
                            ),
                        ],
                        if (_requestId != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: OutlinedButton.icon(
                              onPressed: _busy ? null : _load,
                              icon: const Icon(Icons.sync),
                              label: const Text('查询原投递'),
                            ),
                          ),
                        if (_request?.unresolved == true &&
                            widget.recovery.deliveryRequests.contains(
                              _requestId,
                            ))
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () async {
                                    if (await _confirm(
                                      context,
                                      '结束此请求的恢复？',
                                      '投递结果仍未知。结束恢复不会取消发送，也不会重新发送，请先核对接收端。',
                                      '已核对，结束恢复',
                                    )) {
                                      widget.recovery.deliveryRequests.remove(
                                        _requestId,
                                      );
                                      if (mounted) setState(() {});
                                    }
                                  },
                            child: const Text('核对接收端后结束恢复'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _ChannelPicker extends StatefulWidget {
  const _ChannelPicker({required this.manager, required this.onUnauthorized});
  final PanelNotifyManager manager;
  final Future<void> Function(PanelApiException) onUnauthorized;
  @override
  State<_ChannelPicker> createState() => _ChannelPickerState();
}

class _ChannelPickerState extends State<_ChannelPicker> {
  final _search = TextEditingController();
  PanelNotifyPage? _page;
  bool _loading = false;
  String? _error;
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

  Future<void> _load([int page = 1]) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.manager.fetchPage(
        query: _search.text,
        enabled: '1',
        page: page,
      );
      if (mounted) setState(() => _page = result);
    } on PanelApiException catch (error) {
      if (mounted && error.statusCode == 401) {
        Navigator.pop(context);
        await widget.onUnauthorized(error);
      } else if (mounted) {
        setState(() => _error = error.message);
      }
    } catch (_) {
      if (mounted) setState(() => _error = '通知渠道读取失败');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('选择本次渠道'),
    content: SizedBox(
      width: 360,
      height: 360,
      child: Column(
        children: [
          TextField(
            controller: _search,
            decoration: const InputDecoration(labelText: '搜索已启用渠道'),
            onSubmitted: (_) => _load(),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) Text(_error!),
          Expanded(
            child: ListView(
              children: [
                for (final item in _page?.items ?? <PanelNotifyItem>[])
                  ListTile(
                    title: Text(item.name),
                    subtitle: Text(item.channel),
                    enabled: !_loading,
                    onTap: () => Navigator.pop(context, item),
                  ),
              ],
            ),
          ),
          if (_page != null)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: '上一页渠道',
                  onPressed: _loading || _page!.page <= 1
                      ? null
                      : () => _load(_page!.page - 1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Text(
                    '${_page!.page} / ${_page!.pages}',
                    textAlign: TextAlign.center,
                  ),
                ),
                IconButton(
                  tooltip: '下一页渠道',
                  onPressed: _loading || _page!.page >= _page!.pages
                      ? null
                      : () => _load(_page!.page + 1),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  );
}

Future<bool> _confirm(
  BuildContext context,
  String title,
  String content,
  String action,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(content)),
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
