import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/gdevelop_editor_instance_lease.dart';

void main() {
  late DateTime now;
  var tokenCounter = 0;
  late GDevelopEditorInstanceLeaseManager manager;

  setUp(() {
    now = DateTime.utc(2026, 8, 11, 8);
    manager = GDevelopEditorInstanceLeaseManager(
      clock: () => now,
      tokenFactory: () => 'lease_token_${++tokenCounter}'.padRight(24, '_'),
      ttl: const Duration(seconds: 30),
      heartbeatInterval: const Duration(seconds: 5),
    );
  });

  test('lease is global across different projects and host kinds', () {
    final app = manager.acquire(
      instanceId: 'app_instance_0001',
      pageId: 'app_page_00000001',
    );
    final browser = manager.acquire(
      instanceId: 'browser_instance_1',
      pageId: 'browser_page_00001',
    );

    expect(app.acquired, isTrue);
    expect(browser.acquired, isFalse);
    expect(browser.occupiedBy?.instanceId, 'app_instance_0001');
  });

  test('duplicate tab cannot reuse a copied instance and lease token', () {
    final first = manager.acquire(
      instanceId: 'browser_instance_1',
      pageId: 'browser_page_00001',
    );
    final duplicate = manager.acquire(
      instanceId: 'browser_instance_1',
      pageId: 'browser_page_00002',
      previousLeaseToken: first.lease!.leaseToken,
      resumeAfterReload: false,
    );

    expect(duplicate.acquired, isFalse);
  });

  test('reload recovers the same instance and invalidates the old page', () {
    final first = manager.acquire(
      instanceId: 'browser_instance_1',
      pageId: 'browser_page_00001',
    );
    final resumed = manager.acquire(
      instanceId: 'browser_instance_1',
      pageId: 'browser_page_00002',
      previousLeaseToken: first.lease!.leaseToken,
      resumeAfterReload: true,
    );

    expect(resumed.acquired, isTrue);
    expect(resumed.resumed, isTrue);
    expect(resumed.lease!.leaseToken, isNot(first.lease!.leaseToken));
    expect(
      manager.validates(
        instanceId: first.lease!.instanceId,
        pageId: first.lease!.pageId,
        leaseToken: first.lease!.leaseToken,
      ),
      isFalse,
    );
  });

  test('explicit release lets the other host acquire immediately', () {
    final first = manager
        .acquire(instanceId: 'browser_instance_1', pageId: 'browser_page_00001')
        .lease!;
    expect(
      manager.release(
        instanceId: first.instanceId,
        pageId: first.pageId,
        leaseToken: first.leaseToken,
      ),
      isTrue,
    );

    expect(
      manager
          .acquire(instanceId: 'app_instance_0001', pageId: 'app_page_00000001')
          .acquired,
      isTrue,
    );
  });

  test('heartbeat extends TTL and a crashed stale lease is reclaimed', () {
    final first = manager
        .acquire(instanceId: 'app_instance_0001', pageId: 'app_page_00000001')
        .lease!;
    now = now.add(const Duration(seconds: 20));
    expect(
      manager.heartbeat(
        instanceId: first.instanceId,
        pageId: first.pageId,
        leaseToken: first.leaseToken,
      ),
      isNotNull,
    );
    now = now.add(const Duration(seconds: 29));
    expect(manager.active, isNotNull);
    now = now.add(const Duration(seconds: 1));
    expect(manager.active, isNull);
    expect(
      manager
          .acquire(
            instanceId: 'browser_instance_1',
            pageId: 'browser_page_00001',
          )
          .acquired,
      isTrue,
    );
  });

  test('wrong or old lease credentials never release the current owner', () {
    final first = manager
        .acquire(instanceId: 'app_instance_0001', pageId: 'app_page_00000001')
        .lease!;

    expect(
      manager.release(
        instanceId: first.instanceId,
        pageId: first.pageId,
        leaseToken: 'wrong_lease_token_00000',
      ),
      isFalse,
    );
    expect(manager.active, same(first));
  });

  test('active request headers expose only the exact lease credentials', () {
    final lease = manager
        .acquire(instanceId: 'app_instance_0001', pageId: 'app_page_00000001')
        .lease!;

    expect(manager.activeRequestHeaders, {
      gdevelopEditorInstanceHeader: lease.instanceId,
      gdevelopEditorPageHeader: lease.pageId,
      gdevelopEditorLeaseHeader: lease.leaseToken,
    });
  });

  test('AI session binding is invalidated by refresh generation rotation', () {
    final beforeAcquire = manager.generation;
    final first = manager
        .acquire(instanceId: 'app_instance_0001', pageId: 'app_page_00000001')
        .lease!;
    final registeredGeneration = manager.generation;
    expect(registeredGeneration, greaterThan(beforeAcquire));
    expect(manager.bindAiSession('editor_session_000001'), isTrue);
    expect(manager.validatesAiSession('editor_session_000001'), isTrue);
    expect(manager.hasActiveAiSessionBinding, isTrue);

    now = now.add(const Duration(seconds: 1));
    expect(
      manager.heartbeat(
        instanceId: first.instanceId,
        pageId: first.pageId,
        leaseToken: first.leaseToken,
      ),
      isNotNull,
    );
    expect(
      manager.generation,
      registeredGeneration,
      reason:
          'A heartbeat renews TTL without changing the active page identity.',
    );

    manager.acquire(
      instanceId: first.instanceId,
      pageId: 'app_page_00000002',
      previousLeaseToken: first.leaseToken,
      resumeAfterReload: true,
    );

    expect(manager.generation, greaterThan(registeredGeneration));
    expect(manager.validatesAiSession('editor_session_000001'), isFalse);
    expect(manager.hasActiveAiSessionBinding, isFalse);
  });

  test('AI session binding is invalidated by release and TTL expiry', () {
    final first = manager
        .acquire(instanceId: 'app_instance_0001', pageId: 'app_page_00000001')
        .lease!;
    manager.bindAiSession('editor_session_000001');
    manager.release(
      instanceId: first.instanceId,
      pageId: first.pageId,
      leaseToken: first.leaseToken,
    );
    expect(manager.validatesAiSession('editor_session_000001'), isFalse);

    manager.acquire(
      instanceId: 'app_instance_0001',
      pageId: 'app_page_00000001',
    );
    manager.bindAiSession('editor_session_000002');
    now = now.add(const Duration(seconds: 30));
    expect(manager.validatesAiSession('editor_session_000002'), isFalse);
  });

  test('install barrier is atomic with editor lease acquisition', () {
    expect(manager.beginInstall(), isTrue);
    expect(manager.installationInProgress, isTrue);

    final blocked = manager.acquire(
      instanceId: 'app_instance_0001',
      pageId: 'app_page_00000001',
    );
    expect(blocked.acquired, isFalse);
    expect(blocked.installationInProgress, isTrue);
    expect(manager.beginInstall(), isFalse);

    manager.endInstall();
    expect(manager.installationInProgress, isFalse);
    expect(
      manager
          .acquire(instanceId: 'app_instance_0001', pageId: 'app_page_00000001')
          .acquired,
      isTrue,
    );
  });

  test('active editor prevents install barrier from replacing its tree', () {
    manager.acquire(
      instanceId: 'browser_instance_1',
      pageId: 'browser_page_00001',
    );

    expect(manager.beginInstall(), isFalse);
    expect(manager.installationInProgress, isFalse);
  });

  test('authorized acquire rotates the page capability on every success', () {
    var capabilityCounter = 0;
    final authorizedManager = GDevelopEditorInstanceLeaseManager(
      clock: () => now,
      tokenFactory: () => 'lease_token_${++tokenCounter}'.padRight(24, '_'),
      acquireCapabilityFactory: () =>
          'page_capability_${++capabilityCounter}'.padRight(32, '_'),
      ttl: const Duration(seconds: 30),
      heartbeatInterval: const Duration(seconds: 5),
    );
    final firstCapability = authorizedManager.issueAcquireCapability();

    final denied = authorizedManager.acquireWithCapability(
      acquireCapability: 'wrong_page_capability_value',
      instanceId: 'app_instance_0001',
      pageId: 'app_page_00000001',
    );
    expect(denied.authorized, isFalse);
    expect(authorizedManager.active, isNull);

    final first = authorizedManager.acquireWithCapability(
      acquireCapability: firstCapability,
      instanceId: 'app_instance_0001',
      pageId: 'app_page_00000001',
    );
    expect(first.authorized, isTrue);
    expect(first.acquireResult!.acquired, isTrue);
    expect(first.nextCapability, isNot(firstCapability));
    expect(
      authorizedManager.validatesAcquireCapability(firstCapability),
      isFalse,
    );
    expect(
      authorizedManager.validatesAcquireCapability(first.nextCapability!),
      isTrue,
    );

    final resumed = authorizedManager.acquireWithCapability(
      acquireCapability: first.nextCapability!,
      instanceId: first.acquireResult!.lease!.instanceId,
      pageId: 'app_page_00000002',
      previousLeaseToken: first.acquireResult!.lease!.leaseToken,
      resumeAfterReload: true,
    );
    expect(resumed.acquireResult!.resumed, isTrue);
    expect(resumed.nextCapability, isNot(first.nextCapability));
  });

  test('capability generation failure cannot partially acquire a lease', () {
    final brokenManager = GDevelopEditorInstanceLeaseManager(
      clock: () => now,
      tokenFactory: () => 'lease_token_${++tokenCounter}'.padRight(24, '_'),
      acquireCapabilityFactory: () => 'unchanged_page_capability_value',
      ttl: const Duration(seconds: 30),
      heartbeatInterval: const Duration(seconds: 5),
    );
    final capability = brokenManager.issueAcquireCapability();

    expect(
      () => brokenManager.acquireWithCapability(
        acquireCapability: capability,
        instanceId: 'app_instance_0001',
        pageId: 'app_page_00000001',
      ),
      throwsStateError,
    );
    expect(brokenManager.active, isNull);
    expect(brokenManager.validatesAcquireCapability(capability), isTrue);
  });
}
