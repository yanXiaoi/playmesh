package session

import (
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	binaryProtocolVersion byte = 1
	binaryAuthorityID          = "authority"

	binaryOpCreate   byte = 0x01
	binaryOpJoin     byte = 0x02
	binaryOpClose    byte = 0x03
	binaryOpSend     byte = 0x04
	binaryOpDecision byte = 0x05

	binaryOpResponse byte = 0x81
	binaryOpDelivery byte = 0x82
	binaryOpReview   byte = 0x83
	binaryOpClosed   byte = 0x84

	binaryModeAuthority byte = 1
	binaryModeRelay     byte = 2

	binaryFlagLatest          byte = 1
	binaryFlagMultipleTargets byte = 2
	binaryFlagBroadcast       byte = 4
	maxBinaryTargets               = 1024

	binaryDecisionPass    byte = 1
	binaryDecisionReplace byte = 2
	binaryDecisionReject  byte = 3

	binaryStatusOK         byte = 0
	binaryStatusError      byte = 1
	binaryStatusSuperseded byte = 2

	binaryChannelIDBytes = 16
)

var (
	errBinaryFrameTooShort       = errors.New("二进制帧长度不足")
	errBinaryProtocolVersion     = errors.New("二进制协议版本不受支持")
	errBinaryUnknownOperation    = errors.New("未知二进制操作")
	errBinaryInvalidMode         = errors.New("二进制 Channel mode 无效")
	errBinaryInvalidTarget       = errors.New("二进制目标玩家无效")
	errBinaryInvalidDecision     = errors.New("Authority 二进制审核结果无效")
	errBinaryInvalidChannelToken = errors.New("二进制 Channel ID 无效")
)

type binaryChannelID [binaryChannelIDBytes]byte

func (id binaryChannelID) String() string {
	return base64.RawURLEncoding.EncodeToString(id[:])
}

func parseBinaryChannelID(value string) (binaryChannelID, error) {
	var id binaryChannelID
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil || len(decoded) != len(id) {
		return id, errBinaryInvalidChannelToken
	}
	copy(id[:], decoded)
	return id, nil
}

type binaryClientFrame struct {
	operation    byte
	requestID    uint32
	reviewID     uint64
	mode         byte
	channelID    binaryChannelID
	flags        byte
	targetIDs    []string
	decision     byte
	payload      []byte
	errorMessage string
}

func decodeBinaryClientFrame(data []byte) (binaryClientFrame, error) {
	var frame binaryClientFrame
	if len(data) < 2 {
		return frame, errBinaryFrameTooShort
	}
	if data[0] != binaryProtocolVersion {
		return frame, errBinaryProtocolVersion
	}
	frame.operation = data[1]
	switch frame.operation {
	case binaryOpCreate:
		if len(data) != 7 {
			return frame, errBinaryFrameTooShort
		}
		frame.requestID = binary.BigEndian.Uint32(data[2:6])
		frame.mode = data[6]
		if frame.mode != binaryModeAuthority && frame.mode != binaryModeRelay {
			return frame, errBinaryInvalidMode
		}
	case binaryOpJoin, binaryOpClose:
		if len(data) != 22 {
			return frame, errBinaryFrameTooShort
		}
		frame.requestID = binary.BigEndian.Uint32(data[2:6])
		copy(frame.channelID[:], data[6:22])
	case binaryOpSend:
		if len(data) < 25 {
			return frame, errBinaryFrameTooShort
		}
		frame.requestID = binary.BigEndian.Uint32(data[2:6])
		copy(frame.channelID[:], data[6:22])
		frame.flags = data[22]
		offset := 25
		targetField := int(binary.BigEndian.Uint16(data[23:25]))
		if frame.flags&binaryFlagBroadcast != 0 {
			if frame.flags&binaryFlagMultipleTargets != 0 || targetField != 0 {
				return frame, errBinaryInvalidTarget
			}
		} else if frame.flags&binaryFlagMultipleTargets == 0 {
			if targetField == 0 || len(data) < offset+targetField {
				return frame, errBinaryInvalidTarget
			}
			frame.targetIDs = []string{string(data[offset : offset+targetField])}
			offset += targetField
		} else {
			if targetField == 0 || targetField > maxBinaryTargets {
				return frame, errBinaryInvalidTarget
			}
			frame.targetIDs = make([]string, 0, targetField)
			for range targetField {
				if len(data) < offset+2 {
					return frame, errBinaryInvalidTarget
				}
				targetLength := int(binary.BigEndian.Uint16(data[offset : offset+2]))
				offset += 2
				if targetLength == 0 || len(data) < offset+targetLength {
					return frame, errBinaryInvalidTarget
				}
				frame.targetIDs = append(
					frame.targetIDs,
					string(data[offset:offset+targetLength]),
				)
				offset += targetLength
			}
		}
		frame.payload = data[offset:]
	case binaryOpDecision:
		if len(data) < 11 {
			return frame, errBinaryFrameTooShort
		}
		frame.reviewID = binary.BigEndian.Uint64(data[2:10])
		frame.decision = data[10]
		switch frame.decision {
		case binaryDecisionPass:
			if len(data) != 11 {
				return frame, errBinaryInvalidDecision
			}
		case binaryDecisionReplace:
			frame.payload = data[11:]
		case binaryDecisionReject:
			frame.errorMessage = string(data[11:])
		default:
			return frame, errBinaryInvalidDecision
		}
	default:
		return frame, errBinaryUnknownOperation
	}
	return frame, nil
}

func encodeBinaryResponse(
	requestID uint32,
	status byte,
	mode byte,
	channelID binaryChannelID,
	message string,
) []byte {
	size := 7
	if status == binaryStatusOK && mode != 0 {
		size += 1 + binaryChannelIDBytes
	} else if message != "" {
		size += len(message)
	}
	data := make([]byte, size)
	data[0], data[1] = binaryProtocolVersion, binaryOpResponse
	binary.BigEndian.PutUint32(data[2:6], requestID)
	data[6] = status
	if status == binaryStatusOK && mode != 0 {
		data[7] = mode
		copy(data[8:24], channelID[:])
	} else if message != "" {
		copy(data[7:], message)
	}
	return data
}

func encodeBinaryDelivery(
	channelID binaryChannelID,
	flags byte,
	senderID string,
	payload []byte,
) ([]byte, error) {
	if len(senderID) == 0 || len(senderID) > 0xffff {
		return nil, errBinaryInvalidTarget
	}
	data := make([]byte, 21+len(senderID)+len(payload))
	data[0], data[1] = binaryProtocolVersion, binaryOpDelivery
	copy(data[2:18], channelID[:])
	data[18] = flags
	binary.BigEndian.PutUint16(data[19:21], uint16(len(senderID)))
	copy(data[21:21+len(senderID)], senderID)
	copy(data[21+len(senderID):], payload)
	return data, nil
}

func encodeBinaryReview(
	reviewID uint64,
	channelID binaryChannelID,
	flags byte,
	senderID string,
	targetIDs []string,
	payload []byte,
) ([]byte, error) {
	if len(senderID) == 0 || len(senderID) > 0xffff ||
		len(targetIDs) == 0 || len(targetIDs) > maxBinaryTargets {
		return nil, errBinaryInvalidTarget
	}
	targetBytes := 0
	for _, targetID := range targetIDs {
		if len(targetID) == 0 || len(targetID) > 0xffff {
			return nil, errBinaryInvalidTarget
		}
		targetBytes += len(targetID)
		if len(targetIDs) > 1 {
			targetBytes += 2
		}
	}
	if len(targetIDs) > 1 {
		flags |= binaryFlagMultipleTargets
	} else {
		flags &^= binaryFlagMultipleTargets
	}
	data := make([]byte, 31+len(senderID)+targetBytes+len(payload))
	data[0], data[1] = binaryProtocolVersion, binaryOpReview
	binary.BigEndian.PutUint64(data[2:10], reviewID)
	copy(data[10:26], channelID[:])
	data[26] = flags
	binary.BigEndian.PutUint16(data[27:29], uint16(len(senderID)))
	if len(targetIDs) > 1 {
		binary.BigEndian.PutUint16(data[29:31], uint16(len(targetIDs)))
	} else {
		binary.BigEndian.PutUint16(data[29:31], uint16(len(targetIDs[0])))
	}
	offset := 31
	copy(data[offset:offset+len(senderID)], senderID)
	offset += len(senderID)
	for _, targetID := range targetIDs {
		if len(targetIDs) > 1 {
			binary.BigEndian.PutUint16(data[offset:offset+2], uint16(len(targetID)))
			offset += 2
		}
		copy(data[offset:offset+len(targetID)], targetID)
		offset += len(targetID)
	}
	copy(data[offset:], payload)
	return data, nil
}

func encodeBinaryClosed(channelID binaryChannelID, reason string) []byte {
	data := make([]byte, 18+len(reason))
	data[0], data[1] = binaryProtocolVersion, binaryOpClosed
	copy(data[2:18], channelID[:])
	copy(data[18:], reason)
	return data
}

func validateBinaryFlags(flags byte) error {
	if flags & ^(binaryFlagLatest|binaryFlagMultipleTargets|binaryFlagBroadcast) != 0 {
		return fmt.Errorf("二进制发送 flags 无效: %d", flags)
	}
	return nil
}
