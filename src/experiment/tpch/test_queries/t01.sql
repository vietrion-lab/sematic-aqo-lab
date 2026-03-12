-- Test Q1: Simple aggregation with date filter
select l_returnflag, l_linestatus,
    sum(l_quantity) as sum_qty,
    avg(l_extendedprice) as avg_price
from lineitem
where l_shipdate <= date '1998-09-01'
group by l_returnflag, l_linestatus
order by l_returnflag, l_linestatus;
