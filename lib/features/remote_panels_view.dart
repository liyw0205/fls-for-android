import 'package:flutter/material.dart';

import '../models/panel_server.dart';
import '../services/panel_store.dart';
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

  Future<void> _addServer() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final server = await showDialog<PanelServer>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('添加面板'),
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
                ),
              );
            },
            child: const Text('连接'),
          ),
        ],
      ),
    );
    nameController.dispose();
    urlController.dispose();
    if (server == null || !mounted) return;
    final next = [server, ..._servers.where((item) => item.url != server.url)];
    setState(() => _servers = next);
    await _store.save(next);
    _openPanel(server);
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

  void _syncPanel(PanelServer server) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RemoteWebView(server: server, showUpdatePage: true),
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
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            sliver: SliverList.separated(
              itemCount: _servers.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final server = _servers[index];
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
                    title: Text(
                      server.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      '${uri.host}${uri.hasPort ? ':${uri.port}' : ''}${uri.path}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: PopupMenuButton<String>(
                      tooltip: '面板操作',
                      onSelected: (value) {
                        if (value == 'sync') _syncPanel(server);
                        if (value == 'remove') _removeServer(server);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'sync', child: Text('同步')),
                        PopupMenuItem(value: 'remove', child: Text('移除')),
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
