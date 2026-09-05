# Garbage Collection

Michael Stay ([director.research@f1r3fly.io](mailto:director.research@f1r3fly.io))  
2026-01-27


## Introduction

It is easy for processes to leave inaccessible processes behind in RSpace.  For example, once this deployment runs, `x` is inaccessible; no process can ever receive the sent message.

```
new x in { x!(0) }
```

In the absence of tokenized process storage, garbage permanently consumes storage resources.

Here we propose an algorithm for removing such processes from a HashMap/Bag RSpace (the default).

## Algorithm

At the end of a deployment, all processes have run to completion.  Value processes like integers, strings, lists, etc. that form part of the state already get excluded from the permanent state.  We only need to clean up sends and receives on unforgeable names.

A name is publicly accessible if it is forgeable, registered, sent on a public name, or (crudely) in the body of a public receive.  The last point is conservative; there may be unforgeable names in the body of a public receive that are not actually public, but this approach won't have a free-before-use problem.

1. *The name is forgeable.*

  Anyone can create, e.g. `@0` at any point in a deployment.

2. *The name is registered itself.*

  ```
  new ri(`rho:registry:insertArbitrary`), x in {
    new so(`rho:io:stdout`) in {
      // Publish uri
      ri!(*x, *so)
    }
  }
  ```

  Here, a process can acquire `x` by looking it up in the registry:
  
  ```
  new rl(`rho:registry:lookup`), retX in {
    rl!(uri, *retX) |
    for (x <- retX) {
      // use x
    }
  }
  ```

3. *The name is sent as part of a message on a public name.*

  1. Forgeable name

    ```
    new x in { @0!(*x) }
    ```
  
    Here, a process can acquire `x` by listening on the public name `@0`:
  
    ```
    for (x <- @0) {
      // use x
    }
    ```

  2. Registered name
  
    ```
    new ri(`rho:registry:insertArbitrary`), public, x in {
      public!(*x) |
      new so(`rho:io:stdout`) in {
        // Publish uri
        ri!(*public, *so)
      }
    }
    ```
    
    Here, a process can acquire `x` by looking up `public` in the registry, then reading from it:
    
    ```
    new rl(`rho:registry:lookup`), retPublic in {
      rl!(uri, *retPublic) |
      for (public <- retPublic; x <- public) {
        // use x
      }
    }
    ```

4. *The name is in the body of a process listening on a public name.*

  1. Forgeable name
  
    ```
    new x in {
      for (ret <- @0) {
        ret!(*x)
      }
    }
    ```

    Here, a process can acquire `x` by sending a return name on the public name `@0`:
    
    ```
    new ret in {
      @0!(*ret) |
      for (x <- ret) {
        // use x
      }
    }
    ```
  
  2. Registered name

    ```
    new ri(`rho:registry:insertArbitrary`), public, x in {
      for (ret <- public) {
        ret!(*x)
      } |
      new so(`rho:io:stdout`) in {
        // Publish uri
        ri!(*public, *so)
      }
    }
    ```
    
    Here, a process can acquire `x` by looking up `public` in the registry, then sending a return name on it:
    
    ```
    new rl(`rho:registry:lookup`), retPublic in {
      rl!(uri, *retPublic) |
      for (public <- retPublic) {
        new ret in {
          public!(*ret) |
          for (x <- ret) {
            // use x
          }
        }
      }
    }
    ```

Only public unforgeable names can be accessed by subsequent deploys.  Any processes sending or receiving on non-public unforgeable names should be removed from the RSpace.

## Optimization

We can make this efficient by keeping a pair of indices, where the first index tracks permanently public names and the second tracts transiently public names.  There's no way currently to remove URIs from the registry, so any unforgeable name actually stored at a URI in the registry can simply be marked public.  There's no way to remove a replicated `for` from RSpace, so we can mark any unforgeable name in the body of a replicated `for` listening on a public name as public.  There's no way to remove a replicated send from RSpace, so we can mark any unforgeable name in the message sent with replication on a public name as public.  For the rest we can do reference counting, where we increment the count when an unforgeable name is sent or received linearly on a public name, and we decrement the count when there's a synchronization.

