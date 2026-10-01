# HashBag iteration-order probe

**CHECKS** §III.9's antecedent — that `HashBag`'s iteration order is a property of the
individual `HashMap` instance, not of the multiset it denotes.

**FIPS CLAIM** two bags equal as multisets iterate in different orders when built by
different insertion orders, and again when built at different pre-reserved capacities.

**LAST RUN** 2026-07-25. Both assertions pass.

```
multisets equal : true
iteration A     : ['PSend_a','PMatch_d','PNil_f','PPar_e','PRecv_b','PVar_x','PNew_c','PEval_g']
iteration B     : ['PNil_f','PMatch_d','PSend_a','PPar_e','PRecv_b','PNew_c','PEval_g','PVar_x']
orders equal    : false
orders equal (capacity-varied): false
```

**WHY IT IS BUILT THIS WAY.** The probe replicates the exact declared type from
`runtime/src/hashbag.rs:39-43` — `HashMap<T, usize, BuildHasherDefault<FxHasher>>` — at
the `rustc-hash` version `runtime/Cargo.toml` resolves to (2.1.1).

★ Reasoning is **not** sufficient here, and that is the point of running it. `FxHasher`
being seed-free makes the *hash of a key* stable across processes; iteration order depends
on the map's *bucket layout*, which is a function of insertion and resize history. Those
are independent properties, and an argument from the first does not reach the second. Only
measurement separates them.

**TEETH TEST** build both bags by the same insertion order at the same capacity — the
orders then match and the probe proves nothing. The *variation* is the experiment.

## Run

```sh
RH=$(printf '%s' ~/.cargo/registry/src/index.crates.io-*/rustc-hash-2.1.1)
rustc --edition 2021 --crate-type lib --crate-name rustc_hash -O --out-dir . "$RH/src/lib.rs"
rustc --edition 2021 -O --extern rustc_hash=./librustc_hash.rlib -o probe main.rs
./probe
```

If that `rustc-hash` version is not in the local registry, any 2.x will do — the property
under test is `HashMap`'s, not the hasher's.
