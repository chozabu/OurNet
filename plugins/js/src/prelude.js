// Builds the `ournet` global from the runtime's native `__host`, and
// returns what the runtime calls back into: `reply` for `live.send` answers
// and `timer` for timers the prelude set itself.
(function (host) {
  "use strict";
  delete globalThis.__host;

  // Bytes to send: a Uint8Array as it is, text as UTF-8, else JSON.
  const bytes = (data) =>
    data instanceof Uint8Array
      ? data
      : host.encode(typeof data === "string" ? data : JSON.stringify(data ?? null));

  // Answers to `send`, by request ID.
  const replies = new Map();
  // Timers the prelude set (sleep, setTimeout), by token. Scripts' own
  // tokens (`ournet.timer.set`) stay below 2^32.
  const timers = new Map();
  let nextTimer = 2 ** 32;
  const later = (ms, fire) => {
    const token = nextTimer++;
    timers.set(token, fire);
    host.setTimer(token, Math.max(0, ms | 0));
    return token;
  };

  const text = (...parts) => parts.map((p) => (typeof p === "string" ? p : JSON.stringify(p))).join(" ");

  const ournet = {
    log: (...parts) => host.log(1, text(...parts)),
    debug: (...parts) => host.log(0, text(...parts)),
    warn: (...parts) => host.log(2, text(...parts)),
    error: (...parts) => host.log(3, text(...parts)),

    /** Milliseconds since the epoch. */
    now: () => host.now(),
    /** Resolves after `ms` milliseconds. */
    sleep: (ms) => new Promise((resolve) => later(ms, resolve)),
    /** Calls the script's `onTimer(token)` once, after `ms`; setting a token again moves it. */
    timer: {
      set(token, ms) {
        if (!(token >= 0 && token < 2 ** 32)) throw new RangeError("timer tokens are 0 to 2^32 - 1");
        host.setTimer(token, Math.max(0, ms | 0));
      },
      cancel: (token) => host.cancelTimer(token),
    },

    /** This plugin's private storage on this device. Values are text, bytes or JSON. */
    storage: {
      get(key) {
        const v = host.storageGet(key);
        return v === null ? null : host.decode(v);
      },
      getBytes: (key) => host.storageGet(key),
      getJSON(key) {
        const v = host.storageGet(key);
        if (v === null) return null;
        try {
          return JSON.parse(host.decode(v));
        } catch (_) {
          return null;
        }
      },
      set: (key, value) => host.storageSet(key, bytes(value)),
      setJSON: (key, value) => host.storageSet(key, host.encode(JSON.stringify(value))),
      remove: (key) => host.storageRemove(key),
      keys: (prefix = "") => host.storageKeys(prefix),
    },

    /**
     * Signs, stores and syncs a new object; returns its ID. `to` is
     * "personal", "group", "public" or a list of people.
     */
    publish: (kind, space, to, payload) => host.publish(kind, space, to, JSON.stringify(payload)),
    /**
     * Files attached to this plugin's objects (part of the `objects`
     * grant). `store(name, data)` keeps bytes (or text) as a file and
     * returns a handle; `publish(kind, space, to, payload, file)` publishes
     * like `ournet.publish` with that file attached; `read(id)` returns an
     * object's file as bytes, fetched from friends when needed, and throws
     * when it is not here yet. A `FilePick` widget's `onPicked` brings a
     * handle too.
     */
    files: {
      store: (name, data) => host.fileStore(name, bytes(data)),
      publish: (kind, space, to, payload, file) =>
        host.filePublish(kind, space, to, JSON.stringify(payload), file),
      read: (id) => host.fileRead(id),
    },
    get: (id) => host.get(id),
    /** `{kind, space?, author?, before?: an object from a previous page, limit?}`; newest first. */
    query: (filter) => host.query(filter),
    follow: (space, on = true) => host.follow(space, on),

    me: () => host.me(),
    thisDevice: () => host.thisDevice(),
    contacts: () => host.contacts(),
    groups: () => host.groups(),

    /**
     * Sends a live message to this plugin on `device`. Returns a promise of
     * the reply's bytes (`ournet.text` and `ournet.json` read them), with
     * the request's `id`; `onReply(id, bytes, error)` is called as well.
     */
    send(device, data) {
      const id = host.send(device, bytes(data));
      let settle;
      const reply = new Promise((resolve, reject) => (settle = { resolve, reject }));
      // A script that never awaits it is not told it failed.
      reply.catch(() => {});
      replies.set(id, settle);
      reply.id = id;
      return reply;
    },
    /** One unreliable datagram, at most 1100 bytes; throws if it cannot go at all. */
    datagram: (device, data) => host.datagram(device, bytes(data)),

    tun: {
      open: (address, prefix, routes, mtu) => host.tunOpen(address, prefix, routes, mtu),
      write: (packet) => host.tunWrite(packet),
      close: () => host.tunClose(),
    },

    ui: {
      /** Sets top-level keys of what `surface` shows; null removes one. */
      update: (surface, data) => host.update(surface, data),
      notify: (title, body = "") => host.notify(title, body),
    },

    /** Entry `name` of this plugin's package, as bytes, or null. */
    read: (name) => host.read(name),
    /** UTF-8 bytes as text, and text as UTF-8 bytes. */
    text: (data) => host.decode(data),
    bytes: (text) => host.encode(text),
    /** Bytes (or text) as JSON. */
    json: (data) => JSON.parse(typeof data === "string" ? data : host.decode(data)),
  };
  globalThis.ournet = Object.freeze(ournet);

  globalThis.setTimeout = (fn, ms = 0, ...args) => later(ms, () => fn(...args));
  globalThis.clearTimeout = (token) => {
    if (timers.delete(token)) host.cancelTimer(token);
  };
  globalThis.console = Object.freeze({
    log: ournet.log,
    info: ournet.log,
    debug: ournet.debug,
    warn: ournet.warn,
    error: ournet.error,
  });

  return {
    // Logs an async handler's failure, which would otherwise go unseen.
    watch(promise, name) {
      promise.catch((e) => ournet.error(`${name}: ${e}${e?.stack ? `
${e.stack}` : ""}`));
    },
    reply(id, data, error) {
      const settle = replies.get(id);
      if (!settle) return;
      replies.delete(id);
      if (error === null) settle.resolve(data);
      else settle.reject(new Error(error));
    },
    timer(token) {
      const fire = timers.get(token);
      if (!fire) return token >= 2 ** 32;
      timers.delete(token);
      fire();
      return true;
    },
  };
})(__host);
