"""Independent EFA reference — pure Python, Jacobi eigen, no numpy.

Written before the Swift, so the Swift has something to be wrong against
(risk R12). Same algorithms, different language, different author's hands:
correlation -> KMO/MSA -> Bartlett -> principal axis factoring -> varimax.
"""
import math
import random

P = 6
N = 40

# A planted two-factor structure: items 0-2 share factor A, items 3-5 factor B.
random.seed(20260814)
DATA = []
for _ in range(N):
    a = random.gauss(0, 1)
    b = random.gauss(0, 1)
    row = []
    for j in range(P):
        common = a if j < 3 else b
        value = 0.75 * common + 0.66 * random.gauss(0, 1)
        # Likert 1-5, which is what the real data looks like.
        row.append(min(5, max(1, int(round(3 + value)))))
    DATA.append(row)


def correlation(data):
    n = len(data)
    p = len(data[0])
    means = [sum(r[j] for r in data) / n for j in range(p)]
    dev = [[r[j] - means[j] for r in data] for j in range(p)]
    norm = [math.sqrt(sum(v * v for v in dev[j])) for j in range(p)]
    return [[sum(dev[i][k] * dev[j][k] for k in range(n)) / (norm[i] * norm[j])
             for j in range(p)] for i in range(p)]


def jacobi(matrix, sweeps=200):
    """Eigenvalues/vectors of a symmetric matrix, descending."""
    n = len(matrix)
    a = [row[:] for row in matrix]
    v = [[1.0 if i == j else 0.0 for j in range(n)] for i in range(n)]
    for _ in range(sweeps):
        off = math.sqrt(sum(a[i][j] ** 2 for i in range(n) for j in range(n) if i != j))
        if off < 1e-14:
            break
        for p_ in range(n - 1):
            for q in range(p_ + 1, n):
                if abs(a[p_][q]) < 1e-18:
                    continue
                theta = (a[q][q] - a[p_][p_]) / (2 * a[p_][q])
                t = (1 if theta >= 0 else -1) / (abs(theta) + math.sqrt(theta * theta + 1))
                c = 1 / math.sqrt(t * t + 1)
                s = t * c
                for k in range(n):
                    akp, akq = a[k][p_], a[k][q]
                    a[k][p_] = c * akp - s * akq
                    a[k][q] = s * akp + c * akq
                for k in range(n):
                    apk, aqk = a[p_][k], a[q][k]
                    a[p_][k] = c * apk - s * aqk
                    a[q][k] = s * apk + c * aqk
                for k in range(n):
                    vkp, vkq = v[k][p_], v[k][q]
                    v[k][p_] = c * vkp - s * vkq
                    v[k][q] = s * vkp + c * vkq
    pairs = sorted(((a[i][i], [v[k][i] for k in range(n)]) for i in range(n)),
                   key=lambda pair: -pair[0])
    return [p_[0] for p_ in pairs], [p_[1] for p_ in pairs]


def inverse(matrix):
    values, vectors = jacobi(matrix)
    n = len(matrix)
    return [[sum(vectors[k][i] * vectors[k][j] / values[k] for k in range(n))
             for j in range(n)] for i in range(n)]


def kmo(corr):
    n = len(corr)
    inv = inverse(corr)
    partial = [[0.0] * n for _ in range(n)]
    for i in range(n):
        for j in range(n):
            if i != j:
                partial[i][j] = -inv[i][j] / math.sqrt(inv[i][i] * inv[j][j])
    top = sum(corr[i][j] ** 2 for i in range(n) for j in range(n) if i != j)
    bottom = sum(partial[i][j] ** 2 for i in range(n) for j in range(n) if i != j)
    msa = []
    for i in range(n):
        r = sum(corr[i][j] ** 2 for j in range(n) if j != i)
        q = sum(partial[i][j] ** 2 for j in range(n) if j != i)
        msa.append(r / (r + q))
    return top / (top + bottom), msa


def bartlett(corr, n):
    values, _ = jacobi(corr)
    det = 1.0
    for value in values:
        det *= value
    p = len(corr)
    chi = -(n - 1 - (2 * p + 5) / 6) * math.log(det)
    return chi, p * (p - 1) / 2, det


def principal_axis(corr, factors, iterations=100, tolerance=1e-7):
    n = len(corr)
    inv = inverse(corr)
    comm = [min(max(1 - 1 / inv[i][i], 0.0), 0.998) for i in range(n)]
    loadings = [[0.0] * factors for _ in range(n)]
    used = 0
    converged = False
    while used < iterations:
        used += 1
        reduced = [row[:] for row in corr]
        for i in range(n):
            reduced[i][i] = comm[i]
        values, vectors = jacobi(reduced)
        for i in range(n):
            for f in range(factors):
                loadings[i][f] = vectors[f][i] * math.sqrt(max(values[f], 0.0))
        updated = [min(sum(x * x for x in row), 0.998) for row in loadings]
        change = max(abs(a - b) for a, b in zip(comm, updated))
        comm = updated
        if change < tolerance:
            converged = True
            break
    return loadings, comm, used, converged


def varimax(loadings, iterations=100, tolerance=1e-9):
    rows = len(loadings)
    factors = len(loadings[0])
    lengths = [max(math.sqrt(sum(x * x for x in row)), 1e-12) for row in loadings]
    m = [[x / lengths[i] for x in row] for i, row in enumerate(loadings)]

    def criterion(mat):
        total = 0.0
        for f in range(factors):
            ss = sum(row[f] ** 2 for row in mat)
            s4 = sum(row[f] ** 4 for row in mat)
            total += s4 - ss * ss / rows
        return total

    previous = criterion(m)
    for _ in range(iterations):
        for f1 in range(factors - 1):
            for f2 in range(f1 + 1, factors):
                su = sv = suv = sq = 0.0
                for row in m:
                    a, b = row[f1], row[f2]
                    u = a * a - b * b
                    v = 2 * a * b
                    su += u
                    sv += v
                    sq += u * u - v * v
                    suv += u * v
                num = 2 * suv - 2 * su * sv / rows
                den = sq - (su * su - sv * sv) / rows
                angle = math.atan2(num, den) / 4
                if abs(angle) < 1e-12:
                    continue
                c, s = math.cos(angle), math.sin(angle)
                for row in m:
                    a, b = row[f1], row[f2]
                    row[f1] = a * c + b * s
                    row[f2] = -a * s + b * c
        now = criterion(m)
        if abs(now - previous) < tolerance:
            break
        previous = now
    return [[x * lengths[i] for x in row] for i, row in enumerate(m)]


def order_by_variance(loadings, factors):
    var = [sum(row[f] ** 2 for row in loadings) for f in range(factors)]
    order = sorted(range(factors), key=lambda f: -var[f])
    flip = [-1.0 if sum(row[f] for row in loadings) < 0 else 1.0 for f in order]
    return [[row[f] * flip[pos] for pos, f in enumerate(order)] for row in loadings]


corr = correlation(DATA)
overall, msa = kmo(corr)
chi, df, det = bartlett(corr, N)
values, _ = jacobi(corr)
loadings, comm, used, converged = principal_axis(corr, 2)
rotated = order_by_variance(varimax(loadings), 2)

print("DATA =", DATA)
print()
print("eigenvalues  :", [round(v, 6) for v in values])
print("determinant  :", round(det, 8))
print("KMO          :", round(overall, 6))
print("MSA          :", [round(v, 6) for v in msa])
print("Bartlett chi2:", round(chi, 6), "df", df)
print("iterations   :", used, "converged", converged)
print("communalities:", [round(v, 6) for v in comm])
print("rotated loadings:")
for i, row in enumerate(rotated):
    print("  item%d" % i, [round(v, 6) for v in row])
print("variance explained:",
      [round(sum(row[f] ** 2 for row in rotated) / P, 6) for f in range(2)])

# One-factor omega, on the first three items only (a subscale).
sub = [[row[j] for j in range(3)] for row in DATA]
subcorr = correlation(sub)
one, _, _, _ = principal_axis(subcorr, 1)
lam = [row[0] for row in one]
if sum(lam) < 0:
    lam = [-x for x in lam]
total = sum(lam)
omega = total * total / (total * total + sum(1 - x * x for x in lam))
print("omega(items 0-2):", round(omega, 6), "loadings", [round(x, 6) for x in lam])
