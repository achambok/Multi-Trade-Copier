package engine

import "math"

// RiskMode constants
const (
	RiskModeProportional = "proportional" // masterLot × (slaveEquity / masterEquity)
	RiskModePercent      = "percent"      // equity-based % risk using SL distance
	RiskModeFixedLot     = "fixed_lot"    // always riskValue lots
	RiskModeFixedDollars = "fixed_dollars" // risk exactly riskValue USD per trade
)

// ComputeLot calculates the slave lot size.
//
//   proportional  — slaveLot = masterLot × (slaveEquity / masterEquity)
//                   Same % risk on both accounts when equity values are correct.
//                   Set slave equity in relay_config.json to actual account balance.
//
//   percent       — slaveLot = (slaveEquity × riskValue/100) / (slDistance × contractSize)
//                   True equity-based % risk. The slave risks exactly riskValue% of its
//                   equity on every trade, regardless of master lot size.
//                   Requires SL to be set on the trade (falls back to proportional if SL=0).
//                   contractSize is per-slave in config (default 100000 for standard forex;
//                   use 100 for XAUUSD, 1000 for indices like US30).
//                   Example: equity=10000, risk=2%, SL=10 pips (0.001), contract=100000
//                     → lots = (10000×0.02) / (0.001×100000) = 200/100 = 2.0 lots
//
//   fixed_lot     — always use exactly riskValue lots regardless of master size.
//                   riskValue=0 → mirror master lot exactly.
//
//   fixed_dollars — risk exactly riskValue USD per trade (approximated via SL distance).
//                   Falls back to proportional if SL=0.
func ComputeLot(masterLot, masterEquity, slaveEquity, entryPrice, sl float64,
	mode string, riskValue, contractSize float64) float64 {

	switch mode {

	case RiskModeFixedLot:
		if riskValue > 0 {
			return roundLot(riskValue)
		}
		return masterLot

	case RiskModePercent:
		if riskValue <= 0 {
			return masterLot
		}
		slDist := math.Abs(entryPrice - sl)
		if slDist > 0 && contractSize > 0 {
			dollarRisk := slaveEquity * riskValue / 100.0
			lot := dollarRisk / (slDist * contractSize)
			return roundLot(lot)
		}
		// No SL set — fall back to proportional
		return ScaleLot(masterLot, masterEquity, slaveEquity)

	case RiskModeFixedDollars:
		if riskValue <= 0 {
			return masterLot
		}
		slDist := math.Abs(entryPrice - sl)
		if slDist > 0 && contractSize > 0 {
			lot := riskValue / (slDist * contractSize)
			return roundLot(lot)
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
	return roundLot(masterLot * (slaveEquity / masterEquity))
}

func roundLot(lot float64) float64 {
	if lot < 0.01 {
		return 0.01
	}
	return math.Round(lot*100) / 100
}
