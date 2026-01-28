# Private Methods

Michael Stay ([director.research@f1r3fly.io](mailto:director.research@f1r3fly.io))  
2026-01-28

## Agents

The current desugaring of [agents](https://github.com/F1R3FLY-io/FIPS/blob/main/approved/2025-08-20-Agents/Agents.md) is the following:

```
⟦agent fooCtor {
  constructor(<fooPtrns>) { Pc } |
  method fooMethod1(<ptrns1>) { P1 } |
  ... |
  method fooMethodn(<ptrnsn>) { Pn } |
  default(...@args) { Q } // only allow this exact rest parameter
}⟧
=
for(r, <fooPtrns> <= fooCtor) {
  new this in {
    // At least return channel and method name
    for(...@args <= this) {
      match args {
        [ *return, "fooMethod1", <ptrns1> ] => ⟦P1⟧
        ...
        [ *return, "fooMethodn", <ptrnsn> ] => ⟦Pn⟧
        _ => ⟦Q⟧
      }
    } |
    
    // Set up state and return the instance
    ⟦Pc⟧ |
    r!(bundle+{this})
  }}
}

⟦for(z <- x!y(...args)) { P }⟧ = ⟦for(z <- x!?(@"y", ...args)) { P }⟧
⟦x!y(...args);P⟧ = ⟦x!?(@"y", ...args);P⟧
⟦x!y(...args).⟧  = ⟦x!?(@"y", ...args).⟧
```

If any `method` is declared, the `default` case has to be provided.

The agents proposal doesn't provide for private methods.  Here we propose a small extension of the agent syntax and semantics to allow private methods.

## Private keyword

Methods can now be marked private.  If any `private method` is declared, a `private default` is required.

```
⟦agent fooCtor {
  constructor(<fooPtrns>) { Pc } |
  method fooMethodPub1(<ptrns1>) { Pub1 } |
  ... |
  method fooMethodPubn(<ptrnsn>) { Pubn } |
  default(...@args) { QPub } // only allow this exact rest parameter

  private method fooMethodPriv1(<ptrns1>) { Priv1 } |
  ... |
  private method fooMethodPrivm(<ptrnsm>) { Privm } |
  private default(...@args) { QPriv } // only allow this exact rest parameter
}⟧
=
for(r, <fooPtrns> <= fooCtor) {
  new this, private in {
    // At least return channel and method name
    for(...@args <= this) {
      match args {
        [ *return, "fooMethodPub1", <ptrns1> ] => ⟦Pub1⟧
        ...
        [ *return, "fooMethodPubn", <ptrnsn> ] => ⟦Pubn⟧
        _ => ⟦QPub⟧
      }
    } |
    for(...@args <= private) {
      match args {
        [ *return, "fooMethodPriv1", <ptrns1> ] => ⟦Priv1⟧
        ...
        [ *return, "fooMethodPrivm", <ptrnsn> ] => ⟦Privm⟧
        _ => ⟦QPriv⟧
      }
    } |
    
    // Set up state and return the instance
    ⟦Pc⟧ |
    r!(bundle+{this})
  }}
}
```

Methods can invoke both public and private methods using the method call syntax defined above:

```
for (@result <- this!fooMethodPub1(...args)) { /* handle result */ }
for (@result <- private!fooMethodPriv1(...args)) { /* handle result */ }
```

Because the `private` channel is never exposed by the translation, a client can't use the private methods unless the agent author explicitly breaks the security by sending it to the client.
