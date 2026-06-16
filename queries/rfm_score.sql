-- ============================================================
-- RFM 5점 스코어 변환
-- 전체 유저풀 내 상대 위치 기준 NTILE(5)
-- R: 경과일이 적을수록(최근) 높은 점수 → 역순
-- F, M: 클수록 높은 점수
-- ============================================================

WITH base AS (
  -- rfm_base.sql 결과를 여기에 연결하거나 BQ 저장 테이블 참조
  SELECT * FROM `makestar-dw.datamart.rfm_base`  -- 또는 rfm_base.sql CTE 삽입
),

scored AS (
  SELECT
    user_id,
    r_raw,
    f_raw,
    m_raw,
    total_rounds,
    total_artists,

    -- R: 경과일 역순 (적을수록 5점)
    6 - NTILE(5) OVER (ORDER BY r_raw ASC)  AS r_score,
    -- F: 클수록 5점
    NTILE(5) OVER (ORDER BY f_raw ASC)      AS f_score,
    -- M: 클수록 5점
    NTILE(5) OVER (ORDER BY m_raw ASC)      AS m_score
  FROM base
  WHERE m_raw > 0  -- 구매 이력 없는 유저 제외
)

SELECT
  *,
  r_score + f_score + m_score AS rfm_total_raw  -- 가중치 미적용 단순합 (추후 가중치 모델 적용)
FROM scored
