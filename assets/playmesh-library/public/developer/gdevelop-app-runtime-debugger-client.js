(function installPlaymeshGDevelopAppRuntimeDebuggerClient(global) {
  'use strict';

  var gdjs = global.gdjs;
  if (!gdjs || typeof gdjs.AbstractDebuggerClient !== 'function') {
    console.warn(
      '[Playmesh GDevelop debugger] Abstract debugger client is unavailable.'
    );
    return;
  }

  var outboundMessages = [];
  var client = null;

  function enqueue(message) {
    if (typeof message !== 'string') return;
    outboundMessages.push(message);
  }

  class PlaymeshAppRuntimeDebuggerClient extends gdjs.AbstractDebuggerClient {
    constructor(runtimeGame) {
      super(runtimeGame);
      client = this;
    }

    _sendMessage(message) {
      enqueue(message);
    }

    receive(command) {
      this.handleCommand(command);
    }
  }

  var relay = {
    protocolVersion: '1.0.0',
    drain: function drain() {
      var messages = outboundMessages;
      outboundMessages = [];
      return JSON.stringify({
        protocolVersion: '1.0.0',
        ready: !!client,
        messages: messages,
      });
    },
    receive: function receive(command) {
      if (!client || !command || typeof command.command !== 'string') {
        return false;
      }
      client.receive(command);
      return true;
    },
  };

  Object.defineProperty(global, '__PLAYMESH_GDEVELOP_DEBUGGER_RELAY__', {
    configurable: false,
    enumerable: false,
    writable: false,
    value: relay,
  });
  gdjs.DebuggerClient = PlaymeshAppRuntimeDebuggerClient;
})(window);
