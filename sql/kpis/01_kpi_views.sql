-- KPI views consumed by Power BI. Recreated on every build (dw tables are dropped with CASCADE).

-- 1. Monthly business overview
CREATE OR REPLACE VIEW dw.kpi_monthly AS
SELECT
    d.year_month,
    count(*)                                                  AS orders,
    round(sum(f.items_value), 2)                              AS revenue,
    round(sum(f.freight_value), 2)                            AS freight,
    round(avg(f.items_value), 2)                              AS avg_ticket,
    round(100.0 * avg(f.is_late::int) FILTER (WHERE f.is_delivered), 1) AS pct_late,
    round(avg(f.review_score), 2)                             AS avg_review,
    -- month-over-month change in orders
    round(100.0 * (count(*) - lag(count(*)) OVER w) / nullif(lag(count(*)) OVER w, 0), 1) AS orders_mom_pct
FROM dw.fact_deliveries f
JOIN dw.dim_date d ON d.date_key = f.purchase_date_key
WHERE f.order_status NOT IN ('canceled', 'unavailable')
GROUP BY d.year_month
-- the dataset starts and ends with near-empty months (e.g. 2018-09 has 1 order); leave them out
HAVING count(*) >= 100
WINDOW w AS (ORDER BY d.year_month);

-- 2. Sellers ranked by how many late orders they cause, with cumulative share (Pareto)
CREATE OR REPLACE VIEW dw.kpi_seller_delivery AS
WITH seller_orders AS (            -- one row per seller and order (an order can have several items)
    SELECT DISTINCT i.seller_key, f.order_id, f.is_late, f.days_seller_to_carrier,
           f.days_total, f.review_score
    FROM dw.fact_order_items i
    JOIN dw.fact_deliveries f USING (order_id)
    WHERE f.is_delivered
),
per_seller AS (
    SELECT seller_key,
           count(*)                                   AS orders,
           sum(is_late::int)                          AS late_orders,
           round(100.0 * avg(is_late::int), 1)        AS pct_late,
           round(avg(days_seller_to_carrier), 1)      AS avg_days_to_carrier,
           round(avg(days_total), 1)                  AS avg_days_total,
           round(avg(review_score), 2)                AS avg_review
    FROM seller_orders GROUP BY 1
)
SELECT
    p.*,
    s.state                                                    AS seller_state,
    rank() OVER (ORDER BY late_orders DESC)                    AS rank_late_orders,
    -- unique position for charts: ties in late_orders broken by seller id
    row_number() OVER (ORDER BY late_orders DESC, seller_key)  AS seller_position,
    round(100.0 * sum(late_orders) OVER (ORDER BY late_orders DESC, seller_key)
          / sum(late_orders) OVER (), 1)                       AS cum_pct_of_late_orders
FROM per_seller p
JOIN dw.dim_seller s USING (seller_key);

-- 3. Routes: seller state -> customer state
CREATE OR REPLACE VIEW dw.kpi_route_delivery AS
WITH r AS (
    SELECT DISTINCT s.state AS seller_state, g.state AS customer_state, g.region AS customer_region,
           f.order_id, f.is_late, f.days_total, f.days_promised
    FROM dw.fact_order_items i
    JOIN dw.fact_deliveries f USING (order_id)
    JOIN dw.dim_seller s      USING (seller_key)
    JOIN dw.dim_geography g   ON g.zip_code_prefix = f.customer_zip
    WHERE f.is_delivered
)
SELECT seller_state, customer_state, customer_region,
       count(*)                              AS orders,
       sum(is_late::int)                     AS late_orders,
       round(100.0 * avg(is_late::int), 1)   AS pct_late,
       round(avg(days_total), 1)             AS avg_days_total,
       round(avg(days_promised), 1)          AS avg_days_promised
FROM r
GROUP BY 1, 2, 3;

-- 4. Where the time goes: average days per stage, late vs on-time orders, by customer region
CREATE OR REPLACE VIEW dw.kpi_stage_breakdown AS
SELECT g.region,
       CASE WHEN f.is_late THEN 'late' ELSE 'on time' END AS outcome,
       count(*)                                  AS orders,
       round(avg(f.days_to_approve), 2)          AS avg_days_to_approve,
       round(avg(f.days_seller_to_carrier), 2)   AS avg_days_seller_to_carrier,
       round(avg(f.days_carrier_to_customer), 2) AS avg_days_carrier_to_customer,
       round(avg(f.days_total), 2)               AS avg_days_total,
       round(avg(f.review_score), 2)             AS avg_review
FROM dw.fact_deliveries f
JOIN dw.dim_geography g ON g.zip_code_prefix = f.customer_zip
WHERE f.is_delivered
GROUP BY 1, 2;

-- 5. Customer retention by cohort (month of first purchase)
CREATE OR REPLACE VIEW dw.kpi_customer_cohorts AS
WITH orders AS (
    SELECT customer_key, date_trunc('month', order_purchase_timestamp)::date AS month
    FROM dw.fact_deliveries
    WHERE order_status NOT IN ('canceled', 'unavailable')
),
first AS (
    SELECT customer_key, min(month) AS cohort FROM orders GROUP BY 1
),
activity AS (
    SELECT DISTINCT f.cohort, o.customer_key,
           (extract(year FROM age(o.month, f.cohort)) * 12 + extract(month FROM age(o.month, f.cohort)))::int AS months_since
    FROM orders o JOIN first f USING (customer_key)
)
SELECT cohort, months_since,
       count(*)                                                    AS customers,
       round(100.0 * count(*) / first_value(count(*)) OVER (PARTITION BY cohort ORDER BY months_since), 2)
                                                                   AS retention_pct
FROM activity
GROUP BY 1, 2;
