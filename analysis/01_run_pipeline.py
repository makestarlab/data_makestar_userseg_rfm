"""
RFM + Dimension 전체 파이프라인 실행
bq CLI 사용 (vw_commerce_items_v2 Drive 권한 필요)

실행:
  source ~/bq-analysis/.venv/bin/activate
  python3 analysis/01_run_pipeline.py
"""

import subprocess
import json
from pathlib import Path

PROJECT = "makestar-dw"
QUERIES_DIR = Path(__file__).parent.parent / "queries"


def bq_run(sql: str, label: str = ""):
    """bq CLI로 쿼리 실행 (DDL/DML — stdin, 타임아웃 없음)"""
    print(f"  실행 중: {label}...")
    result = subprocess.run(
        ["bq", "query", "--use_legacy_sql=false",
         "--batch=false",
         f"--project_id={PROJECT}"],
        input=sql, capture_output=True, text=True,
        timeout=3600
    )
    if result.returncode != 0:
        raise Exception(f"{label} 실패:\n{result.stderr}")
    print(f"  ✓ {label} 완료")


def bq_query(sql: str):
    """bq CLI로 SELECT 쿼리 실행 → list[dict]"""
    result = subprocess.run(
        ["bq", "query", "--use_legacy_sql=false", "--format=json",
         "--batch=false", "--nosynchronous_mode",
         f"--project_id={PROJECT}"],
        input=sql, capture_output=True, text=True,
        timeout=300
    )
    if result.returncode != 0:
        raise Exception(result.stderr)
    return json.loads(result.stdout) if result.stdout.strip() else []


# ─── Step 1: RFM 스코어 저장 ──────────────────────────────────────
RFM_SAVE_SQL = """
CREATE OR REPLACE TABLE `makestar-dw.datamart.user_rfm_score` AS
WITH agents AS (
  SELECT user_id FROM UNNEST([
    '1876860','812307','1736734','621230','1302313','1902098','859600','969308',
    '1027784','1581799','797962','802866','1492647','781240','885795','1264675',
    '1001311','2116643','1659287','700815','1540460','1890901','1511280','1006060',
    '1606082','1552669','1913216','1138597','1284854','1504890','12526','944286',
    '945344','2046425','1545878','1600974','886898','1539934','1533310','911936',
    '1069252','971976','1658602','948579','1071325','1995221','1933087','636546',
    '1509180','1257147','2032775','1323619','1958765','864765','1994769','209076',
    '1608153','1312465','1355103','1248833','1506290','965150','1011224','1260938',
    '625886','939836','1870283','1347032','1939835','1973097','2022335','1335644',
    '1975403','646210','1542033','910047','1995697','882978','1252380','2159123',
    '867147','942107','1329252','71764','1845002','999056','809695','1604186',
    '1506617','1006091','870982','1895495','1052115','1313023','1254035','1063330',
    '2050980','1550897','1660416','1620875','946338','1482920','1253405','1502990',
    '91909','1738982','2114301','1005028','1513305','1874153','1267050','1354020',
    '1062950','905126','1071819','1935908','1073305','1247698','898061','943715',
    '1673444','1334025','1982712','1290379','1503928','1502504','2159410'
  ]) AS user_id
),
recency AS (
  SELECT
    CAST(id AS STRING) AS user_id,
    DATE_DIFF(CURRENT_DATE('Asia/Seoul'), DATE(last_login, 'Asia/Seoul'), DAY) AS r_raw
  FROM `makestar-dw.pg_mystarroom_public.tb_auth_user`
  WHERE last_login IS NOT NULL AND is_certified = TRUE AND is_withdrawn = FALSE
),
orders AS (
  SELECT o.user_id, o.order_no, o.total_revenue, e.artist_id, e.album_name
  FROM `makestar-dw.datamart.total_orders` o
  LEFT JOIN `makestar-dw.datamart.events_` e ON o.event_id = e.event_id
  WHERE o.market_type IN ('B2C','B2B')
    AND o.data_source = 'new_commerce_db'
    AND o.user_id NOT IN (SELECT user_id FROM agents)
),
frequency AS (
  SELECT
    user_id,
    SAFE_DIVIDE(
      COUNT(DISTINCT CONCAT(artist_id,'||',album_name)),
      COUNT(DISTINCT artist_id)
    ) AS f_raw
  FROM orders WHERE artist_id IS NOT NULL AND album_name IS NOT NULL
  GROUP BY user_id
),
monetary AS (
  SELECT user_id, SUM(total_revenue) AS m_raw FROM orders GROUP BY user_id
),
base AS (
  SELECT r.user_id, r.r_raw,
    COALESCE(f.f_raw, 0) AS f_raw,
    COALESCE(m.m_raw, 0) AS m_raw
  FROM recency r
  LEFT JOIN frequency f ON r.user_id = f.user_id
  LEFT JOIN monetary  m ON r.user_id = m.user_id
  WHERE COALESCE(m.m_raw, 0) > 0
)
SELECT
  user_id, r_raw, f_raw, m_raw,
  6 - NTILE(5) OVER (ORDER BY r_raw ASC) AS r_score,
  NTILE(5) OVER (ORDER BY f_raw ASC)     AS f_score,
  NTILE(5) OVER (ORDER BY m_raw ASC)     AS m_score
FROM base
"""

# ─── Step 2: Dimension 저장 ───────────────────────────────────────
DIM_SAVE_SQL = """
CREATE OR REPLACE TABLE `makestar-dw.datamart.user_rfm_dimension` AS
-- ============================================================
-- 2nd Depth Dimension 분류 (v2)
-- 4단계: Challenger / Album Collector / Poca Collector / Beginner
--
-- [Challenger] (우선순위 1)
--   - 당첨 이력 있음
--   - qty_ratio > 1.5 (vc > 1 포카 상품)
--   - 응모권 상품(vc=0/NULL) SUM(order_qty) >= 10
--
-- [Album Collector] (우선순위 2)
--   - NOT Challenger
--   - COUNT(DISTINCT ip_name) >= 3 AND MAX(order_qty) <= 5
--
-- [Poca Collector] (우선순위 3)
--   - NOT Challenger, NOT Album Collector
--   - qty_ratio >= 가격대별 하한 (0.2~0.5)
--
-- [Beginner] (우선순위 4)
--   - 나머지
--
-- 가격대별 Poca Collector 하한:
--   ~5만원    : 0.5
--   5~20만원  : 0.3
--   20만원+   : 0.2
-- ============================================================

WITH

agents AS (
  SELECT user_id FROM UNNEST([
    '1876860','812307','1736734','621230','1302313','1902098','859600','969308',
    '1027784','1581799','797962','802866','1492647','781240','885795','1264675',
    '1001311','2116643','1659287','700815','1540460','1890901','1511280','1006060',
    '1606082','1552669','1913216','1138597','1284854','1504890','12526','944286',
    '945344','2046425','1545878','1600974','886898','1539934','1533310','911936',
    '1069252','971976','1658602','948579','1071325','1995221','1933087','636546',
    '1509180','1257147','2032775','1323619','1958765','864765','1994769','209076',
    '1608153','1312465','1355103','1248833','1506290','965150','1011224','1260938',
    '625886','939836','1870283','1347032','1939835','1973097','2022335','1335644',
    '1975403','646210','1542033','910047','1995697','882978','1252380','2159123',
    '867147','942107','1329252','71764','1845002','999056','809695','1604186',
    '1506617','1006091','870982','1895495','1052115','1313023','1254035','1063330',
    '2050980','1550897','1660416','1620875','946338','1482920','1253405','1502990',
    '91909','1738982','2114301','1005028','1513305','1874153','1267050','1354020',
    '1062950','905126','1071819','1935908','1073305','1247698','898061','943715',
    '1673444','1334025','1982712','1290379','1503928','1502504','2159410'
  ]) AS user_id
),

-- 당첨 이력
winners AS (
  SELECT DISTINCT CAST(o.user_id AS STRING) AS user_id
  FROM `makestar-dw.pg_mystarroom_public.tb_commerce_event_winner_group`
  JOIN UNNEST(JSON_EXTRACT_ARRAY(winner_list)) b
  JOIN `makestar-dw.pg_mystarroom_public.tb_commerce_order` o
    ON JSON_VALUE(b.information.order.order_number) = o.order_number
  WHERE JSON_VALUE(b.user.id) != '-1'
),

-- ── 포카 상품: qty_ratio (vc > 1, P타입) ─────────────────────
poca_stats AS (
  SELECT
    o.user_id, e.artist_id, o.event_id, o.option_code,
    SUM(o.order_qty)                                                        AS total_qty,
    SAFE_DIVIDE(SUM(o.total_revenue), NULLIF(SUM(o.order_qty), 0))          AS unit_price,
    MAX(s.virtual_child_sku_count)                                          AS vc,
    SAFE_DIVIDE(SUM(o.order_qty), NULLIF(MAX(s.virtual_child_sku_count),0)) AS qty_ratio
  FROM `makestar-dw.datamart.total_orders` o
  LEFT JOIN `makestar-dw.datamart.events_` e ON o.event_id = e.event_id
  LEFT JOIN `makestar-dw.datamart.vw_commerce_items_v2` i
         ON o.event_id = i.product_event_code AND o.option_code = i.product_option_id
  LEFT JOIN `makestar-dw.pg_oms_public.mst_sku` s ON i.sku_code = s.sku_code
  WHERE o.market_type = 'B2C'
    AND o.data_source = 'new_commerce_db'
    AND o.user_id NOT IN (SELECT user_id FROM agents)
    AND s.sku_type = 'P' AND s.virtual_child_sku_count > 1
  GROUP BY 1,2,3,4
),

-- ── 응모권 상품: qty >= 10이면 Challenger (vc=0/NULL) ──────────
omg_challengers AS (
  SELECT DISTINCT o.user_id
  FROM `makestar-dw.datamart.total_orders` o
  LEFT JOIN `makestar-dw.datamart.vw_commerce_items_v2` i
         ON o.event_id = i.product_event_code AND o.option_code = i.product_option_id
  LEFT JOIN `makestar-dw.pg_oms_public.mst_sku` s ON i.sku_code = s.sku_code
  WHERE o.market_type = 'B2C'
    AND o.data_source = 'new_commerce_db'
    AND o.event_id IS NOT NULL
    AND o.user_id NOT IN (SELECT user_id FROM agents)
    AND (s.sku_type IS NULL OR s.sku_type = 'C'
         OR (s.sku_type = 'P' AND COALESCE(s.virtual_child_sku_count,0) = 0))
  GROUP BY o.user_id, o.event_id, o.option_code
  HAVING SUM(o.order_qty) >= 10
),

-- ── 전체 구매 요약 (Album Collector 판별용) ───────────────────
user_purchases AS (
  SELECT
    user_id,
    COUNT(DISTINCT ip_name) AS distinct_ips,
    MAX(order_qty)          AS max_qty
  FROM `makestar-dw.datamart.total_orders`
  WHERE market_type = 'B2C'
    AND data_source = 'new_commerce_db'
    AND user_id NOT IN (SELECT user_id FROM agents)
  GROUP BY 1
),

-- ── 옵션 단위 포카 분류 ────────────────────────────────────────
poca_labeled AS (
  SELECT o.*,
    CASE
      WHEN w.user_id IS NOT NULL                THEN 'Challenger'
      WHEN o.user_id IN (SELECT user_id FROM omg_challengers) THEN 'Challenger'
      WHEN o.qty_ratio > 1.5                    THEN 'Challenger'
      WHEN o.qty_ratio >= CASE
             WHEN o.unit_price >= 200000 THEN 0.2
             WHEN o.unit_price >= 50000  THEN 0.3
             ELSE 0.5 END                       THEN 'Poca Collector'
      ELSE                                           'Beginner'
    END AS option_label
  FROM poca_stats o
  LEFT JOIN winners w ON o.user_id = w.user_id
),

-- ── 아티스트 단위 집계 ────────────────────────────────────────
artist_lc AS (
  SELECT user_id, artist_id, option_label, COUNT(*) AS cnt
  FROM poca_labeled WHERE artist_id IS NOT NULL GROUP BY 1,2,3
),
artist_labeled AS (
  SELECT user_id, artist_id, option_label AS artist_label
  FROM artist_lc
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY user_id, artist_id
    ORDER BY cnt DESC,
      CASE option_label WHEN 'Challenger' THEN 1 WHEN 'Poca Collector' THEN 2 ELSE 3 END
  ) = 1
),

-- ── 유저 단위 포카 기반 레이블 ────────────────────────────────
user_lc AS (SELECT user_id, artist_label, COUNT(*) AS cnt FROM artist_labeled GROUP BY 1,2),
user_poca_label AS (
  SELECT user_id, artist_label AS poca_label
  FROM user_lc
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY user_id
    ORDER BY cnt DESC,
      CASE artist_label WHEN 'Challenger' THEN 1 WHEN 'Poca Collector' THEN 2 ELSE 3 END
  ) = 1
),

-- ── 최종 4단계 분류 ───────────────────────────────────────────
-- 1. Challenger (당첨/qty>1.5/응모권10장+)
-- 2. Album Collector (ip>=3 AND max_qty<=5, not Challenger)
-- 3. Poca Collector (qty_ratio 범위)
-- 4. Beginner
final_dimension AS (
  SELECT
    up.user_id,
    CASE
      WHEN COALESCE(pl.poca_label, 'Beginner') = 'Challenger'    THEN 'Challenger'
      WHEN up.distinct_ips >= 3 AND up.max_qty <= 5               THEN 'Album Collector'
      WHEN COALESCE(pl.poca_label, 'Beginner') = 'Poca Collector' THEN 'Poca Collector'
      ELSE                                                              'Beginner'
    END AS dimension_label
  FROM user_purchases up
  LEFT JOIN user_poca_label pl ON up.user_id = pl.user_id
),

-- ── 주력 아티스트 ─────────────────────────────────────────────
artist_gmv AS (
  SELECT o.user_id, e.artist_id,
    MAX(o.ip_name) AS artist_name,
    SUM(o.total_revenue) AS gmv
  FROM `makestar-dw.datamart.total_orders` o
  LEFT JOIN `makestar-dw.datamart.events_` e ON o.event_id = e.event_id
  WHERE o.market_type = 'B2C'
    AND o.data_source = 'new_commerce_db'
    AND o.user_id NOT IN (SELECT user_id FROM agents)
    AND e.artist_id IS NOT NULL
  GROUP BY 1,2
),
main_artist AS (
  SELECT user_id, artist_id, artist_name, gmv AS artist_gmv
  FROM artist_gmv
  QUALIFY ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY gmv DESC) = 1
)

-- ── 최종 결과 ─────────────────────────────────────────────────
SELECT
  d.user_id,
  d.dimension_label,
  a.artist_id   AS main_artist_id,
  a.artist_name AS main_artist_name,
  a.artist_gmv  AS main_artist_gmv
FROM final_dimension d
LEFT JOIN main_artist a ON d.user_id = a.user_id


"""

# ─── Step 3: 최종 통합 저장 ──────────────────────────────────────
FINAL_SAVE_SQL = """
CREATE OR REPLACE TABLE `makestar-dw.datamart.user_rfm_segment` AS
SELECT
  r.user_id,
  r.r_raw, r.f_raw, r.m_raw,
  r.r_score, r.f_score, r.m_score,
  r.r_score + r.f_score + r.m_score AS rfm_total,
  COALESCE(d.dimension_label, 'Beginner') AS dimension_label,  -- NULL → Beginner
  d.main_artist_id,
  d.main_artist_name,
  d.main_artist_gmv,
  CURRENT_TIMESTAMP() AS updated_at
FROM `makestar-dw.datamart.user_rfm_score` r
LEFT JOIN `makestar-dw.datamart.user_rfm_dimension` d ON r.user_id = d.user_id
"""

# ─── Step 4: CRM 통합 테이블 ─────────────────────────────────────
CRM_SAVE_SQL = open(
    Path(__file__).parent.parent / "queries" / "crm_users.sql"
).read()


if __name__ == "__main__":
    print("=== RFM 파이프라인 시작 (주 1회 전체 재계산) ===\n")

    print("[1/4] RFM 스코어 계산 및 저장")
    bq_run(RFM_SAVE_SQL, "user_rfm_score")

    print("\n[2/4] Dimension 분류 및 저장")
    bq_run(DIM_SAVE_SQL, "user_rfm_dimension")

    print("\n[3/4] 최종 세그먼트 통합")
    bq_run(FINAL_SAVE_SQL, "user_rfm_segment")

    print("\n[4/4] CRM 통합 테이블 생성")
    bq_run(CRM_SAVE_SQL, "crm_users")

    # 결과 확인
    print("\n=== 결과 확인 ===")
    rows = bq_query("""
        SELECT dimension_label, COUNT(*) AS cnt,
               ROUND(AVG(rfm_total),1) AS avg_rfm,
               ROUND(AVG(total_gmv)) AS avg_gmv
        FROM `makestar-dw.datamart.crm_users`
        WHERE r_score IS NOT NULL
        GROUP BY 1 ORDER BY avg_rfm DESC
    """)
    for r in rows:
        print(f"  {r['dimension_label']}: {int(r['cnt']):,}명  avg_rfm={r['avg_rfm']}  avg_gmv=₩{int(r['avg_gmv']):,}")

    print("\n✓ 파이프라인 완료")
