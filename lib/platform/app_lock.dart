// Biometric app lock: the workspace is covered when the app starts, goes to
// the background, or has been left alone for [AppLockController.inactivityLimit],
// and is shown again only after Face ID / Touch ID succeeds.
//
// There is deliberately no app password, PIN, recovery code or typed
// fallback. Where biometrics-only verification is not available the lock is
// off ([AppLockState.disabled]) and the app says so honestly; it never
// substitutes a weaker check.
//
// STATUS: the Dart side is tested with a simulated authenticator. Face ID /
// Touch ID itself (ios/Runner/AppDelegate.swift) has NOT been run on a
// device. Windows has no lock: see [UnsupportedBiometricAuthenticator].
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/storage/app_log.dart';
import 'ios_bridge.dart';

enum BiometricResult { success, failed, cancelled, unavailable }

/// A source of biometrics-only verification.
abstract class BiometricAuthenticator {
  /// Whether biometrics alone can verify the user on this device right now.
  Future<bool> isAvailable();

  /// Asks the user to verify; never accepts a passcode or PIN.
  Future<BiometricResult> authenticate(String reason);
}

/// Face ID / Touch ID through the native "theapp/ios" channel.
class IosBiometricAuthenticator implements BiometricAuthenticator {
  IosBiometricAuthenticator([IosBridge? bridge])
    : _bridge = bridge ?? IosBridge.instance;

  final IosBridge _bridge;

  @override
  Future<bool> isAvailable() async {
    try {
      return await _bridge.biometricsAvailable();
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<BiometricResult> authenticate(String reason) async {
    try {
      return switch (await _bridge.authenticateBiometric(reason)) {
        'success' => BiometricResult.success,
        'cancelled' => BiometricResult.cancelled,
        'failed' => BiometricResult.failed,
        _ => BiometricResult.unavailable,
      };
    } on PlatformException {
      return BiometricResult.unavailable;
    }
  }
}

/// Windows and other platforms. Windows Hello can fall back to a PIN and its
/// public API cannot be told to accept biometrics only, so claiming a
/// biometric lock there would be untrue: there is no lock.
class UnsupportedBiometricAuthenticator implements BiometricAuthenticator {
  const UnsupportedBiometricAuthenticator();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<BiometricResult> authenticate(String reason) async =>
      BiometricResult.unavailable;
}

/// The authenticator for this platform.
BiometricAuthenticator platformAuthenticator() => Platform.isIOS
    ? IosBiometricAuthenticator()
    : const UnsupportedBiometricAuthenticator();

enum AppLockState {
  /// No biometrics-only verification here: nothing is protected.
  disabled,
  locked,
  authenticating,
  unlocked,
}

class AppLockController extends ChangeNotifier {
  AppLockController({
    required this.authenticator,
    this.inactivityLimit = const Duration(minutes: 5),
  });

  final BiometricAuthenticator authenticator;
  final Duration inactivityLimit;

  // Closed until [start] has found out whether biometrics are available, so
  // nothing shows in the first frame.
  AppLockState _state = AppLockState.locked;
  AppLockState get state => _state;

  /// Why the last attempt did not unlock (null before any attempt).
  BiometricResult? _failure;
  BiometricResult? get failure => _failure;

  bool _shielded = false;
  Timer? _idle;
  bool _started = false;

  /// Bumped on every lock, so the answer to an earlier prompt can never
  /// unlock a later lock.
  int _epoch = 0;

  /// The workspace must not be visible (locked, mid-prompt, or in a state
  /// where the system may take a preview picture).
  bool get covered =>
      _state == AppLockState.locked ||
      _state == AppLockState.authenticating ||
      (_shielded && _state != AppLockState.disabled);

  /// Locks at launch (when biometrics are available) and asks at once.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _epoch++;
    if (!await authenticator.isAvailable()) {
      _set(AppLockState.disabled);
      AppLog.warn(
        'App lock is off: biometrics-only verification is not available here',
      );
      return;
    }
    _set(AppLockState.locked);
    await unlock();
  }

  /// Covers the workspace now (background, screen lock, inactivity).
  void lock() {
    if (_state == AppLockState.disabled) return;
    _idle?.cancel();
    _idle = null;
    _epoch++;
    _failure = null;
    _set(AppLockState.locked);
  }

  /// Asks for Face ID / Touch ID. Does nothing if already unlocked or if a
  /// prompt is already showing (no duplicate prompts).
  Future<void> unlock() async {
    if (_state != AppLockState.locked) return;
    final epoch = _epoch;
    _failure = null;
    _set(AppLockState.authenticating);
    BiometricResult result;
    try {
      result = await authenticator.authenticate('Unlock misc.');
    } catch (e) {
      // Anything that goes wrong keeps the app locked (never opens it).
      AppLog.warn('Biometric prompt failed: $e');
      result = BiometricResult.unavailable;
    }
    if (epoch != _epoch) return; // locked again meanwhile: stays locked
    if (result == BiometricResult.success) {
      _failure = null;
      _set(AppLockState.unlocked);
      noteActivity();
    } else {
      _failure = result;
      _set(AppLockState.locked);
    }
  }

  /// Any touch or key press: restarts the inactivity countdown.
  void noteActivity() {
    if (_state != AppLockState.unlocked) return;
    _idle?.cancel();
    _idle = Timer(inactivityLimit, lock);
  }

  /// Reacts to the app moving between foreground and background. The
  /// biometric prompt itself makes the app "inactive" for a moment, which
  /// only covers the picture; it never locks or unlocks by itself.
  void lifecycleChanged(AppLifecycleState next) {
    switch (next) {
      case AppLifecycleState.inactive:
        _setShield(true);
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _setShield(true);
        lock();
      case AppLifecycleState.resumed:
        _setShield(false);
        if (_state == AppLockState.locked) unawaited(unlock());
    }
  }

  void _setShield(bool on) {
    if (_shielded == on) return;
    _shielded = on;
    notifyListeners();
  }

  void _set(AppLockState next) {
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _idle?.cancel();
    super.dispose();
  }
}

/// Puts the cover over the app. The app underneath stays alive (nothing is
/// rebuilt or lost) but is not painted, reachable by touch, focus or screen
/// reader while covered.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.controller, required this.child});

  final AppLockController controller;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    super.dispose();
  }

  bool _key(KeyEvent event) {
    widget.controller.noteActivity();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => widget.controller.noteActivity(),
      onPointerMove: (_) => widget.controller.noteActivity(),
      onPointerSignal: (_) => widget.controller.noteActivity(),
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final covered = widget.controller.covered;
          return Stack(
            fit: StackFit.expand,
            children: [
              ExcludeFocus(
                excluding: covered,
                child: Offstage(offstage: covered, child: widget.child),
              ),
              if (covered) _LockCover(controller: widget.controller),
            ],
          );
        },
      ),
    );
  }
}

class _LockCover extends StatelessWidget {
  const _LockCover({required this.controller});

  final AppLockController controller;

  String? get _message => switch (controller.failure) {
    BiometricResult.failed => 'That was not recognised. Try again.',
    BiometricResult.cancelled => null,
    BiometricResult.unavailable =>
      'Face ID / Touch ID is not available right now. Check that it is set '
          'up and not locked out in the iPhone/iPad Settings.',
    BiometricResult.success || null => null,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final locked = controller.state == AppLockState.locked;
    return ColoredBox(
      key: const ValueKey('app-lock-cover'),
      color: scheme.surface,
      child: Center(
        child: locked
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline, size: 40, color: scheme.primary),
                  const SizedBox(height: 16),
                  const Text('misc. is locked'),
                  if (_message != null) ...[
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: Text(
                        _message!,
                        key: const ValueKey('app-lock-message'),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const ValueKey('app-lock-unlock'),
                    onPressed: () => unawaited(controller.unlock()),
                    child: const Text('Unlock'),
                  ),
                ],
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}
