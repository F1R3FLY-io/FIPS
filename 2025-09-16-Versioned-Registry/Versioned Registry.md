# Versioned Registry

Mike Stay ([director.research@f1r3fly.io](mailto:director.research@f1r3fly.io))  
2025-09-16

# Introduction

As the scale of software written in Rholang grows, the need for code management tools increases. Our registry should provide [semantic versioning](https://semver.org/) for libraries and services.

# Versioned code

The current registry provides namespaces in which clients can look up code.  We propose the namespace structures

```
rho:lib:<lib version>:<public key>:<project id>:<project version>
rho:serve:<serve version>:<public key>:<project id>:<project version>
```

and new methods for managing code in this namespace.

The `lib version` and `serve version` allow us to change the registry API for these services (see the section "Versioning the Registry API itself" below.)

## `lib`

The `lib` namespace is for storing stateless code; a process registered in this namespace is only permitted to create temporary names, though it can receive persistent names and use them.  Because code in lib only has temp names, nothing a client does with it will persist.  So 

1. even without looking at the source code, the client knows that when they import something from this namespace, it can't leak any name they give it to another party   
2. the client knows they have to handle persistence themselves

Libraries can depend on other libraries, since they're subject to the same constraints.

## `serve`

The `serve` namespace is for storing versioned services that maintain internal state.

## Imports using new

### Specifying the version

When importing from a namespace using the `new` operator, a client has the option to use the asterisk (`*`) at any point in either version to mean "the latest version with the given prefix".

So supposing that the latest version is `2.6.3`, one could specify it as

- "the exact version" with `2.6.3`  
- "the latest patch of 2.6" with `2.6.*`  
- "the latest minor of 2" with `2.*`  
- "the latest major" with `*`

Note that in the last case, one would need to use reflection to discover the API because major version updates can change the API.

Preliminary releases like `2.6.3-alpha` can never be specified with an asterisk.

# Versioning the Registry API itself

At the moment we provide `insertArbitrary` and `insertSigned` via the `rho:registry` namespace.  If we ever want to change the interface, we'll need a principled way to do it.  We propose treating the name "registry" as though it's a project id and introducing a version into the URL, e.g. `rho:registry:1.0.0`.  Like the design above, the returned channel expects a channel on which to send the endpoint and a notification channel for deprecation alerts:

```
new getRegistry(`rho:registry:1.*`),
    notify, ret in {
  for (registry <- getRegistry!?(*notify)) {
    for (result <- registry!?("insertArbitrary", ...)) {
      ...
    }
  }
}
```

# Registry API version 1.x

The name returned from using a registry URL for these namespaces will be listened on by a contract that expects two names.  The first is the name on which the entry point of the contract or library should be sent.  The second is the name on which deprecation notices should be sent. For example, see the use of `getTC` below:

```
new getTC(`rho:lib:1.*:0x60605a76f7250c19c19090088fdf9fe0d814554cf3790765bab92a5971de56f5:tempConvert:2.3.*`),
    stdout(`rho:io:stdout`),
    notify, token in {
  for (tempConvert <- getTC!?(*notify)) {
    for (f2c, c2f <- tempConvert) {
      for (degrees <- f2c!?(-40)) {
        stdout!(("It's", degrees, "°C outside!"))
      }
    }
  }
}
```

## New registry API calls

## `insertVersion(ret, namespace, deployerId, projectId, version, code)`

The `namespace` parameter is a string (either `"lib"` or `"serve"`).  Returns either `true` or `false`.  The API call returns false if the deployerId does not match the public key, if the version already exists, or if the namespace is `"lib"` and the code uses persistent names.  Once we have type information, the system should enforce API stability for minor and patch upgrades instead of having it be merely a recommendation.

## `deprecateVersion(ret, namespace, deployerId, projectId, version)`

Sets the deprecation flag on a version.  Returns either `true` or `false`.  The API call returns false if the `deployerId` doesn't match or if the `version` doesn't exist.  When a version is deprecated, it will send a deprecation warning to notification channels provided to the import API.

## `approveVersion(ret, namespace, deployerId, projectId, version)`

Resets the deprecation flag on a version.  Returns either `true` or `false`.  The API call returns false if the `deployerId` doesn't match or if the `version` doesn't exist.  
