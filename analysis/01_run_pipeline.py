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
winners AS (
  SELECT DISTINCT CAST(o.user_id AS STRING) AS user_id
  FROM `makestar-dw.pg_mystarroom_public.tb_commerce_event_winner_group`
  JOIN UNNEST(JSON_EXTRACT_ARRAY(winner_list)) b
  JOIN `makestar-dw.pg_mystarroom_public.tb_commerce_order` o
    ON JSON_VALUE(b.information.order.order_number) = o.order_number
  WHERE JSON_VALUE(b.user.id) != '-1'
),
option_stats AS (
  SELECT
    o.user_id, e.artist_id, o.event_id, o.option_code,
    SUM(o.order_qty)                                                        AS total_qty,
    SAFE_DIVIDE(SUM(o.total_revenue), NULLIF(SUM(o.order_qty), 0))          AS unit_price,
    MAX(s.virtual_child_sku_count)                                          AS sku_variety,
    SAFE_DIVIDE(SUM(o.order_qty), NULLIF(MAX(s.virtual_child_sku_count),0)) AS qty_ratio
  FROM `makestar-dw.datamart.total_orders` o
  LEFT JOIN `makestar-dw.datamart.events_` e ON o.event_id = e.event_id
  LEFT JOIN `makestar-dw.datamart.vw_commerce_items_v2` i
         ON o.event_id = i.product_event_code AND o.option_code = i.product_option_id
  LEFT JOIN `makestar-dw.pg_oms_public.mst_sku` s ON i.sku_code = s.sku_code
  WHERE o.market_type IN ('B2C','B2B')
    AND o.data_source = 'new_commerce_db'
    AND o.user_id NOT IN (SELECT user_id FROM agents)
    AND s.virtual_child_sku_count > 1
  GROUP BY 1,2,3,4
),
option_labeled AS (
  SELECT *,
    CASE
      WHEN unit_price >= 200000 THEN 0.2
      WHEN unit_price >= 50000  THEN 0.3
      ELSE                           0.5
    END AS collector_threshold
  FROM option_stats
),
event_labeled AS (
  SELECT o.*,
    CASE
      WHEN w.user_id IS NOT NULL               THEN 'Challenger'
      WHEN o.qty_ratio > 1.0                   THEN 'Challenger'
      WHEN o.qty_ratio >= o.collector_threshold THEN 'Collector'
      ELSE                                          'Beginner'
    END AS option_label
  FROM option_labeled o
  LEFT JOIN winners w ON o.user_id = w.user_id
),
artist_label_counts AS (
  SELECT user_id, artist_id, option_label, COUNT(*) AS cnt
  FROM event_labeled WHERE artist_id IS NOT NULL GROUP BY 1,2,3
),
artist_labeled AS (
  SELECT user_id, artist_id, option_label AS artist_label
  FROM artist_label_counts
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY user_id, artist_id
    ORDER BY cnt DESC,
      CASE option_label WHEN 'Challenger' THEN 1 WHEN 'Collector' THEN 2 ELSE 3 END
  ) = 1
),
user_label_counts AS (
  SELECT user_id, artist_label, COUNT(*) AS cnt FROM artist_labeled GROUP BY 1,2
),
user_dimension AS (
  SELECT user_id, artist_label AS dimension_label
  FROM user_label_counts
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY user_id
    ORDER BY cnt DESC,
      CASE artist_label WHEN 'Challenger' THEN 1 WHEN 'Collector' THEN 2 ELSE 3 END
  ) = 1
),
artist_gmv AS (
  SELECT o.user_id, e.artist_id,
    MAX(o.ip_name) AS artist_name,
    SUM(o.total_revenue) AS gmv
  FROM `makestar-dw.datamart.total_orders` o
  LEFT JOIN `makestar-dw.datamart.events_` e ON o.event_id = e.event_id
  WHERE o.market_type IN ('B2C','B2B')
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
SELECT
  d.user_id, d.dimension_label,
  a.artist_id   AS main_artist_id,
  a.artist_name AS main_artist_name,
  a.artist_gmv  AS main_artist_gmv
FROM user_dimension d
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
