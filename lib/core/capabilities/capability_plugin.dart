import 'dart:async';

typedef CapabilityJson = Map<String, Object?>;

class CapabilityMethodDescriptor {
  const CapabilityMethodDescriptor({
    required this.name,
    required this.description,
    this.requiresUserActivation = false,
    this.argumentsSchema = const {'type': 'object'},
    this.resultSchema = const {'type': 'null'},
  });

  final String name;
  final String description;
  final bool requiresUserActivation;
  final CapabilityJson argumentsSchema;
  final CapabilityJson resultSchema;

  CapabilityJson toJson() => {
    'name': name,
    'description': description,
    'requiresUserActivation': requiresUserActivation,
    'argumentsSchema': argumentsSchema,
    'resultSchema': resultSchema,
  };
}

class CapabilityEventDescriptor {
  const CapabilityEventDescriptor({
    required this.name,
    required this.description,
    this.dataSchema = const {'type': 'object'},
  });

  final String name;
  final String description;
  final CapabilityJson dataSchema;

  CapabilityJson toJson() => {
    'name': name,
    'description': description,
    'dataSchema': dataSchema,
  };
}

class CapabilityDescriptor {
  const CapabilityDescriptor({
    required this.code,
    required this.name,
    required this.description,
    required this.apiVersion,
    required this.methods,
    required this.events,
    this.optionsSchema = const {'type': 'object'},
    this.appSupported = true,
    this.htmlSupported = false,
  });

  final String code;
  final String name;
  final String description;
  final String apiVersion;
  final List<CapabilityMethodDescriptor> methods;
  final List<CapabilityEventDescriptor> events;
  final CapabilityJson optionsSchema;
  final bool appSupported;
  final bool htmlSupported;

  CapabilityJson toJson() => {
    'code': code,
    'name': name,
    'description': description,
    'apiVersion': apiVersion,
    'appSupported': appSupported,
    'htmlSupported': htmlSupported,
    'optionsSchema': optionsSchema,
    'methods': methods.map((method) => method.toJson()).toList(),
    'events': events.map((event) => event.toJson()).toList(),
  };
}

class CapabilityInstanceEvent {
  const CapabilityInstanceEvent(this.name, [this.data = const {}]);

  final String name;
  final CapabilityJson data;
}

abstract interface class CapabilityInstance {
  Stream<CapabilityInstanceEvent> get events;

  Future<Object?> invoke(String method, CapabilityJson arguments);

  Future<void> dispose();
}

abstract interface class CapabilityPlugin {
  CapabilityDescriptor get descriptor;

  bool get isAvailable;

  Future<CapabilityInstance> create(CapabilityJson options);

  Future<CapabilityJson> test(Duration timeout);

  Future<void> dispose();
}
