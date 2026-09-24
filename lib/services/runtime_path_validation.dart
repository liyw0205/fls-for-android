import 'dart:io';

import 'package:path/path.dart' as p;

// Absolute links must resolve from the container root, not Android's root.
Future<bool> runtimeFileExistsInRootfs(Directory rootfs, String path) async {
  if (p.isAbsolute(path)) return false;

  final pending = p.split(path);
  final resolved = <String>[];
  final followedLinks = <String>{};
  var linkCount = 0;

  while (pending.isNotEmpty) {
    final segment = pending.removeAt(0);
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (resolved.isEmpty) return false;
      resolved.removeLast();
      continue;
    }

    final candidate = p.joinAll([rootfs.path, ...resolved, segment]);
    final type = await FileSystemEntity.type(candidate, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type == FileSystemEntityType.link) {
      if (++linkCount > 40 || !followedLinks.add(candidate)) return false;
      final target = await Link(candidate).target();
      final remaining = List<String>.from(pending);
      pending.clear();
      if (p.isAbsolute(target)) resolved.clear();
      pending.addAll(
        p
            .split(target)
            .where((part) => part.isNotEmpty && part != p.rootPrefix(target)),
      );
      pending.addAll(remaining);
      continue;
    }
    if (pending.isNotEmpty && type != FileSystemEntityType.directory) {
      return false;
    }
    resolved.add(segment);
  }

  final resolvedPath = p.joinAll([rootfs.path, ...resolved]);
  return await FileSystemEntity.type(resolvedPath) == FileSystemEntityType.file;
}
