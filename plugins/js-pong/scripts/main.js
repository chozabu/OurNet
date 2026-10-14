// Real-time pong between two devices. Invitations travel as live requests
// (`ournet.send`); play travels as datagrams. Whoever invited hosts: it runs
// the ball on a 30 Hz timer and sends the court to the guest each tick; the
// guest sends its paddle. Nothing is stored or synced.
//
// Datagrams are lost at times: each carries the whole state, so the next one
// corrects whatever the last did not deliver.
//
// The JavaScript twin of plugins/pong (Rust), for comparing the two.

const SURFACE = "Pong";
const TICK = 33;
const W = 160;
const H = 100;
const PADDLE = 20;
const WIN = 5;
// Ticks without hearing from the other side before the game is called off.
const LOST = 150;

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const clampPaddle = (y) => clamp(y, PADDLE / 2, H - PADDLE / 2);

class Game {
  constructor(role, peer) {
    this.role = role; // "host", "guest" or "practice"
    this.peer = peer;
    this.ball = [W / 2, H / 2];
    this.speed = [1.6, 0.6];
    // Left (host's) and right (guest's or the computer's) paddles: centres.
    this.paddles = [H / 2, H / 2];
    this.score = [0, 0];
    // Ticks since the other side was last heard.
    this.quiet = 0;
    // Keys held: -1 up, 1 down.
    this.keys = 0;
    this.over = null;
    this.rally = 0;
    this.serve(1);
  }

  serve(toward) {
    this.ball = [W / 2, H / 2];
    const seed = (ournet.now() % 1000) / 1000;
    this.speed = [1.6 * toward, (seed - 0.5) * 1.6];
    this.rally = 0;
  }

  // This side's paddle: the host's is left, the guest's right.
  get mine() {
    return this.role === "guest" ? 1 : 0;
  }

  step() {
    if (this.over !== null) return;
    let x = this.ball[0] + this.speed[0];
    let y = this.ball[1] + this.speed[1];
    if (y < 2 || y > H - 2) {
      this.speed[1] = -this.speed[1];
      y = clamp(y, 2, H - 2);
    }
    const hit = (paddle) => Math.abs(y - paddle) <= PADDLE / 2 + 2;
    if (x <= 7 && this.speed[0] < 0) {
      if (hit(this.paddles[0])) {
        this.bounce(this.paddles[0], y);
        x = 7;
      } else if (x < 0) {
        this.point(1);
        return;
      }
    } else if (x >= W - 7 && this.speed[0] > 0) {
      if (hit(this.paddles[1])) {
        this.bounce(this.paddles[1], y);
        x = W - 7;
      } else if (x > W) {
        this.point(0);
        return;
      }
    }
    this.ball = [x, y];
    if (this.role === "practice") {
      // The computer follows the ball, a little slowly.
      const d = clamp(this.ball[1] - this.paddles[1], -1.1, 1.1);
      this.paddles[1] = clampPaddle(this.paddles[1] + d);
    }
  }

  bounce(paddle, y) {
    this.rally++;
    const faster = 1 + Math.min(this.rally, 12) * 0.04;
    this.speed[0] = -Math.sign(this.speed[0]) * 1.6 * faster;
    // Where it meets the paddle decides the angle.
    this.speed[1] = ((y - paddle) / (PADDLE / 2)) * 1.4;
  }

  point(side) {
    this.score[side]++;
    if (this.score[0] >= WIN || this.score[1] >= WIN) {
      const hostWon = this.score[0] >= WIN;
      const iWon = hostWon === (this.role !== "guest");
      this.over = iWon ? "You won" : "You lost";
    }
    this.serve(side === 0 ? 1 : -1);
  }

  // The court as the host sends it: positions in hundredths.
  encode() {
    const out = new Uint8Array(12);
    const view = new DataView(out.buffer);
    out[0] = 1;
    [this.ball[0], this.ball[1], this.paddles[0], this.paddles[1]].forEach((v, i) =>
      view.setUint16(1 + i * 2, clamp(Math.trunc(v * 100), 0, 65535), true),
    );
    out[9] = this.score[0];
    out[10] = this.score[1];
    out[11] = this.over === null ? 0 : 1;
    return out;
  }

  decode(data) {
    if (data.length < 12 || data[0] !== 1) return;
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const v = (i) => view.getUint16(1 + i * 2, true) / 100;
    this.ball = [v(0), v(1)];
    this.paddles[0] = v(2);
    this.score = [data[9], data[10]];
    if (data[11] === 1 && this.over === null) {
      this.over = this.score[1] >= WIN ? "You won" : "You lost";
    }
  }

  frame() {
    const paddle = (x, y) => ({ op: "rect", x, y: y - PADDLE / 2, w: 3, h: PADDLE, color: 0xffe8f1f2 });
    const cmds = [
      { op: "line", x: W / 2, y: 0, x2: W / 2, y2: H, color: 0x55ffffff, width: 0.5 },
      paddle(3, this.paddles[0]),
      paddle(W - 6, this.paddles[1]),
      { op: "circle", x: this.ball[0], y: this.ball[1], r: 2, color: 0xffffc857 },
    ];
    if (this.over !== null) {
      cmds.push({ op: "text", x: W / 2, y: H / 2, text: this.over, size: 14, color: 0xffffffff });
    }
    return cmds;
  }
}

let game = null;
// Devices that invited this one: [device, person].
let invites = [];
// Devices this one invited.
let invited = [];

function personOf(device) {
  return ournet.contacts().find((c) => c.devices.some((d) => d.id === device))?.person ?? null;
}

function show() {
  if (game) {
    let status = "Live";
    if (game.over !== null) status = game.over;
    else if (game.role === "practice") status = "Practice";
    else if (game.quiet > 30) status = "Waiting for them…";
    ournet.ui.update(SURFACE, {
      mode: "game",
      score: `${game.score[0]}  :  ${game.score[1]}`,
      status,
      frame: game.frame(),
    });
    return;
  }
  const friends = [];
  for (const c of ournet.contacts()) {
    for (const d of c.devices) {
      if (!d.hasPlugin || !d.online) continue;
      friends.push({
        person: c.person,
        device: d.id,
        label: d.name || "A device",
        action: invited.includes(d.id) ? "Invited" : "Challenge",
      });
    }
  }
  ournet.ui.update(SURFACE, {
    mode: "lobby",
    note: "Friends' devices that are online and run Pong.",
    nobody: friends.length === 0 && invites.length === 0,
    friends,
    invites: invites.map(([device, person]) => ({ device, person })),
  });
}

function start(role, peer) {
  game = new Game(role, peer);
  invites = [];
  invited = [];
  ournet.timer.set(1, TICK);
  show();
}

export function onOpen() {
  show();
}

export function onEvent(surface, name, args) {
  const device = typeof args.device === "string" ? args.device : "";
  switch (name) {
    case "practice":
      start("practice", "");
      break;
    case "refresh":
      show();
      break;
    case "challenge":
      if (!device) return;
      ournet.send(device, { t: "invite" });
      invited.push(device);
      show();
      break;
    case "accept":
      if (!device) return;
      ournet.send(device, { t: "accept" });
      start("guest", device);
      break;
    case "leave":
      if (game && game.role !== "practice" && game.over === null) {
        ournet.send(game.peer, { t: "leave" });
      }
      game = null;
      ournet.timer.cancel(1);
      show();
      break;
    case "drag":
      if (game && typeof args.y === "number") game.paddles[game.mine] = clampPaddle(args.y);
      break;
    case "key": {
      if (!game) return;
      const dir = { "Arrow Up": -1, W: -1, "Arrow Down": 1, S: 1 }[args.key] ?? 0;
      if (dir !== 0) game.keys = args.down ? dir : game.keys === dir ? 0 : game.keys;
      break;
    }
  }
}

export function onTimer() {
  const g = game;
  if (!g) return;
  if (g.keys !== 0) g.paddles[g.mine] = clampPaddle(g.paddles[g.mine] + g.keys * 2.2);
  if (g.role === "guest") {
    const out = new Uint8Array(3);
    out[0] = 2;
    new DataView(out.buffer).setUint16(1, clamp(Math.trunc(g.paddles[1] * 100), 0, 65535), true);
    try {
      ournet.datagram(g.peer, out);
    } catch (_) {}
  } else {
    g.step();
    if (g.role === "host") {
      try {
        ournet.datagram(g.peer, g.encode());
      } catch (_) {}
    }
  }
  if (g.role !== "practice") {
    g.quiet++;
    if (g.quiet > LOST && g.over === null) g.over = "Connection lost";
  }
  show();
  if (g.over === null) ournet.timer.set(1, TICK);
}

export function onDatagram(device, data) {
  const g = game;
  if (!g || device !== g.peer || data.length === 0) return;
  g.quiet = 0;
  if (g.role === "host" && data[0] === 2 && data.length >= 3) {
    const y = new DataView(data.buffer, data.byteOffset, data.byteLength).getUint16(1, true) / 100;
    g.paddles[1] = clampPaddle(y);
  } else if (g.role === "guest" && data[0] === 1) {
    g.decode(data);
  }
}

export function onRequest(device, payload) {
  const message = ournet.json(payload);
  switch (message.t) {
    case "invite": {
      const person = personOf(device);
      if (person === null) throw new Error("unknown device");
      if (!invites.some(([d]) => d === device)) {
        invites.push([device, person]);
        ournet.ui.notify("Pong", "A friend wants to play");
      }
      show();
      break;
    }
    case "accept":
      if (!invited.includes(device) || game) throw new Error("not now");
      start("host", device);
      break;
    case "leave":
      if (game && game.peer === device) {
        game.over = "They left";
        show();
      }
      break;
    default:
      throw new Error("not now");
  }
  return {};
}
