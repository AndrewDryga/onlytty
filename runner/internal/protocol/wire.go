package protocol

import (
	"encoding/binary"
	"errors"
)

// Message kinds. Low byte space is runner→viewer, high is viewer→runner; see
// PROTOCOL.md. The numbers are part of the contract and must not change.
const (
	KindHello   byte = 0x01 // runner→viewer: baseline seq + initial size
	KindOutput  byte = 0x02 // runner→viewer: raw PTY output
	KindExit    byte = 0x03 // runner→viewer: command exit code
	KindControl byte = 0x04 // runner→viewer: control state (read-only / granted / taken)

	KindInput   byte = 0x10 // viewer→runner: raw keystrokes
	KindResize  byte = 0x11 // viewer→runner: terminal size
	KindCtrlReq byte = 0x12 // viewer→runner: request control
	KindCtrlRel byte = 0x13 // viewer→runner: release control
)

// Control states carried by KindControl.
const (
	ControlReadOnly byte = 0
	ControlGranted  byte = 1
	ControlTaken    byte = 2
)

var errShortPayload = errors.New("protocol: payload too short")

var (
	viewerPayloadMagic = []byte("OVP1")
	relayViewerMagic   = []byte("OTV1")
)

// EncodeHello builds a HELLO payload: the input-seq baseline the viewer must start
// at, plus the current terminal size.
func EncodeHello(baseline uint64, cols, rows uint16) []byte {
	b := make([]byte, 12)
	binary.BigEndian.PutUint64(b[0:8], baseline)
	binary.BigEndian.PutUint16(b[8:10], cols)
	binary.BigEndian.PutUint16(b[10:12], rows)
	return b
}

// DecodeHello parses a HELLO payload.
func DecodeHello(b []byte) (baseline uint64, cols, rows uint16, err error) {
	if len(b) < 12 {
		return 0, 0, 0, errShortPayload
	}
	return binary.BigEndian.Uint64(b[0:8]),
		binary.BigEndian.Uint16(b[8:10]),
		binary.BigEndian.Uint16(b[10:12]), nil
}

// EncodeResize builds a RESIZE payload.
func EncodeResize(cols, rows uint16) []byte {
	b := make([]byte, 4)
	binary.BigEndian.PutUint16(b[0:2], cols)
	binary.BigEndian.PutUint16(b[2:4], rows)
	return b
}

// DecodeResize parses a RESIZE payload.
func DecodeResize(b []byte) (cols, rows uint16, err error) {
	if len(b) < 4 {
		return 0, 0, errShortPayload
	}
	return binary.BigEndian.Uint16(b[0:2]), binary.BigEndian.Uint16(b[2:4]), nil
}

// EncodeExit builds an EXIT payload.
func EncodeExit(code int32) []byte {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, uint32(code))
	return b
}

// DecodeExit parses an EXIT payload.
func DecodeExit(b []byte) (int32, error) {
	if len(b) < 4 {
		return 0, errShortPayload
	}
	return int32(binary.BigEndian.Uint32(b)), nil
}

// EncodeViewerPayload binds a viewer id to an encrypted viewer→runner payload. The
// relay cannot read this wrapper, but the runner can compare it with the relay's
// plaintext source label to reject re-labeled frames.
func EncodeViewerPayload(viewerID string, payload []byte) []byte {
	if viewerID == "" {
		return payload
	}
	if len(viewerID) > 255 {
		viewerID = viewerID[:255]
	}
	b := make([]byte, len(viewerPayloadMagic)+1+len(viewerID)+len(payload))
	copy(b, viewerPayloadMagic)
	b[len(viewerPayloadMagic)] = byte(len(viewerID))
	copy(b[len(viewerPayloadMagic)+1:], viewerID)
	copy(b[len(viewerPayloadMagic)+1+len(viewerID):], payload)
	return b
}

// DecodeViewerPayload unwraps EncodeViewerPayload. Legacy payloads without the magic
// are returned as viewer id "" and the original payload.
func DecodeViewerPayload(b []byte) (viewerID string, payload []byte, err error) {
	if len(b) < len(viewerPayloadMagic) || string(b[:len(viewerPayloadMagic)]) != string(viewerPayloadMagic) {
		return "", b, nil
	}
	if len(b) < len(viewerPayloadMagic)+1 {
		return "", nil, errShortPayload
	}
	n := int(b[len(viewerPayloadMagic)])
	start := len(viewerPayloadMagic) + 1
	if len(b) < start+n {
		return "", nil, errShortPayload
	}
	return string(b[start : start+n]), b[start+n:], nil
}

// EncodeRelayViewerFrame labels an opaque encrypted viewer→runner frame with the
// relay-assigned viewer id. It carries metadata only; terminal bytes remain inside
// the sealed frame.
func EncodeRelayViewerFrame(viewerID string, sealedFrame []byte) []byte {
	if viewerID == "" {
		return sealedFrame
	}
	if len(viewerID) > 255 {
		viewerID = viewerID[:255]
	}
	b := make([]byte, len(relayViewerMagic)+1+len(viewerID)+len(sealedFrame))
	copy(b, relayViewerMagic)
	b[len(relayViewerMagic)] = byte(len(viewerID))
	copy(b[len(relayViewerMagic)+1:], viewerID)
	copy(b[len(relayViewerMagic)+1+len(viewerID):], sealedFrame)
	return b
}

// DecodeRelayViewerFrame unwraps EncodeRelayViewerFrame. Raw legacy frames are
// returned with viewer id "" and the original frame.
func DecodeRelayViewerFrame(b []byte) (viewerID string, sealedFrame []byte, err error) {
	if len(b) < len(relayViewerMagic) || string(b[:len(relayViewerMagic)]) != string(relayViewerMagic) {
		return "", b, nil
	}
	if len(b) < len(relayViewerMagic)+1 {
		return "", nil, errShortPayload
	}
	n := int(b[len(relayViewerMagic)])
	start := len(relayViewerMagic) + 1
	if len(b) < start+n {
		return "", nil, errShortPayload
	}
	return string(b[start : start+n]), b[start+n:], nil
}
