from dask_cuda import LocalCUDACluster
from dask.distributed import Client, wait, futures_of
import dask.array as da
from cuml.dask.linear_model import LinearRegression
from cuml.dask.datasets.regression import make_regression
from cuml.dask.common.comms import CommsContext
import cudf
import dask_cudf
import numpy as np
import sys
from time import time, sleep
import warnings
import rmm
import cupy as cp
import dask
import numpy as np
from cuml.dask.common.dask_arr_utils import extract_arr_partitions
import os

base_n_points = 250_000_000
n_gb_data = np.asarray([2], dtype=int)
base_n_features = np.asarray([250], dtype=int)

ideal_benchmark_f = open('/gpfs/fs1/dgala/b_outs/ideal_benchmark_f.csv', 'a')

def _read_data(file_list):
    X = []
    for file in file_list:
        X.append(cp.load(file))
    X = cp.concatenate(X, axis=0)
    X = cp.array(X, order='F')
    # del X
    return X


def read_data(client, path, n_workers, workers, n_samples, n_features, n_gb=None, gb_partitions=None):
    total_file_list = os.listdir(path)
    total_file_list = [path + '/' + tfl for tfl in total_file_list]
    if gb_partitions:
        if len(gb_partitions) == n_workers - 1:
            file_list = total_file_list[:n_gb] if n_gb else file_list
            file_list = np.split(np.asarray(file_list), gb_partitions)
    elif n_gb:
        if n_gb % n_workers == 0:
            file_list = total_file_list[:n_gb]
            file_list = np.split(np.asarray(file_list), n_workers)
    else:
        file_list = total_file_list[:n_workers]
        file_list = np.split(np.asarray(file_list), n_workers)

    X = [client.submit(_read_data, file_list[i], workers=[workers[i]]) for i in range(n_workers)]
    wait([X])

    if n_features:
        X = [da.from_delayed(dask.delayed(x), meta=cp.zeros(1, dtype=cp.float32),
            shape=(np.nan, n_features),
            dtype=cp.float32) for x in X]
    else:
        X = [da.from_delayed(dask.delayed(x), meta=cp.zeros(1, dtype=cp.float32),
            shape=(np.nan, ),
            dtype=cp.float32) for x in X] 

    X = da.concatenate(X, axis=0, allow_unknown_chunksizes=True)

    return X

def _mse(ytest, yhat):
    if ytest.shape == yhat.shape:
        return (cp.mean((ytest - yhat) ** 2), ytest.shape[0])
    else:
        print("sorry")


def dask_mse(ytest, yhat, client, workers):
    ytest_parts = client.sync(extract_arr_partitions, ytest, client)
    yhat_parts = client.sync(extract_arr_partitions, yhat, client)
    mse_parts = np.asarray([client.submit(_mse, ytest_parts[i][1], yhat_parts[i][1]).result() for i in range(len(ytest_parts))])
    mse_parts[:, 0] = mse_parts[:, 0] * mse_parts[:, 1]
    return np.sum(mse_parts[:, 0]) / np.sum(mse_parts[:, 1])


def set_alloc():
    cp.cuda.set_allocator(rmm.rmm_cupy_allocator)


def make_client(n_workers=2):
    cluster = LocalCUDACluster(n_workers=n_workers)
    client = Client(cluster)
    return client


def check_order(x):
    print(x.flags.f_contiguous, x.strides)
    return x


def transpose_and_move(X, client, workers, n_samples, n_workers, n_features):
    futures = client.sync(extract_arr_partitions, X, client)
    futures = [client.submit(cp.array, futures[i][1], order="F", workers=[workers[i]]) for i in range(len(futures))]
    wait([futures])

    X = [da.from_delayed(dask.delayed(x), meta=cp.zeros(1, dtype=cp.float64), shape=(n_samples / n_workers, n_features), dtype=cp.float64) for x in futures]
    X = da.concatenate(X, axis=0, allow_unknown_chunksizes=True)
    # X_arr = X_arr.map_blocks(check_order, dtype=cp.float32)
    return X
    # return X_arr


def run_ideal_benchmark(n_workers, X_filepath, y_filepath, n_gb, n_features, scheduler_file):

    # for n_gb_m in n_gb_data:
    #     for n_features in base_n_features:
    fit_time = np.zeros(5)
    pred_time = np.zeros(5)
    mse = np.zeros(5)
    for i in range(5):
        try:
            n_points = int(base_n_points * n_gb)
            if scheduler_file != 'None':
                client = Client(scheduler_file=scheduler_file)
            else:
                cluster = LocalCUDACluster(n_workers=n_workers)
                client = Client(cluster)
            client.run(set_alloc)

            workers = list(client.has_what().keys())
            print(workers)

            n_samples = n_points / n_features
            # X, y = make_regression(n_samples=n_samples, n_features=n_features, n_informative=n_features / 10, n_parts=n_workers)

            # X = X.rechunk((n_samples / n_workers, n_features))
            # y = y.rechunk(n_samples / n_workers )

            X = read_data(client, X_filepath, n_workers, workers, n_samples, n_features, n_gb)
            print(X.compute_chunk_sizes().chunks)
            y = read_data(client, y_filepath, n_workers, workers, n_samples, None, n_gb)
            print(X.compute_chunk_sizes().chunks)
            print(y.compute_chunk_sizes().chunks)
            print(client.has_what())
            
            lr = LinearRegression(client=client)

            start_fit_time = time()
            lr.fit(X, y)
            end_fit_time = time()
            print("nGPUS: ", n_workers, ", Shape: ", X.shape, ", Fit Time: ", end_fit_time - start_fit_time)
            fit_time[i] = end_fit_time - start_fit_time

            start_pred_time = time()
            preds = lr.predict(X)
            parts = client.sync(extract_arr_partitions, preds, client)
            wait([p for w, p in parts])
            # wait(client.compute(preds))
            end_pred_time = time()
            print("nGPUS: ", n_workers, ", Shape: ", X.shape, ", Predict Time: ", end_pred_time - start_pred_time)
            pred_time[i] = end_pred_time - start_pred_time

            mse[i] = dask_mse(y, preds, client, workers)
            print(mse[i])

            del X, y, preds

        except Exception as e:
            print(e)
            continue

        finally:
            if 'X' in vars():
                del X
            if 'y' in vars():
                del y
            if 'preds' in vars():
                del preds
            if scheduler_file == 'None':
                cluster.close()
            client.close()

    print("starting write")
    fit_stats = [np.mean(fit_time), np.min(fit_time), np.var(fit_time)]
    pred_stats = [np.mean(pred_time), np.min(pred_time), np.var(pred_time), np.mean(mse)]
    with open('/gpfs/fs1/dgala/b_outs/benchmark.csv', 'a') as f:
        f.write(','.join(map(str, [n_workers, n_samples, n_features] + fit_stats + pred_stats)))
        f.write('\n')
    print("ending write")
        #     break
        # break


if __name__ == '__main__':
    n_gpus = int(sys.argv[1])
    X_filepath = sys.argv[2]
    y_filepath = sys.argv[3]
    n_gb = int(sys.argv[4])
    n_features = int(sys.argv[5])
    scheduler_file = sys.argv[6]
    run_ideal_benchmark(n_gpus, X_filepath, y_filepath, n_gb, n_features, scheduler_file)