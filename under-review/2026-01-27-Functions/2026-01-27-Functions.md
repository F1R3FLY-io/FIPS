# Functions

Michael Stay ([director.research@f1r3fly.io](mailto:director.research@f1r3fly.io))  
2026-01-27

## Sugar

It is often useful to be able to provide a small function for e.g. filtering a list.  We propose syntactic sugar for functions in let expressions:

```
⟦let foo = (ptrn) => { expr } in P⟧
=
new foo in {
  for (ret, ptrn <= foo) {
    ret!(expr)
  } |
  P
}
```

### Benefits

#### Works with existing syntax

This desugaring works well with the existing `!?` operator:

```
⟦
  let foo = (ptrn) => { expr } in
  for (@result <- foo!?(...args)) {
    // use result
  }
⟧
=
new foo in {
  for (ret, ptrn <= foo) {
    ret!(expr)
  } |
  new ret in {
    foo!(*ret, ...args) |
    for (@result <- ret) {
      // use result
    }
  }
}
```

#### Can be done entirely in memory

Because `expr` is sent immediately, there are no side effects possible, so invocations of the function can be done entirely in memory.

## Possible extensions

### Lookahead

```
⟦let foo = (ptrn) => { expr }[n] in P⟧
=
new foo in {
  for (ret, ptrn <= foo) {
    ret!(expr)[n]
  } |
  P
}
```
