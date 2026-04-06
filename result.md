# Bug #6 (Dead Normalization Code) Investigation Report

## 1. `normalize_clause_for_w2v` function in `path_utils.c`
The `normalize_clause_for_w2v` function was originally implemented to normalize deparsed clauses for word2vec embedding. It stripped parentheses, removed `::cast` expressions, and replaced literals with special mask tokens (`<STR>`, `<DATE>`, `<TIMESTAMP>`, `<NUM>`, `<NULL>`).

According to git history, this function was completely **removed** in commit `af5b4f83a151322a0dd79503139af2b5de33dbee` by `hqvjet`.
Before its removal, the function was located at `src/postgresql-15.15/contrib/aqo/path_utils.c:1861-2044` (approximate).
Its declaration `char *normalize_clause_for_w2v(const char *input);` was also removed from `path_utils.h` in commit `092eae45c4556f4143fe7d03548ca3478c5127b7`.

## 2. Where it SHOULD be called
The normalization should ideally be called in the clause deparse flow in `path_utils.c`.
In `aqo_safe_deparse_expr` (lines ~686-1300), the clause is converted into a string (e.g., `aqo_safe_deparse_expr((Node *) clause->clause, root->parse->rtable)`).
Later, around line 1341 and 1821, `aqo_safe_deparse_expr` is called to generate `clause_str`.
The returned `clause_str` is accumulated into a buffer (`clause_buf`), which is then duplicated (`safe_copy = pstrdup(clause_buf.data);`) and passed directly into `w2v_extract_sql_embedding(safe_copy, 0.0f);` (lines 1370 and 1844).

The function `normalize_clause_for_w2v` should have been called to transform the output of `aqo_safe_deparse_expr` before passing it to `w2v_extract_sql_embedding`. The commit `af5b4f83a151322a0dd79503139af2b5de33dbee` replaced it by integrating a different logic inside `learn_sample()` using `deparse_expression` instead of `aqo_safe_deparse_expr`.

## 3. The W2V embedding extraction flow
1. **Deparse**: In `path_utils.c`, `aqo_safe_deparse_expr` converts Postgres expression trees into string representations (lines ~686-1300).
2. **Buffer Accumulation**: The clauses are appended together into `clause_buf.data`.
3. **Embedding Call**: `w2v_extract_sql_embedding` is called with the raw string (e.g., `src/postgresql-15.15/contrib/aqo/path_utils.c:1370` and `1844`).
4. **Tokenizer Entry Point**: Inside `w2v_extract_sql_embedding` (`src/postgresql-15.15/contrib/aqo/w2v_embedding_extractor.c:32`), it calls `preprocess_sql_query(sql)`.
5. **Tokenization**: `preprocess_sql_query` (`src/postgresql-15.15/contrib/aqo/sql_preprocessor.c:562`) processes the SQL string token by token.

## 4. Bug #2 relationship (tokenizer breaking masked tokens)
In `src/postgresql-15.15/contrib/aqo/sql_preprocessor.c`, around line 366, the tokenizer blindly treats `<` and `>` as operators:
```c
    /* Single character operators/punctuation */
    if (strchr("(),;.=<>+-*/", *p)) {
        token_buf[0] = *p;
        token_buf[1] = '\0';
        return p + 1;
    }
```
If `normalize_clause_for_w2v` had been correctly used to produce `<NUM>` or `<STR>`, the tokenizer would immediately break them apart into `<`, `NUM`, and `>` tokens. The bug is that the normalization was implemented as dead code, and even if it had been called, the downstream tokenizer would have destroyed its masked output.

## 5. All references to `normalize_clause_for_w2v`
- The code implementation and declaration were entirely removed in recent commits (`af5b4f83a151322a0dd79503139af2b5de33dbee` and `092eae45c4556f4143fe7d03548ca3478c5127b7`).
- A reference remains in `./plans/bug_investigation_evidence.md:282:## BUG #6 (Confirmed): normalize_clause_for_w2v là DEAD CODE` which documents this exact issue.
