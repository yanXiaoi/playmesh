import 'developer_channel.dart';

abstract interface class DeveloperWebGateway {
  DeveloperSession get session;

  Future<List<Uri>> workspaceLinks();

  Future<void> close();
}
