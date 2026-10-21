-- Star schema: dimensions. Built from staging; safe to re-run.
CREATE SCHEMA IF NOT EXISTS dw;

-- dim_date: one row per calendar day covering every date in the orders
DROP TABLE IF EXISTS dw.dim_date CASCADE;
CREATE TABLE dw.dim_date AS
SELECT
    to_char(d, 'YYYYMMDD')::int          AS date_key,
    d::date                              AS date,
    extract(year FROM d)::int            AS year,
    extract(quarter FROM d)::int         AS quarter,
    extract(month FROM d)::int           AS month,
    to_char(d, 'YYYY-MM')                AS year_month,
    extract(isodow FROM d)::int          AS day_of_week,   -- 1 = Monday
    extract(isodow FROM d) IN (6, 7)     AS is_weekend
FROM generate_series(
    (SELECT min(order_purchase_timestamp)::date FROM staging.orders),
    (SELECT greatest(max(order_estimated_delivery_date), max(order_delivered_customer_date))::date
       FROM staging.orders),
    interval '1 day') AS d;
ALTER TABLE dw.dim_date ADD PRIMARY KEY (date_key);

-- dim_geography: one row per zip prefix (5 digits). Many raw points per prefix
-- are averaged into one coordinate; city/state taken from the most common value.
DROP TABLE IF EXISTS dw.dim_geography CASCADE;
CREATE TABLE dw.dim_geography AS
WITH zips AS (
    SELECT customer_zip_code_prefix AS zip, customer_city AS city, customer_state AS state FROM staging.customers
    UNION ALL
    SELECT seller_zip_code_prefix, seller_city, seller_state FROM staging.sellers
),
place AS (
    SELECT DISTINCT ON (zip) zip, city, state
    FROM (SELECT zip, city, state, count(*) AS n FROM zips GROUP BY 1, 2, 3) t
    ORDER BY zip, n DESC
),
coords AS (
    SELECT geolocation_zip_code_prefix AS zip,
           avg(geolocation_lat) AS lat, avg(geolocation_lng) AS lng
    FROM staging.geolocation
    WHERE geolocation_lat BETWEEN -34 AND 6        -- inside Brazil's bounding box
      AND geolocation_lng BETWEEN -74 AND -34
    GROUP BY 1
)
SELECT
    p.zip                                AS zip_code_prefix,
    p.city,
    p.state,
    CASE
        WHEN p.state IN ('AC','AP','AM','PA','RO','RR','TO')           THEN 'North'
        WHEN p.state IN ('AL','BA','CE','MA','PB','PE','PI','RN','SE') THEN 'Northeast'
        WHEN p.state IN ('DF','GO','MT','MS')                          THEN 'Center-West'
        WHEN p.state IN ('ES','MG','RJ','SP')                          THEN 'Southeast'
        WHEN p.state IN ('PR','RS','SC')                               THEN 'South'
    END                                  AS region,
    round(c.lat::numeric, 5)             AS lat,
    round(c.lng::numeric, 5)             AS lng
FROM place p
LEFT JOIN coords c USING (zip);
ALTER TABLE dw.dim_geography ADD PRIMARY KEY (zip_code_prefix);

-- dim_customer: one row per real person (customer_unique_id).
-- In Olist, customer_id is created per order, so it is NOT the customer.
DROP TABLE IF EXISTS dw.dim_customer CASCADE;
CREATE TABLE dw.dim_customer AS
SELECT DISTINCT ON (c.customer_unique_id)
    c.customer_unique_id                 AS customer_key,
    c.customer_zip_code_prefix           AS zip_code_prefix,   -- from the latest order
    c.customer_state                     AS state
FROM staging.customers c
JOIN staging.orders o USING (customer_id)
ORDER BY c.customer_unique_id, o.order_purchase_timestamp DESC;
ALTER TABLE dw.dim_customer ADD PRIMARY KEY (customer_key);

DROP TABLE IF EXISTS dw.dim_seller CASCADE;
CREATE TABLE dw.dim_seller AS
SELECT seller_id AS seller_key, seller_zip_code_prefix AS zip_code_prefix, seller_state AS state
FROM staging.sellers;
ALTER TABLE dw.dim_seller ADD PRIMARY KEY (seller_key);

DROP TABLE IF EXISTS dw.dim_product CASCADE;
CREATE TABLE dw.dim_product AS
SELECT
    p.product_id                                             AS product_key,
    coalesce(p.product_category_name, 'unknown')             AS category_pt,
    coalesce(t.product_category_name_english,
             p.product_category_name, 'unknown')             AS category,
    p.product_weight_g                                       AS weight_g,
    p.product_length_cm * p.product_height_cm * p.product_width_cm AS volume_cm3,
    p.product_photos_qty                                     AS photos
FROM staging.products p
LEFT JOIN staging.category_translation t USING (product_category_name);
ALTER TABLE dw.dim_product ADD PRIMARY KEY (product_key);
