import 'endpoint_probe_contract.dart';
import 'endpoint_probe_stub.dart'
    if (dart.library.io) 'endpoint_probe_io.dart'
    as platform;

export 'endpoint_probe_contract.dart';

EndpointProbeService createEndpointProbeService({
  int maxConcurrency = 4,
  Duration timeout = const Duration(seconds: 4),
  Duration cacheDuration = const Duration(seconds: 30),
}) => EndpointProbeService(
  httpClient: platform.createEndpointProbeHttpClient(),
  maxConcurrency: maxConcurrency,
  timeout: timeout,
  cacheDuration: cacheDuration,
);
