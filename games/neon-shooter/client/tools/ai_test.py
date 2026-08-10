#!/usr/bin/env python3
"""AI Test Client for the Godot platform-shooter port (Phase B, issue #12).

Connects to the game's AI test server (TCP, line-delimited JSON) and drives the
live client the same way a human would — but through the net client's outgoing
layer. The Godot game must be running in a debug build (or with
PS_AI_TEST_SERVER=1) AND connected to a Node authoritative server.

Usage:
  # terminal 1 — authoritative server (short draw phase for fast tests)
  cd netgame && PORT=2567 DRAW_TIME=3 BATTLE_TIME=30 node server.js

  # terminal 2 — Godot client (debug), pointed at that server
  godot --path godot -- --server=ws://127.0.0.1:2567

  # terminal 3 — this script
  python3 godot/tools/ai_test.py
"""
import json
import os
import socket
import sys
import time

HOST = "127.0.0.1"
PORT = int(os.environ.get("PS_AI_TEST_PORT", "7070"))
TIMEOUT = 8.0


class Client:
    def __init__(self, host=HOST, port=PORT):
        self.s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.s.settimeout(TIMEOUT)
        self.s.connect((host, port))
        self.buf = b""

    def cmd(self, command, **kwargs):
        kwargs["command"] = command
        self.s.sendall((json.dumps(kwargs) + "\n").encode())
        while b"\n" not in self.buf:
            chunk = self.s.recv(4096)
            if not chunk:
                raise ConnectionError("server closed")
            self.buf += chunk
        line, _, self.buf = self.buf.partition(b"\n")
        return json.loads(line.decode())

    def wait_phase(self, phase, timeout=40.0):
        """Poll until the arena reaches `phase` (or timeout)."""
        end = time.time() + timeout
        st = self.cmd("get_state")
        while st.get("phase") != phase and time.time() < end:
            st = self.cmd("wait_frames", frames=10)
        return st


def main():
    try:
        c = Client()
    except OSError as e:
        print(f"[FAIL] cannot connect to {HOST}:{PORT} — is the Godot debug client running? ({e})")
        return 1
    print(f"[ok] connected to {HOST}:{PORT}")

    st = c.cmd("get_state")
    if not st.get("open"):
        print("[FAIL] game client is not connected to a Node server")
        return 1
    print(f"[ok] client online: id={st['id']} arena={st['arena']} role={st['role']} phase={st['phase']}")

    c.cmd("take_control")

    # ── draw phase: paint a platform under the player, verify terrain appears ──
    st = c.cmd("get_state")
    if st["phase"] == "draw":
        px, py = st["player"]["x"], st["player"]["y"]
        before = c.cmd("solid_at", x=px, y=py + 40)["solid"]
        # draw a horizontal slab ~40px below the player
        c.cmd("draw_stroke", x0=px - 60, y0=py + 40, x1=px + 60, y1=py + 40)
        after = c.cmd("solid_at", x=px, y=py + 40)["solid"]
        print(f"[test] draw terrain: solid_below {before} -> {after}", "PASS" if after and not before else "WARN")

    # ── wait for battle ──
    st = c.wait_phase("battle")
    if st["phase"] != "battle":
        print(f"[WARN] never reached battle phase (phase={st['phase']}); skipping combat test")
        c.cmd("release_control")
        return 0
    print(f"[ok] battle started (timeLeft={st['timeLeft']:.0f})")

    # ── movement: hold right, expect x to change ──
    x0 = c.cmd("get_state")["player"]["x"]
    c.cmd("set_input", right=True)
    st = c.cmd("wait_frames", frames=30)
    c.cmd("set_input")  # stop
    x1 = st["player"]["x"]
    moved = abs(x1 - x0) > 1.0
    print(f"[test] move right: x {x0:.1f} -> {x1:.1f}", "PASS" if moved else "FAIL")

    # ── weapon + shoot ──
    c.cmd("set_weapon", w="shotgun")
    st = c.cmd("get_state")
    print(f"[test] switch weapon -> {st['weapon']}", "PASS" if st["weapon"] == "shotgun" else "FAIL")
    p = st["player"]
    c.cmd("shoot", aimX=p["x"] + 100, aimY=p["y"])
    st = c.cmd("wait_frames", frames=4)
    print(f"[test] shoot spawns bullets: {len(st['bullets'])}", "PASS" if st["bullets"] else "WARN")

    c.cmd("release_control")
    print("[done] AI verification finished")
    return 0 if moved else 1


if __name__ == "__main__":
    sys.exit(main())
