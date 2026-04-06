---
name: hook-chaining
description: Save→install→chain pattern for PG hooks. Full catalog of 13 SAQO hooks (shmem, planner, executor, explain). Exclusive hook conflict detection.
user-invocable: false
---

# Hook Chaining

## The Save → Install → Chain Pattern

PostgreSQL allows extensions to intercept core functionality by overwriting global function pointers (hooks). Because multiple extensions might use the same hook (e.g., `pg_stat_statements` and `aqo`), you **must** chain them.

### Step 1: Declare Static Variables

Save the previous hook value globally in your C file.

```c
static planner_hook_type prev_planner_hook = NULL;
```

### Step 2: Install in `_PG_init`

Save the current value of the global hook, then overwrite it with yours.

```c
void _PG_init(void)
{
    /* ... */
    prev_planner_hook = planner_hook;
    planner_hook = my_planner_hook;
    /* ... */
}
```

### Step 3: Chain in Your Hook

Always call the previous hook. If there wasn't one, call the standard PostgreSQL function.

```c
PlannedStmt *
my_planner_hook(Query *parse, const char *query_string, int cursorOptions, ParamListInfo boundParams)
{
    PlannedStmt *result;

    /* YOUR PRE-PLANNING LOGIC HERE */

    /* Chain to previous hook or standard function */
    if (prev_planner_hook)
        result = prev_planner_hook(parse, query_string, cursorOptions, boundParams);
    else
        result = standard_planner(parse, query_string, cursorOptions, boundParams);

    /* YOUR POST-PLANNING LOGIC HERE */

    return result;
}
```

---

## The "NULL-Allowed" Variant

Some hooks don't have a `standard_` fallback. If the previous hook is `NULL`, you just don't call anything (or you implement the default behavior yourself).

Example: `ExecutorEnd_hook`

```c
void my_ExecutorEnd(QueryDesc *queryDesc)
{
    /* YOUR LOGIC HERE */

    if (prev_ExecutorEnd)
        prev_ExecutorEnd(queryDesc);
    else
        standard_ExecutorEnd(queryDesc);
}
```

Example: `ExplainOneQuery_hook` (no standard fallback)

```c
void my_ExplainOneQuery(Query *query, int cursorOptions, IntoClause *into, ExplainState *es, const char *queryString, ParamListInfo params, QueryEnvironment *queryEnv)
{
    if (prev_ExplainOneQuery)
        prev_ExplainOneQuery(query, cursorOptions, into, es, queryString, params, queryEnv);
    else
        /* Re-implement default behavior if needed */
        ExplainOneQuery_hook_fallback(query, cursorOptions, into, es, queryString, params, queryEnv);
}
```

---

## The "Exclusive" Hook Variant

Some hooks represent internal functions that only one extension should override. `get_relation_info_hook` is one of them.

```c
void _PG_init(void)
{
    if (get_relation_info_hook != NULL)
    {
        ereport(ERROR,
                (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
                 errmsg("get_relation_info_hook is already assigned"),
                 errhint("Another extension is providing cardinality estimates.")));
    }
    get_relation_info_hook = my_get_relation_info;
}
```

---

## Full Catalog: SAQO Hooks

| Hook Name | Category | Purpose in SAQO |
| :--- | :--- | :--- |
| `shmem_request_hook` | Bootstrap | Calculate & request shared memory + DSA size |
| `shmem_startup_hook` | Bootstrap | Initialize Hash Tables & Locks |
| `planner_hook` | Planner | Reset memory contexts, start planning |
| `get_relation_info_hook` | Planner | **Core**: Provide our custom cardinality estimates |
| `set_rel_pathlist_hook` | Planner | Inject custom paths |
| `set_join_pathlist_hook` | Planner | Inspect join paths |
| `ExecutorStart_hook` | Executor | Setup instrumentation (True rows) |
| `ExecutorRun_hook` | Executor | Intercept execution |
| `ExecutorFinish_hook` | Executor | Intercept finish |
| `ExecutorEnd_hook` | Executor | **Core**: Harvest true rows & trigger machine learning |
| `ExplainOneQuery_hook` | Explain | Inject EXPLAIN ANALYZE metadata |
| `ProcessUtility_hook` | Utility | Intercept DDL (e.g., DROP TABLE) to clean cache |
