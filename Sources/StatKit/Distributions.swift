import Foundation

// ─────────────────────────────────────────────────────────────
// The distribution tails, in one place (ARCHITECTURE §12.3 · §20.4).
//
// These used to live inside `Statistics` in M8, which was right while M8 was
// the only module that needed a p-value. P11.3 put a second caller on the other
// side of a wall: M15 Instruments must not depend on M8 (the analysis store
// reaches DuckDB and M15's dependency list is an invariant, §20.6), and
// Bartlett's test of sphericity needs a chi-square tail.
//
// Two copies of a continued fraction is the shape this project has been bitten
// by before — the SQL guard that existed twice and drifted, so the same DELETE
// warned on one screen and ran silently on the other. A p-value is worse: the
// two copies would agree for years and disagree at the fourth decimal in the
// one table somebody publishes.
//
// So: one target, no dependencies, pure arithmetic. `Statistics` keeps its
// public names and forwards here, which is why nothing outside had to change.
// ─────────────────────────────────────────────────────────────

public enum Distributions {

    public static func normalCDF(_ x: Double) -> Double {
        0.5 * erfc(-x / 2.0.squareRoot())
    }

    /// The inverse normal CDF (Acklam's rational approximation, |ε| < 1.15e-9)
    /// — needed for Shapiro–Wilk's expected order statistics.
    public static func normalQuantile(_ p: Double) -> Double {
        guard p > 0, p < 1 else { return p <= 0 ? -.infinity : .infinity }
        let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
                 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
        let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
                 6.680131188771972e+01, -1.328068155288572e+01]
        let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
                 -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
                 3.754408661907416e+00]
        let low = 0.02425
        if p < low {
            let q = (-2 * log(p)).squareRoot()
            return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        if p > 1 - low {
            let q = (-2 * log(1 - p)).squareRoot()
            return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        let q = p - 0.5
        let r = q * q
        return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q
            / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
    }

    /// Two-sided p-value for Student's t.
    public static func tTestPValue(t: Double, degreesOfFreedom: Double) -> Double {
        guard degreesOfFreedom > 0, t.isFinite else { return .nan }
        let df = degreesOfFreedom
        return regularizedIncompleteBeta(df / (df + t * t), df / 2, 0.5)
    }

    /// Upper-tail p-value for an F statistic.
    public static func fTestPValue(f: Double, d1: Double, d2: Double) -> Double {
        guard f > 0, d1 > 0, d2 > 0 else { return .nan }
        return regularizedIncompleteBeta(d2 / (d2 + d1 * f), d2 / 2, d1 / 2)
    }

    /// Upper-tail p-value for a chi-square statistic.
    public static func chiSquarePValue(_ x: Double, degreesOfFreedom: Double) -> Double {
        guard x >= 0, degreesOfFreedom > 0 else { return .nan }
        return 1 - regularizedIncompleteGamma(degreesOfFreedom / 2, x / 2)
    }

    /// I_x(a, b) — the regularised incomplete beta, by the standard continued
    /// fraction with Lentz's method.
    public static func regularizedIncompleteBeta(_ x: Double, _ a: Double, _ b: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let front = exp(lgamma(a + b) - lgamma(a) - lgamma(b)
                        + a * log(x) + b * log1p(-x))
        return x < (a + 1) / (a + b + 2)
            ? front * betaContinuedFraction(x, a, b) / a
            : 1 - front * betaContinuedFraction(1 - x, b, a) / b
    }

    private static func betaContinuedFraction(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let tiny = 1e-300
        var c = 1.0
        var d = 1 - (a + b) * x / (a + 1)
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var result = d
        for m in 1...300 {
            let mm = Double(m)
            var numerator = mm * (b - mm) * x / ((a + 2 * mm - 1) * (a + 2 * mm))
            d = 1 + numerator * d
            if abs(d) < tiny { d = tiny }
            c = 1 + numerator / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            result *= d * c

            numerator = -(a + mm) * (a + b + mm) * x / ((a + 2 * mm) * (a + 2 * mm + 1))
            d = 1 + numerator * d
            if abs(d) < tiny { d = tiny }
            c = 1 + numerator / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let delta = d * c
            result *= delta
            if abs(delta - 1) < 3e-16 { break }
        }
        return result
    }

    /// P(a, x) — the regularised lower incomplete gamma: series below the
    /// crossover, continued fraction above it.
    public static func regularizedIncompleteGamma(_ a: Double, _ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x < a + 1 {
            var term = 1 / a
            var sum = term
            var n = a
            for _ in 0..<500 {
                n += 1
                term *= x / n
                sum += term
                if abs(term) < abs(sum) * 3e-16 { break }
            }
            return sum * exp(-x + a * log(x) - lgamma(a))
        }
        let tiny = 1e-300
        var b = x + 1 - a
        var c = 1 / tiny
        var d = 1 / b
        var h = d
        for i in 1..<500 {
            let an = -Double(i) * (Double(i) - a)
            b += 2
            d = an * d + b
            if abs(d) < tiny { d = tiny }
            c = b + an / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let delta = d * c
            h *= delta
            if abs(delta - 1) < 3e-16 { break }
        }
        return 1 - exp(-x + a * log(x) - lgamma(a)) * h
    }
}
