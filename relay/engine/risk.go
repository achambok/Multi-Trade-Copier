package engine

import "math"

// RiskMode constants
const (
	RiskModeProportional = "proportional" // masterLot * (slaveEquity / masterEquity)
	RiskModePercent      = "percent"      // slaveEquity * riskValue% / (price * contractSize); simplified to riskValue% of masterLot normalized
	RiskModeFixedLot     = "fixed_lot"    // riskValue = fixed lot size
	RiskModeFixedDollars = "fixed_dollars" // riskValue = $ amount; lot = dollars / (price * pipValue) — approximated
)

// ComputeLot calculates the slave lot size based on the risk mode.
//
//   proportional  – classical equity scaling (default)
//   percent       – riskValue is % of slave equity to risk; approximated as masterLot * (slaveEquity * riskValue/100) / (masterEquity * riskValue/100)
//                   effectively the same as proportional but riskValue acts as a cap/scale on the equity fraction
//   fixed_lot     – every trade uses exactly riskValue lots
//   fixed_dollars – every trade risks exactly riskValue USD; lot = riskValue / masterEquity * masterLot (best-effort without tick data)
func ComputeLot(masterLot, masterEquity, slaveEquity float64, mode string, riskValue float64) float64 {
	switch mode {
	case RiskModeFixedLot:
		if riskValue > 0 {
			return roundLot(riskValue)
		}
		return masterLot

	case RiskModeFixedDollars:
		// Approximate: lot = fixedDollars / masterEquity * masterLot
		// (proportional to master risk without live tick data)
		if masterEquity > 0 && riskValue > 0 {
			return roundLot(masterLot * riskValue / masterEquity)
		}
		return masterLot

	case RiskModePercent:
		// Slave risks riskValue% of its own equity proportionally to master
		if masterEquity > 0 && slaveEquity > 0 && riskValue > 0 {
			slaveFraction := slaveEquity * (riskValue / 100.0)
			masterFraction := masterEquity * (riskValue / 100.0)
			return roundLot(masterLot * slaveFraction / masterFraction)
		}
		return ScaleLot(masterLot, masterEquity, slaveEquity)

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
