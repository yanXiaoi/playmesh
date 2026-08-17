part of '../../sdk_feature_registry.dart';

const gameSyncSdkSource = SdkSourceFragment(
  id: 'game.sync',
  target: SdkSourceTarget.game,
  order: 40,
  typeScript: r'''  let syncSnapshotSequence = 0;

  function cloneJson(value, label) {
    let encoded;
    try {
      encoded = JSON.stringify(value);
    } catch (error) {
      throw new Error(`${label} 必须可 JSON 序列化: ${error.message || error}`);
    }
    if (encoded === undefined) throw new Error(`${label} 不能是 undefined`);
    return JSON.parse(encoded);
  }

  function canonicalJson(value) {
    if (value === null || typeof value !== "object") return JSON.stringify(value);
    if (Array.isArray(value)) {
      return `[${value.map((entry) => canonicalJson(entry)).join(",")}]`;
    }
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${canonicalJson(value[key])}`
    ).join(",")}}`;
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
    const encoded = JSON.stringify(normalized);
    const fingerprint = canonicalJson(normalized);
    if (fingerprint === runtime.stateFingerprint) return false;
    runtime.state = normalized;
    runtime.stateJson = encoded;
    runtime.stateFingerprint = fingerprint;
    runtime.revision += 1;
    return true;
  }

  function syncBroadcastNeeded(runtime) {
    return runtime.reconciliationSequence > runtime.lastBroadcastSequence ||
      runtime.lastBroadcastFingerprint === null ||
      runtime.stateFingerprint !== runtime.lastBroadcastFingerprint ||
      (
        runtime.activeAutoPublish &&
        runtime.activeAutoPublish.snapshot.sequence > runtime.lastBroadcastSequence &&
        runtime.stateFingerprint !== runtime.activeAutoPublish.stateFingerprint
      );
  }

  function settleSyncAutoWaiters(runtime, snapshot, error) {
    const remaining = [];
    for (const waiter of runtime.autoWaiters) {
      if (
        snapshot.sequence < waiter.minimumSequence ||
        snapshot.revision < waiter.minimumRevision
      ) {
        remaining.push(waiter);
      } else if (error) {
        waiter.reject(error);
      } else {
        waiter.resolve(snapshot);
      }
    }
    runtime.autoWaiters = remaining;
  }

  function cancelSyncAutoWaiters(runtime) {
    const waiters = runtime.autoWaiters;
    runtime.autoWaiters = [];
    for (const waiter of waiters) waiter.resolve(null);
  }

  function discardCanceledSyncAutoPublishes(runtime) {
    while (
      runtime.publishQueue[0]?.kind === "auto" &&
      !syncBroadcastNeeded(runtime)
    ) {
      runtime.publishQueue.shift();
      runtime.autoQueued = false;
      runtime.autoAgain = false;
      cancelSyncAutoWaiters(runtime);
    }
  }

  function armSyncPublishQueue(runtime) {
    if (runtime.stopped || runtime.publishRunning || runtime.publishTimer) return;
    discardCanceledSyncAutoPublishes(runtime);
    if (runtime.publishQueue.length === 0) return;
    const wait = Math.max(0, runtime.nextPublishAt - Date.now());
    if (wait === 0) {
      void drainSyncPublishQueue(runtime);
      return;
    }
    runtime.publishTimer = global.setTimeout(() => {
      runtime.publishTimer = null;
      void drainSyncPublishQueue(runtime);
    }, Math.ceil(wait));
    runtime.publishTimer?.unref?.();
  }

  function queueAutomaticSyncPublish(runtime) {
    if (runtime.stopped) return;
    if (!syncBroadcastNeeded(runtime)) {
      runtime.autoAgain = false;
      cancelSyncAutoWaiters(runtime);
      return;
    }
    if (runtime.autoQueued) {
      if (runtime.activeAutoPublish) runtime.autoAgain = true;
      return;
    }
    runtime.autoQueued = true;
    const task = { kind: "auto", targetPlayerIds: null };
    runtime.publishQueue.push(task);
    armSyncPublishQueue(runtime);
  }

  function scheduleSyncChangeWindow(runtime) {
    if (
      runtime.stopped || runtime.onTick || runtime.changeTimer ||
      (runtime.autoQueued && !runtime.activeAutoPublish)
    ) return;
    runtime.changeTimer = global.setTimeout(() => {
      runtime.changeTimer = null;
      queueAutomaticSyncPublish(runtime);
    }, runtime.publishIntervalMs);
    runtime.changeTimer?.unref?.();
  }

  function noteSyncStateChanged(runtime) {
    if (!runtime.onTick) scheduleSyncChangeWindow(runtime);
  }

  function waitForAutomaticSyncPublish(runtime) {
    if (runtime.stopped || !syncBroadcastNeeded(runtime)) {
      return Promise.resolve(null);
    }
    let resolve;
    let reject;
    const promise = new Promise((resolvePromise, rejectPromise) => {
      resolve = resolvePromise;
      reject = rejectPromise;
    });
    runtime.autoWaiters.push({
      minimumSequence: syncSnapshotSequence + 1,
      minimumRevision: runtime.revision,
      resolve,
      reject,
    });
    if (!runtime.onTick) scheduleSyncChangeWindow(runtime);
    return promise;
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

  function createSyncSnapshot(runtime) {
    const stateJson = runtime.stateJson;
    return {
      stateFingerprint: runtime.stateFingerprint,
      snapshot: {
        protocolVersion: 1,
        stateType: runtime.stateType,
        full: true,
        revision: runtime.revision,
        sequence: ++syncSnapshotSequence,
        timestamp: Date.now(),
        sourceTick: runtime.tick,
        state: JSON.parse(stateJson),
      },
    };
  }

  function beginDefaultSyncPublish(runtime, stateFingerprint) {
    runtime.pendingDefaultFingerprints.set(
      stateFingerprint,
      (runtime.pendingDefaultFingerprints.get(stateFingerprint) || 0) + 1,
    );
  }

  function endDefaultSyncPublish(runtime, stateFingerprint) {
    const remaining =
      (runtime.pendingDefaultFingerprints.get(stateFingerprint) || 1) - 1;
    if (remaining > 0) {
      runtime.pendingDefaultFingerprints.set(stateFingerprint, remaining);
    } else {
      runtime.pendingDefaultFingerprints.delete(stateFingerprint);
    }
  }

  function applyLocalSyncSnapshot(snapshot) {
    try {
      applySyncSnapshot(snapshot);
    } catch (error) {
      try {
        emit(lifecycleListeners, { state: "error", error: String(error) });
      } catch (_) {}
    }
  }

  function finishSyncPublish(runtime) {
    if (runtime.stopped) return;
    if (!syncBroadcastNeeded(runtime)) {
      runtime.autoAgain = false;
      if (runtime.changeTimer) {
        global.clearTimeout(runtime.changeTimer);
        runtime.changeTimer = null;
      }
      discardCanceledSyncAutoPublishes(runtime);
      cancelSyncAutoWaiters(runtime);
    } else if (!runtime.onTick && !runtime.changeTimer && !runtime.autoQueued) {
      scheduleSyncChangeWindow(runtime);
    }
    armSyncPublishQueue(runtime);
  }

  function publishSyncSnapshot(runtime, targetPlayerIds) {
    if (runtime.stopped) return Promise.resolve(null);
    const session = bootstrap?.session;
    if (!session) return Promise.resolve(null);
    const normalizedTargets = targetPlayerIds == null
      ? null
      : Array.isArray(targetPlayerIds)
        ? [...targetPlayerIds]
        : targetPlayerIds;
    const defaultAudience = normalizedTargets === null;
    const { snapshot, stateFingerprint } = createSyncSnapshot(runtime);
    if (defaultAudience) {
      beginDefaultSyncPublish(runtime, stateFingerprint);
    } else if (
      stateFingerprint !== runtime.lastBroadcastFingerprint &&
      !runtime.pendingDefaultFingerprints.has(stateFingerprint)
    ) {
      runtime.reconciliationSequence = Math.max(
        runtime.reconciliationSequence,
        snapshot.sequence,
      );
      finishSyncPublish(runtime);
    }

    // 先发起 Bridge 发送，再通知本地 observer，保持重入 publish 的发送顺序与 sequence 一致。
    let sending;
    try {
      sending = post("authority.result", { __playmeshSyncSnapshot: snapshot }, {
        targetPlayerIds: defaultAudience
          ? syncTargetIds(session)
          : normalizedTargets,
      });
    } catch (error) {
      sending = Promise.reject(error);
    }
    applyLocalSyncSnapshot(snapshot);

    return Promise.resolve(sending).then(() => {
      if (!runtime.stopped && defaultAudience) {
        if (snapshot.sequence > runtime.lastBroadcastSequence) {
          runtime.lastBroadcastSequence = snapshot.sequence;
          runtime.lastBroadcastFingerprint = stateFingerprint;
        }
        settleSyncAutoWaiters(runtime, snapshot, null);
        finishSyncPublish(runtime);
      }
      return snapshot;
    }).catch((error) => {
      if (
        !runtime.stopped &&
        defaultAudience &&
        stateFingerprint !== runtime.lastBroadcastFingerprint
      ) {
        runtime.reconciliationSequence = Math.max(
          runtime.reconciliationSequence,
          snapshot.sequence,
        );
        finishSyncPublish(runtime);
      }
      throw error;
    }).finally(() => {
      if (defaultAudience) endDefaultSyncPublish(runtime, stateFingerprint);
    });
  }

  async function drainSyncPublishQueue(runtime) {
    if (runtime.stopped || runtime.publishRunning) return;
    discardCanceledSyncAutoPublishes(runtime);
    if (runtime.nextPublishAt > Date.now()) {
      armSyncPublishQueue(runtime);
      return;
    }
    if (!runtime.publishQueue.shift()) return;
    const session = bootstrap?.session;
    if (!session) {
      runtime.autoQueued = false;
      cancelSyncAutoWaiters(runtime);
      armSyncPublishQueue(runtime);
      return;
    }
    const { snapshot, stateFingerprint } = createSyncSnapshot(runtime);
    runtime.publishRunning = true;
    runtime.nextPublishAt = snapshot.timestamp + runtime.publishIntervalMs;
    runtime.activeAutoPublish = { snapshot, stateFingerprint };
    beginDefaultSyncPublish(runtime, stateFingerprint);

    let sending;
    try {
      sending = post("authority.result", { __playmeshSyncSnapshot: snapshot }, {
        targetPlayerIds: syncTargetIds(session),
      });
    } catch (error) {
      sending = Promise.reject(error);
    }
    applyLocalSyncSnapshot(snapshot);

    try {
      await sending;
      if (snapshot.sequence > runtime.lastBroadcastSequence) {
        runtime.lastBroadcastSequence = snapshot.sequence;
        runtime.lastBroadcastFingerprint = stateFingerprint;
      }
      settleSyncAutoWaiters(runtime, snapshot, null);
    } catch (error) {
      if (stateFingerprint !== runtime.lastBroadcastFingerprint) {
        runtime.reconciliationSequence = Math.max(
          runtime.reconciliationSequence,
          snapshot.sequence,
        );
      }
      settleSyncAutoWaiters(runtime, snapshot, error);
      try {
        emit(lifecycleListeners, { state: "error", error: String(error) });
      } catch (_) {}
    } finally {
      endDefaultSyncPublish(runtime, stateFingerprint);
      runtime.publishRunning = false;
      runtime.activeAutoPublish = null;
      runtime.autoQueued = false;
      if (runtime.stopped) {
        cancelSyncAutoWaiters(runtime);
        return;
      }
      if (runtime.autoAgain) {
        runtime.autoAgain = false;
        queueAutomaticSyncPublish(runtime);
      }
      finishSyncPublish(runtime);
    }
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
        if (runtime.stopped) return;
        if (applySyncState(runtime, next)) noteSyncStateChanged(runtime);
      }
    } catch (error) {
      try {
        emit(lifecycleListeners, { state: "error", error: String(error) });
      } catch (_) {}
    } finally {
      runtime.tickRunning = false;
      if (!runtime.stopped) queueAutomaticSyncPublish(runtime);
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
      const next = await runtime.onInput(input, context);
      if (runtime.stopped) return true;
      if (applySyncState(runtime, next)) {
        noteSyncStateChanged(runtime);
      }
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
      stateJson: null,
      stateFingerprint: null,
      revision: 0,
      tick: 0,
      inputs: new Map(),
      lastTickAt: Date.now(),
      tickRunning: false,
      stopped: false,
      timer: null,
      publishIntervalMs: 1000 / tickRate,
      publishQueue: [],
      publishRunning: false,
      publishTimer: null,
      changeTimer: null,
      nextPublishAt: 0,
      activeAutoPublish: null,
      autoQueued: false,
      autoAgain: false,
      autoWaiters: [],
      lastBroadcastSequence: 0,
      lastBroadcastFingerprint: null,
      reconciliationSequence: 0,
      pendingDefaultFingerprints: new Map(),
    };
    runtime.stateJson = JSON.stringify(runtime.state);
    runtime.stateFingerprint = canonicalJson(runtime.state);
    syncAuthorityRuntime = runtime;
    if (runtime.onTick) {
      runtime.timer = global.setInterval(
        () => { void runSyncTick(runtime); },
        runtime.publishIntervalMs,
      );
      runtime.timer?.unref?.();
    }
    void publishSyncSnapshot(runtime).catch((error) => {
      emit(lifecycleListeners, { state: "error", error: String(error) });
    });
    return {
      getState: () => cloneJson(runtime.state, "权威状态"),
      setState(nextState, publish = true) {
        if (applySyncState(runtime, nextState)) noteSyncStateChanged(runtime);
        return publish
          ? waitForAutomaticSyncPublish(runtime)
          : Promise.resolve(null);
      },
      publish(stateOrTargetPlayerIds, targetPlayerIds) {
        const legacyTargets =
          arguments.length === 0 ||
          stateOrTargetPlayerIds === undefined ||
          (
            Array.isArray(stateOrTargetPlayerIds) &&
            stateOrTargetPlayerIds.every((value) => typeof value === "string")
          );
        const hasState = arguments.length >= 2 || !legacyTargets;
        if (runtime.stopped) return Promise.resolve(null);
        if (hasState && applySyncState(runtime, stateOrTargetPlayerIds)) {
          noteSyncStateChanged(runtime);
        }
        return publishSyncSnapshot(
          runtime,
          hasState ? targetPlayerIds : stateOrTargetPlayerIds,
        );
      },
      stop() {
        if (runtime.stopped) return;
        runtime.stopped = true;
        global.clearInterval(runtime.timer);
        if (runtime.publishTimer) global.clearTimeout(runtime.publishTimer);
        if (runtime.changeTimer) global.clearTimeout(runtime.changeTimer);
        runtime.publishTimer = null;
        runtime.changeTimer = null;
        const active = runtime.activeAutoPublish;
        const remainingWaiters = [];
        for (const waiter of runtime.autoWaiters) {
          if (
            active &&
            active.snapshot.sequence >= waiter.minimumSequence &&
            active.snapshot.revision >= waiter.minimumRevision
          ) {
            remainingWaiters.push(waiter);
          } else {
            waiter.resolve(null);
          }
        }
        runtime.autoWaiters = remainingWaiters;
        runtime.publishQueue = [];
        runtime.autoQueued = active !== null;
        runtime.autoAgain = false;
        if (syncAuthorityRuntime === runtime) syncAuthorityRuntime = null;
      },
    };
  }

''',
);
