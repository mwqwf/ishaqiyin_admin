import 'package:flutter/material.dart';
import '../models.dart';
import '../services/admin_repository.dart';
import '../theme.dart';

class ManageSectionsScreen extends StatefulWidget {
  final List<Category> categories;
  const ManageSectionsScreen({super.key, required this.categories});

  @override
  State<ManageSectionsScreen> createState() => _ManageSectionsScreenState();
}

class _ManageSectionsScreenState extends State<ManageSectionsScreen> {
  late List<Category> _categories;
  final _catName = TextEditingController();
  final _subName = TextEditingController();
  String? _subCategoryId;
  bool _busyCat = false;
  bool _busySub = false;

  @override
  void initState() {
    super.initState();
    _categories = List.of(widget.categories);
  }

  @override
  void dispose() {
    _catName.dispose();
    _subName.dispose();
    super.dispose();
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _refreshCategories() async {
    final list = await AdminRepository.fetchCategories();
    if (mounted) setState(() => _categories = list);
  }

  Future<void> _addCategory() async {
    final name = _catName.text.trim();
    if (name.isEmpty) return;
    setState(() => _busyCat = true);
    try {
      await AdminRepository.addCategory(name);
      _catName.clear();
      await _refreshCategories();
      _snack('تم إنشاء القسم الرئيسي.');
    } catch (e) {
      _snack('تعذّر إنشاء القسم: $e');
    }
    if (mounted) setState(() => _busyCat = false);
  }

  Future<void> _addSubcategory() async {
    final name = _subName.text.trim();
    if (name.isEmpty || _subCategoryId == null) {
      _snack('أدخل الاسم واختر القسم الرئيسي.');
      return;
    }
    setState(() => _busySub = true);
    try {
      await AdminRepository.addSubcategory(name, _subCategoryId!);
      _subName.clear();
      setState(() => _subCategoryId = null);
      _snack('تم إنشاء القسم الفرعي.');
    } catch (e) {
      _snack('تعذّر إنشاء القسم الفرعي: $e');
    }
    if (mounted) setState(() => _busySub = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('إدارة الأقسام')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _card(
            title: 'إنشاء قسم رئيسي',
            children: [
              TextField(
                controller: _catName,
                decoration: const InputDecoration(
                  labelText: 'اسم القسم الرئيسي',
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busyCat ? null : _addCategory,
                child: _busyCat
                    ? const _Spin()
                    : const Text('إنشاء القسم الرئيسي'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _card(
            title: 'إنشاء قسم فرعي',
            children: [
              TextField(
                controller: _subName,
                decoration: const InputDecoration(
                  labelText: 'اسم القسم الفرعي',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _subCategoryId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'اختر القسم الرئيسي',
                ),
                items: _categories
                    .map(
                      (c) => DropdownMenuItem(
                        value: c.id,
                        child: Text(c.name, overflow: TextOverflow.ellipsis),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _subCategoryId = v),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busySub ? null : _addSubcategory,
                child: _busySub
                    ? const _Spin()
                    : const Text('إنشاء القسم الفرعي'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _card({required String title, required List<Widget> children}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: kTeal,
              ),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _Spin extends StatelessWidget {
  const _Spin();
  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 22,
    height: 22,
    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
  );
}
