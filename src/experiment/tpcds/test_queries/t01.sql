-- Test T1: Simple aggregate with filter
select i_category, count(*) as cnt, avg(i_current_price) as avg_price
from item
where i_current_price > 50
group by i_category
order by avg_price desc;
