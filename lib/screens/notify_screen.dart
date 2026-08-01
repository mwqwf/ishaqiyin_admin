import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import '../theme.dart';

/// شاشة «إرسال إشعار» — نظير زر/لوحة الإشعارات في نبراس.
/// تكتب وثيقة في مجموعة broadcast، ودالة onBroadcast ترسل دفعاً عبر FCM
/// لكل مستخدمي تطبيق «منبر ادكصهك» المشتركين في الموضوع.
class NotifyScreen extends StatefulWidget {
  const NotifyScreen({super.key});

  @override
  State<NotifyScreen> createState() => _NotifyScreenState();
}

class _NotifyScreenState extends State<NotifyScreen> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  bool _sending = false;
  String _message = '';
  bool _isError = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  bool get _canSend =>
      (_title.text.trim().isNotEmpty || _body.text.trim().isNotEmpty) &&
      _title.text.trim().length <= 100 &&
      _body.text.trim().length <= 500 &&
      !_sending;

  Future<void> _send() async {
    if (!_canSend) return;
    setState(() {
      _sending = true;
      _message = '';
      _isError = false;
    });
    try {
      final response = await FirebaseFunctions.instance
          .httpsCallable('sendNotification')
          .call(<String, dynamic>{
            'title': _title.text.trim(),
            'body': _body.text.trim(),
          });
      final data = response.data;
      if (data is Map && data['success'] == false) {
        throw StateError((data['error'] ?? 'رفض الخادم الإرسال').toString());
      }
      final sent = data is Map ? (data['sent'] as num?)?.toInt() : null;
      final failed = data is Map ? (data['failed'] as num?)?.toInt() : null;
      if (!mounted) return;
      setState(() {
        _sending = false;
        _title.clear();
        _body.clear();
        _message = sent == null
            ? 'أكّد الخادم استلام الإشعار وإرساله.'
            : 'أكّد الخادم الإرسال إلى $sent جهاز'
                  '${(failed ?? 0) > 0 ? '، وتعذّر على $failed' : ''}.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _isError = true;
        _message = 'تعذّر إرسال الإشعار: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('إرسال إشعار')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: kBoxBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              'يصل هذا الإشعار فوراً (دفع) إلى كل مستخدمي تطبيق «منبر ادكصهك». '
              'كما تُرسَل إشعارات تلقائية عند إضافة قسم أو درس أو كتاب.',
              style: TextStyle(height: 1.6, fontSize: 14),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            onChanged: (_) => setState(() {}),
            maxLength: 100,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'العنوان',
              prefixIcon: Icon(Icons.title),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _body,
            onChanged: (_) => setState(() {}),
            maxLength: 500,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'نص الإشعار',
              alignLabelWithHint: true,
              prefixIcon: Padding(
                padding: EdgeInsets.only(bottom: 60),
                child: Icon(Icons.message_outlined),
              ),
            ),
          ),
          const SizedBox(height: 18),
          if (_message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _isError ? kDanger : Colors.green.shade700,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          FilledButton.icon(
            onPressed: _canSend ? _send : null,
            icon: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.send),
            label: Text(_sending ? 'جارٍ الإرسال...' : 'إرسال الإشعار'),
          ),
        ],
      ),
    );
  }
}
