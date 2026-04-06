---
name: expression-trees-and-walkers
description: PG query tree traversal: expression_tree_mutator, planstate_tree_walker, path type switch, safe custom deparser, node macros, catalog lookups.
user-invocable: false
---

# Expression Trees & Walkers

## Walking Query Trees (`expression_tree_mutator`)

PostgreSQL provides a standard `expression_tree_mutator` macro to traverse and modify the abstract syntax tree of a query (the `Node` tree).

**Use case**: Finding all instances of a specific node type (like `Var` or `Const`) and replacing them, or extracting information from them.

```c
static Node *
my_tree_mutator(Node *node, void *context)
{
    if (node == NULL)
        return NULL;

    /* Is it the node type we are looking for? */
    if (IsA(node, Const))
    {
        Const *c = (Const *) node;
        /* Do something with the constant */

        /* Modify it (e.g. replace with a NULL Const) */
        return (Node *) makeNullConst(c->consttype, c->consttypmod, c->constcollid);
    }

    /* Keep recursing down the tree */
    return expression_tree_mutator(node, my_tree_mutator, context);
}

/* Entry point */
Node *modified_tree = my_tree_mutator(original_tree, my_context_struct);
```

## Walking Plan Trees (`planstate_tree_walker`)

After a query is planned, the executor uses a `PlanState` tree. You can walk this tree during execution (e.g. in `ExecutorStart` or `ExecutorEnd`) to gather statistics or inspect the chosen plan.

**Use case**: Finding all SeqScan or IndexScan nodes and reading their `instrument` data (actual row counts vs estimated).

```c
static bool
my_planstate_walker(PlanState *node, void *context)
{
    if (node == NULL)
        return false;

    switch (nodeTag(node))
    {
        case T_SeqScanState:
        case T_IndexScanState:
        case T_IndexOnlyScanState:
            /* Inspect the instrumentation data */
            if (node->instrument)
            {
                double actual_rows = node->instrument->ntuples;
                double est_rows = node->plan->plan_rows;
            }
            break;
        default:
            break;
    }

    /* Recurse down to children */
    return planstate_tree_walker(node, my_planstate_walker, context);
}

/* Entry point */
my_planstate_walker(queryDesc->planstate, my_context_struct);
```

## Walking Path Trees (Planner Hook)

During planning (e.g. `set_rel_pathlist_hook`), you often inspect `Path` nodes to adjust costs or add new paths.

**Use case**: Finding the path that represents a sequential scan and adding a penalty cost.

```c
void my_set_rel_pathlist(PlannerInfo *root, RelOptInfo *rel, Index rti, RangeTblEntry *rte)
{
    ListCell *lc;

    foreach(lc, rel->pathlist)
    {
        Path *path = (Path *) lfirst(lc);

        switch (path->pathtype)
        {
            case T_SeqScan:
                /* Modify the cost of the SeqScan path */
                path->startup_cost += 100.0;
                path->total_cost += 1000.0;
                break;
            case T_IndexScan:
                /* Inspect index scan path */
                break;
            default:
                break;
        }
    }
}
```

## Safe Custom Deparser (SQL stringifier)

PostgreSQL's built-in `deparse_expression` cannot handle certain internal node types (like `Aggref`, `WindowFunc`, or `SubPlan`). It throws an ERROR.

If you are deparsing an arbitrary expression tree (e.g. for hashing or logging), you need a custom walker that intercepts these nodes before calling `deparse_expression`.

```c
static Node *
my_safe_deparse_mutator(Node *node, void *context)
{
    if (node == NULL)
        return NULL;

    /* These nodes crash deparse_expression. Replace them with dummy Consts. */
    if (IsA(node, Aggref) || IsA(node, WindowFunc) || IsA(node, SubPlan))
    {
        return (Node *) makeConst(INT4OID, -1, InvalidOid, sizeof(int32),
                                  Int32GetDatum(0), false, true);
    }

    return expression_tree_mutator(node, my_safe_deparse_mutator, context);
}

/* Usage */
Node *safe_tree = my_safe_deparse_mutator(unsafe_tree, NULL);
char *sql_string = deparse_expression(safe_tree, dpcontext, true, false);
```

## Important Node Macros & Functions

| Macro/Function | Description |
| :--- | :--- |
| `IsA(node, Type)` | Returns true if the node pointer is of the specified `Type`. |
| `nodeTag(node)` | Returns the enum tag of the node (e.g. `T_Var`, `T_Const`). |
| `castNode(Type, node)` | Casts the node pointer to the specified `Type` struct. |
| `foreach(cell, list)` | Loop over a PostgreSQL `List`. Use `lfirst(cell)` or `lfirst_node(Type, cell)` to get the item. |
| `bms_next_member(bms, -1)` | Iterate through a `Bitmapset` (used heavily in planner for relids). |
| `get_attname(relid, attnum, missing_ok)` | Lookup column name from system catalogs. |
| `get_opname(opno)` | Lookup operator name (e.g. `=`, `<`, `LIKE`) from catalogs. |
| `SearchSysCache1(...)` | Low-level catalog lookup. See the `SysCache` cookbook for the full pattern (Search -> Get -> Copy -> Release). |
