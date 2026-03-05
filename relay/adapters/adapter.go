package adapters

import (
	"trs/relay/engine"
)

type SlaveAdapter interface {
	Name() string
	GetEquity() (float64, error)
	PlaceOrder(p *engine.TradePayload, scaledLot float64, mappedSymbol string) error
}
