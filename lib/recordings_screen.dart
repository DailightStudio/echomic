import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'audio_engine.dart';
import 'ui_colors.dart';

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
                e is File &&
                (e.path.endsWith('.wav') || e.path.endsWith('.m4a')))
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

  static final RegExp _stamp =
      RegExp(r'^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})(?:_\d+)?$');

  /// Display title: native names (`yyyyMMdd_HHmmss[_N]`) read as
  /// `M월 d일 HH:mm 녹음`; renamed files show their own name.
  static String _title(File f) {
    final base = _base(f);
    final m = _stamp.firstMatch(base);
    if (m == null) return base;
    return '${int.parse(m[2]!)}월 ${int.parse(m[3]!)}일 ${m[4]}:${m[5]} 녹음';
  }

  String _subtitle(File f) {
    String size = '';
    String date = '';
    try {
      final st = f.statSync();
      size = '${(st.size / (1024 * 1024)).toStringAsFixed(1)} MB';
      // The title already carries the date unless the file was renamed.
      if (!_stamp.hasMatch(_base(f))) {
        final d = st.modified;
        String two(int v) => v.toString().padLeft(2, '0');
        date =
            '${d.year}.${two(d.month)}.${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
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
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('확인')),
        ],
      ),
    );
    ctrl.dispose();
    if (newBase == null || !mounted) return;
    final name = newBase.trim();
    // Path separators / reserved chars would escape the folder or fail on FAT.
    if (name.isEmpty ||
        RegExp(r'[\\/:*?"<>|]').hasMatch(name) ||
        name.startsWith('.')) {
      _snack('사용할 수 없는 이름입니다.');
      return;
    }
    if (name == _base(f)) return;
    final target =
        File('${f.parent.path}${Platform.pathSeparator}$name${_ext(f)}');
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
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('삭제')),
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
              ? const _EmptyRecordings()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: _files.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final f = _files[i];
                    final playing = _playing == f.path;
                    return Card(
                      margin: EdgeInsets.zero,
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        contentPadding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                        leading: IconButton.filled(
                          style: IconButton.styleFrom(
                            backgroundColor: playing
                                ? kNeonA
                                : kNeonA.withValues(alpha: 0.18),
                            foregroundColor: Colors.white,
                          ),
                          icon: Icon(playing
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded),
                          tooltip: playing ? '정지' : '재생',
                          onPressed: () => _togglePlay(f),
                        ),
                        title: Text(_title(f),
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
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
                            PopupMenuItem(
                                value: 'rename', child: Text('이름 바꾸기')),
                            PopupMenuItem(value: 'delete', child: Text('삭제')),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

class _EmptyRecordings extends StatelessWidget {
  const _EmptyRecordings();

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mic_none_rounded,
                size: 56, color: kNeonA.withValues(alpha: 0.6)),
            const SizedBox(height: 16),
            Text('저장된 녹음이 없습니다.', style: tt.titleMedium),
            const SizedBox(height: 6),
            Text('노래를 시작한 뒤 녹음 버튼을 눌러 보세요.',
                textAlign: TextAlign.center,
                style: tt.bodyMedium?.copyWith(color: muted)),
          ],
        ),
      ),
    );
  }
}
