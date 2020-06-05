# Copyright (c) 2019, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

import pytest
import numpy as np
import cupy as cp

from cuml.dask.common.dask_arr_utils import to_dask_cudf


@pytest.mark.mg
@pytest.mark.parametrize("nrows", [1000])
@pytest.mark.parametrize("ncols", [20])
@pytest.mark.parametrize("n_parts", [67])
@pytest.mark.parametrize("input_type", ["dataframe", "array"])
def test_pca_fit(nrows, ncols, n_parts, input_type, client):

    from cuml.dask.decomposition import PCA as daskPCA
    from sklearn.decomposition import PCA

    from cuml.dask.datasets import make_blobs

    X, _ = make_blobs(n_samples=nrows,
                      n_features=ncols,
                      centers=1,
                      n_parts=n_parts,
                      cluster_std=0.5,
                      random_state=10, dtype=np.float32)

    if input_type == "dataframe":
        X_train = to_dask_cudf(X)
        X_cpu = X_train.compute().to_pandas().values
    elif input_type == "array":
        X_train = X
        X_cpu = cp.asnumpy(X_train.compute())

    try:

        cupca = daskPCA(n_components=5, whiten=True)
        cupca.fit(X_train)
    except Exception as e:
        print(str(e))

    skpca = PCA(n_components=5, whiten=True, svd_solver="full")
    skpca.fit(X_cpu)

    from cuml.test.utils import array_equal

    all_attr = ['singular_values_', 'components_',
                'explained_variance_', 'explained_variance_ratio_']

    for attr in all_attr:
        with_sign = False if attr in ['components_'] else True
        cuml_res = (getattr(cupca, attr))
        if type(cuml_res) == np.ndarray:
            cuml_res = cuml_res.as_matrix()
        skl_res = getattr(skpca, attr)
        assert array_equal(cuml_res, skl_res, 1e-1, with_sign=with_sign)


@pytest.mark.mg
@pytest.mark.parametrize("nrows", [1000])
@pytest.mark.parametrize("ncols", [20])
@pytest.mark.parametrize("n_parts", [2])
@pytest.mark.parametrize("input_type", ["dataframe", "array"])
def test_pca_tsqr(nrows, ncols, n_parts, input_type, sign_flip, ucx_client):

    from cuml.dask.decomposition import PCA as daskPCA
    from sklearn.decomposition import PCA

    from cuml.dask.datasets import make_blobs

    X, _ = make_blobs(n_samples=nrows,
                      n_features=ncols,
                      centers=1,
                      n_parts=n_parts,
                      cluster_std=0.5,
                      random_state=10, dtype=np.float32)

    if input_type == "dataframe":
        X_train = to_dask_cudf(X)
        X_cpu = X_train.compute().to_pandas().values
    elif input_type == "array":
        X_train = X
        X_cpu = cp.asnumpy(X_train.compute())

    try:

        cupca = daskPCA(n_components=5, svd_solver="tsqr",
                        sign_flip=sign_flip, whiten=False)
        cupca.fit(X_train)
    except Exception as e:
        print(str(e))

    skpca = PCA(n_components=5, svd_solver="full")
    skpca.fit(X_cpu)

    from cuml.test.utils import array_equal

    all_attr = ['singular_values_', 'components_',
                'explained_variance_', 'explained_variance_ratio_']

    for attr in all_attr:
        with_sign = False if attr in ['components_'] else True
        cuml_res = (getattr(cupca, attr))
        if type(cuml_res) == np.ndarray:
            cuml_res = cuml_res.as_matrix()
        skl_res = getattr(skpca, attr)
        assert array_equal(cuml_res, skl_res, 1e-1, with_sign=with_sign)

    if input_type == "array":
        local_X = cp.array(X_train.compute())
        X_trans = cupca.transform(X_train)
        local_X_inv = cp.array(cupca.inverse_transform(X_trans).compute())

        X_signs = cp.where(local_X >=0, 1, -1)
        X_inv_signs = cp.where(local_X_inv >=0, 1, -1)

        unequal = cp.where(X_signs != X_inv_signs, 1, 0)
        print("cu, sign, ", sign_flip, cp.sum(unequal))

        X_sk = cp.asnumpy(local_X)
        X_sk_t = skpca.transform(X_sk)
        X_sk_inv = skpca.inverse_transform(X_sk_t)

        X_sk_signs = np.where(X_sk >=0, 1, -1)
        X_sk_inv_signs = np.where(X_sk_inv >=0, 1, -1)

        unequal = np.where(X_sk_signs != X_sk_inv_signs, 1, 0)
        print("np: ", np.sum(unequal))

        assert array_equal(X_signs, X_inv_signs, 0, with_sign=True)


@pytest.mark.mg
@pytest.mark.parametrize("nrows", [1000])
@pytest.mark.parametrize("ncols", [20])
@pytest.mark.parametrize("n_parts", [46])
def test_pca_fit_transform_fp32(nrows, ncols, n_parts, client):

    from cuml.dask.decomposition import PCA as daskPCA
    from cuml.dask.datasets import make_blobs

    X_cudf, _ = make_blobs(n_samples=nrows,
                           n_features=ncols,
                           centers=1,
                           n_parts=n_parts,
                           cluster_std=1.5,
                           random_state=10, dtype=np.float32)

    cupca = daskPCA(n_components=20, whiten=True)
    cupca.fit_transform(X_cudf)


@pytest.mark.mg
@pytest.mark.parametrize("nrows", [1000])
@pytest.mark.parametrize("ncols", [20])
@pytest.mark.parametrize("n_parts", [33])
def test_pca_fit_transform_fp64(nrows, ncols, n_parts, client):

    from cuml.dask.decomposition import PCA as daskPCA
    from cuml.dask.datasets import make_blobs

    X_cudf, _ = make_blobs(n_samples=nrows,
                           n_features=ncols,
                           centers=1,
                           n_parts=n_parts,
                           cluster_std=1.5,
                           random_state=10, dtype=np.float64)

    cupca = daskPCA(n_components=30, whiten=False)
    cupca.fit_transform(X_cudf)
