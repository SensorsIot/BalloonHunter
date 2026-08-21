/* [markdown]
# Descent Rate Model

Corrects the descent rate sent to the SondeHub predictor, by comparing how far
the sonde has actually fallen against how far that predictor said it would.

Tawhiri's `descent_rate` is a **sea-level terminal velocity**, not the rate a
sonde is observed falling at: the predictor models the atmosphere itself and
scales the parameter up with altitude. Handing it the observed rate is a category
error, and one whose size shrinks as the sonde descends — so each successive
prediction assumes a little more time aloft than the last, and the landing
estimate marches steadily downwind for the whole descent.

Rather than reproduce Tawhiri's atmosphere to undo that, this compares against
Tawhiri's own answer. Every prediction returns a trajectory of altitude against
time. If the sonde has fallen less than that trajectory said it would, it is
descending proportionally slower, and the rate is scaled by exactly that
proportion.

Measuring across the **entire fall since burst** rather than between consecutive
samples matters: a single pair of readings is noise, while the accumulated drop
integrates, and the estimate sharpens as the descent proceeds.
*/

import Foundation

struct DescentRateModel {

    /// Sea-level terminal velocities worth sending. A rate outside this range
    /// describes no radiosonde, and a near-zero one makes predicted time aloft
    /// diverge — better to keep the previous value than to send that.
    let plausibleRange: ClosedRange<Double>

    /// Smallest fall worth drawing a conclusion from. Early in a descent the
    /// drop is small enough that timing jitter dominates the ratio.
    let minimumDropMetres: Double

    /// Largest single correction, as a factor. A ratio far from 1 usually means
    /// the reference trajectory no longer describes this flight; stepping toward
    /// it is safer than jumping.
    let maximumStep: Double

    init(plausibleRange: ClosedRange<Double> = 1.0...15.0,
         minimumDropMetres: Double = 2_000,
         maximumStep: Double = 2.0) {
        self.plausibleRange = plausibleRange
        self.minimumDropMetres = minimumDropMetres
        self.maximumStep = maximumStep
    }

    /// What the sonde has done, against what the last prediction said it would.
    struct FallComparison {
        /// Metres the sonde has actually descended since burst.
        let actualDrop: Double
        /// Metres the reference trajectory had it descending over the same span.
        let predictedDrop: Double
        /// The `descent_rate` that produced that reference trajectory.
        let rateUsed: Double
    }

    /// The corrected rate to send, or `nil` when the evidence does not yet
    /// support changing anything.
    ///
    /// A ratio below 1 means the sonde is falling short of the prediction, so it
    /// is slower than the rate assumed and the rate must come down.
    func correctedRate(from fall: FallComparison) -> Double? {
        guard fall.actualDrop.isFinite, fall.predictedDrop.isFinite, fall.rateUsed.isFinite else { return nil }
        guard fall.predictedDrop > 0, fall.actualDrop > 0, fall.rateUsed > 0 else { return nil }

        // Too little has happened to tell the difference between a slow chute
        // and imprecise timing.
        guard fall.actualDrop >= minimumDropMetres || fall.predictedDrop >= minimumDropMetres else { return nil }

        let ratio = fall.actualDrop / fall.predictedDrop
        let stepped = min(max(ratio, 1 / maximumStep), maximumStep)
        let corrected = fall.rateUsed * stepped

        guard plausibleRange.contains(corrected) else { return nil }
        return corrected
    }

    /// How far off the current rate is, as a percentage, for display and logging.
    /// Negative means the sonde is falling slower than assumed.
    func deviationPercent(from fall: FallComparison) -> Double? {
        guard fall.predictedDrop > 0, fall.actualDrop > 0 else { return nil }
        return (fall.actualDrop / fall.predictedDrop - 1) * 100
    }
}
