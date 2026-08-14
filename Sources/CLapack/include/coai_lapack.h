#ifndef COAI_LAPACK_H
#define COAI_LAPACK_H

// The one call this project needs from LAPACK, wrapped so that Accelerate's
// headers never reach Swift (ARCHITECTURE §20.4, P11.3).
//
// Two reasons for a C file rather than calling `dsyevd_` from Swift directly:
//
//  1. The CLAPACK interface Swift can see without help has been deprecated since
//     macOS 13.3. It still works, and a build that prints a deprecation warning
//     on every compile is a build where the next real warning goes unread.
//     `ACCELERATE_NEW_LAPACK` is a C preprocessor macro, so it can only be set
//     for a C target — Swift's `-D` does not reach the Clang module.
//  2. The workspace query dance (call once with lwork = −1 to be told how much
//     scratch space is wanted, allocate, call again) is C's idiom, and doing it
//     in Swift means three `UnsafeMutablePointer` dances for no gain.

/// Eigenvalues and eigenvectors of a real symmetric matrix.
///
/// `matrix` is `n` × `n`, read in row-major order — which for a symmetric matrix
/// is the same bytes as column-major, so no transposition happens anywhere.
///
/// `values` receives `n` eigenvalues in **ascending** order (LAPACK's order; the
/// Swift wrapper is what reverses them, once).
/// `vectors` receives `n` × `n` doubles where the eigenvector for `values[j]` is
/// the contiguous run at `vectors[j * n ..< (j + 1) * n]`.
///
/// Returns LAPACK's `info`: 0 on success, < 0 for a bad argument, > 0 when the
/// algorithm failed to converge. Never returns partial results as if they were
/// whole ones.
int coai_symmetric_eigen(const double *matrix, int n, double *values, double *vectors);

#endif
