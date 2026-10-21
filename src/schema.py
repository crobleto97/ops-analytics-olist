"""Expected structure of the Olist CSV files.

Each entry: staging table name -> file, columns with their type, primary key,
and foreign keys (column -> (parent table, parent column)).
Types: str, int, float, datetime. Zip prefixes are str to keep leading zeros.
"""

TABLES = {
    "customers": {
        "file": "olist_customers_dataset.csv",
        "columns": {
            "customer_id": "str",
            "customer_unique_id": "str",
            "customer_zip_code_prefix": "str",
            "customer_city": "str",
            "customer_state": "str",
        },
        "pk": ["customer_id"],
        "fk": {},
    },
    "geolocation": {
        "file": "olist_geolocation_dataset.csv",
        "columns": {
            "geolocation_zip_code_prefix": "str",
            "geolocation_lat": "float",
            "geolocation_lng": "float",
            "geolocation_city": "str",
            "geolocation_state": "str",
        },
        "pk": [],  # one zip prefix has many points by design; aggregated in the model
        "fk": {},
    },
    "sellers": {
        "file": "olist_sellers_dataset.csv",
        "columns": {
            "seller_id": "str",
            "seller_zip_code_prefix": "str",
            "seller_city": "str",
            "seller_state": "str",
        },
        "pk": ["seller_id"],
        "fk": {},
    },
    "category_translation": {
        "file": "product_category_name_translation.csv",
        "columns": {
            "product_category_name": "str",
            "product_category_name_english": "str",
        },
        "pk": ["product_category_name"],
        "fk": {},
    },
    "products": {
        "file": "olist_products_dataset.csv",
        "columns": {
            "product_id": "str",
            "product_category_name": "str",
            "product_name_lenght": "int",         # sic: misspelled in the source
            "product_description_lenght": "int",  # sic
            "product_photos_qty": "int",
            "product_weight_g": "int",
            "product_length_cm": "int",
            "product_height_cm": "int",
            "product_width_cm": "int",
        },
        "pk": ["product_id"],
        "fk": {},
    },
    "orders": {
        "file": "olist_orders_dataset.csv",
        "columns": {
            "order_id": "str",
            "customer_id": "str",
            "order_status": "str",
            "order_purchase_timestamp": "datetime",
            "order_approved_at": "datetime",
            "order_delivered_carrier_date": "datetime",
            "order_delivered_customer_date": "datetime",
            "order_estimated_delivery_date": "datetime",
        },
        "pk": ["order_id"],
        "fk": {"customer_id": ("customers", "customer_id")},
    },
    "order_items": {
        "file": "olist_order_items_dataset.csv",
        "columns": {
            "order_id": "str",
            "order_item_id": "int",
            "product_id": "str",
            "seller_id": "str",
            "shipping_limit_date": "datetime",
            "price": "float",
            "freight_value": "float",
        },
        "pk": ["order_id", "order_item_id"],
        "fk": {
            "order_id": ("orders", "order_id"),
            "product_id": ("products", "product_id"),
            "seller_id": ("sellers", "seller_id"),
        },
    },
    "order_payments": {
        "file": "olist_order_payments_dataset.csv",
        "columns": {
            "order_id": "str",
            "payment_sequential": "int",
            "payment_type": "str",
            "payment_installments": "int",
            "payment_value": "float",
        },
        "pk": ["order_id", "payment_sequential"],
        "fk": {"order_id": ("orders", "order_id")},
    },
    "order_reviews": {
        "file": "olist_order_reviews_dataset.csv",
        "columns": {
            "review_id": "str",
            "order_id": "str",
            "review_score": "int",
            "review_comment_title": "str",
            "review_comment_message": "str",
            "review_creation_date": "datetime",
            "review_answer_timestamp": "datetime",
        },
        "pk": ["review_id", "order_id"],
        "fk": {"order_id": ("orders", "order_id")},
    },
}

# Parents are loaded before children so foreign keys can be checked.
LOAD_ORDER = [
    "customers", "geolocation", "sellers", "category_translation",
    "products", "orders", "order_items", "order_payments", "order_reviews",
]

# Value rules: (table, description, function(df) -> boolean mask of BAD rows, severity)
# "reject" removes the row from staging; "warn" keeps it and only logs it.
RULES = [
    ("order_items", "price <= 0", lambda d: d["price"] <= 0, "reject"),
    ("order_items", "freight_value < 0", lambda d: d["freight_value"] < 0, "reject"),
    ("order_payments", "payment_value < 0", lambda d: d["payment_value"] < 0, "reject"),
    ("order_reviews", "review_score outside 1-5",
     lambda d: ~d["review_score"].between(1, 5), "reject"),
    ("orders", "delivered to customer before purchase",
     lambda d: d["order_delivered_customer_date"] < d["order_purchase_timestamp"], "warn"),
    ("orders", "handed to carrier before approval",
     lambda d: d["order_delivered_carrier_date"] < d["order_approved_at"], "warn"),
    ("orders", "status 'delivered' without delivery date",
     lambda d: (d["order_status"] == "delivered") & d["order_delivered_customer_date"].isna(), "warn"),
]
