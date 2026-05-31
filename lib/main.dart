import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const LocalScreenShareApp());
}

class LocalScreenShareApp extends StatelessWidget {
  const LocalScreenShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Local Screen Share',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0E7C66),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const ShareHomePage(),
    );
  }
}

class ShareHomePage extends StatefulWidget {
  const ShareHomePage({super.key});

  @override
  State<ShareHomePage> createState() => _ShareHomePageState();
}

class _ShareHomePageState extends State<ShareHomePage> {
  static const MethodChannel _channel = MethodChannel(
    'local_screen_share/native',
  );

  final TextEditingController _passwordController = TextEditingController();
  Timer? _statusTimer;

  bool _isSharing = false;
  bool _isBusy = false;
  String _localIP = 'Checking...';
  String _message = 'Ready';

  String get _localUrl {
    if (_localIP.isEmpty || _localIP == 'Checking...') {
      return 'http://<mac-local-ip>:8080';
    }
    return 'http://$_localIP:8080';
  }

  @override
  void initState() {
    super.initState();
    _refreshStatus();
    _statusTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _refreshStatus(silent: true),
    );
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _refreshStatus({bool silent = false}) async {
    try {
      final results = await Future.wait<dynamic>([
        _channel.invokeMethod<String>('getLocalIP'),
        _channel.invokeMethod<Map<dynamic, dynamic>>('getStatus'),
      ]);

      final status = Map<dynamic, dynamic>.from(results[1] as Map);
      if (!mounted) return;
      setState(() {
        _localIP = (results[0] as String?) ?? '';
        _isSharing = status['isSharing'] == true;
        if (!silent) {
          _message = (status['message'] as String?) ?? 'Ready';
        } else if (_isSharing) {
          _message = (status['message'] as String?) ?? 'Sharing';
        }
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _message = error.message ?? error.code;
      });
    }
  }

  Future<void> _startSharing() async {
    setState(() {
      _isBusy = true;
      _message = 'Starting local server and capture...';
    });

    try {
      final status = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'startSharing',
        <String, dynamic>{
          'password': _passwordController.text.trim(),
        },
      );
      if (!mounted) return;
      setState(() {
        _isSharing = status?['isSharing'] == true;
        _message = (status?['message'] as String?) ?? 'Sharing started';
      });
      await _refreshStatus(silent: true);
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _message = error.message ?? error.code;
      });
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _stopSharing() async {
    setState(() {
      _isBusy = true;
      _message = 'Stopping...';
    });

    try {
      final status = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'stopSharing',
      );
      if (!mounted) return;
      setState(() {
        _isSharing = status?['isSharing'] == true;
        _message = (status?['message'] as String?) ?? 'Stopped';
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _message = error.message ?? error.code;
      });
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _copyUrl() async {
    await Clipboard.setData(ClipboardData(text: _localUrl));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Local URL copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F4),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Local Screen Share',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Share this Mac screen to a browser on the same Wi-Fi/LAN.',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: Colors.black.withOpacity(0.62),
                    ),
                  ),
                  const SizedBox(height: 28),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFD9DDD5)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(22),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                _isSharing
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_unchecked,
                                color: _isSharing
                                    ? const Color(0xFF0E7C66)
                                    : Colors.black45,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _isSharing ? 'Sharing' : 'Not sharing',
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _message,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.black.withOpacity(0.68),
                            ),
                          ),
                          const SizedBox(height: 24),
                          TextField(
                            controller: _passwordController,
                            enabled: !_isSharing && !_isBusy,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: 'Viewer password',
                              hintText:
                                  'Optional, but recommended on shared Wi-Fi',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.lock_outline),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: _isBusy || _isSharing
                                      ? null
                                      : _startSharing,
                                  icon: const Icon(Icons.play_arrow),
                                  label: const Text('Start Sharing'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _isBusy || !_isSharing
                                      ? null
                                      : _stopSharing,
                                  icon: const Icon(Icons.stop),
                                  label: const Text('Stop Sharing'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFFE9F3EF),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFC4DCD2)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Row(
                        children: [
                          const Icon(Icons.link),
                          const SizedBox(width: 12),
                          Expanded(
                            child: SelectableText(
                              _localUrl,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Copy URL',
                            onPressed: _copyUrl,
                            icon: const Icon(Icons.copy),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'The server listens on port 8080 and only accepts loopback or private LAN clients.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.black.withOpacity(0.52),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
