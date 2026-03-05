package engine

import "math"

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
