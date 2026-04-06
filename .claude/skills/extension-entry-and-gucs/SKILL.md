---
name: extension-entry-and-gucs
description: PG15 extension bootstrap:_PG_init canonical order, GUC registration recipes for Enum/Bool/Int, context levels (POSTMASTER/SIGHUP/SUSET/USERSET).
user-invocable: false
---

# Extension Entry Point & GUC Registration

## `_PG_init` — The Extension Bootstrap

Every PG extension **must** declare the magic block and export `_PG_init`:

```c
#include "postgres.h"
PG_MODULE_MAGIC;

void _PG_init(void);
```

### Guard Against Non-Preload

Extensions requiring shared memory **must** be loaded via `shared_preload_libraries`:

```c
void _PG_init(void)
{
    if (!process_shared_preload_libraries_in_progress)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("My extension could be loaded only on startup."),
                 errdetail("Add 'myext' into the shared_preload_libraries list.")));
}
```

### Canonical Init Order

1.  Guard check (shared\_preload\_libraries)
2.  `EnableQueryId()` (if needed)
3.  Define GUCs
4.  Register shared memory hooks
5.  Register planner / executor hooks
6.  Initialize global memory contexts
7.  Register resource release callbacks
8.  Register custom nodes (if any)
9.  `MarkGUCPrefixReserved("myext");`

---

## Defining GUCs (Configuration Variables)

GUCs are registered in `_PG_init` via `DefineCustom*Variable`.

### Enum GUC (Multiple Choice)

Requires an array of `config_enum_entry`.

```c
static const struct config_enum_entry my_enum_options[] = {
    {"off", MY_OPT_OFF, false},
    {"on", MY_OPT_ON, false},
    {"auto", MY_OPT_AUTO, false},
    {NULL, 0, false}
};

int my_guc_val = MY_OPT_AUTO;

DefineCustomEnumVariable(
    "myext.mode",
    "Short description of the GUC.",
    "Longer description of what it does.",
    &my_guc_val,
    MY_OPT_AUTO,
    my_enum_options,
    PGC_SUSET,          /* Context */
    0,                  /* Flags */
    NULL,               /* check_hook */
    NULL,               /* assign_hook */
    NULL                /* show_hook */
);
```

### Boolean GUC

```c
bool my_guc_bool = false;

DefineCustomBoolVariable(
    "myext.enable_feature",
    "Enable my cool feature.",
    NULL,
    &my_guc_bool,
    false,
    PGC_USERSET,
    0,
    NULL, NULL, NULL
);
```

### Integer GUC (With Bounds)

```c
int my_guc_int = 100;

DefineCustomIntVariable(
    "myext.max_items",
    "Maximum items to keep in cache.",
    "Valid range is 10 to 1000.",
    &my_guc_int,
    100,                /* default */
    10,                 /* min */
    1000,               /* max */
    PGC_SUSET,
    GUC_UNIT_KB,        /* Unit flag */
    NULL, NULL, NULL
);
```

---

## GUC Context Levels (`GucContext`)

Determines *who* can change the setting and *when*.

| Level | When it can change | Who can change it | Use case |
| :--- | :--- | :--- | :--- |
| `PGC_POSTMASTER` | Only at server start (`postgresql.conf`) | Sysadmin | Shared memory sizes |
| `PGC_SIGHUP` | Server start or reload (`pg_ctl reload`) | Sysadmin | Global features |
| `PGC_SUSET` | Anytime (`SET myext.x = 1`) | Superuser | Dangerous tunables |
| `PGC_USERSET` | Anytime (`SET myext.x = 1`) | Any user | Query-level flags |
