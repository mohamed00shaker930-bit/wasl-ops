# Schema inventory (from types.ts, cross-checked with supabase/migrations)

Generated 2026-09-08T00:24:26.739Z. Tables: 38, views: 1, functions: 56, enums: 12.

## Enums

- `app_role`: `customer`, `merchant`, `super_admin`, `admin`, `operations`, `support`, `finance`
- `credit_status`: `pending`, `approved`, `declined`
- `credit_tx_status`: `pending`, `approved`, `rejected`
- `credit_tx_type`: `charge`, `payment`
- `custom_request_status`: `pending`, `quoted`, `accepted`, `rejected`, `converted`
- `order_channel`: `online`, `in_store`
- `order_status`: `sent`, `accepted`, `preparing`, `out_for_delivery`, `delivered`, `declined`, `cancelled`
- `payment_method`: `cash`, `credit`, `jeeb`, `jawali`, `hasab`, `onecash`
- `return_status`: `none`, `requested`, `approved`, `rejected`
- `store_status`: `pending`, `active`, `suspended`, `rejected`
- `wallet_tx_status`: `pending`, `approved`, `rejected`
- `wallet_tx_type`: `topup`, `payment`, `refund`, `adjustment`

## Tables

| Table | Cols | FKs | In migrations | Columns missing from migrations |
|---|---|---|---|---|
| `admin_permissions` | 4 | permission_defs, profiles | **no** | granted_at, granted_by, permission, user_id |
| `app_admins` | 2 | — | yes | — |
| `app_settings` | 3 | — | yes | — |
| `app_usage_log` | 8 | — | **no** | close_type, closed_at, id, last_ping_at, opened_at, seq, user_agent, user_id |
| `audit_logs` | 13 | — | **no** | action, changed_fields, created_at, id, new_data, old_data, record_id, record_label, seq, table_name, user_id, user_name, user_role |
| `auth_sessions_log` | 10 | — | **no** | id, ip, last_seen_at, login_at, logout_at, logout_type, seq, session_id, user_agent, user_id |
| `banners` | 10 | stores | yes | — |
| `business_categories` | 6 | — | **no** | created_at, id, is_active, name_ar, slug, sort_order |
| `catalog_categories` | 9 | — | yes | image_url, main_section, parent_category, sort_order |
| `catalog_items` | 15 | catalog_categories | yes | category_id, category_path, description, main_section, sort_order, subcategory |
| `categories` | 5 | stores | yes | — |
| `credit_accounts` | 5 | stores | yes | — |
| `credit_transactions` | 8 | credit_accounts, orders | yes | — |
| `custom_product_requests` | 13 | orders, stores | yes | — |
| `customer_ratings` | 7 | orders, stores | yes | — |
| `favorites` | 5 | — | yes | — |
| `locations` | 8 | — | yes | — |
| `monitoring_settings` | 6 | — | **no** | fail_threshold, id, monitor_secret, telegram_bot_token, telegram_chat_id, updated_at |
| `notifications` | 8 | — | yes | — |
| `order_items` | 7 | orders, products | yes | — |
| `orders` | 22 | stores | yes | return_reason, return_requested_at, return_responded_at |
| `password_reset_requests` | 10 | — | **no** | applicant_name, decided_at, decided_by, id, phone, reason, requested_at, status, user_id, user_type |
| `pending_customers` | 7 | stores | yes | — |
| `permission_bundle_items` | 2 | permission_bundles, permission_defs | **no** | bundle, permission |
| `permission_bundles` | 3 | — | **no** | bundle, label, sort |
| `permission_defs` | 6 | — | **no** | grp, grp_label, label, perm, sort, super_only |
| `product_offers` | 10 | products, stores | yes | — |
| `products` | 12 | categories, stores | yes | lib_category, main_section, subcategory |
| `profiles` | 15 | business_categories | yes | account_status, address, approved_at, approved_by, business_category_id, business_name, city, district, status_reason, suspended_until, user_type |
| `ratings` | 7 | orders, stores | yes | — |
| `stores` | 16 | business_categories | yes | business_category_id |
| `uptime_checks` | 7 | uptime_targets | **no** | checked_at, error, http_status, id, is_up, response_time_ms, target_id |
| `uptime_incidents` | 8 | uptime_targets | **no** | alert_sent, downtime_minutes, id, last_error, recovery_alert_sent, resolved_at, started_at, target_id |
| `uptime_pending` | 3 | uptime_targets | **no** | issued_at, request_id, target_id |
| `uptime_targets` | 13 | — | **no** | consecutive_failures, created_at, expected_statuses, id, is_active, last_checked_at, last_response_ms, last_status, method, name, sort_order, timeout_ms, url |
| `user_roles` | 4 | — | yes | — |
| `wallet_transactions` | 11 | orders, wallets | yes | — |
| `wallets` | 4 | — | yes | — |

## Views

- `uptime_status` (6 cols)  **(not in migrations)**

## Functions

| Function | Args | Returns | Body in migrations |
|---|---|---|---|
| `admin_apply_bundle` | p_bundle, p_uid | undefined | **no** |
| `admin_broadcast_notification` | _body, _link, _segment, _title | number | yes |
| `admin_bulk_update_catalog_items` | p_items | Json | **no** |
| `admin_create_bundle` | p_bundle, p_label, p_perms? | undefined | **no** |
| `admin_decide_account_request` | p_approve, p_reason?, p_user_id | undefined | **no** |
| `admin_decide_password_reset` | p_approve, p_request_id, p_temp_password? | undefined | **no** |
| `admin_delete_bundle` | p_bundle | undefined | **no** |
| `admin_get_permission_catalog` | never | Json | **no** |
| `admin_get_user_detail` | p_uid | Json | **no** |
| `admin_grant_admin` | _uid | undefined | yes |
| `admin_grant_permission` | p_grant, p_perm, p_uid | undefined | **no** |
| `admin_grant_wallet_credit` | p_amount, p_note?, p_uid | undefined | **no** |
| `admin_kpis` | p_from, p_grain?, p_to | Json | **no** |
| `admin_list_admin_permissions` | p_uid | string[] | **no** |
| `admin_list_app_usage` | p_limit?, p_offset?, p_status?, p_user_id? | record(close_type, closed_at, duration_seconds, id, is_open, last_ping_at, opened_at, total_count, user_agent, user_id, user_name, user_phone) | **no** |
| `admin_list_audit_logs` | p_action?, p_from?, p_limit?, p_offset?, p_role_group?, p_search?, p_table?, p_to?, p_user_id? | record(action, changed_fields, created_at, id, new_data, old_data, record_id, record_label, seq, table_name, total_count, user_id, user_name, user_phone, user_role) | **no** |
| `admin_list_login_sessions` | p_limit?, p_offset?, p_status?, p_user_id? | record(id, ip, is_active, last_seen_at, login_at, logout_at, logout_type, total_count, user_agent, user_id, user_name, user_phone) | **no** |
| `admin_list_user_files` | p_limit?, p_offset?, p_search?, p_status?, p_user_id? | record(active_sessions, is_open_now, last_action_at, last_activity_at, last_login_at, last_opened_at, registered_at, total_actions, total_count, total_logins, total_opens, user_id, user_name, user_phone, user_role) | **no** |
| `admin_list_users` | p_category_slug?, p_kind?, p_limit?, p_offset?, p_role?, p_search? | record(created_at, name, phone, roles, stores, total_count, user_id, user_kind) | **no** |
| `admin_respond_wallet_tx` | _approve, _tx | undefined | yes |
| `admin_revoke_admin` | _uid | undefined | yes |
| `admin_send_notification` | p_body, p_link?, p_title, p_type?, p_uid | undefined | **no** |
| `admin_set_account_status` | p_reason?, p_status, p_uid, p_until? | undefined | **no** |
| `admin_set_setting` | _key, _value | undefined | yes |
| `admin_set_store_commission` | _pct, _store | undefined | yes |
| `admin_set_store_status` | _status, _store | undefined | yes |
| `admin_set_user_role` | _grant, _role, _uid | undefined | **no** |
| `admin_update_bundle` | p_bundle, p_perms | undefined | **no** |
| `admin_update_profile` | p_address?, p_business_name?, p_city?, p_district?, p_name?, p_uid | undefined | **no** |
| `app_session_close` | p_id | undefined | **no** |
| `app_session_open` | p_user_agent? | string | **no** |
| `app_session_ping` | p_id | undefined | **no** |
| `assign_my_role` | _role | undefined | yes |
| `catalog_category_counts` | never | record(category_id, items_count) | yes |
| `clear_my_force_password_change` | never | undefined | **no** |
| `customer_request_return` | _order_id, _reason | undefined | yes |
| `customer_respond_credit` | _approve, _tx_id | undefined | yes |
| `delete_my_account` | never | undefined | **no** |
| `ensure_wallet` | never | string | yes |
| `get_credit_customer` | _account_id | record(name, phone) | yes |
| `get_order_customer` | _order_id | record(name, phone) | yes |
| `has_permission` | _perm, _uid | boolean | **no** |
| `has_role` | _role, _user_id | boolean | yes |
| `is_account_active` | _uid? | boolean | **no** |
| `is_admin` | _uid? | boolean | yes |
| `is_staff` | _uid? | boolean | **no** |
| `merchant_cancel_credit_tx` | _tx_id | undefined | **no** |
| `my_permissions` | never | Json | **no** |
| `pay_order_with_wallet` | _order_id | undefined | yes |
| `push_notification` | _body, _link, _title, _type, _user_id | undefined | yes |
| `request_password_reset` | p_phone, p_reason? | undefined | **no** |
| `search_customers_by_name` | _q | record(id, name, phone) | yes |
| `uptime_collect_results` | never | undefined | **no** |
| `uptime_issue_checks` | never | undefined | **no** |
| `uptime_run` | never | undefined | **no** |
| `uptime_send_telegram` | p_text | number | **no** |

## Triggers defined in migrations

- `apply_credit_tx_trg`
- `auto_promote_admin_trg`
- `calc_order_commission_trg`
- `claim_pending_customers_trg`
- `touch_custom_requests`
- `trg_apply_credit_tx`
- `trg_apply_wallet_tx`
- `trg_guard_order_money`
- `trg_guard_store_protected`
- `trg_notify_order_status`
- `trg_sync_category_to_catalog`
- `trg_sync_product_to_catalog`
- `trg_update_store_rating`

## Column details

### admin_permissions

| column | type | enum | null | default |
|---|---|---|---|---|
| granted_at | string |  |  | yes |
| granted_by | string |  | yes | yes |
| permission | string |  |  |  |
| user_id | string |  |  |  |

FKs: permission → permission_defs(perm); user_id → profiles(id)

### app_admins

| column | type | enum | null | default |
|---|---|---|---|---|
| created_at | string |  |  | yes |
| user_id | string |  |  |  |

### app_settings

| column | type | enum | null | default |
|---|---|---|---|---|
| key | string |  |  |  |
| updated_at | string |  |  | yes |
| value | Json |  |  |  |

### app_usage_log

| column | type | enum | null | default |
|---|---|---|---|---|
| close_type | string |  | yes | yes |
| closed_at | string |  | yes | yes |
| id | string |  |  | yes |
| last_ping_at | string |  |  | yes |
| opened_at | string |  |  | yes |
| seq | number |  |  | yes |
| user_agent | string |  | yes | yes |
| user_id | string |  |  |  |

### audit_logs

| column | type | enum | null | default |
|---|---|---|---|---|
| action | string |  |  |  |
| changed_fields | string[] |  | yes | yes |
| created_at | string |  |  | yes |
| id | string |  |  | yes |
| new_data | Json |  | yes | yes |
| old_data | Json |  | yes | yes |
| record_id | string |  | yes | yes |
| record_label | string |  | yes | yes |
| seq | number |  |  | yes |
| table_name | string |  |  |  |
| user_id | string |  | yes | yes |
| user_name | string |  | yes | yes |
| user_role | string |  | yes | yes |

### auth_sessions_log

| column | type | enum | null | default |
|---|---|---|---|---|
| id | string |  |  | yes |
| ip | string |  | yes | yes |
| last_seen_at | string |  | yes | yes |
| login_at | string |  |  |  |
| logout_at | string |  | yes | yes |
| logout_type | string |  | yes | yes |
| seq | number |  |  | yes |
| session_id | string |  |  |  |
| user_agent | string |  | yes | yes |
| user_id | string |  |  |  |

### banners

| column | type | enum | null | default |
|---|---|---|---|---|
| bg_color | string |  | yes | yes |
| created_at | string |  |  | yes |
| id | string |  |  | yes |
| image_url | string |  | yes | yes |
| is_active | boolean |  |  | yes |
| link | string |  | yes | yes |
| sort_order | number |  |  | yes |
| store_id | string |  | yes | yes |
| subtitle | string |  | yes | yes |
| title | string |  |  |  |

FKs: store_id → stores(id)

### business_categories

| column | type | enum | null | default |
|---|---|---|---|---|
| created_at | string |  |  | yes |
| id | string |  |  | yes |
| is_active | boolean |  |  | yes |
| name_ar | string |  |  |  |
| slug | string |  |  |  |
| sort_order | number |  |  | yes |

### catalog_categories

| column | type | enum | null | default |
|---|---|---|---|---|
| created_at | string |  |  | yes |
| icon | string |  | yes | yes |
| id | string |  |  | yes |
| image_url | string |  | yes | yes |
| main_section | string |  | yes | yes |
| name | string |  |  |  |
| parent_category | string |  | yes | yes |
| sort_order | number |  |  | yes |
| usage_count | number |  |  | yes |

### catalog_items

| column | type | enum | null | default |
|---|---|---|---|---|
| barcode | string |  | yes | yes |
| category_id | string |  | yes | yes |
| category_name | string |  | yes | yes |
| category_path | string |  | yes | yes |
| created_at | string |  |  | yes |
| default_price | number |  |  | yes |
| description | string |  |  | yes |
| id | string |  |  | yes |
| image_url | string |  | yes | yes |
| main_section | string |  | yes | yes |
| name | string |  |  |  |
| sort_order | number |  |  | yes |
| source | string |  |  | yes |
| subcategory | string |  | yes | yes |
| usage_count | number |  |  | yes |

FKs: category_id → catalog_categories(id)

### categories

| column | type | enum | null | default |
|---|---|---|---|---|
| created_at | string |  |  | yes |
| id | string |  |  | yes |
| name | string |  |  |  |
| sort_order | number |  |  | yes |
| store_id | string |  |  |  |

FKs: store_id → stores(id)

### credit_accounts

| column | type | enum | null | default |
|---|---|---|---|---|
| balance | number |  |  | yes |
| created_at | string |  |  | yes |
| customer_id | string |  |  |  |
| id | string |  |  | yes |
| store_id | string |  |  |  |

FKs: store_id → stores(id)

### credit_transactions

| column | type | enum | null | default |
|---|---|---|---|---|
| account_id | string |  |  |  |
| amount | number |  |  |  |
| created_at | string |  |  | yes |
| id | string |  |  | yes |
| note | string |  | yes | yes |
| order_id | string |  | yes | yes |
| status | Database["public"]["Enums"]["credit_tx_status"] | credit_tx_status |  | yes |
| type | Database["public"]["Enums"]["credit_tx_type"] | credit_tx_type |  |  |

FKs: account_id → credit_accounts(id); order_id → orders(id)

### custom_product_requests

| column | type | enum | null | default |
|---|---|---|---|---|
| created_at | string |  |  | yes |
| customer_id | string |  |  |  |
| description | string |  | yes | yes |
| id | string |  |  | yes |
| image_url | string |  | yes | yes |
| merchant_note | string |  | yes | yes |
| merchant_price | number |  | yes | yes |
| name | string |  |  |  |
| order_id | string |  | yes | yes |
| qty | number |  |  | yes |
| status | Database["public"]["Enums"]["custom_request_status"] | custom_request_status |  | yes |
| store_id | string |  |  |  |
| updated_at | string |  |  | yes |

FKs: order_id → orders(id); store_id → stores(id)

### customer_ratings

| column | type | enum | null | default |
|---|---|---|---|---|
| comment | string |  | yes | yes |
| created_at | string |  |  | yes |
| customer_id | string |  |  |  |
| id | string |  |  | yes |
| order_id | string |  | yes | yes |
| stars | number |  |  |  |
| store_id | string |  |  |  |

FKs: order_id → orders(id); store_id → stores(id)

### favorites

| column | type | enum | null | default |
|---|---|---|---|---|
| created_at | string |  |  | yes |
| id | string |  |  | yes |
| target_id | string |  |  |  |
| target_type | string |  |  |  |
| user_id | string |  |  |  |

### locations

| column | type | enum | null | default |
|---|---|---|---|---|
| created_at | string |  |  | yes |
| id | string |  |  | yes |
| label | string |  |  |  |
| landmark_text | string |  |  |  |
| lat | number |  | yes | yes |
| lng | number |  | yes | yes |
| phone | string |  | yes | yes |
| user_id | string |  |  |  |

### monitoring_settings

| column | type | enum | null | default |
|---|---|---|---|---|
| fail_threshold | number |  |  | yes |
| id | number |  |  | yes |
| monitor_secret | string |  |  | yes |
| telegram_bot_token | string |  | yes | yes |
| telegram_chat_id | string |  | yes | yes |
| updated_at | string |  |  | yes |

### notifications

| column | type | enum | null | default |
|---|---|---|---|---|
| body | string |  | yes | yes |
| created_at | string |  |  | yes |
| id | string |  |  | yes |
| link | string |  | yes | yes |
| read_at | string |  | yes | yes |
| title | string |  |  |  |
| type | string |  |  | yes |
| user_id | string |  |  |  |

### order_items

| column | type | enum | null | default |
|---|---|---|---|---|
| id | string |  |  | yes |
| name | string |  |  |  |
| note | string |  | yes | yes |
| order_id | string |  |  |  |
| price | number |  |  |  |
| product_id | string |  | yes | yes |
| qty | number |  |  |  |

FKs: order_id → orders(id); product_id → products(id)

### orders

| column | type | enum | null | default |
|---|---|---|---|---|
| channel | Database["public"]["Enums"]["order_channel"] | order_channel |  | yes |
| commission_amount | number |  |  | yes |
| commission_pct | number |  |  | yes |
| created_at | string |  |  | yes |
| credit_status | Database["public"]["Enums"]["credit_status"] | credit_status | yes | yes |
| customer_id | string |  |  |  |
| id | string |  |  | yes |
| location_label | string |  | yes | yes |
| location_landmark | string |  | yes | yes |
| location_lat | number |  | yes | yes |
| location_lng | number |  | yes | yes |
| location_phone | string |  | yes | yes |
| note | string |  | yes | yes |
| payment_method | Database["public"]["Enums"]["payment_method"] | payment_method |  |  |
| return_reason | string |  | yes | yes |
| return_requested_at | string |  | yes | yes |
| return_responded_at | string |  | yes | yes |
| return_status | Database["public"]["Enums"]["return_status"] | return_status |  | yes |
| status | Database["public"]["Enums"]["order_status"] | order_status |  | yes |
| store_id | string |  |  |  |
| total | number |  |  |  |
| updated_at | string |  |  | yes |

FKs: store_id → stores(id)

### password_reset_requests

| column | type | enum | null | default |
|---|---|---|---|---|
| applicant_name | string |  | yes | yes |
| decided_at | string |  | yes | yes |
| decided_by | string |  | yes | yes |
| id | string |  |  | yes |
| phone | string |  |  |  |
| reason | string |  | yes | yes |
| requested_at | string |  |  | yes |
| status | string |  |  | yes |
| user_id | string |  | yes | yes |
| user_type | string |  | yes | yes |

### pending_customers

| column | type | enum | null | default |
|---|---|---|---|---|
| claimed_by_user_id | string |  | yes | yes |
| created_at | string |  |  | yes |
| created_by | string |  |  |  |
| id | string |  |  | yes |
| name | string |  |  |  |
| phone | string |  |  |  |
| store_id | string |  |  |  |

FKs: store_id → stores(id)

### permission_bundle_items

| column | type | enum | null | default |
|---|---|---|---|---|
| bundle | string |  |  |  |
| permission | string |  |  |  |

FKs: bundle → permission_bundles(bundle); permission → permission_defs(perm)

### permission_bundles

| column | type | enum | null | default |
|---|---|---|---|---|
| bundle | string |  |  |  |
| label | string |  |  |  |
| sort | number |  |  | yes |

### permission_defs

| column | type | enum | null | default |
|---|---|---|---|---|
| grp | string |  |  |  |
| grp_label | string |  |  |  |
| label | string |  |  |  |
| perm | string |  |  |  |
| sort | number |  |  | yes |
| super_only | boolean |  |  | yes |

### product_offers

| column | type | enum | null | default |
|---|---|---|---|---|
| active | boolean |  |  | yes |
| created_at | string |  |  | yes |
| discount_price | number |  |  |  |
| ends_at | string |  | yes | yes |
| id | string |  |  | yes |
| max_qty | number |  | yes | yes |
| product_id | string |  |  |  |
| sold_qty | number |  |  | yes |
| starts_at | string |  |  | yes |
| store_id | string |  |  |  |

FKs: product_id → products(id); store_id → stores(id)

### products

| column | type | enum | null | default |
|---|---|---|---|---|
| barcode | string |  | yes | yes |
| category_id | string |  | yes | yes |
| created_at | string |  |  | yes |
| id | string |  |  | yes |
| image_url | string |  | yes | yes |
| in_stock | boolean |  |  | yes |
| lib_category | string |  | yes | yes |
| main_section | string |  | yes | yes |
| name | string |  |  |  |
| price | number |  |  |  |
| store_id | string |  |  |  |
| subcategory | string |  | yes | yes |

FKs: category_id → categories(id); store_id → stores(id)

### profiles

| column | type | enum | null | default |
|---|---|---|---|---|
| account_status | string |  |  | yes |
| address | string |  | yes | yes |
| approved_at | string |  | yes | yes |
| approved_by | string |  | yes | yes |
| business_category_id | string |  | yes | yes |
| business_name | string |  | yes | yes |
| city | string |  | yes | yes |
| created_at | string |  |  | yes |
| district | string |  | yes | yes |
| id | string |  |  |  |
| name | string |  | yes | yes |
| phone | string |  |  |  |
| status_reason | string |  | yes | yes |
| suspended_until | string |  | yes | yes |
| user_type | string |  | yes | yes |

FKs: business_category_id → business_categories(id)

### ratings

| column | type | enum | null | default |
|---|---|---|---|---|
| comment | string |  | yes | yes |
| created_at | string |  |  | yes |
| customer_id | string |  |  |  |
| id | string |  |  | yes |
| order_id | string |  | yes | yes |
| stars | number |  |  |  |
| store_id | string |  |  |  |

FKs: order_id → orders(id); store_id → stores(id)

### stores

| column | type | enum | null | default |
|---|---|---|---|---|
| area | string |  | yes | yes |
| business_category_id | string |  | yes | yes |
| commission_pct | number |  | yes | yes |
| created_at | string |  |  | yes |
| delivery_info | string |  | yes | yes |
| id | string |  |  | yes |
| image_url | string |  | yes | yes |
| is_open | boolean |  |  | yes |
| lat | number |  | yes | yes |
| lng | number |  | yes | yes |
| name | string |  |  |  |
| owner_id | string |  |  |  |
| phone | string |  | yes | yes |
| rating | number |  |  | yes |
| rating_count | number |  |  | yes |
| status | Database["public"]["Enums"]["store_status"] | store_status |  | yes |

FKs: business_category_id → business_categories(id)

### uptime_checks

| column | type | enum | null | default |
|---|---|---|---|---|
| checked_at | string |  |  | yes |
| error | string |  | yes | yes |
| http_status | number |  | yes | yes |
| id | number |  |  | yes |
| is_up | boolean |  |  |  |
| response_time_ms | number |  | yes | yes |
| target_id | string |  |  |  |

FKs: target_id → uptime_targets(id)

### uptime_incidents

| column | type | enum | null | default |
|---|---|---|---|---|
| alert_sent | boolean |  |  | yes |
| downtime_minutes | number |  | yes | yes |
| id | number |  |  | yes |
| last_error | string |  | yes | yes |
| recovery_alert_sent | boolean |  |  | yes |
| resolved_at | string |  | yes | yes |
| started_at | string |  |  | yes |
| target_id | string |  |  |  |

FKs: target_id → uptime_targets(id)

### uptime_pending

| column | type | enum | null | default |
|---|---|---|---|---|
| issued_at | string |  |  | yes |
| request_id | number |  |  |  |
| target_id | string |  |  |  |

FKs: target_id → uptime_targets(id)

### uptime_targets

| column | type | enum | null | default |
|---|---|---|---|---|
| consecutive_failures | number |  |  | yes |
| created_at | string |  |  | yes |
| expected_statuses | number[] |  |  | yes |
| id | string |  |  | yes |
| is_active | boolean |  |  | yes |
| last_checked_at | string |  | yes | yes |
| last_response_ms | number |  | yes | yes |
| last_status | string |  | yes | yes |
| method | string |  |  | yes |
| name | string |  |  |  |
| sort_order | number |  |  | yes |
| timeout_ms | number |  |  | yes |
| url | string |  |  |  |

### user_roles

| column | type | enum | null | default |
|---|---|---|---|---|
| created_at | string |  |  | yes |
| id | string |  |  | yes |
| role | Database["public"]["Enums"]["app_role"] | app_role |  |  |
| user_id | string |  |  |  |

### wallet_transactions

| column | type | enum | null | default |
|---|---|---|---|---|
| amount | number |  |  |  |
| created_at | string |  |  | yes |
| id | string |  |  | yes |
| method | string |  | yes | yes |
| note | string |  | yes | yes |
| order_id | string |  | yes | yes |
| reference | string |  | yes | yes |
| status | Database["public"]["Enums"]["wallet_tx_status"] | wallet_tx_status |  | yes |
| type | Database["public"]["Enums"]["wallet_tx_type"] | wallet_tx_type |  |  |
| user_id | string |  |  |  |
| wallet_id | string |  |  |  |

FKs: order_id → orders(id); wallet_id → wallets(id)

### wallets

| column | type | enum | null | default |
|---|---|---|---|---|
| balance | number |  |  | yes |
| created_at | string |  |  | yes |
| id | string |  |  | yes |
| user_id | string |  |  |  |
