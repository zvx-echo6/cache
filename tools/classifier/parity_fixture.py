#!/usr/bin/env python3
"""Write the parity fixture packages/cache_classify/tests/parity.rs reads: numpy's answers on the held-out test books.

Needs numpy and the training folder (results_v2.pkl, vec/, best_weights_v2/). Not for CI; run on the training machine.

  parity_fixture.py --train DIR --divisions divisions.md --sha256 HEX --version 2 --out OUTDIR [--npieces 10]

It also prints the threshold: the 10th percentile of the top softmax probability over the training out-of-fold scores
(softmax regression, all-pieces book vector), the report's "top rule at the 10% Unsorted target".
"""
import argparse
import os
import pickle
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))


def nrm(x):
    return x / (np.linalg.norm(x) + 1e-12)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--train", required=True)
    ap.add_argument("--divisions", required=True)
    ap.add_argument("--sha256", required=True)
    ap.add_argument("--version", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--npieces", type=int, default=10, help="books whose piece vectors are written too")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    D = a.train
    RES, CVLOG, CL, idtr, idte, ytr, yte, y2te, nttr, ntte = pickle.load(open(D + "/results_v2.pkl", "rb"))
    oof, test = RES[(1, "softmax")]
    thr = float(np.quantile(oof.max(1), 0.10))
    print("threshold (10th percentile of OOF top probability): %r" % thr)
    print("test books left Unsorted by it: %.1f%%" % (100 * (test.max(1) < thr).mean()))

    W = np.fromfile(D + "/best_weights_v2/W_f32_1024x89.bin", dtype=np.float32).reshape(1024, 89)
    b = np.fromfile(D + "/best_weights_v2/bias_f32_89.bin", dtype=np.float32)
    W16 = W.astype(np.float16).astype(np.float32)

    def score(x, WW):
        l = x @ WW + b
        l = l - l.max()
        p = np.exp(l)
        return p / p.sum()

    books, vecs = [], []
    for i in idte:
        v = np.load("%s/vec/%s.npy" % (D, i)).astype(np.float32)
        books.append(v)
        vecs.append(nrm(v.mean(0)).astype(np.float32))
    X = np.array(vecs, dtype=np.float32)
    X.tofile(a.out + "/vectors_f32.bin")
    agree = 0
    with open(a.out + "/expected.tsv", "w") as f:
        for i, x in zip(idte, X):
            row = [i]
            for WW in (W, W16):
                p = score(x, WW)
                row += [str(int(p.argmax())), "%.9g" % p.max(), "1" if p.max() >= thr else "0"]
            f.write("\t".join(row) + "\n")
    # numpy f16 vs f32 top-1 agreement, for the record
    p32 = np.array([score(x, W) for x in X]).argmax(1)
    p16 = np.array([score(x, W16) for x in X]).argmax(1)
    print("numpy: f32 top-1 vs held-out key %.4f, f16 agrees with f32 on %d/%d" % ((p32 == yte).mean(), (p32 == p16).sum(), len(X)))

    with open(a.out + "/pieces.tsv", "w") as ft, open(a.out + "/pieces_f16.bin", "wb") as fb:
        for k in range(min(a.npieces, len(idte))):
            v = books[k].astype(np.float16)
            v.tofile(fb)
            ft.write("%s\t%d\t%d\n" % (idte[k], len(v), k))

    for name, extra in (("model_f32.bin", []), ("model_f16.bin", ["--f16"])):
        subprocess.check_call([sys.executable, HERE + "/make_classifier_model.py", "--weights", D + "/best_weights_v2",
                               "--divisions", a.divisions, "--version", str(a.version), "--embedding-sha256", a.sha256,
                               "--threshold", repr(thr), "--out", a.out + "/" + name] + extra)


if __name__ == "__main__":
    main()
