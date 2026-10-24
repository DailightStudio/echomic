import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'audio_engine.dart';

/// Lists saved recordings (Android .wav / iOS .m4a) with play, share, rename
/// and delete. Reachable only while the engine is stopped, so playback never
/// competes with the live mic session.
class RecordingsScreen extends StatefulWidget {
  const RecordingsScreen({super.key});

  @override
  State<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends State<RecordingsScreen> {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<void>? _completeSub;
  List<File> _files = const [];
  bool _loading = true;
  String? _playing;

  @override
  void initState() {
    super.initState();
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = null);
    });
    _load();
  }

  @override
  void dispose() {
    _completeSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    List<File> files = [];
    try {
      final dir = Directory(await AudioEngine.instance.recordingsDir());
      if (await dir.exists()) {
        files = await dir
            .list()
            .where((e) =>
                e is File && (e.path.endsWith('.wav') || e.path.endsWith('.m4a')))
            .cast<File>()
            .toList();
        files.sort((a, b) => _name(b).compareTo(_name(a)));
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _files = files;
      _loading = false;
    });
  }

  static String _name(File f) => f.uri.pathSegments.last;

  static String _ext(File f) {
    final n = _name(f);
    final i = n.lastIndexOf('.');
    return i < 0 ? '' : n.substring(i);
  }

  static String _base(File f) {
    final n = _name(f);
    final i = n.lastIndexOf('.');
    return i < 0 ? n : n.substring(0, i);
  }

  /// `yyyyMMdd_HHmmss` -> `yyyy.MM.dd HH:mm`; null for renamed files.
  static String? _dateFromName(String base) {
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})$').firstMatch(base);
    if (m == null) return null;
    return '${m[1]}.${m[2]}.${m[3]} ${m[4]}:${m[5]}';
  }

  String _subtitle(File f) {
    String size = '';
    String date = _dateFromName(_base(f)) ?? '';
    try {
      final st = f.statSync();
      size = '${(st.size / (1024 * 1024)).toStringAsFixed(1)} MB';
      if (date.isEmpty) {
        final d = st.modified;
        String two(int v) => v.toString().padLeft(2, '0');
        date = '${d.year}.${two(d.month)}.${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
      }
    } catch (_) {}
    return [date, size].where((s) => s.isNotEmpty).join(' · ');
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _togglePlay(File f) async {
    try {
      if (_playing == f.path) {
        await _player.stop();
        setState(() => _playing = null);
      } else {
        await _player.stop();
        await _player.play(DeviceFileSource(f.path));
        setState(() => _playing = f.path);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _playing = null);
      _snack('재생할 수 없습니다.');
    }
  }

  Future<void> _stopIfPlaying(File f) async {
    if (_playing == f.path) {
      await _player.stop();
      _playing = null;
    }
  }

  Future<void> _share(File f) async {
    try {
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
    } catch (_) {
      if (mounted) _snack('공유할 수 없습니다.');
    }
  }

  Future<void> _rename(File f) async {
    final ctrl = TextEditingController(text: _base(f));
    final newBase = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('이름 바꾸기'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(suffixText: _ext(f)),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('확인')),
        ],
      ),
    );
    ctrl.dispose();
    if (newBase == null || !mounted) return;
    final name = newBase.trim();
    // Path separators / reserved chars would escape the folder or fail on FAT.
    if (name.isEmpty || RegExp(r'[\\/:*?"<>|]').hasMatch(name) || name.startsWith('.')) {
      _snack('사용할 수 없는 이름입니다.');
      return;
    }
    if (name == _base(f)) return;
    final target = File('${f.parent.path}${Platform.pathSeparator}$name${_ext(f)}');
    if (await target.exists()) {
      if (mounted) _snack('같은 이름의 파일이 이미 있습니다.');
      return;
    }
    try {
      await _stopIfPlaying(f);
      await f.rename(target.path);
    } catch (_) {
      if (mounted) _snack('이름을 바꿀 수 없습니다.');
    }
    await _load();
  }

  Future<void> _delete(File f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('녹음 삭제'),
        content: Text('${_name(f)} 파일을 삭제하시겠습니까?\n삭제한 녹음은 복구할 수 없습니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('삭제')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _stopIfPlaying(f);
      await f.delete();
    } catch (_) {
      if (mounted) _snack('삭제할 수 없습니다.');
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('녹음 목록'), centerTitle: true),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
              ? const Center(child: Text('저장된 녹음이 없습니다.'))
              : ListView.separated(
                  itemCount: _files.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final f = _files[i];
                    final playing = _playing == f.path;
                    return ListTile(
                      leading: IconButton(
                        icon: Icon(playing ? Icons.stop : Icons.play_arrow),
                        tooltip: playing ? '정지' : '재생',
                        onPressed: () => _togglePlay(f),
                      ),
                      title: Text(_base(f)),
                      subtitle: Text(_subtitle(f)),
                      onTap: () => _togglePlay(f),
                      trailing: PopupMenuButton<String>(
                        tooltip: '더 보기',
                        onSelected: (v) {
                          switch (v) {
                            case 'share':
                              _share(f);
                            case 'rename':
                              _rename(f);
                            case 'delete':
                              _delete(f);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'share', child: Text('공유')),
                          PopupMenuItem(value: 'rename', child: Text('이름 바꾸기')),
                          PopupMenuItem(value: 'delete', child: Text('삭제')),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
