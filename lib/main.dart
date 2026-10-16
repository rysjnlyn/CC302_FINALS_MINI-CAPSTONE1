import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

/// Small SharedPreferences-backed draft store. Each form uses a stable key,
/// and writes are debounced so typing does not cause a preference write per key.
class FormDrafts {
  static final Map<String, Timer> _timers = {};
  static final Map<String, Map<String, dynamic>> _pending = {};
  static final Map<String, Future<void>> _writes = {};
  static String _key(String id) => 'formDraft:$id';

  static Future<Map<String, dynamic>> load(String id) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key(id));
      if (raw == null) return {};
      final value = jsonDecode(raw);
      return value is Map<String, dynamic> ? value : {};
    } catch (_) {
      // A malformed/outdated draft should never prevent the form from opening.
      return {};
    }
  }

  static void save(String id, Map<String, dynamic> values) {
    _pending[id] = Map<String, dynamic>.from(values);
    _timers.remove(id)?.cancel();
    _timers[id] = Timer(const Duration(milliseconds: 400), () {
      _timers.remove(id);
      unawaited(_persist(id));
    });
  }

  static Future<void> _persist(String id) async {
    final previous = _writes[id];
    Future<void> write() async {
      if (_pending[id] == null) return;
      try {
        final prefs = await SharedPreferences.getInstance();
        final values = _pending[id];
        if (values == null) return;
        await prefs.setString(_key(id), jsonEncode(values));
        if (identical(_pending[id], values)) _pending.remove(id);
      } catch (_) {
        // Draft storage is best effort; preserve normal form behavior on errors.
      }
    }

    final next = previous == null ? write() : previous.then((_) => write());
    _writes[id] = next;
    await next;
    if (identical(_writes[id], next)) _writes.remove(id);
  }

  static Future<void> flushPending() async {
    final ids = _pending.keys.toList();
    for (final id in ids) {
      _timers.remove(id)?.cancel();
      await _persist(id);
    }
  }

  static Future<void> clear(String id) async {
    _timers.remove(id)?.cancel();
    _pending.remove(id);
    try {
      await _writes[id];
      await (await SharedPreferences.getInstance()).remove(_key(id));
    } catch (_) {}
  }
}

/// Restores and debounces a single non-sensitive text field draft.
class DraftTextController {
  final String draftId;
  final String field;
  final TextEditingController controller = TextEditingController();
  bool _restoring = false;
  bool _editedBeforeRestore = false;
  bool _disposed = false;

  DraftTextController(this.draftId, {this.field = 'value'}) {
    controller.addListener(_onChanged);
  }

  void _onChanged() {
    if (_restoring) return;
    _editedBeforeRestore = true;
    FormDrafts.save(draftId, {field: controller.text});
  }

  Future<void> restore({VoidCallback? onRestored}) async {
    final draft = await FormDrafts.load(draftId);
    if (_disposed) return;
    _restoring = true;
    if (!_editedBeforeRestore) {
      controller.text = draft[field] as String? ?? '';
    }
    _restoring = false;
    if (_editedBeforeRestore) _onChanged();
    onRestored?.call();
  }

  void dispose() {
    _disposed = true;
    controller.removeListener(_onChanged);
    controller.dispose();
  }
}

class _DialogControllers extends StatefulWidget {
  final List<TextEditingController> controllers;
  final Widget child;
  const _DialogControllers({required this.controllers, required this.child});

  @override
  State<_DialogControllers> createState() => _DialogControllersState();
}

class _DialogControllersState extends State<_DialogControllers> {
  @override
  void dispose() {
    for (final controller in widget.controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = ClearTrackState();
  await app.load();
  runApp(ClearTrackApp(state: app));
}

const green = Color(0xFF236B4A);
const cream = Color(0xFFF7F5EE);
const ink = Color(0xFF24332B);

class Department {
  int id;
  String name, short, icon, description, office;
  List<String> requirements;
  Department(this.id, this.name, this.short, this.icon, this.description,
      this.office, this.requirements);
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'short': short,
        'icon': icon,
        'description': description,
        'office': office,
        'requirements': requirements
      };
  factory Department.fromJson(Map<String, dynamic> j) => Department(
      j['id'],
      j['name'],
      j['short'] ?? '',
      j['icon'] ?? '✓',
      j['description'] ?? '',
      j['office'] ?? '',
      List<String>.from(j['requirements'] ?? []));
}

class LibraryBook {
  final String title;
  final List<String> authors;
  final int? firstPublishYear;
  final int? coverId;

  const LibraryBook(
      {required this.title,
      required this.authors,
      this.firstPublishYear,
      this.coverId});

  factory LibraryBook.fromJson(Map<String, dynamic> json) => LibraryBook(
        title: json['title'] as String? ?? 'Untitled',
        authors: (json['author_name'] as List<dynamic>? ?? [])
            .whereType<String>()
            .toList(),
        firstPublishYear: json['first_publish_year'] as int?,
        coverId: json['cover_i'] as int?,
      );
}

/// Searches Open Library and returns book matches for the given title, author,
/// or keyword. The request uses Open Library's documented Search API.
Future<List<LibraryBook>> fetchLibraryBooks(String query) async {
  final trimmedQuery = query.trim();
  if (trimmedQuery.isEmpty) {
    throw ArgumentError('Enter a book title, author, or keyword.');
  }
  final uri = Uri.https('openlibrary.org', '/search.json', {
    'q': trimmedQuery,
    'fields': 'key,title,author_name,first_publish_year,cover_i',
    'limit': '20',
  });
  final response = await http.get(uri).timeout(const Duration(seconds: 15));
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw http.ClientException(
        'Book search returned HTTP ${response.statusCode}', uri);
  }
  final decoded = jsonDecode(response.body);
  if (decoded is! Map<String, dynamic> || decoded['docs'] is! List) {
    throw const FormatException(
        'The book API returned an unexpected response.');
  }
  return (decoded['docs'] as List)
      .whereType<Map>()
      .map((row) => LibraryBook.fromJson(Map<String, dynamic>.from(row)))
      .toList();
}

class ClearanceRecord {
  int departmentId;
  String status, note, updatedAt;
  ClearanceRecord(this.departmentId, this.status,
      {this.note = '', this.updatedAt = 'Oct 13, 2026'});
  Map<String, dynamic> toJson() => {
        'departmentId': departmentId,
        'status': status,
        'note': note,
        'updatedAt': updatedAt
      };
  factory ClearanceRecord.fromJson(Map<String, dynamic> j) =>
      ClearanceRecord(j['departmentId'], j['status'],
          note: j['note'] ?? '', updatedAt: j['updatedAt'] ?? '');
}

class Submission {
  int id, departmentId;
  String details, fileName, fileData, status, date, studentName, studentId;
  Submission(this.id, this.departmentId, this.details, this.fileName,
      this.fileData, this.status, this.date,
      {this.studentName = 'Alex Student', this.studentId = '2026001'});
  Map<String, dynamic> toJson() => {
        'id': id,
        'departmentId': departmentId,
        'details': details,
        'fileName': fileName,
        'fileData': fileData,
        'status': status,
        'date': date,
        'studentName': studentName,
        'studentId': studentId
      };
  factory Submission.fromJson(Map<String, dynamic> j) => Submission(
      j['id'],
      j['departmentId'],
      j['details'] ?? '',
      j['fileName'] ?? '',
      j['fileData'] ?? '',
      j['status'] ?? 'pending',
      j['date'] ?? '',
      studentName: j['studentName'] ?? 'Alex Student',
      studentId: j['studentId'] ?? '2026001');
}

class Account {
  String id, name, email, password, role, course, year;
  Account(this.id, this.name, this.email, this.password, this.role,
      {this.course = '', this.year = ''});
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'password': password,
        'role': role,
        'course': course,
        'year': year
      };
  factory Account.fromJson(Map<String, dynamic> j) => Account(j['id'],
      j['name'], j['email'], j['password'] ?? '', j['role'] ?? 'student',
      course: j['course'] ?? '', year: j['year'] ?? '');
}

class ClearTrackState extends ChangeNotifier {
  late SharedPreferences prefs;
  List<Department> departments = [];
  List<ClearanceRecord> records = [];
  List<Submission> submissions = [];
  List<Map<String, String>> activities = [];
  List<Account> accounts = [];
  Account? user;

  List<T> _loadCollection<T>(String key, List<Map<String, dynamic>> defaults,
      T Function(Map<String, dynamic>) decode) {
    List<T> decodeDefaults() => defaults.map(decode).toList();
    final raw = prefs.getString(key);
    if (raw == null) return decodeDefaults();
    try {
      final json = jsonDecode(raw);
      if (json is! List) return decodeDefaults();
      final restored = <T>[];
      for (final item in json) {
        if (item is! Map) continue;
        try {
          restored.add(decode(Map<String, dynamic>.from(item)));
        } catch (_) {
          // Skip malformed rows while keeping the valid records in this list.
        }
      }
      return json.isNotEmpty && restored.isEmpty ? decodeDefaults() : restored;
    } catch (_) {
      // A corrupt collection should not prevent other saved data from loading.
      return decodeDefaults();
    }
  }

  List<T> _uniqueBy<T, K>(List<T> items, K Function(T item) keyOf) {
    final unique = <K, T>{};
    for (final item in items) {
      unique[keyOf(item)] = item;
    }
    return unique.values.toList();
  }

  Future<void> load() async {
    prefs = await SharedPreferences.getInstance();
    departments = _uniqueBy(
        _loadCollection(
            'departments', _defaultDepartments(), Department.fromJson),
        (department) => department.id);
    records = _uniqueBy(
        _loadCollection('records', _defaultRecords(), ClearanceRecord.fromJson),
        (record) => record.departmentId);
    submissions = _uniqueBy(
        _loadCollection('submissions', const [], Submission.fromJson),
        (submission) => submission.id);
    final activityRows = _loadCollection<Map<String, String>>(
        'activities',
        const [
          {
            'action': 'ClearTrack account created',
            'detail': 'Your student clearance workspace is ready.',
            'date': 'Oct 13, 2026'
          }
        ],
        (row) => Map<String, String>.from(row));
    activities = activityRows;
    accounts = _uniqueBy(
        _loadCollection(
            'accounts',
            [
              {
                'id': '2026001',
                'name': 'Alex Student',
                'email': 'student@cleartrack.edu',
                'password': 'student123',
                'role': 'student',
                'course': 'BS Information Technology',
                'year': '3rd Year'
              },
              {
                'id': 'ADMIN01',
                'name': 'ClearTrack Administrator',
                'email': 'admin@cleartrack.edu',
                'password': 'admin123',
                'role': 'admin',
                'course': '',
                'year': ''
              }
            ],
            Account.fromJson),
        (account) => account.id);
    final uniqueEmails = <String>{};
    accounts = accounts
        .where((account) => uniqueEmails.add(account.email.toLowerCase()))
        .toList();
    final uid = prefs.getString('currentUser');
    if (uid != null) {
      try {
        user = accounts.firstWhere((a) => a.id == uid);
      } catch (_) {
        user = null;
        await prefs.remove('currentUser');
      }
    }
    await _save(notify: false);
  }

  List<Map<String, dynamic>> _defaultDepartments() => [
        {
          'id': 1,
          'name': 'Library',
          'short': 'LIB',
          'icon': '▤',
          'description':
              'Return borrowed books and settle library obligations.',
          'office': 'Library Services',
          'requirements': [
            'Return all borrowed books',
            'Settle outstanding library fines'
          ]
        },
        {
          'id': 2,
          'name': 'Finance Office',
          'short': 'FIN',
          'icon': '₱',
          'description': 'Confirm tuition, fees, and account balances.',
          'office': 'Finance and Accounting',
          'requirements': [
            'Settle outstanding balances',
            'Verify payment records'
          ]
        },
        {
          'id': 3,
          'name': 'Registrar',
          'short': 'REG',
          'icon': '▣',
          'description': 'Verify enrollment records and academic documents.',
          'office': 'Office of the Registrar',
          'requirements': [
            'Confirm enrollment information',
            'Return borrowed school documents'
          ]
        },
        {
          'id': 4,
          'name': 'Laboratory',
          'short': 'LAB',
          'icon': '⌘',
          'description': 'Return equipment and clear laboratory accounts.',
          'office': 'Laboratory Services',
          'requirements': [
            'Return borrowed equipment',
            'Settle laboratory charges'
          ]
        },
        {
          'id': 5,
          'name': 'Guidance Office',
          'short': 'GUD',
          'icon': '♡',
          'description': 'Complete required guidance consultations.',
          'office': 'Student Guidance Services',
          'requirements': ['Complete required consultation']
        },
        {
          'id': 6,
          'name': 'Student Affairs',
          'short': 'SAO',
          'icon': '☆',
          'description':
              'Confirm student organization and activity obligations.',
          'office': 'Student Affairs Office',
          'requirements': [
            'Return organization property',
            'Complete activity obligations'
          ]
        },
        {
          'id': 7,
          'name': 'Department Office',
          'short': 'DEP',
          'icon': '⌂',
          'description': 'Obtain academic department approval.',
          'office': 'Academic Department',
          'requirements': [
            'Complete department checklist',
            'Secure adviser approval'
          ]
        }
      ];
  List<Map<String, dynamic>> _defaultRecords() => [
        {
          'departmentId': 1,
          'status': 'approved',
          'note': '',
          'updatedAt': 'Oct 13, 2026'
        },
        {
          'departmentId': 2,
          'status': 'pending',
          'note': '',
          'updatedAt': 'Oct 13, 2026'
        },
        {
          'departmentId': 3,
          'status': 'pending',
          'note': '',
          'updatedAt': 'Oct 13, 2026'
        },
        {
          'departmentId': 4,
          'status': 'needs-action',
          'note': 'Please return the borrowed laboratory kit.',
          'updatedAt': 'Oct 13, 2026'
        },
        {
          'departmentId': 5,
          'status': 'approved',
          'note': '',
          'updatedAt': 'Oct 13, 2026'
        },
        {
          'departmentId': 6,  
          'status': 'pending',
          'note': '',
          'updatedAt': 'Oct 13, 2026'
        },
        {
          'departmentId': 7,
          'status': 'pending',
          'note': '',
          'updatedAt': 'Oct 13, 2026'
        }
      ];
  Future<void> _save({bool notify = true}) async {
    await prefs.setString(
        'departments', jsonEncode(departments.map((e) => e.toJson()).toList()));
    await prefs.setString(
        'records', jsonEncode(records.map((e) => e.toJson()).toList()));
    await prefs.setString(
        'submissions', jsonEncode(submissions.map((e) => e.toJson()).toList()));
    await prefs.setString('activities', jsonEncode(activities));
    await prefs.setString(
        'accounts', jsonEncode(accounts.map((e) => e.toJson()).toList()));
    if (notify) notifyListeners();
  }

  void log(String action, String detail,
      {int? departmentId, int? submissionId}) {
    activities.insert(0, {
      'action': action,
      'detail': detail,
      'date': DateTime.now().toString().substring(0, 10),
      if (departmentId != null) 'departmentId': departmentId.toString(),
      if (submissionId != null) 'submissionId': submissionId.toString(),
    });
    if (activities.length > 100) activities.removeLast();
  }

  Department? dept(int id) {
    for (final d in departments) {
      if (d.id == id) return d;
    }
    return null;
  }

  ClearanceRecord? record(int id) {
    for (final r in records) {
      if (r.departmentId == id) return r;
    }
    return null;
  }

  int get approved => records.where((r) => r.status == 'approved').length;
  int get approvedSubmissions =>
      submissions.where((submission) => submission.status == 'approved').length;
  int get pending => records.where((r) => r.status == 'pending').length;
  int get needsAction => records
      .where((r) => r.status == 'needs-action' || r.status == 'rejected')
      .length;
  int get progress =>
      records.isEmpty ? 0 : (approved * 100 / records.length).round();
  bool login(String email, String password) {
    try {
      user = accounts.firstWhere((a) =>
          a.email.toLowerCase() == email.trim().toLowerCase() &&
          a.password == password);
      prefs.setString('currentUser', user!.id);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  String? register(String name, String id, String email, String password) {
    if (accounts.any(
        (a) => a.id == id || a.email.toLowerCase() == email.toLowerCase())) {
      return 'Email or student ID is already registered.';
    }
    if (password.length < 6) return 'Password must be at least 6 characters.';
    final a = Account(id, name, email, password, 'student',
        course: 'Not set', year: 'Not set');
    accounts.add(a);
    user = a;
    prefs.setString('currentUser', id);
    log('ClearTrack account created',
        'Your student clearance workspace is ready.');
    _save();
    return null;
  }

  void logout() {
    user = null;
    prefs.remove('currentUser');
    notifyListeners();
  }

  Future<void> submit(
      int departmentId, String details, PlatformFile? file) async {
    if (details.trim().isEmpty && file == null) {
      throw Exception('Add a note or attach a document before submitting.');
    }
    String data = '';
    if (file?.bytes != null) data = base64Encode(file!.bytes!);
    final submission = Submission(
        DateTime.now().millisecondsSinceEpoch,
        departmentId,
        details.trim(),
        file?.name ?? '',
        data,
        'pending',
        DateTime.now().toString().substring(0, 10),
        studentName: user?.name ?? 'Alex Student',
        studentId: user?.id ?? '2026001');
    submissions.insert(0, submission);
    final r = record(departmentId);
    if (r != null) {
      r.status = 'pending';
      r.note = 'Submitted for department review';
      r.updatedAt = DateTime.now().toString().substring(0, 10);
    }
    log('Requirement submitted',
        '${dept(departmentId)?.name ?? 'Department'} submitted for review',
        departmentId: departmentId, submissionId: submission.id);
    await _save();
  }

  Future<void> review(Submission s, String status) async {
    s.status = status;
    final r = record(s.departmentId);
    if (r != null) {
      r.status = status;
      r.note = status == 'approved'
          ? 'Submission approved'
          : 'Please review the requirement and submit again';
      r.updatedAt = DateTime.now().toString().substring(0, 10);
    }
    final outcome = status == 'approved' ? 'approved' : 'not approved';
    log('Submission $outcome',
        '${dept(s.departmentId)?.name ?? 'Department'} - ${s.studentName} - Status: ${status.toUpperCase()}',
        departmentId: s.departmentId, submissionId: s.id);
    await _save();
  }

  Future<void> editSubmission(
      Submission submission, String details, PlatformFile? file) async {
    submission.details = details.trim();
    if (file != null) {
      submission.fileName = file.name;
      submission.fileData = file.bytes == null ? '' : base64Encode(file.bytes!);
    }
    submission.status = 'pending';
    final r = record(submission.departmentId);
    if (r != null) {
      r.status = 'pending';
      r.note = 'Updated submission for department review';
      r.updatedAt = DateTime.now().toString().substring(0, 10);
    }
    await _save();
  }

  Future<void> setStatus(ClearanceRecord r, String status) async {
    r.status = status;
    r.updatedAt = DateTime.now().toString().substring(0, 10);
    log('Status updated', '${dept(r.departmentId)?.name} changed to $status');
    await _save();
  }

  Future<void> reset() async {
    departments = _defaultDepartments().map(Department.fromJson).toList();
    records = _defaultRecords().map(ClearanceRecord.fromJson).toList();
    submissions = [];
    activities = [
      {
        'action': 'Demo data reset',
        'detail': 'Sample clearance records restored.',
        'date': DateTime.now().toString().substring(0, 10)
      }
    ];
    await _save();
  }

  Future<void> deleteSubmission(Submission s) async {
    submissions.removeWhere((x) => x.id == s.id);
    await _save();
  }

  Future<void> removeSubmissionAttachment(Submission submission) async {
    if (submission.details.trim().isEmpty) {
      submissions.removeWhere((item) => item.id == submission.id);
      final r = record(submission.departmentId);
      if (r != null) {
        r.status = 'needs-action';
        r.note = 'Submission removed; please submit the requirement again';
        r.updatedAt = DateTime.now().toString().substring(0, 10);
      }
      log('Submission removed',
          '${dept(submission.departmentId)?.name ?? 'Department'} attachment removed');
    } else {
      submission.fileName = '';
      submission.fileData = '';
      submission.status = 'pending';
      final r = record(submission.departmentId);
      if (r != null) {
        r.status = 'pending';
        r.note = 'Attachment removed; note sent for department review';
        r.updatedAt = DateTime.now().toString().substring(0, 10);
      }
      log('Submission attachment removed',
          '${dept(submission.departmentId)?.name ?? 'Department'} note retained');
    }
    await _save();
  }

  Future<void> saveDepartment(Department d, {int? editingId}) async {
    if (editingId != null) {
      final i = departments.indexWhere((x) => x.id == editingId);
      if (i >= 0) departments[i] = d;
    } else {
      d.id = departments.isEmpty
          ? 1
          : departments.map((e) => e.id).reduce((a, b) => a > b ? a : b) + 1;
      departments.add(d);
      records.add(ClearanceRecord(d.id, 'pending'));
    }
    log('Department directory updated', d.name);
    await _save();
  }

  Future<void> deleteDepartment(Department d) async {
    departments.removeWhere((department) => department.id == d.id);
    records.removeWhere((r) => r.departmentId == d.id);
    await _save();
  }
}

class ClearTrackApp extends StatefulWidget {
  final ClearTrackState state;
  const ClearTrackApp({super.key, required this.state});

  @override
  State<ClearTrackApp> createState() => _ClearTrackAppState();
}

class _ClearTrackAppState extends State<ClearTrackApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(FormDrafts.flushPending());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(FormDrafts.flushPending());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) => MaterialApp(
          title: 'ClearTrack',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            scaffoldBackgroundColor: cream,
            colorScheme: ColorScheme.fromSeed(
                seedColor: green, primary: green, surface: Colors.white),
            appBarTheme: const AppBarTheme(
                backgroundColor: cream, foregroundColor: ink, elevation: 0),
            inputDecorationTheme: InputDecorationTheme(
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Colors.black12)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Colors.black12))),
          ),
          home: PortalShell(state: widget.state)));
}

class PortalShell extends StatefulWidget {
  final ClearTrackState state;
  const PortalShell({super.key, required this.state});
  @override
  State<PortalShell> createState() => _PortalShellState();
}

class _PortalShellState extends State<PortalShell> {
  int index = 0;
  int? _departmentFocusId;
  int? _clearanceFocusId;
  int? _submissionFocusId;
  String authPage = 'login';
  final GlobalKey<_DepartmentViewState> _departmentKey =
      GlobalKey<_DepartmentViewState>();

  @override
  void initState() {
    super.initState();
    unawaited(_restoreLastPage());
  }

  static const _pageKeyPrefix = 'portalPage:';

  List<String> _pagesForRole(String? role) => role == 'admin'
      ? [
          'Overview',
          'Requests',
          'Approved',
          'Returned',
          'Library',
          'Departments',
          'Students',
          'Activity',
          'Profile'
        ]
      : [
          'Dashboard',
          'My clearance',
          'Library',
          'Departments',
          'Activity',
          'Profile'
        ];

  Future<void> _restoreLastPage() async {
    final user = widget.state.user;
    if (user == null) return;
    final prefs = await SharedPreferences.getInstance();
    final pages = _pagesForRole(user.role);
    final savedPage = prefs.getString('$_pageKeyPrefix${user.id}');
    final draft = user.role == 'admin'
        ? await FormDrafts.load('department:${user.id}:new')
        : <String, dynamic>{};
    final restoreDepartmentDraft = draft.isNotEmpty;
    final page = restoreDepartmentDraft
        ? 'Departments'
        : (savedPage != null && pages.contains(savedPage)
            ? savedPage
            : pages.first);
    if (!mounted) return;
    setState(() => index = pages.indexOf(page));
    if (restoreDepartmentDraft) {
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) await _departmentKey.currentState?.reopenAddDraft();
    }
  }

  void _selectPage(String page, List<String> pages) {
    final nextIndex = pages.indexOf(page);
    if (nextIndex < 0) return;
    setState(() {
      index = nextIndex;
      _departmentFocusId = null;
      _clearanceFocusId = null;
      _submissionFocusId = null;
    });
    final user = widget.state.user;
    if (user != null) {
      unawaited(SharedPreferences.getInstance()
          .then((prefs) => prefs.setString('$_pageKeyPrefix${user.id}', page)));
    }
  }

  void _openDepartment(Department department, List<String> pages) {
    final nextIndex = pages.indexOf('Departments');
    if (nextIndex < 0) return;
    setState(() {
      index = nextIndex;
      _departmentFocusId = department.id;
      _clearanceFocusId = null;
      _submissionFocusId = null;
    });
    final user = widget.state.user;
    if (user != null) {
      unawaited(SharedPreferences.getInstance().then((prefs) =>
          prefs.setString('$_pageKeyPrefix${user.id}', 'Departments')));
    }
  }

  void _openClearanceDepartment(int departmentId, List<String> pages) {
    final nextIndex = pages.indexOf('My clearance');
    if (nextIndex < 0) return;
    setState(() {
      index = nextIndex;
      _departmentFocusId = null;
      _clearanceFocusId = departmentId;
      _submissionFocusId = null;
    });
    final user = widget.state.user;
    if (user != null) {
      unawaited(SharedPreferences.getInstance().then((prefs) =>
          prefs.setString('$_pageKeyPrefix${user.id}', 'My clearance')));
    }
  }

  void _openActivityItem(Map<String, String> activity, List<String> pages) {
    final departmentId = int.tryParse(activity['departmentId'] ?? '');
    final submissionId = int.tryParse(activity['submissionId'] ?? '');
    if (departmentId == null || submissionId == null) return;
    if (widget.state.user?.role == 'admin') {
      final nextIndex = pages.indexOf('Requests');
      if (nextIndex < 0) return;
      setState(() {
        index = nextIndex;
        _departmentFocusId = null;
        _clearanceFocusId = null;
        _submissionFocusId = submissionId;
      });
      final user = widget.state.user;
      if (user != null) {
        unawaited(SharedPreferences.getInstance().then((prefs) =>
            prefs.setString('$_pageKeyPrefix${user.id}', 'Requests')));
      }
    } else {
      _openClearanceDepartment(departmentId, pages);
    }
  }

  void _onAuthDone() {
    setState(() => index = 0);
    unawaited(_restoreLastPage());
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final pages = _pagesForRole(s.user?.role);
    final selected = index.clamp(0, pages.length - 1);
    return Scaffold(
      appBar: AppBar(
          title: Row(children: [
        Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
                color: green, borderRadius: BorderRadius.circular(12)),
            child: const Center(
                child: Text('CT',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)))),
        const SizedBox(width: 10),
        const Text('ClearTrack', style: TextStyle(fontWeight: FontWeight.w800)),
        const Spacer(),
        if (s.user != null)
          PopupMenuButton<String>(
              tooltip: 'Navigate',
              icon: const Icon(Icons.menu),
              onSelected: (p) => _selectPage(p, pages),
              itemBuilder: (ctx) => [
                    for (final p in pages)
                      PopupMenuItem(value: p, child: Text(p))
                  ]),
        if (s.user != null)
          Text(s.user!.name.split(' ').first,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        if (s.user != null)
          IconButton(
              tooltip: 'Sign out',
              onPressed: () {
                s.logout();
                setState(() => index = 0);
              },
              icon: const Icon(Icons.logout)),
      ])),
      body: s.user == null
          ? AuthView(state: s, onDone: _onAuthDone, initial: authPage)
          : LayoutBuilder(builder: (context, c) {
              final wide = c.maxWidth > 850;
              return Row(children: [
                if (wide)
                  NavigationRail(
                      selectedIndex: selected,
                      onDestinationSelected: (i) =>
                          _selectPage(pages[i], pages),
                      labelType: NavigationRailLabelType.all,
                      backgroundColor: Colors.white,
                      destinations: [
                        for (final p in pages)
                          NavigationRailDestination(
                              icon: Icon(_icon(p)), label: Text(p))
                      ]),
                Expanded(
                    child: IndexedStack(index: selected, children: [
                  for (final p in pages)
                    SingleChildScrollView(
                        padding: EdgeInsets.all(wide ? 30 : 18),
                        child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1150),
                            child: PageRouter(
                                state: s,
                                page: p,
                                departmentFocusId: _departmentFocusId,
                                clearanceFocusId: _clearanceFocusId,
                                submissionFocusId: _submissionFocusId,
                                departmentKey:
                                    p == 'Departments' ? _departmentKey : null,
                                onNavigate: (p) => _selectPage(p, pages),
                                onOpenActivity: (activity) =>
                                    _openActivityItem(activity, pages),
                                onOpenDepartment: (department) =>
                                    _openDepartment(department, pages),
                                onOpenClearanceDepartment: (departmentId) =>
                                    _openClearanceDepartment(
                                        departmentId, pages),
                                onClearDepartmentFocus: () => setState(() {
                                      _departmentFocusId = null;
                                    }),
                                onClearClearanceFocus: () => setState(() {
                                      _clearanceFocusId = null;
                                    }))))
                ])),
              ]);
            }),
      bottomNavigationBar: s.user == null
          ? null
          : LayoutBuilder(
              builder: (context, c) => c.maxWidth > 850 || selected >= 5
                  ? const SizedBox.shrink()
                  : NavigationBar(
                      selectedIndex: selected,
                      onDestinationSelected: (i) =>
                          _selectPage(pages[i], pages),
                      destinations: [
                          for (final p in pages.take(5))
                            NavigationDestination(
                                icon: Icon(_icon(p)), label: p)
                        ])),
    );
  }

  IconData _icon(String p) => switch (p) {
        'Dashboard' => Icons.dashboard_outlined,
        'Overview' => Icons.dashboard_outlined,
        'My clearance' => Icons.fact_check_outlined,
        'Requests' => Icons.inbox_outlined,
        'Approved' => Icons.check_circle_outline,
        'Returned' => Icons.assignment_return_outlined,
        'Library' => Icons.local_library_outlined,
        'Departments' => Icons.apartment_outlined,
        'Students' => Icons.people_outline,
        'Activity' => Icons.history,
        'Profile' => Icons.person_outline,
        _ => Icons.dashboard
      };
}

class PageRouter extends StatelessWidget {
  final ClearTrackState state;
  final String page;
  final ValueChanged<String> onNavigate;
  final ValueChanged<Department> onOpenDepartment;
  final ValueChanged<int> onOpenClearanceDepartment;
  final int? departmentFocusId;
  final int? clearanceFocusId;
  final int? submissionFocusId;
  final ValueChanged<Map<String, String>> onOpenActivity;
  final VoidCallback onClearDepartmentFocus;
  final VoidCallback onClearClearanceFocus;
  final Key? departmentKey;
  const PageRouter(
      {super.key,
      required this.state,
      required this.page,
      required this.onNavigate,
      required this.onOpenDepartment,
      required this.onOpenClearanceDepartment,
      required this.departmentFocusId,
      required this.clearanceFocusId,
      required this.submissionFocusId,
      required this.onOpenActivity,
      required this.onClearDepartmentFocus,
      required this.onClearClearanceFocus,
      this.departmentKey});
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (page == 'Dashboard')
          DashboardView(
              state: state,
              onNavigate: onNavigate,
              onOpenDepartment: onOpenDepartment)
        else if (page == 'My clearance')
          ClearanceView(
              state: state,
              focusDepartmentId: clearanceFocusId,
              onOpenDepartment: onOpenClearanceDepartment,
              onClearFocus: onClearClearanceFocus)
        else if (page == 'Departments')
          DepartmentView(
              key: departmentKey,
              state: state,
              admin: state.user?.role == 'admin',
              onOpenDepartment: onOpenDepartment,
              focusDepartmentId: departmentFocusId,
              onClearFocus: onClearDepartmentFocus)
        else if (page == 'Library')
          const LibraryView()
        else if (page == 'Activity')
          ActivityView(state: state, onOpenActivity: onOpenActivity)
        else if (page == 'Profile')
          ProfileView(state: state)
        else if (page == 'Overview')
          AdminDashboard(state: state, onNavigate: onNavigate)
        else if (page == 'Requests')
          RequestView(
              state: state, status: 'all', focusSubmissionId: submissionFocusId)
        else if (page == 'Approved')
          RequestView(state: state, status: 'approved')
        else if (page == 'Returned')
          RequestView(state: state, status: 'rejected')
        else if (page == 'Students')
          StudentView(state: state)
      ]);
}

Widget heading(String eyebrow, String title, String subtitle) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(eyebrow.toUpperCase(),
          style: const TextStyle(
              color: green,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5)),
      const SizedBox(height: 7),
      Text(title,
          style: const TextStyle(
              fontSize: 30, fontWeight: FontWeight.w800, color: ink)),
      const SizedBox(height: 7),
      Text(subtitle,
          style: const TextStyle(color: Colors.black54, fontSize: 14))
    ]));
Widget panel(Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    margin: const EdgeInsets.only(bottom: 14),
    decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE6E8E1))),
    child: child);
Widget primaryButton(String text, VoidCallback onPressed, {Key? key}) =>
    FilledButton(
        key: key,
        onPressed: onPressed,
        style: FilledButton.styleFrom(
            backgroundColor: green,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
        child: Text(text));
Widget statusChip(String status) {
  final color = switch (status) {
    'approved' => green,
    'needs-action' => Colors.deepOrange,
    'rejected' => Colors.red,
    'pending' => Colors.orange.shade800,
    _ => Colors.blueGrey
  };
  final label = switch (status) {
    'approved' => 'Approved',
    'needs-action' => 'Needs action',
    'rejected' => 'Returned',
    _ => 'Pending review'
  };
  return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
          color: color.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(30)),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w700)));
}

class DashboardView extends StatelessWidget {
  final ClearTrackState state;
  final ValueChanged<String> onNavigate;
  final ValueChanged<Department> onOpenDepartment;
  const DashboardView(
      {super.key,
      required this.state,
      required this.onNavigate,
      required this.onOpenDepartment});
  @override
  Widget build(BuildContext context) {
    final s = state;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
          width: double.infinity,
          padding: const EdgeInsets.all(26),
          margin: const EdgeInsets.only(bottom: 22),
          decoration: BoxDecoration(
              color: const Color(0xFFE8F0E6),
              borderRadius: BorderRadius.circular(24)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('STUDENT CLEARANCE PORTAL',
                style: TextStyle(
                    color: green,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.4,
                    fontSize: 11)),
            const SizedBox(height: 12),
            const Text('Your path to clearance,\\nmade simple.',
                style: TextStyle(
                    fontSize: 30, fontWeight: FontWeight.w800, color: ink)),
            const SizedBox(height: 10),
            const Text(
                'Track approvals from every campus office in one place. See what is complete, under review, and needs your attention.'),
            const SizedBox(height: 18),
            primaryButton(
                'View my clearance →', () => onNavigate('My clearance')),
          ])),
      heading('Your progress', 'Clearance overview',
          'Your latest clearance status across campus offices.'),
      Wrap(spacing: 12, runSpacing: 12, children: [
        stat('Approved', s.approved.toString(), Icons.check_circle, green),
        stat('In review', s.pending.toString(), Icons.schedule, Colors.orange),
        stat('Needs attention', s.needsAction.toString(), Icons.priority_high,
            Colors.red),
        stat('Complete', '${s.progress}%', Icons.trending_up, Colors.blue)
      ]),
      const SizedBox(height: 20),
      panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Department status',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        for (final r in s.records.take(5))
          ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(s.dept(r.departmentId)?.name ?? 'Department'),
              subtitle: Text(
                  r.note.isEmpty ? 'Last updated: ${r.updatedAt}' : r.note),
              trailing: statusChip(r.status))
      ])),
      const SizedBox(height: 18),
      DepartmentSearch(state: s, onOpenDepartment: onOpenDepartment),
    ]);
  }
}

class DepartmentSearch extends StatefulWidget {
  final ClearTrackState state;
  final ValueChanged<Department> onOpenDepartment;

  const DepartmentSearch(
      {super.key, required this.state, required this.onOpenDepartment});

  @override
  State<DepartmentSearch> createState() => _DepartmentSearchState();
}

class _DepartmentSearchState extends State<DepartmentSearch> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final departments = widget.state.departments.where((department) {
      final searchable = [
        department.name,
        department.short,
        department.office,
        department.description,
        ...department.requirements
      ].join(' ').toLowerCase();
      return searchable.contains(query);
    }).toList();

    return panel(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Search departments',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text(
            'Search department records saved in this ClearTrack project.'),
        const SizedBox(height: 12),
        TextField(
            decoration: const InputDecoration(
                labelText: 'Department, office, or requirement',
                prefixIcon: Icon(Icons.search)),
            onChanged: (value) => setState(() {
                  _query = value;
                })),
        const SizedBox(height: 8),
        if (departments.isEmpty)
          const Text('No departments match that search.'),
        if (departments.isNotEmpty)
          LayoutBuilder(builder: (context, constraints) {
            final width = constraints.maxWidth;
            final cardWidth = width >= 1000
                ? (width - 24) / 3
                : width >= 620
                    ? (width - 12) / 2
                    : width;
            return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: departments
                    .map((department) => SizedBox(
                        width: cardWidth,
                        child: Card(
                            margin: EdgeInsets.zero,
                            color: Colors.white,
                            child: InkWell(
                                onTap: () =>
                                    widget.onOpenDepartment(department),
                                borderRadius: BorderRadius.circular(14),
                                child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                const Icon(Icons.apartment,
                                                    color: green),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                    child: Text(department.name,
                                                        style: const TextStyle(
                                                            fontSize: 16,
                                                            fontWeight:
                                                                FontWeight
                                                                    .bold))),
                                                const Icon(Icons.arrow_forward,
                                                    color: green, size: 20)
                                              ]),
                                          if (department.office.isNotEmpty) ...[
                                            const SizedBox(height: 8),
                                            Text(department.office,
                                                style: const TextStyle(
                                                    color: Colors.black54))
                                          ],
                                          if (department
                                              .description.isNotEmpty) ...[
                                            const SizedBox(height: 8),
                                            Text(department.description)
                                          ],
                                          if (department
                                              .requirements.isNotEmpty) ...[
                                            const SizedBox(height: 10),
                                            Wrap(
                                                spacing: 6,
                                                runSpacing: 6,
                                                children: department
                                                    .requirements
                                                    .map((requirement) => Chip(
                                                        label:
                                                            Text(requirement),
                                                        visualDensity:
                                                            VisualDensity
                                                                .compact))
                                                    .toList())
                                          ]
                                        ]))))))
                    .toList());
          })
      ],
    ));
  }
}

Widget stat(String label, String value, IconData icon, Color color) =>
    Container(
        width: 220,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFE6E8E1))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color),
          const SizedBox(height: 12),
          Text(label, style: const TextStyle(color: Colors.black54)),
          Text(value,
              style: const TextStyle(
                  fontSize: 28, fontWeight: FontWeight.w800, color: ink))
        ]));

class ClearanceView extends StatefulWidget {
  final ClearTrackState state;
  final int? focusDepartmentId;
  final ValueChanged<int> onOpenDepartment;
  final VoidCallback onClearFocus;
  const ClearanceView(
      {super.key,
      required this.state,
      required this.focusDepartmentId,
      required this.onOpenDepartment,
      required this.onClearFocus});
  @override
  State<ClearanceView> createState() => _ClearanceViewState();
}

class _ClearanceViewState extends State<ClearanceView> {
  late DraftTextController _searchDraft;
  String filter = 'all';
  bool _filterEdited = false;

  String get _filterDraftId => 'clearance-filter:${widget.state.user?.id}';

  @override
  void initState() {
    super.initState();
    final userId = widget.state.user?.id ?? 'guest';
    _searchDraft = DraftTextController('clearance-search:$userId');
    unawaited(_searchDraft.restore(onRestored: () {
      if (mounted) setState(() {});
    }));
    _restoreFilter();
  }

  Future<void> _restoreFilter() async {
    final saved = await FormDrafts.load(_filterDraftId);
    if (!mounted) return;
    if (!_filterEdited) filter = saved['filter'] as String? ?? 'all';
    if (_filterEdited) _saveFilter();
    setState(() {});
  }

  void _saveFilter() => FormDrafts.save(_filterDraftId, {'filter': filter});

  @override
  void dispose() {
    _searchDraft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final search = _searchDraft.controller.text;
    final rows = s.records.where((r) {
      final d = s.dept(r.departmentId);
      return (d?.name.toLowerCase().contains(search.toLowerCase()) ?? false) &&
          (filter == 'all' || r.status == filter);
    }).toList();
    final focusedRecord = widget.focusDepartmentId == null
        ? null
        : s.record(widget.focusDepartmentId!);
    if (focusedRecord != null) {
      return _focusedClearanceView(s, focusedRecord);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      heading('Student workspace', 'My clearance',
          'Follow each department review and attach required documents before submitting.'),
      panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('${s.approved} / ${s.records.length} approved',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const Spacer(),
          Text('${s.progress}% complete',
              style: const TextStyle(color: green, fontWeight: FontWeight.bold))
        ]),
        const SizedBox(height: 12),
        LinearProgressIndicator(
            value: s.progress / 100,
            minHeight: 8,
            backgroundColor: const Color(0xFFE7E9E3),
            color: green,
            borderRadius: BorderRadius.circular(8))
      ])),
      TextField(
          controller: _searchDraft.controller,
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search), hintText: 'Search departments…'),
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(
          key: ValueKey(filter),
          initialValue: filter,
          decoration: const InputDecoration(labelText: 'Filter status'),
          items: const [
            DropdownMenuItem(value: 'all', child: Text('All statuses')),
            DropdownMenuItem(value: 'approved', child: Text('Approved')),
            DropdownMenuItem(value: 'pending', child: Text('Pending review')),
            DropdownMenuItem(
                value: 'needs-action', child: Text('Needs action')),
            DropdownMenuItem(value: 'rejected', child: Text('Returned'))
          ],
          onChanged: (v) => setState(() {
                filter = v ?? 'all';
                _filterEdited = true;
                _saveFilter();
              })),
      const SizedBox(height: 12),
      for (final r in rows)
        panel(Material(
            type: MaterialType.transparency,
            child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => widget.onOpenDepartment(r.departmentId),
                child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      CircleAvatar(
                          backgroundColor: const Color(0xFFE8F0E6),
                          child: Text(s.dept(r.departmentId)?.icon ?? '✓',
                              style: const TextStyle(color: green))),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(s.dept(r.departmentId)?.name ?? 'Department',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 17)),
                            Text(r.note.isEmpty
                                ? 'Updated ${r.updatedAt}'
                                : r.note)
                          ])),
                      const SizedBox(width: 8),
                      statusChip(r.status),
                      const Icon(Icons.chevron_right, color: green)
                    ])))))
    ]);
  }

  Widget _focusedClearanceView(ClearTrackState state, ClearanceRecord record) {
    final department = state.dept(record.departmentId);
    final submissions = state.submissions
        .where((submission) =>
            submission.departmentId == record.departmentId &&
            submission.studentId == (state.user?.id ?? '2026001'))
        .toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextButton.icon(
          onPressed: widget.onClearFocus,
          icon: const Icon(Icons.arrow_back),
          label: const Text('All clearance')),
      heading('My clearance', department?.name ?? 'Department',
          'Check this department’s status and manage your submission.'),
      panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
              child: Text('Current status',
                  style: TextStyle(fontWeight: FontWeight.bold))),
          statusChip(record.status)
        ]),
        const SizedBox(height: 8),
        Text(record.note.isEmpty
            ? 'Last updated: ${record.updatedAt}'
            : record.note),
        const SizedBox(height: 8),
        const Text(
            'For office details and the requirements checklist, open this department from the Departments section.')
      ])),
      for (final submission in submissions)
        panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              submission.fileName.isEmpty
                  ? 'Submitted note'
                  : submission.fileName,
              style: const TextStyle(fontWeight: FontWeight.bold)),
          if (submission.details.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(submission.details)
          ],
          const SizedBox(height: 6),
          Wrap(spacing: 4, children: [
            if (submission.fileName.isNotEmpty)
              TextButton.icon(
                  onPressed: () => showSubmittedFile(context, submission),
                  icon: const Icon(Icons.visibility_outlined),
                  label: const Text('View file')),
            TextButton.icon(
                onPressed: () => showStudentSubmissionDialog(
                    context, state, record,
                    existing: submission),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit submission')),
            if (submission.fileName.isNotEmpty)
              TextButton.icon(
                  onPressed: () => _removeFile(context, submission),
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  label: const Text('Remove file',
                      style: TextStyle(color: Colors.red)))
          ])
        ])),
      Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
              onPressed: () => _submit(context, record),
              icon: const Icon(Icons.attach_file),
              label: const Text('Submit requirements')))
    ]);
  }

  Future<void> _submit(BuildContext context, ClearanceRecord r) async {
    await showStudentSubmissionDialog(context, widget.state, r);
  }

  Future<void> _removeFile(BuildContext context, Submission submission) async {
    final onlyFile = submission.details.trim().isEmpty;
    final message = onlyFile
        ? 'This submission has no note. Removing its file will delete the submission and return the requirement for resubmission. Continue?'
        : 'Remove ${submission.fileName}? The note will remain and be sent for department review.';
    if (!await confirm(context, message)) return;
    await widget.state.removeSubmissionAttachment(submission);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(onlyFile
              ? 'Submission removed. You can submit the requirement again.'
              : 'File removed. Your note was kept.')));
    }
  }
}

Future<void> showStudentSubmissionDialog(
    BuildContext context, ClearTrackState state, ClearanceRecord r,
    {Submission? existing}) async {
  final draftId = 'submission:${state.user?.id ?? 'guest'}:${r.departmentId}';
  final saved = await FormDrafts.load(draftId);
  if (!context.mounted) return;
  final details = TextEditingController(
      text: saved['details'] as String? ?? existing?.details ?? '');
  details
      .addListener(() => FormDrafts.save(draftId, {'details': details.text}));
  PlatformFile? file;
  await showDialog(
      context: context,
      builder: (ctx) => _DialogControllers(
          controllers: [details],
          child: StatefulBuilder(
              builder: (ctx, setD) => AlertDialog(
                      title: Text(existing == null
                          ? 'Submit to ${state.dept(r.departmentId)?.name}'
                          : 'Edit submission'),
                      content: SingleChildScrollView(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                        TextField(
                            controller: details,
                            maxLines: 3,
                            decoration: const InputDecoration(
                                labelText: 'Note / details')),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                            onPressed: () async {
                              final res = await FilePicker.platform
                                  .pickFiles(withData: true);
                              if (res != null) {
                                setD(() => file = res.files.single);
                              }
                            },
                            icon: const Icon(Icons.attach_file),
                            label: Text(file?.name ??
                                existing?.fileName ??
                                'Attach PDF or file'))
                      ])),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Cancel')),
                        FilledButton(
                            onPressed: () async {
                              try {
                                if (existing == null) {
                                  await state.submit(
                                      r.departmentId, details.text, file);
                                } else {
                                  await state.editSubmission(
                                      existing, details.text, file);
                                }
                                details.clear();
                                await FormDrafts.clear(draftId);
                                if (ctx.mounted) Navigator.pop(ctx);
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text(existing == null
                                              ? 'Submission saved.'
                                              : 'Submission updated.')));
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text(e
                                              .toString()
                                              .replaceFirst(
                                                  'Exception: ', ''))));
                                }
                              }
                            },
                            child: Text(
                                existing == null ? 'Submit' : 'Save changes'))
                      ]))));
}

Future<void> showSubmittedFile(
    BuildContext context, Submission submission) async {
  if (submission.fileData.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('This submission has no readable file data.')));
    return;
  }
  final bytes = base64Decode(submission.fileData);
  final name = submission.fileName.toLowerCase();
  final Widget preview;
  if (name.endsWith('.png') ||
      name.endsWith('.jpg') ||
      name.endsWith('.jpeg') ||
      name.endsWith('.gif') ||
      name.endsWith('.webp')) {
    preview = InteractiveViewer(child: Image.memory(bytes));
  } else if (name.endsWith('.txt') ||
      name.endsWith('.csv') ||
      name.endsWith('.md') ||
      name.endsWith('.json')) {
    preview = SingleChildScrollView(
        child: SelectableText(utf8.decode(bytes, allowMalformed: true)));
  } else {
    preview = Text('Preview is not available for ${submission.fileName}.');
  }
  await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
            title: Text(submission.fileName),
            content: SizedBox(width: 560, height: 420, child: preview),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close'))
            ],
          ));
}

class LibraryView extends StatefulWidget {
  const LibraryView({super.key});

  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView> {
  final TextEditingController _searchController = TextEditingController();
  List<LibraryBook> _books = [];
  bool _loading = false;
  String? _error;
  bool _searched = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _searchBooks() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _searched = true;
    });
    try {
      final books = await fetchLibraryBooks(_searchController.text);
      if (!mounted) return;
      setState(() => _books = books);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _books = [];
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading('Book discovery', 'Library search',
              'Search a public catalog for books by title, author, or keyword.'),
          panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Search books',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('Results are provided by the Open Library Search API.'),
            const SizedBox(height: 12),
            LayoutBuilder(builder: (context, constraints) {
              final field = TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _searchBooks(),
                decoration: const InputDecoration(
                    labelText: 'Book title, author, or keyword',
                    hintText: 'e.g. Philippine history',
                    prefixIcon: Icon(Icons.search)),
              );
              final button = FilledButton.icon(
                  onPressed: _loading ? null : _searchBooks,
                  icon: _loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search),
                  label: Text(_loading ? 'Searching…' : 'Search books'));
              if (constraints.maxWidth < 540) {
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [field, const SizedBox(height: 8), button]);
              }
              return Row(children: [
                Expanded(child: field),
                const SizedBox(width: 10),
                button
              ]);
            }),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red))
            ]
          ])),
          const SizedBox(height: 16),
          if (!_searched)
            panel(const Text('Enter a search term to find books.'))
          else if (!_loading && _error == null && _books.isEmpty)
            panel(const Text('No books found. Try another title or author.'))
          else if (_books.isNotEmpty) ...[
            Text('${_books.length} book results',
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            LayoutBuilder(builder: (context, constraints) {
              final width = constraints.maxWidth;
              final cardWidth = width >= 1000
                  ? (width - 24) / 3
                  : width >= 620
                      ? (width - 12) / 2
                      : width;
              return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: _books
                      .map((book) =>
                          SizedBox(width: cardWidth, child: _bookCard(book)))
                      .toList());
            })
          ]
        ],
      );

  Widget _bookCard(LibraryBook book) => Card(
        margin: EdgeInsets.zero,
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                    width: 64,
                    height: 92,
                    child: book.coverId == null
                        ? Container(
                            color: const Color(0xFFE8F0E6),
                            child: const Icon(Icons.menu_book,
                                color: green, size: 34))
                        : Image.network(
                            'https://covers.openlibrary.org/b/id/${book.coverId}-M.jpg',
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                                color: const Color(0xFFE8F0E6),
                                child: const Icon(Icons.menu_book,
                                    color: green, size: 34)),
                          ))),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(book.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Text(
                      book.authors.isEmpty
                          ? 'Author not listed'
                          : book.authors.join(', '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  if (book.firstPublishYear != null) ...[
                    const SizedBox(height: 4),
                    Text('First published ${book.firstPublishYear}',
                        style: const TextStyle(
                            color: Colors.black54, fontSize: 12))
                  ]
                ]))
          ]),
        ),
      );
}

class DepartmentView extends StatefulWidget {
  final ClearTrackState state;
  final bool admin;
  final ValueChanged<Department> onOpenDepartment;
  final int? focusDepartmentId;
  final VoidCallback onClearFocus;
  const DepartmentView(
      {super.key,
      required this.state,
      required this.admin,
      required this.onOpenDepartment,
      required this.focusDepartmentId,
      required this.onClearFocus});
  @override
  State<DepartmentView> createState() => _DepartmentViewState();
}

class _DepartmentViewState extends State<DepartmentView> {
  late DraftTextController _searchDraft;

  @override
  void initState() {
    super.initState();
    _searchDraft = DraftTextController(
        'department-search:${widget.state.user?.id ?? 'guest'}');
    unawaited(_searchDraft.restore(onRestored: () {
      if (mounted) setState(() {});
    }));
  }

  @override
  void dispose() {
    _searchDraft.dispose();
    super.dispose();
  }

  Future<void> reopenAddDraft() => _edit(context);

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final search = _searchDraft.controller.text;
    final ds = s.departments
        .where((d) => ('${d.name} ${d.description}')
            .toLowerCase()
            .contains(search.toLowerCase()))
        .toList();
    final focused = widget.focusDepartmentId == null
        ? null
        : s.dept(widget.focusDepartmentId!);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (focused != null && !widget.admin) ...[
        TextButton.icon(
            onPressed: widget.onClearFocus,
            icon: const Icon(Icons.arrow_back),
            label: const Text('All departments')),
        heading('Campus directory', focused.name,
            'Department details and clearance requirements.'),
        _focusedDepartmentCard(focused)
      ] else ...[
        heading(
            widget.admin ? 'Directory management' : 'Campus directory',
            widget.admin ? 'Manage departments' : 'Departments',
            widget.admin
                ? 'Create, update, and remove clearance offices.'
                : 'Know where to go and what to prepare before requesting clearance.'),
        TextField(
            controller: _searchDraft.controller,
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search departments…'),
            onChanged: (_) => setState(() {})),
        const SizedBox(height: 14),
        if (widget.admin)
          Align(
              alignment: Alignment.centerRight,
              child: primaryButton('＋ Add department', () => _edit(context),
                  key: const ValueKey('add-department'))),
        for (final d in ds)
          widget.admin ? _departmentAdminCard(d, s) : _departmentStudentCard(d),
      ],
    ]);
  }

  Widget _focusedDepartmentCard(Department department) {
    return panel(
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        CircleAvatar(
            backgroundColor: const Color(0xFFE8F0E6),
            child: Text(department.icon, style: const TextStyle(color: green))),
        const SizedBox(width: 12),
        Text(department.short,
            style: const TextStyle(color: green, fontWeight: FontWeight.bold))
      ]),
      const SizedBox(height: 12),
      Text(department.description),
      const SizedBox(height: 16),
      const Text('What to prepare',
          style: TextStyle(fontWeight: FontWeight.bold)),
      for (final requirement in department.requirements)
        Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.checklist, size: 18, color: green),
              const SizedBox(width: 8),
              Expanded(child: Text(requirement))
            ])),
      const SizedBox(height: 16),
      Text('Contact: ${department.office}',
          style: const TextStyle(color: Colors.black54)),
    ]));
  }

  Widget _departmentStudentCard(Department department) => panel(Material(
      type: MaterialType.transparency,
      child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => widget.onOpenDepartment(department),
          child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                CircleAvatar(
                    backgroundColor: const Color(0xFFE8F0E6),
                    child: Text(department.icon,
                        style: const TextStyle(color: green))),
                const SizedBox(width: 12),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(department.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 18)),
                      Text('${department.short} · ${department.office}')
                    ])),
                const Icon(Icons.chevron_right, color: green)
              ])))));
  Widget _departmentAdminCard(Department d, ClearTrackState s) =>
      panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(
              backgroundColor: const Color(0xFFE8F0E6),
              child: Text(d.icon, style: const TextStyle(color: green))),
          const SizedBox(width: 12),
          Expanded(
              child: Text(d.name,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 18))),
          Text(d.short,
              style: const TextStyle(color: green, fontWeight: FontWeight.bold))
        ]),
        const SizedBox(height: 8),
        Text(d.description),
        const SizedBox(height: 12),
        const Text('Common requirements',
            style: TextStyle(fontWeight: FontWeight.bold)),
        for (final req in d.requirements) Text('• $req'),
        const SizedBox(height: 8),
        Text('Contact: ${d.office}',
            style: const TextStyle(color: Colors.black54)),
        if (widget.admin)
          Wrap(spacing: 8, children: [
            TextButton(
                onPressed: () => _edit(context, d), child: const Text('Edit')),
            TextButton(
                onPressed: () async {
                  if (await confirm(context, 'Delete ${d.name}?')) {
                    s.deleteDepartment(d);
                  }
                },
                child:
                    const Text('Delete', style: TextStyle(color: Colors.red)))
          ])
      ]));

  Future<void> _edit(BuildContext context, [Department? d]) async {
    final draftId =
        'department:${widget.state.user?.id ?? 'guest'}:${d?.id ?? 'new'}';
    final saved = await FormDrafts.load(draftId);
    if (!context.mounted) return;
    final name = TextEditingController(
            text: saved['name'] as String? ?? d?.name ?? ''),
        short = TextEditingController(
            text: saved['short'] as String? ?? d?.short ?? ''),
        desc = TextEditingController(
            text: saved['description'] as String? ?? d?.description ?? ''),
        office = TextEditingController(
            text: saved['office'] as String? ?? d?.office ?? ''),
        req = TextEditingController(
            text: saved['requirements'] as String? ??
                d?.requirements.join(', ') ??
                '');
    void saveDraft() {
      FormDrafts.save(draftId, {
        'name': name.text,
        'short': short.text,
        'description': desc.text,
        'office': office.text,
        'requirements': req.text
      });
    }

    for (final c in [name, short, desc, office, req]) {
      c.addListener(saveDraft);
    }
    await showDialog(
        context: context,
        builder: (ctx) => _DialogControllers(
            controllers: [name, short, desc, office, req],
            child: AlertDialog(
                title: Text(d == null ? 'Add department' : 'Edit department'),
                content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                      controller: name,
                      decoration:
                          const InputDecoration(labelText: 'Department name')),
                  TextField(
                      controller: short,
                      decoration:
                          const InputDecoration(labelText: 'Short code')),
                  TextField(
                      controller: desc,
                      decoration:
                          const InputDecoration(labelText: 'Description')),
                  TextField(
                      controller: office,
                      decoration:
                          const InputDecoration(labelText: 'Office contact')),
                  TextField(
                      controller: req,
                      decoration: const InputDecoration(
                          labelText: 'Requirements (comma separated)'))
                ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () async {
                        if (name.text.trim().isEmpty ||
                            desc.text.trim().isEmpty ||
                            office.text.trim().isEmpty) {
                          return;
                        }
                        await widget.state.saveDepartment(
                            Department(
                                d?.id ?? 0,
                                name.text.trim(),
                                short.text.trim(),
                                d?.icon ?? '✓',
                                desc.text.trim(),
                                office.text.trim(),
                                req.text
                                    .split(',')
                                    .map((e) => e.trim())
                                    .where((e) => e.isNotEmpty)
                                    .toList()),
                            editingId: d?.id);
                        await FormDrafts.clear(draftId);
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('Save'))
                ])));
  }
}

Future<bool> confirm(BuildContext context, String text) async =>
    await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(content: Text(text), actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Confirm'))
            ])) ??
    false;

class ActivityView extends StatelessWidget {
  final ClearTrackState state;
  final ValueChanged<Map<String, String>> onOpenActivity;
  const ActivityView(
      {super.key, required this.state, required this.onOpenActivity});
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        heading('Your timeline', 'Recent activity',
            'A record of clearance submissions and status updates on this device.'),
        for (final a in state.activities)
          panel(ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const CircleAvatar(
                  backgroundColor: Color(0xFFE8F0E6),
                  child: Icon(Icons.check, color: green)),
              title: Text(a['action'] ?? ''),
              subtitle: Text(a['detail'] ?? ''),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(a['date'] ?? '', style: const TextStyle(fontSize: 11)),
                if (a['submissionId'] != null)
                  const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(Icons.chevron_right))
              ]),
              onTap:
                  a['submissionId'] == null ? null : () => onOpenActivity(a)))
      ]);
}

class ProfileView extends StatefulWidget {
  final ClearTrackState state;
  const ProfileView({super.key, required this.state});
  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView> {
  late TextEditingController name, email, course, year;
  bool _restored = false;
  String get _draftId => 'profile:${widget.state.user?.id ?? 'guest'}';
  @override
  void initState() {
    super.initState();
    final u = widget.state.user!;
    name = TextEditingController(text: u.name);
    email = TextEditingController(text: u.email);
    course = TextEditingController(text: u.course);
    year = TextEditingController(text: u.year);
    _restoreDraft();
  }

  Future<void> _restoreDraft() async {
    final draft = await FormDrafts.load(_draftId);
    if (!mounted) return;
    name.text = draft['name'] as String? ?? name.text;
    email.text = draft['email'] as String? ?? email.text;
    course.text = draft['course'] as String? ?? course.text;
    year.text = draft['year'] as String? ?? year.text;
    void save() {
      FormDrafts.save(_draftId, {
        'name': name.text,
        'email': email.text,
        'course': course.text,
        'year': year.text
      });
    }

    for (final c in [name, email, course, year]) {
      c.addListener(save);
    }
    setState(() => _restored = true);
  }

  @override
  void dispose() {
    name.dispose();
    email.dispose();
    course.dispose();
    year.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      heading('Account settings', 'My profile',
          'Manage your student account and preferences.'),
      panel(Column(children: [
        CircleAvatar(
            radius: 30,
            backgroundColor: const Color(0xFFE8F0E6),
            child: Text(
                name.text.isEmpty
                    ? 'ST'
                    : name.text.split(' ').map((x) => x[0]).take(2).join(),
                style: const TextStyle(
                    color: green, fontWeight: FontWeight.bold))),
        const SizedBox(height: 14),
        Text(s.user!.role == 'admin' ? 'Administrator' : 'Student account'),
        Text('ID: ${s.user!.id}'),
        const SizedBox(height: 14),
        TextField(
            controller: name,
            enabled: _restored,
            decoration: const InputDecoration(labelText: 'Full name')),
        const SizedBox(height: 10),
        TextField(
            controller: email,
            enabled: _restored,
            decoration: const InputDecoration(labelText: 'Email address')),
        const SizedBox(height: 10),
        TextField(
            controller: course,
            enabled: _restored,
            decoration: const InputDecoration(labelText: 'Course / Program')),
        const SizedBox(height: 10),
        TextField(
            controller: year,
            enabled: _restored,
            decoration: const InputDecoration(labelText: 'Year level')),
        const SizedBox(height: 14),
        primaryButton('Save changes', () async {
          final u = s.user!;
          u.name = name.text;
          u.email = email.text;
          u.course = course.text;
          u.year = year.text;
          await s._save();
          await FormDrafts.clear(_draftId);
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Profile saved.')));
          }
        }),
        const Divider(height: 32),
        const Align(
            alignment: Alignment.centerLeft,
            child: Text('Demo data',
                style: TextStyle(fontWeight: FontWeight.bold))),
        const Align(
            alignment: Alignment.centerLeft,
            child:
                Text('Reset sample clearance records and activity history.')),
        Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
                onPressed: () async {
                  if (await confirm(context,
                      'Reset sample clearance records and activity?')) {
                    await s.reset();
                  }
                },
                child: const Text('Reset demo data')))
      ]))
    ]);
  }
}

class AdminDashboard extends StatelessWidget {
  final ClearTrackState state;
  final ValueChanged<String> onNavigate;
  const AdminDashboard(
      {super.key, required this.state, required this.onNavigate});
  @override
  Widget build(BuildContext context) {
    final s = state;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      heading('Administration', 'Portal overview',
          'Monitor student clearance activity and manage office reviews.'),
      Wrap(spacing: 12, runSpacing: 12, children: [
        stat(
            'Registered students',
            s.accounts.where((a) => a.role == 'student').length.toString(),
            Icons.people,
            green),
        stat('Departments', s.departments.length.toString(), Icons.apartment,
            Colors.blue),
        stat(
            'Awaiting review',
            s.submissions.where((x) => x.status == 'pending').length.toString(),
            Icons.schedule,
            Colors.orange),
        stat('Approved checkpoints', s.approvedSubmissions.toString(),
            Icons.check_circle, green)
      ]),
      const SizedBox(height: 20),
      panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Latest requests',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        for (final sub
            in s.submissions.where((x) => x.status == 'pending').take(5))
          ListTile(
              title: Text(s.dept(sub.departmentId)?.name ?? 'Department'),
              subtitle: Text('${sub.studentName} · ${sub.details}'),
              trailing: statusChip(sub.status)),
        if (s.submissions.where((x) => x.status == 'pending').isEmpty)
          const Text('No pending submissions.'),
        Align(
            alignment: Alignment.centerRight,
            child: primaryButton(
                'Review requests →', () => onNavigate('Requests')))
      ]))
    ]);
  }
}

class RequestView extends StatefulWidget {
  final ClearTrackState state;
  final String status;
  final int? focusSubmissionId;
  const RequestView(
      {super.key,
      required this.state,
      required this.status,
      this.focusSubmissionId});
  @override
  State<RequestView> createState() => _RequestViewState();
}

class _RequestViewState extends State<RequestView> {
  late DraftTextController _searchDraft;

  @override
  void initState() {
    super.initState();
    _searchDraft = DraftTextController(
        'requests-search:${widget.state.user?.id ?? 'guest'}:${widget.status}');
    unawaited(_searchDraft.restore(onRestored: () {
      if (mounted) setState(() {});
    }));
  }

  @override
  void dispose() {
    _searchDraft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final search = _searchDraft.controller.text;
    final items = s.submissions
        .where((x) =>
            (widget.focusSubmissionId == null ||
                x.id == widget.focusSubmissionId) &&
            (widget.status == 'all' || x.status == widget.status) &&
            ('${s.dept(x.departmentId)?.name} ${x.details} ${x.fileName} ${x.studentName}')
                .toLowerCase()
                .contains(search.toLowerCase()))
        .toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      heading(
          'Review workspace',
          widget.status == 'all'
              ? 'Clearance requests'
              : widget.status == 'approved'
                  ? 'Approved requests'
                  : 'Returned requests',
          widget.status == 'all'
              ? 'Review student notes and attached documents, then update the department status.'
              : 'Reviewed requests are kept here, separate from the overview.'),
      TextField(
          controller: _searchDraft.controller,
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search student, department, note, or filename'),
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 12),
      if (items.isEmpty)
        panel(const Text(
            'No requests found. Student submissions will appear here when created.')),
      for (final sub in items)
        panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(
                    s.dept(sub.departmentId)?.name ?? 'Department removed',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 17))),
            statusChip(sub.status)
          ]),
          Text('${sub.studentName} (${sub.studentId}) · ${sub.date}'),
          const SizedBox(height: 6),
          Text(sub.details.isEmpty ? 'No note provided' : sub.details),
          if (sub.fileName.isNotEmpty)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  const Icon(Icons.attach_file),
                  Expanded(
                      child:
                          Text(sub.fileName, overflow: TextOverflow.ellipsis)),
                  IconButton(
                      tooltip: 'View submitted file',
                      onPressed: () => showSubmittedFile(context, sub),
                      icon: const Icon(Icons.visibility_outlined)),
                  Text('${(sub.fileData.length / 1024).round()} KB',
                      style: const TextStyle(color: Colors.black54))
                ])),
          if (widget.status == 'all' && sub.status == 'pending')
            Wrap(spacing: 8, children: [
              FilledButton(
                  onPressed: () => s.review(sub, 'approved'),
                  child: const Text('Approve')),
              OutlinedButton(
                  onPressed: () => s.review(sub, 'rejected'),
                  child: const Text('Return')),
              TextButton(
                  onPressed: () async {
                    if (await confirm(context,
                        'Delete this submission and its attachment?')) {
                      s.deleteSubmission(sub);
                    }
                  },
                  child:
                      const Text('Delete', style: TextStyle(color: Colors.red)))
            ])
        ]))
    ]);
  }
}

class StudentView extends StatefulWidget {
  final ClearTrackState state;
  const StudentView({super.key, required this.state});
  @override
  State<StudentView> createState() => _StudentViewState();
}

class _StudentViewState extends State<StudentView> {
  late DraftTextController _searchDraft;

  @override
  void initState() {
    super.initState();
    _searchDraft = DraftTextController(
        'students-search:${widget.state.user?.id ?? 'guest'}');
    unawaited(_searchDraft.restore(onRestored: () {
      if (mounted) setState(() {});
    }));
  }

  @override
  void dispose() {
    _searchDraft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final search = _searchDraft.controller.text;
    final students = s.accounts
        .where((a) =>
            a.role == 'student' &&
            ('${a.name} ${a.email} ${a.id} ${a.course}')
                .toLowerCase()
                .contains(search.toLowerCase()))
        .toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      heading('Student directory', 'Student accounts',
          'Search, create, edit, and remove student records.'),
      TextField(
          controller: _searchDraft.controller,
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search name, ID, or email'),
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 12),
      Align(
          alignment: Alignment.centerRight,
          child: primaryButton('＋ Add student', () => _edit(context),
              key: const ValueKey('add-student'))),
      for (final a in students)
        panel(ListTile(
            title: Text(a.name,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('${a.id} · ${a.email}\\n${a.course} ${a.year}'),
            isThreeLine: true,
            trailing: PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'edit') _edit(context, a);
                  if (v == 'delete') _delete(context, a);
                },
                itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(value: 'delete', child: Text('Delete'))
                    ])))
    ]);
  }

  Future<void> _edit(BuildContext context, [Account? a]) async {
    final s = widget.state;
    final draftId =
        'student:${widget.state.user?.id ?? 'guest'}:${a?.id ?? 'new'}';
    final saved = await FormDrafts.load(draftId);
    if (!context.mounted) return;
    final name = TextEditingController(
            text: saved['name'] as String? ?? a?.name ?? ''),
        id = TextEditingController(text: saved['id'] as String? ?? a?.id ?? ''),
        email = TextEditingController(
            text: saved['email'] as String? ?? a?.email ?? ''),
        course = TextEditingController(
            text: saved['course'] as String? ?? a?.course ?? ''),
        year = TextEditingController(
            text: saved['year'] as String? ?? a?.year ?? ''),
        password = TextEditingController();
    void saveDraft() {
      FormDrafts.save(draftId, {
        'name': name.text,
        'id': id.text,
        'email': email.text,
        'course': course.text,
        'year': year.text
      });
    }

    for (final c in [name, id, email, course, year]) {
      c.addListener(saveDraft);
    }
    await showDialog(
        context: context,
        builder: (ctx) => _DialogControllers(
            controllers: [name, id, email, course, year, password],
            child: AlertDialog(
                title: Text(
                    a == null ? 'Add student account' : 'Edit student account'),
                content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                      controller: name,
                      decoration:
                          const InputDecoration(labelText: 'Full name')),
                  TextField(
                      controller: id,
                      enabled: a == null,
                      decoration:
                          const InputDecoration(labelText: 'Student ID')),
                  TextField(
                      controller: email,
                      decoration: const InputDecoration(labelText: 'Email')),
                  TextField(
                      controller: course,
                      decoration:
                          const InputDecoration(labelText: 'Course / program')),
                  TextField(
                      controller: year,
                      decoration:
                          const InputDecoration(labelText: 'Year level')),
                  if (a == null)
                    TextField(
                        controller: password,
                        obscureText: true,
                        decoration: const InputDecoration(
                            labelText: 'Temporary password'))
                ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () async {
                        if (name.text.trim().isEmpty ||
                            id.text.trim().isEmpty ||
                            email.text.trim().isEmpty) {
                          return;
                        }
                        if (a == null) {
                          if (password.text.length < 6 ||
                              s.accounts.any((x) =>
                                  x.id == id.text ||
                                  x.email.toLowerCase() ==
                                      email.text.toLowerCase())) {
                            return;
                          }
                          s.accounts.add(Account(id.text, name.text, email.text,
                              password.text, 'student',
                              course: course.text, year: year.text));
                        } else {
                          a.name = name.text;
                          a.email = email.text;
                          a.course = course.text;
                          a.year = year.text;
                        }
                        await s._save();
                        await FormDrafts.clear(draftId);
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('Save'))
                ])));
  }

  Future<void> _delete(BuildContext context, Account a) async {
    if (await confirm(context, 'Delete student ${a.name}?')) {
      widget.state.accounts.remove(a);
      await widget.state._save();
    }
  }
}

class AuthView extends StatefulWidget {
  final ClearTrackState state;
  final VoidCallback onDone;
  final String initial;
  const AuthView(
      {super.key,
      required this.state,
      required this.onDone,
      required this.initial});
  @override
  State<AuthView> createState() => _AuthViewState();
}

class _AuthViewState extends State<AuthView> {
  bool register = false;
  String error = '';
  final name = TextEditingController(),
      id = TextEditingController(),
      email = TextEditingController(text: 'student@cleartrack.edu'),
      password = TextEditingController(text: 'student123');
  @override
  void initState() {
    super.initState();
    register = widget.initial == 'register';
  }

  @override
  void dispose() {
    name.dispose();
    id.dispose();
    email.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
      child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 470),
              child: panel(Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(
                        child: Text('CT  ClearTrack',
                            style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                                color: green))),
                    const SizedBox(height: 20),
                    Text(
                        register
                            ? 'Create your account'
                            : 'Sign in to ClearTrack',
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Text(register
                        ? 'Register with your student details to track clearance progress.'
                        : 'Access your clearance progress and department updates.'),
                    const SizedBox(height: 16),
                    if (register) ...[
                      TextField(
                          controller: name,
                          decoration:
                              const InputDecoration(labelText: 'Full name')),
                      const SizedBox(height: 10),
                      TextField(
                          controller: id,
                          decoration:
                              const InputDecoration(labelText: 'Student ID')),
                      const SizedBox(height: 10)
                    ],
                    TextField(
                        controller: email,
                        decoration:
                            const InputDecoration(labelText: 'Email address')),
                    const SizedBox(height: 10),
                    TextField(
                        controller: password,
                        obscureText: true,
                        decoration:
                            const InputDecoration(labelText: 'Password')),
                    if (error.isNotEmpty)
                      Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(error,
                              style: const TextStyle(color: Colors.red))),
                    const SizedBox(height: 14),
                    primaryButton(register ? 'Create account →' : 'Sign in →',
                        () {
                      setState(() => error = '');
                      if (register) {
                        final e = widget.state.register(name.text.trim(),
                            id.text.trim(), email.text.trim(), password.text);
                        if (e != null) {
                          setState(() => error = e);
                          return;
                        }
                      } else if (!widget.state
                          .login(email.text, password.text)) {
                        setState(() => error = 'Incorrect email or password.');
                        return;
                      }
                      widget.onDone();
                    }),
                    const SizedBox(height: 12),
                    TextButton(
                        onPressed: () => setState(() {
                              register = !register;
                              error = '';
                            }),
                        child: Text(register
                            ? 'Already registered? Sign in'
                            : 'New to ClearTrack? Create an account')),
                    const Divider(),
                    const Text(
                        'Demo student: student@cleartrack.edu / student123'),
                    const Text(
                        'Demo administrator: admin@cleartrack.edu / admin123',
                        style: TextStyle(fontSize: 12, color: Colors.black54))
                  ])))));
}
