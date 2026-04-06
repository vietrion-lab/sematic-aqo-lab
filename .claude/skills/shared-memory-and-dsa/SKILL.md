---
name: shared-memory-and-dsa
description: PG15 two-hook shmem architecture, ShmemInitHash CRUD, DSA for variable-length data, crash-safe file persistence, before_shmem_exit callback.
user-invocable: false
---

# Shared Memory & DSA (Dynamic Shared Area)

## Two-Hook Architecture (PG15+)

PG15 split shared memory into **request** (calculate size) and **startup** (initialize):

```c
static shmem_startup_hook_type  prev_startup = NULL;
static shmem_request_hook_type  prev_request = NULL;

void my_shmem_init(void)
{
    prev_startup = shmem_startup_hook;
    shmem_startup_hook = my_shmem_startup;
    prev_request = shmem_request_hook;
    shmem_request_hook = my_shmem_request;
}
```

## Request Hook — Calculate & Request Size

```c
static void my_shmem_request(void)
{
    Size size;

    if (prev_request) (*prev_request)();  // chain

    size = MAXALIGN(sizeof(MySharedState));
    size = add_size(size, hash_estimate_size(max_items, sizeof(MyEntry)));
    
    RequestAddinShmemSpace(size);
    RequestNamedLWLockTranche("myext_lock", 1);
}
```

## Startup Hook — Initialize Hashes & Locks

```c
static void my_shmem_startup(void)
{
    bool found;
    HASHCTL info;

    if (prev_startup) (*prev_startup)();  // chain

    LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);

    MySharedState = ShmemInitStruct("myext_state",
                                    sizeof(*MySharedState),
                                    &found);

    if (!found)
    {
        /* First time init */
        MySharedState->lock = &(GetNamedLWLockTranche("myext_lock"))->lock;
    }

    info.keysize = sizeof(MyKey);
    info.entrysize = sizeof(MyEntry);
    MyHash = ShmemInitHash("myext_hash",
                           max_items / 10,  /* initial size */
                           max_items,       /* max size */
                           &info,
                           HASH_ELEM | HASH_BLOBS);

    LWLockRelease(AddinShmemInitLock);
}
```

## The Hash Entry Key Rule

The struct definition for a shared memory hash entry **must** have its lookup key as the very first field.

```c
typedef struct MyKey {
    Oid relid;
    uint32 query_hash;
} MyKey;

typedef struct MyEntry {
    MyKey key;              /* MUST BE FIRST */
    int value;
    dsa_pointer dyn_data;   /* If variable length data is needed */
} MyEntry;
```

## Hash Table CRUD Operations

### Insert (or Find existing to Update)

```c
MyEntry *entry;
bool found;

LWLockAcquire(MySharedState->lock, LW_EXCLUSIVE);

entry = (MyEntry *) hash_search(MyHash, &my_key, HASH_ENTER, &found);

if (!found) {
    /* Initialize new entry */
    entry->value = 0;
}

entry->value++;  /* Update */

LWLockRelease(MySharedState->lock);
```

### Read

```c
MyEntry *entry;

LWLockAcquire(MySharedState->lock, LW_SHARED);

entry = (MyEntry *) hash_search(MyHash, &my_key, HASH_FIND, NULL);
if (entry) {
    /* Read entry->value */
}

LWLockRelease(MySharedState->lock);
```

### Delete

```c
hash_search(MyHash, &my_key, HASH_REMOVE, NULL);
```

## Iteration (`hash_seq_search`)

```c
HASH_SEQ_STATUS status;
MyEntry *entry;

LWLockAcquire(MySharedState->lock, LW_SHARED);

hash_seq_init(&status, MyHash);
while ((entry = (MyEntry *) hash_seq_search(&status)) != NULL)
{
    /* Read entry */
}

LWLockRelease(MySharedState->lock);
```

## DSA (Dynamic Shared Area)

Used when you don't know the exact size of your hash values upfront (e.g., storing a variable length string or array per key).

```c
dsa_area *my_dsa;
dsa_pointer ptr;
char *str;

/* Allocate */
my_dsa = dsa_create(LWTRANCHE_DSA);
ptr = dsa_allocate_extended(my_dsa, 1024, DSA_ALLOC_NO_OOM | DSA_ALLOC_ZERO);

/* Use */
str = (char *) dsa_get_address(my_dsa, ptr);
snprintf(str, 1024, "Hello Shared Memory");

/* Free */
dsa_free(my_dsa, ptr);
```

## Crash-Safe File Persistence

To survive restarts, write shared memory to disk using a temporary file and `durable_rename`.

```c
FILE *fp;
char temp_path[MAXPGPATH];
char final_path[MAXPGPATH];

snprintf(final_path, sizeof(final_path), "pg_stat/myext.stat");
snprintf(temp_path, sizeof(temp_path), "%s.tmp", final_path);

fp = AllocateFile(temp_path, PG_BINARY_W);
/* Write data to fp */
FreeFile(fp);

durable_rename(temp_path, final_path, LOG);
```

## Shutdown Hook (`before_shmem_exit`)

Register in `_PG_init` to flush data to disk during clean shutdown.

```c
static void my_shmem_shutdown(int code, Datum arg)
{
    /* Save shared memory to disk */
    save_myext_data();
}

void _PG_init(void)
{
    /* ... */
    before_shmem_exit(my_shmem_shutdown, (Datum) 0);
}
```
