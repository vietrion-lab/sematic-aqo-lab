---
name: memory-contexts
description: 4-level PG memory context hierarchy, AllocSetContextCreate, Switch-Work-Switch-Reset idiom, cross-phase survival, resource release callback.
user-invocable: false
---

# Memory Contexts

## PG Memory Context Hierarchy

PostgreSQL uses memory contexts to prevent leaks. The hierarchy is:

```
TopMemoryContext
 ├── TopTransactionContext
 ├── QueryContext
 └── PortalContext
     ├── ExecutorState
     ├── ExprContext
     └── TupleContext
```

Extensions should create their own hierarchy rooted at `TopMemoryContext` to survive transactions and queries.

```
TopMemoryContext
 └── MyExtTopMemCtx
     ├── CacheContext
     ├── PredictContext
     ├── LearnContext
     └── StorageContext
```

## `AllocSetContextCreate` — Creating Contexts

```c
MyExtTopMemCtx = AllocSetContextCreate(TopMemoryContext,
                                       "MyExtTopMemCtx",
                                       ALLOCSET_DEFAULT_SIZES);

CacheContext = AllocSetContextCreate(MyExtTopMemCtx,
                                     "CacheContext",
                                     ALLOCSET_DEFAULT_SIZES);
```

## Switch-Work-Switch-Reset Idiom

The most common memory pattern. You switch to a temporary context, do work, switch back, and reset the temporary context. This guarantees no leaks.

```c
MemoryContext oldcontext;

oldcontext = MemoryContextSwitchTo(PredictContext);

/*
 * Allocate memory (palloc, pstrdup, SPI returns)
 * The planner might throw an ERROR here. If it does, PG
 * automatically cleans up the context at transaction end.
 */
do_work_that_allocates_a_lot_of_memory();

MemoryContextSwitchTo(oldcontext);
MemoryContextReset(PredictContext);
```

## Cross-Phase Survival

Data allocated in the Planner (`get_relation_info_hook`) needs to survive until Execution (`ExecutorEnd_hook`). `QueryContext` is the standard way to pass data between phases.

If you must pass a string allocated in a temporary context to a longer-living context:

```c
char *temp_str = "This will vanish when context resets";
char *saved_str;

MemoryContextSwitchTo(TopTransactionContext);
saved_str = pstrdup(temp_str);  /* Allocate in TopTransactionContext */
MemoryContextSwitchTo(oldcontext);

/* temp_str can now be freed, saved_str survives until COMMIT/ROLLBACK */
```

## Resource Release Callback

Reset transaction-level caches automatically when the transaction ends (commit or abort). Register a `ResourceReleaseCallback`.

```c
static ResourceReleaseCallbackItem *myext_release_item = NULL;

static void myext_release_callback(ResourceReleasePhase phase,
                                   bool isCommit,
                                   bool isTopLevel,
                                   void *arg)
{
    if (phase == RESOURCE_RELEASE_AFTER_LOCKS)
    {
        /* Clear transaction-level caches */
        MemoryContextReset(CacheContext);
    }
}

void _PG_init(void)
{
    /* ... */
    RegisterResourceReleaseCallback(myext_release_callback, NULL);
}
```

## The 6 Rules of PG Memory

1.  **Use `palloc` / `pfree`**: NEVER use `malloc` / `free`. PG cannot track `malloc` and you will cause true memory leaks.
2.  **`pstrdup` is your friend**: Need to return a string? `return pstrdup(str);`. Need to copy a string into a cache? `cache->name = pstrdup(str);`.
3.  **`MemoryContextReset` vs `MemoryContextDelete`**: `Reset` frees all memory *inside* the context but keeps the context alive for future allocations. `Delete` destroys the context entirely.
4.  **No Dangling Pointers**: If you cache a pointer in a global variable, make sure the memory it points to isn't in a context that resets (like `QueryContext` or `MessageContext`).
5.  **The "Current" Context is King**: `palloc` always allocates in `CurrentMemoryContext`. If you want memory to live longer, `MemoryContextSwitchTo` first.
6.  **`repalloc` to resize**: Reallocating arrays? `arr = repalloc(arr, new_size);`.
