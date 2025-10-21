---
title: Translating Bonito Nanopore Basecalling Models into Rust and the candle ML framework
author: Brandon Saint-John
---

## Install

## Download data with bonito

```bash
bonito download --training --out_dir bonito-out
```

## Convert to safetensors

candle Tensor read_npy causes issues

```bash
Err(npy/npz error unrecognized descr i2)
```

Avoid having to load into memory completely
npy-to-safetensors
Need around 40+ GB for the conversion on my machine
