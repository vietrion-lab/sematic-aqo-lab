-- Test T2: Store sales with date join
select d_year, s_store_name, sum(ss_net_profit) as total_profit
from store_sales, date_dim, store
where ss_sold_date_sk = d_date_sk
    and ss_store_sk = s_store_sk
    and d_year = 2000
group by d_year, s_store_name
order by total_profit desc
limit 20;
