"""Exercise the real app/helper through the stock sender's JSON protocol."""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parent
APP = ROOT / 'build/Sharp Receiver.app/Contents/MacOS/SharpReceiverApp'
LOG = Path.home() / 'Library/Application Support/Sharp Receiver/Receiver.log'


def connect():
    deadline = time.monotonic() + 8
    while True:
        try:
            s = socket.create_connection(('127.0.0.1', 49171), timeout=2)
            s.settimeout(12)
            return s, s.makefile('rb')
        except OSError:
            if time.monotonic() > deadline:
                raise
            time.sleep(.1)


def send(s, command, **fields):
    message = dict(command=command, peerID='test-sender', peerName='Test Mac', **fields)
    s.sendall((json.dumps(message) + '\n').encode())


def receive(s, stream, command):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        line = stream.readline()
        assert line, f'connection closed while waiting for {command}'
        m = json.loads(line)
        if m['command'] == 'ping':
            send(s, 'ping')
        elif m['command'] == command:
            return m
    raise AssertionError(f'no {command}')


probe = socket.socket()
try:
    probe.bind(('127.0.0.1', 49171))
finally:
    probe.close()
proc = subprocess.Popen([str(APP)], env={**os.environ, 'SHARP_RECEIVER_TEST_LOOPBACK': '1'})
try:
    s, stream = connect()
    assert receive(s, stream, 'display')['audioSupported']
    # Invalid resolution must not allocate a helper.
    send(s, 'start', width=999999, height=999999)
    receive(s, stream, 'error')
    # Fragmented framing must work with the ordinary start handshake.
    packet = (json.dumps(dict(command='hello', peerID='test-sender', peerName='Test Mac'))+'\n').encode()
    s.sendall(packet[:7]); s.sendall(packet[7:])
    send(s, 'start', width=1280, height=720, cursorScale=1.2, cursorHue=.2)
    assert receive(s, stream, 'ready')['receiverIP'] == '127.0.0.1'
    send(s, 'cursor-style', cursorScale=.8, cursorHue=1)
    # The sender's screens sleeping and waking must keep the session.
    send(s, 'display-sleep'); send(s, 'display-wake')
    # Exercise unchanged production audio with actual silent PCM playback.
    token = str(uuid.uuid4())
    send(s, 'audio-start', audioToken=token)
    assert receive(s, stream, 'audio-ready')['audioToken'] == token
    with socket.create_connection(('127.0.0.1', 49173), timeout=3) as audio:
        audio.sendall(b'SAA1' + struct.pack('!I', 48000) + token.encode() + bytes(4))
        assert audio.recv(1) == b'R'
        for _ in range(15):
            audio.sendall(struct.pack('!I', 512) + bytes(512*8))
            time.sleep(.01)
        assert audio.recv(1) == b'A'
    send(s, 'audio-stop')
    # Restart/resolution change; stop must cancel a pending start.
    send(s, 'start', width=960, height=540)
    receive(s, stream, 'ready')
    send(s, 'start', width=1280, height=720)
    send(s, 'stop', sharingEnabled=False)
    time.sleep(2.5)
    send(s, 'resume', sharingEnabled=True)
    send(s, 'start', width=960, height=540)
    receive(s, stream, 'ready')
    send(s, 'sleeping')
    stream.close(); s.close()
    time.sleep(.3)
    s, stream = connect()
    receive(s, stream, 'display')
    # Malformed field types cannot crash the process.
    s.sendall(b'{"command":123,"peerID":[],"peerName":{}}\n')
    assert stream.readline() == b''
    stream.close(); s.close()
    time.sleep(.2)
    assert proc.poll() is None
    s, stream = connect()
    receive(s, stream, 'display')
    # Missing heartbeats must close the session.
    s.settimeout(7)
    while stream.readline():
        pass
    stream.close(); s.close()
    log = LOG.read_text()
    assert 'Audio active' in log
    assert 'Disconnected: no reply' in log, 'disconnects must record their reason'
    print('PASS: discovery payload, framing, validation, helper startup/restart, cursor, display sleep/wake, audio, stop, peer sleep, reconnect, heartbeat timeout with reason')
finally:
    subprocess.run(['osascript', '-e', 'tell application id "sh.sharp.high-sierra-receiver" to quit'], capture_output=True)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.terminate(); proc.wait(timeout=5)
