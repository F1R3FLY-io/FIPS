# Rholang System Channel Configuration

Michael Stay ([director.research@f1r3fly.io](mailto:director.research@f1r3fly.io))  
2025-11-18 (proposed)
2026-01-29 (addressed first review comments)

# Introduction

At the moment, system channels have to be added to the source code of the node itself (e.g. [openai\_service.rs](https://github.com/F1R3FLY-io/f1r3node/blob/rust/dev/rholang/src/rust/interpreter/openai_service.rs)).  This clearly does not scale.  We need a way to expose system resources as [agents](https://github.com/F1R3FLY-io/FIPS/blob/main/approved/2025-08-20-Agents/Agents.md) to Rholang code.

We propose to expose files and directories as agents whose names are available in the registry.  To get the names into the registry, we propose to add lines to the configuration file.

# File and directory agents

## Errors

In an async message-passing platform like Rholang, it's conceivable that one could register a process for handling errors so the happy path isn't interrupted by error handling:  

```
new errorHandler in {
  contract errorHandler(@file, @line, @errorCode, @errorMsg) = {
    // handle errors
  } |
  file!onError(*errorHandler);
  // process the file
  P
}
```

But that tends to separate the error handling from the place where the error occurs, making it harder to reason locally about code.  This proposal recommends returning a list from each method, either `[true, result]` or `[false, error code, error message]`.  Clients will typically invoke methods using pattern matching:
```
for (@[ok, ...rest] <- file!method(...args)) {
  if (!ok) {
    let @[code, msg] <- rest in {
      // handle error
    }
  } else {
    let @[result] <- rest in {
      // handle result
    }
  }
}
```

A complete proposal should include a set of codes and messages, but I'd like input on that before making something up.

## File Agent API

The examples below assume a file agent named `file`.

### Per Line

File agents provide line-based access to text files, allowing reading from the beginning and appending to the end.  File agents maintain a mutex to prevent extending a file while it's being read and vice versa.  They also maintain a mutex to prevent positional access (see below) while using line-based methods and vice versa.

##### `text` method

The `text` method returns the contents of the file as a single string.

```
for (@[ok, ...rest] <- file!text()) {
  if (!ok) {
    let @[code, msg] <- rest in {
      // handle error
    }
  } else {
    let @[text] <- rest in {
      // handle text
    }
  }
}
```

##### `lines` method

The `lines` method reads the entire file, splits the string using the regular expression `\R` (Unicode line break), and returns the resulting list of strings.
```
for (@[ok, ...rest] <- file!lines()) {
  if (!ok) {
    let @[code, msg] <- rest in {
      // handle error
    }
  } else {
    let @[lines] <- rest in {
      // handle lines
    }
  }
}
```

##### `forEachLine` method

The `forEachLine` method processes lines of a text file sequentially.  It streams the entire file; as it encounters Unicode line breaks, it invokes a contract to process each line in sequence using the `!?` operator, so the contract must signal when complete.  (To process them in parallel, use `mapReduceLines` below.)

```
new handle in {
  contract handle(done, @line) = {
    // process line, signal when complete
    done!()
  } |
  for (@[ok, ...rest] <- file!forEachLine(handle)) {
    if (!ok) {
      let @[code, msg] <- rest in {
        // handle error
      }
    } else {
      // rest is empty, so continue
    }
  }
}
```

##### `mapReduceLines` method

The `mapReduceLines` method processes lines of a text file in parallel, accumulating the results.  It streams the file; as it encounters Unicode line breaks, it invokes a contract to accumulate the line.  It then combines the results using the provided function and returns the fully accumulated value.

```
new reduce in {
  contract reduce(ret, @accumulator, @line) = {
    // combine accumulator with the line
    ret!(newAccumulator)
  } |
  for (@[ok, ...rest] <- file!mapReduceLines(reduce)) {
    if (!ok) {
      let @[code, msg] <- rest in {
        // handle error
      }
    } else {
      let @[result] <- rest in {
        // do something with the
        // fully accumulated value
      }
    }
  }
}
```

##### `mapReduceLinesOrdered` method

The `mapReduceLinesOrdered` method behaves the same as `mapReduceLines` but guarantees to accumulate the lines in order.  Note that this does not guarantee that the handling of each line is processed in order, only that the results are accumulated in that way.

```
new reduce in {
  contract reduce(ret, @accumulator, @line) = {
    // combine accumulator with the line
    ret!(newAccumulator)
  } |
  for (@[ok, ...rest] <- file!mapReduceLinesOrdered(reduce)) {
    if (!ok) {
      let @[code, msg] <- rest in {
        // handle error
      }
    } else {
      let @[result] <- rest in {
        // do something with the
        // fully accumulated value
      }
    }
  }
}
```

##### `appendLines` method

The `appendLines` method takes a list of strings and appends them to the end of the text file.

```
for (@[ok, ...rest] <- file!appendLines(lines)) {
  if (!ok) {
    let @[code, msg] <- rest in {
      // handle error
    }
  } else {
    // rest is empty
    // continue
  }
}
```

### Positional

File agents provide positional access to both binary and text files.  Positional access relies on acquiring read and write locks for regions of the file, allowing multiple readers and single writers of overlapping regions.  Data in a region cannot be read while a writer has a lock on it.  Also, file agents maintain a mutex to prevent simultaneous line-based access and positional access.

#### Bytes

##### `read` method

The `read` method takes a position `pos` and a length `n`, seeks to that position, and reads up to `n` bytes, returning the result as a byte array.

```
// read 10 bytes from position 5
for (@[ok, ...rest] <- file!read(5, 10)) {
  if (!ok) {
    let @[code, msg] <- rest in {
      // handle error
    }
  } else {
    let @[bytes] <- rest in {
      // handle bytes
    }
  }
}
```

##### `write` method

The `write` method takes a position and a byte array. It seeks to that position and writes out the bytes.  Writing past the end of the file extends the file.

```
for (@[ok, ...rest] <- file!write(5, bytes)) {
  if (!ok) {
    let @[code, msg] <- rest in {
      // handle error
    }
  } else {
    // rest is empty
    // continue
  }
}
```

## Directory Agent API

The examples below assume a directory agent named `dir`.

Directory agents provide capability-scoped access to a filesystem directory tree. All paths passed to a directory agent are interpreted as relative to the directory agent’s configured root, and are normalized before use. Any path that attempts to escape the root must be rejected.

Directory agents also provide a way to obtain file agents and subdirectory agents scoped to children of the directory, so Rholang code can compose the `File Agent API` above without requiring every file to be registered in configuration.

### Listing and metadata

##### `entries` method

Returns the immediate children of the directory as a list of entry records. Each entry record is a map whose keys are strings, and contains at least:

-   `name`: string
    
-   `kind`: `"file" | "dir"`
    
-   `size`: u64
    
-   `readonly`: boolean

```
for (@[ok, ...rest] <- dir!entries()) {
  if (!ok) {
    let @[code, msg] <- rest in {
      // handle error
    }
  } else {
    let @[entries] <- rest in {
      // handle entries
    }
  }
}
``` 

##### `exists` method

Returns `true` if a relative path exists under the directory root.

```
for (@ok <- dir!exists("notes/todo.txt")) {
  // ok is true/false
}
for (@[ok, ...rest] <- dir!exists("notes/todo.txt")) {
  if (!ok) {
    let @[code, msg] <- rest in {
      // handle error
    }
  } else {
    let @[exists] <- rest in {
      if (exists) {
	      // do something
	    } else {
	      // do something else
	    }
    }
  }
}
``` 

##### `stat` method

Returns an entry record for a relative path.

```
for (@[ok, ...rest] <- dir!stat("notes/todo.txt")) {
  if (!ok) {
    let @[code, msg] <- rest in {
      // handle error
    }
  } else {
    let @[entry] <- rest in {
      // handle entry
    }
  }
}
```

### Creating scoped agents

##### `openFile` method

Creates a file agent (or returns a cached one) scoped to the given relative path and returns that agent channel.

```
for (@[ok, ...rest] <- dir!openFile("notes/todo.txt")) {
  if (!ok) {
    let @[code, msg] <- rest in {
      // handle error
    }
  } else {
    let @[file] <- rest in {
      // use file
    }
  }
}
```

##### `openDir` method

Creates a directory agent (or returns a cached one) scoped to the given relative subdirectory and returns that agent channel.

```
for (@[ok, ...rest] <- dir!openDir("notes")) {
  if (!ok) {
    let @[code, msg] <- rest in {
      // handle error
    }
  } else {
    let @[notesSubDir] <- rest in {
      // use notesSubDir
    }
  }
}
``` 

### File and directory management

All mutating operations must be atomic when the underlying filesystem supports it (notably `rename`), and otherwise must fail cleanly.

##### `createFile` method

Creates an empty file at the given relative path. Fails if it already exists.

On success, returns the channel to the newly created file agent.

```
for (@[ok, ...rest] <- dir!createFile("notes/new.txt")) {
  if (!ok) {
    let @[code, msg] <- rest in {
      // handle error
    }
  } else {
    let @[newFile] <- rest in {
      // use newFile (file agent for notes/new.txt)
    }
  }
}
``` 

##### `createDir` method

Takes a path and (optionally) an options map. Creates a directory at the given relative path.  If the `parents` entry in the options map is `true`, it creates intermediate directories.

On success, returns the channel to the newly created directory agent.

```
for (@[ok, ...rest] <- dir!createDir("notes/2026", {"parents": true})) {
  if (!ok) {
    let @[code, msg] <- rest in {
      // handle error
    }
  } else {
    let @[newDir] <- rest in {
      // use newDir
    }
  }
}
``` 

##### `removeFile` method

Deletes a file.

```
for (@[ok, ...rest] <- dir!removeFile("notes/old.txt")) {
  if (!ok) {
    let @[code, msg] <- rest in {
      // handle error
    }
  } else {
    // rest is empty, so continue
  }
}
``` 

##### `removeDir` method

Takes a path and (optionally) an options map. Deletes a directory.  
If the `recursive` entry of the options map is `true`, it deletes its contents first.

```
for (@[ok, ...rest] <- dir!removeDir("notes/archive", {"recursive": true})) {
  if (!ok) {
    let @[code, msg] <- rest in {
      // handle error
    }
  } else {
    // rest is empty, so continue
  }
}
``` 

##### `rename` method

Renames (moves) a path under the same directory root. Implementations should prefer an atomic rename.

```
for (@[ok, ...rest] <- dir!rename("notes/todo.txt", "notes/todo.done.txt")) {
  if (!ok) {
    let @[code, msg] <- rest in {
      // handle error
    }
  } else {
    // rest is empty, so continue
  }
}
``` 

##### `copyFile` method

Copies a file from one relative path to another.

```
for (@[ok, ...rest] <- dir!copyFile("notes/todo.txt", "notes/todo.bak")) {
  if (!ok) {
    let @[code, msg] <- rest in {
      // handle error
    }
  } else {
    // rest is empty, so continue
  }
}
```

## Future work / open questions

* **JSON, JSONL, binary records, etc.**: These common cases should be libraries that build on the file & directory APIs above.
* **Hot reload**: support for reloading system-channel mappings at runtime is out of scope here, but could be considered later.
* **Error codes**: when we have files on different systems like windows/mac/posix/etc., how do we choose a uniform set of errors?
* **Error syntax**: the big `if` block and destructuring assignment in each case seems like a lot of boilerplate.  Is there sugar that would help?  Maybe something like a try/catch block?
  ``` 
  ⟦
  try @result <- file!method(...args) {
    // handle result
  }
  catch @[code, msg] {
    // handle error
  }
  ⟧ = 
  for (@[ok, ...rest] <- file!method(...args)) {
    if (!ok) {
      let @[code, msg] <- rest in {
        // handle error
      }
    } else {
      let @[result] <- rest in {
        // handle result
      }
    }
  }
  ```
