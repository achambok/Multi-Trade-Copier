package engine

import (
	"bytes"
	"encoding/binary"
	"fmt"
)

type TradePayload struct {
	Ticket    int64
	Symbol    [12]byte
	OrderType int32
	Volume    float64
	Price     float64
	SL        float64
	TP        float64
	Magic     int32
	Pad       int32
}

func (p *TradePayload) SymbolString() string {
	n := bytes.IndexByte(p.Symbol[:], 0)
	if n < 0 {
		n = 12
	}
	return string(p.Symbol[:n])
}

func OrderTypeName(t int32) string {
	switch t {
	case 0:
		return "BUY"
	case 1:
		return "SELL"
	case 2:
		return "BUY_LIMIT"
	case 3:
		return "SELL_LIMIT"
	case 4:
		return "BUY_STOP"
	case 5:
		return "SELL_STOP"
	default:
		return fmt.Sprintf("TYPE_%d", t)
	}
}

func DeserializePayload(data []byte) (*TradePayload, error) {
	if len(data) < binary.Size(TradePayload{}) {
		return nil, fmt.Errorf("payload too short: %d bytes", len(data))
	}
	var p TradePayload
	if err := binary.Read(bytes.NewReader(data), binary.LittleEndian, &p); err != nil {
		return nil, fmt.Errorf("deserialize: %w", err)
	}
	return &p, nil
}

func SerializePayload(p *TradePayload) ([]byte, error) {
	buf := new(bytes.Buffer)
	if err := binary.Write(buf, binary.LittleEndian, p); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
