-- Test T3: Multi-table join with subquery
select i_item_id, i_item_desc, avg(ss_sales_price) as avg_sales
from store_sales, item, customer_demographics, date_dim
where ss_item_sk = i_item_sk
    and ss_cdemo_sk = cd_demo_sk
    and ss_sold_date_sk = d_date_sk
    and cd_education_status = 'College'
    and d_year = 2001
group by i_item_id, i_item_desc
having avg(ss_sales_price) > (select avg(ss_sales_price) from store_sales)
order by avg_sales desc
limit 20;
