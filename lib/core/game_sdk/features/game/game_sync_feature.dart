part of '../../sdk_feature_registry.dart';

const gameSyncSdkSource = SdkSourceFragment(
  id: 'game.sync',
  target: SdkSourceTarget.game,
  order: 40,
  typeScript: r'''  function cloneJson(value, label) {
    let encoded;
    try {
      encoded = JSON.stringify(value);
    } catch (error) {
      throw new Error(`${label} 必须可 JSON 序列化: ${error.message || error}`);
    }
    if (encoded === undefined) throw new Error(`${label} 不能是 undefined`);
    return JSON.parse(encoded);
  }

  function syncTargetIds(session) {
    return [...new Set([
      session.authorityClientId,
      ...session.players.map((player) => player.id),
    ].filter(Boolean))];
  }

  function applySyncState(runtime, nextState) {
    if (nextState === undefined) return false;
    const normalized = cloneJson(nextState, "权威状态");
    if (JSON.stringify(normalized) === JSON.stringify(runtime.state)) return false;
    runtime.state = normalized;
    runtime.revision += 1;
    return true;
  }

  function continuousInputs(runtime) {
    const result = {};
    for (const [compoundKey, entry] of runtime.inputs) {
      const separator = compoundKey.indexOf(":");
      const playerId = compoundKey.substring(0, separator);
      const key = compoundKey.substring(separator + 1);
      result[playerId] ??= {};
      result[playerId][key] = cloneJson(entry, "连续输入");
    }
    return result;
  }

  async function publishSyncSnapshot(runtime, targetPlayerIds) {
    if (runtime.stopped) return null;
    const session = bootstrap?.session;
    if (!session) return null;
    const snapshot = {
      protocolVersion: 1,
      stateType: runtime.stateType,
      full: true,
      revision: runtime.revision,
      sequence: ++runtime.snapshotSequence,
      timestamp: Date.now(),
      sourceTick: runtime.tick,
      state: cloneJson(runtime.state, "权威状态"),
    };
    applySyncSnapshot(snapshot);
    await post("authority.result", { __playmeshSyncSnapshot: snapshot }, {
      targetPlayerIds: targetPlayerIds || syncTargetIds(session),
    });
    return snapshot;
  }

  async function runSyncTick(runtime) {
    if (runtime.stopped || runtime.tickRunning) return;
    runtime.tickRunning = true;
    try {
      const now = Date.now();
      const dt = Math.min(1, Math.max(0, (now - runtime.lastTickAt) / 1000));
      runtime.lastTickAt = now;
      runtime.tick += 1;
      if (runtime.onTick) {
        const next = await runtime.onTick({
          state: cloneJson(runtime.state, "权威状态"),
          inputs: continuousInputs(runtime),
          tick: runtime.tick,
          dt,
          now,
          session: bootstrap.session,
          members: bootstrap.session.players,
        });
        applySyncState(runtime, next);
      }
      await publishSyncSnapshot(runtime);
    } catch (error) {
      emit(lifecycleListeners, { state: "error", error: String(error) });
    } finally {
      runtime.tickRunning = false;
    }
  }

  async function dispatchSyncAuthorityAction(transportMessage) {
    const envelope = transportMessage.payload?.__playmeshSync;
    if (!envelope) return false;
    const runtime = syncAuthorityRuntime;
    if (!runtime) return true;
    if (envelope.type === "snapshot.request") {
      await publishSyncSnapshot(runtime, [transportMessage.senderPlayerId]);
      return true;
    }
    if (envelope.type !== "input.action" && envelope.type !== "input.state") {
      return true;
    }
    const input = cloneJson(envelope.payload, "同步输入");
    const context = {
      senderPlayerId: transportMessage.senderPlayerId,
      session: transportMessage.session,
      members: transportMessage.session.players,
      state: cloneJson(runtime.state, "权威状态"),
      inputId: envelope.inputId,
      inputType: envelope.type === "input.state" ? "state" : "action",
      key: envelope.key || null,
      receivedAt: Date.now(),
    };
    if (envelope.type === "input.state") {
      runtime.inputs.set(`${context.senderPlayerId}:${envelope.key}`, {
        value: input,
        inputId: envelope.inputId,
        receivedAt: context.receivedAt,
      });
    }
    if (runtime.onInput) {
      applySyncState(runtime, await runtime.onInput(input, context));
    }
    return true;
  }

  function applySyncSnapshot(snapshot) {
    if (!snapshot || snapshot.protocolVersion !== 1 || snapshot.full !== true) return;
    if (typeof snapshot.revision !== "number" || typeof snapshot.sequence !== "number") return;
    if (currentSyncSnapshot && snapshot.sequence <= currentSyncSnapshot.sequence &&
        snapshot.timestamp <= currentSyncSnapshot.timestamp) return;
    currentSyncSnapshot = cloneJson(snapshot, "同步快照");
    emit(syncListeners, currentSyncSnapshot);
  }

  function submitSyncEnvelope(type, payload, extra = {}) {
    if (!bootstrap?.session) return Promise.reject(new Error("当前游戏没有多人会话"));
    const inputId = `input-${Date.now()}-${++syncInputSequence}`;
    return post("game.submitAction", {
      __playmeshSync: {
        type,
        inputId,
        payload: cloneJson(payload, "同步输入"),
        clientTime: Date.now(),
        ...extra,
      },
    }).then(() => inputId);
  }

  function submitStateInput(key, value, options = {}) {
    if (typeof key !== "string" || !/^[A-Za-z0-9._-]{1,64}$/.test(key)) {
      return Promise.reject(new Error("连续输入 key 无效"));
    }
    const rateHz = options.rateHz ?? 20;
    if (!Number.isFinite(rateHz) || rateHz < 1 || rateHz > 20) {
      return Promise.reject(new Error("连续输入 rateHz 必须在 1 至 20 之间"));
    }
    const existing = pendingStateInputs.get(key) || { lastSentAt: 0, timer: null };
    existing.value = cloneJson(value, "连续输入");
    existing.rateHz = rateHz;
    pendingStateInputs.set(key, existing);
    const wait = Math.max(0, (1000 / rateHz) - (Date.now() - existing.lastSentAt));
    if (!existing.timer) {
      existing.timer = global.setTimeout(() => {
        existing.timer = null;
        existing.lastSentAt = Date.now();
        void submitSyncEnvelope("input.state", existing.value, { key }).catch(() => {});
      }, wait);
      existing.timer?.unref?.();
    }
    return Promise.resolve(null);
  }

  function startSyncAuthority(options) {
    if (!main.session.isAuthority()) {
      throw new Error("只有 Authority Client 可以启动状态同步");
    }
    if (syncAuthorityRuntime) throw new Error("权威状态同步已经启动");
    if (!options || !("initialState" in options)) {
      throw new Error("initialState 为必填项");
    }
    const tickRate = options.tickRate ?? 10;
    if (!Number.isInteger(tickRate) || tickRate < 1 || tickRate > 20) {
      throw new Error("tickRate 必须是 1 至 20 的整数");
    }
    const runtime = {
      state: cloneJson(options.initialState, "initialState"),
      stateType: typeof options.stateType === "string" && options.stateType
        ? options.stateType : "game",
      onInput: typeof options.onInput === "function" ? options.onInput : null,
      onTick: typeof options.onTick === "function" ? options.onTick : null,
      revision: 0,
      snapshotSequence: 0,
      tick: 0,
      inputs: new Map(),
      lastTickAt: Date.now(),
      tickRunning: false,
      stopped: false,
      timer: null,
    };
    syncAuthorityRuntime = runtime;
    runtime.timer = global.setInterval(() => { void runSyncTick(runtime); }, 1000 / tickRate);
    runtime.timer?.unref?.();
    void publishSyncSnapshot(runtime);
    return {
      getState: () => cloneJson(runtime.state, "权威状态"),
      setState(nextState, publish = true) {
        applySyncState(runtime, nextState);
        return publish ? publishSyncSnapshot(runtime) : Promise.resolve(null);
      },
      publish: (targetPlayerIds) => publishSyncSnapshot(runtime, targetPlayerIds),
      stop() {
        if (runtime.stopped) return;
        runtime.stopped = true;
        global.clearInterval(runtime.timer);
        if (syncAuthorityRuntime === runtime) syncAuthorityRuntime = null;
      },
    };
  }

''',
);
