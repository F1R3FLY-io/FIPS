// Does HashBag's iteration order depend on the multiset it denotes, or on the
// individual map instance? mettail's HashBag is
//   HashMap<T, usize, BuildHasherDefault<FxHasher>>  (runtime/src/hashbag.rs:39-43)
// so this probe replicates that exact type and compares iteration orders of two
// bags that are EQUAL as multisets but were built along different insertion paths.
use rustc_hash::FxHasher;
use std::collections::HashMap;
use std::hash::BuildHasherDefault;

type Bag = HashMap<&'static str, usize, BuildHasherDefault<FxHasher>>;

fn build(order: &[&'static str]) -> Bag {
    let mut m: Bag = HashMap::default();
    for k in order { *m.entry(k).or_insert(0) += 1; }
    m
}

fn keys(m: &Bag) -> Vec<&'static str> { m.iter().map(|(k, _)| *k).collect() }

fn main() {
    let elems = ["PVar_x","PSend_a","PRecv_b","PNew_c","PMatch_d","PPar_e","PNil_f","PEval_g"];
    let mut fwd: Vec<&'static str> = elems.to_vec();
    let mut rev: Vec<&'static str> = elems.to_vec();
    rev.reverse();
    let a = build(&fwd);
    let b = build(&rev);
    // Same multiset?
    assert_eq!(a, b, "the two bags must be EQUAL as multisets");
    let (ka, kb) = (keys(&a), keys(&b));
    println!("multisets equal : {}", a == b);
    println!("iteration A     : {:?}", ka);
    println!("iteration B     : {:?}", kb);
    println!("orders equal    : {}", ka == kb);
    // Second probe: same insertion order, different pre-reserved capacity.
    let mut c: Bag = HashMap::with_capacity_and_hasher(64, BuildHasherDefault::<FxHasher>::default());
    for k in &fwd { *c.entry(k).or_insert(0) += 1; }
    println!("orders equal (capacity-varied): {}", keys(&a) == keys(&c));
    fwd.clear();
}
