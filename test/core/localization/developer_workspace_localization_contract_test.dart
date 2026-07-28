import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const developerRoot = 'assets/playmesh-library/public/developer';
  const localizationRoot = 'assets/playmesh-localization';

  test('Developer Workspace consumes only the unified App localization', () {
    final html = File('$developerRoot/workspace.html').readAsStringSync();
    final script = File('$developerRoot/workspace.js').readAsStringSync();
    final localization = File(
      '$developerRoot/workspace-localization.js',
    ).readAsStringSync();
    final zh = _readMessages('$localizationRoot/locales/zh-CN/app.json');
    final en = _readMessages('$localizationRoot/locales/en-US/app.json');

    final requiredKeys = <String>{};
    for (final match in RegExp(
      r'data-i18n(?:-[a-z-]+)?="([^"]+)"',
    ).allMatches(html)) {
      requiredKeys.add(match.group(1)!);
    }
    for (final source in [html, script, localization]) {
      for (final match in RegExp(r"\b(?:tr|t)\('([^']+)'").allMatches(source)) {
        requiredKeys.add(match.group(1)!);
      }
    }
    requiredKeys.removeWhere((key) => key.endsWith('.'));
    requiredKeys.addAll(_dynamicWorkspaceKeys);

    final zhWorkspaceKeys = zh.keys
        .where((key) => key.startsWith('workspace.'))
        .toSet();
    final enWorkspaceKeys = en.keys
        .where((key) => key.startsWith('workspace.'))
        .toSet();
    expect(
      zhWorkspaceKeys.difference(requiredKeys),
      isEmpty,
      reason: 'Unused zh-CN Workspace keys must be removed.',
    );
    expect(
      requiredKeys.difference(zhWorkspaceKeys),
      isEmpty,
      reason: 'Referenced zh-CN Workspace keys must be defined.',
    );
    expect(
      enWorkspaceKeys.difference(requiredKeys),
      isEmpty,
      reason: 'Unused en-US Workspace keys must be removed.',
    );
    expect(
      requiredKeys.difference(enWorkspaceKeys),
      isEmpty,
      reason: 'Referenced en-US Workspace keys must be defined.',
    );
    expect(zhWorkspaceKeys, requiredKeys);
    expect(enWorkspaceKeys, requiredKeys);

    for (final key in requiredKeys) {
      expect(
        _placeholders(zh[key]!),
        _placeholders(en[key]!),
        reason: 'Placeholder mismatch for $key',
      );
    }

    expect(localization, contains("const endpoint = '/dev/api/localization'"));
    expect(localization, isNot(contains('/playmesh/localization/')));
    expect(localization, isNot(contains('playmesh.developer.locale')));
    expect(localization, isNot(contains('playmesh.developer.theme')));
    expect(localization, isNot(contains('localStorage')));
    expect(localization, isNot(contains('matchMedia(')));
    expect(localization, contains('missing_localized_message:'));
    expect(localization, contains('snapshot.themeMode'));
    expect(localization, contains('snapshot.effectiveTheme'));
    expect(localization, contains('snapshot.allowThemeSwitch'));
    expect(localization, isNot(contains('workspacePreferences')));
    expect(
      localization,
      isNot(contains('body: JSON.stringify({ themeMode })')),
    );
    expect(
      html,
      contains(
        '<script id="playmeshAppUiBootstrap" type="application/json">'
        '__PLAYMESH_APP_UI_BOOTSTRAP__</script>',
      ),
    );
    expect(html, isNot(contains('prefers-color-scheme')));
    expect(html, isNot(contains('id="workspacePreferences"')));
    expect(html, isNot(contains('id="workspacePreferencesModal"')));
    expect(
      localization,
      contains("document.documentElement.dataset.theme = 'workspace'"),
    );
    expect(
      localization,
      contains("document.documentElement.style.colorScheme = 'dark'"),
    );
    expect(script, contains("workspaceEditorTheme=()=>'material-darker'"));
    expect(script, contains('window.workspaceI18n.t(key,args)'));
    expect(script, isNot(contains('fallback,args')));
    expect(script, isNot(contains('textOr(')));
  });

  test('Developer Workspace has no independent localization bundle', () {
    final middleware = File(
      'lib/core/developer/operations/middleware/'
      'developer_request_middleware.dart',
    ).readAsStringSync();
    final manifest =
        jsonDecode(
              File(
                'assets/playmesh-localization/manifest.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final locales = (manifest['locales']! as List).cast<Map>();

    for (final locale in locales) {
      final bundles = Map<String, Object?>.from(locale['bundles']! as Map);
      expect(bundles.keys, isNot(contains('developer')));
    }
    expect(middleware, isNot(contains('/playmesh/localization/')));
    expect(
      File(
        'assets/playmesh-localization/locales/zh-CN/developer.json',
      ).existsSync(),
      isFalse,
    );
    expect(
      File(
        'assets/playmesh-localization/locales/en-US/developer.json',
      ).existsSync(),
      isFalse,
    );
  });

  test('Workspace UI copy and icons are packaged and contract-safe', () {
    final html = File('$developerRoot/workspace.html').readAsStringSync();
    final script = File('$developerRoot/workspace.js').readAsStringSync();
    final localization = File(
      '$developerRoot/workspace-localization.js',
    ).readAsStringSync();
    final css = File('$developerRoot/workspace.css').readAsStringSync();
    final icons = File('$developerRoot/workspace-icons.js').readAsStringSync();
    final visibleSources = [html, script, localization, css, icons];

    for (final source in visibleSources) {
      expect(source, isNot(matches(RegExp(r'[\u3400-\u9fff]'))));
    }
    expect(css, isNot(matches(RegExp(r'gradient\(|box-shadow|text-shadow'))));
    expect(
      css,
      isNot(matches(RegExp(r'transition\s*:\s*all', caseSensitive: false))),
    );
    expect(
      css,
      isNot(
        matches(RegExp(r'outline\s*:\s*(?:0|none)\b', caseSensitive: false)),
      ),
      reason: 'Workspace controls must keep the shared visible focus ring.',
    );
    for (final match in RegExp(
      r'border-radius\s*:\s*(\d+)px',
    ).allMatches(css)) {
      final radius = int.parse(match.group(1)!);
      expect(
        radius <= 8 || radius == 999,
        isTrue,
        reason: 'Ordinary workspace radius must not exceed 8px',
      );
    }

    expect(File('$developerRoot/workspace-v1.css').existsSync(), isFalse);
    expect(html, contains('/playmesh/developer/workspace.css'));
    expect(html, isNot(contains('workspace-v1.css')));
    expect(html, contains('/playmesh/developer/workspace-icons.js'));
    expect(html, contains('href="#play"'));
    expect(html, isNot(contains('/playmesh/developer/lucide.svg#')));
    expect(script, isNot(contains('/playmesh/developer/lucide.svg#')));
    expect(script, contains("return window.workspaceIcons.create(name)"));
    expect(
      script,
      contains(
        "window.workspaceIcons.render(toolbarRun.querySelector('svg'),"
        "running?'rotate-ccw':'play')",
      ),
    );
    expect(
      script,
      isNot(contains("toolbarRun.querySelector('use').setAttribute")),
    );
    expect(icons, contains('"file-css"'));
    expect(icons, contains('"file-js"'));
    expect(icons, contains('"file-text"'));
    expect(icons, contains('"file-image"'));
    expect(icons, contains('"file-question"'));
    expect(html, isNot(contains('cdn')));
    expect(
      script,
      contains(
        "return statuses.has(status)?tr('workspace.capability_status.'+status):String(status??'')",
      ),
      reason:
          'Known capability state codes may be localized, but unknown API values must remain verbatim.',
    );
    expect(
      script,
      isNot(contains("tr('workspace.capability_status.'+result.status)")),
    );
    expect(
      script,
      contains(
        "return statuses.has(result.status)?tr('workspace.publish_status.'+result.status):result.status",
      ),
    );
    expect(
      script,
      contains(
        "phaseText=phases.has(data.phase)?tr('workspace.run_status.'+data.phase):data.message||data.phase",
      ),
    );
    expect(
      localization,
      contains("result = result.replaceAll(`{\${key}}`, String(value ?? ''))"),
      reason: 'Dynamic interpolation values must be inserted verbatim.',
    );
    final dynamicMessagePrefixes = RegExp(
      r"tr\('(workspace\.[^']+\.)'\s*\+",
    ).allMatches(script).map((match) => match.group(1)!).toSet();
    expect(dynamicMessagePrefixes, {
      'workspace.publish_status.',
      'workspace.run_status.',
      'workspace.capability_status.',
    });
    expect(script, contains('const capabilityLocalizationKeys=Object.freeze'));
    expect(script, contains('diagnosticLocalizationKeys=Object.freeze'));
    expect(script, contains('historySummaryLocalizationKeys=Object.freeze'));
    expect(script, contains('promptTemplateLocalizationKeys=Object.freeze'));
    expect(script, contains('window.showWorkspaceError=showWorkspaceError'));
    expect(
      script,
      isNot(contains("q('projectSearch').focus()")),
      reason: 'Opening project actions must not force focus into search.',
    );
    expect(
      script,
      isNot(contains("q('projectSearch').select()")),
      reason: 'Opening project actions must not select search text.',
    );
    expect(
      script,
      contains(
        "function openProjectPicker(){toolbarMenu.classList.remove('open');"
        "q('moreActions').setAttribute('aria-expanded','false');"
        "renderProjectList();updateProjectPickerRequirement();"
        "projectPickerMenu.classList.add('open');"
        "projectPicker.setAttribute('aria-expanded','true');"
        "positionAnchoredMenu(projectPickerMenu,projectPicker)}",
      ),
      reason: 'Opening project actions must not move focus automatically.',
    );
    expect(
      script,
      contains("showWorkspaceError(error);throw error}if(!response.ok)"),
      reason: 'Developer API failures must use the centered error message.',
    );
    expect(
      script,
      contains(
        "catch(error){q('promptPreviewContent').textContent=error.message;"
        "throw error}finally",
      ),
      reason: 'Prompt failures must replace the stale generating state.',
    );
    expect(
      html,
      contains(
        'if(window.showWorkspaceError){window.showWorkspaceError(error);return}',
      ),
      reason: 'Unhandled Workspace errors must use the centered error message.',
    );
    expect(css, contains('.workspace-message.error {'));
    expect(
      script,
      contains("return key?tr(key):String(definition?.[field]??'')"),
      reason: 'Unknown capability metadata must remain verbatim.',
    );
    expect(
      script,
      contains("if(!key)return String(diagnostic?.[field]??'')"),
      reason: 'Unknown diagnostic text must remain verbatim.',
    );
    expect(
      script,
      contains(
        "return key?tr(key,operation.summaryArguments||{}):"
        "String(operation?.summary??'')",
      ),
      reason: 'Unknown history summaries must remain verbatim.',
    );
    expect(script, contains("return key?tr(key):String(category?.name??'')"));
    expect(script, contains("return key?tr(key):String(item?.name??'')"));
    expect(
      script,
      contains(
        "title.textContent=localizedDiagnosticField(diagnostic,'message')",
      ),
    );
    expect(
      script,
      contains("hint.textContent=localizedDiagnosticField(diagnostic,'hint')"),
    );
    expect(
      script,
      contains("name.textContent=localizedCapabilityField(item,'name')"),
    );
    expect(script, contains("if(type==='object')"));
    expect(script, contains("if(type==='array')"));
    expect(script, contains("Array.isArray(schema?.enum)"));
    expect(script, contains("if(type==='boolean')"));
    expect(script, contains("if(type==='integer'||type==='number')"));
    expect(script, contains('capabilityParameterRequirementText'));
    expect(script, isNot(contains('capabilityDraftText')));
    expect(script, isNot(contains("tr('workspace.raw_json')")));
    expect(script, contains('log.textContent=capabilityTestLogLines.join'));
    expect(
      script,
      contains(
        'capabilityTestLogRenderTimer=setTimeout('
        'renderCapabilityTestJson,100)',
      ),
    );
    expect(script, contains('const capabilityTestLogLimit=100'));
    expect(
      script,
      contains('capabilityTestLogLines.length-capabilityTestLogLimit'),
    );
    expect(
      script,
      contains(
        'async function runCapabilityTests(codes){'
        'if(capabilityTestBusy)return;clearCapabilityTestJson();',
      ),
    );
    expect(
      script,
      contains(
        'async function startCapabilityContinuousTest(){'
        'const item=capabilityTestDefinition();'
        'if(!item||capabilityTestBusy)return;clearCapabilityTestJson();',
      ),
    );
    expect(
      script,
      contains(
        'if(capabilityTestInstance)'
        'await disposeCapabilityTestInstance({quiet:true});'
        'if(!(await createCapabilityTestInstance({quiet:true})))return;',
      ),
    );
    expect(
      css,
      contains(
        '.manifest-form .capability-options{max-height:min(42svh,320px);'
        'overflow-y:auto',
      ),
    );
    expect(css, contains('scroll-snap-type: x proximity'));
    expect(
      css,
      contains(
        '.capability-test-body {\n'
        '    display: block;\n'
        '    min-height: 0;\n'
        '    overflow-y: auto;',
      ),
    );
    expect(script, contains("' '+event.message+location+stack"));
    expect(
      script,
      contains(
        "event.source+'] ['+event.level+']'+kind+' '+"
        'event.message+location+stack',
      ),
    );
    expect(script, contains("event.stack&&!String(event.message)"));
    expect(script, isNot(contains('tr(event.message')));
    expect(script, isNot(contains('tr(event.stack')));
    expect(script, isNot(contains('tr(event.source')));
    expect(script, isNot(contains('tr(event.level')));
    final manifestBuilder = RegExp(
      r'function manifestFromForm\(\)\{(.+?)return manifest\}',
    ).firstMatch(script)!.group(1)!;
    expect(manifestBuilder, isNot(contains('...manifestSource')));
    expect(manifestBuilder, isNot(contains('delete manifest.')));
    expect(
      manifestBuilder,
      contains('appSdkVersion:manifestSource.appSdkVersion'),
    );
    expect(
      manifestBuilder,
      contains(
        "entries:{game:q('manifestGameEntry').value.trim(),"
        "controller:q('manifestControllerEntry').value.trim()}",
      ),
      reason:
          'The form must write a fresh object containing only current fields; '
          'unknown main.json fields are silently omitted.',
    );
    expect(
      '$html\n$script',
      isNot(matches(RegExp(r'[▶✨⋯⌫↻■✓◉≠＋×]|📁|📄|🔒|🔐'))),
    );
    expect(icons, contains('workspaceIcons'));
    expect(icons, contains('play:'));
    expect(icons, contains('"trash-2"'));
    expect(icons, contains('"file-lock"'));
    expect(icons, contains('"folder-kanban"'));
    expect(icons, contains('"folder-open"'));
    expect(icons, contains('"file-code-2"'));
    expect(icons, contains('"gamepad-2"'));
    expect(icons, contains('smartphone:'));
    expect(icons, contains('"shield-check"'));
    expect(script, contains('function treeFilePresentation(path)'));
    expect(
      script,
      contains(
        "defaultProjectEntryPaths=Object.freeze({game:'app/index.html',"
        "controller:'app/controller/index.html',"
        "authority:'app/static/js/service/index.js'})",
      ),
    );
    expect(script, contains('manifest?.entries?.game'));
    expect(script, contains('manifest?.entries?.controller'));
    expect(script, contains('manifest?.authority?.entry'));
    expect(script, contains("kind:'game-entry-file'"));
    expect(script, contains("kind:'controller-entry-file'"));
    expect(script, contains("kind:'authority-entry-file'"));
    expect(script, contains("kind:'style-file'"));
    expect(script, contains("kind:'script-file'"));
    expect(script, contains("kind:'text-file'"));
    expect(script, contains("kind:'image-file'"));
    expect(script, contains("kind:'unknown-file'"));
    expect(css, contains('.tree.tree .file.game-entry-file'));
    expect(css, contains('.tree.tree .file.controller-entry-file'));
    expect(css, contains('.tree.tree .file.authority-entry-file'));
    expect(css, contains('height: 30px !important'));
    expect(css, contains('margin-inline-start: 20px'));
    expect(css, contains('.tree.tree .file {\n  gap: 2px;'));
    final treeTypeColors = RegExp(
      r'--tree-[a-z-]+-color:\s*([^;]+);',
    ).allMatches(css).map((match) => match.group(1)!.trim()).toList();
    expect(treeTypeColors, hasLength(13));
    expect(
      treeTypeColors.toSet(),
      hasLength(treeTypeColors.length),
      reason: 'Each project-tree type must keep a distinct identifying color.',
    );
    expect(html, contains('id="publishFromMenu" class="mobile-only"'));
    expect(css, contains('.toolbar > #publish'));
    expect(css, contains('display: none'));
  });

  test('Workspace presentation and modal input use one shared contract', () {
    final html = File('$developerRoot/workspace.html').readAsStringSync();
    final script = File('$developerRoot/workspace.js').readAsStringSync();
    final localization = File(
      '$developerRoot/workspace-localization.js',
    ).readAsStringSync();
    final css = File('$developerRoot/workspace.css').readAsStringSync();

    final firstPartyStyleSheets =
        RegExp(
              r'<link rel="stylesheet" href="/playmesh/developer/([^"]+\.css)">',
            )
            .allMatches(html)
            .map((match) => match.group(1)!)
            .where((path) => !path.startsWith('editor/'))
            .toList();
    expect(firstPartyStyleSheets, ['workspace.css']);
    expect(
      RegExp(r'^:root\s*\{', multiLine: true).allMatches(css),
      hasLength(1),
    );
    expect(css, isNot(contains(':root[data-theme="light"]')));
    expect(
      css,
      startsWith('/* Developer Workspace single tokenized presentation layer.'),
    );
    expect(css, contains('--target-size: 44px'));
    expect(css, contains('body :where('));
    expect(css, contains('min-height: var(--target-size) !important'));
    expect(css, contains('min-width: var(--target-size) !important'));
    expect(css, contains(':where(.capability-option, .publish-source)'));
    expect(css, contains('content-visibility: auto'));
    expect(css, contains('contain-intrinsic-size: auto 52px'));
    expect(css, contains('.validation-list > .validation-item'));
    expect(css, contains('.diff-details > .diff-line'));
    final platformManagedCascade = css.substring(
      css.indexOf(
        '/* Visual editor for the platform-managed manifest and capability registry. */',
      ),
    );
    expect(
      platformManagedCascade,
      isNot(
        matches(
          RegExp(r'(?:#[0-9a-f]{3,8}\b|rgba?\s*\()', caseSensitive: false),
        ),
      ),
      reason:
          'Late platform-owned component rules must use the shared theme tokens.',
    );
    expect(
      css,
      matches(
        RegExp(
          r'\.qr\s*\{[^}]*border:\s*1px\s+solid\s+#d8d8d8;'
          r'[^}]*background:\s*#ffffff;',
          caseSensitive: false,
        ),
      ),
      reason: 'QR rendering must keep a fixed neutral border and white canvas.',
    );

    expect(
      script,
      contains(
        "const selector='button,input,select,textarea,a[href],summary,"
        '[contenteditable="true"],[tabindex]\'',
      ),
    );
    expect(script, contains('const openModalStack=[]'));
    expect(script, contains("modal.querySelector('[data-initial-focus]')"));
    expect(script, contains('function bindModalKeyboard('));
    expect(
      script,
      contains("['ArrowDown','ArrowRight','ArrowUp','ArrowLeft']"),
    );
    expect(script, contains('function bindModalFocusLifecycle(modal)'));
    expect(
      script,
      contains(
        'new MutationObserver(sync).observe(modal,'
        "{attributes:true,attributeFilter:['style']})",
      ),
    );
    expect(script, contains("document.addEventListener('focusin'"));
    expect(
      script,
      contains("for(const modal of document.querySelectorAll('.modal'))"),
    );
    expect(
      script,
      contains("bindModalKeyboard(modal,null,{escapeCloses:false})"),
      reason: 'Escape must not resolve or bypass the AI approval decision.',
    );
    expect(
      html,
      contains(
        'id="aiApprovalReject" class="danger-action" data-initial-focus',
      ),
    );
    expect(localization, isNot(contains('workspacePreferences')));
    expect(localization, isNot(contains('preferenceItems')));
    expect(localization, isNot(contains('returnFocus:')));
  });

  test('Conversation console reports JSON errors and only clears input', () {
    final script = File('$developerRoot/workspace.js').readAsStringSync();

    expect(script, contains('function jsonSyntaxLocation(input,error)'));
    expect(script, contains("parsed.code='invalid_json'"));
    expect(
      script,
      contains(
        "q('quickMergeHost').textContent=JSON.stringify(payload,null,2)",
      ),
    );
    expect(script, contains("q('quickApplySelected').disabled=false"));

    final clearStart = script.indexOf('async function applyQuick()');
    expect(clearStart, isNonNegative);
    final clearEnd = script.indexOf('\n', clearStart);
    final clearSource = script.substring(clearStart, clearEnd);
    expect(clearSource, contains("input.value=''"));
    expect(clearSource, contains('input.focus()'));
    expect(clearSource, isNot(contains('quickMergeHost')));
    expect(clearSource, isNot(contains('.disabled')));

    final openStart = script.indexOf("q('quickPanel').onclick");
    expect(openStart, isNonNegative);
    final openEnd = script.indexOf('\n', openStart);
    final openSource = script.substring(openStart, openEnd);
    expect(openSource, isNot(contains("q('quickApply').disabled")));
  });

  test('Project creation and editing share one capability multi-select', () {
    final html = File('$developerRoot/workspace.html').readAsStringSync();
    final script = File('$developerRoot/workspace.js').readAsStringSync();
    final css = File('$developerRoot/workspace.css').readAsStringSync();

    expect(RegExp(r'class="capability-picker"').allMatches(html), hasLength(4));
    expect(
      html,
      contains('id="projectCapabilityOptions" class="capability-picker"'),
    );
    expect(
      html,
      contains(
        'id="projectControllerCapabilityOptions" class="capability-picker"',
      ),
    );
    expect(
      script,
      contains(
        "function renderCapabilityOptions(required=[],"
        "hostId='capabilityOptions'){renderCapabilityPicker(required,hostId)}",
      ),
    );
    expect(
      script,
      contains("renderCapabilityPicker([],'projectCapabilityOptions')"),
    );
    expect(
      script,
      contains(
        "renderCapabilityPicker([],'projectControllerCapabilityOptions')",
      ),
    );

    final pickerStart = script.indexOf('function renderCapabilityPicker(');
    final pickerEnd = script.indexOf(
      '\nasync function openNewProject',
      pickerStart,
    );
    expect(pickerStart, isNonNegative);
    expect(pickerEnd, greaterThan(pickerStart));
    final pickerSource = script.substring(pickerStart, pickerEnd);
    expect(pickerSource, contains("search.setAttribute('role','combobox')"));
    expect(pickerSource, contains("panel.setAttribute('role','listbox')"));
    expect(pickerSource, contains('search.onfocus=open'));
    expect(pickerSource, contains("if(event.key==='Escape')"));
    expect(
      pickerSource,
      contains(
        "document.addEventListener('pointerdown',"
        "host._capabilityPickerOutsidePointerDown,true)",
      ),
    );
    expect(pickerSource, contains("if(!host.contains(event.target))close()"));
    expect(pickerSource, isNot(contains('capabilityContract(')));

    expect(css, contains('.capability-picker-panel {\n  position: absolute;'));
    expect(css, contains('display: none;'));
    expect(
      css,
      contains(
        '.capability-picker.open .capability-picker-panel {\n'
        '  display: grid;',
      ),
    );

    expect(
      html,
      contains(
        'id="projectTags" class="manifest-tags"></div>'
        '<div class="input-action"><input id="projectTagInput"',
      ),
    );
    expect(
      html,
      contains('id="projectTagAdd" class="tag-add-button" type="button"'),
    );
    expect(html, isNot(contains('<textarea id="projectTags"')));
    expect(script, contains('function renderTagChips('));
    expect(script, contains('function renderProjectTags()'));
    expect(script, contains('function addProjectTag()'));
    expect(script, contains('tags:[...projectTags]'));
    expect(script, contains("q('projectTagAdd').onclick=addProjectTag"));
    expect(script, isNot(contains("q('projectTags').value")));
    expect(
      html,
      contains(
        'id="manifestTagAdd" class="tag-add-button" type="button" '
        'data-i18n-title="workspace.add"',
      ),
    );
    expect(
      html,
      contains(
        'id="projectTagAdd" class="tag-add-button" type="button" '
        'data-i18n-title="workspace.add"',
      ),
    );
    expect(script, contains("clear.replaceChildren(lucideIcon('eraser'))"));
    expect(script, isNot(contains("clear.textContent=tr('workspace.clear')")));
    expect(css, contains('.tag-add-button {'));
    expect(css, contains('.capability-picker-clear:disabled {'));
    expect(css, contains('visibility: hidden;'));
  });

  test('Every successful copy surfaces a top workspace message', () {
    final html = File('$developerRoot/workspace.html').readAsStringSync();
    final script = File('$developerRoot/workspace.js').readAsStringSync();
    final css = File('$developerRoot/workspace.css').readAsStringSync();

    expect(
      html,
      contains(
        'id="workspaceMessages" class="workspace-messages" '
        'aria-live="polite" aria-atomic="true"',
      ),
    );
    expect(
      script,
      contains("function showWorkspaceMessage(text,type='success')"),
    );
    expect(
      script,
      contains("showWorkspaceMessage(tr('workspace.copy_succeeded'))"),
    );
    expect(
      RegExp(r'navigator\.clipboard\.writeText\(value\)').allMatches(script),
      hasLength(1),
      reason:
          'All clipboard writes must pass through copyText and its message.',
    );
    expect(
      script,
      contains(
        "if(operation==='copy')"
        "showWorkspaceMessage(tr('workspace.copy_succeeded'))",
      ),
    );
    expect(
      script,
      contains(
        "message.textContent=tr('workspace.project_copied',"
        "{name:data.project.name});showWorkspaceMessage(message.textContent)",
      ),
    );
    expect(css, contains('.workspace-messages {\n  position: fixed;'));
    expect(css, contains('.workspace-message.visible {'));
    expect(css, contains('inset: 16px 12px auto;'));
  });

  test('Project tree commands and run controls stay context-specific', () {
    final html = File('$developerRoot/workspace.html').readAsStringSync();
    final script = File('$developerRoot/workspace.js').readAsStringSync();
    final css = File('$developerRoot/workspace.css').readAsStringSync();

    expect(css, contains('.context-menu button[hidden]'));
    expect(css, contains('display: none !important'));
    expect(
      script,
      contains("const folderTarget=kind==='root'||kind==='directory'"),
    );
    expect(script, contains('treeNewFile.hidden=!folderTarget'));
    expect(script, contains('treeNewDirectory.hidden=!folderTarget'));
    expect(script, contains('treeUpload.hidden=!folderTarget'));
    expect(script, contains('treePaste.hidden=!folderTarget||!treeClipboard'));
    expect(
      script,
      contains(r"treeExtract.hidden=kind!=='file'||!/\.zip$/i.test(itemPath)"),
    );

    expect(html, contains('id="extractModal" class="modal"'));
    expect(html, contains('id="extractDestinationOptions"'));
    expect(script, contains('function normalizeExtractDestination(value)'));
    expect(
      script,
      contains("['.playmesh','cache','data'].includes(segments[0])"),
    );
    expect(script, contains("q('extractDestination').value=treeMenuPath||'.'"));
    expect(script, isNot(contains('workspace.confirm_extract')));

    final menuStart = html.indexOf('<div id="toolbarMenu"');
    expect(menuStart, isNonNegative);
    final menuEnd = html.indexOf('</div>', menuStart);
    final menuSource = html.substring(menuStart, menuEnd);
    expect(menuSource, isNot(contains('id="restart"')));
    expect(menuSource, isNot(contains('id="stop"')));
    expect(menuSource, isNot(contains('id="delete"')));
    expect(html, contains('id="runPaneRun"'));
    expect(html, contains('id="restart"'));
    expect(html, contains('id="stop"'));
    expect(
      script,
      contains("toolbarRun.dataset.action=running?'restart':'run'"),
    );
  });
}

Map<String, String> _readMessages(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync()) as Map;
  return decoded.map(
    (key, value) => MapEntry(key.toString(), value.toString()),
  );
}

Set<String> _placeholders(String value) => RegExp(
  r'\{([^}]+)\}',
).allMatches(value).map((match) => match.group(1)!).toSet();

const _dynamicWorkspaceKeys = <String>{
  'workspace.file_copied_for_paste',
  'workspace.file_cut_for_paste',
  'workspace.directory_with_contents',
  'workspace.file',
  'workspace.before',
  'workspace.after',
  'workspace.before_version',
  'workspace.after_version',
  'workspace.passed',
  'workspace.failed',
  'workspace.webview_history_success',
  'workspace.webview_history_failure',
  'workspace.address_current',
  'workspace.address_local_only',
  'workspace.address_lan',
  'workspace.agent',
  'workspace.chat',
  'workspace.platform_supported',
  'workspace.platform_unsupported',
  'workspace.testable',
  'workspace.platform_unavailable',
  'workspace.ai_operation_rejected',
  'workspace.ai_operation_allowed',
  'workspace.publish_status.waiting',
  'workspace.publish_status.uploading',
  'workspace.publish_status.entered_review',
  'workspace.publish_status.unknown_source',
  'workspace.publish_status.source_not_eligible',
  'workspace.publish_status.invalid_upload_key',
  'workspace.publish_status.rate_limited',
  'workspace.publish_status.game_ownership_conflict',
  'workspace.publish_status.package_validation_failed',
  'workspace.publish_status.version_already_exists',
  'workspace.publish_status.version_must_increase',
  'workspace.publish_status.package_too_large',
  'workspace.publish_status.network_failed',
  'workspace.run_status.idle',
  'workspace.run_status.starting',
  'workspace.run_status.running',
  'workspace.run_status.stopping',
  'workspace.run_status.stopped',
  'workspace.run_status.error',
  'workspace.capability_status.passed',
  'workspace.capability_status.failed',
  'workspace.capability_status.unavailable',
  'workspace.capability_status.timeout',
  'workspace.capability.media_camera.name',
  'workspace.capability.media_camera.description',
  'workspace.capability.media_microphone.name',
  'workspace.capability.media_microphone.description',
  'workspace.capability.device_midi.name',
  'workspace.capability.device_midi.description',
  'workspace.capability.device_vibration.name',
  'workspace.capability.device_vibration.description',
  'workspace.prompt.category.common',
  'workspace.prompt.category.mode',
  'workspace.prompt.category.display',
  'workspace.prompt.template.common',
  'workspace.prompt.template.agent_common',
  'workspace.prompt.template.custom_ideas',
  'workspace.prompt.template.solo',
  'workspace.prompt.template.multiplayer',
  'workspace.prompt.template.multi_screen',
  'workspace.prompt.template.single_screen_multiplayer',
  'workspace.history.summary.publish_project',
  'workspace.history.summary.create_directory',
  'workspace.history.summary.delete_directory',
  'workspace.history.summary.copy_path',
  'workspace.history.summary.move_path',
  'workspace.history.summary.extract_archive',
  'workspace.history.summary.save_file',
  'workspace.history.summary.batch_edit',
  'workspace.history.summary.delete_file',
  'workspace.history.summary.restore_workspace',
  'workspace.history.summary.restore_path',
  'workspace.diagnostic.project_root_missing.message',
  'workspace.diagnostic.project_root_missing.hint',
  'workspace.diagnostic.symbolic_link_forbidden.message',
  'workspace.diagnostic.symbolic_link_forbidden.hint',
  'workspace.diagnostic.forbidden_publish_file.message',
  'workspace.diagnostic.forbidden_publish_file.hint',
  'workspace.diagnostic.manifest_missing.message',
  'workspace.diagnostic.manifest_missing.hint',
  'workspace.diagnostic.entry_missing.message',
  'workspace.diagnostic.entry_missing.hint',
  'workspace.diagnostic.root_icon_invalid.message',
  'workspace.diagnostic.root_icon_invalid.hint',
  'workspace.diagnostic.text_encoding_invalid.message',
  'workspace.diagnostic.text_encoding_invalid.hint',
  'workspace.diagnostic.resource_path_escape.message',
  'workspace.diagnostic.resource_path_escape.hint',
  'workspace.diagnostic.resource_missing.message',
  'workspace.diagnostic.resource_missing.hint',
  'workspace.diagnostic.manifest_encoding_invalid.message',
  'workspace.diagnostic.manifest_json_invalid.message',
  'workspace.diagnostic.manifest_json_invalid.hint',
  'workspace.diagnostic.manifest_root_invalid.message',
  'workspace.diagnostic.manifest_id_mismatch.message',
  'workspace.diagnostic.manifest_id_mismatch.hint',
  'workspace.diagnostic.manifest_semantic_invalid.message',
  'workspace.diagnostic.manifest_semantic_invalid.hint',
  'workspace.diagnostic.capabilities_invalid.message',
  'workspace.diagnostic.capabilities_invalid.hint',
};
