-- ============================================================
-- CRM 통합 유저 테이블
-- 저장: makestar-dw.datamart.crm_users
-- 주기: 주 1회 전체 재생성 (Airflow DAG)
-- ============================================================

CREATE OR REPLACE TABLE `makestar-dw.datamart.crm_users` AS

WITH

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
agents AS (
  SELECT DISTINCT CAST(p.user_id AS STRING) AS user_id
  FROM purchasing_candidates p
  JOIN multi_artist m ON m.user_id = CAST(p.user_id AS STRING)
),

-- 유저 기본 정보
user_base AS (
  SELECT
    CAST(u.id AS STRING)                              AS user_id,
    u.email,
    u.created_from,                                    -- 가입 서비스 (MAKESTAR, POCAALBUM 등)
    DATE(u.created_at, 'Asia/Seoul')                  AS signup_date,
    DATE(u.last_login, 'Asia/Seoul')                  AS last_login,
    u.is_withdrawn,
    u.is_active,
    i.country_code,
    i.gender_type,
    DATE(i.birth, 'Asia/Seoul')                       AS birth_date
  FROM `makestar-dw.pg_mystarroom_public.tb_auth_user` u
  LEFT JOIN `makestar-dw.pg_mystarroom_public.tb_auth_user_information` i
         ON u.id = i.user_id
  WHERE u.is_certified = TRUE
),

-- 구매 이력 (new_commerce_db 기준)
purchase_stats AS (
  SELECT
    user_id,
    MIN(DATE(pay_date))                               AS first_purchase_date,
    MAX(DATE(pay_date))                               AS last_purchase_date,
    COUNT(DISTINCT order_no)                          AS total_orders,
    ROUND(SUM(total_revenue))                         AS total_gmv,
    ROUND(SAFE_DIVIDE(SUM(total_revenue), COUNT(DISTINCT order_no))) AS avg_order_value,
    COUNT(DISTINCT DATE_TRUNC(DATE(pay_date), MONTH)) AS active_months
  FROM `makestar-dw.datamart.total_orders`
  WHERE market_type = 'B2C'
    AND data_source = 'new_commerce_db'
    AND user_id NOT IN (SELECT user_id FROM agents)
  GROUP BY user_id
)

SELECT
  -- ── 유저 식별 ───────────────────────────────────────
  u.user_id,
  u.email,
  u.created_from,
  u.signup_date,
  u.last_login,
  u.birth_date,
  u.country_code,
  u.gender_type,
  u.is_withdrawn,
  u.is_active,

  -- ── 구매 이력 ───────────────────────────────────────
  p.first_purchase_date,
  p.last_purchase_date,
  COALESCE(p.total_orders, 0)     AS total_orders,
  COALESCE(p.total_gmv, 0)        AS total_gmv,
  COALESCE(p.avg_order_value, 0)  AS avg_order_value,
  COALESCE(p.active_months, 0)    AS active_months,

  -- ── RFM Raw 값 ──────────────────────────────────────
  r.r_raw,                        -- 마지막 로그인 경과일
  r.f_raw,                        -- 아티스트당 평균 라운드 수
  r.m_raw,                        -- 누적 GMV

  -- ── RFM 스코어 (1~5) ────────────────────────────────
  r.r_score,
  r.f_score,
  r.m_score,
  r.r_score + r.f_score + r.m_score AS rfm_total,

  -- ── 2nd Depth Dimension ─────────────────────────────
  COALESCE(d.dimension_label, 'Beginner') AS dimension_label,
  d.main_artist_id,
  d.main_artist_name,
  d.main_artist_gmv,

  -- ── 메타 ────────────────────────────────────────────
  CURRENT_TIMESTAMP()             AS updated_at

FROM user_base u
LEFT JOIN `makestar-dw.datamart.user_rfm_score`     r ON u.user_id = r.user_id
LEFT JOIN `makestar-dw.datamart.user_rfm_dimension` d ON u.user_id = d.user_id
LEFT JOIN purchase_stats                            p ON u.user_id = p.user_id
