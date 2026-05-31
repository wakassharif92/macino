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
      title: 'Macino',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF167A68),
          brightness: Brightness.light,
        ),
        fontFamily: 'Segoe UI',
        scaffoldBackgroundColor: const Color(0xFFF3F5F1),
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
      return 'http://<local-ip>:41873';
    }
    return 'http://$_localIP:41873';
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

  Future<void> _minimizeWindow() async {
    try {
      await _channel.invokeMethod<void>('minimizeWindow');
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _message = error.message ?? error.code;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor =
        _isSharing ? const Color(0xFF14886E) : const Color(0xFF6B7280);

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFF6F7F3),
              Color(0xFFEAF0EE),
              Color(0xFFF2F0EA),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: const Color(0xFF111827),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.cast_connected,
                            color: Color(0xFF74E0C4),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Macino',
                                style:
                                    theme.textTheme.headlineSmall?.copyWith(
                                  color: const Color(0xFF111827),
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Local screen sharing for trusted networks',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: const Color(0xFF647069),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor.withOpacity(0.10),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: statusColor.withOpacity(0.24),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _isSharing
                                    ? Icons.sensors
                                    : Icons.sensors_off,
                                size: 18,
                                color: statusColor,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _isSharing ? 'Live' : 'Idle',
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: statusColor,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Tooltip(
                          message: 'Hide to background',
                          child: IconButton(
                            onPressed: _minimizeWindow,
                            icon: const Icon(Icons.minimize),
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: const Color(0xFF374151),
                              side: const BorderSide(
                                color: Color(0xFFD9E0DA),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            flex: 6,
                            child: Container(
                              padding: const EdgeInsets.all(24),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFFD9E0DA),
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x14000000),
                                    blurRadius: 24,
                                    offset: Offset(0, 14),
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                          color: statusColor.withOpacity(0.12),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Icon(
                                          _isSharing
                                              ? Icons.desktop_windows
                                              : Icons.desktop_access_disabled,
                                          color: statusColor,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              _isSharing
                                                  ? 'Screen is sharing'
                                                  : 'Ready to share',
                                              style: theme
                                                  .textTheme.titleLarge
                                                  ?.copyWith(
                                                color:
                                                    const Color(0xFF111827),
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              _message,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme
                                                  .textTheme.bodyMedium
                                                  ?.copyWith(
                                                color:
                                                    const Color(0xFF65716B),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 28),
                                  TextField(
                                    controller: _passwordController,
                                    enabled: !_isSharing && !_isBusy,
                                    obscureText: true,
                                    decoration: InputDecoration(
                                      filled: true,
                                      fillColor: const Color(0xFFF7F9F6),
                                      labelText: 'Viewer password',
                                      hintText: 'Optional access code',
                                      prefixIcon:
                                          const Icon(Icons.lock_outline),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: const BorderSide(
                                          color: Color(0xFFD7DED8),
                                        ),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: const BorderSide(
                                          color: Color(0xFFD7DED8),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 22),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: FilledButton.icon(
                                          onPressed: _isBusy || _isSharing
                                              ? null
                                              : _startSharing,
                                          icon: _isBusy && !_isSharing
                                              ? const SizedBox(
                                                  width: 18,
                                                  height: 18,
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                  ),
                                                )
                                              : const Icon(Icons.play_arrow),
                                          label:
                                              const Text('Start Sharing'),
                                          style: FilledButton.styleFrom(
                                            backgroundColor:
                                                const Color(0xFF167A68),
                                            foregroundColor: Colors.white,
                                            disabledBackgroundColor:
                                                const Color(0xFFE1E6E2),
                                            minimumSize:
                                                const Size.fromHeight(48),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                          ),
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
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor:
                                                const Color(0xFF9F2D35),
                                            side: const BorderSide(
                                              color: Color(0xFFD8B7B9),
                                            ),
                                            minimumSize:
                                                const Size.fromHeight(48),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const Spacer(),
                                  Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF4F7F5),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: const Color(0xFFDDE5DF),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.shield_outlined,
                                          color: Color(0xFF5D6B64),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            'Port 41873 accepts loopback and private LAN clients only.',
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                              color: const Color(0xFF5D6B64),
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 18),
                          Expanded(
                            flex: 4,
                            child: Container(
                              padding: const EdgeInsets.all(24),
                              decoration: BoxDecoration(
                                color: const Color(0xFF111827),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFF263241),
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x18000000),
                                    blurRadius: 22,
                                    offset: Offset(0, 12),
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        width: 40,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF253344),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: const Icon(
                                          Icons.link,
                                          color: Color(0xFF9CE8D4),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        'Viewer Link',
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 22),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF182231),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: const Color(0xFF2D3A4A),
                                      ),
                                    ),
                                    child: SelectableText(
                                      _localUrl,
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                        color: const Color(0xFFEFFCF8),
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  SizedBox(
                                    width: double.infinity,
                                    child: FilledButton.icon(
                                      onPressed: _copyUrl,
                                      icon: const Icon(Icons.copy),
                                      label: const Text('Copy Link'),
                                      style: FilledButton.styleFrom(
                                        backgroundColor:
                                            const Color(0xFF9CE8D4),
                                        foregroundColor:
                                            const Color(0xFF0D1B22),
                                        minimumSize:
                                            const Size.fromHeight(46),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const Spacer(),
                                  Divider(
                                    color: Colors.white.withOpacity(0.12),
                                  ),
                                  const SizedBox(height: 12),
                                  _InfoRow(
                                    icon: Icons.router_outlined,
                                    label: 'Local IP',
                                    value: _localIP,
                                  ),
                                  const SizedBox(height: 12),
                                  const _InfoRow(
                                    icon: Icons.lan_outlined,
                                    label: 'Network',
                                    value: 'Private LAN',
                                  ),
                                  const SizedBox(height: 12),
                                  const _InfoRow(
                                    icon: Icons.http,
                                    label: 'Port',
                                    value: '41873',
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(icon, size: 18, color: const Color(0xFF9CA9B7)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: const Color(0xFF9CA9B7),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}
