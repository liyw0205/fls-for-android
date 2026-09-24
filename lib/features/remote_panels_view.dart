import 'dart:async';

import 'package:flutter/material.dart';

import '../models/panel_server.dart';
import '../services/panel_store.dart';
import 'remote_data_sync_view.dart';
import 'remote_web_view.dart';

class RemotePanelsView extends StatefulWidget {
  const RemotePanelsView({super.key});

  @override
  State<RemotePanelsView> createState() => _RemotePanelsViewState();
}

class _RemotePanelsViewState extends State<RemotePanelsView> {
  final _store = PanelStore();
  List<PanelServer> _servers = const [];
  bool _loading = true;
  String _query = '';
  bool _favoritesOnly = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final servers = await _store.load();
    if (!mounted) return;
    setState(() {
      _servers = servers;
      _loading = false;
    });
  }

  Future<void> _editServer([PanelServer? existing]) async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    nameController.text = existing?.name ?? '';
    urlController.text = existing?.url ?? '';
    final formKey = GlobalKey<FormState>();
    final server = await showDialog<PanelServer>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(existing == null ? '添加面板' : '编辑面板'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '家用服务器',
                ),
                validator: (value) =>
                    value == null || value.trim().isEmpty ? '请输入名称' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: urlController,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: '面板地址',
                  hintText: 'https://fls.example.com 或 192.168.1.2:5700',
                ),
                validator: (value) => normalizePanelUrl(value ?? '') == null
                    ? '请输入有效的 HTTP 或 HTTPS 地址'
                    : null,
                onFieldSubmitted: (_) {
                  if (formKey.currentState?.validate() == true) {
                    Navigator.pop(
                      dialogContext,
                      PanelServer(
                        name: nameController.text.trim(),
                        url: normalizePanelUrl(urlController.text)!,
                        isFavorite: existing?.isFavorite ?? false,
                      ),
                    );
                  }
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              Navigator.pop(
                dialogContext,
                PanelServer(
                  name: nameController.text.trim(),
                  url: normalizePanelUrl(urlController.text)!,
                  isFavorite: existing?.isFavorite ?? false,
                ),
              );
            },
            child: Text(existing == null ? '连接' : '保存'),
          ),
        ],
      ),
    );
    nameController.dispose();
    urlController.dispose();
    if (server == null || !mounted) return;
    final next = existing == null
        ? [server, ..._servers.where((item) => item.url != server.url)]
        : [
            ..._servers.where(
              (item) => item.url != existing.url && item.url != server.url,
            ),
          ];
    if (existing != null) {
      final oldIndex = _servers.indexWhere((item) => item.url == existing.url);
      next.insert(oldIndex.clamp(0, next.length), server);
    }
    setState(() => _servers = next);
    await _store.save(next);
    if (existing == null) _openPanel(server);
  }

  Future<void> _addServer() => _editServer();

  Future<void> _toggleFavorite(PanelServer server) async {
    final next = _servers
        .map(
          (item) => item.url == server.url
              ? PanelServer(
                  name: item.name,
                  url: item.url,
                  isFavorite: !item.isFavorite,
                )
              : item,
        )
        .toList();
    setState(() => _servers = next);
    await _store.save(next);
  }

  Future<void> _removeServer(PanelServer server) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移除面板'),
        content: Text('从此设备移除“${server.name}”？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (remove != true) return;
    final next = _servers.where((item) => item.url != server.url).toList();
    setState(() => _servers = next);
    await _store.save(next);
  }

  void _openPanel(PanelServer server) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => RemoteWebView(server: server)),
    );
  }

  Future<void> _syncPanel(PanelServer server) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('同步服务器数据到本机？'),
        content: Text(
          '将下载“${server.name}”的 data 并完整替换本机 data。任务、账号、配置和变量等本机数据会被覆盖；服务器数据不变。本机 scripts、日志和 data/backups 会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('同步并覆盖本机 data'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RemoteDataSyncView(server: server),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          title: const Text('FLS 面板'),
          actions: [
            IconButton(
              tooltip: '添加面板',
              onPressed: _addServer,
              icon: const Icon(Icons.add),
            ),
            const SizedBox(width: 4),
          ],
        ),
        if (_loading)
          const SliverFillRemaining(
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_servers.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyPanels(onAdd: _addServer),
          )
        else ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: '搜索名称或地址',
                        isDense: true,
                      ),
                      onChanged: (value) =>
                          setState(() => _query = value.trim().toLowerCase()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('收藏'),
                    selected: _favoritesOnly,
                    onSelected: (selected) =>
                        setState(() => _favoritesOnly = selected),
                    avatar: const Icon(Icons.star_outline, size: 18),
                  ),
                ],
              ),
            ),
          ),
          if (_filteredServers.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text('没有匹配的面板'),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              sliver: SliverList.separated(
                itemCount: _filteredServers.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final server = _filteredServers[index];
                  final uri = Uri.parse(server.url);
                  return Card(
                    child: ListTile(
                      minVerticalPadding: 12,
                      leading: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE4F2EE),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.dns_outlined,
                          color: Color(0xFF147D72),
                        ),
                      ),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              server.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (server.isFavorite)
                            const Icon(
                              Icons.star,
                              size: 16,
                              color: Color(0xFFB7791F),
                            ),
                        ],
                      ),
                      subtitle: Text(
                        '${uri.host}${uri.hasPort ? ':${uri.port}' : ''}${uri.path}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: PopupMenuButton<String>(
                        tooltip: '面板操作',
                        onSelected: (value) {
                          if (value == 'favorite') _toggleFavorite(server);
                          if (value == 'edit') _editServer(server);
                          if (value == 'sync') unawaited(_syncPanel(server));
                          if (value == 'remove') _removeServer(server);
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'favorite',
                            child: Text(server.isFavorite ? '取消收藏' : '收藏'),
                          ),
                          const PopupMenuItem(value: 'edit', child: Text('编辑')),
                          const PopupMenuItem(
                            value: 'sync',
                            child: Text('同步服务器数据到本机'),
                          ),
                          const PopupMenuItem(
                            value: 'remove',
                            child: Text('移除'),
                          ),
                        ],
                      ),
                      onTap: () => _openPanel(server),
                    ),
                  );
                },
              ),
            ),
        ],
      ],
    );
  }

  List<PanelServer> get _filteredServers {
    final query = _query;
    return _servers.where((server) {
      if (_favoritesOnly && !server.isFavorite) return false;
      if (query.isEmpty) return true;
      return server.name.toLowerCase().contains(query) ||
          server.url.toLowerCase().contains(query);
    }).toList();
  }
}

class _EmptyPanels extends StatelessWidget {
  const _EmptyPanels({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: const Color(0xFFE4F2EE),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              Icons.dns_outlined,
              size: 34,
              color: Color(0xFF147D72),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            '没有已保存的面板',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('添加面板'),
          ),
        ],
      ),
    );
  }
}
