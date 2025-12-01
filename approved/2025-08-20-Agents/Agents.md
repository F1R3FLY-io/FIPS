# Agents

Michael Stay ([director.research@f1r3fly.io](mailto:director.research@f1r3fly.io))
2025-08-20

# Agents

Many F1R3FLY node Rholang contracts have been written to emulate OOP-style objects (here called “agents” to emphasize that they are concurrent processes), where a constructor sets up internal state for a new instance of an object, then returns a reference to the instance.  We propose the following sugar to enable easier definition of such contracts:

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

where `r # Pc, P1, …, Pn, Q`.  Note that the channels this and return can be used freely in method bodies; the channels become bound in the desugaring.  Only this can be used in Q, since it's not guaranteed that Q will receive a return channel; if it does, it will be the first element of args.

The constructor pattern interacts with the send-return syntax nicely:

```
for(barInstance <- barCtor!?(...barArgs)) {
  barInstance!update(...updateArgs);
  for(response <- barInstance!compute(...computeArgs)){
    // etc.
  }
}
```

## Example
```
new Stack, uriOut, merge, sizeP, elemP in {
  agent Stack {
    constructor() {
      @(*this, *sizeP)!(0) |
      contract merge(@stack, @begin, @end, ret) = {
        match (end - begin) {
          0 => ret!([])
          1 => {
            for(@value <<- @(stack, *elemP, begin)) {
              ret!([value])
            }
          }
          _ => {
            new left, right in {
              merge!(stack, begin, begin + (end - begin) / 2, *left) |
              merge!(stack, begin + (end - begin) / 2, end, *right) |
              
              for(@leftList <- left & @rightList <- right) {
                ret!(leftList ++ rightList)
              }
            }
          }
        }
      }
    } |
    method isEmpty() {
      for (@size <<- @(*this, *sizeP)) {
        return!(size == 0)
      }
    } |
    method size() {
      for (@size <<- @(*this, *sizeP)) {
        return!(size)
      }
    } |
    method push(@value) {
      for (@size <- @(*this, *sizeP)) {
        @(*this, *elemP, size)!(value) |
        @(*this, *sizeP)!(size + 1) |
        return!(size + 1)
      }
    } |
    method pop() {
      for (@size <- @(*this, *sizeP)) {
        if (size == 0) {
          @(*this, *sizeP)!(size) |
          return!((false, "stack is empty"))
        } else {
          for(@value <- @(*this, *elemP, size - 1)) {
            @(*this, *sizeP)!(size - 1) |
            ret!((true, value))
          }
        }
      }
    } |
    method toList() {
      new mergedCh in {
        for (@size <- @(*this, *sizeP)) {
          merge!(*this, 0, size, *mergedCh) |
          
          for(@merged <- mergedCh) {
            @(*this, *sizeP)!(size) |
            ret!(merged)
          }
        }
      }
    }
  }
}
```

# Contracts as agents

In the long run, we would like contracts to be agents rather than just sugar for replicated receive. We can get there in two steps.

1. Add the agent sugar as described above.  Write thorough tests to check that the desugaring is what we’d like it to be.  For example, we may want to put the return channel at the start of the method rather than the end so that we can use a rest parameter to grab the remainder of the args.
2. Update all existing uses of the keyword contract to use agent instead, and update the call sites to use send-return or method-call syntax.  At this point, there will be no uses of the keyword contract.  Once this is done, we can replace the keyword agent with contract instead, and the transition will be complete.
