#include "coai_lapack.h"

#include <Accelerate/Accelerate.h>
#include <stdlib.h>
#include <string.h>

int coai_symmetric_eigen(const double *matrix, int n, double *values, double *vectors) {
    if (n <= 0 || matrix == NULL || values == NULL || vectors == NULL) {
        return -1;
    }

    // `dsyevd_` overwrites the matrix it is given with the eigenvectors, so the
    // caller's copy is never touched — a statistics routine that quietly ate its
    // own input would be found by whoever wanted to print the matrix afterwards.
    memcpy(vectors, matrix, sizeof(double) * (size_t)n * (size_t)n);

    __LAPACK_int order = (__LAPACK_int)n;
    __LAPACK_int lda = order;
    __LAPACK_int info = 0;

    // Ask how much scratch space it wants before allocating any.
    __LAPACK_int lwork = -1;
    __LAPACK_int liwork = -1;
    double wanted_work = 0;
    __LAPACK_int wanted_iwork = 0;
    dsyevd_("V", "U", &order, vectors, &lda, values,
            &wanted_work, &lwork, &wanted_iwork, &liwork, &info);
    if (info != 0) {
        return (int)info;
    }

    lwork = (__LAPACK_int)wanted_work;
    liwork = wanted_iwork;
    double *work = malloc(sizeof(double) * (size_t)lwork);
    __LAPACK_int *iwork = malloc(sizeof(__LAPACK_int) * (size_t)liwork);
    if (work == NULL || iwork == NULL) {
        free(work);
        free(iwork);
        return -1000;
    }

    dsyevd_("V", "U", &order, vectors, &lda, values, work, &lwork, iwork, &liwork, &info);

    free(work);
    free(iwork);
    return (int)info;
}
