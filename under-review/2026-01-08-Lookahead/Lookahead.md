# Lookahead

L. Gregory Meredith ([firefly.ceo@gmail.com](mailto:firefly.ceo@gmail.com))  
Michael Stay ([director.research@f1r3fly.io](mailto:director.research@f1r3fly.io))  
2026-01-08

This proposal introduces new syntax to speculatively execute a process for `n` steps, taking all possible rewrite paths, and gather the leaves of those paths into a `Set` object.  Something like this is necessary to trigger process rewriting in terms coming from MeTTaIL theories.  This proposal is isomorphic to the current semantics when `n = 0`.

## Use cases

### MeTTaIL Theories

Rholang 1.4 has the codename `MeTTaIL` because of the new features driven by SingularityNet's requirements from their MeTTa experimental AI language.  SingularityNet asserts that AIs will create domain-specific languages or virtual machines (VMs) in order to reason about the world.  Theories are how a programmer or AI specifies the operational semantics of a virtual machine.

A theory tells both how to construct the internal state of the VM as well as how to update that state.  VM states in Rholang are processes representing the parse tree for that state.  Because arbitrary VM states do not necessarily involve Rholang names, there is currently no way to run a program for a VM and query it to see the result.  Lookahead will address this problem.

### Lambdas

Currently, library code has to persist at a name to be useful.  With lookahead, we can dynamically create an instance of a process on the fly that will handle exactly one message and extract the name on which it's listening from the code.

### Confinement

Suppose Alice sends Bob some code—say, as part of a library.  Bob would like to guarantee that any secrets he provides to the code do not leak.  That is, Bob would like to *confine* Alice's code so that it communicates externally only on channels that Bob provides.

Lookahead provides this ability.  By providing communication channels to Alice's code and running the code to completion, Bob can see all the outgoing messages.  He can extract those messages being sent on the channels he provided and discard the rest of the state.

### Beam Search

From Wikipedia:

> In computer science, beam search is a heuristic search algorithm that explores a graph by expanding the most promising node in a limited set. Beam search is a modification of best-first search that reduces its memory requirements. Best-first search is a graph search which orders all partial solutions (states) according to some heuristic. But in beam search, only a predetermined number of best partial solutions are kept as candidates. It is thus a greedy algorithm.

With lookahead, we can do beam search naturally: we run a search process some number of steps `k`, gather the results, pick the top `n`, run the search forward from those `n` `k` more steps, gather the results, pick the top `n`, etc.

## Proposed Syntax

The number of steps should be provided in brackets after the arguments to a send: `x!(P)[n]`, where `n` is either a uint64 or an asterisk `*`.  

## Semantics

The process `P` being sent in `x!(P)[n]` should only contain names belonging to the same RSpace, which we'll call `space`.  Effectively, for each possible trace `t` of length `n` a new, empty RSpace `empty_t` will be created from the space agent of `space`, and the process `P` will be executed along that trace in `empty_t`.  The contents of all the `empty_t` spaces get collected into a `Set` object.  If a process cannot be further reduced before reaching a trace of length `n`, it is still considered part of the contents of `empty_t` and is included in the results.

## Examples

### MeTTaIL Theory

```
Theory LambdaCalc() {
  exports {
    T
  }
  terms {
    t1: T, t2: T |- app(t1, t2): T;
    f: T -> T |- lam(f): T;
  }
  rewrites {
    f: T -> T, t: T |- app(lam(f), t) ~> eval(f, t);
    t1: T, t2: T, u: T | t1 ~> t2 |- app(t1, u) ~> app(t2, u);
    t1: T, t2: T, u1: T, u2: T | t1 ~> t2, u1 ~> u2 |- app(t1, u1) ~> app(t2, u2);
  }
}

let lambda = free LambdaCalc() in {
  new x, so(`rho:io:stdout`) in {
    // Run the lambda term to completion
    x!(lambda`app(lam(λx.x), lam(λy.y))`)[*] |
    // Because lambda calculus is confluent, there's a single result
    for (@Set(result) <- x) {
      // Prints lam(λy.y)
      so!(result)
    }
  }
}
```

### Lambdas

```
// Alice defines a function-like process as part of a library.
let square = {
  new f in {
    for (ret, @x <- f) {
      ret!(x*x)
    }
  }
} in 
// Alice sends the code to Bob.
Bob!(square) |
// Bob gets the code.
for (@code <- Bob) {
  new ch in {
    // Bob runs the code to create an instance,
    // but doesn't yet know the name on which
    // the instance is listening.
    ch!(code)[*] |
    // Bob gets the Set containing the resulting instance.
    for (@Set(inst) <- ch) {
      match inst {
        // Bob uses a pattern to extract the channel.
        for (_, _ <- instCh) { _ }} => {
          // Bob invokes the function and
          // continues with the result in P.
          let secret = 5 in {
            inst | for (@squared <- instCh!?(secret)) { P }
          }
        }
      }
    }
  }
}
```

### Confinement

This example is the same as last time, but now Alice attempts to leak a secret.

```
// Alice defines a function-like process as part of a library.
let square = {
  new f in {
    for (ret, @x <- f) {
      ret!(x*x) |
      // She attempts to leak the secret.
      Alice!(["Here's the secret:", x])
    }
  }
} in 
// Alice sends the code to Bob.
Bob!(square) |
// Bob gets the code.
for (@code <- Bob) {
  new ch in {
    // Bob runs the code to create an instance,
    // but doesn't yet know the name
    // on which the instance is listening.
    ch!(code)[*] |
    // Bob gets the Set containing the resulting process.
    for (@Set(inst) <- ch) {
      match inst {
        // Bob uses a pattern to extract the channel.
        for (_, _ <- instCh) { _ }} => {
          // He invokes the confined function
          let secret = 5 in {
            new ret, ch in {
              // He runs inst in an empty space.
              ch!(inst!(*ret, secret))[*] |
              // The resulting process is
              // ret!(25) | Alice!(["Here's the secret:", 5])
              //
              // Bob extracts just the message sent on ret.
              for (@Set(=ret!(squared) | _) <- ch) {
                // The message to Alice never gets delivered.
                P
              }
            }
          }
        }
      }
    }
  }
}
```
