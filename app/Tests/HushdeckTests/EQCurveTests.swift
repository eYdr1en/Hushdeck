import Foundation
import OmniKit
import Testing
@testable import Hushdeck

/// The EQ graphs must show what the filters actually do, so the maths is checked against the
/// textbook behaviour of each biquad type.
@Suite("EQ curve maths")
struct EQCurveTests {
    func db(_ type: EQFilterType, f0: Double, gain: Double, q: Double, at f: Double) -> Double {
        EQCurve.biquad(type: type, frequency: f0, gainDB: gain, q: q).decibels(at: f)
    }

    @Test func peakingHitsItsGainAtTheCentreAndNothingFarAway() {
        for gain in [-12.0, -3.0, 0.0, 4.5, 12.0] {
            #expect(abs(db(.peaking, f0: 1000, gain: gain, q: 1.414, at: 1000) - gain) < 0.05, "\(gain) dB")
            #expect(abs(db(.peaking, f0: 1000, gain: gain, q: 1.414, at: 20)) < 0.1)
            #expect(abs(db(.peaking, f0: 1000, gain: gain, q: 1.414, at: 20000)) < 0.1)
        }
    }

    @Test func higherQMakesAPeakNarrower() {
        let wide = db(.peaking, f0: 1000, gain: 6, q: 0.5, at: 2000)
        let narrow = db(.peaking, f0: 1000, gain: 6, q: 5, at: 2000)
        #expect(wide > narrow + 2)
        #expect(narrow < 1)
    }

    @Test func lowPassIsMinusThreeAtCutoffAndRollsOffAbove() {
        let atCutoff = db(.lowPass, f0: 1000, gain: 0, q: 0.7071, at: 1000)
        #expect(abs(atCutoff + 3) < 0.15)
        #expect(abs(db(.lowPass, f0: 1000, gain: 0, q: 0.7071, at: 50)) < 0.05)
        // Second order: about −12 dB per octave well above the cutoff.
        let twoOctaves = db(.lowPass, f0: 1000, gain: 0, q: 0.7071, at: 4000)
        let threeOctaves = db(.lowPass, f0: 1000, gain: 0, q: 0.7071, at: 8000)
        #expect(twoOctaves < -20 && twoOctaves > -28)
        #expect(abs((threeOctaves - twoOctaves) + 12) < 1.5)
    }

    @Test func highPassMirrorsLowPass() {
        #expect(abs(db(.highPass, f0: 1000, gain: 0, q: 0.7071, at: 1000) + 3) < 0.15)
        #expect(abs(db(.highPass, f0: 1000, gain: 0, q: 0.7071, at: 16000)) < 0.1)
        #expect(db(.highPass, f0: 1000, gain: 0, q: 0.7071, at: 100) < -35)
    }

    @Test func shelvesReachTheirGainOnTheirSide() {
        #expect(abs(db(.lowShelf, f0: 1000, gain: 6, q: 0.707, at: 20) - 6) < 0.1)
        #expect(abs(db(.lowShelf, f0: 1000, gain: 6, q: 0.707, at: 20000)) < 0.1)
        #expect(abs(db(.lowShelf, f0: 1000, gain: 6, q: 0.707, at: 1000) - 3) < 0.2, "half the gain at the corner")
        #expect(abs(db(.highShelf, f0: 1000, gain: -4, q: 0.707, at: 20000) + 4) < 0.1)
        #expect(abs(db(.highShelf, f0: 1000, gain: -4, q: 0.707, at: 20)) < 0.1)
    }

    @Test func notchIsDeepAtTheCentreAndFlatElsewhere() {
        #expect(db(.notch, f0: 1000, gain: 0, q: 2, at: 1000) < -40)
        #expect(abs(db(.notch, f0: 1000, gain: 0, q: 2, at: 100)) < 0.1)
        #expect(abs(db(.notch, f0: 1000, gain: 0, q: 2, at: 10000)) < 0.1)
    }

    @Test func gainIsIgnoredByPassAndNotchFilters() {
        for type in [EQFilterType.lowPass, .highPass, .notch] {
            #expect(!type.usesGain)
            let a = EQCurve.biquad(type: type, frequency: 500, gainDB: 0, q: 1)
            let b = EQCurve.biquad(type: type, frequency: 500, gainDB: 9, q: 1)
            #expect(a == b, "\(type)")
        }
    }

    @Test func bandsAddInSeriesAndDisabledBandsAreSilent() {
        let a = ParametricBand(frequency: 100, filter: .peaking, gainDB: 3, q: 1)
        let b = ParametricBand(frequency: 3000, filter: .highShelf, gainDB: -2, q: 0.7)
        let off = ParametricBand(frequency: ParametricBand.disabledFrequency, filter: .peaking, gainDB: 12, q: 1)
        for f in [30.0, 100, 700, 3000, 15000] {
            let sum = EQCurve.decibels(of: a, at: f) + EQCurve.decibels(of: b, at: f)
            #expect(abs(EQCurve.decibels(of: [a, b, off], at: f) - sum) < 1e-9)
            #expect(EQCurve.decibels(of: off, at: f) == 0)
        }
        #expect(EQCurve.biquad(for: off) == nil)
        #expect(EQCurve.decibels(of: ParametricBand.flat, at: 1000) == 0)
    }

    @Test func graphicBandsPeakAtTheirCentres() {
        let frequencies = BluetoothEQPreset.bandFrequencies
        var gains = [Double](repeating: 0, count: 10)
        gains[5] = 6 // 1 kHz
        let atCentre = EQCurve.decibels(graphicGainsDB: gains, frequencies: frequencies, at: 1000)
        #expect(abs(atCentre - 6) < 0.05)
        // Neighbours an octave away get part of the boost, two octaves away almost none.
        #expect(EQCurve.decibels(graphicGainsDB: gains, frequencies: frequencies, at: 2000) > 1)
        #expect(EQCurve.decibels(graphicGainsDB: gains, frequencies: frequencies, at: 8000) < 0.5)
        #expect(EQCurve.decibels(graphicGainsDB: [Double](repeating: 0, count: 10), frequencies: frequencies, at: 1000) == 0)
    }

    @Test func logAxisRoundTrips() {
        let samples = EQCurve.logSpacedFrequencies(count: 50)
        #expect(samples.count == 50)
        #expect(abs(samples.first! - 20) < 1e-9)
        #expect(abs(samples.last! - 20000) < 1e-6)
        for f in [20.0, 100, 1000, 12345, 20000] {
            #expect(abs(EQCurve.frequency(atPosition: EQCurve.position(of: f)) - f) < 1e-6)
        }
        #expect(abs(EQCurve.position(of: 632.4555) - 0.5) < 0.001, "geometric middle of 20 Hz–20 kHz")
    }

    @Test func frequencyFormatting() {
        #expect(frequencyLabel(50) == "50")
        #expect(frequencyLabel(1000) == "1k")
        #expect(frequencyLabel(2500).hasSuffix("k"))
    }
}
