# Tổng hợp 8 phương pháp nâng cấp Semantic AQO

**Ngày**: 2026-04-05
**Mục tiêu**: Tóm tắt ngắn gọn lý do, bằng chứng, sơ đồ luồng, và tài liệu tham khảo cho từng phương pháp.

---

## Tổng quan & Thứ tự triển khai

```
                    ┌─────────────────┐
                    │   Phase 0       │
                    │   Sửa bug       │
                    │   [BẮT BUỘC]    │
                    └────────┬────────┘
                             │
                ┌────────────┼────────────┐
                ▼                         ▼
   ┌─────────────────────┐   ┌─────────────────────┐
   │ Phase 1              │   │ Phase 1              │
   │ M1: Kết nối W2V     │   │ M4: Hash Lookup      │
   │ 🔴 NGHIÊM TRỌNG     │   │ 🟡 CAO               │
   └──────────┬──────────┘   └─────────────────────┘
              │
    ┌─────────┼──────────────────────┐
    ▼                                ▼
┌─────────────────────┐   ┌─────────────────────┐
│ Phase 2              │   │ Phase 5              │
│ M2: Chuẩn hóa       │   │ M7: Nhúng theo mệnh │
│ 🔴 NGHIÊM TRỌNG     │   │     đề — 🔵 TƯƠNG LAI│
└──────────┬──────────┘   └─────────────────────┘
           │
    ┌──────┼──────────────────┐
    ▼      ▼                  ▼
┌────────────────┐ ┌──────────────┐ ┌──────────────┐
│ Phase 3        │ │ Phase 3      │ │ Phase 4      │
│ M3: Pooling    │ │ M5: k-NN    │ │ M8: Suy giảm │
│ thông minh 🟡  │ │ thích ứng 🟢 │ │ dữ liệu 🟢   │
└───────┬────────┘ └──────────────┘ └──────────────┘
        ▼
┌────────────────┐
│ Phase 5        │
│ M6: MSCN       │
│ 🔵 TƯƠNG LAI   │
└────────────────┘
```

| Phase | Phương pháp                                   | Trọng tâm              |
| ----- | --------------------------------------------- | ---------------------- |
| **0** | Sửa bug (threshold, lr, div-by-zero, rfactor) | Tính đúng đắn          |
| **1** | M4 (hash) + M1 (kết nối W2V)                  | Chức năng lõi          |
| **2** | M2 (chuẩn hóa khoảng cách)                    | Để W2V thực sự hữu ích |
| **3** | M3 (pooling) + M5 (adaptive k)                | Cải thiện chất lượng   |
| **4** | M8 (suy giảm dữ liệu cũ)                      | Độ bền vững            |
| **5** | M6 (MSCN) hoặc M7 (per-clause)                | Hướng nghiên cứu       |

---

## Phase 0: Sửa bug trước

**File**: `machine_learning.c`

| Bug                           | Hiện tại              | Sửa thành                     |
| ----------------------------- | --------------------- | ----------------------------- |
| Ngưỡng merge quá chặt         | `0.1`                 | `0.6`                         |
| Learning rate quá cao         | `0.1`                 | `0.01`                        |
| Chia cho 0 (~dòng 288)        | `/ distances[idx[i]]` | `if (dist < 1e-10) continue;` |
| Sai index rfactor (~dòng 280) | `rfactors[mid]`       | `rfactors[idx[i]]`            |

---

## M1: Kết nối W2V Embedding vào Pipeline dự đoán

### Lý do

Bug nghiêm trọng nhất: W2V embedding được tính trong `w2v_embedding_extractor.c` nhưng **chỉ ghi vào bảng diagnostics** `aqo_node_context`. Vector đặc trưng truyền cho `OkNNr_predict()` **chỉ chứa log-selectivity**, không có thông tin ngữ nghĩa.

### Bằng chứng

- ARCHITECTURE.md §3 "Caterpillar Model" định nghĩa vector 17 chiều (16 W2V + 1 selectivity) — nhưng thực tế chưa bao giờ được tạo ra.
- Code trace: `predict_for_relation()` → `get_fss_for_object()` → `OkNNr_predict(data, features)` — không đoạn nào gọi `w2v_extract_sql_embedding()`.

### Luồng hiện tại (lỗi)

```
  ┌─────────────────┐   ┌─────────────────┐
  │  Query Clauses  │   │  Selectivities  │
  └────────┬────────┘   └────────┬────────┘
           └──────────┬──────────┘
                      ▼
            ┌───────────────────┐
            │ get_fss_for_obj() │
            └────────┬──────────┘
                     ▼
    ┌──────────────────────────────────┐
    │ features = [log(sel₁)..log(selₙ)]│
    └────────────────┬─────────────────┘
                     ▼
          ┌─────────────────────┐
          │ OkNNr_predict(feat) │
          └──────────┬──────────┘
                     ▼
         ┌───────────────────────┐
         │ Estimated Cardinality │
         └───────────────────────┘

  ╔═══════════════════════════════════╗
  ║ w2v_extract_sql_embedding()      ║  ← ❌ TÍNH XONG
  ╚══════════════╤════════════════════╝       rồi VỨT
                 ▼
  ╔═══════════════════════════════════╗
  ║ aqo_node_context (diagnostics)   ║  ← ❌ KHÔNG BAO GIỜ
  ║                                  ║     vào pipeline dự đoán
  ╚═══════════════════════════════════╝
```

### Luồng sau khi sửa

```
  ┌──────────────┐                       ┌──────────────┐
  │ Query Clauses│                       │ Selectivities│
  └───┬──────┬───┘                       └───────┬──────┘
      │      └────────────┐                      │
      ▼                   ▼                      ▼
 ┌────────────────┐  ┌───────────────────┐
 │ Deparse +      │  │ get_fss_for_obj() │
 │ Normalize      │  └────────┬──────────┘
 └───────┬────────┘           ▼
         ▼           ┌─────────────────────────┐
 ┌─────────────────┐ │ sel_features =          │
 │ w2v_extract_sql │ │ [log(sel₁)..log(selₙ)] │
 │ _embedding() ✅ │ └────────────┬────────────┘
 └───────┬─────────┘              │
         ▼                        │
 ┌─────────────────┐              │
 │ semantic_vec     │              │
 │ = 16 chiều  ✅  │              │
 └───────┬─────────┘              │
         └───────────┬────────────┘
                     ▼
    ┌────────────────────────────────────┐
    │ ✅ concat(semantic_vec, sel_feat)  │
    │    → features = [16 + n] chiều    │
    └────────────────┬───────────────────┘
                     ▼
          ┌─────────────────────┐
          │ OkNNr_predict(feat) │
          └──────────┬──────────┘
                     ▼
         ┌───────────────────────┐
         │ Estimated Cardinality │
         └───────────────────────┘
```

### File cần sửa

| File                       | Thay đổi                                                              |
| -------------------------- | --------------------------------------------------------------------- |
| `cardinality_estimation.c` | Thêm `build_semantic_features()`, sửa `predict_for_relation()`        |
| `postprocessing.c`         | Sửa `learn_sample()` — cùng logic concat                              |
| `node_context.c/h`         | Bỏ `static` khỏi `nce_tokenize_literals()`, `nce_remove_type_casts()` |
| `Makefile`                 | Thêm `w2v_inference.o w2v_embedding_extractor.o sql_preprocessor.o`   |

### Ref

- Anisimov et al. (2020), _AQO: Adaptive Query Optimization_, Postgres Professional
- ARCHITECTURE.md §3 "Caterpillar Model"

---

## M2: Chuẩn hóa khoảng cách theo chiều

### Lý do

Sau khi M1 kết nối W2V, khoảng cách Euclidean bị **chi phối bởi selectivity** vì phạm vi quá khác nhau:

- W2V: `[-1, +1]` → biên độ ~2
- log(selectivity): `[-30, 0]` → biên độ ~30

Không chuẩn hóa → W2V chỉ đóng góp ~1% vào khoảng cách → **bị bỏ qua hoàn toàn**.

### Bằng chứng

- Aggarwal et al. (2001) chứng minh L2 distance **mất khả năng phân biệt** khi các chiều có scale khác nhau trong không gian chiều cao.
- Ioffe & Szegedy (2015): chuẩn hóa input là điều kiện tiên quyết cho mọi hệ thống distance-based.

### Sơ đồ

```
  ┌──────────────────────────────────────┐
  │ Feature Vector                       │
  │ [w2v₁..w2v₁₆, log_sel₁..log_selₙ]  │
  └──────────────────┬───────────────────┘
                     ▼
          ┌─────────────────────┐
          │  fs_distance(a, b)  │
          └──────────┬──────────┘
                     ▼
            ┌─────────────────┐
            │ Với mỗi chiều i │
            └────────┬────────┘
                     ▼
                ╔═══════════╗
                ║  i < 16?  ║
                ╚═════╤═════╝
            ┌─────────┴─────────┐
         CÓ │                   │ KHÔNG
            ▼                   ▼
  ┌───────────────────┐   ┌───────────────────────┐
  │ weight = 1.0      │   │ weight = λ (mặc định  │
  │ (chiều ngữ nghĩa) │   │ 0.1, chiều selectivity)│
  └─────────┬─────────┘   └───────────┬───────────┘
            └──────────┬───────────────┘
                       ▼
       ┌─────────────────────────────────┐
       │ sum += weight × (aᵢ - bᵢ)²     │
       └────────────────┬────────────────┘
                        ▼
              ┌──────────────────┐
              │ distance = √sum  │
              └──────────────────┘
```

Công thức: $d_w(a, b) = \sqrt{\sum_{i=0}^{D-1} w_i \cdot (a_i - b_i)^2}$

| Giá trị λ | Hiệu ứng                                            |
| --------- | --------------------------------------------------- |
| 0.01      | Khoảng cách gần như chỉ dựa vào ngữ nghĩa           |
| **0.1**   | **Cân bằng (khuyến nghị)**                          |
| 1.0       | Bằng nhau (nhưng selectivity vẫn trội do range lớn) |

### File cần sửa

`machine_learning.c` → `fs_distance()`, `aqo.c` → GUC `aqo.selectivity_weight`, `aqo.h`

### Ref

- Aggarwal, Hinneburg & Keim (2001), _On the Surprising Behavior of Distance Metrics in High Dimensional Space_, ICDT

---

## M3: Thay Gaussian Averaging bằng TF-IDF + Role-Aware Pooling

### Lý do

`w2v_extract_sql_embedding()` hiện dùng **trọng số Gaussian theo vị trí** (tâm chuỗi). 3 vấn đề:

1. **Thiên vị trung tâm**: token quan trọng không luôn ở giữa
2. **Không nhận biết nội dung**: trọng số chỉ phụ thuộc vị trí
3. **Pha loãng ngữ nghĩa**: token tần suất cao (AND, =, WHERE) chi phối trung bình

### Bằng chứng

- Arora et al. (2017): SIF weighting ($w_i = \frac{a}{a + p(w_i)}$) vượt trội plain averaging lớn trong sentence embedding.
- Rücklé et al. (2018): nối nhiều chiến lược pooling (mean, max) nắm bắt cấu trúc tốt hơn bất kỳ pooling đơn lẻ nào.

### Sơ đồ: 3-Channel Pooling

```
                 ┌──────────────────────┐
                 │  Masked SQL Tokens   │
                 └──────────┬───────────┘
                            ▼
               ┌────────────────────────┐
               │ Phân loại vai trò      │
               │ từng token             │
               └──┬─────────┬──────────┬┘
                  │         │          │
       ┌──────────┘         │          └──────────┐
       ▼                    ▼                     ▼
┌──────────────┐  ┌────────────────┐  ┌──────────────────┐
│ Predicates   │  │ Structure      │  │ Tất cả tokens    │
│ (cột, toán   │  │ (AND, OR,      │  │                  │
│  tử, literal)│  │  JOIN, WHERE)  │  │                  │
└──────┬───────┘  └───────┬────────┘  └────────┬─────────┘
       ▼                  ▼                    ▼
┌──────────────┐  ┌────────────────┐  ┌──────────────────┐
│ SIF weight   │  │ SIF weight     │  │ Element-wise     │
│ × embedding  │  │ × embedding    │  │ MAX              │
└──────┬───────┘  └───────┬────────┘  └────────┬─────────┘
       ▼                  ▼                    ▼
┌──────────────┐  ┌────────────────┐  ┌──────────────────┐
│ Trung bình   │  │ Trung bình     │  │ Max Pool         │
│ → 8 chiều    │  │ → 4 chiều      │  │ → 4 chiều        │
└──────┬───────┘  └───────┬────────┘  └────────┬─────────┘
       └──────────┬───────┴────────────────────┘
                  ▼
       ┌──────────────────┐
       │   Nối lại        │
       └────────┬─────────┘
                ▼
    ┌────────────────────────┐
    │ [pred(8)||struct(4)||  │
    │  max(4)] = 16 chiều   │
    │ (cùng kích thước đầu  │
    │  ra, ko cần migrate)  │
    └────────────────────────┘
```

### File cần sửa

`sql_preprocessor.c/h` → thêm `TokenRole` enum + `classify_token_role()` ; `w2v_embedding_extractor.c` → thay body `w2v_extract_sql_embedding()`

### Ref

- Arora et al. (2017), _A Simple but Tough-to-Beat Baseline for Sentence Embeddings_, ICLR
- Rücklé et al. (2018), _Concatenated Power Mean Word Embeddings_, RepL4NLP

---

## M4: Tra cứu token O(1) thay vì O(n)

### Lý do

`extractor_get_word_id()` duyệt tuyến tính 301 entries cho mỗi token. Với ~15 token/sub-query × hàng trăm sub-query trên JOB → **~170ms overhead**.

### Bằng chứng

Profiling cho thấy thời gian trong `extractor_get_word_id()` chiếm đa số chi phí embedding. Hash table O(1) amortized vs O(n) linear scan.

### Sơ đồ

```
  ┌─────────────────────────────────────────────────────┐
  │  HIỆN TẠI: O(n)                                     │
  │                                                     │
  │  token ──▶ ❌ strcmp loop (i=0..300) ──▶ word_id/-1 │
  └─────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────┐
  │  ĐỀ XUẤT: O(1)                                     │
  │                                                     │
  │  token ──▶ ✅ hash_search(HTAB) ──▶ word_id/-1     │
  └─────────────────────────────────────────────────────┘
```

### File cần sửa

`w2v_inference.c` → thêm `HTAB *vocab_htab`, `build_vocab_hashtable()`, thay `extractor_get_word_id()`

### Ref

- PostgreSQL `dynahash.c` — hash table tích hợp, O(1) amortized

---

## M5: k-NN thích ứng theo mật độ cục bộ

### Lý do

k cố định (=2) không phù hợp mọi vùng:

- **Vùng thưa**: k nhỏ để tránh kéo neighbor xa, gây sai lệch
- **Vùng dày**: k lớn hơn → dự đoán ổn định hơn nhờ trung bình hóa

### Bằng chứng

- Anava & Levy (2016): k cục bộ dựa trên validation error vượt trội k cố định trên mọi dataset thử nghiệm.
- Các spike execution time ở JOB iteration 8, 11 có thể do k cố định kéo neighbor sai.

### Sơ đồ

```
  ┌────────────────────────────────────┐
  │ Tính khoảng cách đến mọi neighbor │
  └─────────────────┬──────────────────┘
                    ▼
         ┌───────────────────┐
         │ Sắp xếp theo d   │
         └─────────┬─────────┘
                   ▼
       ╔═════════════════════════╗
       ║ d[i]/d[i-1] > 2.0 ?    ║
       ╚════════╤════════════════╝
         CÓ│          │KHÔNG
            ▼          ▼
 ┌──────────────────┐  ┌────────────────────┐
 │ effective_k = i  │  │ Tiếp tục neighbor  │─┐
 │ (dừng trước gap) │  │ kế tiếp            │ │
 └────────┬─────────┘  └────────────────────┘ │
          ▼                 (lặp lại) ─────────┘
 ┌──────────────────────┐
 │ Giới hạn: 2 ≤ k ≤ 5 │
 └────────┬─────────────┘
          ▼
 ┌───────────────────────────┐
 │ Dự đoán có trọng số với  │
 │ effective_k neighbors     │
 └───────────────────────────┘
```

Ví dụ gap ratio:

```
Neighbors:  d=0.1  d=0.15  d=0.18  |gap|  d=0.55  d=0.8
                                     ↑
                              ratio = 0.55/0.18 = 3.05 > 2.0
                              → dùng k=3 (chỉ 3 gần nhất)
```

### File cần sửa

`machine_learning.c` → `OkNNr_predict()`, `aqo.c` → GUC `aqo.adaptive_k`

### Ref

- Anava & Levy (2016), _k-Nearest Neighbors: From Global to Local_, NeurIPS

---

## M6: MSCN Encoding (Tương lai)

### Lý do

W2V được huấn luyện trên **đồng xuất hiện từ** (word co-occurrence), không phải trên **bài toán ước lượng cardinality**. Embedding có thể không tối ưu cho downstream task.

### Bằng chứng

Kipf et al. (2019): MSCN encode tables, joins, predicates thành 3 tập độc lập → set convolution → nối lại. Đạt state-of-the-art trên JOB. Q-error giảm 30-50% so với phương pháp truyền thống.

### Sơ đồ

```
  ═══════════ OFFLINE (Python) ═══════════

  Benchmark queries + true cardinalities
            │
            ▼
  ┌───────────────────────────┐
  │ Train MicroMSCN           │
  └────────────┬──────────────┘
               ▼
  ┌───────────────────────────┐
  │ Extract embedding cho mỗi │
  │ unique clause pattern     │
  └────────────┬──────────────┘
               ▼
  ┌───────────────────────────┐
  │ load-token-embeddings.py  │
  │ → bảng token_embeddings   │
  └─────────────┬─────────────┘
                │
  ═══════════ RUNTIME (C, không đổi) ═════
                │
                ▼  (cùng bảng, vector tốt hơn)
  Query → Lookup → Pooling 16-dim → k-NN predict
```

**Ý tưởng chính**: Huấn luyện model embedding tốt hơn offline, nhưng **giữ nguyên code C runtime**. Chỉ thay nội dung bảng `token_embeddings`.

### Ref

- Kipf et al. (2019), _Learned Cardinalities: Estimating Correlated Joins with Deep Learning_, CIDR

---

## M7: Nhúng theo mệnh đề (Clause-Level) (Tương lai)

### Vấn đề

Nhúng toàn bộ query thành 1 vector → **"vector collapse"**: query có cấu trúc khác nhau nhận vector giống nhau sau khi averaging.

### Bằng chứng

- Dutt et al. (2019): micro-model per-predicate tốt hơn one-model-per-query cho range predicates.
- Negi et al. (2023): factorized approach xử lý workload drift tốt hơn.

### Sơ đồ: Hiện tại vs. Đề xuất

```
  HIỆN TẠI (query-level):

  clause₁ ─┐
  clause₂ ─┼──▶ ❌ Gộp hết ──▶ 1 vector 17-dim ──▶ 1 k-NN ──▶ Cardinality
  clause₃ ─┘

  ĐỀ XUẤT (clause-level):

  clause₁: age > NUM   ──▶ ✅ embed₁ + log_sel₁ ──▶ k-NN → pred₁ ──┐
  clause₂: total < NUM ──▶ ✅ embed₂ + log_sel₂ ──▶ k-NN → pred₂ ──┼──▶ avg() ──▶ Cardinality
  clause₃: id = uid    ──▶ ✅ embed₃ + log_sel₃ ──▶ k-NN → pred₃ ──┘
```

**Lợi ích**: Mệnh đề `age > <NUM>` học từ query A **chuyển giao** sang mọi query B cũng chứa `age > <NUM>`. Ví dụ: "3+5+7" thì sẽ học được "3+5', "5+7", khi gặp "3+5+9" thì sẽ tái sử dụng được knowleage 3+5 cũ đã học, nếu chỉ có embedding cả vector 3+5+7 thì gặp 3+5+9 nó cũng cho là tương đồng-> propose: Semantic decomposition (phân rã theo ý nghĩa điều kiện)


### Ref

- Dutt et al. (2019), _Selectivity Estimation for Range Predicates_, PVLDB
- Negi et al. (2023), _Robust Query Driven Cardinality Estimation_, PVLDB

---

## M8: Suy giảm dữ liệu cũ theo hàm mũ

### Lý do

Ma trận `aqo_data` lưu tối đa 30 data points mỗi feature subspace. Dữ liệu cũ có thể phản ánh phân phối lỗi thời (sau INSERT/DELETE/schema change). **Không có cơ chế quên**.

### Bằng chứng

- Gama et al. (2014): exponential decay là chuẩn mực cho concept drift.
- Hilprecht et al. (2020): thống kê cũ làm suy giảm chất lượng cardinality estimation.

### Sơ đồ

```
  ┌───────────────────────────────┐
  │ Observation mới đến           │
  └──────────────┬────────────────┘
                 ▼
  ┌───────────────────────────────┐
  │ Giảm trọng số tất cả rows:   │
  │ rfactor[i] *= 0.995           │
  └──────────────┬────────────────┘
                 ▼
         ╔════════════════════╗
         ║ rfactor < 0.01 ?   ║
         ╚═══════╤════════════╝
           CÓ│       │KHÔNG
              ▼       ▼
     ┌──────────────┐  ┌──────────┐
     │ Loại bỏ rows │  │ Giữ hết  │
     │ quá cũ       │  └────┬─────┘
     └──────┬───────┘       │
            └───────┬───────┘
                    ▼
     ┌─────────────────────────┐
     │ OkNNr_learn() bình thường│
     └─────────────────────────┘

  Prediction: weight = similarity(dist) × rfactor[i]
```

Với `decay = 0.995`, một data point mất nửa trọng số sau ~138 bước: $0.995^{138} \approx 0.5$

### File cần sửa

`machine_learning.c` → `OkNNr_learn()` + `OkNNr_predict()`, `aqo.c` → GUC `aqo.decay_rate`

### Ref

- Gama et al. (2014), _A Survey on Concept Drift Adaptation_, ACM Computing Surveys
- Hilprecht et al. (2020), _DeepDB: Learn from Data, not from Queries!_, PVLDB

---

## Tài liệu tham khảo

1. Anisimov et al. (2020). _AQO: Adaptive Query Optimization_. Postgres Professional.
2. Arora et al. (2017). _A Simple but Tough-to-Beat Baseline for Sentence Embeddings_. ICLR.
3. Kipf et al. (2019). _Learned Cardinalities_. CIDR.
4. Anava & Levy (2016). _k-NN: From Global to Local_. NeurIPS.
5. Aggarwal et al. (2001). _Distance Metrics in High Dimensional Space_. ICDT.
6. Ioffe & Szegedy (2015). _Batch Normalization_. arXiv:1502.03167.
7. Rücklé et al. (2018). _Concatenated Power Mean Word Embeddings_. RepL4NLP.
8. Dutt et al. (2019). _Selectivity Estimation for Range Predicates_. PVLDB.
9. Negi et al. (2023). _Robust Query Driven Cardinality Estimation_. PVLDB.
10. Gama et al. (2014). _A Survey on Concept Drift Adaptation_. ACM Computing Surveys.
11. Hilprecht et al. (2020). _DeepDB_. PVLDB.
