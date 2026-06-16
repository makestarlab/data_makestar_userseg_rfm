# RFM 설계 문서

## 지표 정의

| 지표 | 정의 | 소스 | 비고 |
|---|---|---|---|
| **R** (Recency) | 마지막 로그인일 | `pg_mystarroom_public.tb_auth_user.last_login` | 최신성 |
| **F** (Frequency) | 아티스트당 평균 구매횟수 | `datamart.total_orders` | 복수 아티스트 구매 시 평균값 |
| **M** (Monetary) | 누적 총 결제금액 | `datamart.total_orders.total_revenue` | KRW 기준 |

### F 계산 방식

```
F = 총 구매횟수 / 구매한 아티스트 수
```

예시: 아티스트 A에서 10번, 아티스트 B에서 2번 구매 → F = (10 + 2) / 2 = 6

---

## 스코어링

- 각 지표를 **1~5점**으로 변환 (전체 유저풀 내 상대 위치 기준, 5분위)
- 5점 = 상위 20%, 1점 = 하위 20%

---

## 가중치 모델

> **미확정** — 가중치 정의 필요

최종 RFM 스코어 = `w_r × R점수 + w_f × F점수 + w_m × M점수`

| 가중치 | 값 | 근거 |
|---|---|---|
| w_r | TBD | |
| w_f | TBD | |
| w_m | TBD | |

---

## 적용 기준

- 분석 대상: `market_type IN ('B2C','B2B')` B2C 구매 유저
- 구매대행 제외 (유저 행동 분석 목적)
- 분석 기간: TBD
