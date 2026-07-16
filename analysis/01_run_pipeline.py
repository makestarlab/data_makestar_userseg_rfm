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
WITH -- makestar.com 내부/테스트/운영 계정 (수동 관리 대상 — 구매대행과 무관)
internal_accounts AS (
  SELECT user_id FROM UNNEST([
    -- makestar.com 추가분
    '2308791','2065197','1966353','2108478','1973103','1967649','1962518','1651127',
    -- makestar.com 내부 계정 전체 (271개)
    '1','2','4','5','6','11','23','28','46','47','81','149','250','293','445','446','506','639','640','642','660','1143','1669','1698','2266','3570','3697','6397','7323','7405','9969','13710','18891','18894','18907','18910','18918','18922','18937','18941','18943','25527','27096','31592','61472','65178','75428','77164','81888','89996','91817','94183','114029','116449','118315','135807','158291','159444','171365','171433','183250','191191','200172','634299','703146','777996','779425','780061','873495','912353','913997','916406','924614','927469','952068','957967','958079','978851','1052062','1052063','1072108','1248703','1266580','1297564','1311611','1325480','1468256','1482741','1495292','1529990','1545005','1548348','1600245','1600492','1600495','1601827','1612695','1628967','1641220','1645106','1645266','1645965','1650883','1651127','1674672','1674702','1697154','1709547','1733846','1750907','1763267','1766373','1777929','1821468','1831384','1833148','1843309','1849858','1873463','1873637','1875148','1876851','1878152','1878641','1878643','1881909','1890911','1893867','1901629','1907491','1908565','1913442','1913658','1917824','1917825','1917826','1917867','1917868','1917870','1917871','1917872','1917873','1918208','1920091','1920207','1920253','1921331','1922190','1922323','1924210','1924273','1925289','1928348','1928421','1928595','1928604','1929489','1939880','1944677','1944678','1944790','1951334','1953163','1961321','1962518','1962948','1962950','1966113','1966181','1966353','1967649','1972061','1973103','1976288','1977684','1984821','1987033','2001809','2007916','2010410','2012770','2013196','2018509','2022128','2029267','2034114','2034894','2037880','2040138','2040417','2040419','2047053','2047862','2047934','2048523','2048754','2050183','2050512','2052554','2063566','2063973','2064638','2064873','2065197','2073991','2074693','2080193','2085818','2086326','2090320','2092774','2099682','2103431','2105715','2108478','2112627','2113859','2114330','2116477','2116575','2116643','2117074','2121241','2129227','2132673','2132707','2132737','2142915','2146416','2149239','2149241','2149489','2154856','2161922','2162318','2168465','2170725','2184510','2187366','2189092','2208829','2216236','2219279','2223971','2233650','2238011','2238047','2238604','2242193','2246393','2246854','2246968','2251552','2256789','2258846','2258853','2258864','2258883','2262807','2267385','2277798','2281976','2293704','2293705','2297965','2297968','2302762','2306968','2308791','2310926','2312066',
    -- B2B/운영 계정 추가 제외
    '2293705','2293704','2302812','2048754','1984821','2132737','2116643','1986193','2073991','2063566','1976288'
  ]) AS user_id
),

-- 구매대행 추정 (하드코딩 리스트 대체): 동일 창고주소에 고객코드 3개 이상 + 아티스트 2개 이상 구매
order_shipping AS (
  SELECT
    user_id,
    TRIM(JSON_EXTRACT_SCALAR(shipping_information, '$.information.address'))        AS base_address,
    TRIM(JSON_EXTRACT_SCALAR(shipping_information, '$.information.detail_address')) AS customer_code
  FROM `makestar-dw.pg_mystarroom_public.tb_commerce_order`
  WHERE payment_status IN ('CONFIRMED', 'PARTIAL_CANCELED')
    AND user_id IS NOT NULL
    AND shipping_information IS NOT NULL
),
purchasing_candidates AS (
  SELECT user_id
  FROM order_shipping
  WHERE customer_code IS NOT NULL AND customer_code != ''
    AND base_address  IS NOT NULL AND base_address  != ''
  GROUP BY user_id, base_address
  HAVING COUNT(DISTINCT customer_code) >= 3
),
multi_artist AS (
  SELECT o.user_id
  FROM `makestar-dw.datamart.total_orders` o
  LEFT JOIN `makestar-dw.datamart.events_` e ON o.event_id = e.event_id
  WHERE o.market_type = 'B2C'
    AND DATE(o.pay_date) >= '2025-01-01'
    AND e.artist_id IS NOT NULL
  GROUP BY o.user_id
  HAVING COUNT(DISTINCT e.artist_id) >= 2
),
purchasing_agents AS (
  SELECT DISTINCT CAST(p.user_id AS STRING) AS user_id
  FROM purchasing_candidates p
  JOIN multi_artist m ON m.user_id = CAST(p.user_id AS STRING)
),

agents AS (
  SELECT user_id FROM internal_accounts
  UNION DISTINCT
  SELECT user_id FROM purchasing_agents
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

-- makestar.com 내부/테스트/운영 계정 (수동 관리 대상 — 구매대행과 무관)
internal_accounts AS (
  SELECT user_id FROM UNNEST([
    -- makestar.com 추가분
    '2308791','2065197','1966353','2108478','1973103','1967649','1962518','1651127',
    -- makestar.com 내부 계정 전체 (271개)
    '1','2','4','5','6','11','23','28','46','47','81','149','250','293','445','446','506','639','640','642','660','1143','1669','1698','2266','3570','3697','6397','7323','7405','9969','13710','18891','18894','18907','18910','18918','18922','18937','18941','18943','25527','27096','31592','61472','65178','75428','77164','81888','89996','91817','94183','114029','116449','118315','135807','158291','159444','171365','171433','183250','191191','200172','634299','703146','777996','779425','780061','873495','912353','913997','916406','924614','927469','952068','957967','958079','978851','1052062','1052063','1072108','1248703','1266580','1297564','1311611','1325480','1468256','1482741','1495292','1529990','1545005','1548348','1600245','1600492','1600495','1601827','1612695','1628967','1641220','1645106','1645266','1645965','1650883','1651127','1674672','1674702','1697154','1709547','1733846','1750907','1763267','1766373','1777929','1821468','1831384','1833148','1843309','1849858','1873463','1873637','1875148','1876851','1878152','1878641','1878643','1881909','1890911','1893867','1901629','1907491','1908565','1913442','1913658','1917824','1917825','1917826','1917867','1917868','1917870','1917871','1917872','1917873','1918208','1920091','1920207','1920253','1921331','1922190','1922323','1924210','1924273','1925289','1928348','1928421','1928595','1928604','1929489','1939880','1944677','1944678','1944790','1951334','1953163','1961321','1962518','1962948','1962950','1966113','1966181','1966353','1967649','1972061','1973103','1976288','1977684','1984821','1987033','2001809','2007916','2010410','2012770','2013196','2018509','2022128','2029267','2034114','2034894','2037880','2040138','2040417','2040419','2047053','2047862','2047934','2048523','2048754','2050183','2050512','2052554','2063566','2063973','2064638','2064873','2065197','2073991','2074693','2080193','2085818','2086326','2090320','2092774','2099682','2103431','2105715','2108478','2112627','2113859','2114330','2116477','2116575','2116643','2117074','2121241','2129227','2132673','2132707','2132737','2142915','2146416','2149239','2149241','2149489','2154856','2161922','2162318','2168465','2170725','2184510','2187366','2189092','2208829','2216236','2219279','2223971','2233650','2238011','2238047','2238604','2242193','2246393','2246854','2246968','2251552','2256789','2258846','2258853','2258864','2258883','2262807','2267385','2277798','2281976','2293704','2293705','2297965','2297968','2302762','2306968','2308791','2310926','2312066',
    -- B2B/운영 계정 추가 제외
    '2293705','2293704','2302812','2048754','1984821','2132737','2116643','1986193','2073991','2063566','1976288'
  ]) AS user_id
),

-- 구매대행 추정 (하드코딩 리스트 대체): 동일 창고주소에 고객코드 3개 이상 + 아티스트 2개 이상 구매
order_shipping AS (
  SELECT
    user_id,
    TRIM(JSON_EXTRACT_SCALAR(shipping_information, '$.information.address'))        AS base_address,
    TRIM(JSON_EXTRACT_SCALAR(shipping_information, '$.information.detail_address')) AS customer_code
  FROM `makestar-dw.pg_mystarroom_public.tb_commerce_order`
  WHERE payment_status IN ('CONFIRMED', 'PARTIAL_CANCELED')
    AND user_id IS NOT NULL
    AND shipping_information IS NOT NULL
),
purchasing_candidates AS (
  SELECT user_id
  FROM order_shipping
  WHERE customer_code IS NOT NULL AND customer_code != ''
    AND base_address  IS NOT NULL AND base_address  != ''
  GROUP BY user_id, base_address
  HAVING COUNT(DISTINCT customer_code) >= 3
),
multi_artist AS (
  SELECT o.user_id
  FROM `makestar-dw.datamart.total_orders` o
  LEFT JOIN `makestar-dw.datamart.events_` e ON o.event_id = e.event_id
  WHERE o.market_type = 'B2C'
    AND DATE(o.pay_date) >= '2025-01-01'
    AND e.artist_id IS NOT NULL
  GROUP BY o.user_id
  HAVING COUNT(DISTINCT e.artist_id) >= 2
),
purchasing_agents AS (
  SELECT DISTINCT CAST(p.user_id AS STRING) AS user_id
  FROM purchasing_candidates p
  JOIN multi_artist m ON m.user_id = CAST(p.user_id AS STRING)
),

agents AS (
  SELECT user_id FROM internal_accounts
  UNION DISTINCT
  SELECT user_id FROM purchasing_agents
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
    COUNT(DISTINCT ip_name)                                     AS distinct_ips,
    MAX(order_qty)                                              AS max_qty,
    COUNTIF(event_id IS NOT NULL AND event_id != '')            AS event_order_cnt
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
      WHEN up.user_id IN (SELECT user_id FROM winners)            THEN 'Challenger'
      WHEN up.user_id IN (SELECT user_id FROM omg_challengers)    THEN 'Challenger'
      WHEN up.distinct_ips >= 3 AND up.max_qty < 3                THEN 'Album Collector'
      WHEN COALESCE(pl.poca_label, 'Beginner') = 'Poca Collector' THEN 'Poca Collector'
      WHEN up.event_order_cnt = 0                                  THEN 'Shopper'
      WHEN pl.poca_label IS NULL AND up.event_order_cnt > 0        THEN 'N/A'
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
