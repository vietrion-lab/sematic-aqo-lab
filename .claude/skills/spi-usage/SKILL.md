---
name: spi-usage
description: SPI read/write from C: StringInfo + quote_literal_cstr, result processing, re-entrancy guard, PG_TRY/PG_CATCH wrapper, table existence check.
user-invocable: false
---

# SPI (Server Programming Interface) Usage

## Executing SQL from C

The SPI API allows C extensions to run SQL statements internally.

### SPI Write (INSERT/UPDATE/DELETE)

```c
int ret;
StringInfoData buf;

initStringInfo(&buf);
appendStringInfo(&buf, "INSERT INTO my_table (id, name) VALUES (%d, %s)",
                 1,
                 quote_literal_cstr("O'Brian")); /* CRITICAL: SQL Injection prevention */

SPI_connect();
ret = SPI_execute(buf.data, false, 0);

if (ret != SPI_OK_INSERT)
    elog(WARNING, "SPI_execute failed: error code %d", ret);

SPI_finish();
pfree(buf.data);
```

### SPI Read (SELECT & Result Processing)

```c
int ret;
uint64 j;

SPI_connect();
ret = SPI_execute("SELECT id, name FROM my_table LIMIT 10", true, 0);

if (ret == SPI_OK_SELECT && SPI_processed > 0)
{
    TupleDesc tupdesc = SPI_tuptable->tupdesc;
    SPITupleTable *tuptable = SPI_tuptable;

    for (j = 0; j < tuptable->numvals; j++)
    {
        HeapTuple tuple = tuptable->vals[j];
        bool isnull;
        Datum val;

        /* Column 1 (id) */
        val = SPI_getbinval(tuple, tupdesc, 1, &isnull);
        if (!isnull)
            int32 id = DatumGetInt32(val);

        /* Column 2 (name) */
        val = SPI_getbinval(tuple, tupdesc, 2, &isnull);
        if (!isnull)
            char *name = TextDatumGetCString(val);
    }
}

SPI_finish();
```

## SPI Re-Entrancy Guard (Infinite Loop Protection)

If you use SPI inside a planner or executor hook, your SPI query will trigger that same hook again! You must guard against infinite recursion.

```c
static bool in_my_hook = false;

void my_hook(...)
{
    if (in_my_hook)
    {
        /* We are already inside our hook (triggered by our own SPI call) */
        return standard_function(...);
    }

    in_my_hook = true;

    /* Execute SPI query here */
    run_my_spi_query();

    in_my_hook = false;

    /* Continue normal hook logic */
}
```

## `PG_TRY/PG_CATCH` Wrapper for SPI

If SPI fails (e.g., table doesn't exist, syntax error), PG throws an ERROR that aborts the transaction. To recover gracefully:

```c
MemoryContext oldcontext = CurrentMemoryContext;
ResourceOwner oldowner = CurrentResourceOwner;

PG_TRY();
{
    SPI_connect();
    SPI_execute("SELECT 1 FROM missing_table", true, 0);
    SPI_finish();
}
PG_CATCH();
{
    /* Restore context & owner */
    MemoryContextSwitchTo(oldcontext);
    CurrentResourceOwner = oldowner;

    /* Clear the error so the transaction can continue */
    FlushErrorState();

    /* Finish SPI cleanly since it aborted mid-flight */
    SPI_finish();
    
    elog(WARNING, "SPI execution failed gracefully.");
}
PG_END_TRY();
```

## Checking if a Table Exists

Do this **before** calling SPI to avoid relying on `PG_CATCH` exceptions.

```c
Oid relid = RangeVarGetRelid(makeRangeVar("public", "my_table", -1), NoLock, true);

if (OidIsValid(relid))
{
    /* Table exists, safe to run SPI */
}
else
{
    /* Table does not exist */
}
```

## Extracting Arrays from SPI Results

If a column returns a `double precision[]` (like Word2Vec embeddings):

```c
Datum val = SPI_getbinval(tuple, tupdesc, 3, &isnull);
if (!isnull)
{
    ArrayType *arr = DatumGetArrayTypeP(val);
    int num_elements = ArrayGetNItems(ARR_NDIM(arr), ARR_DIMS(arr));
    float8 *elements = (float8 *) ARR_DATA_PTR(arr);

    /* Use elements[0] to elements[num_elements-1] */
}
```
