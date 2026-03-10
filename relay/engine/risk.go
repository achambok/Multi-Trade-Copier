package engine

import "math"

// RiskMode constants
const (
	RiskModeProportional = "proportional" // masterLot * (slaveEquity / masterEquity)
	RiskModePercent      = "percent"      // masterLot * (riskValue / 100) — lot multiplier
	RiskModeFixedLot     = "fixed_lot"    // always riskValue lots
	RiskModeFixedDollars = "fixed_dollars" // risk exactly riskValue USD per trade (approximated)
)

// ComputeLot calculates the slave lot size based on the risk mode.
//
//   proportional  – slaveLot = masterLot × (slaveEquity / masterEquity)
//                   Equal equity → 1:1 copy. Half equity → half lot.
//
//   percent       – slaveLot = masterLot × (riskValue / 100)
//                   A direct lot multiplier. riskValue=100 → same lot as master.
//                   riskValue=50 → half. riskValue=200 → double.
//                   Example: master trades 1.0 lot, riskValue=2 → slave trades 0.02 lots.
//                   Use riskValue=100 for a 1:1 copy regardless of equity.
//
//   fixed_lot     – every trade uses exactly riskValue lots regardless of master size.
//                   riskValue=0 → mirror master lot exactly.
//
//   fixed_dollars – every trade risks exactly riskValue USD.
//                   Approximated as: lot = (riskValue / masterEquity) × masterLot
func ComputeLot(masterLot, masterEquity, slaveEquity float64, mode string, riskValue float64) float64 {
	switch mode {
	case RiskModeFixedLot:
		if riskValue > 0 {
			return roundLot(riskValue)
		}
		return masterLot

	case RiskModeFixedDollars:
		if masterEquity > 0 && riskValue > 0 {
			return roundLot(masterLot * riskValue / masterEquity)
		}
		return masterLot

	case RiskModePercent:
		// Lot multiplier: riskValue is the percentage of master lot to trade.
		// riskValue=100 → 1:1 copy, riskValue=50 → half, riskValue=200 → double.
		if riskValue > 0 {
			return roundLot(masterLot * riskValue / 100.0)
		}
		return masterLot

	default: // proportional
		return ScaleLot(masterLot, masterEquity, slaveEquity)
	}
}

func ScaleLot(masterLot, masterEquity, slaveEquity float64) float64 {
	if masterEquity <= 0 || slaveEquity <= 0 {
		return masterLot
	}
	scaled := masterLot * (slaveEquity / masterEquity)
	return roundLot(scaled)
}

func roundLot(lot float64) float64 {
	return math.Round(lot*100) / 100
}
