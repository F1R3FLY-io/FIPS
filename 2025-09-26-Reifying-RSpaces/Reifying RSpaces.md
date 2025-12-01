# Reifying RSpaces

Michael Stay ([director.research@f1r3fly.io](mailto:director.research@f1r3fly.io))   
L. Gregory Meredith ([lgreg.meredith@f1r3fly.com](mailto:lgreg.meredith@f1r3fly.com))   
2025-09-26

## Abstract

This document describes a generalization of RSpace that allows different data structures to be used as tuple spaces. An RSpace is a map-like data structure where write keys are channel names, read keys are patterns, and values are either processes or closures. After each operation, RSpace maintains the invariant that no synchronization can occur (i.e., all possible matches have been resolved).

We propose extending RSpace to support multiple storage strategies (outer structures like maps, vectors, pathmaps) and multiple collection semantics (inner structures like bags, queues, stacks, priority queues) at channels. This enables efficient specialized storage while maintaining the core tuple space semantics.

## Background

The current RSpace implementation (`ISpace` trait in `rspace_interface.rs:52`) defines four main groups of operations:

### Checkpointing Methods

Methods for managing persistent state and snapshots:

- **`create_checkpoint()`** (`rspace_interface.rs:57`) \- Creates a persistent checkpoint by writing the current store state into the history trie, returning a `Checkpoint` with the root hash.  
    
- **`create_soft_checkpoint()`** (`rspace_interface.rs:89`) \- Creates a fast, in-memory checkpoint without persisting to the history trie. Significantly faster than `create_checkpoint()` as it avoids the computationally expensive trie construction.  
    
- **`revert_to_soft_checkpoint(checkpoint)`** (`rspace_interface.rs:94`) \- Reverts the store to a previously created soft checkpoint.  
    
- **`reset(root)`** (`rspace_interface.rs:73`) \- Resets the store to a given BLAKE2b256 hash root, reconstructing state from the history trie.  
    
- **`clear()`** (`rspace_interface.rs:67`) \- Clears the current store without affecting the history trie.

### Replay Methods

Methods for deterministic replay and verification:

- **`rig_and_reset(start_root, log)`** (`rspace_interface.rs:172`) \- Prepares the store for replay by resetting to a starting root and loading an event log.  
    
- **`rig(log)`** (`rspace_interface.rs:174`) \- Sets up the replay mechanism with an event log.  
    
- **`check_replay_data()`** (`rspace_interface.rs:176`) \- Verifies that replay data is consistent.  
    
- **`is_replay()`** (`rspace_interface.rs:178`) \- Returns whether the store is in replay mode.  
    
- **`update_produce(produce)`** (`rspace_interface.rs:180`) \- Updates the replay state with a produce event.

### Producing Methods

Methods for adding data to the tuple space:

- **`produce(channel, data, persist)`** (`rspace_interface.rs:156`) \- Searches for a continuation with patterns matching the given data at the specified channel. If no match is found, stores the data at the channel. If a match is found, returns the continuation along with matching data. The `persist` flag controls whether data "sticks" in the store when no matches are found.  
    
- **`get_waiting_continuations(channels)`** (`rspace_interface.rs:61`) \- Retrieves all continuations waiting on the given channels. Used internally by `produce` to find continuations that match the produced data (`rspace.rs:571`).  
    
- **`get_joins(channel)`** (`rspace_interface.rs:63`) \- Retrieves all join patterns (multi-channel operations) associated with a channel. Used internally by `produce` to discover which channel combinations have waiting continuations (`rspace.rs:532`).

### Consuming Methods

Methods for retrieving and waiting for data:

- **`consume(channels, patterns, continuation, persist, peeks)`** (`rspace_interface.rs:124`) \- Searches for data matching all patterns at the given channels. If no match is found, stores the continuation and patterns at those channels. If a match is found, returns the continuation with matching data. The `persist` flag controls whether continuations remain when no matches are found.  
    
- **`install(channels, patterns, continuation)`** (`rspace_interface.rs:163`) \- Permanently installs a continuation at the given channels with the specified patterns.  
    
- **`consume_result(channels, patterns)`** (`rspace_interface.rs:75`) \- Retrieves matched results for given channels and patterns.  
    
- **`get_data(channel)`** (`rspace_interface.rs:59`) \- Retrieves all data stored at a channel. Used internally by `consume` to find data matching the provided patterns (`rspace.rs:517`).

## Understanding the Underlying Data Structure

The key insight for generalizing produce and consume is recognizing that RSpace is fundamentally a **key-value store** where:

- **Keys**: Channels (type `C`) or combinations of channels (`Vec<C>`)  
  - Note: "Channel" and "name" are synonyms  
  - Channels are created implicitly on first use (no explicit creation API needed)  
- **Values**: Pairs of bags (multisets):  
  - **Data bag**: Stores data items (type `Datum<A>`) waiting to be consumed  
  - **Continuation bag**: Stores continuations (type `WaitingContinuation<P, K>`) waiting for data

This structure can be seen in the `HotStoreState` (`hot_store.rs`):

```rust
pub struct HotStoreState<C, P, A, K> {
    /// Data bag per channel
    pub data: DashMap<C, Vec<Datum<A>>>,
    /// Continuation bag per channel combination
    pub continuations: DashMap<Vec<C>, Vec<WaitingContinuation<P, K>>>,
    /// Index: channel → channel combinations
    pub joins: DashMap<C, Vec<Vec<C>>>,
    /// ... (installed variants omitted)
}
```

**Operations:**

- **`produce(channel, data)`**: Looks up `channel` to find waiting continuations, or stores `data` in the data bag  
- **`consume(channels, patterns, continuation)`**: Looks up `channels` to find matching data, or stores `continuation` in the continuation bag

**Critical Invariant:**

After `produce` or `consume` completes, there exists **no match** between any data in the data bag and any continuation in the continuation bag.

This invariant holds because:

- If a match exists, the operation finds it immediately and executes it (removing the matched items)  
- Items only remain in their respective bags when they are genuinely waiting with no available match  
- The system eagerly resolves all possible matches, maintaining a consistent "matched-free" state

This invariant is fundamental to the correctness of the tuple space and will be preserved in any generalization.

## RSpace agent

Any [agent](https://docs.google.com/document/d/13VvNssV67MslHvxycAgywbODodj1ZIBxbxc-TE3oOBo/edit?tab=t.0#heading=h.5g7i17e5p09f) implementing the correct behavioral type can be used as an RSpace; likewise, any RSpace can be reified into an agent.

`agent Space {`  
  `// constructs a new space agent`  
  `// - qualifier is one of "default", "temp", or "seq"`  
  `// - theory is a MeTTaIL theory describing the data that`  
  `//   can be sent on channels`  
  `// - may take arbitrarily many more arguments`  
  `// - may abort if it doesn't support the qualifier`  
  `constructor(qualifier, theory, ...) { ... }`

  `// returns a name`  
  `// - may abort (e.g. if it runs out of names)`  
  `method gensym() { ... }`

  `// implements sending on a channel`  
  `// - may abort (e.g. if process being sent contains a Seq`  
  `//   name)`  
  `method produce(channel, process) { ... }`

  `// implements receiving on a join of channels`  
  `// - listMatcherChannel is a list of pairs (m, c) of processes`  
  `//   - m is a matcher that takes a process to match and returns`  
  `//     either None or Some(env), where env is a map from`  
  `//     string to process`  
  `//   - c is a channel to listen on`  
  `// - arrowType is one of the following strings:`  
  `//   "<-" "<=", "<<-"`  
  `// - body is a process expecting a map from strings to`  
  `//   processes`  
  `// - may abort`  
  `method consume(listMatcherChannel, arrowType, body) { ... }`  
`}`

As the implementation of patterns expands to full spatial-behavioral types in the form of datalog formulae, the matchers will become able to allow tailoring the patterns to both the inner data structure and the theory of the data on the channels.

### RSpace Implementation Variants

The generalization allows replacing the tuplespace with any other data structure that supports the RSpace Agent API. The `rho:space` namespace will contain various combinations of these, but developers can also write their own.

Here are a variety of outer storage structures that can be used:

#### HashMap (Current Implementation)

The default implementation uses `HashMap<Channel, Row>` where each `Row` contains `Vec<Datum>` and `Vec<WaitingContinuation>`.

#### PathMap (For MeTTa)

Channels are paths, and the data structure at each intermediate path is a pathmap.

Pathmaps are special because when you send on a channel, you're really also sending on all the prefixes of the channel. If you have `PathMap<HashMap>` as the RSpace, then when you send:

```
@[0, 1, 2]!({|"hi"|}) | @[0, 1, 2]!({|"hello"|}) | @[0, 1, 3]!({|"there"|})
= @[0, 1]!({|[2, "hi"], [2, "hello"], [3, "there"]|})
= @[0, 1]!({|[2, "hi"], [2, "hello"]|}) | @[0, 1]!({|[3, "there"]|})
= @()!({|[0, 1, 2, "hi"], [0, 1, 2, "hello"], [0, 1, 3, "there"]|}
= @[0, 1, 2, "hi"]!({||}) | @[0, 1, 2, "hello"]!({||}) | @[0, 1, 3, "there"]!({||})
```

you can receive on a prefix:

```
for( x <- @[0, 1] ) { P }
```

and get `x` bound to either `{|[2, "hi"], [2, "hello"]|}` or `{|[3, "there"]|}` with the remaining space being:

- `@[0, 1, 3]!("there")`, or  
- `@[0, 1, 2]!("hi") | @[0, 1, 2]!("hello")`

respectively.

**Quantale semantics of sequential processes:**

Given a set of paths, intersection & union can act on the sets. Multiplication can concatenate all pairs.  The result is an [example of a quantale](https://ncatlab.org/nlab/show/quantale#examples).  The process

`x!(pattern1); P | for (pattern2 <- x) { Q }` 

reduces to `P | Q` with substitutions applied. If variables on either side (say `y`, `z`) unify against each other, the resulting processes may get stuck if they rely on, say, sending on the name of the variable `@y!(3)`, or running the variable `y`, etc. (Or do we want to generate a new name for the unified pair?)

#### Array (Fixed Length)

**Maximum, with out-of-names error:**

When using an array without reuse as an rspace, `new` gives access to the next index up to the maximum. Once the array has allocated all its indices, further `new`s that reach the top level will cause an abort with an out-of-names error.

We could wrap the indices in `Unforgeable{}` so that clients can't get access to indices ambiently.

**Cyclic, with Reuse:**

When using an array with reuse as an rspace, `new` returns the next index modulo the size. Once the channels wrap around, processes start to interfere with each other.

#### Vector (Unbounded Length)

When using a vector as an rspace, `new` grows the vector and returns the index of the last element. When the server runs out of memory, the deploy fails with an out-of-memory error.

As above, we could wrap the indices in `Unforgeable{}` so that clients can't get access to indices ambiently.

#### HashSet of Channels (For Sequential Processes)

Sending on a channel `x` adds `x` to the set. Receives can only use the empty pattern and will receive either `None` or `Some(())`, but can use joins.

### Inner Storage Collection Types

The second part of the generalization replaces the inner storage structure. Instead of two bags (multisets) at each channel, we can have any pair of collection types.

**Key Properties:**

- These are unindexed collections: we add to them and consume from them  
- Patterns depend on the data collection type  
- Produces on a channel do not necessarily commute, since these collections may order incoming messages

Some examples:

#### Bags (Current Implementation)

Bags have the default multiset semantics. Each datum or continuation can appear multiple times.

#### Two sets

Each datum or continuation appears at most once; sending the same datum or continuation is idempotent.

#### Two cells

At most one datum or continuation can be sent on a channel. This is necessary for, but does not suffice for, the situation where we need **exactly one** datum on a channel: we would need extra machinery to prove that every execution path results in a value being put back on a channel after being consumed by a read.

Error when sending twice.

#### Two queues

FIFO semantics.  The tops of each queue have the potential to interact with each other.  The invariant means that only one of the queues is nonempty or the tops of the queues don't match.  Nodes would need to agree on message arrival order.

**Variants:**

- **Priority Queue**: pairs of queues, one per priority.  The patterns allow specifying a priority as well as a structure.

#### Two stacks

FILO semantics. The tops of each stack have the potential to interact with each other.

#### A bag and a vector DB

Consumes go into a bag, as usual, but data goes into a vector DB.  Patterns specify the similarity-distance bound as well as the vector to match. A `for` consumes one vector from within that distance.

We should look into [tensor logic](https://arxiv.org/pdf/2510.12269) to see whether and how it can be applied to a vector db.

We should look into exposing nonlinear operations on vectors like majority for binary vectors or using a sigmoid elementwise for pushing elements toward 0 or 1\.

#### Others

There are obvious fixed size versions of other collection types, where sending on that channel can cause an error once it's full.  We can also mix and match data types, e.g. for a [work-stealing](https://en.wikipedia.org/wiki/Work_stealing) scheduler.

## Channel Qualifiers

Channel qualifiers modify the behavior and persistence properties of the channels of a space.  Some outer data structures, like sets or pathmaps with quantale semantics, require the sequential qualifier.

### Default

When there is no qualifier, a channel is persistent and allows concurrent access.

### Temp

The temp qualifier is concurrent access, but data and continuations on the channel are never written to disk.

### Seq

Seq channels are temp and have the following restrictions:

- You can never send the channel (either alone or as part of some other process) on another channel  
- You cannot use it in a concurrent process  
- You can use it in at most one sequential process

## The `use` block

The `use` block tells the interpreter which space to use by default for untagged channels in `new` blocks and forged names.

## Example code

On `n` channels `space_1` to `space_n`, we construct `n` instances of spaces.  The qualifiers describe whether the space gets persisted and whether to impose the sequentiality restrictions on names.  The theories describe the grammar of the data that can be stored in the inner data structure; these will be specified in another design document.

```
new HMB(`rho:space:HashMapBagSpace`),
    PM(`rho:space:PathMapSpace`),
    getSpaceAgent(`rho:space:getSpaceAgent`),
    assertEqual(`rho:assert:assertEqual`) in {
  for(space_1 <- HMB!?("default", free Th_1()) ;
      ... ;
      space_n <- PM!?("temp", free Th_n())) {
    use space_1 {
      new x_1 : space_j, x_2 : space_j, ..., 
          x_{m-1} : space_k, x_m : space_k in {
        x_1!( e_1 ) | … | x_m!( e_m ) |
        // the forged name is created in space_1 because of the use block
        @{*x_1 | *x_2}!(f) |
        // joins are permitted in the same space and prohibited across spaces
        for( 
          y_1 <- x_1 & y_2 <- x_2 ; 
          y_3 <- x_3 ; 
          ... ; 
          y_r <- x_{m-1} & y_s <- x_m 
        ) {
          P
        } |
        // inside a `new` block that creates names in those spaces,
        //   the names of the spaces refer to the modified spaces
        out!( space_1, ..., space_n ) |
        // getSpaceAgent returns the underlying agent of a space
        assertEqual!(getSpaceAgent(space_1), HMB)
      } |
      // outside a `new` block that creates names in those spaces,
      //   the names of the spaces refer to the unmodified spaces
      out1!( space_1, ..., space_n )
    }
  }
}
```

## Refactoring Proposal: ISpace → Space Agent Architecture

### Current Architecture Issues

1. Tight coupling: ISpace tightly couples the outer structure (HashMap), inner structure (Vec/bags), and core operations  
2. Generic parameters leak implementation: C, P, A, K types are hardwired throughout  
3. HotStore is HashMap-specific: HotStore assumes DashMap\<C, Vec\<Datum\>\> and DashMap, Vec\>\>  
4. No abstraction for collection semantics: Bag semantics (Vec) are baked in with no way to swap for Queue, Stack, Set, etc.

### Proposed Trait Hierarchy

```rust
  // ==========================================================================
  // LAYER 1: Collection Abstractions (Inner Structure)
  // ==========================================================================

  /// Trait for collections that store data at a channel
  pub trait DataCollection<A: Clone> {
      /// Add data to the collection
      fn put(&mut self, datum: Datum<A>);

      /// Find and remove data matching a pattern using the matcher
      /// Returns (matched_data, removed_data, index) if found
      fn find_and_remove<P: Clone>(
          &mut self,
          pattern: &P,
          matcher: &dyn Match<P, A>,
      ) -> Option<(A, A, i32)>;

      /// Peek at data matching a pattern without removing
      fn peek<P: Clone>(
          &self,
          pattern: &P,
          matcher: &dyn Match<P, A>,
      ) -> Option<(A, i32)>;

      /// Get all data (for inspection/checkpointing)
      fn all_data(&self) -> Vec<Datum<A>>;

      /// Clear the collection
      fn clear(&mut self);

      /// Check if empty
      fn is_empty(&self) -> bool;
  }

  /// Trait for collections that store continuations at channel(s)
  pub trait ContinuationCollection<P: Clone, K: Clone> {
      /// Add continuation to the collection
      fn put(&mut self, wk: WaitingContinuation<P, K>);

      /// Find and remove a continuation that matches available data
      /// Returns (continuation, index) if found
      fn find_and_remove<C: Clone, A: Clone>(
          &mut self,
          available_data: &[(C, Vec<Datum<A>>)],
          matcher: &dyn Match<P, A>,
      ) -> Option<(WaitingContinuation<P, K>, i32)>;

      /// Get all continuations (for inspection/checkpointing)
      fn all_continuations(&self) -> Vec<WaitingContinuation<P, K>>;

      /// Clear the collection
      fn clear(&mut self);

      /// Check if empty
      fn is_empty(&self) -> bool;
  }

  // ==========================================================================
  // LAYER 2: Channel Storage (Outer Structure)
  // ==========================================================================

  /// Trait for the outer storage structure that maps channels to collections
  pub trait ChannelStore<C, P, A, K>
  where
      C: Clone + Eq + Hash,
      P: Clone,
      A: Clone,
      K: Clone,
  {
      type DataColl: DataCollection<A>;
      type ContColl: ContinuationCollection<P, K>;

      /// Get or create the data collection for a channel
      fn get_data_collection(&mut self, channel: &C) -> &mut Self::DataColl;

      /// Get or create the continuation collection for channel(s)
      fn get_continuation_collection(
        &mut self,
        channels: &[C]
      ) -> &mut Self::ContColl;

      /// Get all channels that have data or continuations
      fn all_channels(&self) -> Vec<C>;

      /// Get join patterns for a channel
      fn get_joins(&self, channel: &C) -> Vec<Vec<C>>;

      /// Add a join pattern
      fn put_join(&mut self, channel: &C, join: &[C]);

      /// Remove a join pattern
      fn remove_join(&mut self, channel: &C, join: &[C]);

      /// Create a checkpoint snapshot
      fn snapshot(&self) -> Self;

      /// Clear all data
      fn clear(&mut self);
  }

  // ==========================================================================
  // LAYER 3: Space Agent Core Trait (Simplified ISpace)
  // ==========================================================================

  /// Qualifier for space behavior
  #[derive(Debug, Clone, Copy, PartialEq, Eq)]
  pub enum SpaceQualifier {
      Default,  // Persistent, concurrent
      Temp,     // Non-persistent, concurrent
      Seq,      // Non-persistent, sequential, restricted
  }

  /// The core Space Agent trait - minimal interface for tuple space operations
  pub trait SpaceAgent {
      type Channel: Clone + Eq + Hash;
      type Pattern: Clone;
      type Data: Clone;
      type Continuation: Clone;

      /// Get the qualifier for this space
      fn qualifier(&self) -> SpaceQualifier;

      /// Generate a fresh name/channel
      fn gensym(&mut self) -> Result<Self::Channel, RSpaceError>;

      /// Produce data on a channel
      fn produce(
          &mut self,
          channel: Self::Channel,
          data: Self::Data,
          persist: bool,
      ) -> Result<
          Option<(
              ContResult<Self::Channel, Self::Pattern, Self::Continuation>,
              Vec<RSpaceResult<Self::Channel, Self::Data>>,
              Produce,
          )>,
          RSpaceError,
      >;

      /// Consume data from channels matching patterns
      fn consume(
          &mut self,
          channels: Vec<Self::Channel>,
          patterns: Vec<Self::Pattern>,
          continuation: Self::Continuation,
          persist: bool,
          peeks: BTreeSet<i32>,
      ) -> Result<
          Option<(
              ContResult<Self::Channel, Self::Pattern, Self::Continuation>,
              Vec<RSpaceResult<Self::Channel, Self::Data>>,
          )>,
          RSpaceError,
      >;

      /// Install a persistent continuation
      fn install(
          &mut self,
          channels: Vec<Self::Channel>,
          patterns: Vec<Self::Pattern>,
          continuation: Self::Continuation,
      ) -> Result<Option<(Self::Continuation, Vec<Self::Data>)>, RSpaceError>;
  }

  // ==========================================================================
  // LAYER 4: Extended Space Traits (for checkpointing, replay, etc.)
  // ==========================================================================

  /// Extension trait for spaces that support checkpointing
  pub trait CheckpointableSpace: SpaceAgent {
      /// Create a hard checkpoint (persisted to history)
      fn create_checkpoint(&mut self) -> Result<Checkpoint, RSpaceError>;

      /// Create a soft checkpoint (in-memory only)
      fn create_soft_checkpoint(&mut self) -> SoftCheckpoint<
          Self::Channel,
          Self::Pattern,
          Self::Data,
          Self::Continuation,
      >;

      /// Revert to a soft checkpoint
      fn revert_to_soft_checkpoint(
          &mut self,
          checkpoint: SoftCheckpoint<
              Self::Channel,
              Self::Pattern,
              Self::Data,
              Self::Continuation,
          >,
      ) -> Result<(), RSpaceError>;

      /// Reset to a hard checkpoint
      fn reset(&mut self, root: &Blake2b256Hash) -> Result<(), RSpaceError>;

      /// Clear the store
      fn clear(&mut self) -> Result<(), RSpaceError>;
  }

  /// Extension trait for spaces that support replay
  pub trait ReplayableSpace: CheckpointableSpace {
      /// Rig the space for replay from a checkpoint with a log
      fn rig_and_reset(&mut self, start_root: Blake2b256Hash, log: Log)
          -> Result<(), RSpaceError>;

      /// Rig the space for replay with a log
      fn rig(&self, log: Log) -> Result<(), RSpaceError>;

      /// Check replay data consistency
      fn check_replay_data(&self) -> Result<(), RSpaceError>;

      /// Check if in replay mode
      fn is_replay(&self) -> bool;

      /// Update produce event during replay
      fn update_produce(&mut self, produce: Produce);
  }

  // ==========================================================================
  // LAYER 5: Concrete Implementations
  // ==========================================================================

  /// Bag-based data collection (current Vec implementation)
  pub struct BagDataCollection<A: Clone> {
      data: Vec<Datum<A>>,
  }

  impl<A: Clone> DataCollection<A> for BagDataCollection<A> {
      // ... implementation
  }

  /// Queue-based data collection (FIFO)
  pub struct QueueDataCollection<A: Clone> {
      data: VecDeque<Datum<A>>,
  }

  impl<A: Clone> DataCollection<A> for QueueDataCollection<A> {
      // ... FIFO semantics: only check head
  }

  /// Set-based data collection (unique elements)
  pub struct SetDataCollection<A: Clone + Hash + Eq> {
      data: HashSet<Datum<A>>,
  }

  /// Cell-based data collection (at most one element)
  pub struct CellDataCollection<A: Clone> {
      data: Option<Datum<A>>,
  }

  /// HashMap-based channel store (current implementation)
  pub struct HashMapChannelStore<C, P, A, K, DC, CC>
  where
      C: Clone + Eq + Hash,
      P: Clone,
      A: Clone,
      K: Clone,
      DC: DataCollection<A>,
      CC: ContinuationCollection<P, K>,
  {
      data: DashMap<C, DC>,
      continuations: DashMap<Vec<C>, CC>,
      joins: DashMap<C, Vec<Vec<C>>>,
      installed_joins: DashMap<C, Vec<Vec<C>>>,
      _phantom: PhantomData<K>,
  }

  impl<C, P, A, K, DC, CC> ChannelStore<C, P, A, K>
      for HashMapChannelStore<C, P, A, K, DC, CC>
  where
      C: Clone + Eq + Hash,
      P: Clone,
      A: Clone,
      K: Clone,
      DC: DataCollection<A> + Default,
      CC: ContinuationCollection<P, K> + Default,
  {
      type DataColl = DC;
      type ContColl = CC;

      // ... implementation
  }

  /// PathMap-based channel store (for MeTTa)
  pub struct PathMapChannelStore<P, A, K, DC, CC>
  where
      P: Clone,
      A: Clone,
      K: Clone,
      DC: DataCollection<A>,
      CC: ContinuationCollection<P, K>,
  {
      // PathMap implementation with prefix matching
      root: PathMapNode<P, A, K, DC, CC>,
  }

  /// Generic RSpace implementation parameterized by storage strategy
  pub struct GenericRSpace<CS, M>
  where
      CS: ChannelStore<
          <CS as ChannelStore<_, _, _, _>>::Channel,
          <CS as ChannelStore<_, _, _, _>>::Pattern,
          <CS as ChannelStore<_, _, _, _>>::Data,
          <CS as ChannelStore<_, _, _, _>>::Continuation,
      >,
      M: Match<
          <CS as ChannelStore<_, _, _, _>>::Pattern,
          <CS as ChannelStore<_, _, _, _>>::Data,
      >,
  {
      channel_store: CS,
      matcher: M,
      qualifier: SpaceQualifier,
      history_repository: Option<Box<dyn HistoryRepository>>,
      name_counter: AtomicUsize,
  }

  impl<CS, M> SpaceAgent for GenericRSpace<CS, M>
  where
      CS: ChannelStore<...>,
      M: Match<...>,
  {
      type Channel = <CS as ChannelStore<...>>::Channel;
      type Pattern = <CS as ChannelStore<...>>::Pattern;
      type Data = <CS as ChannelStore<...>>::Data;
      type Continuation = <CS as ChannelStore<...>>::Continuation;

      fn qualifier(&self) -> SpaceQualifier {
          self.qualifier
      }

      fn gensym(&mut self) -> Result<Self::Channel, RSpaceError> {
          // Implementation depends on qualifier and channel type
          // For array-based: check bounds
          // For vector-based: grow
          // For hashmap-based: generate unique name
      }

      fn produce(&mut self, channel: Self::Channel, data: Self::Data, persist: bool)
          -> Result<...>
      {
          // 1. Get waiting continuations from channel_store
          // 2. Try to find a match using the matcher
          // 3. If match: return continuation + data
          // 4. If no match: store data in channel_store
      }

      fn consume(
        &mut self, 
        channels: Vec<Self::Channel>,
        patterns: Vec<Self::Pattern>,
        continuation: Self::Continuation,
        persist: bool,
        peeks: BTreeSet<i32>
      ) -> Result<...>
      {
          // 1. Get data from channels via channel_store
          // 2. Try to find matches using the matcher
          // 3. If match: return continuation + data
          // 4. If no match: store continuation in channel_store
      }

      fn install(
        &mut self,
        channels: Vec<Self::Channel>,
        patterns: Vec<Self::Pattern>,
        continuation: Self::Continuation
      ) -> Result<...>
      {
          // Install persistent continuation
      }
  }

  // ==========================================================================
  // LAYER 6: Factory/Builder Pattern for Space Creation
  // ==========================================================================

  pub trait SpaceFactory {
      type Agent: SpaceAgent;

      /// Create a new space with the given qualifier and theory
      fn create(
          &self,
          qualifier: SpaceQualifier,
          theory: Theory,
          additional_args: &[Value],
      ) -> Result<Self::Agent, RSpaceError>;
  }

  /// Factory for HashMap + Bag spaces (current implementation)
  pub struct HashMapBagSpaceFactory;

  impl SpaceFactory for HashMapBagSpaceFactory {
      type Agent = GenericRSpace<
          HashMapChannelStore<
            String,
            Pattern,
            String,
            StringsCaptor,
            BagDataCollection<String>,
            BagContinuationCollection<Pattern, StringsCaptor>,
          >,
          StringMatch,
      >;

      fn create(
        &self,
        qualifier: SpaceQualifier,
        theory: Theory, _args: &[Value]
      ) -> Result<Self::Agent, RSpaceError>
      {
          Ok(GenericRSpace {
              channel_store: HashMapChannelStore::new(),
              matcher: StringMatch,
              qualifier,
              history_repository: if qualifier == SpaceQualifier::Default {
                  Some(Box::new(create_lmdb_history_repo()?))
              } else {
                  None
              },
              name_counter: AtomicUsize::new(0),
          })
      }
  }

  /// Factory for PathMap spaces (for MeTTa)
  pub struct PathMapSpaceFactory;

  /// Registry for space factories
  pub struct SpaceRegistry {
      factories: HashMap<
        String,
        Box<dyn SpaceFactory<Agent = Box<dyn SpaceAgent>>>
      >,
  }

  impl SpaceRegistry {
      pub fn new() -> Self {
          let mut registry = SpaceRegistry {
              factories: HashMap::new(),
          };

          // Register built-in space types
          registry.register("rho:space:HashMapBagSpace",
                           Box::new(HashMapBagSpaceFactory));
          registry.register("rho:space:PathMapSpace",
                           Box::new(PathMapSpaceFactory));
          // ... register other types

          registry
      }

      pub fn register(&mut self, name: &str, factory: Box<dyn SpaceFactory>) {
          self.factories.insert(name.to_string(), factory);
      }

      pub fn create_space(
          &self,
          space_type: &str,
          qualifier: SpaceQualifier,
          theory: Theory,
          args: &[Value],
      ) -> Result<Box<dyn SpaceAgent>, RSpaceError> {
          self.factories
              .get(space_type)
              .ok_or(RSpaceError::UnknownSpaceType(space_type.to_string()))?
              .create(qualifier, theory, args)
      }
  }

```

### Migration Path

1. Phase 1: Extract collection abstractions \- Create DataCollection and ContinuationCollection traits \- Implement BagDataCollection wrapping current Vec\<Datum\> \- Refactor HotStore to use these abstractions  
2. Phase 2: Extract channel store abstraction \- Create ChannelStore trait \- Implement HashMapChannelStore wrapping current HotStoreState \- Update RSpace to depend on ChannelStore trait  
3. Phase 3: Split ISpace into SpaceAgent \+ extension traits \- Create minimal SpaceAgent trait \- Create CheckpointableSpace and ReplayableSpace extension traits \- Make current RSpace implement all three  
4. Phase 4: Implement alternative collection types \- QueueDataCollection, SetDataCollection, CellDataCollection \- Write tests for each  
5. Phase 5: Implement alternative channel stores \- PathMapChannelStore for MeTTa \- VectorChannelStore for array-based names \- Write tests for each  
6. Phase 6: Create space factory system \- Implement SpaceFactory trait and registry \- Update Rholang integration to use factory pattern

