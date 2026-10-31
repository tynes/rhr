import Foundation

/// Small, deterministic statistics helpers.
public enum Stats {
    public static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    public static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    /// Sample standard deviation (n − 1). Nil with fewer than two values.
    public static func standardDeviation(_ xs: [Double]) -> Double? {
        guard xs.count >= 2, let m = mean(xs) else { return nil }
        let ss = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (ss / Double(xs.count - 1)).squareRoot()
    }

    public struct Regression: Equatable, Sendable {
        public var slope: Double
        public var intercept: Double
        public var rSquared: Double
    }

    /// Ordinary least squares fit of y on x. Nil if fewer than two points or x has no variance.
    public static func linearRegression(x: [Double], y: [Double]) -> Regression? {
        guard x.count == y.count, x.count >= 2, let mx = mean(x), let my = mean(y) else { return nil }
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for i in x.indices {
            sxx += (x[i] - mx) * (x[i] - mx)
            sxy += (x[i] - mx) * (y[i] - my)
            syy += (y[i] - my) * (y[i] - my)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        let r2 = syy > 0 ? (sxy * sxy) / (sxx * syy) : 0
        return Regression(slope: slope, intercept: my - slope * mx, rSquared: r2)
    }

    /// Pearson correlation. Nil if fewer than three pairs or either variable is constant.
    public static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 3, let mx = mean(x), let my = mean(y) else { return nil }
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for i in x.indices {
            sxx += (x[i] - mx) * (x[i] - mx)
            syy += (y[i] - my) * (y[i] - my)
            sxy += (x[i] - mx) * (y[i] - my)
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    /// Two-sided 95% critical value of Student's t for `df` degrees of freedom.
    public static func tCritical95(df: Double) -> Double {
        let table: [Double] = [12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
                               2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086,
                               2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042]
        guard df.isFinite, df >= 1 else { return table[0] }
        let i = Int(df.rounded(.down))
        if i <= table.count { return table[i - 1] }
        if i <= 60 { return 2.000 }
        if i <= 120 { return 1.980 }
        return 1.960
    }
}
