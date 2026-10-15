import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cleartrack/main.dart';

Future<ClearTrackState> createState() async {
  SharedPreferences.setMockInitialValues({});
  final state = ClearTrackState();
  await state.load();
  return state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ClearTrack opens its sign-in screen', (tester) async {
    final state = await createState();
    await tester.pumpWidget(ClearTrackApp(state: state));
    await tester.pumpAndSettle();

    expect(find.text('Sign in to ClearTrack'), findsOneWidget);
    expect(find.text('student@cleartrack.edu'), findsOneWidget);
    expect(find.text('Sign in →'), findsOneWidget);
  });

  testWidgets('A student can sign in and navigate between sections',
      (tester) async {
    final state = await createState();
    await tester.pumpWidget(ClearTrackApp(state: state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sign in →'));
    await tester.pumpAndSettle();
    expect(find.text('Clearance overview'), findsOneWidget);

    await tester.tap(find.text('My clearance'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'Follow each department review and attach required documents before submitting.'),
        findsOneWidget);

    await tester.tap(find.text('Departments').last);
    await tester.pumpAndSettle();
    expect(
        find.text(
            'Know where to go and what to prepare before requesting clearance.'),
        findsOneWidget);

    final department = state.departments.first;
    await tester
        .tap(find.byKey(PageStorageKey('student-department-${department.id}')));
    await tester.pumpAndSettle();
    expect(find.text('What to prepare'), findsOneWidget);
    expect(find.text(department.requirements.first), findsOneWidget);
    final departmentAction =
        find.byKey(ValueKey('department-clearance-${department.id}'));
    await tester.ensureVisible(departmentAction);
    await tester.tap(departmentAction);
    await tester.pumpAndSettle();
    expect(find.text('Submit to ${department.name}'), findsOneWidget);
    expect(
        find.byWidgetPredicate((widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Note / details'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  test('Authentication, CRUD, review actions, deletion and reset work',
      () async {
    final state = await createState();
    expect(state.login('unknown@example.edu', 'wrong-password'), isFalse);
    expect(state.user, isNull);
    expect(state.register('New Student', 'STU9001', 'new@student.edu', '123'),
        'Password must be at least 6 characters.');
    expect(
        state.register(
            'New Student', '2026001', 'other@student.edu', 'secure1'),
        'Email or student ID is already registered.');

    expect(
        state.register('New Student', 'STU9001', 'new@student.edu', 'secure1'),
        isNull);
    expect(state.user?.id, 'STU9001');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final restored = ClearTrackState();
    await restored.load();
    expect(restored.user?.id, 'STU9001');

    final originalDepartmentCount = restored.departments.length;
    await restored.saveDepartment(Department(0, 'Testing Office', 'TST', 'T',
        'Temporary test office', 'Room 1', ['Bring the form']));
    expect(restored.departments, hasLength(originalDepartmentCount + 1));
    final department = restored.departments.last;
    final record = restored.record(department.id)!;
    expect(record.status, 'pending');

    await restored.saveDepartment(
        Department(department.id, 'Updated Testing Office', 'TST', 'T',
            'Updated description', 'Room 2', ['Bring ID']),
        editingId: department.id);
    expect(restored.dept(department.id)?.name, 'Updated Testing Office');
    expect(restored.departments, hasLength(originalDepartmentCount + 1));

    await restored.submit(department.id, 'Please review my form', null);
    final submission = restored.submissions.single;
    expect(restored.record(department.id)?.status, 'pending');
    await restored.review(submission, 'approved');
    expect(submission.status, 'approved');
    expect(restored.record(department.id)?.status, 'approved');
    await restored.review(submission, 'rejected');
    expect(submission.status, 'rejected');
    expect(restored.record(department.id)?.status, 'rejected');
    await restored.deleteSubmission(submission);
    expect(restored.submissions, isEmpty);

    await restored.setStatus(record, 'approved');
    expect(restored.approved, greaterThan(0));
    await restored.deleteDepartment(department);
    expect(restored.dept(department.id), isNull);
    expect(restored.record(department.id), isNull);

    await restored.submit(2, 'Finance documents attached.', null);
    final persisted = ClearTrackState();
    await persisted.load();
    expect(persisted.dept(2)?.name, 'Finance Office');
    expect(persisted.submissions.single.details, 'Finance documents attached.');
    expect(persisted.record(2)?.status, 'pending');

    await restored.reset();
    expect(restored.departments, hasLength(7));
    expect(restored.submissions, isEmpty);
    final afterReset = ClearTrackState();
    await afterReset.load();
    expect(afterReset.departments, hasLength(7));
    expect(afterReset.submissions, isEmpty);
    restored.logout();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final loggedOut = ClearTrackState();
    await loggedOut.load();
    expect(loggedOut.user, isNull);
  });

  testWidgets('Profile save persists for the signed-in account',
      (tester) async {
    final state = await createState();
    expect(state.login('student@cleartrack.edu', 'student123'), isTrue);
    await tester.pumpWidget(ClearTrackApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Profile').last);
    await tester.pumpAndSettle();

    final nameField = find.byWidgetPredicate((widget) =>
        widget is TextField && widget.decoration?.labelText == 'Full name');
    await tester.enterText(nameField, 'Updated Student Name');
    final saveButton = find.text('Save changes');
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
    expect(state.user?.name, 'Updated Student Name');

    final restored = ClearTrackState();
    await restored.load();
    expect(restored.user?.name, 'Updated Student Name');
  });

  test('Form drafts persist as JSON and can be cleared independently',
      () async {
    SharedPreferences.setMockInitialValues({});
    FormDrafts.save('test:one', {'note': 'unfinished form'});
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(await FormDrafts.load('test:one'), {'note': 'unfinished form'});
    expect(await FormDrafts.load('test:two'), isEmpty);

    await FormDrafts.clear('test:one');
    expect(await FormDrafts.load('test:one'), isEmpty);
  });

  test('Corrupt storage recovers per collection and removes duplicate records',
      () async {
    SharedPreferences.setMockInitialValues({
      'departments':
          '[{"id":20,"name":"Custom Office","short":"CUS","icon":"C","description":"Saved department","office":"Room 20","requirements":["Bring ID"]}]',
      'records':
          '[{"departmentId":1,"status":"approved"},{"departmentId":1,"status":"pending"}]',
      'submissions': '{invalid-json',
      'activities': '[]',
      'accounts': '[]'
    });

    final restored = ClearTrackState();
    await restored.load();
    expect(restored.departments, hasLength(1));
    expect(restored.dept(20)?.name, 'Custom Office');
    expect(restored.records, hasLength(1));
    expect(restored.record(1)?.status, 'pending');
    expect(restored.submissions, isEmpty);

    final afterRestart = ClearTrackState();
    await afterRestart.load();
    expect(afterRestart.dept(20)?.name, 'Custom Office');
    expect(afterRestart.records, hasLength(1));
    expect(afterRestart.record(1)?.status, 'pending');
  });

  test('Pending drafts flush on background and remain separated by account',
      () async {
    SharedPreferences.setMockInitialValues({});
    FormDrafts.save(
        'submission:student-1:department-1', {'details': 'Student'});
    FormDrafts.save('department:admin-1:new', {'name': 'Admin draft'});
    await FormDrafts.flushPending();

    expect(await FormDrafts.load('submission:student-1:department-1'),
        {'details': 'Student'});
    expect(await FormDrafts.load('department:admin-1:new'),
        {'name': 'Admin draft'});
    expect(await FormDrafts.load('submission:student-2:department-1'), isEmpty);
  });

  test('Failed submission keeps its draft; successful submission clears it',
      () async {
    final state = await createState();
    expect(state.login('student@cleartrack.edu', 'student123'), isTrue);
    final draftId = 'submission:${state.user!.id}:1';
    FormDrafts.save(draftId, {'details': 'Work in progress'});
    await FormDrafts.flushPending();

    try {
      await state.submit(1, '', null);
      fail('An empty submission should fail validation.');
    } catch (_) {
      // Expected: validation failure must leave the local draft intact.
    }
    expect(await FormDrafts.load(draftId), {'details': 'Work in progress'});
    expect(state.submissions, isEmpty);

    await state.submit(1, 'Completed note', null);
    await FormDrafts.clear(draftId);
    expect(state.submissions, hasLength(1));
    expect(await FormDrafts.load(draftId), isEmpty);
  });

  testWidgets('Student submission note restores after cancelling the dialog',
      (tester) async {
    final state = await createState();
    expect(state.login('student@cleartrack.edu', 'student123'), isTrue);
    await tester.pumpWidget(ClearTrackApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My clearance'));
    await tester.pumpAndSettle();

    final openButton = find.text('Submit / edit attachment').first;
    await tester.ensureVisible(openButton);
    await tester.tap(openButton);
    await tester.pumpAndSettle();
    final noteField = find.byWidgetPredicate((widget) =>
        widget is TextField &&
        widget.decoration?.labelText == 'Note / details');
    await tester.enterText(noteField, 'Draft note from student');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(openButton);
    await tester.tap(openButton);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(noteField).controller!.text,
        'Draft note from student');
    expect(state.submissions, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('Admin department draft restores without changing the directory',
      (tester) async {
    final state = await createState();
    final originalCount = state.departments.length;
    expect(state.login('admin@cleartrack.edu', 'admin123'), isTrue);
    await tester.pumpWidget(ClearTrackApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Departments').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('add-department')));
    await tester.pumpAndSettle();
    final nameField = find.byWidgetPredicate((widget) =>
        widget is TextField &&
        widget.decoration?.labelText == 'Department name');
    final shortCodeField = find.byWidgetPredicate((widget) =>
        widget is TextField && widget.decoration?.labelText == 'Short code');
    await tester.enterText(nameField, 'Temporary admin draft');
    await tester.enterText(shortCodeField, 'TMP');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('add-department')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(nameField).controller!.text,
        'Temporary admin draft');
    expect(tester.widget<TextField>(shortCodeField).controller!.text, 'TMP');
    expect(state.departments, hasLength(originalCount));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('Unsaved admin department form reopens after app restart',
      (tester) async {
    final state = await createState();
    final originalCount = state.departments.length;
    expect(state.login('admin@cleartrack.edu', 'admin123'), isTrue);
    await tester.pumpWidget(ClearTrackApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Departments').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-department')));
    await tester.pumpAndSettle();

    final nameField = find.byWidgetPredicate((widget) =>
        widget is TextField &&
        widget.decoration?.labelText == 'Department name');
    final shortCodeField = find.byWidgetPredicate((widget) =>
        widget is TextField && widget.decoration?.labelText == 'Short code');
    await tester.enterText(nameField, 'Unsaved after restart');
    await tester.enterText(shortCodeField, 'UAR');
    await tester.pump(const Duration(milliseconds: 450));
    await FormDrafts.flushPending();
    await tester.pumpWidget(const SizedBox.shrink());

    final restartedState = ClearTrackState();
    await restartedState.load();
    expect(restartedState.user?.role, 'admin');
    await tester.pumpWidget(ClearTrackApp(state: restartedState));
    await tester.pumpAndSettle();

    expect(find.text('Add department'), findsOneWidget);
    expect(tester.widget<TextField>(nameField).controller!.text,
        'Unsaved after restart');
    expect(tester.widget<TextField>(shortCodeField).controller!.text, 'UAR');
    expect(restartedState.departments, hasLength(originalCount));
  });

  testWidgets('The active admin page restores after app restart',
      (tester) async {
    final state = await createState();
    expect(state.login('admin@cleartrack.edu', 'admin123'), isTrue);
    await tester.pumpWidget(ClearTrackApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Navigate'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Students').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpWidget(const SizedBox.shrink());

    final restartedState = ClearTrackState();
    await restartedState.load();
    await tester.pumpWidget(ClearTrackApp(state: restartedState));
    await tester.pumpAndSettle();

    expect(find.text('Student accounts'), findsOneWidget);
  });

  testWidgets('Admin can add, edit and delete a student account',
      (tester) async {
    final state = await createState();
    expect(state.login('admin@cleartrack.edu', 'admin123'), isTrue);
    await tester.pumpWidget(ClearTrackApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Navigate'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Students').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-student')));
    await tester.pumpAndSettle();

    Future<void> enterField(String label, String value) async {
      final field = find.byWidgetPredicate((widget) =>
          widget is TextField && widget.decoration?.labelText == label);
      await tester.enterText(field, value);
    }

    await enterField('Full name', 'New Learner');
    await enterField('Student ID', 'STU7001');
    await enterField('Email', 'learner@example.edu');
    await enterField('Course / program', 'Information Technology');
    await enterField('Year level', '2nd Year');
    await enterField('Temporary password', 'tempPass7');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(state.accounts.any((account) => account.id == 'STU7001'), isTrue);

    Future<Finder> studentActions(String name) async {
      final row =
          find.ancestor(of: find.text(name), matching: find.byType(ListTile));
      await tester.ensureVisible(row);
      return find.descendant(
          of: row, matching: find.byType(PopupMenuButton<String>));
    }

    var actions = await studentActions('New Learner');
    await tester.tap(actions);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await enterField('Full name', 'Updated Learner');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(state.accounts.firstWhere((account) => account.id == 'STU7001').name,
        'Updated Learner');

    actions = await studentActions('Updated Learner');
    await tester.tap(actions);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(state.accounts.any((account) => account.id == 'STU7001'), isFalse);
  });

  testWidgets('Admin can approve and delete a student request', (tester) async {
    final state = await createState();
    expect(state.login('student@cleartrack.edu', 'student123'), isTrue);
    await state.submit(1, 'Please approve my library clearance.', null);
    final submissionId = state.submissions.single.id;
    state.logout();
    expect(state.login('admin@cleartrack.edu', 'admin123'), isTrue);

    await tester.pumpWidget(ClearTrackApp(state: state));
    await tester.pumpAndSettle();
    expect(find.text('Approved checkpoints'), findsOneWidget);
    var approvedStat = find.ancestor(
        of: find.text('Approved checkpoints'),
        matching: find.byType(Container));
    expect(find.descendant(of: approvedStat.first, matching: find.text('0')),
        findsOneWidget);
    await tester.tap(find.byTooltip('Navigate'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Requests').last);
    await tester.pumpAndSettle();
    final approve = find.text('Approve').first;
    await tester.ensureVisible(approve);
    await tester.tap(approve);
    await tester.pumpAndSettle();
    expect(state.submissions.single.status, 'approved');
    expect(state.record(1)?.status, 'approved');
    expect(state.approvedSubmissions, 1);

    await tester.tap(find.byTooltip('Navigate'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Overview').last);
    await tester.pumpAndSettle();
    expect(find.text('Approved checkpoints'), findsOneWidget);
    approvedStat = find.ancestor(
        of: find.text('Approved checkpoints'),
        matching: find.byType(Container));
    expect(find.descendant(of: approvedStat.first, matching: find.text('1')),
        findsOneWidget);

    await tester.tap(find.byTooltip('Navigate'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Requests').last);
    await tester.pumpAndSettle();

    final delete = find.text('Delete').first;
    await tester.ensureVisible(delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(state.submissions.where((item) => item.id == submissionId), isEmpty);
  });
}
