-- Star schema: facts.

-- fact_order_items: grain = one item in one order. Revenue and freight live here.
DROP TABLE IF EXISTS dw.fact_order_items CASCADE;
CREATE TABLE dw.fact_order_items AS
SELECT
    i.order_id,
    i.order_item_id,
    i.product_id                                        AS product_key,
    i.seller_id                                         AS seller_key,
    c.customer_unique_id                                AS customer_key,
    to_char(o.order_purchase_timestamp, 'YYYYMMDD')::int AS purchase_date_key,
    o.order_status,
    i.price::numeric(12,2)          AS price,          -- money as numeric, not float
    i.freight_value::numeric(12,2)  AS freight_value
FROM staging.order_items i
JOIN staging.orders o    USING (order_id)
JOIN staging.customers c USING (customer_id);
ALTER TABLE dw.fact_order_items ADD PRIMARY KEY (order_id, order_item_id);
CREATE INDEX ON dw.fact_order_items (seller_key);
CREATE INDEX ON dw.fact_order_items (product_key);
CREATE INDEX ON dw.fact_order_items (purchase_date_key);

-- fact_deliveries: grain = one order. Every step of the delivery, in days.
DROP TABLE IF EXISTS dw.fact_deliveries CASCADE;
CREATE TABLE dw.fact_deliveries AS
WITH items AS (
    SELECT order_id,
           count(*)                  AS items,
           count(DISTINCT seller_id) AS sellers,
           sum(price)::numeric(12,2)         AS items_value,
           sum(freight_value)::numeric(12,2) AS freight_value
    FROM staging.order_items GROUP BY 1
),
reviews AS (
    SELECT order_id, avg(review_score)::numeric(3,2) AS review_score
    FROM staging.order_reviews GROUP BY 1
),
pay AS (
    SELECT order_id, sum(payment_value)::numeric(12,2) AS payment_value
    FROM staging.order_payments GROUP BY 1
)
SELECT
    o.order_id,
    c.customer_unique_id                                          AS customer_key,
    c.customer_zip_code_prefix                                    AS customer_zip,
    o.order_status,
    to_char(o.order_purchase_timestamp, 'YYYYMMDD')::int          AS purchase_date_key,
    to_char(o.order_estimated_delivery_date, 'YYYYMMDD')::int     AS estimated_date_key,
    to_char(o.order_delivered_customer_date, 'YYYYMMDD')::int     AS delivered_date_key,
    o.order_purchase_timestamp,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,
    -- stage durations in days (NULL when a stage did not happen)
    round(extract(epoch FROM o.order_approved_at - o.order_purchase_timestamp) / 86400, 2)            AS days_to_approve,
    round(extract(epoch FROM o.order_delivered_carrier_date - o.order_approved_at) / 86400, 2)        AS days_seller_to_carrier,
    round(extract(epoch FROM o.order_delivered_customer_date - o.order_delivered_carrier_date) / 86400, 2) AS days_carrier_to_customer,
    round(extract(epoch FROM o.order_delivered_customer_date - o.order_purchase_timestamp) / 86400, 2)  AS days_total,
    round(extract(epoch FROM o.order_estimated_delivery_date - o.order_purchase_timestamp) / 86400, 2)  AS days_promised,
    -- lateness compares calendar dates: the estimate has no time of day
    o.order_delivered_customer_date::date - o.order_estimated_delivery_date::date                     AS days_late,
    (o.order_delivered_customer_date IS NOT NULL)                                                     AS is_delivered,
    (o.order_delivered_customer_date::date > o.order_estimated_delivery_date::date)                   AS is_late,
    (o.order_delivered_carrier_date < o.order_approved_at)                                            AS flag_carrier_before_approval,
    coalesce(i.items, 0)          AS items,
    coalesce(i.sellers, 0)        AS sellers,
    i.items_value,
    i.freight_value,
    p.payment_value,
    r.review_score
FROM staging.orders o
JOIN staging.customers c USING (customer_id)
LEFT JOIN items i   USING (order_id)
LEFT JOIN reviews r USING (order_id)
LEFT JOIN pay p     USING (order_id);
ALTER TABLE dw.fact_deliveries ADD PRIMARY KEY (order_id);
CREATE INDEX ON dw.fact_deliveries (customer_key);
CREATE INDEX ON dw.fact_deliveries (purchase_date_key);
