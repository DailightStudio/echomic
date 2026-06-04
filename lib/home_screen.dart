import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'audio_engine.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final AudioEngine _engine = AudioEngine.instance;

  bool _running = false;
  bool _busy = false;
  String _status = 'Idle';

  double _gain = 1.0;
  double _echoDelayMs = 150.0;
  double _echoFeedback = 0.3;

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_running) {
        await _engine.stop();
        setState(() {
          _running = false;
          _status = 'Stopped';
        });
      } else {
        final PermissionStatus mic = await Permission.microphone.request();
        if (!mic.isGranted) {
          setState(() => _status = 'Microphone permission denied');
          return;
        }
        // Push current parameter values before starting the stream.
        await _engine.setGain(_gain);
        await _engine.setEchoDelay(_echoDelayMs);
        await _engine.setEchoFeedback(_echoFeedback);

        final bool ok = await _engine.start();
        setState(() {
          _running = ok;
          _status = ok ? 'Running (low latency)' : 'Failed to start engine';
        });
      }
    } catch (e) {
      setState(() => _status = 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('echomic'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Icon(
                _running ? Icons.mic : Icons.mic_off,
                size: 96,
                color: _running ? cs.primary : cs.onSurfaceVariant,
              ),
              const SizedBox(height: 8),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 24),
              _SliderTile(
                label: 'Gain',
                value: _gain,
                min: 1.0,
                max: 4.0,
                valueLabel: '${_gain.toStringAsFixed(2)}x',
                onChanged: (v) {
                  setState(() => _gain = v);
                  _engine.setGain(v);
                },
              ),
              _SliderTile(
                label: 'Echo Delay',
                value: _echoDelayMs,
                min: 0.0,
                max: 500.0,
                valueLabel: '${_echoDelayMs.round()} ms',
                onChanged: (v) {
                  setState(() => _echoDelayMs = v);
                  _engine.setEchoDelay(v);
                },
              ),
              _SliderTile(
                label: 'Echo Feedback',
                value: _echoFeedback,
                min: 0.0,
                max: 0.8,
                valueLabel: _echoFeedback.toStringAsFixed(2),
                onChanged: (v) {
                  setState(() => _echoFeedback = v);
                  _engine.setEchoFeedback(v);
                },
              ),
              const Spacer(),
              SizedBox(
                height: 64,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _toggle,
                  icon: Icon(_running ? Icons.stop : Icons.play_arrow),
                  label: Text(
                    _running ? 'Stop' : 'Start',
                    style: const TextStyle(fontSize: 20),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: _running ? cs.error : cs.primary,
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.valueLabel,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String valueLabel;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: Theme.of(context).textTheme.titleSmall),
            Text(valueLabel, style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
