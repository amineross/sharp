# Sharp Receiver for High Sierra

Experimental Intel receiver for macOS 10.13.6. Install normal Sharp on the sending Mac.

## Install

Open `Sharp-Receiver-High-Sierra.dmg` and drag **Sharp Receiver** into Applications.
Open it on the iMac, connect Ethernet or Thunderbolt, and choose **Send this Mac** in normal Sharp on the other Mac.
If the sending Mac paused Sharp, click **Resume** in the receiver window. Use the sender to change resolution, mirror/extend mode, cursor appearance and audio output.
If the sender remembers another receiver, use **Forget paired Mac** before connecting.

This test build is ad-hoc signed, without notarization. On High Sierra, Control-click the installed app and choose **Open** if macOS blocks the first launch. Do not disable Gatekeeper. If macOS still reports the trusted download as damaged, remove only this app's quarantine flag:

```sh
xattr -dr com.apple.quarantine '/Applications/Sharp Receiver.app'
```

Allow incoming connections if the macOS firewall asks (TCP 49171, UDP 49172, TCP 49173, Bonjour). The receiver does not need screen-recording or microphone permission.
Quit through the Sharp Receiver menu. **Open report** in that menu reveals its bounded diagnostic log; send that file with the Mac model and macOS version when reporting problems.

## Build

From this directory, run `make installer`. Run `make test` with no other receiver listening locally.

The build compiles the existing engine and audio implementation directly from the parent directory for Intel macOS 10.13. It does not fork the renderer, codec, tile protocol, cursor renderer or audio playback. `ReceiverApp.m` supplies an AppKit window and the same JSON control protocol using High Sierra-compatible sockets and Bonjour.

The normal sender remains unchanged. Its macOS requirements still apply, including macOS 14.2+ for sending system audio.

Compilation and tests on newer macOS do not establish High Sierra runtime support or 2011 iMac performance. Treat this as a test build until validated on that hardware.

By [Amine Rostane](https://aminerostane.com). GPL-3.0; see `../LICENSE`.
