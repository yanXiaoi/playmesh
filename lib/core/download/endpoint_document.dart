import 'endpoint_document_contract.dart';
import 'endpoint_document_stub.dart'
    if (dart.library.io) 'endpoint_document_io.dart'
    as platform;

export 'endpoint_document_contract.dart';

EndpointDocumentHttpClient createEndpointDocumentHttpClient() =>
    platform.createEndpointDocumentHttpClient();
