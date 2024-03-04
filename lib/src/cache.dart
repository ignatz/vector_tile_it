import 'dart:io';
import 'dart:typed_data';

abstract class ByteStorage {
  Future<bool> exists(String path);
  Future<void> write(String path, Uint8List bytes);
  Future<Uint8List?> read(String path);
  Future<void> delete(String path);

  Future<void> enforceSize();
  Future<void> enforceTtl();
}

typedef PathFunction = Future<Directory> Function();

class FileSystemByteStorage implements ByteStorage {
  final Directory _path;
  final int _maxSizeInBytes;
  final Duration _ttl;

  DateTime? _oldestValid;

  FileSystemByteStorage({
    required Directory path,
    required int maxSizeInBytes,
    required Duration ttl,
  })  : _path = path,
        _maxSizeInBytes = maxSizeInBytes,
        _ttl = ttl;

  Future<String> get _storagePath async {
    final exists = await _path.exists();
    if (!exists) {
      await _path.create(recursive: true);
    }
    return _path.path;
  }

  @override
  Future<bool> exists(String path) async {
    final root = await _storagePath;
    return await File("$root/$path").exists();
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    final file = await _fileOf(path);
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    await file.writeAsBytes(bytes);
  }

  @override
  Future<Uint8List?> read(String path) async {
    final file = await _fileOf(path);
    if (await file.exists()) {
      return file.readAsBytes();
    }
    return null;
  }

  @override
  Future<void> delete(String path) async {
    final file = await _fileOf(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<void> enforceSize() async {
    final directory = Directory(await _storagePath);
    final entries = await directory
        .list()
        .asyncMap((f) async => MapEntry(f, await f.stat()))
        .where((e) => e.value.type == FileSystemEntityType.file)
        .toList();
    int size = entries.isEmpty
        ? 0
        : entries.map((e) => e.value.size).reduce((a, b) => a + b);
    if (size <= _maxSizeInBytes) {
      return;
    }

    entries.sort((a, b) => a.value.accessed.compareTo(b.value.accessed));
    for (final entry in entries) {
      try {
        await entry.key.delete();
        size -= entry.value.size;
        if (size <= _maxSizeInBytes) {
          return;
        }
      } catch (e) {
        // ignore, race condition file was deleted
      }
    }
  }

  @override
  Future<void> enforceTtl() async {
    final now = DateTime.now();
    if (_oldestValid != null && now.difference(_oldestValid!) <= _ttl) {
      return;
    }

    final root = Directory(await _storagePath);
    final deletions = <Future>[];
    await for (final f in root.list()) {
      deletions.add(_expireIfExceedsTtl(now, f));
    }
    await Future.wait(deletions);
  }

  Future<void> _expireIfExceedsTtl(
    DateTime now,
    FileSystemEntity entity,
  ) async {
    final stat = await entity.stat();
    if (stat.type != FileSystemEntityType.file) {
      return;
    }

    final expired = now.difference(stat.modified) > _ttl;
    if (expired) {
      await entity.delete();
    } else if (_oldestValid == null || stat.modified.isBefore(_oldestValid!)) {
      _oldestValid = stat.modified;
    }
  }

  Future<File> _fileOf(String path) async {
    final root = await _storagePath;
    return File("$root/$path");
  }
}
