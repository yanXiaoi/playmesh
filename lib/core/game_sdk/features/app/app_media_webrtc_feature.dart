part of '../../sdk_feature_registry.dart';

/// WebRTC 的浏览器消费细节与公共 app.media 分离；新增协议只需注册另一个适配片段。
const appMediaWebRtcSdkSource = SdkSourceFragment(
  id: 'app.media.webrtc',
  target: SdkSourceTarget.app,
  order: 23,
  typeScript: r'''
  function waitForAppMediaIceGathering(peer, timeoutMs = 8000) {
    if (peer.iceGatheringState === "complete") return Promise.resolve();
    return new Promise((resolve, reject) => {
      const timer = global.setTimeout(() => {
        cleanup();
        reject(new Error("WebRTC ICE 收集超时"));
      }, timeoutMs);
      const onChange = () => {
        if (peer.iceGatheringState !== "complete") return;
        cleanup();
        resolve();
      };
      const cleanup = () => {
        global.clearTimeout(timer);
        peer.removeEventListener("icegatheringstatechange", onChange);
      };
      peer.addEventListener("icegatheringstatechange", onChange);
    });
  }

  function waitForAppMediaTrack(peer, stream, timeoutMs = 10000) {
    let cancel = () => {};
    const promise = new Promise((resolve, reject) => {
      const timer = global.setTimeout(() => {
        cleanup();
        reject(new Error("WebRTC 媒体轨道建立超时"));
      }, timeoutMs);
      const onTrack = (event) => {
        if (!stream.getTracks().some((track) => track.id === event.track.id)) {
          stream.addTrack(event.track);
        }
        cleanup();
        resolve();
      };
      const cleanup = () => {
        global.clearTimeout(timer);
        peer.removeEventListener("track", onTrack);
      };
      cancel = cleanup;
      peer.addEventListener("track", onTrack);
    });
    return { promise, cancel: () => cancel() };
  }

  registerAppMediaAdapter("webrtc", {
    async open(source, options) {
      if (typeof global.RTCPeerConnection !== "function" ||
          typeof global.MediaStream !== "function") {
        throw new Error("当前 WebView 不支持 WebRTC MediaStream");
      }
      const peer = new global.RTCPeerConnection({ iceServers: [] });
      const stream = new global.MediaStream();
      let hostSessionId = null;
      let closed = false;
      let state = "opening";
      const trackWait = waitForAppMediaTrack(peer, stream);
      const abort = () => {
        peer.close();
      };
      options.signal?.addEventListener("abort", abort, { once: true });
      try {
        if (source.kind === "video" || source.kind === "audio-video") {
          peer.addTransceiver("video", { direction: "recvonly" });
        }
        if (source.kind === "audio" || source.kind === "audio-video") {
          peer.addTransceiver("audio", { direction: "recvonly" });
        }
        await peer.setLocalDescription(await peer.createOffer());
        await waitForAppMediaIceGathering(peer);
        if (options.signal?.aborted) throw new DOMException("操作已取消", "AbortError");
        const opened = await request("app.media.open", {
          source,
          adapterOptions: {
            offer: {
              type: peer.localDescription.type,
              sdp: peer.localDescription.sdp,
            },
          },
        });
        hostSessionId = opened?.sessionId;
        if (typeof hostSessionId !== "string" || !hostSessionId ||
            opened?.protocol !== "webrtc" ||
            !opened.answer || typeof opened.answer.sdp !== "string") {
          throw new Error("WebRTC 宿主返回了无效应答");
        }
        await peer.setRemoteDescription(opened.answer);
        await trackWait.promise;
        state = "open";
      } catch (error) {
        state = "failed";
        trackWait.cancel();
        peer.close();
        if (hostSessionId) {
          try {
            await request("app.media.close", { sessionId: hostSessionId });
          } catch (_) {}
        }
        throw error;
      } finally {
        options.signal?.removeEventListener("abort", abort);
      }
      return {
        id: hostSessionId,
        stream,
        get state() {
          return state;
        },
        async close(closeOptions = {}) {
          if (closed) return;
          closed = true;
          state = "ended";
          for (const track of stream.getTracks()) track.stop();
          peer.close();
          if (closeOptions.notifyHost !== false) {
            await request("app.media.close", { sessionId: hostSessionId });
          }
        },
      };
    },
  });
''',
);
