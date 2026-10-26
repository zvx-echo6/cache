import 'package:flutter/material.dart';
import 'package:cache_search/cache_search.dart';

import '../../theme.dart';
import '../../video/video_state.dart';

/// The instance's own details: its address, the account, and removing it. Returns true if the instance was removed.
Future<bool?> showInstanceSheet(BuildContext context, {required VideoState video, required VideoInstance instance}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: context.t.surface,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: _InstanceSheet(video: video, instance: instance),
    ),
  );
}

class _InstanceSheet extends StatefulWidget {
  const _InstanceSheet({required this.video, required this.instance});

  final VideoState video;
  final VideoInstance instance;

  @override
  State<_InstanceSheet> createState() => _InstanceSheetState();
}

class _InstanceSheetState extends State<_InstanceSheet> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _otp = TextEditingController();
  bool _needOtp = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _otp.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.video.login(widget.instance.id, _user.text.trim(), _pass.text, otp: _otp.text.trim().isEmpty ? null : _otp.text.trim());
      _pass.clear();
      _otp.clear();
      _needOtp = false;
    } on CacheSearchException catch (e) {
      if (e.code == 'otp_required') {
        _needOtp = true;
        _error = 'Enter the two-factor code.';
      } else if (e.code == 'auth_failed') {
        _error = 'The user name or password is wrong.';
      } else {
        _error = videoErrorText(e);
      }
    } catch (e) {
      _error = videoErrorText(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _remove() async {
    final keep = widget.video.saved.where((d) => d.instance == widget.instance.id).length;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${widget.instance.name}?'),
        content: Text(keep == 0 ? 'It is taken off your list.' : 'You have $keep video${keep == 1 ? '' : 's'} saved from it. They can stay on this phone, or go too.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          if (keep > 0) TextButton(onPressed: () => Navigator.pop(ctx, 'all'), child: const Text('Remove and delete videos')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'keep'), child: Text(keep > 0 ? 'Keep videos' : 'Remove')),
        ],
      ),
    );
    if (choice == null) return;
    try {
      await widget.video.removeInstance(widget.instance.id, deleteDownloads: choice == 'all');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = videoErrorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final i = widget.instance;
    return ListenableBuilder(
      listenable: widget.video,
      builder: (context, _) {
        final user = widget.video.userOf(i.id);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(i.name, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: k.text)),
              const SizedBox(height: 2),
              Text(i.host + (i.version.isEmpty ? '' : ' · PeerTube ${i.version}'), style: TextStyle(fontSize: 15, color: k.secondary)),
              const SizedBox(height: 20),
              if (user != null) ...[
                Text('Logged in as $user', style: TextStyle(fontSize: 17, color: k.text)),
                const SizedBox(height: 10),
                OutlinedButton(onPressed: () => widget.video.logout(i.id), child: const Text('Log out')),
              ] else ...[
                Text('Log in (optional)', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text)),
                const SizedBox(height: 4),
                Text('Only needed for videos the instance keeps behind a login.', style: TextStyle(fontSize: 14, color: k.secondary)),
                const SizedBox(height: 10),
                TextField(controller: _user, autocorrect: false, decoration: const InputDecoration(hintText: 'User name')),
                const SizedBox(height: 8),
                TextField(controller: _pass, obscureText: true, decoration: const InputDecoration(hintText: 'Password')),
                if (_needOtp) ...[
                  const SizedBox(height: 8),
                  TextField(controller: _otp, keyboardType: TextInputType.number, decoration: const InputDecoration(hintText: 'Two-factor code')),
                ],
                const SizedBox(height: 10),
                FilledButton(onPressed: _busy ? null : _login, child: Text(_busy ? 'Logging in…' : 'Log in')),
              ],
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: TextStyle(fontSize: 15, color: k.emergency))),
              const SizedBox(height: 20),
              TextButton.icon(
                onPressed: _remove,
                icon: Icon(Icons.delete_outline, color: k.emergency),
                label: Text('Remove this instance', style: TextStyle(color: k.emergency)),
              ),
            ],
          ),
        );
      },
    );
  }
}
