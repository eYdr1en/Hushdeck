import Foundation
import OmniKit

/// Frequency-response maths for the EQ graphs. Every curve comes from real second-order
/// (biquad) filters using the Audio EQ Cookbook formulas (R. Bristow-Johnson), evaluated at the
/// device's nominal 48 kHz sample rate, so what the graph shows is what a DSP running those
/// coefficients would do.
enum EQCurve {
    static let sampleRate: Double = 48_000
    static let minimumFrequency: Double = 20
    static let maximumFrequency: Double = 20_000

    /// Biquad coefficients, normalised so `a0 == 1`.
    struct Biquad: Equatable {
        var b0, b1, b2, a1, a2: Double

        static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

        /// Power gain |H(e^jω)|² at `frequency`, from the closed form
        /// |H|² = (B₀ − B₁φ + B₂φ²) / (A₀ − A₁φ + A₂φ²) with φ = sin²(ω/2).
        func magnitudeSquared(at frequency: Double, sampleRate: Double = EQCurve.sampleRate) -> Double {
            let w = 2 * .pi * frequency / sampleRate
            let phi = sin(w / 2) * sin(w / 2)
            let a0 = 1.0
            let num = pow(b0 + b1 + b2, 2) - 4 * (b0 * b1 + 4 * b0 * b2 + b1 * b2) * phi + 16 * b0 * b2 * phi * phi
            let den = pow(a0 + a1 + a2, 2) - 4 * (a0 * a1 + 4 * a0 * a2 + a1 * a2) * phi + 16 * a0 * a2 * phi * phi
            guard den > 0, num >= 0 else { return 1e-12 }
            return num / den
        }

        func decibels(at frequency: Double) -> Double {
            10 * log10(max(magnitudeSquared(at: frequency), 1e-12))
        }
    }

    /// Cookbook coefficients for one filter. `gainDB` is ignored by low-pass, high-pass and notch,
    /// exactly as on the device (GG greys the gain out for those types).
    static func biquad(type: EQFilterType, frequency: Double, gainDB: Double, q: Double,
                       sampleRate: Double = sampleRate) -> Biquad {
        let f = min(max(frequency, 1), sampleRate / 2 - 1)
        let qClamped = max(q, 0.05)
        let w0 = 2 * .pi * f / sampleRate
        let cosW = cos(w0), sinW = sin(w0)
        let alpha = sinW / (2 * qClamped)
        let A = pow(10, gainDB / 40)
        let sqrtA = sqrt(A)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0

        switch type {
        case .peaking:
            b0 = 1 + alpha * A; b1 = -2 * cosW; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cosW; a2 = 1 - alpha / A
        case .lowPass:
            b0 = (1 - cosW) / 2; b1 = 1 - cosW; b2 = (1 - cosW) / 2
            a0 = 1 + alpha; a1 = -2 * cosW; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cosW) / 2; b1 = -(1 + cosW); b2 = (1 + cosW) / 2
            a0 = 1 + alpha; a1 = -2 * cosW; a2 = 1 - alpha
        case .notch:
            b0 = 1; b1 = -2 * cosW; b2 = 1
            a0 = 1 + alpha; a1 = -2 * cosW; a2 = 1 - alpha
        case .lowShelf:
            b0 = A * ((A + 1) - (A - 1) * cosW + 2 * sqrtA * alpha)
            b1 = 2 * A * ((A - 1) - (A + 1) * cosW)
            b2 = A * ((A + 1) - (A - 1) * cosW - 2 * sqrtA * alpha)
            a0 = (A + 1) + (A - 1) * cosW + 2 * sqrtA * alpha
            a1 = -2 * ((A - 1) + (A + 1) * cosW)
            a2 = (A + 1) + (A - 1) * cosW - 2 * sqrtA * alpha
        case .highShelf:
            b0 = A * ((A + 1) + (A - 1) * cosW + 2 * sqrtA * alpha)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosW)
            b2 = A * ((A + 1) + (A - 1) * cosW - 2 * sqrtA * alpha)
            a0 = (A + 1) - (A - 1) * cosW + 2 * sqrtA * alpha
            a1 = 2 * ((A - 1) - (A + 1) * cosW)
            a2 = (A + 1) - (A - 1) * cosW - 2 * sqrtA * alpha
        }
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// The filter behind one parametric band, or `nil` when the band is off or malformed.
    static func biquad(for band: ParametricBand) -> Biquad? {
        guard band.isEnabled, let filter = band.filter else { return nil }
        return biquad(type: filter, frequency: Double(band.frequency), gainDB: band.gainDB, q: band.q)
    }

    /// Response of one band in dB at `frequency` (0 for a disabled band).
    static func decibels(of band: ParametricBand, at frequency: Double) -> Double {
        biquad(for: band)?.decibels(at: frequency) ?? 0
    }

    /// Combined response of a parametric EQ: the bands run in series, so their dB add.
    static func decibels(of bands: [ParametricBand], at frequency: Double) -> Double {
        bands.reduce(0) { $0 + decibels(of: $1, at: frequency) }
    }

    /// Q used to draw one band of the 10-band graphic EQs. Bands sit an octave apart, and a
    /// peaking filter with Q ≈ √2 has a bandwidth of about one octave, so neighbours meet
    /// without a dip. (The hub's own graphic-EQ filter shape isn't documented.)
    static let graphicBandQ = 1.414

    /// Combined response of a graphic EQ at `frequency`, modelling each band as a peaking filter.
    static func decibels(graphicGainsDB gains: [Double], frequencies: [Int], at frequency: Double) -> Double {
        zip(gains, frequencies).reduce(0) { total, band in
            guard band.0 != 0 else { return total }
            return total + biquad(type: .peaking, frequency: Double(band.1), gainDB: band.0, q: graphicBandQ).decibels(at: frequency)
        }
    }

    // MARK: Sampling for drawing

    /// `count` frequencies spaced evenly on a log scale from 20 Hz to 20 kHz.
    static func logSpacedFrequencies(count: Int) -> [Double] {
        guard count > 1 else { return [minimumFrequency] }
        let lo = log10(minimumFrequency), hi = log10(maximumFrequency)
        return (0..<count).map { pow(10, lo + (hi - lo) * Double($0) / Double(count - 1)) }
    }

    /// 0…1 position of `frequency` on the log axis.
    static func position(of frequency: Double) -> Double {
        let lo = log10(minimumFrequency), hi = log10(maximumFrequency)
        let clamped = min(max(frequency, minimumFrequency), maximumFrequency)
        return (log10(clamped) - lo) / (hi - lo)
    }

    /// Frequency at 0…1 on the log axis.
    static func frequency(atPosition position: Double) -> Double {
        let lo = log10(minimumFrequency), hi = log10(maximumFrequency)
        let p = min(max(position, 0), 1)
        return pow(10, lo + (hi - lo) * p)
    }
}
