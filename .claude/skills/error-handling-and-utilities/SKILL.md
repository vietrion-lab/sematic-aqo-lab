---
name: error-handling-and-utilities
description: PG error reporting (ereport/elog), PG_TRY/CATCH/FINALLY, StringInfo, List ops, ArrayType conversion, SRF tuplestore pattern, ENR pattern.
user-invocable: false
---

# Error Handling & Common Utilities

## Error Reporting with `ereport`

```c
ereport(ERROR,
        (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
         errmsg("Invalid value for myext.mode: %s", value_str),
         errhint("Valid values are 'on', 'off', 'auto'.")));
```

*   `ERROR` aborts the transaction.
*   `WARNING` prints to client and log, but continues.
*   `LOG` prints to log only, continues.
*   `DEBUG1`..`DEBUG5` prints if `client_min_messages` or `log_min_messages` is set high enough.

**Shortcut:**
```c
elog(ERROR, "Something went terribly wrong! code=%d", code);
elog(DEBUG1, "Reached step 4.");
```

## Non-Fatal Exception Handling (`PG_TRY`)

If you want to catch an `ERROR` without aborting the entire process (useful in background workers or safely testing features):

```c
PG_TRY();
{
    /* Code that might ereport(ERROR, ...) */
    dangerous_function();
}
PG_CATCH();
{
    /* Catch block */
    ErrorData *edata;

    /* Copy error data before flushing */
    edata = CopyErrorData();
    FlushErrorState();

    elog(WARNING, "Caught an error: %s", edata->message);
    FreeErrorData(edata);
}
PG_FINALLY();
{
    /* Always executes (Note: variables declared here are NOT guaranteed to be initialized) */
}
PG_END_TRY();
```

## Building Strings Dynamically (`StringInfo`)

Safer and easier than `snprintf` + `malloc`.

```c
StringInfoData buf;

initStringInfo(&buf);
appendStringInfo(&buf, "SELECT * FROM %s WHERE id = %d", "my_table", 42);
appendStringInfoString(&buf, " AND active = true");
appendStringInfoChar(&buf, ';');

char *final_str = buf.data;

/* Optional: pfree(buf.data) when done */
```

## List Operations (`List *`)

PostgreSQL's built-in doubly-linked list.

```c
List *my_list = NIL;
ListCell *lc;

/* Append */
my_list = lappend(my_list, makeString("Item 1"));
my_list = lappend_int(my_list, 42);

/* Iterate */
foreach(lc, my_list)
{
    int val = lfirst_int(lc);
    /* ... */
}

/* Concat */
List *list2 = list_make2_int(1, 2);
my_list = list_concat(my_list, list2); /* list2 is consumed */
```

## Array Conversions (C Array ↔ `ArrayType`)

Converting a C `float8` array to a PG `double precision[]` Datum (useful for Word2Vec embeddings):

```c
float8 c_array[16] = {0.1, 0.2, /* ... */};
int dims[1] = {16};
int lbs[1] = {1};

ArrayType *pg_array = construct_md_array((Datum *) c_array,
                                         NULL, /* nulls bitmap */
                                         1,    /* ndims */
                                         dims, /* dims */
                                         lbs,  /* lower bounds */
                                         FLOAT8OID,
                                         sizeof(float8),
                                         true, /* pass-by-value */
                                         'd'); /* alignment ('d' for double) */

Datum result = PointerGetDatum(pg_array);
```

Converting back:
```c
ArrayType *pg_array = DatumGetArrayTypeP(result);
float8 *c_array = (float8 *) ARR_DATA_PTR(pg_array);
```

## System Catalog Lookups (`SearchSysCache1`)

Read metadata directly from PG catalogs (e.g., table names, operator types).

```c
HeapTuple tuple;
Form_pg_class classForm;
char *relname;

/* Lookup by Oid (relid) */
tuple = SearchSysCache1(RELOID, ObjectIdGetDatum(relid));
if (!HeapTupleIsValid(tuple))
    elog(ERROR, "cache lookup failed for relation %u", relid);

/* Cast tuple to specific struct */
classForm = (Form_pg_class) GETSTRUCT(tuple);

/* ALWAYS pstrdup strings from cache if you need them after ReleaseSysCache */
relname = pstrdup(NameStr(classForm->relname));

ReleaseSysCache(tuple);
```

## Set-Returning Functions (SRF)

Returning multiple rows from a C function using a `tuplestore`.

```c
Datum my_srf_func(PG_FUNCTION_ARGS)
{
    ReturnSetInfo *rsi;
    TupleDesc tupdesc;
    Tuplestorestate *tupstore;
    MemoryContext per_query_ctx;
    MemoryContext oldcontext;

    /* Initialize SRF context */
    rsi = (ReturnSetInfo *) fcinfo->resultinfo;
    per_query_ctx = rsi->econtext->ecxt_per_query_memory;
    oldcontext = MemoryContextSwitchTo(per_query_ctx);

    /* Build TupleDesc (assuming OUT parameters are defined in SQL) */
    get_call_result_type(fcinfo, NULL, &tupdesc);

    /* Create tuplestore */
    tupstore = tuplestore_begin_heap(true, false, work_mem);

    /* Generate rows */
    for (int i = 0; i < 10; i++)
    {
        Datum values[2];
        bool nulls[2] = {false, false};

        values[0] = Int32GetDatum(i);
        values[1] = CStringGetTextDatum("Row Data");

        tuplestore_putvalues(tupstore, tupdesc, values, nulls);
    }

    MemoryContextSwitchTo(oldcontext);

    /* Finish SRF */
    rsi->returnMode = SFRM_Materialize;
    rsi->setResult = tupstore;
    rsi->setDesc = tupdesc;

    PG_RETURN_NULL();
}
```

## Ephemeral Named Relations (ENR)

Pass custom data (like an extra table) from `ExecutorStart` to `ExecutorEnd` via `queryDesc->queryEnv`.

```c
/* In ExecutorStart */
if (queryDesc->queryEnv == NULL)
    queryDesc->queryEnv = create_queryEnv();

EphemeralNamedRelation enr = palloc0(sizeof(EphemeralNamedRelationData));
enr->md.name = pstrdup("my_temp_data");
enr->md.reliddesc = InvalidOid;
enr->md.enrtype = ENR_NAMED_TUPLESTORE;
enr->reldata = my_tuplestore;

RegisterENR(queryDesc->queryEnv, enr);

/* In ExecutorEnd */
EphemeralNamedRelation enr;
enr = get_ENR(queryDesc->queryEnv, "my_temp_data");
if (enr) {
    Tuplestorestate *ts = (Tuplestorestate *) enr->reldata;
    /* Read tuplestore */
}
```
