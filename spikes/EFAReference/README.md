# EFA reference — the numbers the Swift had to match

Risk R12 in [`IMPLEMENTATION_PLAN.md`](../../IMPLEMENTATION_PLAN.md) is "a statistic
we wrote ourselves is wrong quietly". The answer used for ICC and κ was to compute
the published worked example in a different language first, and then make the Swift
produce the same figures. EFA has no small published worked example that fits on a
page, so this is the other half of that method: a complete second implementation,
written **before** `Sources/Instruments/FactorStructure.swift`, in pure Python with
no numpy — because this machine has none, and because a shared library would mean
a shared bug.

```bash
/usr/bin/python3 efa_reference.py
```

It prints the 40 × 6 dataset it generates, then the correlation matrix's
eigenvalues, the determinant, KMO, the per-item MSA, Bartlett's χ², the iterated
principal-axis communalities, the varimax-rotated loadings, the variance each
factor explains, and McDonald's ω for the first subscale.

Those numbers are pasted into `Tests/InstrumentsTests/FactorStructureTests.swift`,
where the Swift has to reproduce every one of them to 1e-5. They matched on the
first run, which is worth recording precisely because it is not the usual outcome:
if a later change to the Swift breaks one of them, this file is how you find out
which of the two is wrong.

The Swift does the eigen-decomposition through LAPACK and this does it with Jacobi
rotations. That difference is deliberate — two implementations of the same
algorithm agreeing is weaker evidence than two different algorithms agreeing.
