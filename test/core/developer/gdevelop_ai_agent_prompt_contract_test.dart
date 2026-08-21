import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const promptRoot = 'assets/playmesh-library/public/developer/prompts';
  final contracts =
      <
        ({
          String locale,
          String directHttp,
          String unavailable,
          String toolIndex,
          String onDemandDetails,
          String singleObject,
          String approval,
          String failure,
          List<String> forbiddenTerms,
        })
      >[
        (
          locale: 'zh-CN',
          directHttp: '使用当前模型运行环境提供的 HTTP 请求能力',
          unavailable:
              '{"status":"unavailable","code":"playmesh_gateway_http_unavailable"}',
          toolIndex: '工具名称只以后文 GDevelop 工具索引为准',
          onDemandDetails:
              '先通过 HTTP 合同中 `get_gdevelop_tool_details` 对应的详情 GET 按需取得该工具的参数 Schema',
          singleObject: '每次 `/calls` 请求的 body 恰好是合同给出的单个 call 对象',
          approval: 'awaiting_approval 时，按合同继续轮询并等待审批结果',
          failure: '调用失败时不限制重试次数',
          forbiddenTerms: [
            'Chat',
            '对话',
            '控制台',
            '界面',
            '模式',
            '共用',
            '共享',
            '浏览器',
            '命令',
            '源码',
            '路由',
            '终端',
            'shell',
            'powershell',
            'curl',
            'wget',
            'devtools',
            '抓包',
            '回滚',
            '历史',
            '保存',
            '内存',
          ],
        ),
        (
          locale: 'en-US',
          directHttp:
              'Use the current model runtime\'s HTTP request capability',
          unavailable:
              '{"status":"unavailable","code":"playmesh_gateway_http_unavailable"}',
          toolIndex: 'Use only tool names from the GDevelop tool index below',
          onDemandDetails:
              'obtain its argument schema on demand through the details GET corresponding to `get_gdevelop_tool_details` in the HTTP contract',
          singleObject:
              'each `/calls` request body must equal the single call object specified by the contract',
          approval:
              'While a call is awaiting_approval, keep polling as specified by the contract and wait for the decision',
          failure: 'There is no fixed retry limit when a call fails',
          forbiddenTerms: [
            'chat',
            'console',
            'interface',
            'shared',
            'browser',
            'command',
            'source code',
            'source inspection',
            'route discovery',
            'route probing',
            'terminal',
            'shell',
            'powershell',
            'curl',
            'wget',
            'devtools',
            'traffic inspection',
            'rollback',
            'reconciliation',
            'history',
            'save',
            'memory',
          ],
        ),
      ];

  for (final contract in contracts) {
    test('${contract.locale} Agent template is HTTP-only and bounded', () async {
      final file = File('$promptRoot/${contract.locale}/gdevelop-agent.txt');
      expect(await file.exists(), isTrue, reason: file.path);
      final prompt = await file.readAsString();

      expect(prompt, contains(contract.directHttp));
      expect(prompt, contains(contract.unavailable));
      expect(prompt, contains(contract.toolIndex));
      expect(prompt, contains(contract.onDemandDetails));
      expect(prompt, contains(contract.singleObject));
      expect(prompt, contains(contract.approval));
      expect(prompt, contains(contract.failure));
      expect(prompt, isNot(contains('最多重试3次')));
      expect(prompt, isNot(contains('retry up to 3 times')));
      expect(prompt, contains('AGENT HTTP CONTRACT'));
      expect(prompt.length, lessThan(2200));

      final normalizedPrompt = prompt.toLowerCase();
      for (final forbiddenTerm in contract.forbiddenTerms) {
        expect(
          normalizedPrompt,
          isNot(contains(forbiddenTerm.toLowerCase())),
          reason: '${contract.locale} spread term: $forbiddenTerm',
        );
      }
      if (contract.locale == 'en-US') {
        expect(
          normalizedPrompt,
          isNot(
            matches(
              RegExp(
                r'\b(?:chat|console|interface|mode|shared|source|route|hash|token)\b',
              ),
            ),
          ),
          reason: 'en-US standalone spread concept',
        );
      } else {
        for (final internalStateTerm in ['会话', '工程状态', '哈希', '令牌']) {
          expect(
            prompt,
            isNot(contains(internalStateTerm)),
            reason:
                '${contract.locale} internal state term: $internalStateTerm',
          );
        }
      }

      for (final eagerProjectState in [
        'simplifiedProject',
        'projectRevision',
        'projectContentHash',
        'argumentsSchema',
        'eventPayloadSchema',
        'sceneNames',
        'editorSessionId',
        'callId',
        'idempotencyKey',
      ]) {
        expect(prompt, isNot(contains(eagerProjectState)));
      }
      expect(prompt, isNot(matches(RegExp(r'Bearer [0-9a-f]{64}'))));
      expect(prompt, isNot(contains('generatedEvents')));
      expect(prompt, isNot(contains('gd.EventsList')));
      expect(prompt, isNot(contains('list_event_instructions')));
      expect(prompt, isNot(contains('read_scene_events_json')));
    });
  }
}
